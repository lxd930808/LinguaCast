import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct YTResolvedChannel: Equatable, Sendable {
    public var channelID: String
    public var displayName: String?
    public var url: String

    public init(channelID: String, displayName: String? = nil, url: String) {
        self.channelID = channelID
        self.displayName = displayName
        self.url = url
    }
}

public enum YTChannelResolver {
    public static func channelID(from value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if isChannelID(trimmed) { return trimmed }
        if let url = normalizedURL(from: trimmed) {
            if let id = channelID(fromRSSURL: url) { return id }
            let parts = url.pathComponents
            if let channelIndex = parts.firstIndex(of: "channel"),
               parts.indices.contains(channelIndex + 1),
               isChannelID(parts[channelIndex + 1]) {
                return parts[channelIndex + 1]
            }
        }
        return nil
    }

    public static func channelID(fromRSSURL url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return components.queryItems?.first(where: { $0.name == "channel_id" })?.value.flatMap { isChannelID($0) ? $0 : nil }
    }

    public static func channelID(fromHTML html: String) -> String? {
        let patterns = [
            #""channelId"\s*:\s*"(UC[A-Za-z0-9_-]{20,})""#,
            #""browseId"\s*:\s*"(UC[A-Za-z0-9_-]{20,})""#,
            #"<meta[^>]+itemprop="channelId"[^>]+content="(UC[A-Za-z0-9_-]{20,})""#,
            #"youtube\.com/channel/(UC[A-Za-z0-9_-]{20,})"#
        ]
        return firstRegexCapture(in: html, patterns: patterns).flatMap { isChannelID($0) ? $0 : nil }
    }

    public static func displayName(fromHTML html: String) -> String? {
        let patterns = [
            #"<meta[^>]+property="og:title"[^>]+content="([^"]+)""#,
            #""title"\s*:\s*"([^"]+?)\s*-\s*YouTube""#,
            #"<title>(.*?)</title>"#
        ]
        guard let raw = firstRegexCapture(in: html, patterns: patterns) else { return nil }
        return htmlDecoded(raw)
            .replacingOccurrences(of: " - YouTube", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    public static func normalizedChannelURL(channelID: String) -> String {
        "https://www.youtube.com/channel/\(channelID)"
    }

    public static func isValidChannelID(_ value: String) -> Bool {
        isChannelID(value)
    }

    public static func normalizedInputURL(_ value: String) -> URL? {
        normalizedURL(from: value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func normalizedURL(from value: String) -> URL? {
        if value.hasPrefix("@") {
            return URL(string: "https://www.youtube.com/\(value)")
        }
        if value.hasPrefix("http://") || value.hasPrefix("https://") {
            return URL(string: value)
        }
        if value.contains("youtube.com") || value.contains("youtu.be") {
            return URL(string: "https://\(value)")
        }
        return nil
    }

    private static func isChannelID(_ value: String) -> Bool {
        value.range(of: #"^UC[A-Za-z0-9_-]{20,}$"#, options: .regularExpression) != nil
    }
}

public struct YTFeed: Equatable, Sendable {
    public var channelTitle: String
    public var videos: [YTFeedVideo]

    public init(channelTitle: String = "", videos: [YTFeedVideo]) {
        self.channelTitle = channelTitle
        self.videos = videos
    }
}

public struct YTFeedVideo: Equatable, Identifiable, Sendable {
    public var id: String
    public var channelID: String?
    public var title: String
    public var publishedAt: Date?
    public var updatedAt: Date?
    public var url: String
    public var thumbnail: String?

    public init(
        id: String,
        channelID: String? = nil,
        title: String,
        publishedAt: Date? = nil,
        updatedAt: Date? = nil,
        url: String,
        thumbnail: String? = nil
    ) {
        self.id = id
        self.channelID = channelID
        self.title = title
        self.publishedAt = publishedAt
        self.updatedAt = updatedAt
        self.url = url
        self.thumbnail = thumbnail
    }
}

public struct YTChannelVideosPage: Equatable, Sendable {
    public var feed: YTFeed
    public var continuationToken: String?

    public init(feed: YTFeed, continuationToken: String? = nil) {
        self.feed = feed
        self.continuationToken = continuationToken
    }

    public var hasMoreVideos: Bool {
        continuationToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

public enum YTChannelPaginationPolicy {
    public static func hasMoreVideos(after page: YTChannelVideosPage) -> Bool {
        page.hasMoreVideos
    }
}

public enum YTFeedMergePolicy {
    public static func mergeLatestMetadata(primary: YTFeed, latestMetadata: YTFeed) -> YTFeed {
        guard !latestMetadata.videos.isEmpty else { return primary }
        guard !primary.videos.isEmpty else { return latestMetadata }

        var primaryByID: [String: YTFeedVideo] = [:]
        for video in primary.videos where primaryByID[video.id] == nil {
            primaryByID[video.id] = video
        }

        var mergedVideos: [YTFeedVideo] = []
        var seen: Set<String> = []
        for metadataVideo in latestMetadata.videos where seen.insert(metadataVideo.id).inserted {
            if let primaryVideo = primaryByID[metadataVideo.id] {
                mergedVideos.append(merge(primary: primaryVideo, metadata: metadataVideo))
            } else {
                mergedVideos.append(metadataVideo)
            }
        }

        for video in primary.videos where seen.insert(video.id).inserted {
            mergedVideos.append(video)
        }

        return YTFeed(
            channelTitle: primary.channelTitle.nilIfEmpty ?? latestMetadata.channelTitle,
            videos: mergedVideos
        )
    }

    private static func merge(primary: YTFeedVideo, metadata: YTFeedVideo) -> YTFeedVideo {
        YTFeedVideo(
            id: primary.id,
            channelID: primary.channelID ?? metadata.channelID,
            title: preferredTitle(primary: primary, metadata: metadata),
            publishedAt: primary.publishedAt ?? metadata.publishedAt,
            updatedAt: primary.updatedAt ?? metadata.updatedAt,
            url: primary.url.nilIfEmpty ?? metadata.url,
            thumbnail: primary.thumbnail ?? metadata.thumbnail
        )
    }

    private static func preferredTitle(primary: YTFeedVideo, metadata: YTFeedVideo) -> String {
        guard let title = primary.title.nilIfEmpty, title != primary.id else {
            return metadata.title
        }
        return title
    }
}

public struct YouTubeDataAPIChannel: Equatable, Sendable {
    public var id: String
    public var title: String
    public var uploadsPlaylistID: String
    public var thumbnail: String?
    public var videoCount: Int?

    public init(id: String, title: String, uploadsPlaylistID: String, thumbnail: String? = nil, videoCount: Int? = nil) {
        self.id = id
        self.title = title
        self.uploadsPlaylistID = uploadsPlaylistID
        self.thumbnail = thumbnail
        self.videoCount = videoCount
    }
}

public struct YouTubeDataAPIError: LocalizedError, Equatable, Sendable {
    public var code: Int
    public var reason: String?
    public var message: String

    public init(code: Int, reason: String? = nil, message: String) {
        self.code = code
        self.reason = reason
        self.message = message
    }

    public var errorDescription: String? {
        switch reason {
        case "quotaExceeded", "dailyLimitExceeded":
            "YouTube Data API 配额已用尽，请稍后再试或检查 Google Cloud 配额。"
        case "keyInvalid", "badRequest":
            "YouTube API Key 无效，请在设置中检查 YouTube Data API Key。"
        case "accessNotConfigured":
            "当前 Google Cloud 项目未启用 YouTube Data API v3。"
        case "channelNotFound":
            "未找到该 YouTube 频道。"
        case "playlistNotFound":
            "未找到该 YouTube 播放列表。"
        default:
            message.nilIfEmpty ?? "YouTube Data API 请求失败（HTTP \(code)）。"
        }
    }
}

public enum YouTubeDataAPIRequestPolicy {
    public static func applyIOSRestrictionHeaders(to request: inout URLRequest, bundleIdentifier: String?) {
        guard let bundleIdentifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleIdentifier.isEmpty
        else { return }
        request.setValue(bundleIdentifier, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
    }
}

public enum YouTubeDataAPIParser {
    public static func parseChannelList(data: Data) throws -> YouTubeDataAPIChannel? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]]
        else { return nil }
        return items.compactMap(channel(from:)).first
    }

    public static func parsePlaylistItemsPage(data: Data, fallbackChannelID: String, channelTitle: String = "") throws -> YTChannelVideosPage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return YTChannelVideosPage(feed: YTFeed(channelTitle: channelTitle, videos: []))
        }
        let items = root["items"] as? [[String: Any]] ?? []
        let videos = items.compactMap { playlistVideo(from: $0, fallbackChannelID: fallbackChannelID) }
        return YTChannelVideosPage(
            feed: YTFeed(channelTitle: channelTitle, videos: videos),
            continuationToken: (root["nextPageToken"] as? String)?.nilIfEmpty
        )
    }

    public static func mergingVideoDetails(page: YTChannelVideosPage, data: Data) throws -> YTChannelVideosPage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return page }
        let items = root["items"] as? [[String: Any]] ?? []
        var detailsByID: [String: YTFeedVideo] = [:]
        for item in items {
            guard let video = videoDetail(from: item) else { continue }
            detailsByID[video.id] = video
        }
        let videos = page.feed.videos.map { video -> YTFeedVideo in
            guard let detail = detailsByID[video.id] else { return video }
            return YTFeedVideo(
                id: video.id,
                channelID: detail.channelID ?? video.channelID,
                title: detail.title.nilIfEmpty ?? video.title,
                publishedAt: detail.publishedAt ?? video.publishedAt,
                updatedAt: detail.updatedAt ?? video.updatedAt,
                url: detail.url.nilIfEmpty ?? video.url,
                thumbnail: detail.thumbnail ?? video.thumbnail
            )
        }
        return YTChannelVideosPage(
            feed: YTFeed(channelTitle: page.feed.channelTitle, videos: videos),
            continuationToken: page.continuationToken
        )
    }

    public static func apiError(from data: Data) -> YouTubeDataAPIError? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any]
        else { return nil }
        let code = error["code"] as? Int ?? -1
        let message = error["message"] as? String ?? ""
        let errors = error["errors"] as? [[String: Any]] ?? []
        let reason = errors.compactMap { $0["reason"] as? String }.first
        return YouTubeDataAPIError(code: code, reason: reason, message: message)
    }

    /// 解析 `videos.list`（part=snippet,contentDetails）响应为视频详情列表。
    /// 跳过 private / deleted 条目；结果不含频道归属校验（由调用方负责）。
    public static func parseVideoDetailsList(data: Data) throws -> [YTFeedVideo] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let items = root["items"] as? [[String: Any]] ?? []
        return items.compactMap(videoDetail(from:))
    }

    public static func thumbnailURL(from thumbnails: Any?) -> String? {
        guard let dict = thumbnails as? [String: Any] else { return nil }
        for key in ["maxres", "standard", "high", "medium", "default"] {
            if let url = (dict[key] as? [String: Any])?["url"] as? String,
               !url.isEmpty {
                return url
            }
        }
        return nil
    }

    private static func channel(from item: [String: Any]) -> YouTubeDataAPIChannel? {
        guard let id = item["id"] as? String,
              YTChannelResolver.isValidChannelID(id),
              let uploads = (((item["contentDetails"] as? [String: Any])?["relatedPlaylists"] as? [String: Any])?["uploads"] as? String)?.nilIfEmpty
        else { return nil }
        let snippet = item["snippet"] as? [String: Any] ?? [:]
        let statistics = item["statistics"] as? [String: Any] ?? [:]
        let title = (snippet["title"] as? String)?.nilIfEmpty ?? id
        return YouTubeDataAPIChannel(
            id: id,
            title: title,
            uploadsPlaylistID: uploads,
            thumbnail: thumbnailURL(from: snippet["thumbnails"]),
            videoCount: (statistics["videoCount"] as? String).flatMap(Int.init) ?? statistics["videoCount"] as? Int
        )
    }

    private static func playlistVideo(from item: [String: Any], fallbackChannelID: String) -> YTFeedVideo? {
        if let status = ((item["status"] as? [String: Any])?["privacyStatus"] as? String)?.lowercased(),
           status == "private" || status == "privacy_status_unspecified" {
            return nil
        }
        let snippet = item["snippet"] as? [String: Any] ?? [:]
        let contentDetails = item["contentDetails"] as? [String: Any] ?? [:]
        let resourceID = snippet["resourceId"] as? [String: Any] ?? [:]
        guard let videoID = (contentDetails["videoId"] as? String)?.nilIfEmpty
                ?? (resourceID["videoId"] as? String)?.nilIfEmpty
        else { return nil }
        let title = (snippet["title"] as? String)?.nilIfEmpty ?? videoID
        if title == "Deleted video" || title == "Private video" { return nil }
        let published = (contentDetails["videoPublishedAt"] as? String)?.nilIfEmpty
            ?? (snippet["publishedAt"] as? String)?.nilIfEmpty
        return YTFeedVideo(
            id: videoID,
            channelID: (snippet["channelId"] as? String)?.nilIfEmpty ?? fallbackChannelID,
            title: title,
            publishedAt: published.flatMap(parseISODate),
            updatedAt: nil,
            url: "https://www.youtube.com/watch?v=\(videoID)",
            thumbnail: thumbnailURL(from: snippet["thumbnails"])
        )
    }

    private static func videoDetail(from item: [String: Any]) -> YTFeedVideo? {
        guard let videoID = (item["id"] as? String)?.nilIfEmpty else { return nil }
        let snippet = item["snippet"] as? [String: Any] ?? [:]
        let published = (snippet["publishedAt"] as? String)?.nilIfEmpty
        return YTFeedVideo(
            id: videoID,
            channelID: (snippet["channelId"] as? String)?.nilIfEmpty,
            title: (snippet["title"] as? String)?.nilIfEmpty ?? videoID,
            publishedAt: published.flatMap(parseISODate),
            updatedAt: nil,
            url: "https://www.youtube.com/watch?v=\(videoID)",
            thumbnail: thumbnailURL(from: snippet["thumbnails"])
        )
    }
}

