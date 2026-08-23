import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum PodcastArtworkSource: String, Codable, Equatable, Sendable {
    case rss
    case apple
}

public struct PodcastShowInfo: Codable, Equatable, Sendable {
    public var title: String
    public var author: String
    public var feedURL: URL?
    public var artworkURL: URL?
    public var summary: String?
    public var websiteURL: URL?
    public var applePodcastsURL: URL?
    public var artworkSource: PodcastArtworkSource?

    public init(
        title: String,
        author: String = "",
        feedURL: URL? = nil,
        artworkURL: URL? = nil,
        summary: String? = nil,
        websiteURL: URL? = nil,
        applePodcastsURL: URL? = nil,
        artworkSource: PodcastArtworkSource? = nil
    ) {
        self.title = title
        self.author = author
        self.feedURL = feedURL
        self.artworkURL = artworkURL
        self.summary = summary
        self.websiteURL = websiteURL
        self.applePodcastsURL = applePodcastsURL
        self.artworkSource = artworkSource ?? (artworkURL == nil ? nil : .rss)
    }
}

public struct PodcastEpisodeInfo: Codable, Equatable, Identifiable, Sendable {
    public var id: String { guid.isEmpty ? enclosureURL.absoluteString : guid }
    public var title: String
    public var guid: String
    public var publishedAt: Date?
    public var enclosureURL: URL
    public var link: URL?
    public var artworkURL: URL?
    public var summary: String?
    public var durationSeconds: Double?
    public var seasonNumber: Int?
    public var episodeNumber: Int?

    public init(
        title: String,
        guid: String,
        publishedAt: Date? = nil,
        enclosureURL: URL,
        link: URL? = nil,
        artworkURL: URL? = nil,
        summary: String? = nil,
        durationSeconds: Double? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil
    ) {
        self.title = title
        self.guid = guid
        self.publishedAt = publishedAt
        self.enclosureURL = enclosureURL
        self.link = link
        self.artworkURL = artworkURL
        self.summary = summary
        self.durationSeconds = durationSeconds
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
    }
}

public struct PodcastFeed: Codable, Equatable, Sendable {
    public var show: PodcastShowInfo
    public var episodes: [PodcastEpisodeInfo]
}

public enum PodcastFeedOrderingPolicy {
    public static func newestFirst(_ episodes: [PodcastEpisodeInfo]) -> [PodcastEpisodeInfo] {
        episodes.enumerated().sorted { lhs, rhs in
            let lhsDate = lhs.element.publishedAt ?? .distantPast
            let rhsDate = rhs.element.publishedAt ?? .distantPast
            if lhsDate == rhsDate {
                return lhs.offset < rhs.offset
            }
            return lhsDate > rhsDate
        }.map(\.element)
    }
}

public enum PodcastCatalogFetchMode: Equatable, Sendable {
    case recent(limit: Int)
    case all
}

public enum PodcastCatalogSelectionPolicy {
    public static func select(
        _ episodes: [PodcastEpisodeInfo],
        mode: PodcastCatalogFetchMode
    ) -> [PodcastEpisodeInfo] {
        let ordered = PodcastFeedOrderingPolicy.newestFirst(episodes)
        var seenGUIDs: Set<String> = []
        let uniqueEpisodes = ordered.filter { seenGUIDs.insert($0.guid).inserted }
        switch mode {
        case .recent(let limit):
            return Array(uniqueEpisodes.prefix(max(0, limit)))
        case .all:
            return uniqueEpisodes
        }
    }
}

