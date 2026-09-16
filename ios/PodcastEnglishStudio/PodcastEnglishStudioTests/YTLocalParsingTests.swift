import Foundation
import XCTest
@testable import PodcastEnglishStudioCore

final class YTChannelResolverTests: XCTestCase {
    func testResolvesDirectChannelURL() {
        XCTAssertEqual(
            YTChannelResolver.channelID(from: "https://www.youtube.com/channel/UCYO_jab_esuFRV4b17AJtAw"),
            "UCYO_jab_esuFRV4b17AJtAw"
        )
        XCTAssertTrue(YTChannelResolver.isValidChannelID("UCYO_jab_esuFRV4b17AJtAw"))
        XCTAssertFalse(YTChannelResolver.isValidChannelID("lexfridman"))
    }

    func testResolvesRSSChannelID() {
        XCTAssertEqual(
            YTChannelResolver.channelID(from: "https://www.youtube.com/feeds/videos.xml?channel_id=UCYO_jab_esuFRV4b17AJtAw"),
            "UCYO_jab_esuFRV4b17AJtAw"
        )
    }

    func testResolvesChannelIDFromHandleHTML() {
        let html = """
        <html><head>
          <meta property="og:title" content="3Blue1Brown">
          <meta itemprop="channelId" content="UCYO_jab_esuFRV4b17AJtAw">
        </head></html>
        """

        XCTAssertEqual(YTChannelResolver.channelID(fromHTML: html), "UCYO_jab_esuFRV4b17AJtAw")
        XCTAssertEqual(YTChannelResolver.displayName(fromHTML: html), "3Blue1Brown")
    }

    func testResolvesChannelIDFromBrowseEndpointHTML() {
        let html = """
        <script>
        window['ytCommand'] = {"browseEndpoint":{"browseId":"UCSHZKyawb77ixDdsGog4iWA","params":"EgC4AQCSAwDyBgQKAjIA"}};
        </script>
        """

        XCTAssertEqual(YTChannelResolver.channelID(fromHTML: html), "UCSHZKyawb77ixDdsGog4iWA")
    }
}

final class YTFeedParserTests: XCTestCase {
    func testParsesYouTubeRSSFeedEntries() throws {
        let xml = """
        <feed xmlns:yt="http://www.youtube.com/xml/schemas/2015"
              xmlns:media="http://search.yahoo.com/mrss/">
          <title>Example Channel</title>
          <entry>
            <id>yt:video:abc123</id>
            <yt:videoId>abc123</yt:videoId>
            <yt:channelId>UCYO_jab_esuFRV4b17AJtAw</yt:channelId>
            <title>Linear algebra</title>
            <link rel="alternate" href="https://www.youtube.com/watch?v=abc123"/>
            <published>2026-05-01T12:00:00+00:00</published>
            <updated>2026-05-02T12:00:00+00:00</updated>
            <media:group>
              <media:thumbnail url="https://i.ytimg.com/vi/abc123/hqdefault.jpg"/>
            </media:group>
          </entry>
        </feed>
        """

        let feed = try YTFeedParser().parse(data: Data(xml.utf8))

        XCTAssertEqual(feed.channelTitle, "Example Channel")
        XCTAssertEqual(feed.videos.count, 1)
        XCTAssertEqual(feed.videos[0].id, "abc123")
        XCTAssertEqual(feed.videos[0].title, "Linear algebra")
        XCTAssertEqual(feed.videos[0].channelID, "UCYO_jab_esuFRV4b17AJtAw")
        XCTAssertEqual(feed.videos[0].thumbnail, "https://i.ytimg.com/vi/abc123/hqdefault.jpg")
    }
}

final class YTChannelVideosPageParserTests: XCTestCase {
    func testParsesLockupViewModelVideos() {
        let html = """
        <script>
        var ytInitialData = {
          "contents": {
            "richItemRenderer": {
              "content": {
                "lockupViewModel": {
                  "contentId": "nepKKz-MzFM",
                  "contentType": "LOCKUP_CONTENT_TYPE_VIDEO",
                  "contentImage": {
                    "thumbnailViewModel": {
                      "image": {
                        "sources": [{"url":"https://i.ytimg.com/vi/nepKKz-MzFM/hqdefault.jpg"}]
                      }
                    }
                  },
                  "metadata": {
                    "lockupMetadataViewModel": {
                      "title": {"content":"FFmpeg: The Incredible Technology Behind Video on the Internet"}
                    }
                  }
                }
              }
            }
          }
        };
        </script>
        """

        let feed = YTChannelVideosPageParser.parse(html: html, channelID: "UCSHZKyawb77ixDdsGog4iWA", channelTitle: "Lex Fridman")

        XCTAssertEqual(feed.channelTitle, "Lex Fridman")
        XCTAssertEqual(feed.videos.count, 1)
        XCTAssertEqual(feed.videos[0].id, "nepKKz-MzFM")
        XCTAssertEqual(feed.videos[0].title, "FFmpeg: The Incredible Technology Behind Video on the Internet")
        XCTAssertEqual(feed.videos[0].thumbnail, "https://i.ytimg.com/vi/nepKKz-MzFM/hqdefault.jpg")
    }

    func testParsesInitialPageVideosTitleAndContinuationToken() {
        let items = (1...20).map { index in
            Self.lockupJSON(
                id: "video\(index)",
                title: "Video \(index)"
            )
        }
        .joined(separator: ",")
        let html = """
        <html>
          <head><meta property="og:title" content="Lex Fridman"></head>
          <body>
            <script>
            var ytInitialData = {
              "contents": {
                "richGridRenderer": {
                  "contents": [
                    \(items),
                    {
                      "continuationItemRenderer": {
                        "continuationEndpoint": {
                          "continuationCommand": { "token": "FIRST_PAGE_TOKEN" }
                        }
                      }
                    }
                  ]
                }
              }
            };
            </script>
          </body>
        </html>
        """

        let page = YTChannelVideosPageParser.parseInitialPage(
            html: html,
            channelID: "UCSHZKyawb77ixDdsGog4iWA"
        )

        XCTAssertEqual(page.feed.channelTitle, "Lex Fridman")
        XCTAssertEqual(page.feed.videos.count, 20)
        XCTAssertEqual(page.feed.videos.first?.id, "video1")
        XCTAssertEqual(page.feed.videos.last?.id, "video20")
        XCTAssertEqual(page.continuationToken, "FIRST_PAGE_TOKEN")
        XCTAssertTrue(page.hasMoreVideos)
    }

    func testParsesContinuationVideosAndNextToken() {
        let json = """
        {
          "onResponseReceivedActions": [
            {
              "appendContinuationItemsAction": {
                "continuationItems": [
                  \(Self.lockupJSON(id: "next1", title: "Next 1")),
                  \(Self.lockupJSON(id: "next2", title: "Next 2")),
                  {
                    "continuationItemRenderer": {
                      "continuationEndpoint": {
                        "continuationCommand": { "token": "SECOND_PAGE_TOKEN" }
                      }
                    }
                  }
                ]
              }
            }
          ]
        }
        """

        let page = YTChannelVideosPageParser.parseContinuation(
            json: json,
            channelID: "UCSHZKyawb77ixDdsGog4iWA",
            channelTitle: "Lex Fridman"
        )

        XCTAssertEqual(page.feed.channelTitle, "Lex Fridman")
        XCTAssertEqual(page.feed.videos.map(\.id), ["next1", "next2"])
        XCTAssertEqual(page.continuationToken, "SECOND_PAGE_TOKEN")
        XCTAssertTrue(page.hasMoreVideos)
    }

