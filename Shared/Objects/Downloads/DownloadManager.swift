//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import FactoryKit
import Foundation
import JellyfinAPI
import Logging
import Nuke
import SwiftUI
import UIKit

/// Manages the local downloads queue (issue #1784, #1788).
///
/// Responsibilities:
/// - Enqueue / pause / resume / cancel / delete downloads.
/// - Persist the queue (metadata + options) in the CoreStore so it survives
///   relaunches.
/// - Drive downloads through a background `URLSession` so they continue while
///   the app is backgrounded, with a concurrency limit.
/// - Recover the queue on launch and detect missing media files.
@MainActor
final class DownloadManager: ObservableObject {

    /// The shared manager (a singleton, used by views and the app entrypoint).
    static let shared = DownloadManager()

    private let logger = Logger.swiftfin()

    @Published
    private(set) var downloads: [Download] = []

    private var session: URLSession?

    /// The download task currently running for each download ID (used for
    /// cancellation). MainActor-isolated (the manager is @MainActor).
    private var activeTasks: [String: URLSessionDownloadTask] = [:]

    /// Maps an active download task to the download ID. `NSMapTable` is
    /// thread-safe, so the nonisolated session delegate can read it from
    /// URLSession's background queue. The task object is used as the key
    /// because `NSMapTable` requires object (reference) types.
    fileprivate nonisolated(unsafe) static let taskIDMap = NSMapTable<AnyObject, AnyObject>(
        keyOptions: .strongMemory,
        valueOptions: .strongMemory
    )

    /// In-memory resume data so a paused download can be resumed without
    /// starting over.
    fileprivate var resumeDataByDownloadID: [String: Data] = [:]

    private var hasStarted = false

    private var maxConcurrent: Int {
        max(1, Defaults[.Experimental.downloadsConcurrency])
    }

    /// Whether the manager has any downloads.
    var hasAnyDownloads: Bool {
        !downloads.isEmpty
    }

    /// The tracked download for an item, if any.
    func download(for itemID: String?) -> Download? {
        guard let itemID else { return nil }

        return downloads.first { $0.id == itemID }
    }

    // MARK: - Lifecycle

    /// Loads the persisted queue and starts the background session. Call once
    /// at app launch (issue #1788).
    func start() async {
        guard !hasStarted else { return }

        hasStarted = true

        let configuration: URLSessionConfiguration

        #if os(iOS)
        // iOS supports background download sessions, so downloads can
        // continue while the app is backgrounded (issue #1788).
        configuration = URLSessionConfiguration.background(withIdentifier: "swiftfin-downloads")
        #else
        // tvOS has no background sessions; use a long-running default session.
        configuration = URLSessionConfiguration.default
        #endif

        configuration.isDiscretionary = false

        #if os(iOS)
        configuration.sessionSendsLaunchEvents = true
        #endif

        configuration.timeoutIntervalForResource = 24 * 60 * 60

        let session = URLSession(configuration: configuration, delegate: DownloadSessionDelegate(manager: self), delegateQueue: nil)
        self.session = session

        observeLowPowerState()

        await loadQueue()
        reconcileWithDisk()
        await remapLiveTasks(in: session)
        processQueue()
    }

    /// Relaunch reconciliation for background sessions (issue #1788 QA pass).
    ///
    /// `taskIDMap` is in-memory only, so after a relaunch the restored
    /// background tasks were un-mappable: progress ticks were dropped, a
    /// finished file got discarded on arrival, and persisted `.downloading`
    /// entries counted as active forever (starving the queue). Tasks stamped
    /// with `taskDescription` remap themselves; zombie `.downloading` entries
    /// with no live task go back to `.queued`.
    private func remapLiveTasks(in session: URLSession) async {
        let restored = await session.allTasks.compactMap { $0 as? URLSessionDownloadTask }

        var liveIDs = Set<String>()
        for task in restored {
            guard let downloadID = task.taskDescription else { continue }

            activeTasks[downloadID] = task
            Self.taskIDMap.setObject(downloadID as NSString, forKey: task)
            liveIDs.insert(downloadID)
        }

        var requeued = false
        for index in downloads.indices
            where downloads[index].state == .downloading && !liveIDs.contains(downloads[index].id) {
            downloads[index].state = .queued
            requeued = true
        }

        if requeued {
            await persist()
        }
    }

