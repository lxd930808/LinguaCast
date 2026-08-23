import Foundation

public enum TranslationTarget: String, CaseIterable, Codable, Hashable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case spanish = "es"
    case brazilianPortuguese = "pt-BR"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case arabic = "ar"

    public var autonym: String {
        switch self {
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .spanish: "Español"
        case .brazilianPortuguese: "Português (Brasil)"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .french: "Français"
        case .german: "Deutsch"
        case .arabic: "العربية"
        }
    }

    public var promptName: String {
        switch self {
        case .simplifiedChinese: "Simplified Chinese"
        case .traditionalChinese: "Traditional Chinese"
        case .spanish: "Spanish"
        case .brazilianPortuguese: "Brazilian Portuguese"
        case .japanese: "Japanese"
        case .korean: "Korean"
        case .french: "French"
        case .german: "German"
        case .arabic: "Arabic"
        }
    }

    public var fileComponent: String { rawValue }
}

public enum TranslationTargetPolicy {
    public static func normalized(_ rawValue: String?) -> TranslationTarget {
        guard let rawValue,
              let target = TranslationTarget(rawValue: rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return .simplifiedChinese }
        return target
    }

    public static func defaultTarget(preferredLanguageIdentifiers: [String]) -> TranslationTarget {
        for identifier in preferredLanguageIdentifiers {
            if let target = target(matching: identifier) { return target }
        }
        return .simplifiedChinese
    }

    private static func target(matching identifier: String) -> TranslationTarget? {
        let normalized = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        if normalized == "zh-hans" || normalized.hasPrefix("zh-cn") || normalized.hasPrefix("zh-sg") {
            return .simplifiedChinese
        }
        if normalized == "zh-hant" || normalized.hasPrefix("zh-tw") || normalized.hasPrefix("zh-hk") || normalized.hasPrefix("zh-mo") {
            return .traditionalChinese
        }
        if normalized == "pt-br" || normalized.hasPrefix("pt-br-") { return .brazilianPortuguese }
        return TranslationTarget.allCases.first { target in
            normalized == target.rawValue.lowercased() || normalized.hasPrefix(target.rawValue.lowercased() + "-")
        }
    }
}

public enum TranslationContentKind: String, Codable, Hashable, Sendable {
    case podcastEpisode
    case youtubeVideo
}

public enum TranslationVariantStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case notRequested
    case running
    case partial
    case ready
    case failed
}

public enum TranslationVariantIdentity {
    public static func make(
        contentKind: TranslationContentKind,
        contentID: String,
        target: TranslationTarget
    ) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let escapedID = contentID.addingPercentEncoding(withAllowedCharacters: allowed) ?? contentID
        return "\(contentKind.rawValue):\(escapedID):\(target.rawValue)"
    }
}

/// Decides whether a podcast episode whose status is stuck at `running` may be
/// reconciled to `completed` purely from local artifacts, without re-running the
/// translation pipeline. The acceptance target for the completion-bug fix is that
/// an episode that already has a complete, valid translation on disk recovers to
/// `completed` in the current process; every incomplete / stale / mismatched input
/// must be refused so we never mark partial or wrong work as finished.
///
/// Fully translated `running` manifests are accepted too: display sub-clause
/// refinement is a post-completion background enhancement and must not block
/// playback (the historical `running / build_learning_pack / 90%` stall).
public enum PodcastCompletionReconciliationPolicy {
    /// Pure, injectable description of the on-disk translation state for one
    /// (episode, target) pair. The caller (app layer, which owns file IO and
    /// SwiftData) fills this in; the policy stays free of any IO so it is unit
    /// testable through `swift test`.
    public struct Input: Equatable, Sendable {
        /// The target the episode is actively being translated into.
        public var activeTarget: TranslationTarget?
        /// The target whose artifacts we are validating.
        public var artifactTarget: TranslationTarget
        /// `TranslationArtifactManifest.status` for the artifact target ("ready"…).
        public var manifestStatus: String?
        /// `TranslationArtifactManifest.pipelineVersion` for the artifact target.
        public var pipelineVersion: Int?
        /// Number of segments in the translation segments file (0 when unreadable/missing).
        public var segmentCount: Int
        /// Number of segments with a non-empty translation.
        public var translatedCount: Int
        /// `TranslationArtifactManifest.sourceFingerprint`.
        public var manifestFingerprint: String?
        /// Fingerprint recomputed from the segments actually on disk.
        public var segmentsFingerprint: String?
        /// Fingerprint of the episode's English base transcription, when available.
        public var sourceFingerprint: String?

        public init(
            activeTarget: TranslationTarget?,
            artifactTarget: TranslationTarget,
            manifestStatus: String?,
            pipelineVersion: Int?,
            segmentCount: Int,
            translatedCount: Int,
            manifestFingerprint: String?,
            segmentsFingerprint: String?,
            sourceFingerprint: String?
        ) {
            self.activeTarget = activeTarget
            self.artifactTarget = artifactTarget
            self.manifestStatus = manifestStatus
            self.pipelineVersion = pipelineVersion
            self.segmentCount = segmentCount
            self.translatedCount = translatedCount
            self.manifestFingerprint = manifestFingerprint
            self.segmentsFingerprint = segmentsFingerprint
            self.sourceFingerprint = sourceFingerprint
        }
    }

    /// Returns `true` only when every integrity gate passes:
    /// content/target identity, the current pipeline version, a complete and fully
    /// translated segment list, and matching source fingerprints. Any doubt → `false`.
    public static func shouldComplete(_ input: Input) -> Bool {
        // Identity: only reconcile the episode's active translation target.
        guard input.activeTarget == input.artifactTarget else { return false }
        // Only artifacts the current pipeline produced are trusted to be final.
        guard SubtitlePipelineVersion.isCurrent(input.pipelineVersion) else { return false }
        // Translation finished: `ready` is the normal stamp; `running` covers orphans
        // killed after the last translate write but before display refinement / commit.
        guard input.manifestStatus == TranslationVariantStatus.ready.rawValue
            || input.manifestStatus == TranslationVariantStatus.running.rawValue
        else { return false }
        // Every segment must be present and translated (no partial/empty output).
        guard input.segmentCount > 0, input.translatedCount == input.segmentCount else { return false }
        // The manifest fingerprint must match the segments actually on disk.
        guard let manifestFingerprint = input.manifestFingerprint,
              !manifestFingerprint.isEmpty,
              manifestFingerprint == input.segmentsFingerprint
        else { return false }
        // When an English base exists, the translation must have been generated from it.
        if let source = input.sourceFingerprint, !source.isEmpty {
            guard source == manifestFingerprint else { return false }
        }
        return true
    }
}