    func testContinuationWithoutTokenMarksNoMoreVideos() {
        let json = """
        {
          "onResponseReceivedActions": [
            {
              "appendContinuationItemsAction": {
                "continuationItems": [
                  \(Self.lockupJSON(id: "final1", title: "Final 1")),
                  \(Self.lockupJSON(id: "final2", title: "Final 2"))
                ]
              }
            }
          ]
        }
        """

        let page = YTChannelVideosPageParser.parseContinuation(
            json: json,
            channelID: "UCSHZKyawb77ixDdsGog4iWA",
            channelTitle: "Lex Fridman"
        )

        XCTAssertEqual(page.feed.videos.map(\.id), ["final1", "final2"])
        XCTAssertNil(page.continuationToken)
        XCTAssertFalse(page.hasMoreVideos)
    }

    func testPaginationPolicyKeepsContinuationForShortPages() {
        let page = YTChannelVideosPage(
            feed: YTFeed(videos: [
                YTFeedVideo(id: "short1", title: "Short page item", url: "https://www.youtube.com/watch?v=short1")
            ]),
            continuationToken: "NEXT_PAGE_TOKEN"
        )

        XCTAssertTrue(YTChannelPaginationPolicy.hasMoreVideos(after: page))
    }

    private static func lockupJSON(id: String, title: String) -> String {
        """
        {
          "richItemRenderer": {
            "content": {
              "lockupViewModel": {
                "contentId": "\(id)",
                "contentType": "LOCKUP_CONTENT_TYPE_VIDEO",
                "contentImage": {
                  "thumbnailViewModel": {
                    "image": {
                      "sources": [{"url":"https://i.ytimg.com/vi/\(id)/hqdefault.jpg"}]
                    }
                  }
                },
                "metadata": {
                  "lockupMetadataViewModel": {
                    "title": {"content":"\(title)"}
                  }
                }
              }
            }
          }
        }
        """
    }
}

final class YTFeedMergePolicyTests: XCTestCase {
    func testRSSLatestMetadataComesBeforeHTMLVideosWithoutDates() {
        let latestDate = Date(timeIntervalSince1970: 1_780_000_000)
        let olderDate = Date(timeIntervalSince1970: 1_770_000_000)
        let htmlFeed = YTFeed(channelTitle: "Training Think Tank", videos: [
            YTFeedVideo(
                id: "latest",
                channelID: "channel",
                title: "Latest from HTML",
                url: "https://www.youtube.com/watch?v=latest",
                thumbnail: "https://img.example/latest-html.jpg"
            ),
            YTFeedVideo(
                id: "html-only",
                channelID: "channel",
                title: "Only on HTML page",
                url: "https://www.youtube.com/watch?v=html-only",
                thumbnail: "https://img.example/html-only.jpg"
            )
        ])
        let rssFeed = YTFeed(channelTitle: "Training Think Tank", videos: [
            YTFeedVideo(
                id: "latest",
                channelID: "channel",
                title: "Latest from RSS",
                publishedAt: latestDate,
                updatedAt: latestDate,
                url: "https://www.youtube.com/watch?v=latest",
                thumbnail: "https://img.example/latest-rss.jpg"
            ),
            YTFeedVideo(
                id: "older",
                channelID: "channel",
                title: "Older RSS item",
                publishedAt: olderDate,
                updatedAt: olderDate,
                url: "https://www.youtube.com/watch?v=older",
                thumbnail: "https://img.example/older.jpg"
            )
        ])

        let merged = YTFeedMergePolicy.mergeLatestMetadata(primary: htmlFeed, latestMetadata: rssFeed)

        XCTAssertEqual(merged.videos.map(\.id), ["latest", "older", "html-only"])
        XCTAssertEqual(merged.videos[0].title, "Latest from HTML")
        XCTAssertEqual(merged.videos[0].publishedAt, latestDate)
        XCTAssertEqual(merged.videos[0].thumbnail, "https://img.example/latest-html.jpg")
        XCTAssertEqual(merged.videos[2].publishedAt, nil)
    }
}

final class YouTubeDataAPIParserTests: XCTestCase {
    func testAppliesIOSBundleIdentifierRestrictionHeader() {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/youtube/v3/channels")!)

        YouTubeDataAPIRequestPolicy.applyIOSRestrictionHeaders(
            to: &request,
            bundleIdentifier: "com.local.PodcastEnglishStudio"
        )

        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Ios-Bundle-Identifier"), "com.local.PodcastEnglishStudio")
    }

    func testParsesChannelResponseForHandle() throws {
        let json = """
        {
          "items": [
            {
              "id": "UCYO_jab_esuFRV4b17AJtAw",
              "snippet": {
                "title": "3Blue1Brown",
                "customUrl": "@3blue1brown",
                "thumbnails": {
                  "default": {"url": "https://example.com/default.jpg"},
                  "high": {"url": "https://example.com/high.jpg"}
                }
              },
              "contentDetails": {
                "relatedPlaylists": {
                  "uploads": "UUYO_jab_esuFRV4b17AJtAw"
                }
              },
              "statistics": {
                "videoCount": "172"
              }
            }
          ]
        }
        """

        let channel = try YouTubeDataAPIParser.parseChannelList(data: Data(json.utf8))

        XCTAssertEqual(channel?.id, "UCYO_jab_esuFRV4b17AJtAw")
        XCTAssertEqual(channel?.title, "3Blue1Brown")
        XCTAssertEqual(channel?.uploadsPlaylistID, "UUYO_jab_esuFRV4b17AJtAw")
        XCTAssertEqual(channel?.videoCount, 172)
        XCTAssertEqual(channel?.thumbnail, "https://example.com/high.jpg")
    }

    func testParsesPlaylistItemsPageAndPreservesNextPageToken() throws {
        let json = """
        {
          "nextPageToken": "NEXT_PAGE",
          "items": [
            {
              "snippet": {
                "title": "Linear algebra",
                "channelId": "UCYO_jab_esuFRV4b17AJtAw",
                "publishedAt": "2026-05-01T12:00:00Z",
                "resourceId": {
                  "kind": "youtube#video",
                  "videoId": "abc123"
                },
                "thumbnails": {
                  "medium": {"url": "https://i.ytimg.com/vi/abc123/mqdefault.jpg"}
                }
              },
              "contentDetails": {
                "videoId": "abc123",
                "videoPublishedAt": "2026-05-01T12:00:00Z"
              },
              "status": {
                "privacyStatus": "public"
              }
            },
            {
              "snippet": {
                "title": "Private video",
                "resourceId": {
                  "kind": "youtube#video",
                  "videoId": "private1"
                }
              },
              "status": {
                "privacyStatus": "private"
              }
            }
          ]
        }
        """

        let page = try YouTubeDataAPIParser.parsePlaylistItemsPage(data: Data(json.utf8), fallbackChannelID: "fallback")

        XCTAssertEqual(page.feed.videos.count, 1)
        XCTAssertEqual(page.feed.videos[0].id, "abc123")
        XCTAssertEqual(page.feed.videos[0].channelID, "UCYO_jab_esuFRV4b17AJtAw")
        XCTAssertEqual(page.feed.videos[0].title, "Linear algebra")
        XCTAssertEqual(page.feed.videos[0].thumbnail, "https://i.ytimg.com/vi/abc123/mqdefault.jpg")
        XCTAssertEqual(page.continuationToken, "NEXT_PAGE")
    }

