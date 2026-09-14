import SwiftUI

#if os(tvOS)
struct TVSettingsScene<Preview: View>: View {
    let model: TVSettingsScreenModel
    var iconColor: Color = LinguaTheme.accent
    var statusForRow: (TVSettingsRowDescriptor) -> String? = { _ in nil }
    var initialFocusID: String? = nil
    @ViewBuilder var preview: () -> Preview
    var onActivate: (TVSettingsRowDescriptor) -> Void
    var onFocusedRowChange: (TVSettingsRowDescriptor?) -> Void = { _ in }

    @FocusState private var focusedRowID: String?

    var body: some View {
        VStack(spacing: 36) {
            Text(model.title)
                .font(.title2.bold())
                .frame(maxWidth: .infinity)

            HStack(alignment: .top, spacing: 80) {
                detailPane
                    .frame(width: 620)
                    .allowsHitTesting(false)

                rowList
                    .frame(minWidth: 620, idealWidth: 700, maxWidth: 760)
                    .focusSection()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, LinguaTheme.pageHorizontalPadding)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinguaScreenBackground())
        .onAppear(perform: applyDefaultFocus)
        .onChange(of: focusedRowID) { _, newValue in
            onFocusedRowChange(model.row(id: newValue))
        }
    }

    private var focusedRow: TVSettingsRowDescriptor? {
        model.row(id: focusedRowID)
    }

    @ViewBuilder
    private var detailPane: some View {
        let row = focusedRow
        TVSettingsDetailPane(
            icon: row?.icon ?? model.defaultIcon,
            title: row?.title ?? model.title,
            help: detailHelp(for: row),
            status: row.flatMap(statusForRow),
            iconColor: iconColor
        ) {
            if model.showsSubtitlePreview {
                preview()
            }
        }
    }

    private func detailHelp(for row: TVSettingsRowDescriptor?) -> String {
        if let row {
            if !row.isEnabled, let reason = row.disabledReason, !reason.isEmpty {
                return reason
            }
            return row.help
        }
        return model.defaultHelp
    }

    private var rowList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(Array(model.groups.enumerated()), id: \.offset) { _, group in
                        VStack(alignment: .leading, spacing: 4) {
                            if let title = group.title, !title.isEmpty {
                                Text(title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(LinguaTheme.secondaryText)
                                    .textCase(.uppercase)
                                    .padding(.leading, 8)
                                    .padding(.bottom, 6)
                            }
                            ForEach(group.rows) { row in
                                rowView(row)
                                    .id(row.id)
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: focusedRowID) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: TVSettingsRowDescriptor) -> some View {
        TVSettingsRowView(row: row) {
            activate(row)
        }
        .ifFocusable(row.isFocusable) { view in
            view.focused($focusedRowID, equals: row.id)
        }
    }

    private func activate(_ row: TVSettingsRowDescriptor) {
        guard row.isFocusable else { return }
        if !row.isEnabled { return }
        onActivate(row)
    }

    private func applyDefaultFocus() {
        focusedRowID = initialFocusID ?? model.firstFocusableID
    }
}

private extension View {
    @ViewBuilder
    func ifFocusable<Content: View>(
        _ enabled: Bool,
        transform: (Self) -> Content
    ) -> some View {
        if enabled {
            transform(self)
        } else {
            self
        }
    }
}
#endif