/// Decides whether a persisted `running` podcast episode should be re-scheduled after
/// app launch / foreground when there is no in-memory pipeline task for it.
/// Completion reconciliation runs first; any episode still `running` without a live
/// task is an orphan (e.g. killed mid-ASR) and is safe to resume.
public enum PodcastOrphanedPipelinePolicy {
    public static func shouldResume(status: String, hasInMemoryTask: Bool) -> Bool {
        status == "running" && !hasInMemoryTask
    }
}

/// Chooses whether an automatic subtitle resume must consult iCloud first.
/// Once local transcription/translation artifacts exist, they are the resume source
/// of truth and a missing iCloud account must not replace the real pipeline error.
public enum PodcastTranslationAutoResumePolicy {
    public static func shouldBypassCloudCheck(
        hasLocalSource: Bool,
        translatedCount: Int,
        totalCount: Int
    ) -> Bool {
        hasLocalSource
            && totalCount > 0
            && translatedCount >= 0
            && translatedCount < totalCount
    }
}

/// UI eligibility for “clear and regenerate”: keep the catalog row, wipe generation
/// artifacts, and re-run the pipeline. Queued episodes have nothing to clear.
public enum PodcastClearAndRegeneratePolicy {
    public static func isAvailable(status: String) -> Bool {
        switch status {
        case "running", "failed", "completed": true
        default: false
        }
    }
}

public enum LegacyPipelineStatusPolicy {
    public static func normalizedCode(step: String, message: String?) -> String {
        let knownCodes = [
            "cloud_check", "download", "oss_upload", "transcribe", "translate", "build_learning_pack", "completed", "failed"
        ]
        if knownCodes.contains(step) { return step }
        return code(forLegacyMessage: message) ?? step
    }

    public static func code(forLegacyMessage message: String?) -> String? {
        switch message?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "下载原始音频", "音频下载完成": return "download"
        case "上传音频到 DashScope 临时存储": return "oss_upload"
        case "等待语音转文字", "语音转文字": return "transcribe"
        case "翻译转录内容", "翻译内容": return "translate"
        case "生成双语字幕": return "build_learning_pack"
        case "双语字幕已就绪", "已完成": return "completed"
        case "处理失败": return "failed"
        default: return nil
        }
    }
}

public enum TranslationPromptPolicy {
    /// Numbered-JSON batch translation. The model must echo each line's `origin` verbatim
    /// and produce a strict object keyed by line number so structure validation is possible.
    public static func batchSystemPrompt(
        target: TranslationTarget,
        topicSummary: String,
        terms: [TranslationTerm],
        contextBefore: [String],
        contextAfter: [String],
        qualityMode: TranslationQualityMode
    ) -> String {
        let termsBlock = terms.isEmpty
            ? ""
            : "\n\nGlossary terms to honour:\n" + terms.map { "- \($0.source) → \($0.target)" + ($0.note.isEmpty ? "" : " (\($0.note))") }.joined(separator: "\n")
        let beforeBlock = contextBefore.isEmpty
            ? ""
            : "\n\nPrevious lines (context only, do not translate):\n" + contextBefore.joined(separator: "\n")
        let afterBlock = contextAfter.isEmpty
            ? ""
            : "\n\nFollowing lines (context only, do not translate):\n" + contextAfter.joined(separator: "\n")
        let formatInstructions: String
        switch qualityMode {
        case .quality:
            formatInstructions = """
            Return strict JSON only, an object keyed by each line's number:
            {"1":{"origin":"<exact source line>","direct":"<literal \(target.promptName)>","reflection":"<one short improvement note>","final":"<natural \(target.promptName)>"}}
            Include every provided number exactly once. `origin` must match the source line character-for-character.
            """
        case .fast:
            formatInstructions = """
            Return strict JSON only, an object keyed by each line's number:
            {"1":{"origin":"<exact source line>","direct":"<literal \(target.promptName)>"}}
            Include every provided number exactly once. `origin` must match the source line character-for-character.
            """
        }
        return """
        You are translating English podcast transcript lines into concise \(target.promptName) for language learning.
        Use the writing system implied by the target locale \(target.rawValue). Do not add explanations.
        \(formatInstructions)

        Topic summary:
        \(topicSummary.isEmpty ? "(none)" : topicSummary)\(termsBlock)\(beforeBlock)\(afterBlock)
        """
    }

    /// Single-line reflective translation used for per-line retry after batch failures.
    public static func singleSystemPrompt(
        target: TranslationTarget,
        topicSummary: String,
        terms: [TranslationTerm],
        qualityMode: TranslationQualityMode
    ) -> String {
        let termsBlock = terms.isEmpty
            ? ""
            : "\n\nGlossary terms to honour:\n" + terms.map { "- \($0.source) → \($0.target)" + ($0.note.isEmpty ? "" : " (\($0.note))") }.joined(separator: "\n")
        let formatInstructions: String
        switch qualityMode {
        case .quality:
            formatInstructions = """
            Return strict JSON only: {"origin":"<exact source line>","direct":"<literal \(target.promptName)>","reflection":"<one short improvement note>","final":"<natural \(target.promptName)>"}.
            `origin` must match the source line character-for-character.
            """
        case .fast:
            formatInstructions = """
            Return strict JSON only: {"origin":"<exact source line>","direct":"<literal \(target.promptName)>"}.
            `origin` must match the source line character-for-character.
            """
        }
        return """
        You are translating one English podcast transcript line into concise \(target.promptName) for language learning.
        Use the writing system implied by the target locale \(target.rawValue). Do not add explanations.
        \(formatInstructions)

        Topic summary:
        \(topicSummary.isEmpty ? "(none)" : topicSummary)\(termsBlock)
        """
    }

    /// Topic summary + glossary extraction for one transcript excerpt.
    public static func contextExtractionSystemPrompt(target: TranslationTarget) -> String {
        """
        You analyze an English podcast transcript excerpt and return strict JSON only:
        {"summary":"<two short sentences describing the topic>","terms":[{"source":"<English term>","target":"<\(target.promptName) rendering>","note":"<optional disambiguation>"}]}
        Include at most 15 terms, only proper nouns / domain terms worth consistent translation.
        """
    }

    /// Split a translation into the same number of parts as the (already split) source.
    public static func alignedTranslationSplitSystemPrompt(target: TranslationTarget, partCount: Int) -> String {
        """
        You split a \(target.promptName) translation into exactly \(partCount) consecutive parts matching a source split.
        Return strict JSON only: {"parts":["part1","part2",...]} with exactly \(partCount) non-empty strings in order.
        Do not translate again; only split the provided translation. Use the writing system implied by \(target.rawValue).
        """
    }
}

/// A glossary term extracted once per content and injected into the blocks that use it.
public struct TranslationTerm: Codable, Hashable, Sendable {
    public var source: String
    public var target: String
    public var note: String

    public init(source: String, target: String, note: String = "") {
        self.source = source
        self.target = target
        self.note = note
    }
}

/// Auto-extracted translation context: a short topic summary plus a glossary.
public struct TranslationContext: Codable, Hashable, Sendable {
    public var topicSummary: String
    public var terms: [TranslationTerm]