public enum PodcastShowMetadataPolicy {
    public static func merging(
        rss: PodcastShowInfo,
        apple: PodcastShowInfo?
    ) -> PodcastShowInfo {
        guard let apple else { return rss }
        let rssTitle = rss.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldUseAppleTitle = rssTitle.isEmpty || rssTitle == "Untitled Podcast"
        let artworkURL = rss.artworkURL ?? apple.artworkURL
        return PodcastShowInfo(
            title: shouldUseAppleTitle ? apple.title : rss.title,
            author: nonEmpty(rss.author) ?? apple.author,
            feedURL: rss.feedURL ?? apple.feedURL,
            artworkURL: artworkURL,
            summary: nonEmpty(rss.summary) ?? apple.summary,
            websiteURL: rss.websiteURL ?? apple.websiteURL,
            applePodcastsURL: rss.applePodcastsURL ?? apple.applePodcastsURL,
            artworkSource: rss.artworkURL == nil ? apple.artworkSource : .rss
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}

public enum PodcastMetadataTextPolicy {
    public static let maximumSyncedSummaryLength = 20_000

    public static func plainText(_ value: String, maximumLength: Int? = nil) -> String? {
        var text = decodeHTMLEntities(value)
        text = replacingMatches(
            in: text,
            pattern: #"<(script|style)\b[^>]*>[\s\S]*?</\1\s*>"#,
            with: ""
        )
        text = replacingMatches(
            in: text,
            pattern: #"</?(p|div|section|article|header|footer|li|ul|ol|h[1-6]|blockquote)\b[^>]*>"#,
            with: "\n\n"
        )
        text = replacingMatches(in: text, pattern: #"<br\s*/?>"#, with: "\n")
        text = replacingMatches(in: text, pattern: #"<[^>]+>"#, with: "")
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = replacingMatches(in: text, pattern: #"[ \t]+"#, with: " ")
        text = replacingMatches(in: text, pattern: #" *\n *"#, with: "\n")
        text = replacingMatches(in: text, pattern: #"\n{3,}"#, with: "\n\n")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let maximumLength, text.count > maximumLength {
            return String(text.prefix(maximumLength))
        }
        return text
    }

    private static func replacingMatches(in value: String, pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return value
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(in: value, range: range, withTemplate: replacement)
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        var result = value
        let named: [(String, String)] = [
            ("&nbsp;", " "),
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'")
        ]
        for (entity, replacement) in named {
            result = result.replacingOccurrences(of: entity, with: replacement, options: [.caseInsensitive])
        }
        guard let regex = try? NSRegularExpression(pattern: #"&#(x?[0-9A-Fa-f]+);"#) else {
            return result
        }
        let matches = regex.matches(
            in: result,
            range: NSRange(result.startIndex..<result.endIndex, in: result)
        ).reversed()
        for match in matches {
            guard let fullRange = Range(match.range(at: 0), in: result),
                  let numberRange = Range(match.range(at: 1), in: result)
            else { continue }
            let raw = String(result[numberRange])
            let radix = raw.lowercased().hasPrefix("x") ? 16 : 10
            let digits = radix == 16 ? String(raw.dropFirst()) : raw
            guard let scalarValue = UInt32(digits, radix: radix),
                  let scalar = UnicodeScalar(scalarValue)
            else { continue }
            result.replaceSubrange(fullRange, with: String(Character(scalar)))
        }
        return result
    }
}

public struct PodcastEpisodeRefreshPlan: Equatable, Sendable {
    public var insertions: [PodcastEpisodeInfo]
    public var updates: [PodcastEpisodeInfo]
}

public enum PodcastEpisodeRefreshPolicy {
    public static func plan(
        existingGUIDs: Set<String>,
        incoming: [PodcastEpisodeInfo]
    ) -> PodcastEpisodeRefreshPlan {
        var seenGUIDs: Set<String> = []
        var insertions: [PodcastEpisodeInfo] = []
        var updates: [PodcastEpisodeInfo] = []

        for episode in incoming where seenGUIDs.insert(episode.guid).inserted {
            if existingGUIDs.contains(episode.guid) {
                updates.append(episode)
            } else {
                insertions.append(episode)
            }
        }

        return PodcastEpisodeRefreshPlan(
            insertions: insertions,
            updates: updates
        )
    }
}

public enum PodcastDisplayNamePolicy {
    public static func refreshedName(current: String, sourceURL: String, feedTitle: String) -> String {
        let trimmedCurrent = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSourceURL = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedCurrent == trimmedSourceURL ? feedTitle : current
    }
}

public enum PodcastSubscriptionURLInspector {
    public static func isUnsupportedAppleChannel(_ url: URL) -> Bool {
        guard url.host()?.lowercased().contains("podcasts.apple.com") == true else { return false }
        return url.pathComponents.contains { $0.lowercased() == "channel" }
    }

    public static func applePodcastID(from url: URL) -> String? {
        let pattern = #"id(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let value = url.absoluteString
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range),
              let swiftRange = Range(match.range(at: 1), in: value)
        else { return nil }
        return String(value[swiftRange])
    }
}

public final class PodcastFeedParser: NSObject, XMLParserDelegate {
    private var showTitle = ""
    private var showAuthor = ""
    private var showArtworkURL: URL?
    private var showSummary = ""
    private var showWebsiteURL: URL?
    private var currentElement = ""
    private var currentText = ""
    private var inChannelImage = false
    private var inAtomAuthor = false
    private var inItem = false
    private var itemTitle = ""
    private var itemGUID = ""
    private var itemPubDate = ""
    private var itemLink = ""
    private var itemEnclosure: URL?
    private var itemArtworkURL: URL?
    private var itemSummary = ""
    private var itemDuration = ""
    private var itemSeason = ""
    private var itemEpisode = ""
    private var episodes: [PodcastEpisodeInfo] = []
    private let dateFormatters: [DateFormatter]

    public override init() {
        let rfc822 = DateFormatter()
        rfc822.locale = Locale(identifier: "en_US_POSIX")
        rfc822.dateFormat = "E, d MMM yyyy HH:mm:ss Z"

        let rfc822TwoDigit = DateFormatter()
        rfc822TwoDigit.locale = Locale(identifier: "en_US_POSIX")
        rfc822TwoDigit.dateFormat = "E, dd MMM yyyy HH:mm:ss Z"

        self.dateFormatters = [rfc822, rfc822TwoDigit]
        super.init()
    }

    public func parse(data: Data, feedURL: URL? = nil) throws -> PodcastFeed {
        reset()
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            throw parser.parserError ?? CocoaError(.fileReadCorruptFile)
        }
        let show = PodcastShowInfo(
            title: showTitle.isEmpty ? "Untitled Podcast" : showTitle,
            author: showAuthor,
            feedURL: feedURL,
            artworkURL: showArtworkURL,
            summary: PodcastMetadataTextPolicy.plainText(
                showSummary,
                maximumLength: PodcastMetadataTextPolicy.maximumSyncedSummaryLength
            ),
            websiteURL: showWebsiteURL,
            artworkSource: showArtworkURL == nil ? nil : .rss
        )
        return PodcastFeed(show: show, episodes: episodes)
    }

    private func reset() {
        showTitle = ""
        showAuthor = ""
        showArtworkURL = nil
        showSummary = ""
        showWebsiteURL = nil
        currentElement = ""
        currentText = ""
        inChannelImage = false
        inAtomAuthor = false
        inItem = false
        itemTitle = ""
        itemGUID = ""
        itemPubDate = ""
        itemLink = ""
        itemEnclosure = nil
        itemArtworkURL = nil
        itemSummary = ""
        itemDuration = ""
        itemSeason = ""
        itemEpisode = ""
        episodes = []
    }

    public func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let normalizedName = elementName.lowercased()
        currentElement = normalizedName
        currentText = ""
        if normalizedName == "item" || normalizedName == "entry" {
            inItem = true
            itemTitle = ""
            itemGUID = ""
            itemPubDate = ""
            itemLink = ""
            itemEnclosure = nil
            itemArtworkURL = nil
            itemSummary = ""
            itemDuration = ""
            itemSeason = ""
            itemEpisode = ""
        }
        if normalizedName == "image", !inItem {
            inChannelImage = true
        }
        if normalizedName == "author", !inItem {
            inAtomAuthor = true
        }
        if normalizedName == "itunes:image",
           let value = attributeDict["href"] ?? attributeDict["url"],
           let url = URL(string: value) {
            if inItem {
                itemArtworkURL = itemArtworkURL ?? url
            } else {
                showArtworkURL = showArtworkURL ?? url
            }
        }
        if normalizedName == "enclosure",
           itemEnclosure == nil,
           let value = attributeDict["url"],
           let url = URL(string: value),
           isPlayableAudioEnclosure(url: url, mimeType: attributeDict["type"]) {
            itemEnclosure = url
        }
        if normalizedName == "link", let href = attributeDict["href"] {
            let relationship = attributeDict["rel"]?.lowercased()
            if inItem, relationship == "enclosure",
               itemEnclosure == nil,
               let url = URL(string: href),
               isPlayableAudioEnclosure(url: url, mimeType: attributeDict["type"]) {
                itemEnclosure = url
            } else if inItem, itemLink.isEmpty, relationship == nil || relationship == "alternate" {
                itemLink = href
            } else if !inItem, showWebsiteURL == nil, relationship == nil || relationship == "alternate" {
                showWebsiteURL = URL(string: href)
            }
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    public func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let normalizedName = elementName.lowercased()
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if inItem {
            switch normalizedName {
            case "title":
                itemTitle = text
            case "guid", "id":
                itemGUID = text
            case "pubdate", "published", "updated":
                itemPubDate = text
            case "link" where !text.isEmpty:
                itemLink = text
            case "description", "itunes:summary", "summary", "content", "content:encoded":
                if itemSummary.isEmpty && !text.isEmpty {
                    itemSummary = text
                }
            case "itunes:duration":
                itemDuration = text
            case "itunes:season":
                itemSeason = text
            case "itunes:episode":
                itemEpisode = text
            case "item", "entry":
                if let enclosure = itemEnclosure {
                    episodes.append(
                        PodcastEpisodeInfo(
                            title: itemTitle.isEmpty ? "Untitled Episode" : itemTitle,
                            guid: itemGUID.isEmpty ? enclosure.absoluteString : itemGUID,
                            publishedAt: parseDate(itemPubDate),
                            enclosureURL: enclosure,
                            link: URL(string: itemLink),
                            artworkURL: itemArtworkURL,
                            summary: PodcastMetadataTextPolicy.plainText(itemSummary),
                            durationSeconds: parseDuration(itemDuration),
                            seasonNumber: positiveInt(itemSeason),
                            episodeNumber: positiveInt(itemEpisode)
                        )
                    )
                }
                inItem = false
            default:
                break
            }
        } else {
            switch normalizedName {
            case "title" where showTitle.isEmpty:
                showTitle = text
            case "itunes:author" where showAuthor.isEmpty:
                showAuthor = text
            case "name" where inAtomAuthor && showAuthor.isEmpty:
                showAuthor = text
            case "author" where showAuthor.isEmpty:
                showAuthor = text
                inAtomAuthor = false
            case "author":
                inAtomAuthor = false
            case "description", "itunes:summary", "subtitle", "itunes:subtitle", "summary", "content":
                if showSummary.isEmpty && !text.isEmpty {
                    showSummary = text
                }
            case "url" where inChannelImage && showArtworkURL == nil:
                showArtworkURL = URL(string: text)
            case "link" where !text.isEmpty && showWebsiteURL == nil:
                showWebsiteURL = URL(string: text)
            case "image":
                inChannelImage = false
            default:
                break
            }
        }
        currentText = ""
    }

    private func parseDate(_ value: String) -> Date? {
        for formatter in dateFormatters {
            if let date = formatter.date(from: value) { return date }
        }
        return ISO8601DateFormatter().date(from: value)
    }

    private func parseDuration(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let seconds = Double(trimmed), seconds.isFinite, seconds >= 0 {
            return seconds
        }
        let components = trimmed.split(separator: ":").compactMap { Double($0) }
        guard components.count == trimmed.split(separator: ":").count,
              (2...3).contains(components.count),
              components.allSatisfy({ $0.isFinite && $0 >= 0 })
        else { return nil }
        if components.count == 2 {
            return components[0] * 60 + components[1]
        }
        return components[0] * 3_600 + components[1] * 60 + components[2]
    }

    private func positiveInt(_ value: String) -> Int? {
        guard let number = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              number > 0
        else { return nil }
        return number
    }

    private func isPlayableAudioEnclosure(url: URL, mimeType: String?) -> Bool {
        let normalizedType = mimeType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if !normalizedType.isEmpty {
            return normalizedType.hasPrefix("audio/")
        }
        return ["aac", "flac", "m4a", "mp3", "oga", "ogg", "opus", "wav"]
            .contains(url.pathExtension.lowercased())
    }
}
