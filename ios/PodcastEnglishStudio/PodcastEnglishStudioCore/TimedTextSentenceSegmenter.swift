import Foundation

// MARK: - Profile

/// Acoustic–semantic segmentation knobs. Podcast production uses `.podcast`; other
/// content types can supply their own profile without changing the DP core.
public struct TimedTextSegmentationProfile: Equatable, Sendable {
    public var softPauseMS: Int
    public var strongPauseMS: Int
    public var targetDurationMS: Int
    public var maxDurationMS: Int
    public var targetWeightedLength: Double
    public var maxWeightedLength: Double
    public var minimumWordCount: Int

    public init(
        softPauseMS: Int,
        strongPauseMS: Int,
        targetDurationMS: Int,
        maxDurationMS: Int,
        targetWeightedLength: Double,
        maxWeightedLength: Double,
        minimumWordCount: Int
    ) {
        self.softPauseMS = softPauseMS
        self.strongPauseMS = strongPauseMS
        self.targetDurationMS = targetDurationMS
        self.maxDurationMS = maxDurationMS
        self.targetWeightedLength = targetWeightedLength
        self.maxWeightedLength = maxWeightedLength
        self.minimumWordCount = minimumWordCount
    }

    /// Podcast defaults: soft 250ms / strong 700ms, target 4s·60, hard max 7s·75, ≥2 words.
    public static let podcast = TimedTextSegmentationProfile(
        softPauseMS: 250,
        strongPauseMS: 700,
        targetDurationMS: 4_000,
        maxDurationMS: 7_000,
        targetWeightedLength: 60,
        maxWeightedLength: 75,
        minimumWordCount: 2
    )
}

// MARK: - Segmenter

/// Deterministic local sentence segmenter over a word-level timestamp stream.
///
/// Cut priority (lowest cost first): sentence-end punctuation → strong pause →
/// clause punctuation → soft pause. Hard caps (max duration / weighted length) force
/// a split; without a natural boundary the most balanced word cut wins. Function-word
/// and single-word isolations are penalized. Every input word appears exactly once.
public enum TimedTextSentenceSegmenter {
    /// Build length/duration-constrained subtitle segments from a word stream.
    public static func segments(
        from words: [TranscriptWord],
        profile: TimedTextSegmentationProfile
    ) -> [LearningSegment] {
        guard !words.isEmpty else { return [] }
        // Sentence-ending punctuation and strong pauses are hard boundaries; DP then
        // packs/splits each hard chunk against soft targets and hard max caps.
        var output: [LearningSegment] = []
        for hardChunk in splitOnHardBoundaries(words, profile: profile) {
            let cuts = optimalExclusiveEnds(words: hardChunk, profile: profile)
            var start = 0
            for end in cuts {
                let slice = Array(hardChunk[start..<end])
                output.append(makeSegment(slice, sequence: output.count + 1))
                start = end
            }
        }
        return output
    }

    /// Best single cut index for display refinement (`left = words[..<index]`).
    /// Returns `nil` when the stream cannot be safely split into two non-empty parts.
    public static func bestBinarySplit(
        _ words: [TranscriptWord],
        profile: TimedTextSegmentationProfile
    ) -> Int? {
        guard words.count >= 2 else { return nil }

        var bestCut: Int?
        var bestScore = Double.greatestFiniteMagnitude
        let mid = Double(words.count) / 2.0

        for cut in 1..<words.count {
            let left = Array(words[..<cut])
            let right = Array(words[cut...])
            var score = boundaryCost(after: cut - 1, words: words, profile: profile)
            score += balanceCost(left: left, right: right)
            if left.count < profile.minimumWordCount { score += 6 }
            if right.count < profile.minimumWordCount { score += 6 }
            if left.count == 1 { score += 4 }
            if right.count == 1 { score += 4 }

            let midDistance = abs(Double(cut) - mid)
            let better: Bool
            if abs(score - bestScore) < 1e-9 {
                let bestDistance = abs(Double(bestCut ?? cut) - mid)
                better = midDistance < bestDistance - 1e-9
                    || (abs(midDistance - bestDistance) < 1e-9 && cut < (bestCut ?? cut))
            } else {
                better = score < bestScore
            }
            if better {
                bestScore = score
                bestCut = cut
            }
        }
        return bestCut
    }

