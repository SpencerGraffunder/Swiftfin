//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI

/// Fetches and persists external text-subtitle sidecars for a download so
/// they stay selectable during offline playback (round-4 invisible-offline).
///
/// Embedded/in-container subtitles already ride the media file; only the
/// server-delivered sidecars are otherwise lost offline. Image-based subtitle
/// streams are skipped: the players drop them for progressive files anyway,
/// and rendering them offline would be misleading.
enum DownloadSubtitleSupport {

    /// External text subtitle streams worth persisting.
    static func candidates(in mediaSource: MediaSourceInfo) -> [MediaStream] {
        (mediaSource.mediaStreams ?? []).filter { stream in
            stream.type == .subtitle
                && stream.isExternal == true
                && stream.isTextSubtitleStream == true
        }
    }

    /// Server subtitle stream format for a codec, nil when unsupported.
    static func format(for stream: MediaStream) -> String? {
        switch stream.codec {
        case "subrip", "srt":
            "srt"
        case "ass":
            "ass"
        case "ssa":
            "ssa"
        case "webvtt", "vtt":
            "vtt"
        case "smptett", "ttml":
            "ttml"
        default:
            nil
        }
    }

    /// Fetches every candidate subtitle through the server (which converts to
    /// the requested format) and writes it into the download's subtitle
    /// directory. Failures are silent: that track simply stays unavailable
    /// offline.
    static func persist(
        for download: Download,
        itemID: String,
        mediaSourceID: String?,
        mediaSource: MediaSourceInfo,
        client: JellyfinClient
    ) async -> [Download.SubtitleFile] {
        let candidates = candidates(in: mediaSource)
        guard let itemID, candidates.isNotEmpty else { return [] }

        let directory = DownloadStorage.subtitleDirectory(for: download.id)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var saved: [Download.SubtitleFile] = []

        for stream in candidates {
            guard let index = stream.index,
                  let format = format(for: stream)
            else { continue }

            let request = Paths.getSubtitle(
                routeItemID: itemID,
                routeMediaSourceID: mediaSourceID ?? itemID,
                routeIndex: index,
                routeFormat: format
            )

            guard let response = try? await client.send(request) else { continue }

            let url = directory.appendingPathComponent("\(index).\(format)")

            do {
                try response.value.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                continue
            }

            saved.append(
                Download.SubtitleFile(
                    index: index,
                    format: format,
                    codec: stream.codec,
                    language: stream.language,
                    title: stream.title,
                    displayTitle: stream.displayTitle,
                    isHearingImpaired: stream.isHearingImpaired == true
                )
            )
        }

        return saved
    }
}
