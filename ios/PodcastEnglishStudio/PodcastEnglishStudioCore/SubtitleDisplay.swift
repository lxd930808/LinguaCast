import Foundation

// MARK: - CJK-weighted length

/// Display-oriented weighted length. East-Asian scripts occupy more horizontal space
/// per glyph than Latin, so a simple `count` under-estimates the rendered width of
/// translations. Weights follow VideoLingo's display model.
public enum SubtitleWeightedLength {
    /// CJK ideographs, Japanese kana and full-width punctuation.
    public static let cjkFullWidthWeight = 1.75
    /// Hangul syllables and Jamo.
    public static let hangulWeight = 1.5
    /// Thai and every other character.
    public static let defaultWeight = 1.0

    public static func calculate(_ text: String) -> Double {
        var total = 0.0
        for scalar in text.unicodeScalars {
            total += weight(for: scalar)
        }
        return total
    }

    public static func weight(for scalar: Unicode.Scalar) -> Double {
        let value = scalar.value
        // CJK ideographs, kana, full-width forms and CJK punctuation.
        if (0x1100...0x11FF).contains(value) { return hangulWeight }              // Hangul Jamo
        if (0x2E80...0x9FFF).contains(value) { return cjkFullWidthWeight }        // CJK radicals … ideographs
        if (0xA000...0xA4CF).contains(value) { return cjkFullWidthWeight }        // Yi
        if (0xAC00...0xD7AF).contains(value) { return hangulWeight }              // Hangul syllables
        if (0xF900...0xFAFF).contains(value) { return cjkFullWidthWeight }        // CJK compat ideographs
        if (0xFE30...0xFE4F).contains(value) { return cjkFullWidthWeight }        // CJK compat forms
        if (0xFF00...0xFF60).contains(value) { return cjkFullWidthWeight }        // Full-width forms
        if (0xFFE0...0xFFE6).contains(value) { return cjkFullWidthWeight }        // Full-width signs
        if (0x3000...0x303F).contains(value) { return cjkFullWidthWeight }        // CJK punctuation
        if (0x3040...0x30FF).contains(value) { return cjkFullWidthWeight }        // Hiragana + Katakana
        if (0x31F0...0x31FF).contains(value) { return cjkFullWidthWeight }        // Katakana phonetic ext
        if (0x0E00...0x0E7F).contains(value) { return defaultWeight }             // Thai
        if (0x20000...0x2FA1F).contains(value) { return cjkFullWidthWeight }      // CJK ext B..compat sup
        return defaultWeight
    }

    /// Thai vowels/tones combine visually; treat the Thai block at the default weight.
    public static func isThai(_ scalar: Unicode.Scalar) -> Bool {
        (0x0E00...0x0E7F).contains(scalar.value)
    }
}

// MARK: - Display-split decision

/// Decides whether a source/translation pair is long enough to warrant splitting into
/// display sub-clauses, independent of how the split is performed.
public enum SubtitleDisplaySplitPolicy {
    /// Character budget a single display line should stay under.
    public static let characterBudget = 75.0
    /// Translation tolerance: split when the weighted target exceeds budget × this factor.
    public static let targetOverflowFactor = 1.2
    /// Maximum recursive split rounds.
    public static let maxRecursionDepth = 3

    public static func requiresDisplaySplit(source: String, translation: String) -> Bool {
        if Double(source.count) > characterBudget { return true }
        let targetLength = SubtitleWeightedLength.calculate(translation)
        return targetLength * targetOverflowFactor > characterBudget
    }

    public static func requiresDisplaySplit(source: String, targetWeightedLength: Double) -> Bool {
        if Double(source.count) > characterBudget { return true }
        return targetWeightedLength * targetOverflowFactor > characterBudget
    }

    /// A segment is a display-refinement candidate when it exceeds the budget and still
    /// carries a word stream (required for word-precise sub-clause timing).
    public static func isRefinementCandidate(_ segment: LearningSegment) -> Bool {
        requiresDisplaySplit(source: segment.text, translation: segment.translation)
            && !segment.words.isEmpty
    }
}

// MARK: - Display refinement status / checkpoint

