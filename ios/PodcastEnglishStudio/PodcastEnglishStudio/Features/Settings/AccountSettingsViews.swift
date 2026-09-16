import AuthenticationServices
import CloudSyncKit
import SwiftUI

// V18 WP05 account UI shared by iOS Settings, the first-launch prompt and the
// tvOS sign-in sheet.

enum AccountFormatting {
    static func shortAccountID(_ accountId: String?) -> String {
        guard let accountId, !accountId.isEmpty else {
            return L10n.string("account.status_signed_out", fallback: "Not signed in")
        }
        guard accountId.count > 14 else { return accountId }
        return "\(accountId.prefix(8))\u{2026}\(accountId.suffix(4))"
    }

    static func serverTitle(_ kind: AccountServerKind) -> String {
        switch kind {
        case .official:
            return L10n.string("account.server_official", fallback: "Official Service")
        case .selfHosted:
            return L10n.string("account.server_self_hosted", fallback: "Self-Hosted Server")
        }
    }

    static func bucketTitle(_ bucket: QuotaBucket) -> String {
        bucket.kind == "media"
            ? L10n.string("account.media_quota", fallback: "Media processing today")
            : L10n.string("account.assistant_quota", fallback: "Assistant turns today")
    }

    static func bucketValue(_ bucket: QuotaBucket, enforced: Bool) -> String {
        guard enforced else { return L10n.string("account.quota_unlimited", fallback: "Not limited") }
        if bucket.kind == "media" {
            return L10n.format(
                "account.media_quota_value",
                fallback: "%1$lld of %2$lld min left",
                Int64(bucket.remaining / 60),
                Int64(bucket.limit / 60)
            )
        }
        return L10n.format(
            "account.assistant_quota_value",
            fallback: "%1$lld of %2$lld left",
            Int64(bucket.remaining),
            Int64(bucket.limit)
        )
    }

    static func resetTime(_ value: String) -> String {
        AccountDates.parse(value)?.formatted(date: .abbreviated, time: .shortened) ?? value
    }
}

struct AccountSignInPanel: View {
    @Environment(AccountController.self) private var account

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string(
                "account.sign_in_help",
                fallback: "Sign in with Apple to use cloud transcription, translation and the research assistant. Content already on this device stays playable without signing in."
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if account.challenge == nil {
                ProgressView(L10n.string("account.preparing_sign_in", fallback: "Preparing sign-in…"))
            } else {
                SignInWithAppleButton(.signIn) { request in
                    account.configure(request)
                } onCompletion: { result in
                    Task { await account.completeSignIn(result) }
                }
                #if os(tvOS)
                .frame(width: 520, height: 90)
                #else
                .frame(height: 48)
                #endif
                .disabled(account.phase == .working)
                .accessibilityIdentifier("account.sign-in-apple")
            }

            if let message = account.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(LinguaTheme.danger)
            }
        }
        .task { await account.prepareSignIn() }
    }
}

struct AccountSignInSheet: View {
    @Environment(AccountController.self) private var account
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                Text(L10n.string("account.sign_in_title", fallback: "Sign in to LinguaCast"))
                    .font(.title2.bold())
                AccountSignInPanel()
                Button(L10n.string("account.not_now", fallback: "Not Now")) {
                    dismiss()
                }
                .accessibilityIdentifier("account.not-now")
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .onChange(of: account.phase) { _, phase in
            if phase == .signedIn { dismiss() }
        }
    }
}

#if os(iOS)
struct AccountSettingsSection: View {
    @Environment(AccountController.self) private var account
    @State private var confirmingDeletion = false

    var body: some View {
        Section(L10n.string("account.section_title", fallback: "Account")) {
            if account.phase == .signedIn {
                LabeledContent(
                    L10n.string("account.signed_in_as", fallback: "Account ID"),
                    value: AccountFormatting.shortAccountID(account.accountId)
                )
                .accessibilityIdentifier("settings.account-id")
                LabeledContent(
                    L10n.string("account.server", fallback: "Server"),
                    value: AccountFormatting.serverTitle(account.serverKind)
                )
                if let quota = account.quota {
                    ForEach(quota.buckets, id: \.kind) { bucket in
                        LabeledContent(
                            AccountFormatting.bucketTitle(bucket),
                            value: AccountFormatting.bucketValue(bucket, enforced: quota.enforced)
                        )
                    }
                    if quota.enforced {
                        LabeledContent(
                            L10n.string("account.quota_resets", fallback: "Resets"),
                            value: AccountFormatting.resetTime(quota.resetAt)
                        )
                    }
                }
                if let message = account.errorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(LinguaTheme.danger)
                }
                Button(L10n.string("account.sign_out", fallback: "Sign Out")) {
                    Task { await account.signOut() }
                }
                .accessibilityIdentifier("settings.account-sign-out")
                if account.config?.capabilities.accountDeletion == true {
                    Button(L10n.string("account.delete", fallback: "Delete Account"), role: .destructive) {
                        confirmingDeletion = true
                    }
                    .accessibilityIdentifier("settings.account-delete")
                }
            } else {
                AccountSignInPanel()
            }
        }
        .confirmationDialog(
            L10n.string("account.delete_confirm_title", fallback: "Delete your account?"),
            isPresented: $confirmingDeletion,
            titleVisibility: .visible
        ) {
            Button(L10n.string("account.delete", fallback: "Delete Account"), role: .destructive) {
                Task { await account.deleteAccount() }
            }
        } message: {
            Text(L10n.string(
                "account.delete_confirm_message",
                fallback: "This signs you out on all devices and deletes your cloud jobs, research and preferences. Content downloaded to this device is kept."
            ))
        }
        .task { await account.refreshQuota() }
    }
}

struct AccountServerSection: View {
    @Environment(AccountController.self) private var account
    @State private var urlDraft = ""
    @State private var tokenDraft = ""

    var body: some View {
        Section(L10n.string("account.server", fallback: "Server")) {
            LabeledContent(
                L10n.string("account.server", fallback: "Server"),
                value: AccountFormatting.serverTitle(account.serverKind)
            )
            TextField(L10n.string("account.self_hosted_url", fallback: "Server URL"), text: $urlDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .accessibilityIdentifier("settings.self-hosted-url")
            SecureField(L10n.string("account.self_hosted_token", fallback: "Server Access Token"), text: $tokenDraft)
                .accessibilityIdentifier("settings.self-hosted-token")
            Button(L10n.string("account.connect", fallback: "Connect")) {
                let token = tokenDraft
                tokenDraft = ""
                Task { await account.connectSelfHosted(urlString: urlDraft, token: token) }
            }
            .disabled(
                urlDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || account.phase == .working
            )
            if account.serverKind == .selfHosted {
                Button(L10n.string("account.use_official", fallback: "Use Official Service")) {
                    Task { await account.useOfficialServer() }
                }
            }
            Text(L10n.string(
                "account.self_hosted_help",
                fallback: "Use your own LinguaCast server. Official sign-in credentials are never sent to a self-hosted server."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .onAppear { urlDraft = account.selfHostedURL }
    }
}
#endif
