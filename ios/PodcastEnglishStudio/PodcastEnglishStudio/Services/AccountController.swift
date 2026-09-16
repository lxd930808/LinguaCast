import AuthenticationServices
import CloudSyncKit
import Foundation
import Observation
import UIKit

/// App-wide account state (V18 WP05): Sign in with Apple, self-hosted server
/// tokens, today's quota and the service access published to gateways.
@MainActor
@Observable
final class AccountController {
    static let shared = AccountController()

    enum Phase: Equatable {
        case signedOut
        case working
        case signedIn
    }

    private(set) var phase: Phase = .signedOut
    private(set) var serverKind: AccountServerKind
    private(set) var selfHostedURL: String
    private(set) var accountId: String?
    private(set) var config: AccountConfig?
    private(set) var quota: QuotaSnapshot?
    private(set) var challenge: AppleSignInChallenge?
    var errorMessage: String?

    @ObservationIgnored private let preferences: AccountServerPreferences
    @ObservationIgnored private let credentialStore: AccountCredentialStoring
    @ObservationIgnored private let officialURL: URL?
    @ObservationIgnored private var manager: AccountSessionManager?
    @ObservationIgnored private var started = false

    private static let promptedKey = "account.firstLaunchPromptShown"

    nonisolated static var bundledOfficialURL: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "LinguaCastOfficialAccountURL") as? String)
            .flatMap(AccountServerProfile.normalizedURL)
    }

    init(
        preferences: AccountServerPreferences = AccountServerPreferences(),
        credentialStore: AccountCredentialStoring = KeychainAccountCredentialStore(),
        officialURL: URL? = AccountController.bundledOfficialURL
    ) {
        self.preferences = preferences
        self.credentialStore = credentialStore
        self.officialURL = officialURL
        serverKind = preferences.kind
        selfHostedURL = preferences.selfHostedURL
        manager = Self.makeManager(preferences: preferences, store: credentialStore, officialURL: officialURL)
    }

    static var platform: String {
        #if os(tvOS)
        return "tvos"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios"
        #endif
    }

    /// Restores a stored session at launch; never blocks local playback.
    func start() async {
        guard !started, !UITestSupport.isEnabled else { return }
        started = true
        await restore()
    }

    /// Foreground refresh: retries configuration after an offline launch, else updates quota.
    func refreshIfNeeded() async {
        guard started else { return }
        if phase == .signedIn, config == nil {
            await restore()
        } else {
            await refreshQuota()
        }
    }

    /// True once per install while signed out on first launch.
    func consumeFirstLaunchPrompt() -> Bool {
        guard phase == .signedOut, !UserDefaults.standard.bool(forKey: Self.promptedKey) else { return false }
        UserDefaults.standard.set(true, forKey: Self.promptedKey)
        return true
    }

    func prepareSignIn() async {
        guard let manager, !UITestSupport.isEnabled else { return }
        if let challenge, let expiresAt = AccountDates.parse(challenge.expiresAt), expiresAt.timeIntervalSinceNow > 30 {
            return
        }
        do {
            challenge = try await manager.beginAppleSignIn(platform: Self.platform)
            errorMessage = nil
        } catch {
            errorMessage = message(for: error)
        }
    }

    func configure(_ request: ASAuthorizationAppleIDRequest) {
        request.requestedScopes = []
        request.nonce = challenge?.nonce
    }

    func completeSignIn(_ result: Result<ASAuthorization, Error>) async {
        guard let manager else { return }
        switch result {
        case .failure(let error):
            if let authorizationError = error as? ASAuthorizationError, authorizationError.code == .canceled { return }
            errorMessage = L10n.string("account.error.sign_in_failed", fallback: "Sign-in failed. Please try again.")
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let identityToken = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) }),
                  let authorizationCode = credential.authorizationCode.flatMap({ String(data: $0, encoding: .utf8) }),
                  let usedChallenge = challenge
            else {
                errorMessage = L10n.string("account.error.sign_in_failed", fallback: "Sign-in failed. Please try again.")
                return
            }
            // Challenges are single use on the server, successful or not.
            challenge = nil
            phase = .working
            do {
                let config = try await manager.completeAppleSignIn(
                    challengeId: usedChallenge.challengeId,
                    identityToken: identityToken,
                    authorizationCode: authorizationCode,
                    platform: Self.platform,
                    deviceName: UIDevice.current.name
                )
                apply(config, manager: manager)
                await refreshQuota()
            } catch {
                phase = .signedOut
                errorMessage = message(for: error)
                await prepareSignIn()
            }
        }
    }

    func connectSelfHosted(urlString: String, token: String) async {
        guard let url = AccountServerProfile.normalizedURL(urlString) else {
            errorMessage = L10n.string("account.error.invalid_url", fallback: "Enter a valid https server address.")
            return
        }
        await switchServer(kind: .selfHosted, url: url.absoluteString)
        guard let manager else { return }
        phase = .working
        do {
            let config = try await manager.connectSelfHosted(token: token)
            apply(config, manager: manager)
            await refreshQuota()
        } catch {
            phase = .signedOut
            errorMessage = message(for: error)
        }
    }

    func useOfficialServer() async {
        await switchServer(kind: .official, url: selfHostedURL)
        await restore()
    }

    func signOut() async {
        await manager?.signOut()
        clearSession()
        await prepareSignIn()
    }

    func deleteAccount() async {
        guard let manager else { return }
        phase = .working
        do {
            try await manager.deleteAccount()
            clearSession()
            await prepareSignIn()
        } catch {
            phase = await manager.isSignedIn ? .signedIn : .signedOut
            errorMessage = message(for: error)
        }
    }

    func refreshQuota() async {
        guard let manager, phase == .signedIn, config != nil else { return }
        quota = try? await manager.quota()
    }

    // MARK: - Private

    private static func makeManager(
        preferences: AccountServerPreferences,
        store: AccountCredentialStoring,
        officialURL: URL?
    ) -> AccountSessionManager? {
        guard let profile = preferences.profile(officialURL: officialURL) else { return nil }
        return AccountSessionManager(profile: profile, gateway: AccountGateway(baseURL: profile.accountBaseURL), store: store)
    }

    private func restore() async {
        guard let manager else {
            clearSession()
            return
        }
        guard await manager.isSignedIn else {
            clearSession()
            return
        }
        accountId = await manager.accountId
        phase = .signedIn
        do {
            let config = try await manager.config(forceRefresh: true)
            apply(config, manager: manager)
            await refreshQuota()
        } catch {
            if await manager.isSignedIn {
                // Offline or service error: keep the stored session and retry on the next foreground.
                errorMessage = message(for: error)
            } else {
                clearSession()
                errorMessage = message(for: error)
            }
        }
    }

    /// Switching servers ends the previous server's session and stops publishing its access.
    private func switchServer(kind: AccountServerKind, url: String) async {
        AccountServiceAccess.clear()
        await manager?.signOut()
        preferences.kind = kind
        preferences.selfHostedURL = url
        serverKind = kind
        selfHostedURL = url
        challenge = nil
        clearSession()
        manager = Self.makeManager(preferences: preferences, store: credentialStore, officialURL: officialURL)
    }

    private func apply(_ config: AccountConfig, manager: AccountSessionManager) {
        self.config = config
        accountId = config.account.accountId
        phase = .signedIn
        errorMessage = nil
        AccountServiceAccess.publish(
            AccountServiceAccessSnapshot(profileID: manager.profile.id, config: config),
            tokenProvider: AccountSessionTokenProvider(manager: manager)
        )
    }

    private func clearSession() {
        AccountServiceAccess.clear()
        config = nil
        quota = nil
        accountId = nil
        phase = .signedOut
    }

    private func message(for error: Error) -> String {
        var code: String?
        if case AccountSessionError.gateway(let gatewayError) = error {
            switch gatewayError {
            case .http(_, let httpCode, _):
                code = httpCode
            case .transport, .configuration:
                return L10n.string("account.error.service_unavailable", fallback: "The account service is unavailable. Please try again later.")
            case .decoding:
                code = nil
            }
        }
        switch code {
        case "AUTH_REQUIRED", "UNAUTHORIZED":
            return serverKind == .selfHosted
                ? L10n.string("account.error.invalid_token", fallback: "The server rejected this access token.")
                : L10n.string("account.error.sign_in_failed", fallback: "Sign-in failed. Please try again.")
        case "ACCOUNT_DISABLED":
            return L10n.string("account.error.account_disabled", fallback: "This account is disabled.")
        case "ACCOUNT_DELETING":
            return L10n.string("account.error.account_deleting", fallback: "This account is being deleted.")
        case "APPLE_KEYS_UNAVAILABLE", "SERVICE_UNAVAILABLE":
            return L10n.string("account.error.service_unavailable", fallback: "The account service is unavailable. Please try again later.")
        default:
            return L10n.string("account.error.sign_in_failed", fallback: "Sign-in failed. Please try again.")
        }
    }
}
