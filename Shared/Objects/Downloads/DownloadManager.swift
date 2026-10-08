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
import SwiftUI

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

    // Maps the stream URL (absolute string) of each active download task to the
    // download ID. `NSMapTable` is thread-safe, so the nonisolated session
    // delegate can read it from URLSession's background queue. `NSString` is
    // used for the key because `NSMapTable` requires class (reference) types.
    private static let taskURLMap = NSMapTable(
        keyOptions: .strongMemory,
        valueOptions: .strongMemory
    )

    // In-memory resume data so a paused download can be resumed without
    // starting over.
    private var resumeDataByDownloadID: [String: Data] = [:]

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
        configuration.sessionSendsPendingEvents = true
        #endif

        configuration.timeoutIntervalForResource = 24 * 60 * 60

        let session = URLSession(configuration: configuration, delegate: DownloadSessionDelegate(manager: self), delegateQueue: nil)
        self.session = session

        observeLowPowerState()

        await loadQueue()
        reconcileWithDisk()
        processQueue()
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
        guard let index = index(of: downloadID), downloads[index].state == .downloading else { return }

        cancelActiveTask(for: downloadID) { [weak self] data in
            Task { @MainActor [weak self] in
                self?.resumeDataByDownloadID[downloadID] = data
            }
        }

        downloads[index].state = .paused
        if let url = streamURL(for: downloadID) {
            Self.taskURLMap.removeObject(forKey: url.absoluteString as NSString)
        }
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

        cancelActiveTask(for: downloadID) { _ in }

        if !keepMediaFile {
            try? FileManager.default.removeItem(at: download.fileURL)
        }

        try? FileManager.default.removeItem(at: download.posterImageURL)
        resumeDataByDownloadID[downloadID] = nil

        downloads.remove(at: index)
        Task {
            await persist()
            processQueue()
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

    // MARK: - Delegate callbacks (called on MainActor)

    func setProgress(_ progress: Double, for downloadID: String) {
        guard let index = index(of: downloadID) else { return }

        downloads[index].progress = min(1, max(0, progress))
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
            markCompleted(downloadID)
        } catch {
            logger.error("Failed to move downloaded file for \(downloadID): \(error.localizedDescription)")
            markFailed(downloadID)
        }
    }

    func markCompleted(_ downloadID: String) {
        guard let index = index(of: downloadID) else { return }

        downloads[index].state = .completed
        downloads[index].progress = 1
        Task { await persist() }
    }

    func markFailed(_ downloadID: String) {
        guard let index = index(of: downloadID) else { return }

        downloads[index].state = .failed
        Task { await persist() }
    }

    func notifyTaskFinished(_ downloadID: String) {
        processQueue()
    }

    // MARK: - Queue processing

    private func processQueue() {
        guard let session else { return }

        let activeCount = downloads.filter { $0.state == .downloading }.count
        let queued = downloads.filter { $0.state == .queued }
        let toStart = queued.prefix(max(0, maxConcurrent - activeCount))

        for download in toStart {
            startTask(for: download, in: session)
        }
    }

    private func startTask(for download: Download, in session: URLSession) {
        guard let index = index(of: download.id) else { return }

        Task { @MainActor in
            guard let url = await resolveStreamURL(for: download) else {
                markFailed(download.id)
                processQueue()

                return
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 600

            let task: URLSessionDownloadTask
            if let resumeData = resumeDataByDownloadID[download.id], !resumeData.isEmpty {
                task = session.downloadTask(withResumeData: resumeData)
            } else {
                task = session.downloadTask(with: request)
            }

            downloads[index].state = .downloading
            Self.taskURLMap.setObject(download.id as NSString, forKey: url.absoluteString as NSString)

            task.resume()

            Task { await persist() }
        }
    }

    /// Resolve the stream URL to download, reusing the playback pipeline's
    /// resolution so the downloaded file matches what the player would use.
    private func resolveStreamURL(for download: Download) async -> URL? {
        guard let userSession = Container.shared.currentUserSession() else { return nil }

        let compatibilityMode: PlaybackCompatibility = download.options.method == .transcoded
            ? .mostCompatible
            : .directPlay

        do {
            let playbackItem = try await MediaPlayerItem.build(
                for: download.item,
                mediaSource: download.mediaSource,
                requestedBitrate: download.options.bitrate,
                compatibilityMode: compatibilityMode
            )

            return playbackItem.url
        } catch {
            logger.error("Failed to resolve download stream URL for \(download.id): \(error.localizedDescription)")

            return nil
        }
    }

    // MARK: - Offline playback

    /// Builds a `MediaPlayerItem` that plays a locally downloaded file, reusing the
    /// same playback pipeline (device profile, track handling) as online playback
    /// (issue #1789).
    static func makeOfflinePlaybackItem(
        item: BaseItemDto,
        mediaSource: MediaSourceInfo,
        fileURL: URL,
        bitrate: PlaybackBitrate
    ) -> MediaPlayerItem {
        let deviceProfile = DeviceProfile.build(
            for: Defaults[.VideoPlayer.videoPlayerType],
            compatibilityMode: .directPlay
        )

        return MediaPlayerItem(
            baseItem: item,
            mediaSource: mediaSource,
            playSessionID: UUID().uuidString,
            url: fileURL,
            requestedBitrate: bitrate,
            deviceProfile: deviceProfile
        )
    }

    // MARK: - Task helpers

    private func cancelActiveTask(for downloadID: String, onCancelling: @escaping (Data) -> Void) {
        guard let url = streamURL(for: downloadID) else {
            onCancelling(Data())

            return
        }

        for task in session?.downloadTasks ?? [] {
            if task.originalRequest?.url == url {
                task.cancel { onCancelling($0 ?? Data()) }
            }
        }

        Self.taskURLMap.removeObject(forKey: url.absoluteString as NSString)
    }

    private func streamURL(for downloadID: String) -> URL? {
        for key in Self.taskURLMap.objectKeys.allObjects {
            if let value = Self.taskURLMap.object(for: key) as? String,
               value == downloadID,
               let keyString = key as? String,
               let url = URL(string: keyString)
            {
                return url
            }
        }

        return nil
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
               !fileManager.fileExists(atPath: downloads[index].fileURL.path)
            {
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

    // MARK: - Helpers

    private func index(of downloadID: String) -> Int? {
        downloads.firstIndex { $0.id == downloadID }
    }
}

/// A nonisolated `URLSessionDownloadDelegate` that forwards URLSession
/// callbacks (delivered on URLSession's background queue) to the `@MainActor`
/// `DownloadManager`. The download ID for a task is resolved via a shared,
/// thread-safe `NSMapTable` keyed by stream URL string.
final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private let manager: DownloadManager

    init(manager: DownloadManager) {
        self.manager = manager
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWrite dataBytes: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let downloadID = downloadID(for: downloadTask), totalBytesExpectedToWrite > 0 else { return }

        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)

        Task { @MainActor in
            self.manager.setProgress(progress, for: downloadID)
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

        Task { @MainActor in
            self.manager.moveDownloadFile(downloadID, from: location)
            self.manager.notifyTaskFinished(downloadID)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let downloadID = downloadID(for: task), let error else { return }

        Task { @MainActor in
            self.manager.markFailed(downloadID)
            self.manager.notifyTaskFinished(downloadID)
        }
    }

    private func downloadID(for task: URLSessionTask) -> String? {
        guard let url = task.originalRequest?.url else { return nil }

        return DownloadManager.taskURLMap.object(for: url.absoluteString as NSString) as? String
    }
}
