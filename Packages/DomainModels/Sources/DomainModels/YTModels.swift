import Foundation
import SwiftData
import PodcastEnglishStudioCore

// MARK: - YouTube

@Model
public final class YTChannelRecord {
    @Attribute(.unique) public var id: String
    public var channelID: String
    public var url: String
    public var displayName: String
    public var uploadsPlaylistID: String?
    public var isEnabled: Bool
    public var lastVideoID: String?
    public var lastCheckedAt: Date?
    public var lastError: String?
    public var videoCount: Int
    public var nextVideosContinuation: String?
    public var hasMoreVideos: Bool = false
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        channelID: String,
        url: String,
        displayName: String,
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.channelID = channelID
        self.url = url
        self.displayName = displayName
        self.uploadsPlaylistID = nil
        self.isEnabled = isEnabled
        self.videoCount = 0
        self.nextVideosContinuation = nil
        self.hasMoreVideos = false
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
}

@Model
public final class YTVideoRecord {
    @Attribute(.unique) public var id: String
    public var channelRecordID: String
    public var channelID: String
    public var title: String
    public var publishedAt: Date?
    public var updatedAt: Date?
    public var url: String
    public var thumbnail: String?
    public var subtitleStatus: String
    public var subtitleTranslatedCount: Int?
    public var subtitleTotalCount: Int?
    public var enVTTPath: String?
    public var zhVTTPath: String?
    public var segmentsPath: String?
    public var lastError: String?
    public var activeSubtitleTargetLanguage: String?
    public var playbackPositionSeconds: Double?
    public var playbackDurationSeconds: Double?
    public var playbackCompletedAt: Date?
    public var playbackUpdatedAt: Date?
    /// `youtubeCaption` | `audioASR`
    public var sourceTranscriptMethod: String?
    /// `resolving` | `downloading` | `uploading` | `transcribing` | `segmenting` | `translating`
    public var sourceGenerationStep: String?
    public var sourceGenerationProgress: Double?
    public var localAudioPath: String?
    public var actualPlaybackHeight: Int?
    public var actualPlaybackCodec: String?
    public var createdAt: Date
    public var recordUpdatedAt: Date
    /// `subscription` (default / nil) or `assistant`. Optional so SwiftData can
    /// lightweight-migrate existing rows.
    public var originRaw: String?
    public var pinnedToHome: Bool = false

    public init(
        id: String,
        channelRecordID: String,
        channelID: String,
        title: String,
        publishedAt: Date? = nil,
        updatedAt: Date? = nil,
        url: String,
        thumbnail: String? = nil,
        createdAt: Date = Date(),
        originRaw: String? = nil,
        pinnedToHome: Bool = false
    ) {
        self.id = id
        self.channelRecordID = channelRecordID
        self.channelID = channelID
        self.title = title
        self.publishedAt = publishedAt
        self.updatedAt = updatedAt
        self.url = url
        self.thumbnail = thumbnail
        self.subtitleStatus = "not_requested"
        self.subtitleTranslatedCount = nil
        self.subtitleTotalCount = nil
        self.activeSubtitleTargetLanguage = nil
        self.sourceTranscriptMethod = nil
        self.sourceGenerationStep = nil
        self.sourceGenerationProgress = nil
        self.localAudioPath = nil
        self.actualPlaybackHeight = nil
        self.actualPlaybackCodec = nil
        self.createdAt = createdAt
        self.recordUpdatedAt = createdAt
        self.originRaw = originRaw
        self.pinnedToHome = pinnedToHome
    }

    public var catalogOrigin: CatalogOrigin {
        get { CatalogOrigin(stored: originRaw) }
        set { originRaw = newValue.storedValue }
    }

    public var appearsInSubscriptionLibrary: Bool {
        CatalogIsolationPolicy.appearsInSubscriptionLibrary(originRaw: originRaw)
    }

    public var isPinnedAssistantHomeItem: Bool {
        CatalogIsolationPolicy.isPinnedAssistantHomeItem(originRaw: originRaw, pinnedToHome: pinnedToHome)
    }

    public var enReady: Bool {
        enVTTPath != nil
    }

    public var zhReady: Bool {
        zhVTTPath != nil
    }

    /// Whether bilingual subtitles are fully complete for UI display.
    /// Partial mid-translation VTT paths must not count as ready.
    public var bilingualSubtitlesCompleted: Bool {
        switch subtitleStatus {
        case "ready":
            return true
        case "translating", "running", "partial", "failed", "not_requested":
            return false
        default:
            return enReady && zhReady
        }
    }
}
