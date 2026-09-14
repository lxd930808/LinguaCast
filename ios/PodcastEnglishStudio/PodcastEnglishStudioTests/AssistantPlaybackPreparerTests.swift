import Foundation
import XCTest

#if canImport(CloudSyncKit) && canImport(DomainModels)

import SwiftData
@testable import PodcastEnglishStudio
@testable import CloudSyncKit
@testable import DomainModels
import PodcastEnglishStudioCore

@MainActor
final class AssistantPlaybackPreparerTests: XCTestCase {
    func testMaterializesAssistantPodcastAndVideoRecords() async throws {
        let (container, context) = try makeContainer()
        _ = container
        let installer = RecordingInstaller()
        let preparer = AssistantPlaybackPreparer(installer: installer)

        let podcastBinding = makeBinding(
            searchResultId: "sr_ep",
            contentKey: "podcast:aaaaaaaaaaaaaaaa:bbbbbbbbbbbbbbbb",
            contentType: .podcastEpisode,
            jobID: "job-podcast"
        )
        let podcastSource = makeSource(
            searchResultId: "sr_ep",
            platform: .podcast,
            sourceType: .podcastEpisode,
            sourceId: "guid-ep-1",
            url: "https://media.example.com/ep.mp3",
            feedURL: "https://example.com/feed.xml",
            title: "Assistant Episode"
        )
        let podcastPrepared = try await preparer.prepare(
            binding: podcastBinding,
            source: podcastSource,
            configuration: AppConfiguration(),
            context: context
        )
        guard case .podcast(let episodeID) = podcastPrepared else {
            return XCTFail("expected podcast playback")
        }
        let episode = try XCTUnwrap(
            context.fetch(FetchDescriptor<EpisodeRecord>()).first { $0.id == episodeID }
        )
        XCTAssertEqual(episode.catalogOrigin, .assistant)
        XCTAssertEqual(episode.episodeGUID, "guid-ep-1")
        XCTAssertEqual(episode.assistantFeedURL, "https://example.com/feed.xml")
        XCTAssertEqual(episode.enclosureURL, "https://media.example.com/ep.mp3")
        XCTAssertFalse(episode.appearsInSubscriptionLibrary)
        XCTAssertEqual(installer.podcastJobIDs, ["job-podcast"])

        let videoBinding = makeBinding(
            searchResultId: "sr_yt",
            contentKey: "video:youtube:abc123",
            contentType: .video,
            jobID: "job-video"
        )
        let videoSource = makeSource(
            searchResultId: "sr_yt",
            platform: .youtube,
            sourceType: .video,
            sourceId: "abc123",
            url: "https://www.youtube.com/watch?v=abc123",
            title: "Assistant Video"
        )
        let videoPrepared = try await preparer.prepare(
            binding: videoBinding,
            source: videoSource,
            configuration: AppConfiguration(),
            context: context
        )
        guard case .youtube(let videoID) = videoPrepared else {
            return XCTFail("expected youtube playback")
        }
        XCTAssertEqual(videoID, "abc123")
        let video = try XCTUnwrap(
            context.fetch(FetchDescriptor<YTVideoRecord>()).first { $0.id == "abc123" }
        )
        XCTAssertEqual(video.catalogOrigin, .assistant)
        XCTAssertEqual(video.channelRecordID, CatalogOrigin.assistantChannelRecordID)
        XCTAssertFalse(video.appearsInSubscriptionLibrary)
        XCTAssertEqual(installer.videoJobIDs, ["job-video"])
    }

    func testReusesExistingSubscriptionVideoWithoutChangingOrigin() async throws {
        let (_, context) = try makeContainer()
        let existing = YTVideoRecord(
            id: "abc123",
            channelRecordID: "UCsub",
            channelID: "UCsub",
            title: "Subscribed",
            url: "https://www.youtube.com/watch?v=abc123"
        )
        context.insert(existing)
        try context.save()

        let installer = RecordingInstaller()
        let preparer = AssistantPlaybackPreparer(installer: installer)
        let prepared = try await preparer.prepare(
            binding: makeBinding(
                searchResultId: "sr_yt",
                contentKey: "video:youtube:abc123",
                contentType: .video,
                jobID: "job-video"
            ),
            source: makeSource(
                searchResultId: "sr_yt",
                platform: .youtube,
                sourceType: .video,
                sourceId: "abc123",
                url: "https://www.youtube.com/watch?v=abc123",
                title: "Assistant Video"
            ),
            configuration: AppConfiguration(),
            context: context
        )
        guard case .youtube(let videoID) = prepared else {
            return XCTFail("expected youtube playback")
        }
        XCTAssertEqual(videoID, "abc123")
        XCTAssertEqual(existing.catalogOrigin, .subscription)
        XCTAssertTrue(existing.appearsInSubscriptionLibrary)
    }