    public init(topicSummary: String, terms: [TranslationTerm]) {
        self.topicSummary = topicSummary
        self.terms = terms
    }

    public static let empty = TranslationContext(topicSummary: "", terms: [])

    /// Terms whose source text literally appears in the given block, so each block only
    /// receives the glossary entries it can actually apply.
    public func terms(matching blockText: String) -> [TranslationTerm] {
        terms.filter { term in
            !term.source.isEmpty && blockText.localizedCaseInsensitiveContains(term.source)
        }
    }
}

/// Selects the transcript excerpt sent for topic/term extraction.
///
/// - ≤8000 chars: use the full transcript.
/// - Longer: sample whole sentences evenly across 8 equal time buckets (~1000 chars each),
///   keeping original order, capped at 8000 chars total.
public enum TranslationContextSamplingPolicy {
    public static let maxContextCharacters = 8_000
    public static let bucketCount = 8
    public static let perBucketCharacterTarget = 1_000

    public static func sample(segments: [LearningSegment]) -> [String] {
        let texts = segments.map(\.text)
        let total = texts.reduce(0) { $0 + $1.count }
        guard total > maxContextCharacters else { return texts }
        guard !segments.isEmpty else { return [] }

        let bucketCount = min(Self.bucketCount, segments.count)
        let bucketSize = max(1, segments.count / bucketCount)
        var sampled: [String] = []
        var bucketIndex = 0
        while bucketIndex < bucketCount {
            let lower = bucketIndex * bucketSize
            let upper = bucketIndex == bucketCount - 1 ? segments.count : min(segments.count, (bucketIndex + 1) * bucketSize)
            guard lower < upper else { break }
            var bucketCharacters = 0
            for segment in segments[lower..<upper] {
                if bucketCharacters >= perBucketCharacterTarget { break }
                sampled.append(segment.text)
                bucketCharacters += segment.text.count
            }
            bucketIndex += 1
        }

        // Cap the combined excerpt at the budget, preserving order.
        var result: [String] = []
        var running = 0
        for text in sampled where running < maxContextCharacters {
            result.append(text)
            running += text.count
        }
        return result
    }

    public static func sampleText(segments: [LearningSegment]) -> String {
        sample(segments: segments).joined(separator: "\n")
    }
}

/// Per-block context injection: previous 3 lines, following 2 lines.
public enum TranslationBlockContextPolicy {
    public static let precedingLineCount = 3
    public static let followingLineCount = 2

    public static func context(
        allSegments: [LearningSegment],
        blockSequences: Set<Int>
    ) -> (before: [String], after: [String]) {
        guard !allSegments.isEmpty else { return ([], []) }
        let indices = allSegments.indices.filter { blockSequences.contains(allSegments[$0].sequence) }
        guard let first = indices.first, let last = indices.last else { return ([], []) }
        let beforeStart = max(allSegments.startIndex, first - precedingLineCount)
        let before = allSegments[beforeStart..<first].map(\.text)
        let afterEnd = min(allSegments.endIndex, last + 1 + followingLineCount)
        let after = allSegments[(last + 1)..<afterEnd].map(\.text)
        return (Array(before), Array(after))
    }
}

public enum InterfaceLanguagePolicy {
    public static let supportedLanguages = [
        "en", "zh-Hans", "zh-Hant", "es", "pt-BR", "ja", "ko", "fr", "de", "ar"
    ]

    public static func bestSupportedLanguage(acceptLanguageHeader: String?) -> String {
        guard let acceptLanguageHeader else { return "en" }
        let candidates = acceptLanguageHeader
            .split(separator: ",")
            .enumerated()
            .compactMap { index, part -> (identifier: String, quality: Double, order: Int)? in
                let fields = part.split(separator: ";", omittingEmptySubsequences: true)
                guard let first = fields.first else { return nil }
                let identifier = first.trimmingCharacters(in: .whitespacesAndNewlines)
                var quality = 1.0
                for field in fields.dropFirst() {
                    let value = field.trimmingCharacters(in: .whitespacesAndNewlines)
                    if value.hasPrefix("q="), let parsed = Double(value.dropFirst(2)) { quality = parsed }
                }
                guard quality > 0 else { return nil }
                return (identifier, quality, index)
            }
            .sorted { lhs, rhs in
                lhs.quality == rhs.quality ? lhs.order < rhs.order : lhs.quality > rhs.quality
            }

        for candidate in candidates {
            if let match = matchInterfaceLanguage(candidate.identifier) { return match }
        }
        return "en"
    }

    private static func matchInterfaceLanguage(_ identifier: String) -> String? {
        let normalized = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        if normalized == "*" { return "en" }
        if normalized == "zh" || normalized == "zh-hans" || normalized.hasPrefix("zh-cn") || normalized.hasPrefix("zh-sg") { return "zh-Hans" }
        if normalized == "zh-hant" || normalized.hasPrefix("zh-tw") || normalized.hasPrefix("zh-hk") || normalized.hasPrefix("zh-mo") { return "zh-Hant" }
        if normalized == "pt" || normalized.hasPrefix("pt-") { return "pt-BR" }
        for language in supportedLanguages where !language.contains("-") {
            if normalized == language.lowercased() || normalized.hasPrefix(language.lowercased() + "-") { return language }
        }
        return nil
    }
}

public struct TranscriptWord: Codable, Hashable, Sendable {
    public var text: String
    public var startMS: Int
    public var endMS: Int
    public var punctuation: String?

    public init(text: String, startMS: Int, endMS: Int, punctuation: String? = nil) {
        self.text = text
        self.startMS = startMS
        self.endMS = endMS
        self.punctuation = punctuation
    }
}

public struct LearningSegment: Codable, Identifiable, Hashable, Sendable {
    public var id: Int { sequence }
    public var sequence: Int
    public var startMS: Int
    public var endMS: Int
    public var text: String
    public var learningText: String
    public var translation: String
    public var speaker: String?
    public var notes: String
    public var words: [TranscriptWord]
    /// Whole-sentence grouping used for repeat and previous/next navigation. When a long
    /// sentence is split into display sub-clauses, `text`/`translation`/`startMS`/`endMS`
    /// describe the display sub-clause while `playbackSentence` describes the full sentence.
    /// Absent on older artifacts, where the segment itself is the playback unit.
    public var playbackSentence: PlaybackSentence?
    /// How this segment's timestamps were produced (word-level precise vs legacy fallback).
    public var timingSource: SegmentTimingSource?

    public init(
        sequence: Int,
        startMS: Int,
        endMS: Int,
        text: String,
        learningText: String? = nil,
        translation: String = "",
        speaker: String? = nil,
        notes: String = "",
        words: [TranscriptWord] = [],
        playbackSentence: PlaybackSentence? = nil,
        timingSource: SegmentTimingSource? = nil
    ) {
        self.sequence = sequence
        self.startMS = startMS
        self.endMS = endMS
        self.text = text
        self.learningText = learningText ?? text
        self.translation = translation
        self.speaker = speaker
        self.notes = notes
        self.words = words
        self.playbackSentence = playbackSentence
        self.timingSource = timingSource
    }
}

