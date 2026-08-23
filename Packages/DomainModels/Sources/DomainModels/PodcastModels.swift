import Foundation
import SwiftData
import PodcastEnglishStudioCore

// MARK: - Podcast

@Model
public final class PodcastSubscription {
    @Attribute(.unique) public var id: String
    public var showURL: String
    public var displayName: String
    public var feedURL: String?
    public var authorName: String?
    public var summaryText: String?
    public var artworkURL: String?
    public var artworkSource: String?
    public var websiteURL: String?
    public var applePodcastsURL: String?
    public var hasMoreEpisodes: Bool?
    public var isEnabled: Bool
    public var lastEpisodeGUID: String?
    public var lastJobID: String?
    public var lastCheckedAt: Date?
    public var lastError: String?
    /// Local-only RSS ETag; not synced via CloudKit.
    public var rssETag: String?
    /// Local-only RSS Last-Modified; not synced via CloudKit.
    public var rssLastModified: String?
    /// Feed URL the local RSS validators were captured for; not synced via CloudKit.
    public var rssValidatorFeedURL: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        showURL: String,
        displayName: String,
        feedURL: String? = nil,
        authorName: String? = nil,
        summaryText: String? = nil,
        artworkURL: String? = nil,
        artworkSource: String? = nil,
        websiteURL: String? = nil,
        applePodcastsURL: String? = nil,
        hasMoreEpisodes: Bool? = nil,
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.showURL = showURL
        self.displayName = displayName
        self.feedURL = feedURL
        self.authorName = authorName
        self.summaryText = summaryText
        self.artworkURL = artworkURL
        self.artworkSource = artworkSource
        self.websiteURL = websiteURL
        self.applePodcastsURL = applePodcastsURL
        self.hasMoreEpisodes = hasMoreEpisodes
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
}

public extension PodcastSubscription {
    var artworkSourceKind: PodcastArtworkSource? {
        artworkSource.flatMap(PodcastArtworkSource.init(rawValue:))
    }

    var rssValidators: PodcastFeedValidators? {
        guard let feedURL = rssValidatorFeedURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !feedURL.isEmpty
        else { return nil }
        let validators = PodcastFeedValidators(
            etag: rssETag,
            lastModified: rssLastModified,
            feedURL: feedURL
        )
        return validators.hasAnyValidator ? validators : nil
    }

    func applyRSSValidators(_ validators: PodcastFeedValidators) {
        rssETag = validators.etag
        rssLastModified = validators.lastModified
        rssValidatorFeedURL = validators.feedURL
    }

    func clearRSSValidators() {
        rssETag = nil
        rssLastModified = nil
        rssValidatorFeedURL = nil
    }
}

@Model
public final class EpisodeRecord {
    @Attribute(.unique) public var id: String
    public var subscriptionID: String?
    public var showTitle: String
    public var showArtist: String
    public var episodeTitle: String
    public var episodeGUID: String
    public var publishedAt: Date?
    public var enclosureURL: String
    public var artworkURL: String?
    public var summaryText: String?
    public var mediaDurationSeconds: Double?
    public var seasonNumber: Int?
    public var episodeNumber: Int?
    public var episodeWebsiteURL: String?
    public var localAudioPath: String?
    public var status: String
    public var pipelineStep: String
    public var pipelineProgress: Double?
    public var pipelineMessage: String?
    public var errorMessage: String?
    public var activeTranslationTargetLanguage: String?
    public var isNew: Bool
    public var playbackPositionSeconds: Double?
    public var playbackDurationSeconds: Double?
    public var playbackCompletedAt: Date?
    public var playbackUpdatedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        subscriptionID: String? = nil,
        showTitle: String,
        showArtist: String = "",
        episodeTitle: String,
        episodeGUID: String,
        publishedAt: Date? = nil,
        enclosureURL: String,
        artworkURL: String? = nil,
        summaryText: String? = nil,
        mediaDurationSeconds: Double? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        episodeWebsiteURL: String? = nil,
        status: String = "queued",
        pipelineStep: String = "discover",
        isNew: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.subscriptionID = subscriptionID
        self.showTitle = showTitle
        self.showArtist = showArtist
        self.episodeTitle = episodeTitle
        self.episodeGUID = episodeGUID
        self.publishedAt = publishedAt
        self.enclosureURL = enclosureURL
        self.artworkURL = artworkURL
        self.summaryText = summaryText
        self.mediaDurationSeconds = mediaDurationSeconds
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.episodeWebsiteURL = episodeWebsiteURL
        self.status = status
        self.pipelineStep = pipelineStep
        self.pipelineProgress = status == "completed" ? 1.0 : 0.0
        self.pipelineMessage = nil
        self.activeTranslationTargetLanguage = nil
        self.isNew = isNew
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
}

