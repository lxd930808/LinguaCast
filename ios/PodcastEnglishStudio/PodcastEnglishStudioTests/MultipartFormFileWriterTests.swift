import Foundation
import XCTest
@testable import PodcastEnglishStudioCore

final class MultipartFormFileWriterTests: XCTestCase {
    func testTemporaryBodyMatchesMultipartWireFormatAndPreservesBinaryPayload() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.mp3")
        try Data([0x00, 0xff, 0x0d, 0x0a, 0x41]).write(to: sourceURL)

        let result = try MultipartFormFileWriter.writeTemporary(
            fields: [
                MultipartFormField(name: "policy", value: "signed-policy"),
                MultipartFormField(name: "key", value: "uploads/source.mp3")
            ],
            fileFieldName: "file",
            fileName: "source.mp3",
            contentType: "audio/mpeg",
            sourceFileURL: sourceURL,
            boundary: "TestBoundary",
            temporaryDirectory: directory,
            chunkSize: 2
        )
        defer { try? FileManager.default.removeItem(at: result.url) }

        var expected = Data((
            "--TestBoundary\r\n"
                + "Content-Disposition: form-data; name=\"policy\"\r\n\r\n"
                + "signed-policy\r\n"
                + "--TestBoundary\r\n"
                + "Content-Disposition: form-data; name=\"key\"\r\n\r\n"
                + "uploads/source.mp3\r\n"
                + "--TestBoundary\r\n"
                + "Content-Disposition: form-data; name=\"file\"; filename=\"source.mp3\"\r\n"
                + "Content-Type: audio/mpeg\r\n\r\n"
        ).utf8)
        expected.append(contentsOf: [0x00, 0xff, 0x0d, 0x0a, 0x41])
        expected.append(Data("\r\n--TestBoundary--\r\n".utf8))