public struct LearningPack: Codable, Sendable {
    public var segments: [LearningSegment]
    public var updatedAt: Date

    public init(
        segments: [LearningSegment],
        updatedAt: Date = Date()
    ) {
        self.segments = segments
        self.updatedAt = updatedAt
    }
}

public enum LearningPackBuilder {
    public static func cleanLearningText(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    public static func enrichSegments(_ segments: [LearningSegment], now: Date = Date()) -> [LearningSegment] {
        segments.map { segment in
            let learningText = cleanLearningText(segment.learningText.isEmpty ? segment.text : segment.learningText)
            return LearningSegment(
                sequence: segment.sequence,
                startMS: segment.startMS,
                endMS: segment.endMS,
                text: segment.text,
                learningText: learningText,
                translation: segment.translation,
                speaker: segment.speaker,
                notes: segment.notes,
                words: segment.words,
                playbackSentence: segment.playbackSentence,
                timingSource: segment.timingSource
            )
        }
    }

    public static func buildPack(segments: [LearningSegment], now: Date = Date()) -> LearningPack {
        let enriched = enrichSegments(segments, now: now)
        return LearningPack(segments: enriched, updatedAt: now)
    }
}

public enum PlaybackProgressPolicy {
    public static let minimumRestorablePosition: TimeInterval = 3
    public static let persistInterval: TimeInterval = 5

    public static func restorePosition(from value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, value >= minimumRestorablePosition else { return nil }
        return value
    }

    public static func positionToPersist(
        currentTime: TimeInterval,
        lastPersistedTime: TimeInterval?,
        lastPersistedAt: Date?,
        now: Date = Date(),
        force: Bool = false
    ) -> TimeInterval? {
        guard currentTime.isFinite, currentTime >= minimumRestorablePosition else { return nil }
        if force { return currentTime }
        return shouldPersist(
            currentTime: currentTime,
            lastPersistedTime: lastPersistedTime,
            lastPersistedAt: lastPersistedAt,
            now: now
        ) ? currentTime : nil
    }

    public static func shouldPersist(
        currentTime: TimeInterval,
        lastPersistedTime: TimeInterval?,
        lastPersistedAt: Date?,
        now: Date = Date()
    ) -> Bool {
        guard currentTime.isFinite, currentTime >= minimumRestorablePosition else { return false }
        guard let lastPersistedTime, let lastPersistedAt else { return true }
        guard abs(currentTime - lastPersistedTime) >= 0.5 else { return false }
        return now.timeIntervalSince(lastPersistedAt) >= persistInterval
    }
}

public enum PlaybackSeekPolicy {
    public static func clampedTime(_ time: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard time.isFinite, duration.isFinite, duration > 0 else { return 0 }
        return min(max(time, 0), duration)
    }

    public static func offsetTime(
        from currentTime: TimeInterval,
        by offset: TimeInterval,
        duration: TimeInterval
    ) -> TimeInterval {
        clampedTime(currentTime + offset, duration: duration)
    }
}

public struct PlaybackScrubbingState: Equatable, Sendable {
    public private(set) var draftTime: TimeInterval?

    public init(draftTime: TimeInterval? = nil) {
        self.draftTime = draftTime
    }

    public mutating func begin(at time: TimeInterval, duration: TimeInterval) {
        draftTime = PlaybackSeekPolicy.clampedTime(time, duration: duration)
    }

    public mutating func update(to time: TimeInterval, duration: TimeInterval) {
        draftTime = PlaybackSeekPolicy.clampedTime(time, duration: duration)
    }

    public mutating func end() -> TimeInterval? {
        let target = draftTime
        draftTime = nil
        return target
    }

    public func displayedTime(playbackTime: TimeInterval) -> TimeInterval {
        draftTime ?? playbackTime
    }
}

public enum PlaybackListCategory: String, Equatable, Sendable {
    case unplayed
    case inProgress
    case played
}

public enum PlaybackListPolicy {
    public static let completionThreshold: Double = 0.95

    public static func category(
        playbackPosition: TimeInterval?,
        duration: TimeInterval?,
        completedAt: Date?
    ) -> PlaybackListCategory {
        if completedAt != nil { return .played }

        guard let playbackPosition,
              playbackPosition.isFinite,
              playbackPosition >= PlaybackProgressPolicy.minimumRestorablePosition
        else {
            return .unplayed
        }

        if let duration,
           duration.isFinite,
           duration > 0,
           playbackPosition / duration >= completionThreshold {
            return .played
        }

        return .inProgress
    }
}

public enum PipelinePersistencePolicy {
    public static let defaultSegmentBatchSize = 100

    public static func batches(totalCount: Int, batchSize: Int = defaultSegmentBatchSize) -> [Range<Int>] {
        guard totalCount > 0 else { return [] }
        let safeBatchSize = max(1, batchSize)
        return stride(from: 0, to: totalCount, by: safeBatchSize).map { start in
            start..<min(start + safeBatchSize, totalCount)
        }
    }
}

public enum EpisodePlaybackSegmentPolicy {
    public static func sorted(_ segments: [LearningSegment]) -> [LearningSegment] {
        segments.sorted { lhs, rhs in
            if lhs.sequence == rhs.sequence {
                return lhs.startMS < rhs.startMS
            }
            return lhs.sequence < rhs.sequence
        }
    }

    public static func inferredDuration(from segments: [LearningSegment]) -> TimeInterval? {
        guard let lastEnd = segments.map(\.endMS).max() else { return nil }
        return TimeInterval(lastEnd) / 1000
    }
}

public struct EpisodePlaybackSegmentIndex: Sendable {
    private let segments: [LearningSegment]

    public init(segments: [LearningSegment]) {
        self.segments = segments.sorted { lhs, rhs in
            if lhs.startMS == rhs.startMS {
                return lhs.sequence < rhs.sequence
            }
            return lhs.startMS < rhs.startMS
        }
    }

    public func nearestSequence(at seconds: TimeInterval) -> Int? {
        search(atMilliseconds: Int(seconds * 1_000)).sequence
    }

    func search(atMilliseconds milliseconds: Int) -> (sequence: Int?, inspectedCount: Int) {
        guard !segments.isEmpty else { return (nil, 0) }

        // Find the first segment that starts after the playback position. The
        // preceding segment is either the active segment or the nearest useful
        // fallback when the transcript contains a timestamp gap.
        var lowerBound = 0
        var upperBound = segments.count
        var inspectedCount = 0

        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            inspectedCount += 1
            if segments[middle].startMS <= milliseconds {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        let candidateIndex = max(0, lowerBound - 1)
        return (segments[candidateIndex].sequence, inspectedCount)
    }
}

public struct SentencePlaybackContext: Equatable, Sendable {
    public var current: LearningSegment?
    public var previous: LearningSegment?
    public var next: LearningSegment?
    /// One-based position of `current` in timeline order.
    public var position: Int?
    public var totalCount: Int
    public var repeatRange: ClosedRange<TimeInterval>?

