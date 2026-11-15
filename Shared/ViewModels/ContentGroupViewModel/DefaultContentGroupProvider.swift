//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Defaults
import FactoryKit
import Foundation
import JellyfinAPI

struct DefaultContentGroupProvider: ContentGroupProvider {

    /// Resolved fresh on every access. `@Injected` stores its resolution at
    /// init, and this provider lives for the whole process inside the static
    /// tab coordinator — a stored injection would keep serving a dead
    /// `UserSession` after a session swap (issue QA pass: home stuck empty).
    var userSession: UserSession? {
        Container.shared.currentUserSession()
    }

    let displayTitle: String = L10n.home
    let id: String = "default-content-group-provider"

    var refreshRequests: AnyPublisher<Void, Never> {
        userSession?.userLibraryChanges ?? Combine.Empty().eraseToAnyPublisher()
    }

    func makeGroups(environment: Empty) async throws -> [any ContentGroup] {
        // A nil session is a failure to retry against, not "no content":
        // returning [] here would render "No results" instead of a
        // retryable error state.
        guard let userSession else { throw ErrorMessage(L10n.unknownError) }

        do {
            return try await _makeOnlineGroups(userSession: userSession)
        } catch {
            // Server unreachable (airplane mode, tunnel down): fall back to a
            // home built entirely from completed local downloads so the screen
            // still shows the user's content instead of an error. With nothing
            // downloaded the original error surfaces as before.
            if let offline = Self._offlineGroups(), !offline.isEmpty {
                return offline
            }
            throw error
        }
    }

    private func _makeOnlineGroups(userSession: UserSession) async throws -> [any ContentGroup] {
        let parameters = Paths.GetUserViewsParameters(userID: userSession.user.id)
        let userViewsPath = Paths.getUserViews(parameters: parameters)
        let userViews = try await userSession.send(userViewsPath)
        let excludedLibraryIDs = userSession.userData.configuration?.latestItemsExcludes ?? []

        let resolvedUserViews = (userViews.value.items ?? [])
            .subtracting(excludedLibraryIDs, using: \.id)
            .intersecting(
                [
                    .homevideos,
                    .movies,
                    .musicvideos,
                    .tvshows,
                ],
                using: \.collectionType
            )

        return _makeGroups(userViews: resolvedUserViews)
    }

    @ContentGroupBuilder
    private func _makeGroups(userViews: [BaseItemDto]) -> [any ContentGroup] {
        #if os(tvOS)
        let cinematicSelectionContentGroup = CinematicSelectionContentGroup(
            resumeLibrary: ResumeItemsLibrary(mediaTypes: [.video]),
            recentlyAddedLibrary: RecentlyAddedLibrary()
        )

        cinematicSelectionContentGroup
        #else
        PosterGroup(
            library: ResumeItemsLibrary(mediaTypes: [.video]),
            posterDisplayType: .landscape,
            posterSize: .medium,
            _viewContext: .isInResume
        )
        #endif

        PosterGroup(
            library: NextUpLibrary()
        )

        if Defaults[.Customization.Home.showRecentlyAdded] {
            #if os(tvOS)
            CinematicRecentlyAddedContentGroup(
                viewModel: cinematicSelectionContentGroup.viewModel
            )
            #else
            PosterGroup(
                library: ItemLibrary(
                    parent: BaseItemDto(name: L10n.recentlyAdded.localizedCapitalized),
                    filters: .init(
                        itemTypes: [.movie, .series],
                        sortBy: [.dateCreated],
                        sortOrder: [.descending]
                    )
                )
            )
            #endif
        }

        if Defaults[.Customization.Home.showRecentlyPlayed] {
            PosterGroup(
                library: ItemLibrary(
                    parent: BaseItemDto(name: L10n.recentlyPlayed.localizedCapitalized),
                    filters: .init(
                        itemTypes: [.movie, .series],
                        sortBy: [.datePlayed],
                        sortOrder: [.descending],
                        traits: [.isPlayed]
                    )
                )
            )
        }

        PosterGroup(
            id: "programs-recommended",
            library: RecommendedProgramsLibrary(),
            posterDisplayType: .landscape,
            posterSize: .small
        )

        userViews
            .map(LatestInLibrary.init)
            .map {
                PosterGroup(
                    library: $0,
                    posterDisplayType: .landscape
                )
            }
    }

    /// Home groups derived from completed local downloads, used whenever the
    /// server cannot be reached so airplane mode still shows the user's
    /// content. Mirrors the online home's shape: a resume row (landscape),
    /// then movies and episodes rows. Returns nil when nothing is downloaded,
    /// letting the caller surface the normal retryable error instead of an
    /// empty home.
    private static func _offlineGroups() -> [any ContentGroup]? {
        let completed = DownloadManager.shared.downloads.filter { download in
            download.state == .completed && download.localFileURL != nil
        }

        guard !completed.isEmpty else { return nil }

        let positions = LocalPlaybackPositions.shared
        var seen = Set<String>()

        func unique(_ items: [BaseItemDto]) -> [BaseItemDto] {
            items.filter { item in
                guard let id = item.id else { return true }

                return seen.insert(id).inserted
            }
        }

        let resumable = unique(
            completed.filter { download in
                guard let entry = positions.entry(for: download.item.id) else { return false }

                return !entry.completed && entry.ticks > 0
            }
            .map(\.item)
        )

        let movies = unique(completed.filter { $0.item.type == .movie }.map(\.item))
        let episodes = unique(completed.filter { $0.item.type == .episode }.map(\.item))

        var groups: [any ContentGroup] = []

        if !resumable.isEmpty {
            groups.append(
                PosterGroup(
                    id: "offline-resume",
                    library: StaticLibrary(title: L10n.resume, id: "offline-resume", elements: resumable),
                    posterDisplayType: .landscape,
                    posterSize: .medium,
                    _viewContext: .isInResume
                )
            )
        }

        if !movies.isEmpty {
            groups.append(
                PosterGroup(
                    id: "offline-movies",
                    library: StaticLibrary(title: L10n.movies, id: "offline-movies", elements: movies)
                )
            )
        }

        if !episodes.isEmpty {
            groups.append(
                PosterGroup(
                    id: "offline-episodes",
                    library: StaticLibrary(title: L10n.episodes, id: "offline-episodes", elements: episodes)
                )
            )
        }

        return groups
    }
}
