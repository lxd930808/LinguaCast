import SwiftUI
import DomainModels

#if os(iOS)
/// Cindy-style work group for one turn: a fold header (spinner while running, a one-line summary
/// once done) that expands into the thinking card and the tool rows. Placed between a turn's user
/// bubble and its assistant content by `AssistantV2ConversationView`, and reused for the in-flight
/// turn by `AssistantV2StreamTailView`.
struct AssistantV2TurnWorkGroup: View {
    let work: AssistantV2TurnWork?
    let isRunning: Bool
    let thinkingStartedAt: Date?
    @State private var manualExpanded: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if isExpanded, hasContent {
                content
            }
        }
    }

    private var isExpanded: Bool { manualExpanded ?? isRunning }

    private var hasContent: Bool {
        work?.thinking != nil || !(work?.tools.isEmpty ?? true)
    }

    @ViewBuilder
    private var header: some View {
        if hasContent {
            Button {
                manualExpanded = !isExpanded
            } label: {
                headerRow
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("assistant.v2.workgroup.header")
        } else {
            headerRow
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            if isRunning {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "sparkles")
                    .font(.footnote)
                    .foregroundStyle(LinguaTheme.secondaryText)
            }
            Text(AssistantV2ViewModel.foldSummary(for: work, isRunning: isRunning))
                .font(.subheadline)
                .foregroundStyle(LinguaTheme.secondaryText)
                .lineLimit(1)
            Spacer()
            if hasContent {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(LinguaTheme.tertiaryText)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let thinking = work?.thinking {
                AssistantV2ThinkingCard(thinking: thinking, startedAt: thinkingStartedAt)
            }
            ForEach(work?.tools ?? []) { tool in
                AssistantV2ToolRow(tool: tool)
            }
        }
        .padding(.leading, 4)
    }
}

/// Collapsed by default even while streaming: "Thinking · 12s" (ticking every 500ms) or "Thought
/// for 12s" once done. Expanding reveals the folded thinking text; redacted blocks never show one.
struct AssistantV2ThinkingCard: View {
    let thinking: AssistantV2TurnWorkThinking
    let startedAt: Date?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if expanded, canExpand, let text = thinking.text, !text.isEmpty {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(LinguaTheme.secondaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if thinking.truncated == true {
                    Text(L10n.string("assistant.v2.thinking.truncated", fallback: "Truncated"))
                        .font(.caption2)
                        .foregroundStyle(LinguaTheme.tertiaryText)
                }
            }
        }
        .padding(10)
        .background(LinguaTheme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var canExpand: Bool {
        !thinking.isRedacted && !(thinking.text?.isEmpty ?? true)
    }

    private var header: some View {
        Button {
            guard canExpand else { return }
            expanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "brain")
                    .font(.caption)
                    .foregroundStyle(LinguaTheme.secondaryText)
                headerLabel
                Spacer()
                if canExpand {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(LinguaTheme.tertiaryText)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!canExpand)
        .accessibilityIdentifier("assistant.v2.thinking")
    }

    @ViewBuilder
    private var headerLabel: some View {
        if thinking.isStreaming, let startedAt {
            TimelineView(.periodic(from: startedAt, by: 0.5)) { context in
                Text(Self.elapsedText(from: startedAt, to: context.date))
                    .font(.caption)
                    .foregroundStyle(LinguaTheme.secondaryText)
            }
        } else {
            Text(staticHeaderText)
                .font(.caption)
                .foregroundStyle(LinguaTheme.secondaryText)
        }
    }

    private static func elapsedText(from startedAt: Date, to now: Date) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(startedAt)))
        return L10n.format("assistant.v2.thinking.elapsed", fallback: "Thinking · %ds", elapsed)
    }

    private var staticHeaderText: String {
        if thinking.isRedacted {
            return L10n.string("assistant.v2.thinking.redacted", fallback: "Reasoning hidden")
        }
        if thinking.isStreaming {
            return L10n.string("assistant.thinking", fallback: "Thinking")
        }
        if let duration = thinking.durationMs {
            return L10n.format("assistant.v2.thinking.done_duration", fallback: "Thought for %ds", max(0, duration / 1000))
        }
        return L10n.string("assistant.v2.thinking.done", fallback: "Thought")
    }
}

/// One tool call: a human-readable verb (never the raw function name), a status icon, and — only
/// once expanded — the search query. No URI, path, or tool-call JSON is ever shown.
struct AssistantV2ToolRow: View {
    let tool: AssistantV2TurnWorkTool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                guard hasQuery else { return }
                expanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    statusIcon
                    Text(AssistantV2ViewModel.toolLabel(for: tool.tool))
                        .font(.footnote)
                        .foregroundStyle(LinguaTheme.secondaryText)
                        .lineLimit(1)
                    Spacer()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityText)
            }
            .buttonStyle(.plain)
            .disabled(!hasQuery)
            .accessibilityIdentifier("assistant.v2.tool.\(tool.callId)")
            if expanded, hasQuery, let query = tool.query {
                Text(query)
                    .font(.caption2)
                    .foregroundStyle(LinguaTheme.tertiaryText)
                    .lineLimit(2)
                    .padding(.leading, 22)
            }
        }
    }

    private var hasQuery: Bool {
        !(tool.query?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private var accessibilityText: String {
        let label = AssistantV2ViewModel.toolLabel(for: tool.tool)
        switch tool.status {
        case "running":
            return "\(label) – \(L10n.string("assistant.v2.tool.status.running", fallback: "In progress"))"
        case "failed":
            return "\(label) – \(L10n.string("assistant.v2.tool.status.failed", fallback: "Failed"))"
        default:
            return "\(label) – \(L10n.string("assistant.v2.tool.status.completed", fallback: "Done"))"
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch tool.status {
        case "running":
            ProgressView()
                .controlSize(.mini)
        case "failed":
            Image(systemName: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(LinguaTheme.danger)
        default:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(LinguaTheme.secondaryText)
        }
    }
}
#endif
