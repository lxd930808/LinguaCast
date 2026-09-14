import CoreImage.CIFilterBuiltins
import SwiftData
import SwiftUI
import UIKit
import PodcastEnglishStudioCore
import DomainModels
import CloudSyncKit

struct MobileSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(SettingsStore.self) private var settings
    @Environment(PipelineRunner.self) private var runner
    @State private var server = LocalSetupServer()
    @State private var localService = YTLocalService()
    @State private var dismissTask: Task<Void, Never>?

    var body: some View {
        platformBody
        .linguaPage()
        .accessibilityIdentifier("screen.mobile-setup")
        .task {
            if !UITestSupport.isEnabled {
                startServer()
            }
        }
        .onChange(of: server.lastMessage) { _, message in
            guard LocalSetupDismissalPolicy.shouldDismissAfterSuccessfulSubmission(message: message) else { return }
            dismissTask?.cancel()
            dismissTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled else { return }
                dismiss()
            }
        }
        .onDisappear {
            dismissTask?.cancel()
            server.stop()
        }
    }

    @ViewBuilder
    private var platformBody: some View {
        #if os(tvOS)
        setupContent
            .padding(36)
            .frame(minWidth: 560, minHeight: 620)
        #else
        ScrollView {
            setupContent
                .padding(20)
                .frame(maxWidth: .infinity)
        }
        #endif
    }

    private var setupContent: some View {
        VStack(spacing: 24) {
            Text(L10n.string("mobile_setup.scan_code_with_mobile_phone_to_fill_in", fallback: "Scan code with mobile phone to fill in"))
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if UITestSupport.isEnabled {
                QRCodeView(value: "http://192.0.2.1:8765/setup")
                    .frame(width: 320, height: 320)
                    .padding(18)
                    .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else if let url = server.setupURL {
                QRCodeView(value: url.absoluteString)
                    .frame(width: 320, height: 320)
                    .padding(18)
                    .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Text(url.absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if server.isRunning {
                ProgressView()
            } else {
                LinguaEmptyState(L10n.string("mobile_setup.waiting_for_lan_address", fallback: "Waiting for LAN address"), systemImage: "wifi", kind: .failure)
            }

            VStack(spacing: 8) {
                Text(L10n.string("mobile_setup.scan_instructions", fallback: "Scan with the iPhone camera, then configure APIs, Podcast subscriptions, or YouTube channels in Safari."))
                    .multilineTextAlignment(.center)
                Text(L10n.string("mobile_setup.same_network", fallback: "iPhone and Apple TV must be connected to the same local network."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.string("mobile_setup.if_the_page_cannot_be_opened_on_your_phone_please_confirm_that_a", fallback: "If the page cannot be opened on your phone, please confirm that Apple TV has allowed local network access and turn off guest network or AP isolation."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let lastError = server.lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(LinguaTheme.danger)
                    .multilineTextAlignment(.center)
            }
            if !server.lastMessage.isEmpty {
                Label(server.lastMessage, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(LinguaTheme.success)
                    .multilineTextAlignment(.center)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    setupButtons
                }
                VStack(spacing: 12) {
                    setupButtons
                }
            }
        }
    }

    @ViewBuilder
    private var setupButtons: some View {
        Button {
            restartServer()
        } label: {
            Label(L10n.string("mobile_setup.regenerate_qr_code", fallback: "Regenerate QR code"), systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)

        Button(L10n.string("mobile_setup.done", fallback: "Done")) {
            dismissTask?.cancel()
            dismiss()
        }
        .buttonStyle(.borderedProminent)
    }

    @MainActor
    private func startServer() {
        server.start { submission in
            try await apply(submission)
        }
    }

    private func restartServer() {
        dismissTask?.cancel()
        server.stop()
        startServer()
    }

    @MainActor
    private func apply(_ submission: MobileSetupSubmission) async throws -> String {
        if let provider = submission.settings[.translationProvider] {
            applySetting(provider, for: .translationProvider)
        }
        for (key, value) in submission.settings where key != .translationProvider {
            applySetting(value, for: key)
        }
        if !submission.settings.isEmpty {
            settings.save()
        }

        var changes: [String] = []
        if !submission.settings.isEmpty {
            changes.append(L10n.string("mobile_setup.settings_saved", fallback: "Settings saved"))
        }

        if submission.hasLocalMediaChanges {
            applyLocalMedia(submission)
            changes.append(
                L10n.string(
                    "mobile_setup.local_media_saved",
                    fallback: "Media backend settings saved"
                )
            )
        }

        if !submission.podcastURL.isEmpty {
            let subscription = PodcastSubscription(
                showURL: submission.podcastURL,
                displayName: submission.podcastName.isEmpty ? submission.podcastURL : submission.podcastName
            )
            modelContext.insert(subscription)
            try modelContext.save()
            CloudSyncCoordinator.shared.upsertPodcast(subscription)
            await runner.refresh(
                subscription: subscription,
                context: modelContext,
                mode: .recent(limit: 50)
            )
            changes.append(L10n.string("mobile_setup.podcast_subscription_added", fallback: "Podcast subscription added"))
        }

        if !submission.youtubeURL.isEmpty {
            let channel = try await localService.addChannel(
                input: submission.youtubeURL,
                displayName: submission.youtubeName.isEmpty ? nil : submission.youtubeName,
                configuration: settings.configuration,
                context: modelContext
            )
            await localService.refreshChannel(
                channel,
                configuration: settings.configuration,
                context: modelContext
            )
            changes.append(L10n.string("mobile_setup.youtube_channel_has_been_added", fallback: "YouTube Channel has been added"))
        }

        return changes.isEmpty
            ? L10n.string("mobile_setup.nothing_to_save", fallback: "Nothing to save.")
            : ListFormatter.localizedString(byJoining: changes)
    }

    private func applyLocalMedia(_ submission: MobileSetupSubmission) {
        _ = YTLocalMediaServiceConfig.applyMobileSetupPatch(from: submission.localMediaForm)
        YTPlaybackBackend.resetLocalResolverCache()
    }

    private func applySetting(_ value: String, for key: AppConfigurationKey) {
        if key == .translationProvider {
            let defaults = TranslationProviderPolicy.defaultsForProviderSwitch(
                toProvider: value,
                currentBaseURL: settings.configuration.translationBaseURL,
                currentModelID: settings.configuration.translationModelID,
                currentReasoningEffort: settings.configuration.translationReasoningEffort
            )
            settings.configuration.translationProvider = TranslationProviderPolicy.normalizedProvider(value)
            settings.configuration.translationBaseURL = defaults.baseURL
            settings.configuration.translationModelID = defaults.modelID
            settings.configuration.translationReasoningEffort = defaults.reasoningEffort
            return
        }
        settings.configuration[key] = value
    }
}

private struct QRCodeView: View {
    let value: String

    var body: some View {
        if let image = QRCodeGenerator.image(from: value) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
        } else {
            LinguaEmptyState(L10n.string("mobile_setup.unable_to_generate_qr_code", fallback: "Unable to generate QR code"), systemImage: "qrcode", kind: .failure)
        }
    }
}

private enum QRCodeGenerator {
    static func image(from value: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let transformed = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = CIContext().createCGImage(transformed, from: transformed.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