    func testPodcastPlaybackUsesEnclosureNotAppleEpisodePage() async throws {
        let (_, context) = try makeContainer()
        let installer = RecordingInstaller()
        let preparer = AssistantPlaybackPreparer(installer: installer)
        let applePage =
            "https://podcasts.apple.com/us/podcast/andrew-ng-the-biggest-opportunities-in-ai-arent-where/id1819090545?i=1000786527866"
        let audio = "https://traffic.megaphone.fm/APO4554511240.mp3"
        let prepared = try await preparer.prepare(
            binding: makeBinding(
                searchResultId: "sr_ep",
                contentKey: "podcast:aaaaaaaaaaaaaaaa:bbbbbbbbbbbbbbbb",
                contentType: .podcastEpisode,
                jobID: "job-podcast"
            ),
            source: makeSource(
                searchResultId: "sr_ep",
                platform: .podcast,
                sourceType: .podcastEpisode,
                sourceId: "1000786527866",
                url: applePage,
                feedURL: "https://anchor.fm/s/105af30ec/podcast/rss",
                title: "Andrew Ng",
                enclosureUrl: audio
            ),
            configuration: AppConfiguration(),
            context: context
        )
        guard case .podcast(let episodeID) = prepared else {
            return XCTFail("expected podcast playback")
        }
        let episode = try XCTUnwrap(
            context.fetch(FetchDescriptor<EpisodeRecord>()).first { $0.id == episodeID }
        )
        XCTAssertEqual(episode.enclosureURL, audio)
        XCTAssertEqual(episode.episodeWebsiteURL, applePage)
        XCTAssertEqual(episode.assistantFeedURL, "https://anchor.fm/s/105af30ec/podcast/rss")
    }

    private func makeContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([EpisodeRecord.self, YTVideoRecord.self, TranslationVariantRecord.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return (container, container.mainContext)
    }

    private func makeBinding(
        searchResultId: String,
        contentKey: String,
        contentType: CloudContentType,
        jobID: String
    ) -> AssistantContentBinding {
        AssistantContentBinding(
            bindingId: "b1",
            sessionId: "s1",
            searchResultId: searchResultId,
            contentKey: contentKey,
            contentType: contentType,
            targetLanguage: "zh-Hans",
            translationQuality: .quality,
            v10JobId: jobID,
            status: "ready",
            stage: "completed",
            progress: 1,
            indexStatus: "pending",
            error: nil,
            reused: true,
            updatedAt: nil
        )
    }

    private func makeSource(
        searchResultId: String,
        platform: AssistantPlatform,
        sourceType: AssistantSourceType,
        sourceId: String,
        url: String,
        feedURL: String? = nil,
        title: String,
        enclosureUrl: String? = nil
    ) -> AssistantSearchResult {
        AssistantSearchResult(
            searchResultId: searchResultId,
            platform: platform,
            sourceType: sourceType,
            sourceId: sourceId,
            canonicalURL: url,
            feedURL: feedURL,
            title: title,
            publisher: "Publisher",
            publishedAt: nil,
            durationSeconds: 60,
            description: nil,
            thumbnailURL: nil,
            availability: nil,
            provider: nil,
            fallback: nil,
            deepResearchAvailability: "available",
            warnings: nil,
            searchRunId: nil,
            rank: nil,
            relevanceScore: nil,
            matchReason: nil,
            retrievedAt: nil,
            qualified: nil,
            itunesId: nil,
            guid: sourceId,
            language: nil,
            podcastIndexFeedId: nil,
            podcastIndexEpisodeId: nil,
            enclosureUrl: enclosureUrl
        )
    }
}

private final class RecordingInstaller: AssistantCloudArtifactInstalling {
    var podcastJobIDs: [String] = []
    var videoJobIDs: [String] = []

    func installPodcastArtifacts(
        episode: EpisodeRecord,
        jobID: String,
        target: TranslationTarget,
        configuration: AppConfiguration,
        context: ModelContext
    ) async throws {
        episode.status = "completed"
        podcastJobIDs.append(jobID)
        try context.save()
    }

    func installVideoArtifacts(
        video: YTVideoRecord,
        jobID: String,
        target: TranslationTarget,
        configuration: AppConfiguration,
        context: ModelContext
    ) async throws {
        video.subtitleStatus = "ready"
        videoJobIDs.append(jobID)
        try context.save()
    }
}

#else

final class AssistantPlaybackPreparerTests: XCTestCase {
    func testRequiresAppModules() throws {
        throw XCTSkip(
            "Assistant playback preparer tests need the app-hosted test bundle."
        )
    }
}

#endif