    private func observeLowPowerState() {
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(
            forName: UIDevice.batteryLevelDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleLowPowerStateChanged()
            }
        }
        #endif
    }

    /// Pause active downloads when the device is on low power, so we don't
    /// drain the battery (issue #1788).
    private func handleLowPowerStateChanged() {
        #if os(iOS)
        guard UIDevice.current.isBatteryMonitoringEnabled,
              UIDevice.current.batteryState == .unplugged,
              UIDevice.current.batteryLevel < 0.2
        else { return }

        pauseAll()
        #endif
    }

    // MARK: - Queue mutations

    /// Enqueue an item for download (issue #1784).
    func download(
        _ item: BaseItemDto,
        options: DownloadOptions,
        mediaSource: MediaSourceInfo? = nil
    ) async {
        await start()

        guard let itemID = item.id else { return }

        if let index = index(of: itemID) {
            downloads[index].options = options
            if let mediaSource {
                downloads[index].mediaSource = mediaSource
            }
            if downloads[index].state != .completed {
                downloads[index].state = .queued
            }

            await persist()
            processQueue()

            return
        }

        let selectedMediaSource = mediaSource ?? item.mediaSources?.first
        guard let selectedMediaSource else {
            logger.error("No media source to download for item \(itemID)")

            return
        }

        let extensionName = selectedMediaSource.container ?? "mp4"
        let fileName = "\(itemID)-\(selectedMediaSource.id ?? "source").\(extensionName)"

        let download = Download(
            item: item,
            mediaSource: selectedMediaSource,
            options: options,
            fileName: fileName
        )

        downloads.append(download)
        await persist()
        processQueue()
    }

    func pause(_ downloadID: String) {
        // `.queued` also accepts the window while resolveStreamURL is still
        // running and no URLSession task exists yet — pausing there is legal
        // and must not silently no-op.
        guard let index = index(of: downloadID), downloads[index].state == .downloading || downloads[index].state == .queued else { return }

        cancelActiveTask(for: downloadID, pausing: true)

        downloads[index].state = .paused
        Task { await persist() }
    }

    func resume(_ downloadID: String) {
        guard let index = index(of: downloadID), downloads[index].state == .paused else { return }

        downloads[index].state = .queued
        processQueue()
        Task { await persist() }
    }

    /// Retry a failed download (issue #1788).
    func retry(_ downloadID: String) {
        guard let index = index(of: downloadID), downloads[index].state == .failed else { return }

        resumeDataByDownloadID[downloadID] = nil
        downloads[index].state = .queued
        downloads[index].progress = 0
        downloads[index].failureReason = nil
        processQueue()
        Task { await persist() }
    }

    /// Cancel the download and remove it from the queue (deletes the media file).
    func cancel(_ downloadID: String) {
        delete(downloadID, keepMediaFile: false)
    }

    /// Remove a download from the queue, deleting its media file and image.
    func delete(_ downloadID: String, keepMediaFile: Bool = false) {
        guard let index = index(of: downloadID) else { return }

        let download = downloads[index]

        cancelActiveTask(for: downloadID, pausing: false)

        if !keepMediaFile {
            try? FileManager.default.removeItem(at: download.fileURL)
        }

        try? FileManager.default.removeItem(at: download.posterImageURL)
        try? FileManager.default.removeItem(at: download.backdropImageURL)
        resumeDataByDownloadID[downloadID] = nil

        downloads.remove(at: index)
        Task {
            await persist()
            processQueue()
        }
    }

    /// Remove several downloads at once (downloads-library multi-select).
    /// Queue the next N episodes for download after one starts playing
    /// (round-3 "download next n episodes"). Gated by the Wi-Fi/cellular
    /// policy; failures (offline, removed show) are logged and skipped so the
    /// next play start retries. Existing downloads are never re-queued.
    func autoQueueNextEpisodes(after episode: BaseItemDto, userSession: UserSession) async {
        let count = Defaults[.Experimental.downloadsAutoQueueNext]
        guard count > 0,
              episode.type == .episode,
              let seriesID = episode.seriesID?.nilIfBlank,
              DownloadNetworkPolicy.allowsAutoDownload(allowCellular: Defaults[.Experimental.downloadsAllowCellular])
        else { return }

        await start()

        let client = userSession.client
        let userID = userSession.user.id

        var seasons: [BaseItemDto]
        do {
            var parameters = Paths.GetSeasonsParameters()
            parameters.userID = userID
            let response = try await client.send(Paths.getSeasons(seriesID: seriesID, parameters: parameters))
            seasons = (response.value.items ?? []).sorted { ($0.indexNumber ?? 0) < ($1.indexNumber ?? 0) }
        } catch {
            logger.warning("Auto-queue: unable to load seasons for \(seriesID): \(error.localizedDescription)")

            return
        }

        var seasonIndex = seasons.firstIndex { $0.id == episode.seasonID }
            ?? seasons.firstIndex { $0.indexNumber == episode.parentIndexNumber }
            ?? 0

        var candidates: [BaseItemDto] = []
        var seenCurrent = seasonIndex > 0

        while seasonIndex < seasons.count, candidates.count < count {
            defer { seasonIndex += 1 }
            guard let seasonID = seasons[seasonIndex].id else { continue }

            var parameters = Paths.GetEpisodesParameters()
            parameters.seasonID = seasonID
            parameters.userID = userID
            parameters.fields = PosterSubtitleField.itemFields

            let episodes: [BaseItemDto]
            do {
                let response = try await client.send(Paths.getEpisodes(seriesID: seasonID, parameters: parameters))
                episodes = (response.value.items ?? []).sorted { ($0.indexNumber ?? 0) < ($1.indexNumber ?? 0) }
            } catch {
                logger.warning("Auto-queue: unable to load episodes for \(seasonID): \(error.localizedDescription)")

                break
            }

            for candidate in episodes {
                guard let candidateID = candidate.id else { continue }

                if !seenCurrent {
                    seenCurrent = candidateID == episode.id
                    continue
                }
                guard candidateID != episode.id, index(of: candidateID) == nil else { continue }

                candidates.append(candidate)
                if candidates.count >= count {
                    break
                }
            }

            seenCurrent = true
        }

        for candidate in candidates {
            await download(candidate, options: .direct(candidate))
        }

        if candidates.isNotEmpty {
            logger.info("Auto-queue: queued \(candidates.count) episode(s) after \(episode.id ?? "?")")
        }
    }

    func deleteAll(in downloadIDs: some Sequence<String>) {
        for downloadID in downloadIDs {
            delete(downloadID)
        }
    }

    func pauseAll() {
        for download in downloads where download.state == .downloading {
            pause(download.id)
        }
    }

    func resumeAll() {
        for download in downloads where download.state == .paused {
            resume(download.id)
        }
    }

    /// Downloads whose in-flight task was intentionally paused/cancelled.
    /// Background sessions deliver resume data only through
    /// `didCompleteWithError`, so completion must consult this set instead of
    /// blindly marking the download failed (issue #1788 QA pass).
    fileprivate var deliberateCancellationIDs: Set<String> = []

    // MARK: - Delegate callbacks (called on MainActor)

    func setProgress(
        _ progress: Double,
        bytesWritten: Int64?,
        totalBytesExpected: Int64?,
        speed: Double?,
        for downloadID: String
    ) {
        guard let index = index(of: downloadID) else { return }

        downloads[index].progress = min(1, max(0, progress))

        if let bytesWritten {
            downloads[index].bytesWritten = bytesWritten
        }
        if let totalBytesExpected {
            downloads[index].totalBytesExpected = totalBytesExpected
        }
        if let speed {
            downloads[index].speedBytesPerSecond = speed
        }
    }

    /// The completed download for an item whose file is actually on disk —
    /// the check used by the resolver to prefer playing the downloaded
    /// version and by the downloads UI for local affordances.
    func completedLocalDownload(for itemID: String?) -> Download? {
        guard let itemID,
              let download = download(for: itemID),
              download.localFileURL != nil
        else { return nil }

        return download
    }

    func moveDownloadFile(_ downloadID: String, from tempURL: URL) {
        guard let index = index(of: downloadID) else {
            try? FileManager.default.removeItem(at: tempURL)

            return
        }

        let destination = downloads[index].fileURL

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }

            try FileManager.default.moveItem(at: tempURL, to: destination)
            persistPosterImage(for: downloads[index])
            persistBackdropImage(for: downloads[index])
            markCompleted(downloadID)
        } catch {
            logger.error("Failed to move downloaded file for \(downloadID): \(error.localizedDescription)")
            markFailed(downloadID, reason: error.localizedDescription)
        }
    }

    func markCompleted(_ downloadID: String) {
        guard let index = index(of: downloadID) else { return }

        downloads[index].state = .completed
        downloads[index].progress = 1
        Task { await persist() }
    }

    func markFailed(_ downloadID: String, reason: String? = nil) {
        guard let index = index(of: downloadID) else { return }

        downloads[index].state = .failed
        downloads[index].failureReason = reason
        Task { await persist() }
    }

    func notifyTaskFinished(_ downloadID: String) {
        if let task = activeTasks.removeValue(forKey: downloadID) {
            Self.taskIDMap.removeObject(forKey: task)
        }

        processQueue()
    }

    // MARK: - Queue processing

    private func processQueue() {
        guard let session else { return }

        let activeCount = downloads.count(where: { $0.state == .downloading })
        let queued = downloads.filter { $0.state == .queued }
        let toStart = queued.prefix(max(0, maxConcurrent - activeCount))

        for download in toStart {
            startTask(for: download, in: session)
        }
    }

    private func startTask(for download: Download, in session: URLSession) {
        Task { @MainActor in
            guard let index = self.index(of: download.id) else { return }
            guard let url = await self.resolveStreamURL(for: download) else {
                self.markFailed(download.id, reason: L10n.downloadStreamUnavailable)
                self.processQueue()

                return
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 600

            let task: URLSessionDownloadTask = if let resumeData = self.resumeDataByDownloadID[download.id], !resumeData.isEmpty {
                session.downloadTask(withResumeData: resumeData)
            } else {
                session.downloadTask(with: request)
            }

            self.downloads[index].state = .downloading
            self.activeTasks[download.id] = task
            Self.taskIDMap.setObject(download.id as NSString, forKey: task)
            // Background-session tasks persist across relaunches; the
            // description rides along so they stay mappable (issue #1788).
            task.taskDescription = download.id

            task.resume()

            Task { await self.persist() }
        }
    }

    /// Resolve the stream URL to download, reusing the playback pipeline's
    /// resolution so the downloaded file matches what the player would use.
    private func resolveStreamURL(for download: Download) async -> URL? {
        guard let userSession = Container.shared.currentUserSession(), let itemID = download.item.id else { return nil }

        do {
            var configuration = MediaPlaybackConfiguration()
            configuration.requestedBitrate = download.options.bitrate
            configuration.compatibilityMode = download.options.method == .transcoded
                ? .mostCompatible
                : .directPlay

            let deviceProfile = DeviceProfile.build(
                for: Defaults[.VideoPlayer.mediaPlayerType],
                configuration: configuration,
                mediaSource: download.mediaSource
            )

            var playbackInfo = PlaybackInfoDto()
            playbackInfo.isAutoOpenLiveStream = true
            playbackInfo.deviceProfile = deviceProfile
            playbackInfo.mediaSourceID = download.mediaSource.id
            playbackInfo.userID = userSession.user.id
            if download.options.bitrate != .auto {
                playbackInfo.maxStreamingBitrate = download.options.bitrate.rawValue
            }
            if download.options.method == .transcoded {
                playbackInfo.enableDirectPlay = false
                playbackInfo.enableDirectStream = false
                playbackInfo.enableTranscoding = true
            }

            let response = try await userSession.send(
                Paths.getPostedPlaybackInfo(itemID: itemID, playbackInfo)
            )

            let sources = response.value.mediaSources ?? []
            let resolvedSource = sources.first(property: \.id, equalTo: download.mediaSource.id) ?? sources.first

            guard let resolvedSource, let playSessionID = response.value.playSessionID else { return nil }

            if let transcodingPath = resolvedSource.transcodingURL {
                return userSession.client.url(path: transcodingPath)
            }

            let parameters = Paths.GetVideoStreamParameters(
                isStatic: true,
                tag: resolvedSource.eTag ?? download.item.etag,
                playSessionID: playSessionID,
                mediaSourceID: resolvedSource.id ?? itemID,
                liveStreamID: resolvedSource.liveStreamID
            )

            return userSession.client.url(
                with: Paths.getVideoStream(itemID: itemID, parameters: parameters),
                queryAPIKey: true
            )
        } catch {
            logger.error("Failed to resolve download stream URL for \(download.id): \(error.localizedDescription)")

            return nil
        }
    }

    // MARK: - Task helpers

    private func cancelActiveTask(for downloadID: String, pausing: Bool) {
        // Plain cancel(): background sessions don't support
        // cancel(byProducingResumeData:). The mapping stays alive until
        // `didCompleteWithError` runs so resume data can be captured there.
        guard let task = activeTasks[downloadID] else {
            activeTasks.removeValue(forKey: downloadID)
            if pausing {
                deliberateCancellationIDs.remove(downloadID)
            }

            return
        }

        if pausing {
            deliberateCancellationIDs.insert(downloadID)
        } else {
            activeTasks.removeValue(forKey: downloadID)
            Self.taskIDMap.removeObject(forKey: task)
            deliberateCancellationIDs.remove(downloadID)
        }

        task.cancel()
    }

    // MARK: - Persistence (CoreStore)

    private var ownerID: String {
        Container.shared.currentUserSession()?.user.id ?? "swiftfin"
    }

    private func persist() async {
        guard let userSession = Container.shared.currentUserSession() else { return }

        do {
            try AnyStoredData.store(
                value: downloads,
                ownerID: userSession.user.id,
                field: "downloads",
                key: "queue"
            )
        } catch {
            logger.error("Failed to persist downloads: \(error.localizedDescription)")
        }
    }

    private func loadQueue() async {
        guard let userSession = Container.shared.currentUserSession() else { return }

        do {
            let stored: [Download]? = try AnyStoredData.fetch(
                ownerID: userSession.user.id,
                field: "downloads",
                key: "queue"
            )
            self.downloads = stored ?? []
        } catch {
            logger.error("Failed to load downloads: \(error.localizedDescription)")
            downloads = []
        }
    }

    // MARK: - Recovery (issue #1788)

    /// Ensure completed downloads still have their file on disk; otherwise mark
    /// them failed so the user can re-download (missing-file recovery).
    private func reconcileWithDisk() {
        let fileManager = FileManager.default
        var changed = false

        for index in downloads.indices {
            if downloads[index].state == .completed,
               !fileManager.fileExists(atPath: downloads[index].fileURL.path) {
                downloads[index].state = .failed
                downloads[index].progress = 0
                changed = true

                logger.warning("Downloaded file missing on disk for \(downloads[index].id); marked failed")
            }
        }

        if changed {
            Task { await persist() }
        }
    }

    // MARK: - Images

    private func persistPosterImage(for download: Download) {
        let source = download.item.imageSource(
            .primary,
            itemID: download.item.id,
            environment: ImageSourceOptions(maxWidth: 400, maxHeight: nil)
        )
        guard let url = source?.url else { return }

        Task {
            if let (data, _) = try? await URLSession.shared.data(from: url) {
                try? data.write(to: download.posterImageURL)
            }
        }
    }

    /// Persists the landscape backdrop (the episode/series preview image) so
    /// the downloads library and offline item views can show previews in
    /// airplane mode. Tries the same URL candidates the poster grid uses:
    /// the parent backdrop, the item's own backdrop, then the series thumb.
    private func persistBackdropImage(for download: Download) {
        let environment = ImageSourceOptions(maxWidth: 640, maxHeight: nil)

        let candidates = [
            download.item.imageSource(
                .backdrop,
                itemID: download.item.parentBackdropItemID,
                tag: download.item.parentBackdropImageTags?.first,
                environment: environment
            ),
            download.item.imageSource(.backdrop, itemID: download.item.id, environment: environment),
            download.item.imageSource(
                .thumb,
                itemID: download.item.seriesID,
                tag: download.item.seriesThumbImageTag,
                environment: environment
            ),
        ].compactMap { $0?.url }

        guard !candidates.isEmpty else { return }

        Task {
            let pipeline: ImagePipeline = .Swiftfin.posters
            for url in candidates {
                if let image = try? await pipeline.image(for: url), let data = image.jpegData(compressionQuality: 0.85) {
                    try? data.write(to: download.backdropImageURL)
                    return
                }
            }
        }
    }

    /// Queue every downloadable episode of a season (long-press season →
    /// download whole season). Already-queued/completed episodes are skipped.
    func downloadSeason(_ season: BaseItemDto) async {
        guard let seasonID = season.id,
              let userSession = Container.shared.currentUserSession()
        else { return }

        await start()

        var parameters = Paths.GetEpisodesParameters()
        parameters.enableUserData = true
        parameters.fields = PosterSubtitleField.itemFields + [.overview]
        parameters.seasonID = seasonID
        parameters.userID = userSession.user.id

        do {
            let response = try await userSession.send(
                Paths.getEpisodes(seriesID: seasonID, parameters: parameters)
            )

            let episodes = (response.value.items ?? []).filter { item in
                item.type == .episode
                    && item.mediaSources?.isEmpty == false
                    && download(for: item.id)?.state != .completed
            }

            for episode in episodes {
                await download(episode, options: .direct(episode))
            }
        } catch {
            logger.error("Failed to fetch season \(seasonID) for download: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func index(of downloadID: String) -> Int? {
        downloads.firstIndex { $0.id == downloadID }
    }
}

/// A nonisolated `URLSessionDownloadDelegate` that forwards URLSession
/// callbacks (delivered on URLSession's background queue) to the `@MainActor`
/// `DownloadManager`. The download ID for a task is resolved via a shared,
/// thread-safe `NSMapTable` keyed by the task object.
final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private let manager: DownloadManager

    /// Last (time, bytes) transfer samples for speed estimation, guarded by a
    /// lock because URLSession delivers callbacks off the main thread.
    private var speedSamples: [String: (Date, Int64)] = [:]
    private let speedLock = NSLock()

    init(manager: DownloadManager) {
        self.manager = manager
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData dataBytes: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let downloadID = downloadID(for: downloadTask) else { return }

        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0

        // Smoothed instantaneous speed: sample every ~2 s of transfer so the
        // downloads row can show MB/s and a time-remaining estimate.
        var speed: Double?
        speedLock.lock()
        let now = Date()
        if let (sampleTime, sampleBytes) = speedSamples[downloadID] {
            let elapsed = now.timeIntervalSince(sampleTime)
            if elapsed >= 2 {
                speed = max(0, Double(totalBytesWritten - sampleBytes) / elapsed)
                speedSamples[downloadID] = (now, totalBytesWritten)
            }
        } else {
            speedSamples[downloadID] = (now, totalBytesWritten)
        }
        speedLock.unlock()

        Task { @MainActor in
            self.manager.setProgress(
                progress,
                bytesWritten: totalBytesWritten,
                totalBytesExpected: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil,
                speed: speed,
                for: downloadID
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let downloadID = downloadID(for: downloadTask) else {
            try? FileManager.default.removeItem(at: location)

            return
        }

        // URLSession deletes `location` the moment this callback returns, so the
        // file MUST be moved synchronously here. Handing the original URL to an
        // async MainActor hop raced the deletion and failed every move
        // ("CFNetworkDownload_*.tmp couldn't be moved"), marking downloads failed.
        let stagingURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("swiftfin-staging-\(downloadID)-\(UUID().uuidString)")

        do {
            try FileManager.default.moveItem(at: location, to: stagingURL)
        } catch {
            Task { @MainActor in
                self.manager.markFailed(downloadID, reason: error.localizedDescription)
                self.manager.notifyTaskFinished(downloadID)
            }

            return
        }

        Task { @MainActor in
            self.manager.moveDownloadFile(downloadID, from: stagingURL)
            self.manager.notifyTaskFinished(downloadID)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: any Error?) {
        guard let downloadID = downloadID(for: task), let error else { return }

        // Pause/cancel also surfaces here (background sessions report the
        // cancellation as an error, with resume data in the userInfo).
        let nsError = error as NSError
        let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data

        Task { @MainActor in
            if self.manager.deliberateCancellationIDs.contains(downloadID) {
                self.manager.deliberateCancellationIDs.remove(downloadID)
                if let resumeData {
                    self.manager.resumeDataByDownloadID[downloadID] = resumeData
                }
            } else {
                self.manager.markFailed(downloadID, reason: error.localizedDescription)
            }

            self.manager.notifyTaskFinished(downloadID)
        }
    }

    private func downloadID(for task: URLSessionTask) -> String? {
        (DownloadManager.taskIDMap.object(forKey: task) as? String) ?? task.taskDescription
    }
}
