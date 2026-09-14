import Foundation

public enum ChineseFrontendError: Error {
    case unknownText(String)
    case unsupportedLexicon
}

/// Experimental dictionary frontend. Quality and parity must be evaluated before app use.
public struct ChineseFrontend {
    struct Word: Decodable {
        let frequency: Int
        let phonemes: String
    }
    struct Lexicon: Decodable {
        let version: String
        let words: [String: Word]
        let english: [String: String]
    }
    private let lexicon: Lexicon
    private let logTotal: Double
    private let maxWordLength: Int
    public let version: String

    public init(lexiconURL: URL) throws {
        let lexicon = try JSONDecoder().decode(Lexicon.self, from: Data(contentsOf: lexiconURL))
        guard lexicon.version == "v16-lexicon-poc-1", !lexicon.words.isEmpty else {
            throw ChineseFrontendError.unsupportedLexicon
        }
        self.lexicon = lexicon
        self.version = lexicon.version
        self.logTotal = log(lexicon.words.values.reduce(0.0) { $0 + Double($1.frequency) })
        self.maxWordLength = lexicon.words.keys.map(\.count).max() ?? 1
    }

    /// Marks the voice model has tokens for.
    private static let spokenMarks = ";:,.!?/—…\"()“”"
    /// Marks that carry prosody but have no token; the closest spoken mark keeps the pause.
    private static let foldedMarks: [String: String] = [
        "'": "\"", "‘": "“", "’": "”", "「": "“", "」": "”", "『": "“", "』": "”",
        "[": "(", "]": ")", "{": "(", "}": ")", "【": "(", "】": ")", "〔": "(", "〕": ")",
        "–": "—", "―": "—", "~": "—", "〜": "—"]

