import SwiftData
import SwiftUI
import DomainModels

struct AssistantPinHomeToolbarButton: View {
    @Environment(\.modelContext) private var modelContext
    let isAssistantOrigin: Bool
    let isPinned: Bool
    let onToggle: () -> Void

    var body: some View {
        if isAssistantOrigin {
            Button(action: onToggle) {
                Text(
                    isPinned
                        ? L10n.string("assistant.pinned", fallback: "Added to Home")
                        : L10n.string("assistant.pin_home", fallback: "Add to Home")
                )
                .font(.subheadline.weight(.semibold))
            }
            .accessibilityIdentifier("assistant.pin-home")
            .accessibilityLabel(
                isPinned
                    ? L10n.string("assistant.pinned", fallback: "Added to Home")
                    : L10n.string("assistant.pin_home", fallback: "Add to Home")
            )
        }
    }

    static func togglePin(on record: EpisodeRecord, context: ModelContext) {
        record.pinnedToHome.toggle()
        record.updatedAt = Date()
        try? context.save()
    }

    static func togglePin(on record: YTVideoRecord, context: ModelContext) {
        record.pinnedToHome.toggle()
        record.recordUpdatedAt = Date()
        try? context.save()
    }
}
