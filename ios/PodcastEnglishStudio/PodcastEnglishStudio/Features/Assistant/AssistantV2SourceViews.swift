import SwiftUI
import DomainModels

#if os(iOS)
struct AssistantV2SourceCard: View {
    let source: AssistantV2DisplayedSource
    var job: AssistantV2TranscriptJob?
    /// Set when starting the transcription itself failed (e.g. the source could no longer be
    /// resolved server-side), before any job existed to carry its own `.failed*` status.
    var transcriptionError: String?
    var onTranscribe: () -> Void
    var onPlay: (() -> Void)? = nil
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(platformLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(LinguaTheme.secondaryText)
                Spacer()
                Text(AssistantV2ViewModel.evidenceTitle(source.evidenceLevel))
                    .font(.caption2)
                    .foregroundStyle(LinguaTheme.secondaryText)
            }
            Text(source.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(3)
            if source.status == .corrupt {
                Text(L10n.string("assistant.v2.artifact.corrupt", fallback: "This source could not be verified."))
                    .font(.caption)
                    .foregroundStyle(LinguaTheme.danger)
            } else if source.status == .failed {
                Text(L10n.string("assistant.v2.artifact.failed", fallback: "This source could not be saved."))
                    .font(.caption)
                    .foregroundStyle(LinguaTheme.danger)
            }
            if let job {
                Text(AssistantV2ViewModel.transcriptStatusTitle(job.status, progress: job.progress, error: job.error?.message, installStatus: job.installStatus))
                    .font(.caption)
                    .foregroundStyle(job.status == .ready ? LinguaTheme.success :
                        ((job.status == .failedRetryable || job.status == .failedTerminal) ? LinguaTheme.danger : LinguaTheme.warning))
                if let transcriptionError {
                    Text(transcriptionError).font(.caption).foregroundStyle(LinguaTheme.warning)
                }
                if job.status == .requested || job.status == .waitingService || job.status == .running || job.status == .installing {
                    LinguaProgressBar(value: job.progress)
                }
            } else if let transcriptionError {
                Text(transcriptionError)
                    .font(.caption)
                    .foregroundStyle(LinguaTheme.danger)
            }
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(LinguaTheme.surface, in: RoundedRectangle(cornerRadius: LinguaTheme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LinguaTheme.cardRadius, style: .continuous)
                .stroke(LinguaTheme.border, lineWidth: 1)
        }
        .accessibilityIdentifier("assistant.v2.source.\(source.id)")
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 12) {
            if let raw = source.canonicalURL, let url = URL(string: raw) {
                Button(L10n.string("assistant.v2.open_link", fallback: "Open link")) {
                    openURL(url)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LinguaTheme.accent)
            }
            if job?.status == .ready {
                Button(L10n.string("assistant.open_player", fallback: "Play")) {
                    onPlay?()
                }
                .buttonStyle(.borderedProminent)
                .disabled(onPlay == nil)
                .frame(minHeight: 44)
                .accessibilityIdentifier("assistant.v2.play.\(source.transcribeSourceId ?? source.id)")
            } else if source.canTranscribe, source.status != .corrupt,
                      job == nil || job?.status == .failedRetryable || job?.installStatus == "stalled" {
                Button(L10n.string("assistant.v2.transcribe", fallback: "Transcribe")) {
                    onTranscribe()
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
                .accessibilityIdentifier("assistant.v2.transcribe.\(source.transcribeSourceId ?? source.id)")
            }
        }
    }

    private var platformLabel: String {
        switch source.platform.lowercased() {
        case "youtube": return "YouTube"
        case "podcast": return "Podcast"
        case "web": return "Web"
        default: return source.platform
        }
    }
}

struct AssistantV2ProposalStack: View {
    let model: AssistantV2ViewModel?

    var body: some View {
        ForEach(model?.pendingMemoryProposals ?? [], id: \.proposalId) { proposal in
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.string("assistant.v2.memory_proposal_title", fallback: "Save as a preference?"))
                    .font(.subheadline.weight(.semibold))
                Text(proposal.content)
                    .font(.body)
                Text(proposal.reason)
                    .font(.caption)
                    .foregroundStyle(LinguaTheme.secondaryText)
                Text(L10n.string(
                    "assistant.v2.memory_proposal_body",
                    fallback: "Confirming this preference can be recalled in future research."
                ))
                .font(.caption)
                .foregroundStyle(LinguaTheme.secondaryText)
                HStack(spacing: 12) {
                    Button(L10n.string("assistant.v2.memory_confirm", fallback: "Confirm")) {
                        Task { await model?.confirmMemoryProposal(proposal.proposalId) }
                    }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("assistant.v2.memory.confirm.\(proposal.proposalId)")
                    Button(L10n.string("assistant.v2.memory_reject", fallback: "Don't save")) {
                        Task { await model?.rejectMemoryProposal(proposal.proposalId) }
                    }
                    .font(.subheadline)
                    .foregroundStyle(LinguaTheme.secondaryText)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("assistant.v2.memory.reject.\(proposal.proposalId)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(LinguaTheme.surface, in: RoundedRectangle(cornerRadius: LinguaTheme.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: LinguaTheme.cardRadius, style: .continuous)
                    .stroke(LinguaTheme.border, lineWidth: 1)
            }
        }
    }
}
#endif
