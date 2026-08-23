import Foundation
import XCTest
@testable import PodcastEnglishStudioCore

final class PodcastFeedParserTests: XCTestCase {
    func testSanitizerDecodesEntitiesBeforeRemovingEncodedMarkup() {
        let value = """
        &lt;p&gt;Visible &amp; safe.&lt;/p&gt;
        &lt;script&gt;hidden()&lt;/script&gt;
        """

        XCTAssertEqual(
            PodcastMetadataTextPolicy.plainText(value),
            "Visible & safe."
        )
    }

    func testParsesAtomAuthorAndProgramSummary() throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Atom Metadata</title>
          <author><name>Atom Host</name></author>
          <summary type="html">&lt;p&gt;Program summary.&lt;/p&gt;</summary>
          <link rel="alternate" href="https://example.com/atom" />
          <entry>
            <title>Episode</title>
            <id>atom-episode</id>
            <link rel="enclosure" href="https://example.com/atom.mp3" type="audio/mpeg" />
          </entry>
        </feed>
        """

        let show = try PodcastFeedParser().parse(data: Data(xml.utf8)).show

        XCTAssertEqual(show.author, "Atom Host")
        XCTAssertEqual(show.summary, "Program summary.")
        XCTAssertEqual(show.websiteURL?.absoluteString, "https://example.com/atom")
    }

    func testParsesProgramAndEpisodeMetadataAndSanitizesHTML() throws {
        let xml = """
        <rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
          <channel>
            <title>Metadata Show</title>
            <itunes:author>Example Host</itunes:author>
            <itunes:image href="https://example.com/show.jpg" />
            <description><![CDATA[
              <p>A <strong>bilingual</strong> show &amp; archive.</p>
              <script>alert("ignored")</script>
              <p>Second paragraph.</p>
            ]]></description>
            <link>https://example.com/show</link>
            <item>
              <title>Episode One</title>
              <guid>episode-one</guid>
              <pubDate>Fri, 13 Mar 2026 10:00:00 +0000</pubDate>
              <itunes:image href="https://example.com/episode.jpg" />
              <itunes:summary><![CDATA[<p>Episode <em>summary</em>.</p>]]></itunes:summary>
              <itunes:duration>01:02:03</itunes:duration>
              <itunes:season>2</itunes:season>
              <itunes:episode>7</itunes:episode>
              <link>https://example.com/episodes/one</link>
              <enclosure url="https://example.com/one.mp3" type="audio/mpeg" />
            </item>
          </channel>
        </rss>
        """

        let feed = try PodcastFeedParser().parse(
            data: Data(xml.utf8),
            feedURL: URL(string: "https://example.com/feed.xml")
        )
        let episode = try XCTUnwrap(feed.episodes.first)

        XCTAssertEqual(feed.show.artworkURL?.absoluteString, "https://example.com/show.jpg")
        XCTAssertEqual(feed.show.artworkSource, .rss)
        XCTAssertEqual(
            feed.show.summary,
            "A bilingual show & archive.\n\nSecond paragraph."
        )
        XCTAssertEqual(feed.show.websiteURL?.absoluteString, "https://example.com/show")
        XCTAssertEqual(episode.artworkURL?.absoluteString, "https://example.com/episode.jpg")
        XCTAssertEqual(episode.summary, "Episode summary.")
        XCTAssertEqual(episode.durationSeconds, 3_723)
        XCTAssertEqual(episode.seasonNumber, 2)
        XCTAssertEqual(episode.episodeNumber, 7)
        XCTAssertEqual(episode.link?.absoluteString, "https://example.com/episodes/one")
    }

    func testEpisodeMetadataDoesNotLeakAndSupportsSecondsDuration() throws {
        let xml = """
        <rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
          <channel>
            <title>Metadata Isolation</title>
            <item>
              <title>First</title>
              <guid>first</guid>
              <itunes:image href="https://example.com/first.jpg" />
              <description>First summary</description>
              <itunes:duration>95</itunes:duration>
              <itunes:season>3</itunes:season>
              <itunes:episode>9</itunes:episode>
              <enclosure url="https://example.com/first.mp3" type="audio/mpeg" />
            </item>
            <item>
              <title>Second</title>
              <guid>second</guid>
              <enclosure url="https://example.com/second.mp3" type="audio/mpeg" />
            </item>
          </channel>
        </rss>
        """

        let episodes = try PodcastFeedParser().parse(data: Data(xml.utf8)).episodes

        XCTAssertEqual(episodes.first?.durationSeconds, 95)
        XCTAssertNil(episodes.last?.artworkURL)
        XCTAssertNil(episodes.last?.summary)
        XCTAssertNil(episodes.last?.durationSeconds)
        XCTAssertNil(episodes.last?.seasonNumber)
        XCTAssertNil(episodes.last?.episodeNumber)
    }

    func testProgramMetadataMergeKeepsRSSAndOnlyFillsMissingValuesFromApple() {
        let rss = PodcastShowInfo(
            title: "RSS Title",
            author: "",
            feedURL: URL(string: "https://example.com/feed.xml"),
            artworkURL: URL(string: "https://example.com/rss.jpg"),
            summary: "RSS summary",
            websiteURL: URL(string: "https://example.com")
        )
        let apple = PodcastShowInfo(
            title: "Apple Title",
            author: "Apple Author",
            artworkURL: URL(string: "https://example.com/apple.jpg"),
            applePodcastsURL: URL(string: "https://podcasts.apple.com/podcast/id123"),
            artworkSource: .apple
        )

        let merged = PodcastShowMetadataPolicy.merging(rss: rss, apple: apple)

        XCTAssertEqual(merged.title, "RSS Title")
        XCTAssertEqual(merged.author, "Apple Author")
        XCTAssertEqual(merged.artworkURL?.absoluteString, "https://example.com/rss.jpg")
        XCTAssertEqual(merged.artworkSource, .rss)
        XCTAssertEqual(merged.summary, "RSS summary")
        XCTAssertEqual(merged.applePodcastsURL?.absoluteString, "https://podcasts.apple.com/podcast/id123")
    }

    func testCatalogSelectionDefaultsToLatestFiftyAndAllKeepsArchive() {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let episodes = (0..<51).map { index in
            PodcastEpisodeInfo(
                title: "Episode \(index)",
                guid: "guid-\(index)",
                publishedAt: baseDate.addingTimeInterval(Double(index)),
                enclosureURL: URL(string: "https://example.com/\(index).mp3")!
            )
        }

        let recent = PodcastCatalogSelectionPolicy.select(
            episodes,
            mode: .recent(limit: 50)
        )
        let all = PodcastCatalogSelectionPolicy.select(episodes, mode: .all)

        XCTAssertEqual(recent.count, 50)
        XCTAssertEqual(recent.first?.guid, "guid-50")
        XCTAssertFalse(recent.contains { $0.guid == "guid-0" })
        XCTAssertEqual(all.count, 51)
        XCTAssertEqual(all.first?.guid, "guid-50")
        XCTAssertEqual(all.last?.guid, "guid-0")
    }

    func testCatalogSelectionDeduplicatesBeforeApplyingRecentLimit() {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        var episodes = (0..<51).map { index in
            PodcastEpisodeInfo(
                title: "Episode \(index)",
                guid: "guid-\(index)",
                publishedAt: baseDate.addingTimeInterval(Double(index)),
                enclosureURL: URL(string: "https://example.com/\(index).mp3")!
            )
        }
        episodes.append(
            PodcastEpisodeInfo(
                title: "Duplicate newest item",
                guid: "guid-50",
                publishedAt: baseDate.addingTimeInterval(10_000),
                enclosureURL: URL(string: "https://example.com/duplicate.mp3")!
            )
        )

        let recent = PodcastCatalogSelectionPolicy.select(
            episodes,
            mode: .recent(limit: 50)
        )

        XCTAssertEqual(recent.count, 50)
        XCTAssertEqual(Set(recent.map(\.guid)).count, 50)
        XCTAssertEqual(recent.first?.title, "Duplicate newest item")
        XCTAssertTrue(recent.contains { $0.guid == "guid-1" })
        XCTAssertFalse(recent.contains { $0.guid == "guid-0" })
    }

    func testCatalogSelectionPreservesFeedOrderForUndatedEpisodes() {
        let episodes = (0..<3).map { index in
            PodcastEpisodeInfo(
                title: "Episode \(index)",
                guid: "guid-\(index)",
                enclosureURL: URL(string: "https://example.com/\(index).mp3")!
            )
        }

        XCTAssertEqual(
            PodcastCatalogSelectionPolicy.select(episodes, mode: .all).map(\.guid),
            ["guid-0", "guid-1", "guid-2"]
        )
    }

    func testProgramSummaryIsTruncatedToCloudSyncLimit() throws {
        let longSummary = String(repeating: "a", count: 20_050)
        let xml = """
        <rss><channel>
          <title>Long Summary</title>
          <description>\(longSummary)</description>
          <item>
            <title>Episode</title>
            <guid>episode</guid>
            <enclosure url="https://example.com/episode.mp3" type="audio/mpeg" />
          </item>
        </channel></rss>
        """

        let summary = try PodcastFeedParser().parse(data: Data(xml.utf8)).show.summary

        XCTAssertEqual(summary?.count, PodcastMetadataTextPolicy.maximumSyncedSummaryLength)
    }

    func testRejectsApplePodcastsChannelURLAsUnsupportedSubscription() throws {
        let url = URL(string: "https://podcasts.apple.com/us/channel/the-wall-street-journal/id6442484762")!

        XCTAssertTrue(PodcastSubscriptionURLInspector.isUnsupportedAppleChannel(url))
        XCTAssertEqual(PodcastSubscriptionURLInspector.applePodcastID(from: url), "6442484762")
    }

    func testAcceptsApplePodcastsShowURLAsSinglePodcastSubscription() throws {
        let url = URL(string: "https://podcasts.apple.com/us/podcast/the-journal/id1469394914")!

        XCTAssertFalse(PodcastSubscriptionURLInspector.isUnsupportedAppleChannel(url))
        XCTAssertEqual(PodcastSubscriptionURLInspector.applePodcastID(from: url), "1469394914")
    }

    func testParsesLatestEpisodeWithEnclosure() throws {
        let xml = """
        <rss><channel>
          <title>Example Show</title>
          <itunes:author>Example Host</itunes:author>
          <item>
            <title>Episode One</title>
            <guid>episode-one</guid>
            <pubDate>Fri, 13 Mar 2026 10:00:00 +0000</pubDate>
            <enclosure url="https://example.com/one.mp3" type="audio/mpeg" />
          </item>
        </channel></rss>
        """

        let feed = try PodcastFeedParser().parse(data: Data(xml.utf8), feedURL: URL(string: "https://example.com/feed.xml"))

        XCTAssertEqual(feed.show.title, "Example Show")
        XCTAssertEqual(feed.show.author, "Example Host")
        XCTAssertEqual(feed.episodes.first?.title, "Episode One")
        XCTAssertEqual(feed.episodes.first?.enclosureURL.absoluteString, "https://example.com/one.mp3")
    }

    func testParsesEveryPlayableEpisodeAndSkipsItemsWithoutAudio() throws {
        let xml = """
        <rss><channel>
          <title>Archive Show</title>
          <item>
            <title>Older Episode</title>
            <guid>older</guid>
            <pubDate>Thu, 12 Mar 2026 10:00:00 +0000</pubDate>
            <enclosure url="https://example.com/older.mp3" type="audio/mpeg" />
          </item>
          <item>
            <title>Article Without Audio</title>
            <guid>article</guid>
          </item>
          <item>
            <title>Newest Episode</title>
            <guid>newest</guid>
            <pubDate>Fri, 13 Mar 2026 10:00:00 +0000</pubDate>
            <enclosure url="https://example.com/newest.mp3" type="audio/mpeg" />
          </item>
        </channel></rss>
        """

        let feed = try PodcastFeedParser().parse(data: Data(xml.utf8))
        let sorted = PodcastFeedOrderingPolicy.newestFirst(feed.episodes)

        XCTAssertEqual(sorted.map(\.guid), ["newest", "older"])
        XCTAssertEqual(sorted.map(\.enclosureURL.absoluteString), [
            "https://example.com/newest.mp3",
            "https://example.com/older.mp3"
        ])
    }

    func testParsesEveryPlayableAtomEnclosureAndSkipsNonAudioLinks() throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Atom Archive</title>
          <entry>
            <title>Older Episode</title>
            <id>older</id>
            <published>2026-03-12T10:00:00Z</published>
            <link rel="alternate" href="https://example.com/episodes/older" />
            <link rel="enclosure" href="https://example.com/older.mp3" type="audio/mpeg" />
          </entry>
          <entry>
            <title>Newest Episode</title>
            <id>newest</id>
            <published>2026-03-13T10:00:00Z</published>
            <link rel="enclosure" href="https://example.com/newest.m4a" type="audio/mp4" />
          </entry>
          <entry>
            <title>Notes Only</title>
            <id>notes</id>
            <link rel="enclosure" href="https://example.com/notes.pdf" type="application/pdf" />
          </entry>
        </feed>
        """