@Model
public final class SegmentRecord {
    @Attribute(.unique) public var id: String
    public var episodeID: String
    public var sequence: Int
    public var startMS: Int
    public var endMS: Int
    public var text: String
    public var learningText: String
    public var translation: String
    public var speaker: String?
    public var notes: String

    public init(
        id: String = UUID().uuidString,
        episodeID: String,
        sequence: Int,
        startMS: Int,
        endMS: Int,
        text: String,
        learningText: String,
        translation: String = "",
        speaker: String? = nil,
        notes: String = ""
    ) {
        self.id = id
        self.episodeID = episodeID
        self.sequence = sequence
        self.startMS = startMS
        self.endMS = endMS
        self.text = text
        self.learningText = learningText
        self.translation = translation
        self.speaker = speaker
        self.notes = notes
    }
}

@Model
public final class TranslationVariantRecord {
    @Attribute(.unique) public var id: String
    public var contentKind: String
    public var contentID: String
    public var targetLanguage: String
    public var status: String
    public var translatedCount: Int?
    public var totalCount: Int?
    public var segmentsPath: String?
    public var targetVTTPath: String?
    public var errorCode: String?
    public var technicalDetails: String?
    public var updatedAt: Date

    public init(
        contentKind: TranslationContentKind,
        contentID: String,
        target: TranslationTarget,
        status: TranslationVariantStatus = .notRequested,
        updatedAt: Date = Date()
    ) {
        self.id = TranslationVariantIdentity.make(
            contentKind: contentKind,
            contentID: contentID,
            target: target
        )
        self.contentKind = contentKind.rawValue
        self.contentID = contentID
        self.targetLanguage = target.rawValue
        self.status = status.rawValue
        self.updatedAt = updatedAt
    }

    public var target: TranslationTarget {
        TranslationTargetPolicy.normalized(targetLanguage)
    }

    public var variantStatus: TranslationVariantStatus {
        get { TranslationVariantStatus(rawValue: status) ?? .notRequested }
        set { status = newValue.rawValue }
    }
}

@MainActor
public enum TranslationVariantRepository {
    public static func find(
        contentKind: TranslationContentKind,
        contentID: String,
        target: TranslationTarget,
        context: ModelContext
    ) throws -> TranslationVariantRecord? {
        let id = TranslationVariantIdentity.make(contentKind: contentKind, contentID: contentID, target: target)
        let descriptor = FetchDescriptor<TranslationVariantRecord>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first
    }

    public static func getOrCreate(
        contentKind: TranslationContentKind,
        contentID: String,
        target: TranslationTarget,
        context: ModelContext
    ) throws -> TranslationVariantRecord {
        if let existing = try find(
            contentKind: contentKind,
            contentID: contentID,
            target: target,
            context: context
        ) {
            return existing
        }
        let variant = TranslationVariantRecord(contentKind: contentKind, contentID: contentID, target: target)
        context.insert(variant)
        return variant
    }

    public static func deleteAll(
        contentKind: TranslationContentKind,
        contentID: String,
        context: ModelContext
    ) throws {
        let rawKind = contentKind.rawValue
        let descriptor = FetchDescriptor<TranslationVariantRecord>(
            predicate: #Predicate { $0.contentKind == rawKind && $0.contentID == contentID }
        )
        for variant in try context.fetch(descriptor) {
            context.delete(variant)
        }
    }
}
