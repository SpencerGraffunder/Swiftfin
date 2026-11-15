//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI

/// Fetches and persists trickplay thumbnail sheets (or per-chapter thumbs as
/// a fallback) at download completion, so scrubbing previews and chapter
/// images survive airplane mode (round-4 invisible-offline).
///
/// Mirrors the online `PreviewImageProvider` exactly: the same smallest-width
/// resolution selection and the "stop at first failure" sheet loop.
enum DownloadTrickplaySupport {

    /// Upper bound so a misconfigured server cannot flood the downloads dir.
    private static let maxSheets = 64

    /// Same resolution choice as the online provider: smallest usable width.
    static func select(in item: BaseItemDto, mediaSourceID: String?) -> (width: Int, info: TrickplayInfoDto)? {
        guard let mediaSourceID, let resolutions = item.trickplay?[mediaSourceID] else { return nil }

        for info in resolutions.values.sorted(by: { ($0.width ?? 0) < ($1.width ?? 0) }) {
            guard let width = info.width,
                  width > 0,
                  let height = info.height,
                  height > 0,
                  let columns = info.tileWidth,
                  columns > 0,
                  let rows = info.tileHeight,
                  rows > 0,
                  let interval = info.interval,
                  interval > 0
            else { continue }

            return (width, info)
        }

        return nil
    }

    /// The server gives no sheet count, so bound it by thumbnailCount AND the
    /// runtime (thumbnailCount only counts non-black thumbnails).
    static func sheetCount(info: TrickplayInfoDto, runtimeTicks: Int64?) -> Int {
        let tilesPerSheet = max((info.tileWidth ?? 1) * (info.tileHeight ?? 1), 1)
        let interval = max(info.interval ?? 10000, 1)

        var count = 1

        if let thumbnailCount = info.thumbnailCount, thumbnailCount > 0 {
            count = max(count, Int(ceil(Double(thumbnailCount) / Double(tilesPerSheet))))
        }

        if let runtimeTicks, runtimeTicks > 0 {
            // One thumbnail every `interval` milliseconds; one millisecond is
            // 10_000 ticks. (The first version of this line multiplied by
            // 1000 instead, overcounting 1000x — pinned by OfflineExtrasTests.)
            let thumbnails = Double(runtimeTicks) / (10000.0 * Double(interval))
            count = max(count, Int(ceil(thumbnails / Double(tilesPerSheet))))
        }

        return min(count, maxSheets)
    }

    /// Downloads the trickplay sheets and writes the manifest. Silent on
    /// failure; a partially fetched prefix still works (the online provider
    /// also stops at the first missing sheet).
    static func persist(
        downloadID: String,
        item: BaseItemDto,
        mediaSource: MediaSourceInfo,
        client: JellyfinClient
    ) async -> Download.TrickplayManifest? {
        guard let itemID = item.id,
              let (width, info) = select(in: item, mediaSourceID: mediaSource.id)
        else { return nil }

        let columns = info.tileWidth ?? 1
        let rows = info.tileHeight ?? 1
        let count = sheetCount(info: info, runtimeTicks: mediaSource.runTimeTicks.map(Int64.init))
        let sheetDirectory = DownloadStorage.trickplayDirectory(for: downloadID)
            .appendingPathComponent(String(width), isDirectory: true)
        try? FileManager.default.createDirectory(at: sheetDirectory, withIntermediateDirectories: true)

        var stored = 0

        for index in 0 ..< count {
            let request = Paths.getTrickplayTileImage(
                itemID: itemID,
                width: width,
                index: index,
                mediaSourceID: mediaSource.id
            )

            guard let response = try? await client.send(request) else { break }

            let url = sheetDirectory.appendingPathComponent("\(index).jpg")

            do {
                try response.value.write(to: url)
            } catch {
                break
            }

            stored += 1
        }

        guard stored > 0 else { return nil }

        let manifest = Download.TrickplayManifest(
            width: width,
            height: info.height ?? 0,
            columns: columns,
            rows: rows,
            intervalMilliseconds: info.interval ?? 10000,
            sheetCount: stored
        )

        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: DownloadStorage.trickplayManifestURL(for: downloadID))
        }

        return manifest
    }

    /// Fallback used when the item has no trickplay: fetch the per-chapter
    /// thumbnail images the chapter menu/scrubber shows online, stored at the
    /// same `<index>` positions the chapter image source would use.
    static func persistChapterThumbs(
        downloadID: String,
        item: BaseItemDto,
        client: JellyfinClient
    ) async {
        guard let itemID = item.id else { return }

        let directory = DownloadStorage.trickplayDirectory(for: downloadID)
            .appendingPathComponent("chapters", isDirectory: true)

        var storedAny = false

        for (index, chapter) in (item.chapters ?? []).enumerated() {
            guard let imageTag = chapter.imageTag, imageTag.isNotEmpty else { continue }

            var parameters = Paths.GetItemImageParameters()
            parameters.maxWidth = 500
            parameters.quality = 90
            parameters.tag = imageTag
            parameters.imageIndex = index

            let request = Paths.getItemImage(
                itemID: itemID,
                imageType: ImageType.chapter.rawValue,
                parameters: parameters
            )

            guard let response = try? await client.send(request) else { continue }

            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            do {
                try response.value.write(to: directory.appendingPathComponent("\(index).jpg"))
                storedAny = true
            } catch {
                continue
            }
        }

        _ = storedAny
    }
}