    public init(
        current: LearningSegment?,
        previous: LearningSegment?,
        next: LearningSegment?,
        position: Int?,
        totalCount: Int,
        repeatRange: ClosedRange<TimeInterval>?
    ) {
        self.current = current
        self.previous = previous
        self.next = next
        self.position = position
        self.totalCount = totalCount
        self.repeatRange = repeatRange
    }
}

public enum SentencePlaybackPolicy {
    public static func context(
        at seconds: TimeInterval,
        segments: [LearningSegment]
    ) -> SentencePlaybackContext {
        let ordered = orderedSegments(segments)
        guard !ordered.isEmpty else {
            return SentencePlaybackContext(
                current: nil,
                previous: nil,
                next: nil,
                position: nil,
                totalCount: 0,
                repeatRange: nil
            )
        }

        let safeSeconds = seconds.isFinite ? max(0, seconds) : 0
        let milliseconds = Int((safeSeconds * 1_000).rounded())
        var lowerBound = 0
        var upperBound = ordered.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if ordered[middle].startMS <= milliseconds {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        let currentIndex = max(0, lowerBound - 1)
        let current = ordered[currentIndex]

        // Collapse adjacent display sub-clauses that share one explicit playback sentence so
        // previous/next navigation steps per whole sentence, not per fragment. Only an explicit
        // `playbackSentence` groups fragments; legacy duplicate sequences must stay distinct.
        if let currentGroup = current.playbackSentence?.id {
            var previousIndex = currentIndex - 1
            while previousIndex >= 0, ordered[previousIndex].playbackSentence?.id == currentGroup {
                previousIndex -= 1
            }
            var nextIndex = currentIndex + 1
            while nextIndex < ordered.count, ordered[nextIndex].playbackSentence?.id == currentGroup {
                nextIndex += 1
            }
            return SentencePlaybackContext(
                current: current,
                previous: previousIndex >= 0 ? ordered[previousIndex] : nil,
                next: nextIndex < ordered.count ? ordered[nextIndex] : nil,
                position: currentIndex + 1,
                totalCount: ordered.count,
                repeatRange: repeatRange(for: current)
            )
        }

        return SentencePlaybackContext(
            current: current,
            previous: currentIndex > 0 ? ordered[currentIndex - 1] : nil,
            next: currentIndex + 1 < ordered.count ? ordered[currentIndex + 1] : nil,
            position: currentIndex + 1,
            totalCount: ordered.count,
            repeatRange: repeatRange(for: current)
        )
    }

    public static func startTime(for segment: LearningSegment?) -> TimeInterval? {
        guard let segment else { return nil }
        return TimeInterval(max(0, segment.playbackStartMS)) / 1_000
    }

    public static func repeatRange(
        for segment: LearningSegment?
    ) -> ClosedRange<TimeInterval>? {
        guard let segment, let start = startTime(for: segment) else { return nil }
        let end = TimeInterval(max(segment.playbackStartMS, segment.playbackEndMS)) / 1_000
        return start...end
    }

    private static func orderedSegments(
        _ segments: [LearningSegment]
    ) -> [LearningSegment] {
        segments.sorted { lhs, rhs in
            if lhs.startMS != rhs.startMS { return lhs.startMS < rhs.startMS }
            if lhs.endMS != rhs.endMS { return lhs.endMS < rhs.endMS }
            if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
            return lhs.text < rhs.text
        }
    }
}

public enum TranscriptFollowEvent: Sendable {
    case programmaticScrollPositionChanged
    case userDragBegan
    case locatePlayback
}

public enum TranscriptFollowPolicy {
    public static func isFollowing(
        after event: TranscriptFollowEvent,
        wasFollowing: Bool
    ) -> Bool {
        switch event {
        case .programmaticScrollPositionChanged:
            wasFollowing
        case .userDragBegan:
            false
        case .locatePlayback:
            true
        }
    }
}

public struct PlaybackGroupedItems<Item> {
    public var category: PlaybackListCategory
    public var items: [Item]

    public init(category: PlaybackListCategory, items: [Item]) {
        self.category = category
        self.items = items
    }
}

public enum ProgramPlaybackGroupingPolicy {
    public static func group<Item>(
        items: [Item],
        category: (Item) -> PlaybackListCategory
    ) -> [PlaybackGroupedItems<Item>] {
        [
            PlaybackGroupedItems(category: .unplayed, items: items.filter { category($0) == .unplayed }),
            PlaybackGroupedItems(category: .inProgress, items: items.filter { category($0) == .inProgress }),
            PlaybackGroupedItems(category: .played, items: items.filter { category($0) == .played })
        ]
    }
}

public struct TranslationBatch: Equatable, Sendable {
    public var id: Int
    public var segments: [LearningSegment]

    public init(id: Int, segments: [LearningSegment]) {
        self.id = id
        self.segments = segments
    }
}

public enum TranslationBatchPlanner {
    /// Numbered-JSON translation batches: at most 10 lines or 600 characters each, so the
    /// model can keep every line's origin verbatim and inject per-block context/terms.
    public static let batchMaxItems = 10
    public static let batchMaxCharacters = 600

    public static func batches(for segments: [LearningSegment], provider: String) -> [TranslationBatch] {
        batches(
            for: segments,
            maxItems: TranslationBatchPolicy.maxItems(forProvider: provider),
            maxCharacters: TranslationBatchPolicy.maxCharacters(forProvider: provider)
        )
    }

    public static func batches(
        for segments: [LearningSegment],
        maxItems: Int = batchMaxItems,
        maxCharacters: Int = batchMaxCharacters
    ) -> [TranslationBatch] {
        var batches: [TranslationBatch] = []
        var current: [LearningSegment] = []
        var currentCharacters = 0

        for segment in segments {
            let segmentCharacters = segment.text.count
            let wouldExceedItems = !current.isEmpty && current.count >= maxItems
            let wouldExceedCharacters = !current.isEmpty && currentCharacters + segmentCharacters > maxCharacters
            if wouldExceedItems || wouldExceedCharacters {
                batches.append(TranslationBatch(id: batches.count, segments: current))
                current = []
                currentCharacters = 0
            }

            current.append(segment)
            currentCharacters += segmentCharacters
        }

        if !current.isEmpty {
            batches.append(TranslationBatch(id: batches.count, segments: current))
        }
        return batches
    }