/// Background display sub-clause refinement after a translation is already playable.
/// Absent on older `ready` manifests → treat as already completed.
public enum DisplayRefinementStatus: String, Codable, Sendable, Equatable {
    case pending
    case running
    case completed
}

public enum DisplayRefinementManifestPolicy {
    /// Old ready manifests without these fields are treated as already refined.
    public static func effectiveStatus(from raw: String?) -> DisplayRefinementStatus {
        guard let raw, let status = DisplayRefinementStatus(rawValue: raw) else {
            return .completed
        }
        return status
    }

    public static func needsResume(_ status: DisplayRefinementStatus) -> Bool {
        status == .pending || status == .running
    }
}

/// Per-candidate checkpoint entry. Keyed by the original (pre-split) segment sequence so
/// interrupted refinement only redoes missing candidates.
public struct DisplayRefinementCheckpointEntry: Codable, Equatable, Sendable {
    public var originalSequence: Int
    public var segments: [LearningSegment]

    public init(originalSequence: Int, segments: [LearningSegment]) {
        self.originalSequence = originalSequence
        self.segments = segments
    }
}

/// Fingerprint-scoped checkpoint written atomically after each concurrent batch.
public struct DisplayRefinementCheckpoint: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var sourceFingerprint: String
    public var entries: [DisplayRefinementCheckpointEntry]

    public init(
        schemaVersion: Int = 1,
        sourceFingerprint: String,
        entries: [DisplayRefinementCheckpointEntry] = []
    ) {
        self.schemaVersion = schemaVersion
        self.sourceFingerprint = sourceFingerprint
        self.entries = entries
    }

    public var resultsBySequence: [Int: [LearningSegment]] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.originalSequence, $0.segments) })
    }
}

/// Pure planner/assembler for display refinement — unit-testable without LLM calls.
public enum DisplayRefinementPlanner {
    public static func candidateIndices(in segments: [LearningSegment]) -> [Int] {
        segments.indices.filter { SubtitleDisplaySplitPolicy.isRefinementCandidate(segments[$0]) }
    }

    public static func needsRefinement(_ segments: [LearningSegment]) -> Bool {
        !candidateIndices(in: segments).isEmpty
    }

    /// Merge checkpointed candidate results back into the original order, then resequence.
    public static func assemble(
        original: [LearningSegment],
        refinedBySequence: [Int: [LearningSegment]]
    ) -> [LearningSegment] {
        var output: [LearningSegment] = []
        output.reserveCapacity(original.count)
        for segment in original {
            if let refined = refinedBySequence[segment.sequence], !refined.isEmpty {
                output.append(contentsOf: refined)
            } else {
                output.append(segment)
            }
        }
        for index in output.indices {
            output[index].sequence = index + 1
        }
        return output
    }

    /// Pending candidate sequences not yet recorded in the checkpoint.
    public static func pendingCandidateSequences(
        in segments: [LearningSegment],
        checkpoint: DisplayRefinementCheckpoint?
    ) -> [Int] {
        let done = Set(checkpoint?.entries.map(\.originalSequence) ?? [])
        return segments.compactMap { segment in
            guard SubtitleDisplaySplitPolicy.isRefinementCandidate(segment),
                  !done.contains(segment.sequence)
            else { return nil }
            return segment.sequence
        }
    }
}

// MARK: - Playback range / grouping helpers (dual-track)

public extension LearningSegment {
    /// Whole-sentence start (ms) used for repeat and sentence navigation. Falls back to
    /// the segment's own timing when it is not a display sub-clause of a larger sentence.
    var playbackStartMS: Int { playbackSentence?.startMS ?? startMS }

    /// Whole-sentence end (ms) used for repeat and sentence navigation.
    var playbackEndMS: Int { playbackSentence?.endMS ?? endMS }

    /// Identity of the whole sentence this segment belongs to (display sub-clauses of one
    /// sentence share it). Standalone segments use their own sequence.
    var playbackGroupID: Int { playbackSentence?.id ?? sequence }
}

public enum SentencePlaybackGrouping {
    /// Indices of `segments` with consecutive duplicates of the same playback sentence
    /// removed, so previous/next navigation and repeat operate per whole sentence.
    public static func uniquePlaybackIndices(of segments: [LearningSegment]) -> [Int] {
        var result: [Int] = []
        var lastGroup: Int?
        for index in segments.indices {
            let group = segments[index].playbackGroupID
            if group != lastGroup {
                result.append(index)
                lastGroup = group
            }
        }
        return result
    }

