import Foundation

/// One media subsegment described by an ISO BMFF `sidx` box.
public struct YTMP4MediaSegment: Sendable, Equatable {
    public let byteOffset: Int
    public let byteLength: Int
    public let duration: TimeInterval

    public init(byteOffset: Int, byteLength: Int, duration: TimeInterval) {
        self.byteOffset = byteOffset
        self.byteLength = byteLength
        self.duration = duration
    }
}

/// Init + media segments derived from an fMP4/`sidx` prefix.
public struct YTMP4SegmentIndex: Sendable, Equatable {
    /// Bytes `[0, initByteLength)` form the HLS `#EXT-X-MAP` init segment
    /// (everything before the first media subsegment, typically `ftyp`+`moov`+`sidx`).
    public let initByteLength: Int
    public let segments: [YTMP4MediaSegment]

    public init(initByteLength: Int, segments: [YTMP4MediaSegment]) {
        self.initByteLength = initByteLength
        self.segments = segments
    }

    public var targetDuration: Int {
        let maxDuration = segments.map(\.duration).max() ?? 1
        return max(1, Int(maxDuration.rounded(.up)))
    }
}

public enum YTMP4SegmentIndexScanResult: Sendable, Equatable {
    case found(YTMP4SegmentIndex)
    /// Prefix is incomplete; caller should fetch at least this many leading bytes.
    case needMoreBytes(minimum: Int)
    /// Complete boxes were scanned and no usable media `sidx` was present.
    case notFound
}

/// Pure ISO BMFF helpers for locating and parsing `sidx` from a file prefix.
public enum YTMP4SegmentIndexParser {
    public static let defaultProbeLength = 128 * 1024
    public static let maxProbeLength = 1024 * 1024

    /// Scan `data` for the first media-level `sidx` (reference_type == 0 entries)
    /// and build a segment index. Nested/index-only references are skipped.
    public static func scan(_ data: Data) -> YTMP4SegmentIndexScanResult {
        switch locateSidx(in: data) {
        case .needMoreBytes(let minimum):
            return .needMoreBytes(minimum: minimum)
        case .notFound:
            return .notFound
        case .found(let offset, let size):
            guard offset + size <= data.count else {
                return .needMoreBytes(minimum: offset + size)
            }
            let box = data.subdata(in: offset..<(offset + size))
            guard let index = parseSidxBox(box, boxFileOffset: offset) else {
                return .notFound
            }
            return .found(index)
        }
    }

    // MARK: - Box scan

    enum SidxLocation: Equatable {
        case found(offset: Int, size: Int)
        case needMoreBytes(minimum: Int)
        case notFound
    }

    static func locateSidx(in data: Data) -> SidxLocation {
        var offset = 0
        while offset < data.count {
            let remaining = data.count - offset
            guard remaining >= 8 else {
                return .needMoreBytes(minimum: offset + 8)
            }

            let size32 = readUInt32(data, at: offset)
            let type = readFourCC(data, at: offset + 4)
            var headerSize = 8
            var boxSize: Int
            if size32 == 1 {
                guard remaining >= 16 else {
                    return .needMoreBytes(minimum: offset + 16)
                }
                let large = readUInt64(data, at: offset + 8)
                guard large > 16, large <= UInt64(Int.max) else {
                    return .notFound
                }
                boxSize = Int(large)
                headerSize = 16
            } else if size32 == 0 {
                // Extends to EOF — only useful when the whole file is present.
                boxSize = remaining
            } else {
                boxSize = Int(size32)
            }

            guard boxSize >= headerSize else {
                return .notFound
            }

            if type == "sidx" {
                if remaining < boxSize {
                    return .needMoreBytes(minimum: offset + boxSize)
                }
                return .found(offset: offset, size: boxSize)
            }

            if remaining < boxSize {
                return .needMoreBytes(minimum: offset + boxSize)
            }
            offset += boxSize
        }
        return .notFound
    }

    // MARK: - sidx parse

