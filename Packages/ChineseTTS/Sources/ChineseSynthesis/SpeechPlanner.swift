import Foundation

public struct PreparedSpeech {
    public let phonemes: String
    public let ids: [Int32]
    public let style: [Float]
    public init(phonemes: String, ids: [Int32], style: [Float]) {
        self.phonemes = phonemes; self.ids = ids; self.style = style
    }
}
public struct SpeechFragment {
    public let source: String
    public let characterRange: Range<Int>
    public let prepared: PreparedSpeech
    public let predictedFrames: Int
    public let bucketSeconds: Int
}
public enum SpeechPlanningError: Error { case emptyText, invalidPrediction, unsplittable, invalidBuckets }
public struct SpeechPlanner {
    public let buckets: [Int]
    public init(buckets: [Int]) throws {
        guard !buckets.isEmpty, buckets.allSatisfy({ [3, 7, 10, 15, 30].contains($0) }) else { throw SpeechPlanningError.invalidBuckets }
        self.buckets = Array(Set(buckets)).sorted()
    }
    public func plan(_ text: String, prepare: (String) throws -> PreparedSpeech,
                     predict: (PreparedSpeech) throws -> Int) throws -> [SpeechFragment] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SpeechPlanningError.emptyText }
        // Numeric expressions and Latin words remain atomic; all other graphemes remain traceable.
        let regex = try NSRegularExpression(pattern: "[A-Za-z]+(?:['-][A-Za-z]+)*|[+-]?[0-9]+(?:[.:/-][0-9]+)*(?:%|年|月|日)?|.", options: [.dotMatchesLineSeparators])
        let atoms = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
        guard atoms.joined() == text else { throw SpeechPlanningError.unsplittable }
        func split(_ parts: ArraySlice<String>, offset: Int) throws -> [SpeechFragment] {
            let raw = parts.joined()
            let input = try prepare(raw)
            if input.ids.count <= 128 {
                let frames = try predict(input)
                guard frames > 0 else { throw SpeechPlanningError.invalidPrediction }
                if let bucket = buckets.first(where: { frames <= $0 * 40 }) {
                    return [SpeechFragment(source: raw, characterRange: offset..<(offset + raw.count),
                        prepared: input, predictedFrames: frames, bucketSeconds: bucket)]
                }
            }
            guard parts.count > 1 else { throw SpeechPlanningError.unsplittable }
            let indices = Array(parts.indices.dropFirst()).filter { index in
                parts[..<index].joined().contains(where: { $0.isLetter || $0.isNumber }) &&
                parts[index...].joined().contains(where: { $0.isLetter || $0.isNumber })
            }
            let midpoint = parts.startIndex + parts.count / 2
            let punctuation = indices.filter { index in
                parts[index - 1].last.map { "。！？；，,.!?;".contains($0) } ?? false
            }
            guard let boundary = (punctuation.isEmpty ? indices : punctuation).min(by: {
                abs($0 - midpoint) < abs($1 - midpoint)
            }) else { throw SpeechPlanningError.unsplittable }
            let left = parts[..<boundary]
            return try split(left, offset: offset) + split(parts[boundary...], offset: offset + left.joined().count)
        }
        return try split(atoms[...], offset: 0)
    }
}
