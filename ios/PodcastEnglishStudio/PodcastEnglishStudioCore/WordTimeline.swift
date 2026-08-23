import Foundation

// MARK: - Timing source

/// Records how a segment's timestamps were produced so the UI and freshness
/// policy can distinguish word-level precise artifacts from legacy fallbacks.
public enum SegmentTimingSource: String, Codable, Hashable, Sendable {
    /// Aligned against a word-level timestamp stream (highest precision).
    case wordTimeline
    /// Produced from a semantic/cue source without a word stream (sentence-level).
    case semantic
    /// Legacy cue/sentence timing kept verbatim (no word stream available).
    case legacy
}

// MARK: - Playback sentence (复读整句)

/// One complete logical sentence a display sub-clause belongs to. When a long
/// sentence is split into several display sub-clauses, every sub-clause carries
/// the same `PlaybackSentence` so audio/video repeat and previous/next navigation
/// still operate on the whole sentence, never on an individual fragment.
public struct PlaybackSentence: Codable, Hashable, Sendable {
    /// Shared identifier for every display sub-clause derived from the same sentence.
    public var id: Int
    /// Whole-sentence source text.
    public var text: String
    /// Whole-sentence translation.
    public var translation: String
    /// Whole-sentence start in milliseconds.
    public var startMS: Int
    /// Whole-sentence end in milliseconds.
    public var endMS: Int

    public init(id: Int, text: String, translation: String, startMS: Int, endMS: Int) {
        self.id = id
        self.text = text
        self.translation = translation
        self.startMS = startMS
        self.endMS = endMS
    }
}

// MARK: - Word timeline aligner

/// Errors raised when a word stream exists but a sentence cannot be aligned to it.
/// Per the pipeline contract these are fatal to artifact generation — we never fall
/// back to guessed timestamps once a word stream is present.
public enum WordTimelineAlignmentError: Error, Equatable, LocalizedError {
    /// A non-empty word stream was provided but yielded no usable aligned words.
    case emptyWordStream
    /// The sentence at the given index could not be located in the word stream.
    case sentenceMismatch(index: Int, sentence: String)

    public var errorDescription: String? {
        switch self {
        case .emptyWordStream:
            "A word-level timestamp stream was present but contained no usable words."
        case .sentenceMismatch(let index, let sentence):
            "Sentence \(index) could not be aligned to the word-level timestamp stream: \"\(sentence.prefix(60))\"."
        }
    }
}

/// Aligns sentences to a single word-level timestamp stream (the "single timing source").
///
/// The algorithm is an order-preserving substring match over normalized text:
/// - Both the concatenated word stream and each sentence are normalized with NFKC,
///   POSIX lowercase, and removal of everything except letters and digits, so
///   punctuation/casing/spacing differences never break matching.
/// - A character-position → word-index map lets us translate a character hit back
///   into the first and last source word, whose timestamps become the sentence's.
/// - Each sentence is searched starting from the end of the previous match, which
///   keeps repeated sentences in order and guarantees a monotonic timeline.
public enum WordTimelineSentenceAligner {
    public struct Options: Sendable, Equatable {
        /// When the source data carries no word stream at all, fall back to the
        /// sentence's own timing (marked `timingSource == .legacy`) instead of throwing.
        public var allowSentenceFallbackWithoutWords: Bool

        public init(allowSentenceFallbackWithoutWords: Bool = true) {
            self.allowSentenceFallbackWithoutWords = allowSentenceFallbackWithoutWords
        }

        public static let `default` = Options()
    }

    /// Input sentence to align. Timing/text are only used as fallback when no word
    /// stream exists; on success they are replaced by word-derived values.
    public struct SentenceInput: Sendable, Equatable {
        public var text: String
        public var startMS: Int
        public var endMS: Int

        public init(text: String, startMS: Int, endMS: Int) {
            self.text = text
            self.startMS = startMS
            self.endMS = endMS
        }
    }

    /// Align `sentences` against the word stream `words`.
    ///
    /// - Throws: `WordTimelineAlignmentError` when a word stream exists but any
    ///   sentence cannot be matched. With an empty word stream, returns the inputs
    ///   unchanged (timing marked `.legacy`) when `allowSentenceFallbackWithoutWords`
    ///   is set, otherwise throws `.emptyWordStream`.
    public static func align(
        sentences: [SentenceInput],
        to words: [TranscriptWord],
        options: Options = .default
    ) throws -> [LearningSegment] {
        let stream = NormalizedWordStream(words: words)
        guard !stream.isEmpty else {
            if options.allowSentenceFallbackWithoutWords {
                return sentences.enumerated().map { index, sentence in
                    LearningSegment(
                        sequence: index + 1,
                        startMS: sentence.startMS,
                        endMS: max(sentence.endMS, sentence.startMS + 1),
                        text: sentence.text,
                        learningText: sentence.text,
                        timingSource: .legacy
                    )
                }
            }
            throw WordTimelineAlignmentError.emptyWordStream
        }

        var aligned: [LearningSegment] = []
        aligned.reserveCapacity(sentences.count)
        var searchStart = 0

        for (index, sentence) in sentences.enumerated() {
            let key = NormalizedText.normalize(sentence.text)
            guard !key.isEmpty else {
                throw WordTimelineAlignmentError.sentenceMismatch(index: index, sentence: sentence.text)
            }
            guard let range = stream.find(key, startingAt: searchStart) else {
                throw WordTimelineAlignmentError.sentenceMismatch(index: index, sentence: sentence.text)
            }

            let slice = stream.wordSlice(range)
            let startMS = slice.first?.startMS ?? 0
            let endMS = max(slice.last?.endMS ?? startMS + 1, startMS + 1)
            aligned.append(
                LearningSegment(
                    sequence: index + 1,
                    startMS: startMS,
                    endMS: endMS,
                    text: sentence.text,
                    learningText: sentence.text,
                    words: slice,
                    timingSource: .wordTimeline
                )
            )
            searchStart = range.upperBound
        }
        return aligned
    }

