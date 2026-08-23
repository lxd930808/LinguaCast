import PodcastEnglishStudioCore
#if os(iOS)
import SwiftUI
import WebKit

struct YTAccountView: View {
    @State private var webSession = YTWebSession.shared
    @State private var isClearing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LinguaCard {
                HStack(spacing: 16) {
                    Image(systemName: webSession.isLoggedIn ? "person.crop.circle.fill.badge.checkmark" : "person.crop.circle")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(webSession.isLoggedIn ? LinguaTheme.success : LinguaTheme.accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L10n.string("ytaccount.youtube_account", fallback: "YouTube Account"))
                            .font(.title3.bold())
                        Text(
                            webSession.isLoggedIn
                                ? L10n.string("ytaccount.logged_in_youtube", fallback: "Logged in YouTube")
                                : L10n.string("ytaccount.sign_in_to_try_ad_free_and_recommendations", fallback: "Sign in to try ad-free and recommendations")
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if webSession.isLoggedIn {
                        Button(
                            isClearing
                                ? L10n.string("ytaccount.exiting", fallback: "Exiting")
                                : L10n.string("ytaccount.log_out", fallback: "Log out"),
                            role: .destructive
                        ) {
                            Task { await clearLogin() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isClearing)
                    }
                }
            }

            LinguaCard {
                Label(
                    L10n.string(
                        "ytaccount.login_only_occurs_on_the_google_page_and_the_app_does_not_read_o",
                        fallback: "Login only occurs on the Google page, and the App does not read or save the account password. YouTube Whether to display ads is determined by YouTube."
                    ),
                    systemImage: "hand.raised.fill"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            YTLoginWebView(webSession: webSession)
                .clipShape(RoundedRectangle(cornerRadius: LinguaTheme.cardRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: LinguaTheme.cardRadius, style: .continuous)
                        .stroke(LinguaTheme.border, lineWidth: 1)
                }
                .frame(maxWidth: .infinity, minHeight: 420)
        }
        .padding(LinguaTheme.pageHorizontalPadding)
        .linguaContentWidth()
        .linguaPage()
        .accessibilityIdentifier("screen.youtube-account")
        .navigationTitle(L10n.string("ytaccount.youtube_account", fallback: "YouTube Account"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await webSession.refreshLoginState()
        }
    }

    private func clearLogin() async {
        isClearing = true
        defer { isClearing = false }
        await webSession.clearLogin()
    }
}

private struct YTLoginWebView: UIViewRepresentable {
    var webSession: YTWebSession

    func makeCoordinator() -> Coordinator {
        Coordinator(webSession: webSession)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = webSession.dataStore
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0 Safari/537.36"
        let url = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube")!
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        var webSession: YTWebSession

        init(webSession: YTWebSession) {
            self.webSession = webSession
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                await webSession.refreshLoginState()
            }
        }
    }
}
#endif