    public static func missingSequences(in batch: TranslationBatch, translatedSequences: Set<Int>) -> [Int] {
        batch.segments
            .map(\.sequence)
            .filter { !translatedSequences.contains($0) }
    }
}

public enum TranslationBatchPolicy {
    /// Cerebras keeps slightly smaller blocks to stay well under its context/rate budget.
    public static let cerebrasBatchMaxItems = 8
    public static let cerebrasBatchMaxCharacters = 600

    public static func maxItems(forProvider provider: String) -> Int {
        TranslationProviderPolicy.normalizedProvider(provider) == TranslationProviderPolicy.cerebrasProviderID
            ? cerebrasBatchMaxItems
            : TranslationBatchPlanner.batchMaxItems
    }

    public static func maxCharacters(forProvider provider: String) -> Int {
        TranslationProviderPolicy.normalizedProvider(provider) == TranslationProviderPolicy.cerebrasProviderID
            ? cerebrasBatchMaxCharacters
            : TranslationBatchPlanner.batchMaxCharacters
    }
}

public enum TranslationConcurrencyPolicy {
    public static let deepSeekDefaultConcurrentRequests = 6

    public static func maxConcurrentRequests(forProvider provider: String) -> Int {
        let normalized = TranslationProviderPolicy.normalizedProvider(provider)
        switch normalized {
        case TranslationProviderPolicy.cerebrasProviderID:
            return 1
        case TranslationProviderPolicy.deepSeekProviderID:
            return deepSeekDefaultConcurrentRequests
        default:
            // Numbered blocks are small (≤10 lines / 600 chars); a few parallel requests
            // keep DashScope/qwen throughput reasonable without tripping rate limits.
            return 3
        }
    }
}

public struct TranslationProviderDefaults: Equatable, Sendable {
    public var baseURL: String
    public var modelID: String
    public var reasoningEffort: String

    public init(baseURL: String, modelID: String, reasoningEffort: String) {
        self.baseURL = baseURL
        self.modelID = modelID
        self.reasoningEffort = reasoningEffort
    }
}

public enum TranslationProviderPolicy {
    public static let dashScopeProviderID = "dashscope"
    public static let deepSeekProviderID = "deepseek"
    public static let cerebrasProviderID = "cerebras"

    public static let defaultDashScopeBaseURL = "https://dashscope.aliyuncs.com/compatible-mode/v1"
    public static let defaultDashScopeModelID = "qwen-turbo"
    public static let defaultDeepSeekBaseURL = "https://api.deepseek.com"
    public static let defaultDeepSeekModelID = "deepseek-v4-flash"
    public static let defaultDeepSeekReasoningEffort = "high"
    public static let defaultCerebrasBaseURL = "https://api.cerebras.ai/v1"
    public static let defaultCerebrasModelID = "gpt-oss-120b"
    public static let defaultCerebrasReasoningEffort = "medium"

    public static let deepSeekReasoningEffortOptions = ["high", "max"]
    public static let cerebrasReasoningEffortOptions = ["low", "medium", "high"]

    private static let knownDefaultBaseURLs = [
        defaultDashScopeBaseURL,
        defaultDeepSeekBaseURL,
        defaultCerebrasBaseURL
    ]
    private static let knownDefaultModelIDs = [
        defaultDashScopeModelID,
        defaultDeepSeekModelID,
        defaultCerebrasModelID
    ]
    private static let knownDefaultReasoningEfforts = [
        defaultDeepSeekReasoningEffort,
        defaultCerebrasReasoningEffort
    ]

    public static func normalizedProvider(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case deepSeekProviderID, cerebrasProviderID:
            return normalized
        default:
            return dashScopeProviderID
        }
    }

    public static func defaults(forProvider provider: String) -> TranslationProviderDefaults {
        switch normalizedProvider(provider) {
        case deepSeekProviderID:
            return TranslationProviderDefaults(
                baseURL: defaultDeepSeekBaseURL,
                modelID: defaultDeepSeekModelID,
                reasoningEffort: defaultDeepSeekReasoningEffort
            )
        case cerebrasProviderID:
            return TranslationProviderDefaults(
                baseURL: defaultCerebrasBaseURL,
                modelID: defaultCerebrasModelID,
                reasoningEffort: defaultCerebrasReasoningEffort
            )
        default:
            return TranslationProviderDefaults(
                baseURL: defaultDashScopeBaseURL,
                modelID: defaultDashScopeModelID,
                reasoningEffort: ""
            )
        }
    }

    public static func defaultsForProviderSwitch(
        toProvider provider: String,
        currentBaseURL: String,
        currentModelID: String,
        currentReasoningEffort: String
    ) -> TranslationProviderDefaults {
        let targetDefaults = defaults(forProvider: provider)
        let trimmedBaseURL = currentBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModelID = currentModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReasoningEffort = currentReasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return TranslationProviderDefaults(
            baseURL: shouldReplaceKnownValue(trimmedBaseURL, knownValues: knownDefaultBaseURLs)
                ? targetDefaults.baseURL
                : trimmedBaseURL,
            modelID: shouldReplaceKnownValue(trimmedModelID, knownValues: knownDefaultModelIDs)
                ? targetDefaults.modelID
                : trimmedModelID,
            reasoningEffort: shouldReplaceReasoningEffort(
                trimmedReasoningEffort,
                targetProvider: provider
            ) ? targetDefaults.reasoningEffort : trimmedReasoningEffort
        )
    }

    public static func requestBaseURL(provider: String, configuredBaseURL: String) -> String {
        let normalized = normalizedProvider(provider)
        if normalized == dashScopeProviderID {
            return defaultDashScopeBaseURL
        }
        let trimmed = configuredBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaults(forProvider: normalized).baseURL : trimmed
    }

    public static func normalizedModelID(_ value: String, provider: String) -> String {
        let normalized = normalizedProvider(provider)
        if normalized == dashScopeProviderID {
            return defaultDashScopeModelID
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaults(forProvider: normalized).modelID : trimmed
    }

    public static func normalizedReasoningEffort(_ value: String, provider: String) -> String {
        let normalized = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case deepSeekProviderID:
            return deepSeekReasoningEffortOptions.contains(trimmed) ? trimmed : defaultDeepSeekReasoningEffort
        case cerebrasProviderID:
            return cerebrasReasoningEffortOptions.contains(trimmed) ? trimmed : defaultCerebrasReasoningEffort
        default:
            return ""
        }
    }

    public static func sendsReasoningEffort(provider: String) -> Bool {
        let normalized = normalizedProvider(provider)
        return normalized == deepSeekProviderID || normalized == cerebrasProviderID
    }

    public static func retriesTransientHTTPStatus(provider: String) -> Bool {
        let normalized = normalizedProvider(provider)
        return normalized == deepSeekProviderID || normalized == cerebrasProviderID
    }

    private static func shouldReplaceKnownValue(_ value: String, knownValues: [String]) -> Bool {
        value.isEmpty || knownValues.contains { $0.caseInsensitiveCompare(value) == .orderedSame }
    }