    func testMergesVideoDetailsWithoutLosingPlaylistOrder() throws {
        let firstDate = Date(timeIntervalSince1970: 1_778_000_000)
        let secondDate = Date(timeIntervalSince1970: 1_777_000_000)
        let page = YTChannelVideosPage(
            feed: YTFeed(channelTitle: "Example", videos: [
                YTFeedVideo(id: "first", channelID: "channel", title: "First playlist title", publishedAt: firstDate, url: "https://www.youtube.com/watch?v=first"),
                YTFeedVideo(id: "second", channelID: "channel", title: "Second playlist title", publishedAt: secondDate, url: "https://www.youtube.com/watch?v=second")
            ]),
            continuationToken: "NEXT"
        )
        let json = """
        {
          "items": [
            {
              "id": "second",
              "snippet": {
                "title": "Second canonical title",
                "channelId": "channel",
                "publishedAt": "2026-04-01T12:00:00Z",
                "thumbnails": {
                  "high": {"url": "https://example.com/second.jpg"}
                }
              }
            },
            {
              "id": "first",
              "snippet": {
                "title": "First canonical title",
                "channelId": "channel",
                "publishedAt": "2026-05-01T12:00:00Z",
                "thumbnails": {
                  "high": {"url": "https://example.com/first.jpg"}
                }
              }
            }
          ]
        }
        """

        let merged = try YouTubeDataAPIParser.mergingVideoDetails(page: page, data: Data(json.utf8))

        XCTAssertEqual(merged.feed.videos.map(\.id), ["first", "second"])
        XCTAssertEqual(merged.feed.videos[0].title, "First canonical title")
        XCTAssertEqual(merged.feed.videos[0].thumbnail, "https://example.com/first.jpg")
        XCTAssertEqual(merged.continuationToken, "NEXT")
    }

    func testMapsAPIErrorToReadableMessage() throws {
        let json = """
        {
          "error": {
            "code": 403,
            "message": "The request cannot be completed because you have exceeded your quota.",
            "errors": [
              {
                "reason": "quotaExceeded"
              }
            ]
          }
        }
        """

        let error = try XCTUnwrap(YouTubeDataAPIParser.apiError(from: Data(json.utf8)))

        XCTAssertEqual(error.code, 403)
        XCTAssertEqual(error.reason, "quotaExceeded")
        XCTAssertTrue(error.localizedDescription.contains("配额"))
    }
}

final class YTStreamFormatSelectorTests: XCTestCase {
    func testHighestQualityPolicyChoosesLargestPlayableMP4() {
        let formats: [[String: Any]] = [
            [
                "itag": 18,
                "mimeType": "video/mp4; codecs=\"avc1.42001E, mp4a.40.2\"",
                "qualityLabel": "360p",
                "height": 360,
                "bitrate": 420_000,
                "url": "https://example.com/360.mp4"
            ],
            [
                "itag": 22,
                "mimeType": "video/mp4; codecs=\"avc1.64001F, mp4a.40.2\"",
                "qualityLabel": "720p",
                "height": 720,
                "bitrate": 1_500_000,
                "url": "https://example.com/720.mp4"
            ],
            [
                "itag": 137,
                "mimeType": "video/mp4; codecs=\"avc1.640028\"",
                "qualityLabel": "1080p",
                "height": 1080,
                "bitrate": 4_200_000,
                "url": "https://example.com/1080-video-only.mp4"
            ]
        ]

        XCTAssertEqual(
            YTStreamFormatSelector.selectURL(from: formats, policy: .highestQuality)?.absoluteString,
            "https://example.com/720.mp4"
        )
        XCTAssertEqual(
            YTStreamFormatSelector.selectURL(from: formats, policy: .legacyCompatible)?.absoluteString,
            "https://example.com/360.mp4"
        )
    }

    private var qualityFormats: [[String: Any]] {
        [
            [
                "itag": 18,
                "mimeType": "video/mp4; codecs=\"avc1.42001E, mp4a.40.2\"",
                "qualityLabel": "360p",
                "height": 360,
                "bitrate": 420_000,
                "url": "https://example.com/360.mp4"
            ],
            [
                "itag": 22,
                "mimeType": "video/mp4; codecs=\"avc1.64001F, mp4a.40.2\"",
                "qualityLabel": "720p",
                "height": 720,
                "bitrate": 1_500_000,
                "url": "https://example.com/720.mp4"
            ],
            [
                "itag": 135,
                "mimeType": "video/mp4; codecs=\"avc1.4d401F, mp4a.40.2\"",
                "qualityLabel": "480p",
                "height": 480,
                "bitrate": 900_000,
                "url": "https://example.com/480.mp4"
            ],
            [
                "itag": 137,
                "mimeType": "video/mp4; codecs=\"avc1.640028\"",
                "qualityLabel": "1080p",
                "height": 1080,
                "bitrate": 4_200_000,
                "url": "https://example.com/1080-video-only.mp4"
            ]
        ]
    }

    func testPreferredPolicyCapsAtRequestedHeight() {
        XCTAssertEqual(
            YTStreamFormatSelector.selectURL(from: qualityFormats, policy: .preferred(maxHeight: 480))?.absoluteString,
            "https://example.com/480.mp4"
        )
        XCTAssertEqual(
            YTStreamFormatSelector.selectURL(from: qualityFormats, policy: .preferred(maxHeight: 720))?.absoluteString,
            "https://example.com/720.mp4"
        )
        // 1080 is video-only, so a 1080 cap still lands on the best audio+video format (720p).
        XCTAssertEqual(
            YTStreamFormatSelector.selectURL(from: qualityFormats, policy: .preferred(maxHeight: 1080))?.absoluteString,
            "https://example.com/720.mp4"
        )
    }

    func testPreferredPolicyBelowAllFormatsPicksSmallest() {
        XCTAssertEqual(
            YTStreamFormatSelector.selectURL(from: qualityFormats, policy: .preferred(maxHeight: 240))?.absoluteString,
            "https://example.com/360.mp4"
        )
    }

    func testQualityPolicyRawValueRoundTrips() {
        for policy in YTStreamSelectionPolicy.qualityTierOptions {
            XCTAssertEqual(
                YTStreamSelectionPolicy(storedRawValue: policy.storedRawValue),
                policy,
                "Round trip failed for \(policy.storedRawValue)"
            )
        }
        XCTAssertEqual(YTStreamSelectionPolicy(storedRawValue: "max720"), .preferred(maxHeight: 720))
        XCTAssertEqual(YTStreamSelectionPolicy(storedRawValue: "highest"), .highestQuality)
        XCTAssertEqual(YTStreamSelectionPolicy(storedRawValue: "auto"), .highestQuality)
        XCTAssertEqual(YTStreamSelectionPolicy(storedRawValue: "compatible"), .legacyCompatible)
        XCTAssertNil(YTStreamSelectionPolicy(storedRawValue: "bogus"))
        XCTAssertNil(YTStreamSelectionPolicy(storedRawValue: ""))
    }
}

