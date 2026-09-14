import Foundation
import DomainModels

public struct AssistantV2StreamEvent: Equatable, Sendable {
    public var id: String
    public var type: AssistantV2SseEventType
    public var data: AssistantV2SseEventData?
    public var heartbeatAt: Date?

    public var shouldRefreshSnapshot: Bool { type.shouldRefreshSnapshot }

    public var eventId: Int? { data?.eventId }
}

/// Incremental SSE parser for the frozen assistant v2 event stream.
public struct AssistantV2SSEParser: Sendable {
    private var currentId = ""
    private var currentEvent = "message"
    private var dataLines: [String] = []
    private var pending = ""

    public init() {}

    public mutating func push(_ chunk: String) -> [AssistantV2StreamEvent] {
        pending += chunk
        var emitted: [AssistantV2StreamEvent] = []
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

    public mutating func finish() -> [AssistantV2StreamEvent] {
        var emitted: [AssistantV2StreamEvent] = []
        if !pending.isEmpty {
            emitted.append(contentsOf: consume(pending).map { [$0] } ?? [])
            pending = ""
        }
        if let event = flushEvent() {
            emitted.append(event)
        }
        return emitted
    }

    private mutating func consume(_ line: String) -> AssistantV2StreamEvent? {
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

    private mutating func flushEvent() -> AssistantV2StreamEvent? {
        guard !dataLines.isEmpty else {
            currentId = ""
            currentEvent = "message"
            return nil
        }
        let raw = dataLines.joined(separator: "\n")
        let type = AssistantV2SseEventType(rawValue: currentEvent)
        let json = raw.data(using: .utf8)
        let data: AssistantV2SseEventData?
        var heartbeatAt: Date?
        if type == .heartbeat {
            data = nil
            if let json, let pulse = try? JSONDecoder.assistantV2.decode(AssistantV2Heartbeat.self, from: json) {
                heartbeatAt = pulse.t
            }
        } else {
            data = json.flatMap { try? JSONDecoder.assistantV2.decode(AssistantV2SseEventData.self, from: $0) }
        }
        let event = AssistantV2StreamEvent(
            id: currentId,
            type: type,
            data: data,
            heartbeatAt: heartbeatAt
        )
        currentId = ""
        currentEvent = "message"
        dataLines = []
        return event
    }
}

private struct AssistantV2Heartbeat: Decodable {
    var t: Date
}

/// Deduplicates durable v2 events by eventId. Heartbeats are not durable.
public struct AssistantV2EventCursor: Equatable, Sendable {
    public private(set) var lastEventId: String?
    private var seenIds: Set<Int>

    public init(lastEventId: String? = nil) {
        self.lastEventId = lastEventId
        if let lastEventId, let value = Int(lastEventId) {
            self.seenIds = [value]
        } else {
            self.seenIds = []
        }
    }

    /// Returns false when the event is a duplicate durable frame and should be ignored.
    public mutating func accept(_ event: AssistantV2StreamEvent) -> Bool {
        if event.type == .heartbeat {
            return true
        }
        if let eventId = event.data?.eventId {
            if seenIds.contains(eventId) { return false }
            seenIds.insert(eventId)
            lastEventId = event.id.isEmpty ? String(eventId) : event.id
            return true
        }
        if !event.id.isEmpty {
            lastEventId = event.id
        }
        return true
    }
}

public enum AssistantV2StreamRecoveryAction: Equatable, Sendable {
    case refreshSnapshot
    case retryAfter(seconds: Int)
    case fail
}

public enum AssistantV2StreamRecovery {
    public static func action(for error: Error) -> AssistantV2StreamRecoveryAction {
        guard let gateway = error as? AssistantGatewayError else { return .fail }
        if gateway.shouldRefreshSnapshot { return .refreshSnapshot }
        if case .http(let status, let server) = gateway {
            if status == 429 || status == 503 {
                return .retryAfter(seconds: server?.retryAfterSeconds ?? 2)
            }
        }
        return .fail
    }

    public static func action(for event: AssistantV2StreamEvent) -> AssistantV2StreamRecoveryAction? {
        event.shouldRefreshSnapshot ? .refreshSnapshot : nil
    }
}

public actor AssistantV2EventStream {
    private let session: URLSession
    private let tokenProvider: AssistantTokenProviding

    public init(session: URLSession = .shared, tokenProvider: AssistantTokenProviding) {
        self.session = session
        self.tokenProvider = tokenProvider
    }

    public func events(url: URL, lastEventId: String? = nil) -> AsyncThrowingStream<AssistantV2StreamEvent, Error> {
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
                        throw AssistantV2EventStream.decodeHTTPError(status: http.statusCode)
                    }
                    var parser = AssistantV2SSEParser()
                    var cursor = AssistantV2EventCursor(lastEventId: lastEventId)
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        for event in parser.push(line + "\n") {
                            guard cursor.accept(event) else { continue }
                            continuation.yield(event)
                        }
                    }
                    for event in parser.finish() {
                        guard cursor.accept(event) else { continue }
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

    private static func decodeHTTPError(status: Int) -> AssistantGatewayError {
        if status == 409 {
            return AssistantGatewayError.http(
                status: 409,
                server: AssistantErrorBody(
                    code: "EVENT_CURSOR_EXPIRED",
                    message: "Last-Event-ID is no longer retained",
                    retryable: false,
                    traceId: ""
                )
            )
        }
        return AssistantGatewayError.http(status: status, server: nil)
    }
}

private extension JSONDecoder {
    static var assistantV2: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid ISO-8601 date \(value)")
        }
        return decoder
    }
}