        let feed = try PodcastFeedParser().parse(data: Data(xml.utf8))
        let sorted = PodcastFeedOrderingPolicy.newestFirst(feed.episodes)

        XCTAssertEqual(sorted.map(\.guid), ["newest", "older"])
        XCTAssertEqual(sorted.map(\.enclosureURL.absoluteString), [
            "https://example.com/newest.m4a",
            "https://example.com/older.mp3"
        ])
    }

    func testParserSelectsAudioEnclosureAndRejectsNonAudioEnclosures() throws {
        let xml = """
        <rss><channel>
          <title>Mixed Media Show</title>
          <item>
            <title>Mixed Episode</title>
            <guid>mixed</guid>
            <enclosure url="https://example.com/cover.jpg" type="image/jpeg" />
            <enclosure url="https://example.com/audio.mp3" type="audio/mpeg" />
            <enclosure url="https://example.com/trailer.mp4" type="video/mp4" />
          </item>
          <item>
            <title>PDF Only</title>
            <guid>pdf</guid>
            <enclosure url="https://example.com/notes.pdf" type="application/pdf" />
          </item>
          <item>
            <title>Missing MIME</title>
            <guid>fallback-extension</guid>
            <enclosure url="https://example.com/fallback.m4a?token=123" />
          </item>
        </channel></rss>
        """

        let feed = try PodcastFeedParser().parse(data: Data(xml.utf8))

        XCTAssertEqual(feed.episodes.map(\.guid), ["mixed", "fallback-extension"])
        XCTAssertEqual(feed.episodes.map(\.enclosureURL.absoluteString), [
            "https://example.com/audio.mp3",
            "https://example.com/fallback.m4a?token=123"
        ])
    }

    func testEpisodeWithoutGUIDUsesAudioURLAsStableIdentity() throws {
        let xml = """
        <rss><channel>
          <title>Fallback Identity Show</title>
          <item>
            <title>Episode</title>
            <enclosure url="https://example.com/fallback.mp3" type="audio/mpeg" />
          </item>
        </channel></rss>
        """

        let episode = try XCTUnwrap(PodcastFeedParser().parse(data: Data(xml.utf8)).episodes.first)

        XCTAssertEqual(episode.guid, "https://example.com/fallback.mp3")
        XCTAssertEqual(episode.id, "https://example.com/fallback.mp3")
    }

    func testRefreshPlanInsertsNewUpdatesExistingAndNeverDeletesMissingEpisodes() throws {
        let existing = Set(["existing", "local-only"])
        let incoming = [
            PodcastEpisodeInfo(
                title: "Updated existing",
                guid: "existing",
                enclosureURL: URL(string: "https://example.com/existing.mp3")!
            ),
            PodcastEpisodeInfo(
                title: "Brand new",
                guid: "new",
                enclosureURL: URL(string: "https://example.com/new.mp3")!
            ),
            PodcastEpisodeInfo(
                title: "Duplicate new item",
                guid: "new",
                enclosureURL: URL(string: "https://example.com/new-copy.mp3")!
            )
        ]

        let plan = PodcastEpisodeRefreshPolicy.plan(existingGUIDs: existing, incoming: incoming)

        XCTAssertEqual(plan.insertions.map(\.guid), ["new"])
        XCTAssertEqual(plan.updates.map(\.guid), ["existing"])
    }

    func testRefreshPlanIsIdempotentAfterFirstInsert() throws {
        let incoming = [
            PodcastEpisodeInfo(
                title: "Episode",
                guid: "episode",
                enclosureURL: URL(string: "https://example.com/episode.mp3")!
            )
        ]

        let first = PodcastEpisodeRefreshPolicy.plan(existingGUIDs: [], incoming: incoming)
        let second = PodcastEpisodeRefreshPolicy.plan(existingGUIDs: ["episode"], incoming: incoming)

        XCTAssertEqual(first.insertions.map(\.guid), ["episode"])
        XCTAssertTrue(second.insertions.isEmpty)
        XCTAssertEqual(second.updates.map(\.guid), ["episode"])
    }

    func testRefreshedDisplayNameAdoptsFeedTitleOnlyForURLPlaceholder() {
        XCTAssertEqual(
            PodcastDisplayNamePolicy.refreshedName(
                current: "https://example.com/feed.xml",
                sourceURL: "https://example.com/feed.xml",
                feedTitle: "Official Show"
            ),
            "Official Show"
        )
        XCTAssertEqual(
            PodcastDisplayNamePolicy.refreshedName(
                current: "My commute show",
                sourceURL: "https://example.com/feed.xml",
                feedTitle: "Official Show"
            ),
            "My commute show"
        )
    }
}