    /// Podcast Pipeline seam: re-segment ASR sentences locally without any LLM call.
    /// Missing word streams or empty segmenter output keep the original sentence;
    /// speaker / notes metadata are preserved on every piece.
    public static func resegmentLearningSegments(
        _ learningSegments: [LearningSegment],
        profile: TimedTextSegmentationProfile = .podcast
    ) -> [LearningSegment] {
        var output: [LearningSegment] = []
        output.reserveCapacity(learningSegments.count)
        var changed = false

        for segment in learningSegments {
            let wordStream = segment.words
            guard !wordStream.isEmpty else {
                output.append(segment)
                continue
            }

            let pieces = segments(from: wordStream, profile: profile)
            guard !pieces.isEmpty else {
                output.append(segment)
                continue
            }

            if pieces.count != 1
                || pieces[0].startMS != segment.startMS
                || pieces[0].endMS != segment.endMS
                || pieces[0].text != segment.text {
                changed = true
            }

            for piece in pieces {
                var copy = segment
                copy.startMS = piece.startMS
                copy.endMS = piece.endMS
                copy.text = piece.text
                copy.learningText = piece.text
                copy.translation = ""
                copy.words = piece.words
                copy.timingSource = piece.timingSource ?? .wordTimeline
                output.append(copy)
            }
        }

        guard changed else { return learningSegments }
        for index in output.indices {
            output[index].sequence = index + 1
        }
        return output
    }

    // MARK: Hard / DP cuts