public final class YTFeedParser: NSObject, XMLParserDelegate {
    private var channelTitle = ""
    private var currentElement = ""
    private var currentText = ""
    private var inEntry = false
    private var inAuthor = false
    private var entryVideoID = ""
    private var entryChannelID = ""
    private var entryTitle = ""
    private var entryPublished = ""
    private var entryUpdated = ""
    private var entryURL = ""
    private var entryThumbnail = ""
    private var videos: [YTFeedVideo] = []

    public func parse(data: Data) throws -> YTFeed {
        reset()
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            throw parser.parserError ?? CocoaError(.fileReadCorruptFile)
        }
        return YTFeed(channelTitle: channelTitle, videos: videos)
    }

    private func reset() {
        channelTitle = ""
        currentElement = ""
        currentText = ""
        inEntry = false
        inAuthor = false
        entryVideoID = ""
        entryChannelID = ""
        entryTitle = ""
        entryPublished = ""
        entryUpdated = ""
        entryURL = ""
        entryThumbnail = ""
        videos = []
    }

    public func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        currentText = ""
        if elementName == "entry" {
            inEntry = true
            entryVideoID = ""
            entryChannelID = ""
            entryTitle = ""
            entryPublished = ""
            entryUpdated = ""
            entryURL = ""
            entryThumbnail = ""
        }
        if elementName == "author" {
            inAuthor = true
        }
        if inEntry, elementName == "link", let href = attributeDict["href"], entryURL.isEmpty {
            entryURL = href
        }
        if inEntry, elementName.hasSuffix("thumbnail"), let url = attributeDict["url"] {
            entryThumbnail = url
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    public func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if inEntry {
            switch elementName {
            case "yt:videoId", "videoId":
                entryVideoID = text
            case "yt:channelId", "channelId":
                entryChannelID = text
            case "title":
                entryTitle = text
            case "published":
                entryPublished = text
            case "updated":
                entryUpdated = text
            case "id" where entryVideoID.isEmpty:
                entryVideoID = text.replacingOccurrences(of: "yt:video:", with: "")
            case "entry":
                let id = entryVideoID.nilIfEmpty ?? videoID(fromWatchURL: entryURL)
                if let id {
                    videos.append(
                        YTFeedVideo(
                            id: id,
                            channelID: entryChannelID.nilIfEmpty,
                            title: entryTitle.nilIfEmpty ?? id,
                            publishedAt: parseISODate(entryPublished),
                            updatedAt: parseISODate(entryUpdated),
                            url: entryURL.nilIfEmpty ?? "https://www.youtube.com/watch?v=\(id)",
                            thumbnail: entryThumbnail.nilIfEmpty
                        )
                    )
                }
                inEntry = false
            default:
                break
            }
        } else if !inAuthor, elementName == "title", channelTitle.isEmpty {
            channelTitle = text
        }
        if elementName == "author" {
            inAuthor = false
        }
        currentText = ""
    }

    private func videoID(fromWatchURL value: String) -> String? {
        guard let url = URL(string: value),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        return components.queryItems?.first(where: { $0.name == "v" })?.value
    }
}

public enum YTChannelVideosPageParser {
    public static func parse(html: String, channelID: String, channelTitle: String = "") -> YTFeed {
        parseInitialPage(html: html, channelID: channelID, channelTitle: channelTitle).feed
    }

    public static func parseInitialPage(
        html: String,
        channelID: String,
        channelTitle: String = ""
    ) -> YTChannelVideosPage {
        let title = channelTitle.nilIfEmpty ?? YTChannelResolver.displayName(fromHTML: html) ?? ""
        guard let root = initialDataObject(from: html) else {
            return YTChannelVideosPage(
                feed: YTFeed(channelTitle: title, videos: videosFromRegex(html: html, channelID: channelID))
            )
        }
        let parsed = parsePageObject(root, channelID: channelID, channelTitle: title)
        if !parsed.feed.videos.isEmpty {
            return parsed
        }
        return YTChannelVideosPage(
            feed: YTFeed(channelTitle: title, videos: videosFromRegex(html: html, channelID: channelID)),
            continuationToken: parsed.continuationToken
        )
    }