final class YTVTTParserTests: XCTestCase {
    func testParsesAndGeneratesVTT() {
        let vtt = """
        WEBVTT

        1
        00:00:01.250 --> 00:00:03.500 align:start
        <c>Hello &amp; welcome</c>

        2
        00:00:04,000 --> 00:00:05,250
        Next line
        """

        let cues = YTVTTParser.parse(vtt)
        let regenerated = YTVTTParser.makeVTT(from: cues)

        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].start, 1.25, accuracy: 0.001)
        XCTAssertEqual(cues[0].end, 3.5, accuracy: 0.001)
        XCTAssertEqual(cues[0].text, "Hello & welcome")
        XCTAssertTrue(regenerated.contains("00:00:01.250 --> 00:00:03.500"))
    }

    func testConvertsYouTubeXMLToVTT() {
        let xml = """
        <transcript>
          <text start="1.25" dur="2.5">Hello &amp; welcome</text>
          <text start="4" dur="1.25">Next line</text>
        </transcript>
        """

        let vtt = YTVTTParser.vttFromYouTubeXML(xml)
        let cues = YTVTTParser.parse(vtt)

        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].start, 1.25, accuracy: 0.001)
        XCTAssertEqual(cues[0].end, 3.75, accuracy: 0.001)
        XCTAssertEqual(cues[0].text, "Hello & welcome")
    }

    func testConvertsYouTubeJSON3ToVTT() {
        let json = """
        {
          "events": [
            {"tStartMs":80,"dDurationMs":3620,"segs":[{"utf8":"Hello\\nworld"}]},
            {"tStartMs":3740,"dDurationMs":1000,"segs":[{"utf8":"Next "},{"utf8":"line"}]}
          ]
        }
        """

        let vtt = YTVTTParser.vttFromYouTubeJSON3(json)
        let cues = YTVTTParser.parse(vtt)

        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].start, 0.08, accuracy: 0.001)
        XCTAssertEqual(cues[0].end, 3.7, accuracy: 0.001)
        XCTAssertEqual(cues[0].text, "Hello world")
        XCTAssertEqual(cues[1].text, "Next line")
    }

    func testAppliesTranslatedCuesToLearningSegmentsByTiming() {
        let segments = [
            LearningSegment(sequence: 1, startMS: 0, endMS: 1000, text: "Hello."),
            LearningSegment(sequence: 2, startMS: 1000, endMS: 2200, text: "Next line.")
        ]
        let translatedCues = [
            YTCue(id: 100, start: 0.08, end: 0.92, text: "你好。"),
            YTCue(id: 101, start: 1.05, end: 2.1, text: "下一句。")
        ]

        let translated = YTVTTParser.applyingTranslations(from: translatedCues, to: segments)

        XCTAssertEqual(translated[0].translation, "你好。")
        XCTAssertEqual(translated[1].translation, "下一句。")
        XCTAssertEqual(translated[0].text, "Hello.")
    }

    func testNativeCaptionAlignmentAcceptsExclusiveDominantOverlaps() {
        let segments = [
            LearningSegment(sequence: 1, startMS: 0, endMS: 1000, text: "Hello."),
            LearningSegment(sequence: 2, startMS: 1000, endMS: 2000, text: "World."),
            LearningSegment(sequence: 3, startMS: 2000, endMS: 3000, text: "Again."),
            LearningSegment(sequence: 4, startMS: 3000, endMS: 4000, text: "Done.")
        ]
        let translatedCues = [
            YTCue(id: 1, start: 0.0, end: 1.0, text: "你好。"),
            YTCue(id: 2, start: 1.0, end: 2.0, text: "世界。"),
            YTCue(id: 3, start: 2.0, end: 3.0, text: "再次。"),
            YTCue(id: 4, start: 3.0, end: 4.0, text: "完成。")
        ]

        let alignment = YTVTTParser.alignNativeTranslations(from: translatedCues, to: segments)
        XCTAssertEqual(alignment.score, 1.0, accuracy: 0.001)
        XCTAssertTrue(alignment.isAccepted)
        XCTAssertEqual(alignment.segments.map(\.translation), ["你好。", "世界。", "再次。", "完成。"])
    }

    func testNativeCaptionAlignmentAggregatesMultipleCuesIntoOneEnglishSegment() {
        let segments = [
            LearningSegment(sequence: 1, startMS: 0, endMS: 3_000, text: "A complete thought."),
            LearningSegment(sequence: 2, startMS: 3_000, endMS: 5_000, text: "The next thought.")
        ]
        let translatedCues = [
            YTCue(id: 10, start: 0.0, end: 1.4, text: "一个"),
            YTCue(id: 11, start: 1.4, end: 3.0, text: "完整想法。"),
            YTCue(id: 12, start: 3.0, end: 5.0, text: "下一个想法。")
        ]

        let alignment = YTVTTParser.alignNativeTranslations(
            from: translatedCues,
            to: segments,
            acceptanceThreshold: 1.0
        )

        XCTAssertTrue(alignment.isAccepted)
        XCTAssertEqual(alignment.segments.map(\.translation), ["一个完整想法。", "下一个想法。"])
    }

    func testNativeCaptionAlignmentScoresDownloadedTrackIndependentlyOfSavedTranslations() {
        let segments = [
            LearningSegment(sequence: 1, startMS: 0, endMS: 1_000, text: "One.", translation: "旧译文1"),
            LearningSegment(sequence: 2, startMS: 1_000, endMS: 2_000, text: "Two.", translation: "旧译文2"),
            LearningSegment(sequence: 3, startMS: 2_000, endMS: 3_000, text: "Three.", translation: "旧译文3"),
            LearningSegment(sequence: 4, startMS: 3_000, endMS: 4_000, text: "Four.")
        ]
        let oneCue = [YTCue(id: 1, start: 3.0, end: 4.0, text: "新译文")]

        let alignment = YTVTTParser.alignNativeTranslations(from: oneCue, to: segments)

        XCTAssertEqual(alignment.score, 0.25, accuracy: 0.001)
        XCTAssertFalse(alignment.isAccepted)
        XCTAssertEqual(alignment.segments.map(\.translation), ["旧译文1", "旧译文2", "旧译文3", "新译文"])
    }

    func testNativeCaptionMergeDoesNotDeleteSingleRepeatedChineseCharacter() {
        let segments = [
            LearningSegment(sequence: 1, startMS: 0, endMS: 2_000, text: "Good news.")
        ]
        let translatedCues = [
            YTCue(id: 1, start: 0.0, end: 1.0, text: "很好"),
            YTCue(id: 2, start: 1.0, end: 2.0, text: "好消息")
        ]

        let alignment = YTVTTParser.alignNativeTranslations(
            from: translatedCues,
            to: segments,
            acceptanceThreshold: 1.0
        )

        XCTAssertEqual(alignment.segments[0].translation, "很好好消息")
    }

    func testNativeCaptionAlignmentRejectsSharedCueMisalignment() {
        // One Chinese cue spans all English segments → none are exclusive.
        let segments = [
            LearningSegment(sequence: 1, startMS: 0, endMS: 1000, text: "One"),
            LearningSegment(sequence: 2, startMS: 1000, endMS: 2000, text: "Two"),
            LearningSegment(sequence: 3, startMS: 2000, endMS: 3000, text: "Three"),
            LearningSegment(sequence: 4, startMS: 3000, endMS: 4000, text: "Four")
        ]
        let translatedCues = [
            YTCue(id: 1, start: 0.0, end: 4.0, text: "整段中文")
        ]

        let alignment = YTVTTParser.alignNativeTranslations(from: translatedCues, to: segments)
        XCTAssertEqual(alignment.score, 0.0, accuracy: 0.001)
        XCTAssertFalse(alignment.isAccepted)
    }

    func testSyncedLearningSegmentsRebuildSourceAndTranslatedVTT() {
        let segments = [
            LearningSegment(sequence: 1, startMS: 80, endMS: 920, text: "Hello.", translation: "\u{4f60}\u{597d}\u{3002}"),
            LearningSegment(sequence: 2, startMS: 1_050, endMS: 2_100, text: "Next line.", translation: "\u{4e0b}\u{4e00}\u{53e5}\u{3002}")
        ]

        let sourceVTT = YTVTTParser.makeVTT(from: YTVTTParser.sourceCues(from: segments))
        let translatedVTT = YTVTTParser.makeVTT(from: YTVTTParser.translatedCues(from: segments))

        XCTAssertEqual(YTVTTParser.parse(sourceVTT).map(\.text), ["Hello.", "Next line."])
        XCTAssertEqual(YTVTTParser.parse(translatedVTT).map(\.text), ["\u{4f60}\u{597d}\u{3002}", "\u{4e0b}\u{4e00}\u{53e5}\u{3002}"])
        XCTAssertEqual(YTVTTParser.parse(sourceVTT).map(\.start), [0.08, 1.05])
    }

    func testSubtitleTranslationProgressCountsNonEmptyTranslations() {
        let segments = [
            LearningSegment(sequence: 1, startMS: 0, endMS: 1000, text: "Hello.", translation: "你好。"),
            LearningSegment(sequence: 2, startMS: 1000, endMS: 2200, text: "Next line."),
            LearningSegment(sequence: 3, startMS: 2200, endMS: 3200, text: "Done.", translation: "   ")
        ]

        let progress = YTSubtitleTranslationProgress(segments: segments)

        XCTAssertEqual(progress.translatedCount, 1)
        XCTAssertEqual(progress.totalCount, 3)
        XCTAssertEqual(progress.fraction, 1.0 / 3.0, accuracy: 0.001)
    }

    func testSubtitleCachePolicyTrustsExistingDualVTTForPlayback() {
        let english = [
            YTCue(id: 1, start: 0, end: 1, text: "Hello."),
            YTCue(id: 2, start: 1, end: 2, text: "Next line.")
        ]
        let chinese = [
            YTCue(id: 1, start: 0, end: 1, text: "你好。"),
            YTCue(id: 2, start: 1, end: 2, text: "下一句。")
        ]
        let staleSegments = [
            LearningSegment(sequence: 1, startMS: 0, endMS: 1000, text: "Hello."),
            LearningSegment(sequence: 2, startMS: 1000, endMS: 2000, text: "Next line.")
        ]

        XCTAssertTrue(
            YTSubtitleCachePolicy.hasPlayableDualSubtitles(
                englishCues: english,
                chineseCues: chinese,
                savedSegments: staleSegments
            )
        )
    }

    func testSubtitleCachePolicyDoesNotPromoteIncompleteGeneratedSegmentsAtNinetyPercentCoverage() {
        let english = (0..<10).map { index in
            YTCue(id: index, start: Double(index), end: Double(index + 1), text: "English \(index)")
        }
        let translated = english.dropLast().map { cue in
            YTCue(id: cue.id, start: cue.start, end: cue.end, text: "Translation \(cue.id)")
        }
        let segments = english.map { cue in
            LearningSegment(
                sequence: cue.id,
                startMS: Int(cue.start * 1000),
                endMS: Int(cue.end * 1000),
                text: cue.text,
                translation: cue.id < 9 ? "Translation \(cue.id)" : ""
            )
        }

        XCTAssertFalse(YTSubtitleCachePolicy.hasPlayableDualSubtitles(
            englishCues: english,
            chineseCues: translated,
            savedSegments: segments
        ))
    }

    // MARK: json3 word timestamps + pause segmentation (M2)

    func testWordsFromYouTubeJSON3PreservesOffsetsAndPunctuation() {
        let json = """
        {
          "events": [
            {
              "tStartMs": 1000,
              "dDurationMs": 2500,
              "segs": [
                {"utf8": "Hello", "tOffsetMs": 0},
                {"utf8": " world.", "tOffsetMs": 400},
                {"utf8": " Next", "tOffsetMs": 1200},
                {"utf8": " line", "tOffsetMs": 1600}
              ]
            },
            {
              "tStartMs": 5000,
              "dDurationMs": 1000,
              "segs": [
                {"utf8": "Done!", "tOffsetMs": 0}
              ]
            }
          ]
        }
        """

        let words = YTVTTParser.wordsFromYouTubeJSON3(json)
        XCTAssertEqual(words.map(\.text), ["Hello", "world", "Next", "line", "Done"])
        XCTAssertEqual(words.map(\.punctuation), [nil, ".", nil, nil, "!"])
        XCTAssertEqual(words[0].startMS, 1000)
        XCTAssertEqual(words[1].startMS, 1400)
        XCTAssertEqual(words[2].startMS, 2200)
        XCTAssertEqual(words[4].startMS, 5000)
    }

    func testWordsFromYouTubeJSON3KeepsMultiwordSegmentAsOneTimedAtom() {
        let json = """
        {
          "events": [
            {
              "tStartMs": 1000,
              "dDurationMs": 5000,
              "segs": [
                {"utf8": "multi word phrase", "tOffsetMs": 0},
                {"utf8": " done.", "tOffsetMs": 900}
              ]
            },
            {
              "tStartMs": 2400,
              "dDurationMs": 4000,
              "segs": [{"utf8": "Next", "tOffsetMs": 0}]
            }
          ]
        }
        """

        let words = YTVTTParser.wordsFromYouTubeJSON3(json)

        XCTAssertEqual(words.map(\.text), ["multi word phrase", "done", "Next"])
        XCTAssertEqual(words[1].endMS, 2400)
        XCTAssertNotEqual(words[1].endMS, 6000)
    }

    func testWordsFromYouTubeJSON3FinalAtomEndIgnoresEventDuration() {
        let shortDuration = """
        {"events":[{"tStartMs":1000,"dDurationMs":10,"segs":[{"utf8":"final"}]}]}
        """
        let longDuration = """
        {"events":[{"tStartMs":1000,"dDurationMs":9000,"segs":[{"utf8":"final"}]}]}
        """

        let short = YTVTTParser.wordsFromYouTubeJSON3(shortDuration)
        let long = YTVTTParser.wordsFromYouTubeJSON3(longDuration)

        XCTAssertEqual(short.first?.endMS, long.first?.endMS)
        XCTAssertEqual(short.first?.endMS, 1_200)
    }

    func testLearningSegmentsFromJSON3CoalescesEqualOffsetsWithoutOverlap() {
        let json = """
        {
          "events": [
            {"tStartMs":1000,"dDurationMs":4000,"segs":[
              {"utf8":"First,"},{"utf8":" thought", "tOffsetMs":0},
              {"utf8":" continues.", "tOffsetMs":0}
            ]},
            {"tStartMs":3000,"dDurationMs":3000,"segs":[{"utf8":"Next sentence."}]}
          ]
        }
        """

        let segments = YTVTTParser.learningSegmentsFromYouTubeJSON3(json)

        XCTAssertEqual(segments.map(\.text), ["First, thought continues.", "Next sentence."])
        XCTAssertTrue(zip(segments, segments.dropFirst()).allSatisfy { $0.endMS <= $1.startMS })
    }

    func testLearningSegmentsFromJSON3DeduplicatesRollingASRText() {
        let json = """
        {"events":[
          {"tStartMs":0,"dDurationMs":2500,"segs":[{"utf8":"the quick"}]},
          {"tStartMs":1000,"dDurationMs":2500,"segs":[{"utf8":"the quick brown fox."}]}
        ]}
        """

        let segments = YTVTTParser.learningSegmentsFromYouTubeJSON3(json)

        XCTAssertEqual(segments.map(\.text), ["the quick brown fox."])
    }

    func testLearningSegmentsFromLongUnpunctuatedJSON3SplitsNearBalancedBoundaries() throws {
        let rawSegments: [[String: Any]] = (0..<40).map { index in
            ["utf8": " word\(index)", "tOffsetMs": index * 150]
        }
        let payload: [String: Any] = [
            "events": [["tStartMs": 0, "dDurationMs": 7_000, "segs": rawSegments]]
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)

        let segments = YTVTTParser.learningSegmentsFromYouTubeJSON3(json)

        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertFalse(segments.contains { $0.text.split(separator: " ").count == 1 })
        XCTAssertTrue(segments.allSatisfy {
            $0.text.count <= PauseBasedSentenceSegmenter.maxCharacters
                && $0.endMS - $0.startMS <= PauseBasedSentenceSegmenter.maxDurationMS
        })
        XCTAssertTrue(zip(segments, segments.dropFirst()).allSatisfy { $0.endMS <= $1.startMS })
    }

    func testLearningSegmentsBalancedSplitsOneOversizedMultiwordSeg() throws {
        let text = (0..<40).map { "word\($0)" }.joined(separator: " ")
        let payload: [String: Any] = [
            "events": [[
                "tStartMs": 1_000,
                "dDurationMs": 7_000,
                "segs": [["utf8": text]]
            ]]
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)

        let segments = YTVTTParser.learningSegmentsFromYouTubeJSON3(json)

        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertTrue(segments.allSatisfy { $0.text.count <= PauseBasedSentenceSegmenter.maxCharacters })
        XCTAssertLessThanOrEqual(abs(segments[0].text.count - segments[1].text.count), 20)
        XCTAssertTrue(zip(segments, segments.dropFirst()).allSatisfy { $0.endMS <= $1.startMS })
    }

    func testLearningSegmentsFromProductionJSON3KeepsROIClauseAndFullThought() {
        let json = """
        {
          "events": [
            {
              "tStartMs": 1014959,
              "dDurationMs": 5761,
              "segs": [
                {"utf8": ">> In"}, {"utf8": " terms", "tOffsetMs": 240},
                {"utf8": " of", "tOffsetMs": 320}, {"utf8": " measuring", "tOffsetMs": 481},
                {"utf8": " ROI,", "tOffsetMs": 880}, {"utf8": " like", "tOffsetMs": 1521},
                {"utf8": " we've", "tOffsetMs": 2081}
              ]
            },
            {
              "tStartMs": 1017440,
              "dDurationMs": 5680,
              "segs": [
                {"utf8": "been"}, {"utf8": " it's", "tOffsetMs": 319},
                {"utf8": " been", "tOffsetMs": 639}, {"utf8": " easy", "tOffsetMs": 800},
                {"utf8": " and", "tOffsetMs": 1199}, {"utf8": " we've", "tOffsetMs": 1440},
                {"utf8": " seen", "tOffsetMs": 1759}, {"utf8": " very", "tOffsetMs": 2000}
              ]
            },
            {
              "tStartMs": 1020720,
              "dDurationMs": 6079,
              "segs": [
                {"utf8": "um"}, {"utf8": " clear", "tOffsetMs": 559},
                {"utf8": " signals", "tOffsetMs": 960}, {"utf8": " in", "tOffsetMs": 1359},
                {"utf8": " that", "tOffsetMs": 1520}, {"utf8": " space.", "tOffsetMs": 1760},
                {"utf8": " We're", "tOffsetMs": 2160}
              ]
            },
            {
              "tStartMs": 1023120,
              "dDurationMs": 6000,
              "segs": [{"utf8": "seeing"}, {"utf8": " a", "tOffsetMs": 240}]
            }
          ]
        }
        """

        let segments = YTVTTParser.learningSegmentsFromYouTubeJSON3(json)

        // Word-stream-first segmentation: sentences are cut from the per-seg word timeline, so
        // they carry word-precise timing and monotonic boundaries. The ROI clause is grouped
        // with the following words (no sentence-terminal pause at the comma) rather than split
        // into a bare clause.
        XCTAssertEqual(segments[0].text, ">> In terms of measuring ROI, like we've been it's been")
        XCTAssertEqual(
            segments[1].text,
            "easy and we've seen very um clear signals in that space."
        )
        XCTAssertEqual(segments[1].startMS, 1_018_240)
        XCTAssertEqual(segments[1].endMS, 1_022_880)
        XCTAssertTrue(zip(segments, segments.dropFirst()).allSatisfy { $0.endMS <= $1.startMS })
        XCTAssertFalse(segments.contains { $0.text.split(separator: " ").count == 1 })
        // Word-level timing is attached for downstream [br] re-segmentation / display-splitting.
        XCTAssertTrue(segments.allSatisfy { !$0.words.isEmpty })
        XCTAssertTrue(segments.allSatisfy { $0.timingSource == .wordTimeline })
    }

    func testCaptionSegmentationQualityRejectsFragmentedOneWordTimeline() {
        let fragmented = (0..<20).map { index in
            LearningSegment(
                sequence: index + 1,
                startMS: index * 500,
                endMS: index * 500 + 300,
                text: "word"
            )
        }

        let report = YTCaptionSegmentationQualityPolicy.report(for: fragmented)

        XCTAssertEqual(report.oneWordRatio, 1.0, accuracy: 0.001)
        XCTAssertEqual(report.shortDurationRatio, 1.0, accuracy: 0.001)
        XCTAssertFalse(report.isAcceptable)
    }

    func testCaptionSegmentationQualityRejectsOverlappingFinalSegments() {
        let segments = [
            LearningSegment(sequence: 1, startMS: 0, endMS: 1_200, text: "A complete cue."),
            LearningSegment(sequence: 2, startMS: 1_000, endMS: 2_000, text: "Another complete cue.")
        ]

        let report = YTCaptionSegmentationQualityPolicy.report(for: segments)

        XCTAssertFalse(report.hasMonotonicTimeline)
        XCTAssertFalse(report.isAcceptable)
    }

    func testCaptionSegmentationQualityRejectsPathologicalSmallSample() {
        let segments = [
            LearningSegment(sequence: 1, startMS: 0, endMS: 20, text: "A very dense subtitle flash")
        ]

        let report = YTCaptionSegmentationQualityPolicy.report(for: segments)

        XCTAssertGreaterThan(report.maximumCharactersPerSecond, 100)
        XCTAssertFalse(report.isAcceptable)
        XCTAssertTrue(report.rejectionReasons.contains("absoluteCPSExceeded"))
    }

    func testCaptionSegmentationQualityAcceptsIsolatedSoftCPSOutliersWithinTolerance() {
        var segments = (0..<100).map { index in
            LearningSegment(
                sequence: index + 1,
                startMS: index * 1_000,
                endMS: index * 1_000 + 1_000,
                text: "A healthy caption segment for learning."
            )
        }
        // ~101 CPS soft outlier, still under the absolute 120 ceiling.
        segments[50] = LearningSegment(
            sequence: 51,
            startMS: 50_000,
            endMS: 50_505,
            text: String(repeating: "x", count: 51)
        )

        let strict = YTCaptionSegmentationQualityPolicy.report(for: segments)
        XCTAssertEqual(strict.highCPSOutlierCount, 1)
        XCTAssertEqual(strict.highCPSOutlierRatio, 0.01, accuracy: 0.0001)
        XCTAssertFalse(strict.isAcceptable)

        let tolerant = YTCaptionSegmentationQualityPolicy.report(
            for: segments,
            outlierTolerancePercent: 1
        )
        XCTAssertTrue(tolerant.isAcceptable)
        XCTAssertEqual(tolerant.maximumTextLength, 51)
        XCTAssertEqual(tolerant.oversizedSegmentCount, 0)
        XCTAssertTrue(tolerant.rejectionReasons.isEmpty)
    }

    func testCaptionSegmentationQualityRejectsWhenOutlierRatioExceedsTolerance() {
        var segments = (0..<100).map { index in
            LearningSegment(
                sequence: index + 1,
                startMS: index * 1_000,
                endMS: index * 1_000 + 1_000,
                text: "A healthy caption segment for learning."
            )
        }
        for index in [10, 20, 30] {
            segments[index] = LearningSegment(
                sequence: index + 1,
                startMS: index * 1_000,
                endMS: index * 1_000 + 505,
                text: String(repeating: "y", count: 51)
            )
        }

        let report = YTCaptionSegmentationQualityPolicy.report(
            for: segments,
            outlierTolerancePercent: 1
        )
        XCTAssertEqual(report.highCPSOutlierCount, 3)
        XCTAssertFalse(report.isAcceptable)
        XCTAssertTrue(report.rejectionReasons.contains("highCPSOutlierRatioExceeded"))
    }

    func testCaptionSegmentationQualityRejectsAnySegmentAboveAbsoluteCPSCeiling() {
        let segments = [
            LearningSegment(
                sequence: 1,
                startMS: 0,
                endMS: 1_000,
                text: "A healthy caption segment for learning."
            ),
            LearningSegment(
                sequence: 2,
                startMS: 1_000,
                endMS: 1_400,
                text: String(repeating: "z", count: 49) // 122.5 CPS
            )
        ]

        let report = YTCaptionSegmentationQualityPolicy.report(
            for: segments,
            outlierTolerancePercent: 5
        )
        XCTAssertGreaterThan(
            report.maximumCharactersPerSecond,
            YTCaptionSegmentationQualityPolicy.absoluteMaximumCharactersPerSecond
        )
        XCTAssertFalse(report.isAcceptable)
        XCTAssertTrue(report.rejectionReasons.contains("absoluteCPSExceeded"))
    }

    func testCaptionSegmentationQualityRegressionSampleMatchesJWOPTolerance() {
        // Programmatic stand-in for jwopF96RVdU: 800 healthy + 5 soft CPS outliers (~0.62%).
        var segments = (0..<800).map { index in
            LearningSegment(
                sequence: index + 1,
                startMS: index * 1_000,
                endMS: index * 1_000 + 1_000,
                text: "Healthy narrative caption for the regression sample."
            )
        }
        for offset in 0..<5 {
            let index = 100 + offset * 50
            segments[index] = LearningSegment(
                sequence: index + 1,
                startMS: index * 1_000,
                endMS: index * 1_000 + 504,
                text: String(repeating: "q", count: 51) // ~101 CPS
            )
        }

        let strict = YTCaptionSegmentationQualityPolicy.report(
            for: segments,
            outlierTolerancePercent: 0
        )
        XCTAssertEqual(strict.highCPSOutlierCount, 5)
        XCTAssertFalse(strict.isAcceptable)

        let defaultTolerance = YTCaptionSegmentationQualityPolicy.report(
            for: segments,
            outlierTolerancePercent: 1
        )
        XCTAssertTrue(defaultTolerance.isAcceptable)
        XCTAssertLessThanOrEqual(
            defaultTolerance.maximumCharactersPerSecond,
            YTCaptionSegmentationQualityPolicy.absoluteMaximumCharactersPerSecond
        )
    }

    func testCaptionIngestionSegmentsSplitsOversizedCuesNearPunctuation() {
        // 91 characters with punctuation near the midpoint so the splitter prefers it.
        let longCue = String(repeating: "a", count: 50) + ". " + String(repeating: "b", count: 39)
        XCTAssertEqual(longCue.count, 91)
        let cues = [
            YTCue(id: 1, start: 0.0, end: 2.0, text: longCue)
        ]

        let segments = YTVTTParser.captionIngestionSegments(from: cues)

        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertEqual(segments.map(\.text).joined(separator: " "), longCue)
        XCTAssertTrue(segments.allSatisfy { $0.text.count <= PauseBasedSentenceSegmenter.maxCharacters })
        XCTAssertTrue(segments.allSatisfy {
            $0.endMS - $0.startMS >= YTCaptionSegmentationQualityPolicy.absoluteMinimumDurationMS
        })
        XCTAssertTrue(zip(segments, segments.dropFirst()).allSatisfy { $0.endMS <= $1.startMS })
        XCTAssertEqual(segments.first?.startMS, 0)
        XCTAssertEqual(segments.last?.endMS, 2_000)
        XCTAssertTrue(segments[0].text.hasSuffix("."))
    }

    func testCaptionIngestionSegmentsSplits119CharacterCueByCharacterWeight() {
        // No internal sentence punctuation — forces a midpoint word-boundary split.
        let longCue = String(repeating: "abcdefghij ", count: 10) + "abcdefghi"
        XCTAssertEqual(longCue.count, 119)
        let cues = [
            YTCue(id: 1, start: 1.0, end: 4.0, text: longCue)
        ]

        let segments = YTVTTParser.captionIngestionSegments(from: cues)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.map(\.text).joined(separator: " "), longCue)
        XCTAssertTrue(segments.allSatisfy { $0.text.count <= 90 })
        XCTAssertEqual(segments[0].startMS, 1_000)
        XCTAssertEqual(segments[1].endMS, 4_000)
        XCTAssertLessThanOrEqual(segments[0].endMS, segments[1].startMS)
        let totalCharacters = segments.reduce(0) { $0 + $1.text.count }
        let expectedFirstSpan = Int(
            (3_000.0 * Double(segments[0].text.count) / Double(totalCharacters)).rounded()
        )
        XCTAssertEqual(segments[0].endMS - segments[0].startMS, max(expectedFirstSpan, 100))
        XCTAssertEqual(
            (segments[0].endMS - segments[0].startMS) + (segments[1].endMS - segments[1].startMS),
            3_000
        )
    }

    func testCaptionIngestionSegmentsKeepsUnsafeShortOversizedCueIntact() {
        let longCue = String(repeating: "a", count: 50) + ". " + String(repeating: "b", count: 39)
        XCTAssertEqual(longCue.count, 91)
        // 150ms cannot host two ≥100ms slices.
        let cues = [
            YTCue(id: 1, start: 0.0, end: 0.15, text: longCue)
        ]

        let segments = YTVTTParser.captionIngestionSegments(from: cues)
        let baseline = YTVTTParser.learningSegments(from: cues)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, baseline[0].text)
        XCTAssertEqual(segments[0].startMS, baseline[0].startMS)
        XCTAssertEqual(segments[0].endMS, baseline[0].endMS)
        XCTAssertFalse(
            YTCaptionSegmentationQualityPolicy.report(for: segments).isAcceptable
        )
    }

    func testCaptionIngestionSegmentsLeavesHealthyCuesUnchanged() {
        let cues = [
            YTCue(id: 1, start: 0.0, end: 1.2, text: "Hello there."),
            YTCue(id: 2, start: 1.2, end: 2.5, text: "This is a healthy caption cue.")
        ]

        let ingested = YTVTTParser.captionIngestionSegments(from: cues)
        let baseline = YTVTTParser.learningSegments(from: cues)

        XCTAssertEqual(ingested, baseline)
    }

    func testPauseBasedSentenceSegmenterSplitsOnPunctuationAndPauses() {
        let words = [
            TranscriptWord(text: "Hello", startMS: 0, endMS: 300, punctuation: "."),
            TranscriptWord(text: "How", startMS: 400, endMS: 600),
            TranscriptWord(text: "are", startMS: 620, endMS: 800),
            TranscriptWord(text: "you", startMS: 820, endMS: 1000, punctuation: "?"),
            // 900ms gap → new sentence by pause
            TranscriptWord(text: "Fine", startMS: 1900, endMS: 2200)
        ]

        let segments = PauseBasedSentenceSegmenter.segments(from: words)
        XCTAssertEqual(segments.map(\.text), ["Hello.", "How are you?", "Fine"])
        XCTAssertEqual(segments[0].startMS, 0)
        XCTAssertEqual(segments[0].endMS, 300)
        XCTAssertEqual(segments[1].startMS, 400)
        XCTAssertEqual(segments[2].startMS, 1900)
        XCTAssertFalse(segments[0].words.isEmpty)
    }

    func testPauseBasedSentenceSegmenterEnforcesDurationAndCharacterCaps() {
        // One long run with tiny gaps and no punctuation — must force-split.
        var words: [TranscriptWord] = []
        var cursor = 0
        for index in 0..<40 {
            let text = "word\(index)"
            words.append(TranscriptWord(text: text, startMS: cursor, endMS: cursor + 180))
            cursor += 200
        }

        let segments = PauseBasedSentenceSegmenter.segments(from: words)
        XCTAssertGreaterThan(segments.count, 1)
        for segment in segments {
            XCTAssertLessThanOrEqual(segment.endMS - segment.startMS, PauseBasedSentenceSegmenter.maxDurationMS)
            XCTAssertLessThanOrEqual(segment.text.count, PauseBasedSentenceSegmenter.maxCharacters)
        }
    }

    func testPauseBasedSentenceSegmenterBalancesOversizedZeroGapInput() {
        let words = (0..<12).map { index in
            TranscriptWord(
                text: "longword\(index)",
                startMS: index * 100,
                endMS: (index + 1) * 100
            )
        }

        let segments = PauseBasedSentenceSegmenter.segments(from: words)

        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertFalse(segments.contains { $0.text.split(separator: " ").count == 1 })
    }

    func testSubtitlePipelineVersionRejectsStaleCaches() {
        XCTAssertEqual(SubtitlePipelineVersion.current, 4)
        XCTAssertTrue(SubtitlePipelineVersion.isCurrent(4))
        XCTAssertFalse(SubtitlePipelineVersion.isCurrent(3))
        XCTAssertFalse(SubtitlePipelineVersion.isCurrent(2))
        XCTAssertFalse(SubtitlePipelineVersion.isCurrent(nil))
        // v4 keeps older complete artifacts playable and surfaces a manual upgrade instead.
        XCTAssertTrue(SubtitlePipelineVersion.isPlayableLegacy(3))
        XCTAssertTrue(SubtitlePipelineVersion.isPlayableLegacy(nil))
        XCTAssertFalse(SubtitlePipelineVersion.isPlayableLegacy(4))
    }

    // MARK: Rolling ASR normalization (2.2.1)

    func testNormalizedSentenceCuesDeduplicatesRollingASRWithoutPunctuation() {
        // Rolling ASR: each cue repeats the previous text and appends a fragment.
        let cues = [
            YTCue(id: 1, start: 0.0, end: 1.0, text: "the"),
            YTCue(id: 2, start: 0.5, end: 2.0, text: "the quick"),
            YTCue(id: 3, start: 1.5, end: 3.0, text: "the quick brown"),
            YTCue(id: 4, start: 2.5, end: 4.0, text: "the quick brown fox"),
            YTCue(id: 5, start: 4.0, end: 5.0, text: "jumps"),
            YTCue(id: 6, start: 4.5, end: 6.0, text: "jumps over")
        ]

        let normalized = YTVTTParser.normalizedSentenceCues(from: cues)

        // The deduplicated output keeps each cue's real start time and emits
        // every word exactly once: cue1 "the quick brown fox", cue2 "jumps over".
        XCTAssertEqual(normalized.map(\.text), ["the quick brown fox", "jumps over"])
        XCTAssertEqual(normalized.map(\.id), [1, 2])
        XCTAssertEqual(normalized[0].start, 0.0, accuracy: 0.001)
        XCTAssertEqual(normalized[1].start, 4.0, accuracy: 0.001)
        // Timeline is monotonic and non-overlapping.
        XCTAssertGreaterThanOrEqual(normalized[1].start, normalized[0].start)
    }

    func testNormalizedSentenceCuesIsStableForCleanPunctuatedInput() {
        // Manual captions already carry punctuation and do not overlap.
        let cues = [
            YTCue(id: 1, start: 0.0, end: 1.0, text: "Hello."),
            YTCue(id: 2, start: 1.0, end: 2.0, text: "Next line.")
        ]

        let normalized = YTVTTParser.normalizedSentenceCues(from: cues)

        XCTAssertEqual(normalized.map(\.text), ["Hello.", "Next line."])
        XCTAssertEqual(normalized.map(\.id), [1, 2])
        XCTAssertEqual(normalized[0].start, 0.0, accuracy: 0.001)
        XCTAssertEqual(normalized[1].start, 1.0, accuracy: 0.001)
    }

    func testLearningSegmentsBuildFromNormalizedSentences() {
        let rolling = [
            YTCue(id: 1, start: 0.0, end: 1.0, text: "the"),
            YTCue(id: 2, start: 0.5, end: 2.0, text: "the quick"),
            YTCue(id: 3, start: 1.5, end: 3.0, text: "the quick brown")
        ]

        let segments = YTVTTParser.learningSegments(from: rolling)
        let texts = segments.map(\.text)

        // No segment text is a rolling prefix of another, and the union of
        // words is exactly the deduplicated stream.
        for (index, text) in texts.enumerated() {
            for other in texts.dropFirst(index + 1) where other.hasPrefix(text) {
                XCTFail("rolling duplicate survived: \(text) / \(other)")
            }
        }
        XCTAssertEqual(texts.flatMap { $0.split(separator: " ").map(String.init) }, ["the", "quick", "brown"])
    }

    // MARK: Translation completion (2.2.2)

    func testTranslationProgressStatusRequiresFullSentenceCoverage() {
        // First batch translated (3/3) but only 3 of 10 sentences covered.
        let firstBatch = YTSubtitleTranslationProgress(translatedCount: 3, totalCount: 3)
        XCTAssertTrue(firstBatch.isComplete)
        XCTAssertFalse(firstBatch.isComplete(expectedSentenceCount: 10))
        XCTAssertEqual(firstBatch.status(expectedSentenceCount: 10), .partial)

        // Full coverage: translated == total == English sentence count.
        let complete = YTSubtitleTranslationProgress(translatedCount: 10, totalCount: 10)
        XCTAssertEqual(complete.status(expectedSentenceCount: 10), .complete)

        // Nothing translated yet.
        let empty = YTSubtitleTranslationProgress(translatedCount: 0, totalCount: 10)
        XCTAssertEqual(empty.status(expectedSentenceCount: 10), .notStarted)
    }

    func testSavedTranslationsCompleteRequiresExactSentenceCount() {
        let translated = (1...3).map {
            LearningSegment(sequence: $0, startMS: 0, endMS: 1000, text: "S\($0).", translation: "T\($0)")
        }
        // All translated but only 3 of 10 sentences: partial, not complete.
        XCTAssertFalse(YTSubtitleCachePolicy.savedTranslationsComplete(translated, expectedCueCount: 10))
        XCTAssertTrue(YTSubtitleCachePolicy.savedTranslationsComplete(translated, expectedCueCount: 3))

        // One missing translation: never complete.
        var partial = translated
        partial[2].translation = "   "
        XCTAssertFalse(YTSubtitleCachePolicy.savedTranslationsComplete(partial, expectedCueCount: 3))

        let duplicatedSequences = [
            LearningSegment(sequence: 1, startMS: 0, endMS: 1000, text: "A", translation: "甲"),
            LearningSegment(sequence: 1, startMS: 1000, endMS: 2000, text: "B", translation: "乙")
        ]
        XCTAssertFalse(YTSubtitleCachePolicy.savedTranslationsComplete(
            duplicatedSequences,
            expectedSequences: [1, 2]
        ))
    }

    func testHasPlayableDualSubtitlesRejectsFirstBatchCompletionOnRollingCues() {
        // Rolling English cues collapse to a small set of sentences. Segments
        // covering only part of them (all translated so far) must NOT report
        // complete, even though the translated cues happen to cover the timeline.
        let rollingEnglish = [
            YTCue(id: 1, start: 0.0, end: 1.0, text: "the"),
            YTCue(id: 2, start: 0.5, end: 2.0, text: "the quick"),
            YTCue(id: 3, start: 1.5, end: 3.0, text: "the quick brown"),
            YTCue(id: 4, start: 2.5, end: 4.0, text: "the quick brown fox"),
            YTCue(id: 5, start: 4.0, end: 5.0, text: "jumps"),
            YTCue(id: 6, start: 4.5, end: 6.0, text: "jumps over")
        ]
        let sentences = YTVTTParser.learningSegments(from: rollingEnglish)
        XCTAssertEqual(sentences.count, 2)

        // Only the first sentence has a translation: the "first batch" finished.
        let firstBatch = sentences.enumerated().map { index, segment in
            LearningSegment(
                sequence: segment.sequence,
                startMS: segment.startMS,
                endMS: segment.endMS,
                text: segment.text,
                translation: index == 0 ? "敏捷的棕色狐狸" : ""
            )
        }
        let chinese = [YTCue(id: 1, start: 0.0, end: 6.0, text: "敏捷的棕色狐狸跳过去")]

        XCTAssertFalse(YTSubtitleCachePolicy.hasPlayableDualSubtitles(
            englishCues: rollingEnglish,
            chineseCues: chinese,
            savedSegments: firstBatch
        ))

        // Every sentence translated => genuinely complete.
        let full = sentences.map {
            LearningSegment(
                sequence: $0.sequence,
                startMS: $0.startMS,
                endMS: $0.endMS,
                text: $0.text,
                translation: "已翻译"
            )
        }
        XCTAssertTrue(YTSubtitleCachePolicy.hasPlayableDualSubtitles(
            englishCues: rollingEnglish,
            chineseCues: chinese,
            savedSegments: full
        ))
    }
}
