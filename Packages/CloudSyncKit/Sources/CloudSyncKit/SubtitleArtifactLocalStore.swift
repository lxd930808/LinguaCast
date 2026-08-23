import Foundation
import PodcastEnglishStudioCore

// 自 app 层 LocalFileStore.swift 迁入：仅供 CloudSyncCoordinator 使用的云端字幕本地缓存。
// 磁盘布局（CloudSubtitleArtifacts/index.json 与 payload 文件名）保持不变。

public struct SubtitleArtifactLocalEntry: Codable, Hashable {
    public var metadata: SubtitleArtifactMetadata
    public var relativePayloadPath: String?

    public init(metadata: SubtitleArtifactMetadata, relativePayloadPath: String?) {
        self.metadata = metadata
        self.relativePayloadPath = relativePayloadPath
    }
}

public final class SubtitleArtifactLocalStore {
    private let fileManager: FileManager
    private let directory: URL
    private let indexURL: URL
    private var entries: [String: SubtitleArtifactLocalEntry]
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let support = (try? fileManager.url(
            for: LocalArtifactStoragePolicy.runtimeDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        directory = support.appending(path: "CloudSubtitleArtifacts")
        indexURL = directory.appending(path: "index.json")
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? decoder.decode([String: SubtitleArtifactLocalEntry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    public var activeCount: Int {
        entries.values.filter { !$0.metadata.isDeleted }.count
    }

    public var hasPersistedIndex: Bool {
        fileManager.fileExists(atPath: indexURL.fileSystemPath)
    }

    public var activeByteCount: Int64 {
        entries.values.reduce(0) { partial, entry in
            partial + (entry.metadata.isDeleted ? 0 : entry.metadata.byteCount)
        }
    }

    public var allEntries: [SubtitleArtifactLocalEntry] {
        Array(entries.values)
    }

    public func entry(for identity: SubtitleArtifactIdentity) -> SubtitleArtifactLocalEntry? {
        entries[identity.recordName]
    }

    public func entry(recordName: String) -> SubtitleArtifactLocalEntry? {
        entries[recordName]
    }

    public func payloadURL(for identity: SubtitleArtifactIdentity) -> URL? {
        guard let path = entry(for: identity)?.relativePayloadPath else { return nil }
        return directory.appending(path: path)
    }

    public func envelope(for identity: SubtitleArtifactIdentity) -> SubtitleArtifactEnvelope? {
        guard let entry = entry(for: identity),
              !entry.metadata.isDeleted,
              let url = payloadURL(for: identity),
              let data = try? Data(contentsOf: url),
              let envelope = try? SubtitleArtifactPayloadValidator.validate(
                data: data,
                metadata: entry.metadata
              )
        else { return nil }
        return envelope
    }

    public func verifiedPayloadURL(for identity: SubtitleArtifactIdentity) -> URL? {
        guard envelope(for: identity) != nil else { return nil }
        return payloadURL(for: identity)
    }

    public func anyEnvelope(
        contentKind: TranslationContentKind,
        contentKey: String,
        excluding targetLanguage: String
    ) -> SubtitleArtifactEnvelope? {
        entries.values
            .filter {
                !$0.metadata.isDeleted
                    && $0.metadata.identity.contentKind == contentKind
                    && $0.metadata.identity.contentKey == contentKey
                    && $0.metadata.identity.targetLanguage != targetLanguage
            }
            .sorted { $0.metadata.version > $1.metadata.version }
            .lazy
            .compactMap { self.envelope(for: $0.metadata.identity) }
            .first
    }

    public func install(
        data: Data,
        metadata: SubtitleArtifactMetadata
    ) throws {
        _ = try SubtitleArtifactPayloadValidator.validate(data: data, metadata: metadata)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = "\(metadata.identity.recordName).json"
        let destination = directory.appending(path: fileName)
        try data.write(to: destination, options: .atomic)
        entries[metadata.identity.recordName] = SubtitleArtifactLocalEntry(
            metadata: metadata,
            relativePayloadPath: fileName
        )
        try persistIndex()
    }

    public func installTombstone(_ metadata: SubtitleArtifactMetadata) throws {
        guard metadata.isDeleted else { throw SubtitleArtifactValidationError.invalidPayload }
        if let url = payloadURL(for: metadata.identity) {
            try? fileManager.removeItem(at: url)
        }
        entries[metadata.identity.recordName] = SubtitleArtifactLocalEntry(
            metadata: metadata,
            relativePayloadPath: nil
        )
        try persistIndex()
    }

    public func removeEntry(for identity: SubtitleArtifactIdentity) throws {
        if let url = payloadURL(for: identity) {
            try? fileManager.removeItem(at: url)
        }
        entries.removeValue(forKey: identity.recordName)
        try persistIndex()
    }

    public func ensureIndexExists() throws {
        guard !hasPersistedIndex else { return }
        try persistIndex()
    }

    private func persistIndex() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(entries).write(to: indexURL, options: .atomic)
    }
}