    public static func parseContinuation(
        json: String,
        channelID: String,
        channelTitle: String = ""
    ) -> YTChannelVideosPage {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data)
        else {
            return YTChannelVideosPage(feed: YTFeed(channelTitle: channelTitle, videos: []))
        }
        return parsePageObject(root, channelID: channelID, channelTitle: channelTitle)
    }

    private static func initialDataObject(from html: String) -> Any? {
        guard let markerRange = html.range(of: "ytInitialData"),
              let objectStart = html[markerRange.upperBound...].firstIndex(of: "{"),
              let json = extractJSONObject(from: html, start: objectStart),
              let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data)
        else {
            return nil
        }
        return root
    }

    private static func parsePageObject(_ root: Any, channelID: String, channelTitle: String) -> YTChannelVideosPage {
        var videos: [YTFeedVideo] = []
        var seen: Set<String> = []
        var continuationTokens: [String] = []
        collectVideos(from: root, channelID: channelID, videos: &videos, seen: &seen)
        collectContinuationTokens(from: root, tokens: &continuationTokens)
        return YTChannelVideosPage(
            feed: YTFeed(channelTitle: channelTitle, videos: videos),
            continuationToken: continuationTokens.first
        )
    }

    private static func collectVideos(from value: Any, channelID: String, videos: inout [YTFeedVideo], seen: inout Set<String>) {
        if let dict = value as? [String: Any] {
            if let lockup = dict["lockupViewModel"] as? [String: Any],
               let video = video(fromLockup: lockup, channelID: channelID),
               seen.insert(video.id).inserted {
                videos.append(video)
            }
            if let renderer = dict["videoRenderer"] as? [String: Any],
               let video = video(fromVideoRenderer: renderer, channelID: channelID),
               seen.insert(video.id).inserted {
                videos.append(video)
            }
            for child in dict.values {
                collectVideos(from: child, channelID: channelID, videos: &videos, seen: &seen)
            }
            return
        }
        if let array = value as? [Any] {
            for child in array {
                collectVideos(from: child, channelID: channelID, videos: &videos, seen: &seen)
            }
        }
    }

    private static func collectContinuationTokens(from value: Any, tokens: inout [String]) {
        if let dict = value as? [String: Any] {
            if let command = dict["continuationCommand"] as? [String: Any],
               let token = command["token"] as? String,
               !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                tokens.append(token)
            }
            for child in dict.values {
                collectContinuationTokens(from: child, tokens: &tokens)
            }
            return
        }
        if let array = value as? [Any] {
            for child in array {
                collectContinuationTokens(from: child, tokens: &tokens)
            }
        }
    }

    private static func video(fromLockup lockup: [String: Any], channelID: String) -> YTFeedVideo? {
        guard (lockup["contentType"] as? String) == "LOCKUP_CONTENT_TYPE_VIDEO",
              let videoID = lockup["contentId"] as? String
        else { return nil }
        let title = (((lockup["metadata"] as? [String: Any])?["lockupMetadataViewModel"] as? [String: Any])?["title"] as? [String: Any])?["content"] as? String
        return YTFeedVideo(
            id: videoID,
            channelID: channelID,
            title: title?.nilIfEmpty ?? videoID,
            publishedAt: nil,
            updatedAt: nil,
            url: "https://www.youtube.com/watch?v=\(videoID)",
            thumbnail: thumbnailURL(from: lockup)
        )
    }

    private static func video(fromVideoRenderer renderer: [String: Any], channelID: String) -> YTFeedVideo? {
        guard let videoID = renderer["videoId"] as? String else { return nil }
        return YTFeedVideo(
            id: videoID,
            channelID: channelID,
            title: text(from: renderer["title"]) ?? videoID,
            publishedAt: nil,
            updatedAt: nil,
            url: "https://www.youtube.com/watch?v=\(videoID)",
            thumbnail: thumbnailURL(from: renderer)
        )
    }

    private static func videosFromRegex(html: String, channelID: String) -> [YTFeedVideo] {
        guard let regex = try? NSRegularExpression(pattern: #""videoId"\s*:\s*"([A-Za-z0-9_-]{6,})""#) else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var videos: [YTFeedVideo] = []
        var seen: Set<String> = []
        for match in regex.matches(in: html, range: range) {
            guard let swiftRange = Range(match.range(at: 1), in: html) else { continue }
            let videoID = String(html[swiftRange])
            guard seen.insert(videoID).inserted else { continue }
            videos.append(
                YTFeedVideo(
                    id: videoID,
                    channelID: channelID,
                    title: videoID,
                    url: "https://www.youtube.com/watch?v=\(videoID)",
                    thumbnail: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg"
                )
            )
        }
        return videos
    }

    private static func thumbnailURL(from value: [String: Any]) -> String? {
        if let thumbnail = value["thumbnail"] {
            return thumbnailURL(fromAny: thumbnail)
        }
        if let contentImage = value["contentImage"] {
            return thumbnailURL(fromAny: contentImage)
        }
        return nil
    }

    private static func thumbnailURL(fromAny value: Any) -> String? {
        if let dict = value as? [String: Any] {
            if let sources = ((dict["thumbnailViewModel"] as? [String: Any])?["image"] as? [String: Any])?["sources"] as? [[String: Any]] {
                return sources.last?["url"] as? String ?? sources.first?["url"] as? String
            }
            if let thumbnails = (dict["thumbnails"] as? [[String: Any]]) {
                return thumbnails.last?["url"] as? String ?? thumbnails.first?["url"] as? String
            }
            for child in dict.values {
                if let url = thumbnailURL(fromAny: child) { return url }
            }
        }
        if let array = value as? [Any] {
            for child in array {
                if let url = thumbnailURL(fromAny: child) { return url }
            }
        }
        return nil
    }

    private static func text(from value: Any?) -> String? {
        if let dict = value as? [String: Any] {
            if let simpleText = dict["simpleText"] as? String { return simpleText }
            if let runs = dict["runs"] as? [[String: Any]] {
                return runs.compactMap { $0["text"] as? String }.joined().nilIfEmpty
            }
        }
        return nil
    }
}

public struct YTCaptionTrack: Equatable, Sendable {
    public var languageCode: String
    public var name: String
    public var kind: String?
    public var baseURL: String
    public var isTranslatable: Bool
    public var vssID: String?

    public init(
        languageCode: String,
        name: String,
        kind: String? = nil,
        baseURL: String,
        isTranslatable: Bool = false,
        vssID: String? = nil
    ) {
        self.languageCode = languageCode
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.isTranslatable = isTranslatable
        self.vssID = vssID
    }

    /// Stable identity for deduplicating tracks across signed URL rotations.
    public var stableIdentity: String {
        let language = languageCode.lowercased()
        let kindValue = kind ?? ""
        if let vssID, !vssID.isEmpty {
            return [vssID, language, kindValue].joined(separator: "\u{1F}")
        }
        return [
            Self.normalizedBaseURL(baseURL),
            language,
            kindValue
        ].joined(separator: "\u{1F}")
    }

    /// Tracks whose timedtext URL requires a Subs PoToken (`exp=xpe` / `exp=xpv`).
    public var requiresAttestation: Bool {
        guard let components = URLComponents(string: baseURL) else {
            let lowered = baseURL.lowercased()
            return lowered.contains("exp=xpe") || lowered.contains("exp=xpv")
        }
        let exp = components.queryItems?.first(where: { $0.name == "exp" })?.value?.lowercased()
        return exp == "xpe" || exp == "xpv"
    }

    public static func normalizedBaseURL(_ value: String) -> String {
        guard var components = URLComponents(string: value) else { return value }
        let stripped: Set<String> = [
            "expire", "signature", "sig", "ei", "opi", "sparams", "lsig", "alr"
        ]
        components.queryItems = (components.queryItems ?? []).filter { item in
            !stripped.contains(item.name.lowercased())
        }
        if components.queryItems?.isEmpty == true {
            components.queryItems = nil
        }
        return components.string ?? value
    }
}

public enum YTCaptionTrackExtractor {
    public static func captionTracks(fromWatchHTML html: String) throws -> [YTCaptionTrack] {
        let data = try playerResponseJSONData(fromWatchHTML: html)
        return try captionTracks(fromPlayerResponseData: data)
    }

    public static func captionTracks(fromPlayerResponseData data: Data) throws -> [YTCaptionTrack] {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let renderer = ((object?["captions"] as? [String: Any])?["playerCaptionsTracklistRenderer"] as? [String: Any])
        let tracks = renderer?["captionTracks"] as? [[String: Any]] ?? []
        return tracks.compactMap(track(from:))
    }

    public static func innertubeAPIKey(fromWatchHTML html: String) -> String? {
        firstRegexCapture(in: html, patterns: [
            #""INNERTUBE_API_KEY"\s*:\s*"([^"]+)""#,
            #"INNERTUBE_API_KEY['"]?\s*:\s*['"]([^'"]+)['"]"#
        ])
    }

    public static func visitorData(fromWatchHTML html: String) -> String? {
        firstRegexCapture(in: html, patterns: [
            #""VISITOR_DATA"\s*:\s*"([^"]+)""#,
            #""visitorData"\s*:\s*"([^"]+)""#,
            #"VISITOR_DATA['"]?\s*:\s*['"]([^'"]+)['"]"#
        ])
    }

    public static func selectEnglishTrack(from tracks: [YTCaptionTrack]) -> YTCaptionTrack? {
        let english = tracks.filter { $0.languageCode.lowercased().hasPrefix("en") }
        return english.first(where: { $0.kind != "asr" }) ?? english.first
    }

    public static func selectChineseTrack(from tracks: [YTCaptionTrack]) -> YTCaptionTrack? {
        let exactCodes: Set<String> = ["zh", "zh-cn", "zh-hans", "zh-hant"]
        return tracks.first { track in
            let code = track.languageCode.lowercased()
            return exactCodes.contains(code) || track.name.contains("中文") || track.name.localizedCaseInsensitiveContains("Chinese")
        }
    }

    public static func captionURL(for track: YTCaptionTrack, translatedTo languageCode: String? = nil) -> URL? {
        captionURL(for: track, translatedTo: languageCode, format: "vtt")
    }

    public static func captionURL(for track: YTCaptionTrack, translatedTo languageCode: String? = nil, format: String?) -> URL? {
        guard var components = URLComponents(string: track.baseURL) else { return URL(string: track.baseURL) }
        var items = components.queryItems ?? []
        if let format {
            upsertQueryItem(name: "fmt", value: format, items: &items)
        } else {
            items.removeAll { $0.name == "fmt" }
        }
        if let languageCode {
            upsertQueryItem(name: "tlang", value: languageCode, items: &items)
        }
        components.queryItems = items
        return components.url
    }

    private static func playerResponseJSONData(fromWatchHTML html: String) throws -> Data {
        guard let markerRange = html.range(of: "ytInitialPlayerResponse"),
              let objectStart = html[markerRange.upperBound...].firstIndex(of: "{")
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let object = extractJSONObject(from: html, start: objectStart)
        guard let object, let data = object.data(using: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return data
    }

    private static func track(from value: [String: Any]) -> YTCaptionTrack? {
        guard let languageCode = value["languageCode"] as? String,
              let baseURL = value["baseUrl"] as? String
        else { return nil }
        let name = captionName(from: value["name"]) ?? languageCode
        return YTCaptionTrack(
            languageCode: languageCode,
            name: name,
            kind: value["kind"] as? String,
            baseURL: baseURL,
            isTranslatable: value["isTranslatable"] as? Bool ?? false,
            vssID: value["vssId"] as? String
        )
    }

    private static func captionName(from value: Any?) -> String? {
        if let dict = value as? [String: Any] {
            if let text = dict["simpleText"] as? String { return text }
            if let runs = dict["runs"] as? [[String: Any]] {
                return runs.compactMap { $0["text"] as? String }.joined().nilIfEmpty
            }
        }
        return nil
    }

    private static func upsertQueryItem(name: String, value: String, items: inout [URLQueryItem]) {
        if let index = items.firstIndex(where: { $0.name == name }) {
            items[index] = URLQueryItem(name: name, value: value)
        } else {
            items.append(URLQueryItem(name: name, value: value))
        }
    }
}

public struct YTCue: Equatable, Identifiable, Hashable, Codable, Sendable {
    public var id: Int
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(id: Int, start: TimeInterval, end: TimeInterval, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
    }
}

public enum YTSubtitleTranslationStatus: String, Equatable, Sendable {
    case notStarted
    case partial
    case complete
}

public struct YTSubtitleTranslationProgress: Equatable, Sendable {
    public var translatedCount: Int
    public var totalCount: Int

    public init(translatedCount: Int, totalCount: Int) {
        self.translatedCount = max(0, translatedCount)
        self.totalCount = max(0, totalCount)
    }

