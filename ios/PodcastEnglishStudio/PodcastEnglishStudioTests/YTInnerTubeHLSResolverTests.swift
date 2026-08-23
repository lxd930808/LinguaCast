import XCTest
@testable import PodcastEnglishStudioCore

final class YTInnerTubeHLSResolverTests: XCTestCase {
    override func tearDown() {
        InnerTubeHLSTestURLProtocol.requestHandler = nil
        InnerTubeHLSTestURLProtocol.requestCount = 0
        super.tearDown()
    }

    func testResolveReturnsIOSHLSManifestAndSendsIOSClientContext() async throws {
        let expectedURL = URL(string: "https://example.com/vod/master.m3u8")!
        InnerTubeHLSTestURLProtocol.requestHandler = { request in
            let body = try Self.bodyData(from: request)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            let context = try XCTUnwrap(object["context"] as? [String: Any])
            let client = try XCTUnwrap(context["client"] as? [String: Any])

            XCTAssertEqual(object["videoId"] as? String, "hls-test-video")
            XCTAssertEqual(client["clientName"] as? String, "IOS")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-YouTube-Client-Name"), "5")

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let payload: [String: Any] = [
                "playabilityStatus": ["status": "OK"],
                "streamingData": ["hlsManifestUrl": expectedURL.absoluteString]
            ]
            return (response, try JSONSerialization.data(withJSONObject: payload))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InnerTubeHLSTestURLProtocol.self]
        let resolver = YTInnerTubeHLSResolver(
            session: URLSession(configuration: configuration)
        )

        let resolved = try await resolver.resolve(videoID: "hls-test-video")

        XCTAssertEqual(resolved, expectedURL)
        XCTAssertEqual(InnerTubeHLSTestURLProtocol.requestCount, 1)
    }

    func testResolveDoesNotTreatServerABRAsHLS() async throws {
        InnerTubeHLSTestURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let payload: [String: Any] = [
                "playabilityStatus": ["status": "OK"],
                "streamingData": [
                    "serverAbrStreamingUrl": "https://example.com/videoplayback?sabr=1"
                ]
            ]
            return (response, try JSONSerialization.data(withJSONObject: payload))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InnerTubeHLSTestURLProtocol.self]
        let resolver = YTInnerTubeHLSResolver(
            session: URLSession(configuration: configuration)
        )

        // iOS has no HLS → one web_safari attempt also returns no HLS.
        let resolved = try await resolver.resolve(videoID: "server-abr-only-video")

        XCTAssertNil(resolved)
        XCTAssertEqual(InnerTubeHLSTestURLProtocol.requestCount, 2)
    }

    func testResolveFallsBackToWebSafariWhenIOSHasNoHLS() async throws {
        let safariURL = URL(string: "https://example.com/safari/master.m3u8")!
        InnerTubeHLSTestURLProtocol.requestHandler = { request in
            let body = try Self.bodyData(from: request)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            let context = try XCTUnwrap(object["context"] as? [String: Any])
            let client = try XCTUnwrap(context["client"] as? [String: Any])
            let clientName = try XCTUnwrap(client["clientName"] as? String)

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!

            if clientName == "IOS" {
                let payload: [String: Any] = [
                    "playabilityStatus": ["status": "OK"],
                    "streamingData": [:]
                ]
                return (response, try JSONSerialization.data(withJSONObject: payload))
            }

            XCTAssertEqual(clientName, "WEB")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-YouTube-Client-Name"), "1")
            XCTAssertTrue(
                (request.value(forHTTPHeaderField: "User-Agent") ?? "").contains("Safari")
            )
            let payload: [String: Any] = [
                "playabilityStatus": ["status": "OK"],
                "streamingData": ["hlsManifestUrl": safariURL.absoluteString]
            ]
            return (response, try JSONSerialization.data(withJSONObject: payload))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InnerTubeHLSTestURLProtocol.self]
        let resolver = YTInnerTubeHLSResolver(
            session: URLSession(configuration: configuration)
        )

        let resolved = try await resolver.resolve(videoID: "ios-missing-hls")

        XCTAssertEqual(resolved, safariURL)
        XCTAssertEqual(InnerTubeHLSTestURLProtocol.requestCount, 2)
    }

    func testWebSafariNon2xxDoesNotRetry() async throws {
        InnerTubeHLSTestURLProtocol.requestHandler = { request in
            let body = try Self.bodyData(from: request)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            let context = try XCTUnwrap(object["context"] as? [String: Any])
            let client = try XCTUnwrap(context["client"] as? [String: Any])
            let clientName = try XCTUnwrap(client["clientName"] as? String)

            if clientName == "IOS" {
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                let payload: [String: Any] = [
                    "playabilityStatus": ["status": "OK"],
                    "streamingData": [:]
                ]
                return (response, try JSONSerialization.data(withJSONObject: payload))
            }

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 403,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("{}".utf8))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InnerTubeHLSTestURLProtocol.self]
        let resolver = YTInnerTubeHLSResolver(
            session: URLSession(configuration: configuration)
        )

        let resolved = try await resolver.resolve(videoID: "safari-forbidden")

        XCTAssertNil(resolved)
        XCTAssertEqual(InnerTubeHLSTestURLProtocol.requestCount, 2)
    }

    private static func bodyData(from request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            return body
        }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                throw try XCTUnwrap(stream.streamError)
            }
            if count == 0 {
                break
            }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class InnerTubeHLSTestURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requestCount += 1
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