    /// Always cut after sentence-ending punctuation, and before a strong pause gap.
    private static func splitOnHardBoundaries(
        _ words: [TranscriptWord],
        profile: TimedTextSegmentationProfile
    ) -> [[TranscriptWord]] {
        var chunks: [[TranscriptWord]] = []
        var current: [TranscriptWord] = []
        for word in words {
            if let last = current.last {
                let gap = max(0, word.startMS - last.endMS)
                if gap >= profile.strongPauseMS {
                    chunks.append(current)
                    current = []
                }
            }
            current.append(word)
            if isSentenceEnding(word.punctuation) {
                chunks.append(current)
                current = []
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    /// Exclusive end indices of each chosen segment, always ending with `words.count`.
    private static func optimalExclusiveEnds(
        words: [TranscriptWord],
        profile: TimedTextSegmentationProfile
    ) -> [Int] {
        let n = words.count
        var dp = Array(repeating: Double.greatestFiniteMagnitude, count: n + 1)
        var prev = Array(repeating: -1, count: n + 1)
        dp[0] = 0

        for end in 1...n {
            for start in 0..<end {
                guard dp[start].isFinite else { continue }
                let slice = Array(words[start..<end])
                let duration = sliceDurationMS(slice)
                let length = weightedLength(slice)
                let exceedsMax = duration > profile.maxDurationMS || length > profile.maxWeightedLength
                if exceedsMax && slice.count > 1 { continue }

                var cost = dp[start]
                if start > 0 {
                    cost += boundaryCost(after: start - 1, words: words, profile: profile)
                }
                cost += segmentShapeCost(slice, profile: profile)

                let replace: Bool
                if abs(cost - dp[end]) < 1e-9 {
                    // Deterministic tie: prefer the start that yields a more balanced
                    // final piece (closer to target duration), then earlier start.
                    let currentBalance = shapeBalance(Array(words[prev[end]..<end]), profile: profile)
                    let candidateBalance = shapeBalance(slice, profile: profile)
                    replace = candidateBalance < currentBalance - 1e-9
                        || (abs(candidateBalance - currentBalance) < 1e-9 && start < prev[end])
                } else {
                    replace = cost < dp[end]
                }
                if replace {
                    dp[end] = cost
                    prev[end] = start
                }
            }
            // Safety: if nothing valid reached `end` (should only happen on corrupt
            // inputs), force a single-word extension from end-1.
            if !dp[end].isFinite {
                dp[end] = dp[end - 1] + 100
                prev[end] = end - 1
            }
        }

        var ends: [Int] = []
        var cursor = n
        while cursor > 0 {
            ends.append(cursor)
            let previous = prev[cursor]
            precondition(previous >= 0 && previous < cursor)
            cursor = previous
        }
        return ends.reversed()
    }

    // MARK: Costs

    /// Boundary cost of cutting *after* `index` (before `index + 1`).
    /// Priority: sentence-end → strong pause → clause punct → soft pause → none.
    private static func boundaryCost(
        after index: Int,
        words: [TranscriptWord],
        profile: TimedTextSegmentationProfile
    ) -> Double {
        precondition(index >= 0 && index + 1 < words.count)
        let left = words[index]
        let right = words[index + 1]
        let gap = max(0, right.startMS - left.endMS)

        var cost: Double
        if isSentenceEnding(left.punctuation) {
            cost = 0
        } else if gap >= profile.strongPauseMS {
            cost = 1
        } else if isClausePunctuation(left.punctuation) {
            cost = 2
        } else if gap >= profile.softPauseMS {
            cost = 4
        } else {
            // No natural boundary — only attractive when a hard max forces a cut.
            cost = 25
        }

        // Penalize splits that isolate a function word at the end of the left side
        // (e.g. "… of | the people").
        if isFunctionWord(left.text) {
            cost += 12
        }
        return cost
    }

    private static func segmentShapeCost(
        _ slice: [TranscriptWord],
        profile: TimedTextSegmentationProfile
    ) -> Double {
        let duration = Double(sliceDurationMS(slice))
        let length = weightedLength(slice)
        let targetDuration = Double(max(profile.targetDurationMS, 1))
        let targetLength = max(profile.targetWeightedLength, 1)

        var cost = 0.0
        cost += 2.0 * pow(duration / targetDuration - 1.0, 2)
        cost += 2.0 * pow(length / targetLength - 1.0, 2)

        if slice.count < profile.minimumWordCount {
            cost += 5.0 * Double(profile.minimumWordCount - slice.count)
        }
        if slice.count == 1 {
            cost += 8
        }
        if duration < targetDuration * 0.4 {
            cost += 1.5
        }
        if length < targetLength * 0.4 {
            cost += 1.5
        }
        return cost
    }

    private static func balanceCost(left: [TranscriptWord], right: [TranscriptWord]) -> Double {
        let leftLen = weightedLength(left)
        let rightLen = weightedLength(right)
        let totalLen = max(leftLen + rightLen, 1)
        let leftDur = Double(sliceDurationMS(left))
        let rightDur = Double(sliceDurationMS(right))
        let totalDur = max(leftDur + rightDur, 1)
        return abs(leftLen - rightLen) / totalLen + abs(leftDur - rightDur) / totalDur
    }

    private static func shapeBalance(
        _ slice: [TranscriptWord],
        profile: TimedTextSegmentationProfile
    ) -> Double {
        let duration = Double(sliceDurationMS(slice))
        let length = weightedLength(slice)
        return abs(duration - Double(profile.targetDurationMS)) / Double(max(profile.targetDurationMS, 1))
            + abs(length - profile.targetWeightedLength) / max(profile.targetWeightedLength, 1)
    }

    // MARK: Rendering / metrics

    private static func makeSegment(_ words: [TranscriptWord], sequence: Int) -> LearningSegment {
        let text = renderText(words)
        let startMS = words.first?.startMS ?? 0
        let endMS = max(words.last?.endMS ?? startMS + 1, startMS + 1)
        return LearningSegment(
            sequence: sequence,
            startMS: startMS,
            endMS: endMS,
            text: text,
            learningText: text,
            words: words,
            timingSource: .wordTimeline
        )
    }

    public static func renderText(_ words: [TranscriptWord]) -> String {
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

    private static func sliceDurationMS(_ words: [TranscriptWord]) -> Int {
        guard let first = words.first, let last = words.last else { return 0 }
        return max(0, last.endMS - first.startMS)
    }

    private static func weightedLength(_ words: [TranscriptWord]) -> Double {
        SubtitleWeightedLength.calculate(renderText(words))
    }

    private static func isSentenceEnding(_ punctuation: String?) -> Bool {
        guard let punctuation else { return false }
        return punctuation.contains(where: { ".?!…".contains($0) })
    }

    private static func isClausePunctuation(_ punctuation: String?) -> Bool {
        guard let punctuation else { return false }
        return punctuation.contains(where: { ",;:——–".contains($0) })
    }

    private static let functionWords: Set<String> = [
        "a", "an", "the",
        "of", "in", "on", "at", "to", "for", "from", "by", "with", "as", "into", "onto",
        "over", "under", "about", "after", "before", "between", "through", "during", "without",
        "and", "or", "but", "nor", "so", "yet", "if", "than", "that",
        "is", "are", "was", "were", "be", "been", "am", "do", "does", "did",
        "have", "has", "had", "will", "would", "could", "should", "may", "might",
        "must", "shall", "can", "not", "no", "up", "out"
    ]

    private static func isFunctionWord(_ text: String) -> Bool {
        let folded = text
            .precomposedStringWithCompatibilityMapping
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = folded.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        return functionWords.contains(stripped)
    }
}