    public init(segments: [LearningSegment]) {
        self.init(
            translatedCount: segments.filter {
                !$0.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.count,
            totalCount: segments.count
        )
    }

    public var fraction: Double {
        guard totalCount > 0 else { return 0 }
        return min(max(Double(translatedCount) / Double(totalCount), 0), 1)
    }

    public var isComplete: Bool {
        totalCount > 0 && translatedCount >= totalCount
    }

    // Completion is only trustworthy when the denominator equals the English
    // sentence count. A denominator polluted by the first translation batch
    // would otherwise read as "all done" as soon as that batch finishes.
    public func isComplete(expectedSentenceCount: Int) -> Bool {
        isComplete && totalCount == max(0, expectedSentenceCount)
    }

    public func status(expectedSentenceCount: Int) -> YTSubtitleTranslationStatus {
        if isComplete(expectedSentenceCount: expectedSentenceCount) { return .complete }
        return translatedCount > 0 ? .partial : .notStarted
    }
}

/// Builds learning segments from word-level timestamps using punctuation and pause heuristics.
public enum PauseBasedSentenceSegmenter {
    public static let pauseThresholdMS = 700
    public static let maxDurationMS = 7_000
    public static let maxCharacters = 90

    public static func segments(from words: [TranscriptWord]) -> [LearningSegment] {
        guard !words.isEmpty else { return [] }

        var sentences: [[TranscriptWord]] = []
        var current: [TranscriptWord] = []

        func flushCurrent() {
            guard !current.isEmpty else { return }
            for chunk in splitOversized(current) {
                sentences.append(chunk)
            }
            current = []
        }

        for word in words {
            if let last = current.last {
                let gap = word.startMS - last.endMS
                if gap >= pauseThresholdMS {
                    flushCurrent()
                }
            }
            current.append(word)
            if endsSentence(word) {
                flushCurrent()
            }
        }
        flushCurrent()

        return sentences.enumerated().map { index, chunk in
            let text = renderText(chunk)
            return LearningSegment(
                sequence: index + 1,
                startMS: chunk.first?.startMS ?? 0,
                endMS: max(chunk.last?.endMS ?? 0, (chunk.first?.startMS ?? 0) + 1),
                text: text,
                learningText: text,
                words: chunk
            )
        }
    }

    private static func endsSentence(_ word: TranscriptWord) -> Bool {
        guard let punctuation = word.punctuation?.trimmingCharacters(in: .whitespacesAndNewlines),
              !punctuation.isEmpty
        else { return false }
        return punctuation.contains(where: { ".?!…".contains($0) })
    }

    private static func splitOversized(_ words: [TranscriptWord]) -> [[TranscriptWord]] {
        guard let first = words.first, let last = words.last else { return [] }
        let duration = last.endMS - first.startMS
        let characterCount = renderText(words).count
        if duration <= maxDurationMS, characterCount <= maxCharacters {
            return [words]
        }
        guard words.count >= 2 else { return [words] }

        // Split at the largest positive internal pause. Equal/zero/overlapping
        // timings are common in presentation cues, so choose the candidate
        // nearest the midpoint instead of recursively peeling the first word.
        let midpoint = words.count / 2
        let candidates = (1..<words.count).map { index in
            (index: index, gap: words[index].startMS - words[index - 1].endMS)
        }
        let largestPositiveGap = candidates.map(\.gap).filter { $0 > 0 }.max()
        let bestIndex: Int
        if let largestPositiveGap {
            bestIndex = candidates
                .filter { $0.gap == largestPositiveGap }
                .min { abs($0.index - midpoint) < abs($1.index - midpoint) }?
                .index ?? midpoint
        } else {
            bestIndex = midpoint
        }
        let left = Array(words[..<bestIndex])
        let right = Array(words[bestIndex...])
        return splitOversized(left) + splitOversized(right)
    }