    private static func shouldReplaceReasoningEffort(_ value: String, targetProvider: String) -> Bool {
        if value.isEmpty || knownDefaultReasoningEfforts.contains(value) {
            return true
        }
        return normalizedReasoningEffort(value, provider: targetProvider) != value
    }
}

public enum TranslationChatRequestPolicy {
    public static let defaultDeepSeekModelID = TranslationProviderPolicy.defaultDeepSeekModelID
    public static let defaultDeepSeekReasoningEffort = TranslationProviderPolicy.defaultDeepSeekReasoningEffort
    public static let reasoningEffortOptions = TranslationProviderPolicy.deepSeekReasoningEffortOptions
    /// DeepSeek JSON Output needs a high enough ceiling so structured replies are not truncated mid-object.
    public static let deepSeekJSONOutputMaxTokens = 8192

    public static func requestBody(
        provider: String,
        modelID: String,
        reasoningEffort: String,
        messages: [[String: String]]
    ) -> [String: Any] {
        let normalizedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var body: [String: Any] = [
            "model": normalizedModelID(modelID, provider: normalizedProvider),
            "messages": messages,
            "temperature": 0.2,
            "top_p": 0.7
        ]

        if TranslationProviderPolicy.sendsReasoningEffort(provider: normalizedProvider) {
            body["reasoning_effort"] = normalizedReasoningEffort(reasoningEffort, provider: normalizedProvider)
        }
        // DeepSeek JSON Output: force json_object and cap tokens so structured replies stay intact.
        if TranslationProviderPolicy.normalizedProvider(normalizedProvider)
            == TranslationProviderPolicy.deepSeekProviderID {
            body["response_format"] = ["type": "json_object"]
            body["max_tokens"] = deepSeekJSONOutputMaxTokens
        }
        return body
    }

    public static func normalizedModelID(_ value: String) -> String {
        normalizedModelID(value, provider: TranslationProviderPolicy.deepSeekProviderID)
    }

    public static func normalizedModelID(_ value: String, provider: String) -> String {
        TranslationProviderPolicy.normalizedModelID(value, provider: provider)
    }

    public static func normalizedReasoningEffort(_ value: String) -> String {
        normalizedReasoningEffort(value, provider: TranslationProviderPolicy.deepSeekProviderID)
    }

    public static func normalizedReasoningEffort(_ value: String, provider: String) -> String {
        TranslationProviderPolicy.normalizedReasoningEffort(value, provider: provider)
    }
}

public enum TranslationRateLimitPolicy {
    public static let cerebrasMinimumRequestIntervalSeconds = 12

    public static func minimumRequestIntervalSeconds(forProvider provider: String) -> Int {
        TranslationProviderPolicy.normalizedProvider(provider) == TranslationProviderPolicy.cerebrasProviderID
            ? cerebrasMinimumRequestIntervalSeconds
            : 0
    }
}

/// Local subtitle pipeline version stamped on translation manifests.
/// Bump when open-to-rebuild invalidation of cached dual subtitles is required.
public enum SubtitlePipelineVersion {
    /// v4: word-level single timing source, local acoustic–semantic sentence splits,
    /// reflective (direct→reflect→retranslate) translation, and dual-track
    /// display/playback subtitles. Older complete artifacts remain playable and
    /// surface a manual "upgrade subtitle quality" entry instead of auto-rebuilding.
    public static let current = 4

    public static func isCurrent(_ version: Int?) -> Bool {
        version == current
    }

    /// Whether a stored artifact is a complete, playable legacy build (older than the
    /// current pipeline but still decodable). Used to surface the manual upgrade entry
    /// without forcing an automatic rebuild on page open.
    public static func isPlayableLegacy(_ version: Int?) -> Bool {
        guard let version else { return true }
        return version < current
    }
}

/// Stable fingerprint of a transcription's English text so saved translations
/// can be rejected when a later ASR run changes segment boundaries.
public enum TranscriptionFingerprint {
    public static func make(segments: [LearningSegment]) -> String {
        let texts = segments.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let payload = "\(texts.count)\n" + texts.joined(separator: "\n")
        return SubtitleArtifactHash.sha256Hex(payload)
    }

    public static func make(cues: [YTCue]) -> String {
        make(segments: cues.map { cue in
            LearningSegment(
                sequence: cue.id,
                startMS: Int((cue.start * 1000).rounded()),
                endMS: Int((cue.end * 1000).rounded()),
                text: cue.text
            )
        })
    }
}

public enum TranslationResultMerger {
    /// Maximum |startMS| delta allowed when salvaging a translation by exact English text.
    public static let startMSTolerance = 1_000

    public static func apply(
        translationsBySequence: [Int: String],
        to segments: [LearningSegment]
    ) -> [LearningSegment] {
        var updated = segments
        for index in updated.indices {
            guard let translation = translationsBySequence[updated[index].sequence]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !translation.isEmpty
            else {
                continue
            }
            updated[index].translation = translation
        }
        return updated
    }

    /// Merge previously saved translations onto a fresh transcription.
    ///
    /// - Fingerprint match (or legacy saved fingerprint inferred from `saved`): sequence merge.
    /// - Fingerprint mismatch: salvage only segments whose English text matches exactly and
    ///   whose start time is within `startMSTolerance`; everything else is left blank for retranslation.
    public static func mergeSavedTranslations(
        saved: [LearningSegment],
        onto source: [LearningSegment],
        savedFingerprint: String? = nil
    ) -> [LearningSegment] {
        guard !saved.isEmpty, !source.isEmpty else { return source }
        let sourceFingerprint = TranscriptionFingerprint.make(segments: source)
        let effectiveSavedFingerprint = savedFingerprint ?? TranscriptionFingerprint.make(segments: saved)
        if effectiveSavedFingerprint == sourceFingerprint {
            let translations = Dictionary(
                uniqueKeysWithValues: saved.compactMap { segment -> (Int, String)? in
                    let value = segment.translation.trimmingCharacters(in: .whitespacesAndNewlines)
                    return value.isEmpty ? nil : (segment.sequence, value)
                }
            )
            return apply(translationsBySequence: translations, to: source)
        }
        return salvage(saved: saved, onto: source)
    }