        let actual = try Data(contentsOf: result.url)
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(result.byteCount, Int64(expected.count))
    }

    func testNinetyMiBPayloadIsWrittenIncrementallyWithCorrectLengthAndSamples() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("large.mp3")
        XCTAssertTrue(FileManager.default.createFile(atPath: sourceURL.path, contents: nil))

        let mebibyte = 1_048_576
        let sourceHandle = try FileHandle(forWritingTo: sourceURL)
        for index in 0..<90 {
            try sourceHandle.write(contentsOf: Data(repeating: UInt8(index), count: mebibyte))
        }
        try sourceHandle.close()

        let result = try MultipartFormFileWriter.writeTemporary(
            fields: [],
            fileFieldName: "file",
            fileName: "large.mp3",
            contentType: "audio/mpeg",
            sourceFileURL: sourceURL,
            boundary: "LargeBoundary",
            temporaryDirectory: directory
        )
        defer { try? FileManager.default.removeItem(at: result.url) }

        let prefix = Data((
            "--LargeBoundary\r\n"
                + "Content-Disposition: form-data; name=\"file\"; filename=\"large.mp3\"\r\n"
                + "Content-Type: audio/mpeg\r\n\r\n"
        ).utf8)
        let suffix = Data("\r\n--LargeBoundary--\r\n".utf8)
        XCTAssertEqual(result.byteCount, Int64(prefix.count + (90 * mebibyte) + suffix.count))

        let outputHandle = try FileHandle(forReadingFrom: result.url)
        defer { try? outputHandle.close() }
        XCTAssertEqual(try outputHandle.read(upToCount: prefix.count), prefix)
        try outputHandle.seek(toOffset: UInt64(prefix.count + (44 * mebibyte)))
        XCTAssertEqual(try outputHandle.read(upToCount: 16), Data(repeating: 44, count: 16))
        try outputHandle.seek(toOffset: UInt64(prefix.count + (89 * mebibyte)))
        XCTAssertEqual(try outputHandle.read(upToCount: 16), Data(repeating: 89, count: 16))
        try outputHandle.seek(toOffset: UInt64(prefix.count + (90 * mebibyte)))
        XCTAssertEqual(try outputHandle.readToEnd(), suffix)
    }

    func testWithTemporaryBodyRemovesFileAfterOperationFailure() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.mp3")
        try Data("audio".utf8).write(to: sourceURL)
        var bodyURL: URL?

        do {
            _ = try await MultipartFormFileWriter.withTemporaryBody(
                fields: [],
                fileFieldName: "file",
                fileName: "source.mp3",
                contentType: "audio/mpeg",
                sourceFileURL: sourceURL,
                boundary: "FailureBoundary",
                temporaryDirectory: directory
            ) { body in
                bodyURL = body.url
                throw ExpectedError.operationFailed
            } as Void
            XCTFail("Expected operation failure")
        } catch ExpectedError.operationFailed {
            // Expected.
        }

        XCTAssertNotNil(bodyURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(bodyURL).path))
    }

    func testWithTemporaryBodyRemovesFileAfterSuccessfulOperation() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.mp3")
        try Data("audio".utf8).write(to: sourceURL)
        var bodyURL: URL?

        let byteCount = try await MultipartFormFileWriter.withTemporaryBody(
            fields: [],
            fileFieldName: "file",
            fileName: "source.mp3",
            contentType: "audio/mpeg",
            sourceFileURL: sourceURL,
            boundary: "SuccessBoundary",
            temporaryDirectory: directory
        ) { body in
            bodyURL = body.url
            XCTAssertTrue(FileManager.default.fileExists(atPath: body.url.path))
            return body.byteCount
        }

        XCTAssertGreaterThan(byteCount, 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(bodyURL).path))
    }

    func testWithTemporaryBodyRemovesFileAfterCancellation() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.mp3")
        try Data("audio".utf8).write(to: sourceURL)
        let capture = URLCapture()
        let bodyCreated = expectation(description: "Temporary multipart body created")

        let task = Task {
            try await MultipartFormFileWriter.withTemporaryBody(
                fields: [],
                fileFieldName: "file",
                fileName: "source.mp3",
                contentType: "audio/mpeg",
                sourceFileURL: sourceURL,
                boundary: "CancellationBoundary",
                temporaryDirectory: directory
            ) { body in
                await capture.set(body.url)
                bodyCreated.fulfill()
                try await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }

        await fulfillment(of: [bodyCreated], timeout: 5)
        task.cancel()

        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let capturedURL = await capture.value
        let bodyURL = try XCTUnwrap(capturedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bodyURL.path))
    }

    func testMissingSourceDoesNotCreateMultipartFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(
            try MultipartFormFileWriter.writeTemporary(
                fields: [],
                fileFieldName: "file",
                fileName: "missing.mp3",
                contentType: "audio/mpeg",
                sourceFileURL: directory.appendingPathComponent("missing.mp3"),
                boundary: "MissingBoundary",
                temporaryDirectory: directory
            )
        )

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testUnwritableTemporaryLocationDoesNotLeavePartialBody() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.mp3")
        try Data("audio".utf8).write(to: sourceURL)
        let nonDirectoryURL = directory.appendingPathComponent("not-a-directory")
        try Data("occupied".utf8).write(to: nonDirectoryURL)

        XCTAssertThrowsError(
            try MultipartFormFileWriter.writeTemporary(
                fields: [],
                fileFieldName: "file",
                fileName: "source.mp3",
                contentType: "audio/mpeg",
                sourceFileURL: sourceURL,
                boundary: "WriteFailureBoundary",
                temporaryDirectory: nonDirectoryURL
            )
        )

        let remainingNames = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(remainingNames, ["not-a-directory", "source.mp3"])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultipartFormFileWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private enum ExpectedError: Error {
    case operationFailed
}

private actor URLCapture {
    private(set) var value: URL?

    func set(_ value: URL) {
        self.value = value
    }
}
