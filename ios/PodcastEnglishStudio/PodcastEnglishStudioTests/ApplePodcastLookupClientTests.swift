import Foundation
import XCTest
@testable import PodcastEnglishStudioCore

final class ApplePodcastLookupClientTests: XCTestCase {
    override func tearDown() {
        LookupURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testLookupUsesExactIDRequestAndDecodesFixedResponse() async throws {
        LookupURLProtocol.requestHandler = { request in
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            let query = Dictionary(
                uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
            )
            XCTAssertEqual(components.path, "/lookup")
            XCTAssertEqual(query, ["id": "1469394914", "entity": "podcast"])
            XCTAssertNil(query["term"])
            let json = """
            {
              "resultCount": 1,
              "results": [{
                "feedUrl": "https://example.com/feed.xml",
                "artistName": "Example Host",
                "collectionName": "Example Show",
                "collectionViewUrl": "https://podcasts.apple.com/podcast/id1469394914",
                "artworkUrl600": "https://example.com/artwork.jpg"
              }]
            }
            """
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(json.utf8)
            )
        }

        let result = try await makeClient().lookup(id: "1469394914")

        XCTAssertEqual(result.feedUrl, "https://example.com/feed.xml")
        XCTAssertEqual(result.artistName, "Example Host")
        XCTAssertEqual(result.collectionName, "Example Show")
        XCTAssertEqual(result.artworkUrl600, "https://example.com/artwork.jpg")
    }

    func testLookupRejectsHTTPFailureWithoutUsingOnlineService() async {
        LookupURLProtocol.requestHandler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }

        do {
            _ = try await makeClient().lookup(id: "123")
            XCTFail("Expected HTTP failure")
        } catch let error as ApplePodcastLookupError {
            guard case .invalidResponse = error else {
                return XCTFail("Unexpected lookup error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeClient() -> ApplePodcastLookupClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LookupURLProtocol.self]
        return ApplePodcastLookupClient(session: URLSession(configuration: configuration))
    }
}

private final class LookupURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: ApplePodcastLookupError.invalidRequest)
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
