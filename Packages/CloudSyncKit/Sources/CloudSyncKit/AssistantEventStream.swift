import Foundation
import DomainModels

public struct AssistantStreamEvent: Equatable, Sendable {
    public var id: String
    public var type: AssistantSseEventType
    public var data: AssistantSseEventData?
}

/// Incremental SSE parser for the frozen assistant event stream.
public struct AssistantSSEParser: Sendable {
    private var currentId = ""
    private var currentEvent = "message"
    private var dataLines: [String] = []
    private var pending = ""

    public init() {}

    public mutating func push(_ chunk: String) -> [AssistantStreamEvent] {
        pending += chunk
        var emitted: [AssistantStreamEvent] = []
        while let newline = pending.firstIndex(of: "\n") {
            var line = String(pending[..<newline])
            pending.removeSubrange(..<pending.index(after: newline))
            if line.hasSuffix("\r") { line.removeLast() }
            if let event = consume(line) {
                emitted.append(event)
            }
        }
        return emitted
    }

    public mutating func finish() -> [AssistantStreamEvent] {
        var emitted: [AssistantStreamEvent] = []
        if !pending.isEmpty {
            emitted.append(contentsOf: consume(pending).map { [$0] } ?? [])
            pending = ""
        }
        if let event = flushEvent() {
            emitted.append(event)
        }
        return emitted
    }

    private mutating func consume(_ line: String) -> AssistantStreamEvent? {
        if line.isEmpty {
            return flushEvent()
        }
        if line.hasPrefix("id:") {
            currentId = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("event:") {
            currentEvent = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("data:") {
            dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private mutating func flushEvent() -> AssistantStreamEvent? {
        guard !dataLines.isEmpty else {
            currentId = ""
            currentEvent = "message"
            return nil
        }
        let raw = dataLines.joined(separator: "\n")
        let decoded = raw.data(using: .utf8).flatMap { try? JSONDecoder.assistant.decode(AssistantSseEventData.self, from: $0) }
        let event = AssistantStreamEvent(
            id: currentId,
            type: AssistantSseEventType(rawValue: currentEvent),
            data: decoded
        )
        currentId = ""
        currentEvent = "message"
        dataLines = []
        return event
    }
}

public actor AssistantEventStream {
    private let session: URLSession
    private let tokenProvider: AssistantTokenProviding

    public init(session: URLSession = .shared, tokenProvider: AssistantTokenProviding) {
        self.session = session
        self.tokenProvider = tokenProvider
    }

    public func events(url: URL, lastEventId: String? = nil) -> AsyncThrowingStream<AssistantStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let token = try await tokenProvider.bearerToken()
                    var request = URLRequest(url: url)
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    if let lastEventId {
                        request.setValue(lastEventId, forHTTPHeaderField: "Last-Event-ID")
                    }
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        if http.statusCode == 409 {
                            throw AssistantGatewayError.http(
                                status: 409,
                                server: AssistantErrorBody(
                                    code: "EVENT_CURSOR_EXPIRED",
                                    message: "Last-Event-ID is no longer retained",
                                    retryable: false,
                                    traceId: ""
                                )
                            )
                        }
                        throw AssistantGatewayError.http(status: http.statusCode, server: nil)
                    }
                    var parser = AssistantSSEParser()
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        for event in parser.push(line + "\n") {
                            continuation.yield(event)
                        }
                    }
                    for event in parser.finish() {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private extension JSONDecoder {
    static var assistant: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
