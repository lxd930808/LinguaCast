import CryptoKit
import Foundation

public enum TTSTranscriptError: Error, Equatable {
    case invalidIdentity
    case unsupportedLanguage
    case duplicateDisplaySequence(Int)
    case inconsistentSentence(Int)
    case invalidRange(String)
    case overlappingSegments
}

public struct TTSContentSegment: Codable, Hashable, Sendable {
    public let id: String
    public let startMS: Int
    public let endMS: Int
    public let text: String
    public let displaySequences: [Int]

    public var isReadable: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Immutable translation identity and whole-sentence mapping for local synthesis.
public struct TTSTranscriptSnapshot: Sendable {
    public let episodeID: String
    public let targetLanguage: String
    public let revision: String
    public let segments: [TTSContentSegment]

    public init(episodeID: String, targetLanguage: String, segments rows: [LearningSegment]) throws {
        guard !episodeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TTSTranscriptError.invalidIdentity
        }
        let language = targetLanguage.lowercased().replacingOccurrences(of: "_", with: "-")
        guard language == "zh" || language.hasPrefix("zh-") else {
            throw TTSTranscriptError.unsupportedLanguage
        }
        var seen = Set<Int>()
        var sentences: [Int: PlaybackSentence] = [:]
        var grouped: [String: TTSContentSegment] = [:]
        for row in rows.sorted(by: { ($0.startMS, $0.sequence) < ($1.startMS, $1.sequence) }) {
            guard seen.insert(row.sequence).inserted else {
                throw TTSTranscriptError.duplicateDisplaySequence(row.sequence)
            }
            let id = row.playbackSentence.map { "sentence:\($0.id)" } ?? "segment:\(row.sequence)"
            let start = row.playbackSentence?.startMS ?? row.startMS
            let end = row.playbackSentence?.endMS ?? row.endMS
            guard start >= 0, end > start, row.startMS >= start,
                  row.endMS <= end, row.endMS > row.startMS else {
                throw TTSTranscriptError.invalidRange(id)
            }
            if let sentence = row.playbackSentence {
                if let existing = sentences[sentence.id], existing != sentence {
                    throw TTSTranscriptError.inconsistentSentence(sentence.id)
                }
                sentences[sentence.id] = sentence
            }
            let text = row.playbackSentence?.translation ?? row.translation
            grouped[id] = TTSContentSegment(
                id: id, startMS: start, endMS: end, text: text,
                displaySequences: (grouped[id]?.displaySequences ?? []) + [row.sequence]
            )
        }
        let ordered = grouped.values.sorted { ($0.startMS, $0.id) < ($1.startMS, $1.id) }
        for pair in zip(ordered, ordered.dropFirst()) where pair.0.endMS > pair.1.startMS {
            throw TTSTranscriptError.overlappingSegments
        }
        self.episodeID = episodeID
        self.targetLanguage = language
        self.segments = ordered
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let identity = try encoder.encode(Identity(episode: episodeID, language: language, segments: ordered))
        self.revision = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    }

    public var missingTranslationCount: Int { segments.filter { !$0.isReadable }.count }

    public func segment(forDisplaySequence sequence: Int) -> TTSContentSegment? {
        segments.first { $0.displaySequences.contains(sequence) }
    }

    /// A gap selects the next segment; the transcript tail has no next segment.
    /// Missing translations are preserved until the user explicitly permits skipping.
    public func segment(atOriginalSeconds seconds: TimeInterval, skipMissing: Bool = false) -> TTSContentSegment? {
        guard seconds.isFinite else { return nil }
        let milliseconds = max(0, seconds) * 1000
        return segments.first {
            Double($0.endMS) > milliseconds && (!skipMissing || $0.isReadable)
        }
    }

    /// Where playback resumes once the user explicitly skips the segment it stopped on.
    public func nextReadableIndex(after index: Int) -> Int? {
        let start = max(0, index + 1)
        guard start < segments.count else { return nil }
        return segments[start...].firstIndex { $0.isReadable }
    }

    /// Playback time is media time, independent of the playback rate.
    public func originalSeconds(segmentID: String, playedSeconds: TimeInterval, totalSeconds: TimeInterval?) -> TimeInterval? {
        guard let segment = segments.first(where: { $0.id == segmentID }) else { return nil }
        let start = Double(segment.startMS) / 1000
        guard let totalSeconds, totalSeconds.isFinite, totalSeconds > 0,
              playedSeconds.isFinite else { return start }
        let fraction = min(1, max(0, playedSeconds / totalSeconds))
        return start + fraction * Double(segment.endMS - segment.startMS) / 1000
    }

    private struct Identity: Encodable {
        let episode: String
        let language: String
        let segments: [TTSContentSegment]
    }
}

/// A mapping exists only after a complete audio file has been validated.
public struct TTSRenderedFragment: Codable, Equatable, Sendable {
    public let segmentID: String
    public let displaySequences: [Int]
    public let fragmentIndex: Int
    public let fragmentCount: Int
    public let originalStartMS: Int
    public let originalEndMS: Int
    public let sampleCount: Int
    public let rhythmVersion: String
    public let audioURL: URL

    public init(segment: TTSContentSegment, fragmentIndex: Int, fragmentCount: Int,
                sampleCount: Int, rhythmVersion: String, audioURL: URL) {
        self.segmentID = segment.id
        self.displaySequences = segment.displaySequences
        self.fragmentIndex = fragmentIndex
        self.fragmentCount = fragmentCount
        self.originalStartMS = segment.startMS
        self.originalEndMS = segment.endMS
        self.sampleCount = sampleCount
        self.rhythmVersion = rhythmVersion
        self.audioURL = audioURL
    }
    public var seconds: Double { Double(sampleCount) / 24000 }
}

public enum TTSRenderedTimeline {
    /// Stop at the first missing content/model fragment. No estimated total is exposed.
    public static func continuousPrefix(snapshot: TTSTranscriptSnapshot,
                                        fragments: [TTSRenderedFragment], version: String) -> [(TTSRenderedFragment, Double)] {
        var result: [(TTSRenderedFragment, Double)] = []
        var position = 0.0
        for segment in snapshot.segments {
            let known = fragments.filter { $0.segmentID == segment.id && $0.rhythmVersion == version }
                .sorted { $0.fragmentIndex < $1.fragmentIndex }
            guard let first = known.first, first.fragmentIndex == 0, first.fragmentCount > 0 else { break }
            for index in 0..<first.fragmentCount {
                guard let fragment = known.first(where: { $0.fragmentIndex == index }),
                      fragment.sampleCount > 0, fragment.fragmentCount == first.fragmentCount else { return result }
                result.append((fragment, position))
                position += fragment.seconds
            }
        }
        return result
    }
}
