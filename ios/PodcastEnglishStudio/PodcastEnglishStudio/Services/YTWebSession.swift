import PodcastEnglishStudioCore
import Foundation
import Observation
#if os(iOS)
import WebKit

@MainActor
@Observable
final class YTWebSession {
    static let shared = YTWebSession()

    let dataStore: WKWebsiteDataStore
    var isLoggedIn = false

    private init() {
        let defaultsKey = "YTWebSessionDataStoreIdentifier"
        let defaults = UserDefaults.standard
        let identifier: UUID
        if let stored = defaults.string(forKey: defaultsKey), let uuid = UUID(uuidString: stored) {
            identifier = uuid
        } else {
            identifier = UUID()
            defaults.set(identifier.uuidString, forKey: defaultsKey)
        }
        dataStore = WKWebsiteDataStore(forIdentifier: identifier)
        Task { await refreshLoginState() }
    }

    func refreshLoginState() async {
        let cookies = await allCookies()
        isLoggedIn = cookies.contains { cookie in
            cookie.domain.contains("youtube.com") || cookie.domain.contains("google.com")
        } && cookies.contains { $0.name == "SAPISID" || $0.name == "__Secure-1PSID" || $0.name == "__Secure-3PSID" }
    }

    func clearLogin() async {
        let cookies = await allCookies()
        for cookie in cookies where cookie.domain.contains("youtube.com") || cookie.domain.contains("google.com") {
            await delete(cookie)
        }
        await removeWebsiteData()
        await refreshLoginState()
    }

    private func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            dataStore.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    private func delete(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { continuation in
            dataStore.httpCookieStore.delete(cookie) {
                continuation.resume()
            }
        }
    }

    private func removeWebsiteData() async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation { continuation in
            dataStore.removeData(ofTypes: types, modifiedSince: .distantPast) {
                continuation.resume()
            }
        }
    }
}
#endif
