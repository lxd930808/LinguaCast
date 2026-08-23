import XCTest
@testable import PodcastEnglishStudioCore

final class YTMP4SegmentIndexTests: XCTestCase {
    // MARK: - Fixture builders

    private func appendUInt16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private func appendUInt32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private func appendFourCC(_ data: inout Data, _ type: String) {
        data.append(contentsOf: type.utf8)
    }

    private func makeBox(type: String, payload: Data) -> Data {
        var box = Data()
        appendUInt32(&box, UInt32(8 + payload.count))
        appendFourCC(&box, type)
        box.append(payload)
        return box
    }

    /// Minimal version-0 media sidx with the given references.
    private func makeSidxBox(
        timescale: UInt32,
        firstOffset: UInt32,
        references: [(size: UInt32, duration: UInt32, isIndex: Bool)]
    ) -> Data {
        var payload = Data()
        payload.append(0) // version
        payload.append(contentsOf: [0, 0, 0]) // flags
        appendUInt32(&payload, 1) // reference_ID
        appendUInt32(&payload, timescale)
        appendUInt32(&payload, 0) // earliest_presentation_time
        appendUInt32(&payload, firstOffset)
        appendUInt16(&payload, 0) // reserved
        appendUInt16(&payload, UInt16(references.count))
        for reference in references {
            var typeAndSize = reference.size & 0x7FFF_FFFF
            if reference.isIndex {
                typeAndSize |= 0x8000_0000
            }
            appendUInt32(&payload, typeAndSize)
            appendUInt32(&payload, reference.duration)
            // starts_with_SAP=1, SAP_type=1, SAP_delta=0
            appendUInt32(&payload, 0x9000_0000)
        }
        return makeBox(type: "sidx", payload: payload)
    }

    private func makePrefix(ftypSize: Int = 24, moovSize: Int = 64, sidx: Data) -> Data {
        var data = Data()
        data.append(makeBox(type: "ftyp", payload: Data(count: max(0, ftypSize - 8))))
        data.append(makeBox(type: "moov", payload: Data(count: max(0, moovSize - 8))))
        data.append(sidx)
        return data
    }

    // MARK: - Parser

    func testScanParsesVersion0MediaSidx() {
        let sidx = makeSidxBox(
            timescale: 1000,
            firstOffset: 0,
            references: [
                (size: 50_000, duration: 5005, isIndex: false),
                (size: 48_000, duration: 4990, isIndex: false),
                (size: 52_000, duration: 5010, isIndex: false),
            ]
        )
        let prefix = makePrefix(sidx: sidx)

        guard case .found(let index) = YTMP4SegmentIndexParser.scan(prefix) else {
            return XCTFail("expected found index")
        }

        XCTAssertEqual(index.segments.count, 3)
        XCTAssertEqual(index.initByteLength, prefix.count)
        XCTAssertEqual(index.segments[0].byteOffset, prefix.count)
        XCTAssertEqual(index.segments[0].byteLength, 50_000)
        XCTAssertEqual(index.segments[0].duration, 5.005, accuracy: 0.0001)
        XCTAssertEqual(index.segments[1].byteOffset, prefix.count + 50_000)
        XCTAssertEqual(index.segments[2].byteOffset, prefix.count + 50_000 + 48_000)
        XCTAssertEqual(index.targetDuration, 6)
    }

    func testScanHonorsFirstOffset() {
        let sidx = makeSidxBox(
            timescale: 1,
            firstOffset: 100,
            references: [(size: 1000, duration: 2, isIndex: false)]
        )
        let prefix = makePrefix(sidx: sidx)
        guard case .found(let index) = YTMP4SegmentIndexParser.scan(prefix) else {
            return XCTFail("expected found index")
        }
        XCTAssertEqual(index.initByteLength, prefix.count + 100)
        XCTAssertEqual(index.segments[0].byteOffset, prefix.count + 100)
    }

    func testScanSkipsNestedIndexReferences() {
        let sidx = makeSidxBox(
            timescale: 1000,
            firstOffset: 0,
            references: [
                (size: 200, duration: 0, isIndex: true),
                (size: 10_000, duration: 4000, isIndex: false),
            ]
        )
        let prefix = makePrefix(sidx: sidx)
        guard case .found(let index) = YTMP4SegmentIndexParser.scan(prefix) else {
            return XCTFail("expected found index")
        }
        XCTAssertEqual(index.segments.count, 1)
        // Nested index bytes are absorbed into the init range before media.
        XCTAssertEqual(index.initByteLength, prefix.count + 200)
        XCTAssertEqual(index.segments[0].byteOffset, prefix.count + 200)
        XCTAssertEqual(index.segments[0].duration, 4.0, accuracy: 0.0001)
    }

    func testScanRequestsMoreBytesWhenSidxTruncated() {
        let sidx = makeSidxBox(
            timescale: 1000,
            firstOffset: 0,
            references: [(size: 1000, duration: 1000, isIndex: false)]
        )
        let prefix = makePrefix(sidx: sidx)
        let truncated = prefix.prefix(prefix.count - 8)
        guard case .needMoreBytes(let minimum) = YTMP4SegmentIndexParser.scan(Data(truncated)) else {
            return XCTFail("expected needMoreBytes")
        }
        XCTAssertGreaterThanOrEqual(minimum, prefix.count)
    }

    func testScanRequestsMoreBytesWhenPrefixEndsMidBox() {
        let ftyp = makeBox(type: "ftyp", payload: Data(count: 16))
        let partial = ftyp.prefix(10)
        guard case .needMoreBytes = YTMP4SegmentIndexParser.scan(Data(partial)) else {
            return XCTFail("expected needMoreBytes")
        }
    }

    func testScanReturnsNotFoundWithoutSidx() {
        let prefix = makeBox(type: "ftyp", payload: Data(count: 16))
            + makeBox(type: "moov", payload: Data(count: 32))
        XCTAssertEqual(YTMP4SegmentIndexParser.scan(prefix), .notFound)
    }

    func testLocateSidxReportsOffsetInsidePrefix() {
        let sidx = makeSidxBox(
            timescale: 1000,
            firstOffset: 0,
            references: [(size: 1000, duration: 1000, isIndex: false)]
        )
        let prefix = makePrefix(ftypSize: 24, moovSize: 80, sidx: sidx)
        guard case .found(let offset, let size) = YTMP4SegmentIndexParser.locateSidx(in: prefix) else {
            return XCTFail("expected sidx location")
        }
        XCTAssertEqual(offset, 24 + 80)
        XCTAssertEqual(size, sidx.count)
    }
}