    /// Repeat range (seconds) covering the *whole* sentence for the segment at `index`.
    public static func playbackRange(
        forIndex index: Int,
        in segments: [LearningSegment]
    ) -> ClosedRange<TimeInterval>? {
        guard segments.indices.contains(index) else { return nil }
        let segment = segments[index]
        let start = TimeInterval(max(0, segment.playbackStartMS)) / 1_000
        let end = TimeInterval(max(segment.playbackStartMS, segment.playbackEndMS)) / 1_000
        return start...max(start, end)
    }
}

// MARK: - Translation quality mode + generation profile

/// Translation depth. `quality` runs direct→reflect→retranslate and stores the
/// retranslated `final`; `fast` runs a single direct pass.
public enum TranslationQualityMode: String, Codable, CaseIterable, Hashable, Sendable {
    case quality
    case fast

    public static let `default`: TranslationQualityMode = .quality

    public static func normalized(_ rawValue: String?) -> TranslationQualityMode {
        guard let rawValue,
              let mode = TranslationQualityMode(rawValue: rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        else { return .default }
        return mode
    }

    /// Whether this mode performs the second reflective pass.
    public var usesReflection: Bool { self == .quality }
}

/// Provenance describing how a subtitle artifact was produced. Stored on the artifact
/// envelope and the local manifest so freshness decisions and the upgrade UI can show
/// exactly which pipeline/mode generated the current subtitles.
public struct TranslationGenerationProfile: Codable, Hashable, Sendable {
    public var pipelineVersion: Int
    public var qualityMode: TranslationQualityMode
    public var timingSource: SegmentTimingSource

    public init(
        pipelineVersion: Int,
        qualityMode: TranslationQualityMode,
        timingSource: SegmentTimingSource
    ) {
        self.pipelineVersion = pipelineVersion
        self.qualityMode = qualityMode
        self.timingSource = timingSource
    }

    public static func current(
        qualityMode: TranslationQualityMode,
        timingSource: SegmentTimingSource
    ) -> TranslationGenerationProfile {
        TranslationGenerationProfile(
            pipelineVersion: SubtitlePipelineVersion.current,
            qualityMode: qualityMode,
            timingSource: timingSource
        )
    }
}

// MARK: - Artifact freshness

/// Freshness of a stored subtitle artifact relative to the current pipeline.
public enum SubtitleArtifactFreshness: String, Equatable, Sendable {
    /// Produced by the current pipeline; play normally, no upgrade offered.
    case current
    /// Older but still decodable and playable; show a manual "upgrade quality" entry.
    case playableLegacy
    /// Cannot be decoded/played by this client; must be rebuilt before use.
    case incompatible
}

public enum SubtitleArtifactFreshnessPolicy {
    /// Classify a locally-stored artifact.
    ///
    /// - `pipelineVersion`: version stamped on the artifact (nil = pre-versioning legacy).
    /// - `isDecodable`: whether the payload still parses into playable segments.
    /// - `isComplete`: whether the artifact is fully translated.
    public static func status(
        pipelineVersion: Int?,
        isDecodable: Bool,
        isComplete: Bool
    ) -> SubtitleArtifactFreshness {
        guard isDecodable else { return .incompatible }
        if SubtitlePipelineVersion.isCurrent(pipelineVersion) {
            return isComplete ? .current : .playableLegacy
        }
        // A complete artifact from an older pipeline stays playable and is offered an upgrade.
        return .playableLegacy
    }

    /// Classify a cloud-synced envelope.
    public static func status(
        envelope: SubtitleArtifactEnvelope?
    ) -> SubtitleArtifactFreshness {
        guard let envelope else { return .incompatible }
        return status(
            pipelineVersion: envelope.pipelineVersion,
            isDecodable: true,
            isComplete: envelope.isComplete
        )
    }

    /// Whether the manual "upgrade subtitle quality" entry should be shown.
    public static func shouldOfferUpgrade(_ freshness: SubtitleArtifactFreshness) -> Bool {
        freshness == .playableLegacy
    }
}