    public static func salvage(
        saved: [LearningSegment],
        onto source: [LearningSegment]
    ) -> [LearningSegment] {
        var candidatesByText: [String: [LearningSegment]] = [:]
        for segment in saved {
            let key = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty,
                  !segment.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            candidatesByText[key, default: []].append(segment)
        }

        var updated = source
        var usedSavedSequences: Set<Int> = []
        for index in updated.indices {
            let key = updated[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, let candidates = candidatesByText[key] else {
                updated[index].translation = ""
                continue
            }
            guard let match = candidates.first(where: { candidate in
                !usedSavedSequences.contains(candidate.sequence)
                    && abs(candidate.startMS - updated[index].startMS) <= startMSTolerance
            }) else {
                updated[index].translation = ""
                continue
            }
            usedSavedSequences.insert(match.sequence)
            updated[index].translation = match.translation
            if updated[index].learningText.isEmpty {
                updated[index].learningText = match.learningText.isEmpty ? updated[index].text : match.learningText
            }
            if updated[index].speaker == nil {
                updated[index].speaker = match.speaker
            }
            if updated[index].notes.isEmpty {
                updated[index].notes = match.notes
            }
            if updated[index].words.isEmpty {
                updated[index].words = match.words
            }
        }
        return updated
    }
}

public enum TranslationRetryPolicy {
    public static func shouldRetryHTTPStatus(_ statusCode: Int, provider: String) -> Bool {
        guard TranslationProviderPolicy.retriesTransientHTTPStatus(provider: provider) else {
            return false
        }
        return statusCode == 429 || statusCode == 500 || statusCode == 503
    }

    public static func retryDelaySeconds(
        statusCode: Int,
        provider: String,
        attempt: Int,
        headers: [String: String]
    ) -> Int? {
        guard shouldRetryHTTPStatus(statusCode, provider: provider) else { return nil }
        if statusCode == 429,
           let retryAfter = headerValue(named: "Retry-After", in: headers),
           let seconds = Int(retryAfter.trimmingCharacters(in: .whitespacesAndNewlines)),
           seconds > 0 {
            return seconds
        }
        if statusCode == 429,
           TranslationProviderPolicy.normalizedProvider(provider) == TranslationProviderPolicy.cerebrasProviderID {
            return 60
        }
        let exponent = max(0, attempt - 1)
        return min(8, 2 << exponent)
    }

    private static func headerValue(named name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public struct LocalNetworkInterface: Equatable, Sendable {
    public var name: String
    public var address: String
    public var isUp: Bool
    public var isLoopback: Bool

    public init(name: String, address: String, isUp: Bool, isLoopback: Bool) {
        self.name = name
        self.address = address
        self.isUp = isUp
        self.isLoopback = isLoopback
    }
}

public enum LocalNetworkAddressPolicy {
    public static func preferredIPv4Address(from interfaces: [LocalNetworkInterface]) -> String? {
        let candidates = interfaces.filter(isUsablePrivateLANInterface)
        return candidates.first { $0.name == "en0" }?.address
            ?? candidates.first { $0.name == "en1" }?.address
            ?? candidates.first?.address
    }

    private static func isUsablePrivateLANInterface(_ interface: LocalNetworkInterface) -> Bool {
        interface.isUp
            && !interface.isLoopback
            && !isVirtualOrVPNInterface(interface.name)
            && isPrivateIPv4(interface.address)
            && !interface.address.hasPrefix("169.254.")
    }

    private static func isVirtualOrVPNInterface(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("utun")
            || lower.hasPrefix("tun")
            || lower.hasPrefix("tap")
            || lower.hasPrefix("ppp")
            || lower.hasPrefix("ipsec")
            || lower.hasPrefix("bridge")
            || lower.hasPrefix("vmnet")
            || lower.hasPrefix("vnic")
            || lower.hasPrefix("llw")
            || lower.hasPrefix("awdl")
    }

    private static func isPrivateIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ 0...255 ~= $0 }) else { return false }
        if parts[0] == 10 { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        return false
    }
}

public enum LocalSetupHTTPResponseBuilder {
    public static func response(body: String, status: String, contentType: String) -> Data {
        let bodyData = Data(body.utf8)
        let header = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(bodyData.count)",
            "Cache-Control: no-store",
            "Referrer-Policy: no-referrer",
            "X-Content-Type-Options: nosniff",
            "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        var data = Data(header.utf8)
        data.append(bodyData)
        return data
    }
}

public enum LocalSetupDismissalPolicy {
    public static func shouldDismissAfterSuccessfulSubmission(message: String) -> Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum ConfigurationRequirement: String, CaseIterable, Equatable, Sendable {
    case youtubeAPIKey
    case dashscopeAPIKey
    case translationAPIKey
}

public struct ConfigurationReadinessSummary: Equatable, Sendable {
    public var missingRequirements: [ConfigurationRequirement]
    public var completedCount: Int
    public var totalCount: Int

    public var isComplete: Bool {
        missingRequirements.isEmpty
    }

    public var hasYouTubeMetadataKey: Bool {
        !missingRequirements.contains(.youtubeAPIKey)
    }

    public var hasPodcastGenerationKeys: Bool {
        !missingRequirements.contains(.dashscopeAPIKey)
            && !missingRequirements.contains(.translationAPIKey)
    }
}

public enum ConfigurationReadinessPolicy {
    public static func summary(
        youtubeAPIKey: String,
        dashscopeAPIKey: String,
        translationAPIKey: String
    ) -> ConfigurationReadinessSummary {
        let values: [(ConfigurationRequirement, String)] = [
            (.youtubeAPIKey, youtubeAPIKey),
            (.dashscopeAPIKey, dashscopeAPIKey),
            (.translationAPIKey, translationAPIKey)
        ]
        let missing = values
            .filter { $0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(\.0)
        return ConfigurationReadinessSummary(
            missingRequirements: missing,
            completedCount: values.count - missing.count,
            totalCount: values.count
        )
    }
}

public struct RefreshAvailability: Equatable, Sendable {
    public var canRefresh: Bool
    public var disabledReason: String?
}

public enum SubscriptionRefreshAvailabilityPolicy {
    public static func podcastRefreshAvailability(
        isLoading: Bool,
        hasRequiredGenerationKeys _: Bool
    ) -> RefreshAvailability {
        if isLoading {
            return RefreshAvailability(canRefresh: false, disabledReason: "正在刷新，请稍候。")
        }
        return RefreshAvailability(canRefresh: true, disabledReason: nil)
    }

    public static func canRefreshPodcastSubscriptions(
        isLoading: Bool,
        hasRequiredGenerationKeys: Bool
    ) -> Bool {
        podcastRefreshAvailability(
            isLoading: isLoading,
            hasRequiredGenerationKeys: hasRequiredGenerationKeys
        ).canRefresh
    }
}

public enum PodcastEpisodeProcessingAction: Equatable, Sendable {
    case start
    case openSettings
    case retry
    case playback
    case none
}

public enum AsyncOperationErrorPresentationPolicy {
    public static func shouldPresent(_ error: Error) -> Bool {
        !(error is CancellationError)
    }
}

public enum PodcastEpisodeProcessingPolicy {
    public static func action(
        status: String,
        hasGenerationKeys: Bool,
        allowsCloudLookup: Bool = false
    ) -> PodcastEpisodeProcessingAction {
        switch status {
        case "completed": .playback
        case "running": .none
        case "failed": hasGenerationKeys ? .retry : .openSettings
        default: (hasGenerationKeys || allowsCloudLookup) ? .start : .openSettings
        }
    }
}
