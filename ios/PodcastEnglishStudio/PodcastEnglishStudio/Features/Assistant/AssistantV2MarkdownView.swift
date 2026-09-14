import SwiftUI

#if os(iOS)
/// A single parsed markdown block. The V2 report/message body arrives as one markdown string;
/// rendering it through `Text(AttributedString(markdown:, .full))` collapses every heading, list
/// and paragraph break into one inline run — the "wall of text" problem. Splitting into blocks and
/// laying each out in a `VStack` restores real document structure.
struct AssistantMarkdownBlock: Identifiable {
    enum Kind: Hashable {
        case heading(Int)
        case paragraph
        case bullet
        case ordered(Int)
        case quote
        case code
        case divider
    }

    let id = UUID()
    let kind: Kind
    let text: String
}

/// Renders a markdown string as stacked, individually styled blocks. Inline emphasis, links and
/// code still render via `AttributedString`; inline `[cN]` citation markers are tinted so they read
/// as references instead of raw noise inside the prose.
struct AssistantV2MarkdownView: View {
    let markdown: String
    let cache: AssistantV2MarkdownCache
    var cacheKey: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(cache.blocks(markdown, key: cacheKey)) { block in
                row(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func row(for block: AssistantMarkdownBlock) -> some View {
        switch block.kind {
        case .heading(let level):
            Text(cache.inline(block.text))
                .font(Self.headingFont(level))
                .foregroundStyle(LinguaTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, level <= 2 ? 6 : 2)
        case .paragraph:
            Text(cache.inline(block.text))
                .font(.body)
                .foregroundStyle(LinguaTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "•")
                    .font(.body)
                    .foregroundStyle(LinguaTheme.secondaryText)
                Text(cache.inline(block.text))
                    .font(.body)
                    .foregroundStyle(LinguaTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .ordered(let number):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "\(number).")
                    .font(.body.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(LinguaTheme.secondaryText)
                Text(cache.inline(block.text))
                    .font(.body)
                    .foregroundStyle(LinguaTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .quote:
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(LinguaTheme.accent.opacity(0.55))
                    .frame(width: 3)
                Text(cache.inline(block.text))
                    .font(.body)
                    .italic()
                    .foregroundStyle(LinguaTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code:
            Text(block.text)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(LinguaTheme.primaryText)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinguaTheme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .divider:
            Divider().padding(.vertical, 2)
        }
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title3.weight(.bold)
        case 2: return .headline
        default: return .subheadline.weight(.semibold)
        }
    }
}

// MARK: - Parsing

/// A pragmatic block splitter for the markdown the research agent produces: ATX headings, `-`/`*`/`+`
/// bullets, `1.` ordered items, `>` quotes, fenced code, `---` rules, blank-line-separated paragraphs.
/// Not a full CommonMark parser — inline emphasis is left to `AttributedString`.
func parseMarkdownBlocks(_ raw: String) -> [AssistantMarkdownBlock] {
    var blocks: [AssistantMarkdownBlock] = []
    var paragraph: [String] = []
    var codeLines: [String] = []
    var inCode = false

    func flushParagraph() {
        let joined = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if !joined.isEmpty {
            blocks.append(AssistantMarkdownBlock(kind: .paragraph, text: joined))
        }
        paragraph.removeAll()
    }

    let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("```") {
            if inCode {
                blocks.append(AssistantMarkdownBlock(kind: .code, text: codeLines.joined(separator: "\n")))
                codeLines.removeAll()
                inCode = false
            } else {
                flushParagraph()
                inCode = true
            }
            continue
        }
        if inCode {
            codeLines.append(line)
            continue
        }

        if trimmed.isEmpty {
            flushParagraph()
            continue
        }
        if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            flushParagraph()
            blocks.append(AssistantMarkdownBlock(kind: .divider, text: ""))
            continue
        }
        if let level = headingLevel(trimmed) {
            flushParagraph()
            let text = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            blocks.append(AssistantMarkdownBlock(kind: .heading(level), text: text))
            continue
        }
        if trimmed.hasPrefix(">") {
            flushParagraph()
            let text = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            blocks.append(AssistantMarkdownBlock(kind: .quote, text: text))
            continue
        }
        if let text = bulletText(trimmed) {
            flushParagraph()
            blocks.append(AssistantMarkdownBlock(kind: .bullet, text: text))
            continue
        }
        if let (number, text) = orderedItem(trimmed) {
            flushParagraph()
            blocks.append(AssistantMarkdownBlock(kind: .ordered(number), text: text))
            continue
        }
        paragraph.append(trimmed)
    }

    if inCode, !codeLines.isEmpty {
        blocks.append(AssistantMarkdownBlock(kind: .code, text: codeLines.joined(separator: "\n")))
    }
    flushParagraph()
    return blocks
}

private func headingLevel(_ trimmed: String) -> Int? {
    guard trimmed.hasPrefix("#") else { return nil }
    let hashes = trimmed.prefix { $0 == "#" }.count
    guard hashes <= 6, trimmed.dropFirst(hashes).first == " " else { return nil }
    return hashes
}

private func bulletText(_ trimmed: String) -> String? {
    for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
        return String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
    }
    return nil
}

private func orderedItem(_ trimmed: String) -> (Int, String)? {
    let digits = trimmed.prefix { $0.isNumber }
    guard !digits.isEmpty, let number = Int(digits) else { return nil }
    let rest = trimmed.dropFirst(digits.count)
    guard rest.first == "." || rest.first == ")" else { return nil }
    let text = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return nil }
    return (number, text)
}

/// Inline markdown → `AttributedString`, preserving whitespace (so soft breaks survive) and tinting
/// `[cN]` citation markers with the accent color so they read as references, not body text.
func inlineMarkdownAttributed(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    var attributed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    styleCitationMarkers(&attributed)
    return attributed
}

private func styleCitationMarkers(_ attributed: inout AttributedString) {
    let plain = String(attributed.characters)
    guard plain.contains("[c"), let regex = try? NSRegularExpression(pattern: "\\[c\\d+\\]") else { return }
    let ns = plain as NSString
    let matches = regex.matches(in: plain, range: NSRange(location: 0, length: ns.length))
    guard !matches.isEmpty else { return }
    let tokens = Set(matches.map { ns.substring(with: $0.range) })
    for token in tokens {
        var searchStart = attributed.startIndex
        while let range = attributed[searchStart...].range(of: token) {
            attributed[range].foregroundColor = LinguaTheme.accent
            searchStart = range.upperBound
        }
    }
}
#endif
