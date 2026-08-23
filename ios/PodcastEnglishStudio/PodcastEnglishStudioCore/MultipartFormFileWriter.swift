import Foundation

public struct MultipartFormField: Equatable, Sendable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct MultipartFormFile: Equatable, Sendable {
    public let url: URL
    public let byteCount: Int64

    public init(url: URL, byteCount: Int64) {
        self.url = url
        self.byteCount = byteCount
    }
}

public enum MultipartFormFileWriterError: Error, Equatable {
    case invalidChunkSize
    case unableToCreateTemporaryFile
}

public enum MultipartFormFileWriter {
    public static let defaultChunkSize = 1_048_576

    public static func writeTemporary(
        fields: [MultipartFormField],
        fileFieldName: String,
        fileName: String,
        contentType: String,
        sourceFileURL: URL,
        boundary: String,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        chunkSize: Int = defaultChunkSize
    ) throws -> MultipartFormFile {
        guard chunkSize > 0 else {
            throw MultipartFormFileWriterError.invalidChunkSize
        }
        try Task.checkCancellation()

        let sourceHandle = try FileHandle(forReadingFrom: sourceFileURL)
        defer { try? sourceHandle.close() }

        let outputURL = temporaryDirectory
            .appendingPathComponent("multipart-upload-\(UUID().uuidString).body")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
            throw MultipartFormFileWriterError.unableToCreateTemporaryFile
        }

        var shouldRemoveOutput = true
        defer {
            if shouldRemoveOutput {
                try? FileManager.default.removeItem(at: outputURL)
            }
        }

        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }

        var byteCount: Int64 = 0

        func write(_ data: Data) throws {
            try outputHandle.write(contentsOf: data)
            byteCount += Int64(data.count)
        }

        func write(_ string: String) throws {
            try write(Data(string.utf8))
        }

        for field in fields {
            try write("--\(boundary)\r\n")
            try write("Content-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n")
            try write("\(field.value)\r\n")
        }

        try write("--\(boundary)\r\n")
        try write(
            "Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(fileName)\"\r\n"
        )
        try write("Content-Type: \(contentType)\r\n\r\n")

        while let chunk = try sourceHandle.read(upToCount: chunkSize), !chunk.isEmpty {
            try Task.checkCancellation()
            try write(chunk)
        }

        try write("\r\n--\(boundary)--\r\n")
        try sourceHandle.close()
        try outputHandle.close()

        shouldRemoveOutput = false
        return MultipartFormFile(url: outputURL, byteCount: byteCount)
    }

    public static func withTemporaryBody<T>(
        fields: [MultipartFormField],
        fileFieldName: String,
        fileName: String,
        contentType: String,
        sourceFileURL: URL,
        boundary: String,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        chunkSize: Int = defaultChunkSize,
        operation: (MultipartFormFile) async throws -> T
    ) async throws -> T {
        let body = try writeTemporary(
            fields: fields,
            fileFieldName: fileFieldName,
            fileName: fileName,
            contentType: contentType,
            sourceFileURL: sourceFileURL,
            boundary: boundary,
            temporaryDirectory: temporaryDirectory,
            chunkSize: chunkSize
        )
        defer { try? FileManager.default.removeItem(at: body.url) }
        try Task.checkCancellation()
        return try await operation(body)
    }
}