    private static func renderText(_ words: [TranscriptWord]) -> String {
        words.map { word in
            if let punctuation = word.punctuation, !punctuation.isEmpty {
                return word.text + punctuation
            }
            return word.text
        }
        .joined(separator: " ")
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct YTCaptionSegmentationQualityReport: Equatable, Sendable {
    public var segmentCount: Int
    public var oneWordRatio: Double
    public var shortDurationRatio: Double
    public var maximumCharactersPerSecond: Double
    /// Segments whose reading speed exceeds the soft CPS threshold.
    public var highCPSOutlierCount: Int
    public var highCPSOutlierRatio: Double
    public var maximumTextLength: Int
    public var oversizedSegmentCount: Int
    public var hasMonotonicTimeline: Bool
    public var isAcceptable: Bool
    /// Human-readable rejection reasons for logs; empty when acceptable.
    public var rejectionReasons: [String]
}

public enum YTCaptionSegmentationQualityPolicy {
    public static let minimumSampleCountForRatioChecks = 20
    public static let maximumOneWordRatio = 0.35
    public static let maximumShortDurationRatio = 0.35
    public static let targetMinimumDurationMS = 800
    public static let absoluteMinimumDurationMS = 100
    /// Soft corruption guard. Segments above this count as CPS outliers; a
    /// small configured share may still be accepted.
    public static let maximumCharactersPerSecond = 80.0
    /// Absolute hard ceiling. Any segment above this rejects the whole track.
    public static let absoluteMaximumCharactersPerSecond = 120.0

    /// Evaluates caption segmentation quality.
    /// - Parameter outlierTolerancePercent: Allowed share of soft CPS outliers
    ///   (0…100 scale, e.g. `1` means 1%). Defaults to `0` so existing callers
    ///   keep the historical strict behavior unless they opt in.
    public static func report(
        for segments: [LearningSegment],
        outlierTolerancePercent: Double = 0
    ) -> YTCaptionSegmentationQualityReport {
        let count = segments.count
        let oneWordCount = segments.filter {
            $0.text.split(whereSeparator: { $0.isWhitespace }).count <= 1
        }.count
        let shortDurationCount = segments.filter {
            $0.endMS - $0.startMS < targetMinimumDurationMS
        }.count
        let oneWordRatio = count > 0 ? Double(oneWordCount) / Double(count) : 0
        let shortDurationRatio = count > 0 ? Double(shortDurationCount) / Double(count) : 0
        let charactersPerSecond = segments.map { segment -> Double in
            let duration = max(0.001, Double(segment.endMS - segment.startMS) / 1_000)
            return Double(segment.text.count) / duration
        }
        let maximumCharactersPerSecond = charactersPerSecond.max() ?? 0
        let highCPSOutlierCount = charactersPerSecond.filter {
            $0 > Self.maximumCharactersPerSecond
        }.count
        let highCPSOutlierRatio = count > 0 ? Double(highCPSOutlierCount) / Double(count) : 0
        let maximumTextLength = segments.map(\.text.count).max() ?? 0
        let oversizedSegmentCount = segments.filter {
            $0.text.count > PauseBasedSentenceSegmenter.maxCharacters
        }.count
        let hasValidDurations = segments.allSatisfy {
            $0.endMS - $0.startMS >= absoluteMinimumDurationMS
                && $0.endMS - $0.startMS <= PauseBasedSentenceSegmenter.maxDurationMS
        }
        let hasMonotonicTimeline = hasValidDurations && zip(segments, segments.dropFirst()).allSatisfy {
            $0.startMS <= $1.startMS && $0.endMS <= $1.startMS
        }
        let hasContent = !segments.isEmpty && segments.allSatisfy {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let ratiosAreAcceptable = count < minimumSampleCountForRatioChecks
            || (oneWordRatio <= maximumOneWordRatio && shortDurationRatio <= maximumShortDurationRatio)
        let lengthsAreAcceptable = oversizedSegmentCount == 0
        let normalizedTolerance = max(0, outlierTolerancePercent) / 100
        let readingSpeedIsAcceptable =
            maximumCharactersPerSecond <= Self.absoluteMaximumCharactersPerSecond
            && highCPSOutlierRatio <= normalizedTolerance

        var rejectionReasons: [String] = []
        if !hasContent { rejectionReasons.append("emptyOrBlankContent") }
        if !hasMonotonicTimeline { rejectionReasons.append("nonMonotonicOrInvalidDuration") }
        if !ratiosAreAcceptable { rejectionReasons.append("fragmentedWordOrShortDurationRatios") }
        if !lengthsAreAcceptable { rejectionReasons.append("oversizedText") }
        if maximumCharactersPerSecond > Self.absoluteMaximumCharactersPerSecond {
            rejectionReasons.append("absoluteCPSExceeded")
        } else if highCPSOutlierRatio > normalizedTolerance {
            rejectionReasons.append("highCPSOutlierRatioExceeded")
        }

        return YTCaptionSegmentationQualityReport(
            segmentCount: count,
            oneWordRatio: oneWordRatio,
            shortDurationRatio: shortDurationRatio,
            maximumCharactersPerSecond: maximumCharactersPerSecond,
            highCPSOutlierCount: highCPSOutlierCount,
            highCPSOutlierRatio: highCPSOutlierRatio,
            maximumTextLength: maximumTextLength,
            oversizedSegmentCount: oversizedSegmentCount,
            hasMonotonicTimeline: hasMonotonicTimeline,
            isAcceptable: hasContent
                && hasMonotonicTimeline
                && ratiosAreAcceptable
                && lengthsAreAcceptable
                && readingSpeedIsAcceptable,
            rejectionReasons: rejectionReasons
        )
    }
}

public enum YTSubtitleCachePolicy {
    /// Saved translations are resumable only when they were produced by the
    /// current subtitle pipeline. Text similarity is not sufficient: a stale
    /// v2 line can have the same English text but the wrong semantic pairing.
    public static func shouldReuseSavedTranslations(localPipelineVersion: Int?) -> Bool {
        SubtitlePipelineVersion.isCurrent(localPipelineVersion)
    }

    /// Simplified Chinese can still be completed from an author track or from
    /// YouTube's opportunistic `tlang=zh-Hans` result when no LLM key exists.
    public static func canGenerateLocallyWithoutTranslationKey(target: TranslationTarget) -> Bool {
        target == .simplifiedChinese
    }

    public static func hasPlayableDualSubtitles(
        englishCues: [YTCue],
        chineseCues: [YTCue],
        savedSegments: [LearningSegment]?
    ) -> Bool {
        guard !englishCues.isEmpty, !chineseCues.isEmpty else { return false }
        // The English sentence count is the authoritative translation unit:
        // rolling ASR cues inflate the raw count and would poison any
        // count-based comparison, so normalize before comparing.
        let englishSentences = YTVTTParser.normalizedSentenceCues(from: englishCues)
        guard !englishSentences.isEmpty else { return false }
        if let savedSegments {
            let translatedCount = savedSegments.filter {
                !$0.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.count
            // A legacy cache can contain authoritative dual VTT files alongside
            // English-only segment metadata. Once generation has written any
            // segment translations, however, require the whole batch to finish.
            if translatedCount == 0 {
                return timelineCoverage(of: englishSentences, by: chineseCues) >= 0.9
            }
            return savedTranslationsComplete(savedSegments, expectedCueCount: englishSentences.count)
        }
        if chineseCues.count >= englishSentences.count {
            return true
        }
        return timelineCoverage(of: englishSentences, by: chineseCues) >= 0.9
    }

    // Complete means every English sentence has a translation: the translated
    // count must equal the segment count AND the segment count must equal the
    // English sentence count. Anything less is partial, never complete.
    public static func savedTranslationsComplete(
        _ segments: [LearningSegment]?,
        expectedCueCount: Int
    ) -> Bool {
        guard let segments, expectedCueCount > 0, segments.count == expectedCueCount else { return false }
        guard Set(segments.map(\.sequence)).count == segments.count else { return false }
        return segments.allSatisfy {
            !$0.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public static func savedTranslationsComplete(
        _ segments: [LearningSegment]?,
        expectedSequences: Set<Int>
    ) -> Bool {
        guard let segments, !expectedSequences.isEmpty else { return false }
        guard Set(segments.map(\.sequence)) == expectedSequences else { return false }
        return segments.allSatisfy {
            !$0.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func timelineCoverage(of englishCues: [YTCue], by chineseCues: [YTCue]) -> Double {
        let totalDuration = englishCues.reduce(0) { $0 + max(0, $1.end - $1.start) }
        guard totalDuration > 0 else { return 0 }
        let coveredDuration = englishCues.reduce(0) { partial, english in
            partial + chineseCues.reduce(0) { cuePartial, chinese in
                cuePartial + max(0, min(english.end, chinese.end) - max(english.start, chinese.start))
            }
        }
        return min(max(coveredDuration / totalDuration, 0), 1)
    }
}

public enum YTVTTParser {
    private struct CaptionAtom {
        var text: String
        var startMS: Int
        var displayEndMS: Int
    }

    private struct CaptionEvent {
        /// The authoritative source cue: every `segs[].utf8` fragment from one
        /// JSON3 event is joined before any rolling-text normalization.
        var text: String
        var startMS: Int
        var displayEndMS: Int
        /// Optional first-appearance markers used only as later semantic
        /// boundary hints. They are not independent source cues.
        var startHints: [CaptionAtom]
    }

    public static func parse(_ text: String) -> [YTCue] {
        let blocks = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n\n")
        var cues: [YTCue] = []
        for block in blocks {
            let lines = block
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !lines.isEmpty, !lines[0].uppercased().hasPrefix("WEBVTT") else { continue }
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2 else { continue }
            let body = lines.dropFirst(timingIndex + 1).joined(separator: " ")
            let cue = YTCue(
                id: cues.count + 1,
                start: parseTimestamp(parts[0]),
                end: parseTimestamp(parts[1]),
                text: cleanCueText(body)
            )
            if !cue.text.isEmpty {
                cues.append(cue)
            }
        }
        return cues
    }

    public static func makeVTT(from cues: [YTCue]) -> String {
        var lines = ["WEBVTT", ""]
        for cue in cues {
            lines.append(String(cue.id))
            lines.append("\(formatTimestamp(cue.start)) --> \(formatTimestamp(cue.end))")
            lines.append(cue.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    public static func learningSegments(from cues: [YTCue]) -> [LearningSegment] {
        normalizedSentenceCues(from: cues).enumerated().map { index, cue in
            let startMS = Int((cue.start * 1000).rounded())
            let rawEndMS = Int((cue.end * 1000).rounded())
            return LearningSegment(
                sequence: index + 1,
                startMS: startMS,
                endMS: max(
                    startMS + 1,
                    min(rawEndMS, startMS + PauseBasedSentenceSegmenter.maxDurationMS)
                ),
                text: cue.text,
                learningText: cue.text,
                // VTT/XML cue sources carry no word-level timing; mark them legacy so the
                // freshness/upgrade policy can distinguish them from precise JSON3 builds.
                timingSource: .legacy
            )
        }
    }

    /// Caption-ingestion path for YouTube cue/VTT/XML fallbacks only.
    /// Oversized cues (>90 characters) are split at punctuation or word boundaries when
    /// each resulting slice can keep ≥100ms without overlapping. Unsafe splits keep the
    /// original cue so quality policy can reject it. Healthy cues match `learningSegments`.
    public static func captionIngestionSegments(from cues: [YTCue]) -> [LearningSegment] {
        var result: [LearningSegment] = []
        for segment in learningSegments(from: cues) {
            if let split = safelySplitOversizedIngestionSegment(segment) {
                result.append(contentsOf: split)
            } else {
                result.append(segment)
            }
        }
        return result.enumerated().map { index, segment in
            var copy = segment
            copy.sequence = index + 1
            return copy
        }
    }

    /// Attempts to split one oversized legacy cue across its original time window.
    /// Returns `nil` when the cue is already within limits or cannot be split safely.
    private static func safelySplitOversizedIngestionSegment(
        _ segment: LearningSegment
    ) -> [LearningSegment]? {
        guard segment.text.count > PauseBasedSentenceSegmenter.maxCharacters else { return nil }
        let chunks = balancedTextChunks(segment.text)
        guard chunks.count > 1 else { return nil }

        let minDuration = YTCaptionSegmentationQualityPolicy.absoluteMinimumDurationMS
        let duration = segment.endMS - segment.startMS
        guard duration >= chunks.count * minDuration else { return nil }

        let totalCharacters = chunks.reduce(0) { $0 + $1.count }
        guard totalCharacters > 0 else { return nil }

        var parts: [LearningSegment] = []
        var cursor = segment.startMS
        for (index, chunk) in chunks.enumerated() {
            let remainingAfter = chunks.count - index - 1
            let endMS: Int
            if remainingAfter == 0 {
                endMS = segment.endMS
            } else {
                let proportional = Int(
                    (Double(duration) * Double(chunk.count) / Double(totalCharacters)).rounded()
                )
                let latestEnd = segment.endMS - remainingAfter * minDuration
                endMS = min(
                    max(cursor + max(proportional, minDuration), cursor + minDuration),
                    latestEnd
                )
            }
            guard endMS - cursor >= minDuration, endMS <= segment.endMS else { return nil }
            guard chunk.count <= PauseBasedSentenceSegmenter.maxCharacters else { return nil }
            parts.append(
                LearningSegment(
                    sequence: 0,
                    startMS: cursor,
                    endMS: endMS,
                    text: chunk,
                    learningText: chunk,
                    timingSource: segment.timingSource
                )
            )
            cursor = endMS
        }

        guard parts.first?.startMS == segment.startMS,
              parts.last?.endMS == segment.endMS,
              zip(parts, parts.dropFirst()).allSatisfy({ $0.endMS <= $1.startMS }),
              parts.map(\.text).joined(separator: " ") == segment.text
        else {
            return nil
        }
        return parts
    }

    /// Builds stable semantic learning units from YouTube JSON3 presentation
    /// cues. Event duration is deliberately treated as display lifetime; only
    /// segment offsets provide text start markers.
    public static func learningSegmentsFromYouTubeJSON3(_ json: String) -> [LearningSegment] {
        // Preferred path: build a deduped word stream (one timed entry per json3 seg), then cut
        // sentences from it. This yields word-precise, monotonic segment timing with populated
        // `words` for downstream [br] re-segmentation and display-splitting. A single coarse
        // atom (a multiword seg with no per-word timing) cannot be segmented into word-timed
        // sentences, so fall through to the atom path which can text-split it.
        let wordStream = preciseWordStreamFromYouTubeJSON3(json)
        if wordStream.count > 1 {
            let segments = PauseBasedSentenceSegmenter.segments(from: wordStream)
            if segments.count > 1 {
                return segments.map { segment in
                    var copy = segment
                    copy.timingSource = .wordTimeline
                    return copy
                }
            }
        }
        // Fallback: the atom-based semantic grouping with balanced text-splitting (handles
        // coarse single-atom input and rolling-caption edge cases).
        let hintedAtoms = captionAtomsFromYouTubeJSON3(json)
        return semanticLearningSegments(from: expandedOversizedAtoms(hintedAtoms))
    }

    private static func captionAtomsFromYouTubeJSON3(_ json: String) -> [CaptionAtom] {
        let events = captionEventsFromYouTubeJSON3(json)
        guard !events.isEmpty else { return [] }

        var result: [CaptionAtom] = []
        var historyWords: [String] = []
        var previousDisplayEndMS: Int?

        for event in events {
            let eventWords = words(in: event.text)
            guard !eventWords.isEmpty else { continue }
            let isNearby = previousDisplayEndMS.map {
                event.startMS - $0 <= 3_000
            } ?? false
            let overlap = isNearby ? wordOverlap(prior: historyWords, current: eventWords) : 0
            var wordsToSkip = overlap

            for atom in event.startHints {
                let atomWords = words(in: atom.text)
                guard !atomWords.isEmpty else { continue }
                if wordsToSkip >= atomWords.count {
                    wordsToSkip -= atomWords.count
                    continue
                }
                let retainedWords = atomWords.dropFirst(wordsToSkip)
                wordsToSkip = 0
                guard !retainedWords.isEmpty else { continue }
                result.append(
                    CaptionAtom(
                        text: retainedWords.joined(separator: " "),
                        startMS: atom.startMS,
                        displayEndMS: atom.displayEndMS
                    )
                )
            }

            if !isNearby {
                historyWords = []
            }
            historyWords.append(contentsOf: eventWords.dropFirst(overlap))
            if historyWords.count > 120 {
                historyWords.removeFirst(historyWords.count - 120)
            }
            previousDisplayEndMS = max(previousDisplayEndMS ?? 0, event.displayEndMS)
        }
        return result.sorted { ($0.startMS, $0.displayEndMS) < ($1.startMS, $1.displayEndMS) }
    }

    private static func captionEventsFromYouTubeJSON3(_ json: String) -> [CaptionEvent] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawEvents = object["events"] as? [[String: Any]]
        else {
            return []
        }

        return rawEvents.compactMap { event in
            guard let eventStart = doubleValue(event["tStartMs"]),
                  let segments = event["segs"] as? [[String: Any]]
            else { return nil }
            let eventStartMS = Int(eventStart.rounded())
            let durationMS = max(1, Int((doubleValue(event["dDurationMs"]) ?? 2_000).rounded()))
            let displayEndMS = eventStartMS + durationMS
            var atoms: [CaptionAtom] = []

            for segment in segments {
                guard let rawText = segment["utf8"] as? String else { continue }
                let text = cleanCueText(rawText.replacingOccurrences(of: "\n", with: " "))
                guard !text.isEmpty else { continue }
                if let offset = doubleValue(segment["tOffsetMs"]) {
                    let startMS = eventStartMS + Int(offset.rounded())
                    if let lastIndex = atoms.indices.last, atoms[lastIndex].startMS == startMS {
                        atoms[lastIndex].text = joinCaptionText(atoms[lastIndex].text, text)
                    } else {
                        atoms.append(
                            CaptionAtom(
                                text: text,
                                startMS: startMS,
                                displayEndMS: displayEndMS
                            )
                        )
                    }
                } else if atoms.isEmpty {
                    atoms.append(CaptionAtom(text: text, startMS: eventStartMS, displayEndMS: displayEndMS))
                } else {
                    atoms[atoms.index(before: atoms.endIndex)].text = joinCaptionText(
                        atoms[atoms.index(before: atoms.endIndex)].text,
                        text
                    )
                }
            }
            guard !atoms.isEmpty else { return nil }
            let eventText = atoms.map(\.text).reduce("") { joinCaptionText($0, $1) }
            return CaptionEvent(
                text: eventText,
                startMS: eventStartMS,
                displayEndMS: displayEndMS,
                startHints: atoms
            )
        }
    }

    /// Force-split a single oversized cue at a word boundary nearest its text
    /// midpoint. The assigned starts divide only that cue's bounded display
    /// window; they are semantic segment boundaries, never word speech ends.
    private static func expandedOversizedAtoms(_ atoms: [CaptionAtom]) -> [CaptionAtom] {
        var result: [CaptionAtom] = []
        for index in atoms.indices {
            let atom = atoms[index]
            let chunks = balancedTextChunks(atom.text)
            guard chunks.count > 1 else {
                result.append(atom)
                continue
            }
            let nextStartMS = atoms[(index + 1)...].first(where: { $0.startMS > atom.startMS })?.startMS
            let horizonMS = min(
                nextStartMS ?? atom.displayEndMS,
                atom.startMS + PauseBasedSentenceSegmenter.maxDurationMS
            )
            let availableMS = max(chunks.count, horizonMS - atom.startMS)
            for chunkIndex in chunks.indices {
                result.append(
                    CaptionAtom(
                        text: chunks[chunkIndex],
                        startMS: atom.startMS + availableMS * chunkIndex / chunks.count,
                        displayEndMS: max(atom.displayEndMS, atom.startMS + availableMS)
                    )
                )
            }
        }
        return result
    }

    private static func balancedTextChunks(_ text: String) -> [String] {
        let normalized = cleanCueText(text)
        guard normalized.count > PauseBasedSentenceSegmenter.maxCharacters else { return [normalized] }
        let tokens = words(in: normalized)
        guard tokens.count >= 2 else { return [normalized] }

        let target = normalized.count / 2
        let boundaries = 1..<tokens.count
        let punctuationBoundaries = boundaries.filter { index in
            tokens[index - 1].last.map { ".?!…,;:".contains($0) } ?? false
        }
        let candidates = punctuationBoundaries.isEmpty ? Array(boundaries) : punctuationBoundaries
        let splitIndex = candidates.min { lhs, rhs in
            let lhsDistance = abs(tokens[..<lhs].joined(separator: " ").count - target)
            let rhsDistance = abs(tokens[..<rhs].joined(separator: " ").count - target)
            return lhsDistance < rhsDistance
        } ?? tokens.count / 2
        let left = tokens[..<splitIndex].joined(separator: " ")
        let right = tokens[splitIndex...].joined(separator: " ")
        return balancedTextChunks(left) + balancedTextChunks(right)
    }

    private static func semanticLearningSegments(from atoms: [CaptionAtom]) -> [LearningSegment] {
        guard !atoms.isEmpty else { return [] }
        var groups: [[CaptionAtom]] = []
        var current: [CaptionAtom] = []

        func flush() {
            guard !current.isEmpty else { return }
            groups.append(current)
            current = []
        }

        for atom in atoms {
            if let first = current.first, let previous = current.last {
                let proposedText = joinCaptionText(current.map(\.text).joined(separator: " "), atom.text)
                let durationMS = atom.startMS - first.startMS
                let startGapMS = atom.startMS - previous.startMS
                if durationMS > PauseBasedSentenceSegmenter.maxDurationMS
                    || proposedText.count > PauseBasedSentenceSegmenter.maxCharacters
                    || startGapMS >= 1_600 {
                    flush()
                }
            }

            current.append(atom)
            let text = current.map(\.text).joined(separator: " ")
            let wordCount = words(in: text).count
            if endsSentence(atom.text) || (endsClause(atom.text) && wordCount >= 4) {
                flush()
            }
        }
        flush()

        return groups.enumerated().map { index, group in
            let startMS = group.first?.startMS ?? 0
            let nextStartMS = index + 1 < groups.count ? groups[index + 1].first?.startMS : nil
            let rawEndMS = group.map(\.displayEndMS).max() ?? (startMS + 1)
            let boundedEndMS = min(rawEndMS, startMS + PauseBasedSentenceSegmenter.maxDurationMS)
            let endMS = max(startMS + 1, min(nextStartMS ?? boundedEndMS, boundedEndMS))
            let text = group.map(\.text).reduce("") { joinCaptionText($0, $1) }
            return LearningSegment(
                sequence: index + 1,
                startMS: startMS,
                endMS: endMS,
                text: text,
                learningText: text,
                // JSON3 presentation cues provide per-fragment offsets (the closest thing to
                // a word stream YouTube offers), so segments from this path are treated as
                // word-timeline precise rather than legacy cue timing.
                timingSource: .wordTimeline
            )
        }
    }

    private static func endsSentence(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).last.map { ".?!…".contains($0) } ?? false
    }

    private static func endsClause(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).last.map { ",;:".contains($0) } ?? false
    }

    private static func words(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func joinCaptionText(_ lhs: String, _ rhs: String) -> String {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        return left + " " + right
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    // Normalizes raw caption cues so each English word appears once, preserving
    // real cue timestamps.
    //
    // YouTube ASR tracks emit a rolling window: each cue repeats the previous
    // text and appends a fragment, so the same sentence is shown many times. We
    // stitch the cues word-by-word (each adjacent pair shares an overlapping
    // word run), keeping every cue's own start time and assigning its end to the
    // next emitted cue's start. A cue that contributes no new words (an exact
    // rolling continuation) is dropped.
    //
    // Already-clean tracks (manual captions: punctuated, non-overlapping) pass
    // through unchanged apart from re-numbering, so their timing is preserved.
    public static func normalizedSentenceCues(from cues: [YTCue]) -> [YTCue] {
        let sorted = cues
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        guard !sorted.isEmpty else { return [] }

        // Rolling-window collapse. `window` holds the current run's words and its
        // start time. A cue that extends the window (overlaps it) or is contained
        // in it is folded in — no new cue is emitted. A cue that shares no words
        // with the window starts a new run, so clean (non-overlapping) captions
        // and genuine topic changes are preserved verbatim with their own times.
        var window: [String] = []
        var windowStart: TimeInterval = 0
        var windowOriginalEnd: TimeInterval = 0
        var lastEnd: TimeInterval = 0
        var keptWords: [[String]] = []
        var keptStart: [TimeInterval] = []
        var keptOriginalEnd: [TimeInterval] = []

        func flushWindow() {
            guard !window.isEmpty else { return }
            keptWords.append(window)
            keptStart.append(windowStart)
            keptOriginalEnd.append(windowOriginalEnd)
        }

        for cue in sorted {
            let words = cue.text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
            guard !words.isEmpty else { continue }
            if window.isEmpty {
                window = words
                windowStart = cue.start
                windowOriginalEnd = cue.end
                lastEnd = cue.end
                continue
            }
            // A long gap forces a new run even if words happen to repeat.
            let overlap = (cue.start - lastEnd) <= 3.0 ? wordOverlap(prior: window, current: words) : 0
            if overlap > 0 {
                window += words.dropFirst(overlap)
                windowOriginalEnd = max(windowOriginalEnd, cue.end)
            } else {
                flushWindow()
                window = words
                windowStart = cue.start
                windowOriginalEnd = cue.end
            }
            lastEnd = max(lastEnd, cue.end)
        }
        flushWindow()
        guard !keptWords.isEmpty else { return [] }

        // Rebuild cues: each kept slice spans from its own start to the next
        // slice's start (the last keeps its original end).
        var result: [YTCue] = []
        for index in keptWords.indices {
            let start = keptStart[index]
            let end = index + 1 < keptWords.count
                ? max(keptStart[index + 1], start + 0.001)
                : max(keptOriginalEnd[index], start + 0.001)
            result.append(
                YTCue(id: result.count + 1, start: start, end: end, text: keptWords[index].joined(separator: " "))
            )
        }
        return result
    }

    // Largest overlap between the tail of `prior` and the head of `current`,
    // requiring the shorter side to match fully. Words are compared with
    // punctuation stripped and case folded, because rolling ASR revises
    // punctuation/capitalization as more speech arrives ("brown" -> "brown,").
    private static func wordOverlap(prior: [String], current: [String]) -> Int {
        let maxOverlap = min(prior.count, current.count)
        for length in stride(from: maxOverlap, through: 1, by: -1) {
            let tail = prior.suffix(length).map(normalizedWord)
            let head = current.prefix(length).map(normalizedWord)
            if tail == head {
                return length
            }
        }
        return 0
    }

    private static func normalizedWord(_ word: String) -> String {
        let stripped = word.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"'()[]"))
        return stripped.isEmpty ? word.lowercased() : stripped.lowercased()
    }

    public static func cues(from segments: [LearningSegment]) -> [YTCue] {
        segments.map { segment in
            YTCue(
                id: segment.sequence,
                start: TimeInterval(segment.startMS) / 1000,
                end: TimeInterval(segment.endMS) / 1000,
                text: segment.translation.nilIfEmpty ?? segment.text
            )
        }
    }

    public static func sourceCues(from segments: [LearningSegment]) -> [YTCue] {
        segments.map { segment in
            YTCue(
                id: segment.sequence,
                start: TimeInterval(segment.startMS) / 1_000,
                end: TimeInterval(segment.endMS) / 1_000,
                text: segment.text
            )
        }
    }

    public static func translatedCues(from segments: [LearningSegment]) -> [YTCue] {
        segments.compactMap { segment in
            let text = segment.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return YTCue(
                id: segment.sequence,
                start: TimeInterval(segment.startMS) / 1_000,
                end: TimeInterval(segment.endMS) / 1_000,
                text: text
            )
        }
    }

    /// Result of mapping a native (YouTube) translation track onto English segments.
    public struct NativeCaptionAlignment: Equatable, Sendable {
        public var segments: [LearningSegment]
        public var score: Double
        public var isAccepted: Bool

        /// Minimum share of English segments that must receive an exclusive, dominant
        /// overlapping native cue before the native track is trusted.
        public static let acceptanceThreshold = 0.85
        /// Overlap must cover at least this fraction of the English segment duration.
        public static let dominantOverlapRatio = 0.5

        public init(segments: [LearningSegment], score: Double, isAccepted: Bool) {
            self.segments = segments
            self.score = score
            self.isAccepted = isAccepted
        }
    }

    public static func applyingTranslations(from translatedCues: [YTCue], to segments: [LearningSegment]) -> [LearningSegment] {
        alignNativeTranslations(from: translatedCues, to: segments).segments
    }

    /// Map native translation cues onto English segments and score alignment quality.
    ///
    /// Score = share of English segments that received an exclusive (cue not shared with
    /// another segment) and dominant (overlap ≥ 50% of segment duration) native cue.
    public static func alignNativeTranslations(
        from translatedCues: [YTCue],
        to segments: [LearningSegment],
        acceptanceThreshold: Double = NativeCaptionAlignment.acceptanceThreshold
    ) -> NativeCaptionAlignment {
        guard !translatedCues.isEmpty, !segments.isEmpty else {
            return NativeCaptionAlignment(segments: segments, score: 0, isAccepted: false)
        }

        var translatedSegments = segments
        var cuesBySegment: [Int: [YTCue]] = [:]
        let usableCues = translatedCues
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }

        // Assign each native cue globally to its one dominant English owner.
        // This lets one English semantic unit collect several shorter native
        // cues without duplicating a long cue across multiple English units.
        for cue in usableCues {
            let matches = segments.indices.compactMap { index -> (Int, TimeInterval)? in
                let overlap = overlapDuration(segment: segments[index], cue: cue)
                return overlap > 0 ? (index, overlap) : nil
            }
            guard let best = matches.max(by: { $0.1 < $1.1 }) else { continue }
            let tiedBestCount = matches.filter { abs($0.1 - best.1) < 0.001 }.count
            let cueDuration = max(0.001, cue.end - cue.start)
            guard tiedBestCount == 1, best.1 / cueDuration > 0.5 else { continue }
            cuesBySegment[best.0, default: []].append(cue)
        }

        var exclusiveDominantCount = 0
        for index in translatedSegments.indices {
            let ownedCues = cuesBySegment[index] ?? []
            guard !ownedCues.isEmpty else { continue }
            let downloadedTranslation = mergedTranslationText(from: ownedCues)
            if translatedSegments[index].translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                translatedSegments[index].translation = downloadedTranslation
            }
            let duration = max(
                0.001,
                TimeInterval(translatedSegments[index].endMS - translatedSegments[index].startMS) / 1_000
            )
            let coverage = coveredDuration(of: translatedSegments[index], by: ownedCues)
            if coverage >= duration * NativeCaptionAlignment.dominantOverlapRatio {
                exclusiveDominantCount += 1
            }
        }

        let score = Double(exclusiveDominantCount) / Double(translatedSegments.count)
        return NativeCaptionAlignment(
            segments: translatedSegments,
            score: score,
            isAccepted: score >= acceptanceThreshold
        )
    }

    private static func coveredDuration(of segment: LearningSegment, by cues: [YTCue]) -> TimeInterval {
        let segmentStart = TimeInterval(segment.startMS) / 1_000
        let segmentEnd = TimeInterval(segment.endMS) / 1_000
        let intervals = cues.compactMap { cue -> (TimeInterval, TimeInterval)? in
            let start = max(segmentStart, cue.start)
            let end = min(segmentEnd, cue.end)
            return end > start ? (start, end) : nil
        }
        .sorted { $0.0 < $1.0 }
        guard var current = intervals.first else { return 0 }
        var total: TimeInterval = 0
        for interval in intervals.dropFirst() {
            if interval.0 <= current.1 {
                current.1 = max(current.1, interval.1)
            } else {
                total += current.1 - current.0
                current = interval
            }
        }
        return total + current.1 - current.0
    }

    private static func mergedTranslationText(from cues: [YTCue]) -> String {
        cues.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
            .map(\.text)
            .reduce("") { accumulated, next in
                let left = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
                let right = next.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !left.isEmpty else { return right }
                guard !right.isEmpty else { return left }
                let leftCharacters = Array(left)
                let rightCharacters = Array(right)
                let maximumOverlap = min(leftCharacters.count, rightCharacters.count)
                var overlap = 0
                if maximumOverlap >= 2 {
                    for length in stride(from: maximumOverlap, through: 2, by: -1)
                    where Array(leftCharacters.suffix(length)) == Array(rightCharacters.prefix(length)) {
                        overlap = length
                        break
                    }
                }
                let suffix = String(rightCharacters.dropFirst(overlap))
                guard !suffix.isEmpty else { return left }
                let needsSpace = left.last?.isASCII == true
                    && right.first?.isASCII == true
                    && left.last?.isWhitespace != true
                    && right.first?.isWhitespace != true
                return left + (needsSpace ? " " : "") + suffix
            }
    }

    private static func overlaps(segment: LearningSegment, cue: YTCue) -> Bool {
        overlapDuration(segment: segment, cue: cue) > 0
    }

    private static func overlapDuration(segment: LearningSegment, cue: YTCue) -> TimeInterval {
        let start = TimeInterval(segment.startMS) / 1000
        let end = TimeInterval(segment.endMS) / 1000
        return max(0, min(end, cue.end) - max(start, cue.start))
    }

    public static func vttFromYouTubeXML(_ xml: String) -> String {
        let cues = YouTubeCaptionXMLParser().parse(xml)
        return makeVTT(from: cues)
    }

    public static func vttFromYouTubeJSON3(_ json: String) -> String {
        makeVTT(from: cuesFromYouTubeJSON3(json))
    }

    /// Parse YouTube json3 caption payloads into cue-level VTT-compatible units.
    public static func cuesFromYouTubeJSON3(_ json: String) -> [YTCue] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = object["events"] as? [[String: Any]]
        else {
            return []
        }

        var cues: [YTCue] = []
        for event in events {
            guard let startMS = event["tStartMs"] as? Double,
                  let segments = event["segs"] as? [[String: Any]]
            else { continue }
            let text = segments
                .compactMap { $0["utf8"] as? String }
                .joined()
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let durationMS = event["dDurationMs"] as? Double ?? 2_000
            cues.append(
                YTCue(
                    id: cues.count + 1,
                    start: startMS / 1000,
                    end: (startMS + max(durationMS, 500)) / 1000,
                    text: cleanCueText(text)
                )
            )
        }
        return cues
    }

    /// Extract timed text atoms from YouTube json3 `segs` + `tOffsetMs`.
    /// A multiword seg remains one atom because its individual word starts are
    /// unknown. Event duration is never used as the final atom's speech end.
    public static func wordsFromYouTubeJSON3(_ json: String) -> [TranscriptWord] {
        let atoms = captionAtomsFromYouTubeJSON3(json)
        return atoms.indices.compactMap { index in
            let atom = atoms[index]
            let nextStartMS = index + 1 < atoms.count ? atoms[index + 1].startMS : nil
            let fallbackEndMS = atom.startMS + 200
            let endMS = max(atom.startMS + 1, nextStartMS ?? fallbackEndMS)
            let (text, punctuation) = splitTrailingPunctuation(atom.text)
            guard !text.isEmpty else { return nil }
            return TranscriptWord(
                text: text,
                startMS: atom.startMS,
                endMS: endMS,
                punctuation: punctuation
            )
        }
    }

    /// Build a deduped word-level stream straight from json3 `segs`. Single-word timed segs
    /// (carrying `tOffsetMs`) yield per-word start times, so they become individual stream
    /// entries; a multiword seg stays one entry because its per-word starts are unknown.
    /// Rolling-caption overlap with the previous event is removed so the stream reads as the
    /// final caption text, and end times are derived from the next entry's start so
    /// `PauseBasedSentenceSegmenter` can measure pauses. This is the word stream the plan
    /// requires before sentence building.
    public static func preciseWordStreamFromYouTubeJSON3(_ json: String) -> [TranscriptWord] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawEvents = object["events"] as? [[String: Any]]
        else {
            return []
        }

        var result: [TranscriptWord] = []
        var historyWords: [String] = []
        var previousDisplayEndMS: Int?

        for event in rawEvents {
            guard let eventStart = doubleValue(event["tStartMs"]),
                  let segments = event["segs"] as? [[String: Any]]
            else { continue }
            let eventStartMS = Int(eventStart.rounded())
            let durationMS = max(1, Int((doubleValue(event["dDurationMs"]) ?? 2_000).rounded()))
            let displayEndMS = eventStartMS + durationMS

            let eventText = segments
                .compactMap { $0["utf8"] as? String }
                .map { cleanCueText($0.replacingOccurrences(of: "\n", with: " ")) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let eventWords = words(in: eventText)
            guard !eventWords.isEmpty else { continue }

            let isNearby = previousDisplayEndMS.map { eventStartMS - $0 <= 3_000 } ?? false
            var wordsToSkip = isNearby ? wordOverlap(prior: historyWords, current: eventWords) : 0

            for segment in segments {
                guard let rawText = segment["utf8"] as? String else { continue }
                let text = cleanCueText(rawText.replacingOccurrences(of: "\n", with: " "))
                let segWords = words(in: text)
                guard !segWords.isEmpty else { continue }

                // Base time for this seg: its own tOffsetMs if present, else the event start.
                let baseMS = doubleValue(segment["tOffsetMs"]).map { eventStartMS + Int($0.rounded()) } ?? eventStartMS

                // Each seg is one timed stream entry (YouTube's finest timing unit). A single-word
                // seg is one word; a multiword seg stays whole because its per-word starts are
                // unknown. Rolling-caption overlap with the previous event is removed by word count.
                if wordsToSkip >= segWords.count {
                    wordsToSkip -= segWords.count
                    continue
                }
                let retained = segWords.dropFirst(wordsToSkip)
                wordsToSkip = 0
                let joined = retained.joined(separator: " ")
                let (clean, punctuation) = splitTrailingPunctuation(joined)
                guard !clean.isEmpty else { continue }
                result.append(TranscriptWord(text: clean, startMS: baseMS, endMS: baseMS + 1, punctuation: punctuation))
            }

            if !isNearby { historyWords = [] }
            historyWords.append(contentsOf: eventWords.dropFirst(wordOverlap(prior: historyWords, current: eventWords)))
            if historyWords.count > 120 { historyWords.removeFirst(historyWords.count - 120) }
            previousDisplayEndMS = max(previousDisplayEndMS ?? 0, displayEndMS)
        }

        guard !result.isEmpty else { return [] }
        for index in result.indices {
            let nextStart = index + 1 < result.count ? result[index + 1].startMS : nil
            let fallback = result[index].startMS + 200
            result[index].endMS = max(result[index].startMS + 1, nextStart ?? fallback)
        }
        return result
    }

    private static func splitTrailingPunctuation(_ value: String) -> (String, String?) {
        let punctuationSet = CharacterSet(charactersIn: ".?!…")
        var end = value.endIndex
        while end > value.startIndex {
            let previous = value.index(before: end)
            guard value[previous].unicodeScalars.allSatisfy({ punctuationSet.contains($0) }) else { break }
            end = previous
        }
        if end == value.endIndex {
            return (value, nil)
        }
        let word = String(value[..<end])
        let punctuation = String(value[end...])
        return (word, punctuation.isEmpty ? nil : punctuation)
    }

    private static func parseTimestamp(_ value: String) -> TimeInterval {
        let cleaned = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .first
            .map(String.init)?
            .replacingOccurrences(of: ",", with: ".") ?? ""
        let parts = cleaned.split(separator: ":")
        guard parts.count == 3 else { return 0 }
        let secondParts = parts[2].split(separator: ".")
        let seconds = Double(secondParts.first ?? "0") ?? 0
        let millis = secondParts.count > 1 ? (Double(secondParts[1]) ?? 0) / pow(10, Double(secondParts[1].count)) : 0
        return (Double(parts[0]) ?? 0) * 3600 + (Double(parts[1]) ?? 0) * 60 + seconds + millis
    }

    private static func formatTimestamp(_ value: TimeInterval) -> String {
        let totalMilliseconds = max(0, Int((value * 1000).rounded()))
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds % 3_600_000) / 60_000
        let seconds = (totalMilliseconds % 60_000) / 1000
        let milliseconds = totalMilliseconds % 1000
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, milliseconds)
    }

    private static func cleanCueText(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum YTStreamSelectionPolicy: Sendable, Equatable {
    // Highest playable quality, ignoring any cap.
    case highestQuality
    // Highest playable quality whose height does not exceed `maxHeight` (falls back to the
    // lowest available playable format when nothing is at or below the cap).
    case preferred(maxHeight: Int)
    // Data-saving / maximum-compatibility path (legacy combined itag-18 style MP4).
    case legacyCompatible

    // MARK: Quality-tier convenience

    // Ordered list of selectable quality tiers exposed to the player UI.
    public static let qualityTierOptions: [Self] = [
        .highestQuality,
        .preferred(maxHeight: 2160),
        .preferred(maxHeight: 1440),
        .preferred(maxHeight: 1080),
        .preferred(maxHeight: 720),
        .preferred(maxHeight: 480),
        .preferred(maxHeight: 360),
        .legacyCompatible
    ]

    // Stable string used to persist the user's choice in settings.
    public var storedRawValue: String {
        switch self {
        case .highestQuality: "highest"
        case .preferred(let maxHeight): "max\(maxHeight)"
        case .legacyCompatible: "compatible"
        }
    }

    // Parses `storedRawValue`; returns nil for unknown values so callers can fall back.
    public init?(storedRawValue: String) {
        switch storedRawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "highest", "auto":
            self = .highestQuality
        case "compatible", "legacy", "legacycompatible", "data-saver", "datasaver":
            self = .legacyCompatible
        default:
            guard storedRawValue.lowercased().hasPrefix("max"),
                  let height = Int(storedRawValue.lowercased().dropFirst(3)),
                  height > 0
            else { return nil }
            self = .preferred(maxHeight: height)
        }
    }

    // Short English label for the player quality menu (height-based tiers read naturally).
    public var menuTitle: String {
        switch self {
        case .highestQuality: "Auto (Highest)"
        case .preferred(let maxHeight): "\(maxHeight)p"
        case .legacyCompatible: "Data Saver"
        }
    }

    /// Whether this policy is a user-fixed quality (not auto).
    public var isManualFixedQuality: Bool {
        switch self {
        case .highestQuality:
            false
        case .preferred, .legacyCompatible:
            true
        }
    }
}

public enum YTStreamFormatSelector {
    public static func selectURL(from formats: [[String: Any]], policy: YTStreamSelectionPolicy) -> URL? {
        switch policy {
        case .legacyCompatible:
            return legacyCompatibleURL(from: formats)
        case .highestQuality:
            return highestQualityURL(from: formats) ?? legacyCompatibleURL(from: formats)
        case .preferred(let maxHeight):
            return preferredQualityURL(from: formats, maxHeight: maxHeight)
                ?? highestQualityURL(from: formats)
                ?? legacyCompatibleURL(from: formats)
        }
    }

    private static func legacyCompatibleURL(from formats: [[String: Any]]) -> URL? {
        let mp4Formats = formats.filter(isMP4Video)
        let preferred = mp4Formats.first { ($0["itag"] as? Int) == 18 }
            ?? mp4Formats.first
            ?? formats.first
        return url(from: preferred)
    }

    private static func highestQualityURL(from formats: [[String: Any]]) -> URL? {
        let mp4Formats = formats.filter(isMP4Video)
        let playableFormats = mp4Formats.filter(hasAudioAndVideo)
        return (playableFormats.isEmpty ? mp4Formats : playableFormats)
            .max { lhs, rhs in
                qualityScore(lhs) < qualityScore(rhs)
            }
            .flatMap(url)
    }

    // Picks the highest-quality playable MP4 at or below `maxHeight`. When no format fits the
    // cap, picks the lowest-quality playable MP4 (closest to the cap from below is impossible,
    // so the smallest stream is the least-wasteful choice). Returns nil when there is no MP4.
    private static func preferredQualityURL(from formats: [[String: Any]], maxHeight: Int) -> URL? {
        let mp4Formats = formats.filter(isMP4Video)
        let playableFormats = mp4Formats.filter(hasAudioAndVideo)
        let candidates = playableFormats.isEmpty ? mp4Formats : playableFormats
        guard !candidates.isEmpty else { return nil }
        let withinCap = candidates.filter { intValue($0["height"]) > 0 && intValue($0["height"]) <= maxHeight }
        if let best = withinCap.max(by: { qualityScore($0) < qualityScore($1) }) {
            return url(from: best)
        }
        // Nothing at or below the cap: choose the smallest stream rather than blowing the budget.
        return candidates
            .min { lhs, rhs in qualityScore(lhs) < qualityScore(rhs) }
            .flatMap(url)
    }

    private static func isMP4Video(_ format: [String: Any]) -> Bool {
        (format["mimeType"] as? String)?.contains("video/mp4") == true && url(from: format) != nil
    }

    private static func hasAudioAndVideo(_ format: [String: Any]) -> Bool {
        guard let mimeType = format["mimeType"] as? String else { return false }
        return mimeType.contains("mp4a") || format["audioQuality"] != nil || format["audioSampleRate"] != nil
    }

    private static func qualityScore(_ format: [String: Any]) -> (Int, Int, Int, Int) {
        (
            intValue(format["height"]),
            intValue(format["width"]),
            intValue(format["bitrate"]),
            intValue(format["fps"])
        )
    }

    private static func intValue(_ value: Any?) -> Int {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let string = value as? String { return Int(string) ?? 0 }
        return 0
    }

    private static func url(from format: [String: Any]?) -> URL? {
        guard let stream = format?["url"] as? String else { return nil }
        return URL(string: stream)
    }
}

private final class YouTubeCaptionXMLParser: NSObject, XMLParserDelegate {
    private var cues: [YTCue] = []
    private var currentText = ""
    private var currentStart: TimeInterval?
    private var currentDuration: TimeInterval?

    func parse(_ xml: String) -> [YTCue] {
        cues = []
        currentText = ""
        currentStart = nil
        currentDuration = nil
        guard let data = xml.data(using: .utf8) else { return [] }
        let parser = XMLParser(data: data)
        parser.delegate = self
        _ = parser.parse()
        return cues
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "text" else { return }
        currentText = ""
        currentStart = Double(attributeDict["start"] ?? "")
        currentDuration = Double(attributeDict["dur"] ?? "")
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard elementName == "text", let start = currentStart else { return }
        let text = cleanXMLText(currentText)
        guard !text.isEmpty else { return }
        let duration = currentDuration ?? 2
        cues.append(
            YTCue(
                id: cues.count + 1,
                start: start,
                end: start + max(duration, 0.5),
                text: text
            )
        )
    }

    private func cleanXMLText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private func firstRegexCapture(in text: String, patterns: [String]) -> String? {
    for pattern in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            continue
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let swiftRange = Range(match.range(at: 1), in: text)
        else { continue }
        return String(text[swiftRange])
    }
    return nil
}

private func extractJSONObject(from text: String, start: String.Index) -> String? {
    var index = start
    var depth = 0
    var isInString = false
    var isEscaped = false
    while index < text.endIndex {
        let char = text[index]
        if isInString {
            if isEscaped {
                isEscaped = false
            } else if char == "\\" {
                isEscaped = true
            } else if char == "\"" {
                isInString = false
            }
        } else {
            if char == "\"" {
                isInString = true
            } else if char == "{" {
                depth += 1
            } else if char == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[start...index])
                }
            }
        }
        index = text.index(after: index)
    }
    return nil
}

private func parseISODate(_ value: String) -> Date? {
    guard !value.isEmpty else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    return ISO8601DateFormatter().date(from: value)
}

private func htmlDecoded(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&#39;", with: "'")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
