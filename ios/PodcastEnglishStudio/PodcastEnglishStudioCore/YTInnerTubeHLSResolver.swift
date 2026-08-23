import Foundation

public struct YTInnerTubeHLSResolver: Sendable {
    private enum ClientProfile: Sendable, Equatable {
        case ios
        case webSafari

        var name: String {
            switch self {
            case .ios: "IOS"
            case .webSafari: "WEB"
            }
        }

        var headerName: String {
            switch self {
            case .ios: "5"
            case .webSafari: "1"
            }
        }

        var version: String {
            switch self {
            case .ios: "21.02.3"
            case .webSafari: "2.20260114.08.00"
            }
        }

        var userAgent: String {
            switch self {
            case .ios:
                "com.google.ios.youtube/21.02.3 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"
            case .webSafari:
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)"
            }
        }

        var deviceMake: String? {
            switch self {
            case .ios: "Apple"
            case .webSafari: nil
            }
        }

        var deviceModel: String? {
            switch self {
            case .ios: "iPhone16,2"
            case .webSafari: nil
            }
        }

        var osName: String? {
            switch self {
            case .ios: "iPhone"
            case .webSafari: nil
            }
        }

        var osVersion: String? {
            switch self {
            case .ios: "18.3.2.22D82"
            case .webSafari: nil
            }
        }

        /// The fallback runs after the iOS probe already spent its budget, and the
        /// caller races this whole chain against the stream resolver, so it gets a
        /// short leash rather than doubling the wait before an error surfaces.
        var timeout: TimeInterval {
            switch self {
            case .ios: 8
            case .webSafari: 4
            }
        }
    }

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Ordered probe: iOS InnerTube first; only if that yields no `hlsManifestUrl`,
    /// one `web_safari` attempt. Never retries or fans out additional clients.
    public func resolve(videoID: String) async throws -> URL? {
        if let iosURL = try await probe(videoID: videoID, profile: .ios) {
            return iosURL
        }
        return try await probe(videoID: videoID, profile: .webSafari)
    }

    private func probe(videoID: String, profile: ClientProfile) async throws -> URL? {
        guard let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = profile.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(profile.headerName, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(profile.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue(profile.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: Self.requestBody(videoID: videoID, profile: profile)
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard 200..<300 ~= http.statusCode else {
            // iOS: preserve hard failure so a 429 does not trigger a second client.
            // web_safari: soft-fail — one attempt, no retry, no further clients.
            if profile == .ios {
                throw URLError(.badServerResponse)
            }
            return nil
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let playability = object["playabilityStatus"] as? [String: Any],
              playability["status"] as? String == "OK",
              let streamingData = object["streamingData"] as? [String: Any],
              let rawURL = streamingData["hlsManifestUrl"] as? String
        else {
            return nil
        }
        return URL(string: rawURL)
    }

    private static func requestBody(videoID: String, profile: ClientProfile) -> [String: Any] {
        var client: [String: Any] = [
            "clientName": profile.name,
            "clientVersion": profile.version,
            "userAgent": profile.userAgent,
            "hl": "en",
            "timeZone": "UTC",
            "utcOffsetMinutes": 0
        ]
        if let deviceMake = profile.deviceMake {
            client["deviceMake"] = deviceMake
        }
        if let deviceModel = profile.deviceModel {
            client["deviceModel"] = deviceModel
        }
        if let osName = profile.osName {
            client["osName"] = osName
        }
        if let osVersion = profile.osVersion {
            client["osVersion"] = osVersion
        }

        return [
            "context": [
                "client": client
            ],
            "videoId": videoID,
            "playbackContext": [
                "contentPlaybackContext": [
                    "html5Preference": "HTML5_PREF_WANTS"
                ]
            ],
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
    }
}