    /// Parse a complete `sidx` box (including the 8/16-byte header).
    static func parseSidxBox(_ box: Data, boxFileOffset: Int) -> YTMP4SegmentIndex? {
        guard box.count >= 8 else { return nil }
        let size32 = readUInt32(box, at: 0)
        var cursor = 8
        if size32 == 1 {
            guard box.count >= 16 else { return nil }
            cursor = 16
        }
        guard cursor + 4 <= box.count else { return nil }
        let version = box[cursor]
        cursor += 4 // version + flags

        guard cursor + 8 <= box.count else { return nil }
        _ = readUInt32(box, at: cursor) // reference_ID
        cursor += 4
        let timescale = readUInt32(box, at: cursor)
        cursor += 4
        guard timescale > 0 else { return nil }

        let earliestPresentationTime: UInt64
        let firstOffset: UInt64
        if version == 0 {
            guard cursor + 8 <= box.count else { return nil }
            earliestPresentationTime = UInt64(readUInt32(box, at: cursor))
            cursor += 4
            firstOffset = UInt64(readUInt32(box, at: cursor))
            cursor += 4
        } else {
            guard cursor + 16 <= box.count else { return nil }
            earliestPresentationTime = readUInt64(box, at: cursor)
            cursor += 8
            firstOffset = readUInt64(box, at: cursor)
            cursor += 8
        }
        _ = earliestPresentationTime

        guard cursor + 4 <= box.count else { return nil }
        cursor += 2 // reserved
        let referenceCount = Int(readUInt16(box, at: cursor))
        cursor += 2

        let boxEndFileOffset = boxFileOffset + box.count
        guard firstOffset <= UInt64(Int.max - boxEndFileOffset) else { return nil }
        var mediaOffset = boxEndFileOffset + Int(firstOffset)

        var segments: [YTMP4MediaSegment] = []
        segments.reserveCapacity(referenceCount)

        for _ in 0..<referenceCount {
            guard cursor + 12 <= box.count else { return nil }
            let typeAndSize = readUInt32(box, at: cursor)
            cursor += 4
            let subsegmentDuration = readUInt32(box, at: cursor)
            cursor += 4
            cursor += 4 // SAP fields unused for playlist generation

            let isIndexReference = (typeAndSize & 0x8000_0000) != 0
            let referencedSize = Int(typeAndSize & 0x7FFF_FFFF)
            guard referencedSize > 0 else { continue }

            if isIndexReference {
                // Nested sidx — skip its byte range; media follows after it.
                mediaOffset += referencedSize
                continue
            }

            let duration = TimeInterval(subsegmentDuration) / TimeInterval(timescale)
            segments.append(
                YTMP4MediaSegment(
                    byteOffset: mediaOffset,
                    byteLength: referencedSize,
                    duration: duration
                )
            )
            mediaOffset += referencedSize
        }

        // Init = every leading byte before the first media subsegment (ftyp/moov/sidx
        // and any nested index boxes skipped above).
        guard let first = segments.first, first.byteOffset > 0 else { return nil }
        return YTMP4SegmentIndex(initByteLength: first.byteOffset, segments: segments)
    }

    // MARK: - Binary helpers

    static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        (UInt64(readUInt32(data, at: offset)) << 32) | UInt64(readUInt32(data, at: offset + 4))
    }

    static func readFourCC(_ data: Data, at offset: Int) -> String {
        String(bytes: data[offset..<(offset + 4)], encoding: .ascii) ?? ""
    }
}

/// Fetches leading bytes of a googlevideo stream and parses `sidx` when present.
public actor YTMP4SegmentIndexFetcher {
    public static let shared = YTMP4SegmentIndexFetcher()

    private let session: URLSession
    private let timeout: TimeInterval
    private let userAgent: String

    public init(
        session: URLSession? = nil,
        timeout: TimeInterval = 3,
        userAgent: String = "com.google.ios.youtube/21.02.3 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"
    ) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
        self.timeout = timeout
        self.userAgent = userAgent
    }

    /// Returns a segment index or `nil` when the probe fails / times out / has no sidx.
    public func fetchIndex(for streamURL: URL) async -> YTMP4SegmentIndex? {
        do {
            return try await withTimeout(seconds: timeout) {
                try await self.probe(streamURL: streamURL)
            }
        } catch {
            return nil
        }
    }

    /// Parallel probes for video + audio; each failure independently yields `nil`.
    public func fetchIndexes(
        videoURL: URL,
        audioURL: URL
    ) async -> (video: YTMP4SegmentIndex?, audio: YTMP4SegmentIndex?) {
        async let video = fetchIndex(for: videoURL)
        async let audio = fetchIndex(for: audioURL)
        return await (video, audio)
    }

    private func probe(streamURL: URL) async throws -> YTMP4SegmentIndex? {
        var probeLength = YTMP4SegmentIndexParser.defaultProbeLength
        var data = try await fetchRange(url: streamURL, endInclusive: probeLength - 1)

        switch YTMP4SegmentIndexParser.scan(data) {
        case .found(let index):
            return index
        case .notFound:
            return nil
        case .needMoreBytes(let minimum):
            let nextLength = min(
                max(minimum, probeLength * 2),
                YTMP4SegmentIndexParser.maxProbeLength
            )
            guard nextLength > probeLength else { return nil }
            probeLength = nextLength
            data = try await fetchRange(url: streamURL, endInclusive: probeLength - 1)
            if case .found(let index) = YTMP4SegmentIndexParser.scan(data) {
                return index
            }
            return nil
        }
    }

    private func fetchRange(url: URL, endInclusive: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-\(endInclusive)", forHTTPHeaderField: "Range")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        // 206 Partial Content is ideal; some CDNs may still answer 200 with a prefix.
        guard (200...299).contains(http.statusCode), !data.isEmpty else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                let nanoseconds = UInt64(max(seconds, 0.1) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                throw URLError(.timedOut)
            }
            guard let value = try await group.next() else {
                throw URLError(.timedOut)
            }
            group.cancelAll()
            return value
        }
    }
}