    /// Convenience overload aligning already-formed `LearningSegment`s against a
    /// word stream, preserving their translation/speaker/notes/playback metadata.
    public static func align(
        segments: [LearningSegment],
        to words: [TranscriptWord],
        options: Options = .default
    ) throws -> [LearningSegment] {
        let inputs = segments.map { SentenceInput(text: $0.text, startMS: $0.startMS, endMS: $0.endMS) }
        let aligned = try align(sentences: inputs, to: words, options: options)
        return zip(segments, aligned).map { original, alignedSegment in
            var copy = original
            copy.startMS = alignedSegment.startMS
            copy.endMS = alignedSegment.endMS
            if !alignedSegment.words.isEmpty {
                copy.words = alignedSegment.words
            }
            copy.timingSource = alignedSegment.timingSource
            return copy
        }
    }
}

// MARK: - Normalization primitives

/// Shared text normalization: NFKC, POSIX lowercase, strip everything but letters/digits.
enum NormalizedText {
    static func normalize(_ text: String) -> String {
        let folded = text
            .precomposedStringWithCompatibilityMapping
            .lowercased()
        var result = String()
        result.reserveCapacity(folded.count)
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}

/// The concatenated, normalized word stream plus a char-position → word-index map.
struct NormalizedWordStream {
    /// Normalized text of each word (parallel to `words`).
    private let keys: [String]
    /// For each character position in the concatenated stream, the source word index.
    private let charToWord: [Int]
    /// The concatenated normalized text of all words.
    private let joined: String
    /// Source words (may include words whose normalized key is empty, e.g. pure punctuation).
    private let words: [TranscriptWord]
    /// Start offset (in `joined`) of each word's key.
    private let keyStart: [Int]

    init(words: [TranscriptWord]) {
        self.words = words
        var keys: [String] = []
        var charToWord: [Int] = []
        var keyStart: [Int] = []
        var joined = String()
        var position = 0
        for (index, word) in words.enumerated() {
            let surface = word.punctuation.map { word.text + $0 } ?? word.text
            let key = NormalizedText.normalize(surface)
            keys.append(key)
            keyStart.append(position)
            for _ in 0..<key.count {
                charToWord.append(index)
            }
            joined += key
            position += key.count
        }
        self.keys = keys
        self.charToWord = charToWord
        self.joined = joined
        self.keyStart = keyStart
    }

    var isEmpty: Bool { joined.isEmpty }

    /// Finds `needle` at or after `fromPosition` in the joined stream, returning the
    /// character range. Returns nil when not found.
    func find(_ needle: String, startingAt fromPosition: Int) -> Range<Int>? {
        guard !needle.isEmpty, fromPosition <= joined.count else { return nil }
        let joinedChars = Array(joined)
        let needleChars = Array(needle)
        guard needleChars.count <= joinedChars.count else { return nil }
        var start = max(0, fromPosition)
        let lastStart = joinedChars.count - needleChars.count
        while start <= lastStart {
            var matched = true
            for offset in 0..<needleChars.count where joinedChars[start + offset] != needleChars[offset] {
                matched = false
                break
            }
            if matched {
                return start..<(start + needleChars.count)
            }
            start += 1
        }
        return nil
    }

    /// Maps a character range in the joined stream back to the inclusive source word slice.
    func wordSlice(_ range: Range<Int>) -> [TranscriptWord] {
        guard !range.isEmpty, range.lowerBound < charToWord.count else { return [] }
        let firstWord = charToWord[range.lowerBound]
        let lastWord = charToWord[min(range.upperBound - 1, charToWord.count - 1)]
        guard firstWord <= lastWord, lastWord < words.count else { return [] }
        return Array(words[firstWord...lastWord])
    }

    /// Start offset (in the joined stream) of the word at `index`'s normalized key.
    func startOffset(ofWord index: Int) -> Int {
        guard keys.indices.contains(index) else { return joined.count }
        return keyStart[index]
    }
}