    public func phonemes(for text: String) throws -> String {
        let normalized = normalize(text)
        let expression = try NSRegularExpression(pattern: "[\\p{Han}]+|[A-Za-z]+(?:['-][A-Za-z]+)*|\\s+|.", options: [.dotMatchesLineSeparators])
        var output: [String] = []
        for match in expression.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) {
            guard let range = Range(match.range, in: normalized) else { continue }
            let token = String(normalized[range])
            if token.allSatisfy(\.isWhitespace) { continue }
            if token.unicodeScalars.allSatisfy({ (0x3400...0x9FFF).contains($0.value) }) {
                output.append(try chinese(token))
            } else if token.first?.isASCII == true, token.first?.isLetter == true {
                output.append(try english(token))
            } else if token.count == 1, Self.spokenMarks.contains(token) {
                output.append(token)
            } else if token.count == 1, let folded = Self.foldedMarks[token] {
                output.append(folded)
            } else if token.count == 1, let mark = token.first, !mark.isLetter, !mark.isNumber {
                // Marks the voice has no sound for (interpuncts, speaker arrows, emoji) are
                // silent. Dropping one never changes a word, so it must not fail the sentence.
                continue
            } else {
                throw ChineseFrontendError.unknownText(token)
            }
        }
        return output.joined(separator: " ")
    }

    private func chinese(_ text: String) throws -> String {
        let chars = Array(text)
        var scores = Array(repeating: -Double.infinity, count: chars.count + 1)
        var ends = Array(repeating: 0, count: chars.count)
        scores[chars.count] = 0
        for start in stride(from: chars.count - 1, through: 0, by: -1) {
            for end in (start + 1)...min(chars.count, start + maxWordLength) {
                let word = String(chars[start..<end])
                guard let entry = lexicon.words[word], scores[end].isFinite else { continue }
                let score = log(Double(max(1, entry.frequency))) - logTotal + scores[end]
                if score > scores[start] {
                    scores[start] = score
                    ends[start] = end
                }
            }
        }
        guard scores[0].isFinite else { throw ChineseFrontendError.unknownText(text) }
        var tokens: [(text: String, phones: String)] = []
        var start = 0
        while start < chars.count {
            let end = ends[start]
            let word = String(chars[start..<end])
            guard let phones = lexicon.words[word]?.phonemes else { throw ChineseFrontendError.unknownText(word) }
            tokens.append((word, phones))
            start = end
        }
        // Context-sensitive prefix tones cannot be baked into isolated dictionary words.
        if tokens.count > 1 {
            for index in 0..<(tokens.count - 1) {
                let nextTone = tokens[index + 1].phones.first(where: { "12345".contains($0) })
                if tokens[index].text == "不", nextTone == "4" {
                    tokens[index].phones = replacingLastTone(tokens[index].phones, with: "2")
                } else if tokens[index].text == "一", let nextTone {
                    let numeric = tokens[index + 1].text.allSatisfy { "零一二三四五六七八九十百千万亿".contains($0) }
                    if !numeric {
                        tokens[index].phones = replacingLastTone(tokens[index].phones, with: nextTone == "4" || nextTone == "5" ? "2" : "4")
                    }
                } else if tokens[index].phones.last == "3", nextTone == "3" {
                    tokens[index].phones = replacingLastTone(tokens[index].phones, with: "2")
                }
            }
        }
        return tokens.map(\.phones).joined(separator: "/")
    }

    private func replacingLastTone(_ text: String, with tone: Character) -> String {
        guard let index = text.lastIndex(where: { "12345".contains($0) }) else { return text }
        var result = text
        result.replaceSubrange(index...index, with: String(tone))
        return result
    }

    private func english(_ text: String) throws -> String {
        if let phones = lexicon.english[text] ?? lexicon.english[text.lowercased()] { return phones }
        // Unknown abbreviations and product names remain audible by spelling their letters.
        return try text.filter { $0 != "-" && $0 != "'" }.map { letter in
            guard let phones = lexicon.english[String(letter).uppercased()] else {
                throw ChineseFrontendError.unknownText(String(letter))
            }
            return phones
        }.joined(separator: " ")
    }

    private func normalize(_ text: String) -> String {
        var value = text.precomposedStringWithCompatibilityMapping
        // The lexicon is simplified only; a traditional transcript reads the same words.
        value = value.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? value
        // Accented Latin names ("Réunion") stay one word for the English speller.
        value = value.applyingTransform(.stripDiacritics, reverse: false) ?? value
        // A curly apostrophe inside an English word must not split the word.
        value = replace(pattern: "([A-Za-z])[’‘]([A-Za-z])", in: value) { groups in groups[1] + "'" + groups[2] }
        let punctuation = ["，": ",", "。": ".", "、": ",", "！": "!", "？": "?", "：": ":", "；": ";",
                           "（": "(", "）": ")", "《": "“", "》": "”", "￥": "人民币", "¥": "人民币", "℃": "摄氏度"]
        for (old, new) in punctuation { value = value.replacingOccurrences(of: old, with: new) }
        value = replace(pattern: "([0-9]{4})-([0-9]{1,2})-([0-9]{1,2})", in: value) { groups in
            groups[1].map { digitName($0) }.joined() + "年" + groups[2] + "月" + groups[3] + "日"
        }
        value = replace(pattern: "([0-9]{4})年", in: value) { groups in groups[1].map { digitName($0) }.joined() + "年" }
        value = replace(pattern: "([0-9]{1,2}):([0-9]{2})", in: value) { groups in groups[1] + "点" + groups[2] + "分" }
        value = replace(pattern: "([0-9]+(?:\\.[0-9]+)?)%", in: value) { groups in "百分之" + groups[1] }
        return replace(pattern: "-?[0-9]+(?:\\.[0-9]+)?", in: value) { groups in
            let number = groups[0]
            if number.count >= 7, number.allSatisfy(\.isNumber) { return number.map { digitName($0) }.joined() }
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.numberStyle = .spellOut
            guard let decimal = Decimal(string: number, locale: Locale(identifier: "en_US_POSIX")),
                  let result = formatter.string(from: NSDecimalNumber(decimal: decimal)) else { return number }
            return result.replacingOccurrences(of: "〇", with: "零")
        }
    }

    private func digitName(_ digit: Character) -> String {
        guard let value = digit.wholeNumberValue, value < 10 else { return String(digit) }
        return String(Array("零一二三四五六七八九")[value])
    }

    private func replace(pattern: String, in text: String, transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let groups = (0..<match.numberOfRanges).map { index -> String in
                guard let range = Range(match.range(at: index), in: text) else { return "" }
                return String(text[range])
            }
            if let range = Range(match.range, in: result) { result.replaceSubrange(range, with: transform(groups)) }
        }
        return result
    }
}
