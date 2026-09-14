import Foundation
import CryptoKit
import PodcastEnglishStudioCore
import DomainModels

extension URL {
    var fileSystemPath: String {
        path(percentEncoded: false)
    }

    static func storedFileURL(from value: String) -> URL {
        URL(filePath: value.removingPercentEncoding ?? value)
    }
}

struct EpisodeFiles {
    let directory: URL
    let sourceAudio: URL
    let rawTranscription: URL
    let segments: URL
    let learning: URL
    let manifest: URL

    var asrCheckpoint: URL {
        directory.appending(path: "asr_checkpoint.json")
    }

    var asrDownloadedResult: URL {
        directory.appending(path: "asr_result.json")
    }

    /// ETag sidecar for cloud artifact downloads (V10 / WP11); keyed by
    /// "<targetLanguage>|<fileName>" so variants never share cache entries.
    var cloudArtifactETags: URL {
        directory.appending(path: "cloud_artifact_etags.json")
    }
}

struct TranslationVariantFiles {
    let directory: URL
    let segments: URL
    let targetVTT: URL
    let manifest: URL
    /// Cloud-published source-language VTT (V10 / WP11); written only after
    /// SHA-256 verification, never read by the legacy local pipeline.
    var sourceVTT: URL {
        directory.appending(path: "source.vtt")
    }
    /// Internal checkpoint for background display refinement; not read by the player or synced.
    var displayRefinementCheckpoint: URL {
        directory.appending(path: "display_refinement_checkpoint.json")
    }
}

/// Errors raised while installing cloud-published artifacts into the local cache.
enum CloudArtifactCacheError: Error, Equatable {
    /// Downloaded bytes did not match the manifest SHA-256; the existing cache
    /// was left untouched.
    case checksumMismatch(expected: String, actual: String)
    /// A required manifest role this client does not know how to install.
    case unsupportedRequiredRole(String)
    /// A required artifact was not in `ready` status on the server manifest.
    case missingRequiredArtifact(String)
    /// The installed segments payload was empty or only partially translated.
    case incompleteSegments
    /// The ready job carried no artifact manifest.
    case missingManifest
    /// Artifact bundle schema is newer than this client understands.
    case incompatibleSchema(Int)
}

final class LocalFileStore {
    private let fileManager: FileManager
    private static let writeLock = NSLock()

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func episodeFiles(episodeID: String) throws -> EpisodeFiles {
        let support = try fileManager.url(
            for: LocalArtifactStoragePolicy.runtimeDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appending(path: "Episodes").appending(path: episodeID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return EpisodeFiles(
            directory: directory,
            sourceAudio: directory.appending(path: "source.mp3"),
            rawTranscription: directory.appending(path: "raw_transcription.json"),
            segments: directory.appending(path: "segments.json"),
            learning: directory.appending(path: "learning.json"),
            manifest: directory.appending(path: "manifest.json")
        )
    }

    func translationFiles(episodeID: String, target: TranslationTarget) throws -> TranslationVariantFiles {
        let episode = try episodeFiles(episodeID: episodeID)
        let directory = episode.directory
            .appending(path: "translations")
            .appending(path: target.fileComponent)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return TranslationVariantFiles(
            directory: directory,
            segments: directory.appending(path: "segments.json"),
            targetVTT: directory.appending(path: "target.vtt"),
            manifest: directory.appending(path: "manifest.json")
        )
    }

    /// Removes transcription / translation / learning artifacts while keeping `source.mp3`.
    func clearGenerationArtifacts(episodeID: String) throws {
        let files = try episodeFiles(episodeID: episodeID)
        for url in [
            files.rawTranscription,
            files.segments,
            files.learning,
            files.manifest,
            files.asrCheckpoint,
            files.asrDownloadedResult,
            files.cloudArtifactETags
        ] {
            try? fileManager.removeItem(at: url)
        }
        let translationsRoot = files.directory.appending(path: "translations")
        if fileManager.fileExists(atPath: translationsRoot.fileSystemPath) {
            try? fileManager.removeItem(at: translationsRoot)
        }
    }

    func migrateLegacySimplifiedChineseIfNeeded(
        episodeID: String,
        to destination: TranslationVariantFiles
    ) throws -> Bool {
        let legacy = try episodeFiles(episodeID: episodeID)
        guard fileManager.fileExists(atPath: legacy.segments.fileSystemPath) else {
            return false
        }
        try fileManager.createDirectory(at: destination.directory, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: destination.segments.fileSystemPath) {
            try atomicCopy(from: legacy.segments, to: destination.segments)
        }
        _ = try migrateLegacyEnglishBaseIfNeeded(episodeID: episodeID)
        return true
    }

    @discardableResult
    func migrateLegacyEnglishBaseIfNeeded(episodeID: String) throws -> Bool {
        let legacy = try episodeFiles(episodeID: episodeID)
        if fileManager.fileExists(atPath: legacy.rawTranscription.fileSystemPath) { return true }
        guard fileManager.fileExists(atPath: legacy.segments.fileSystemPath) else { return false }
        let legacySegments = try readJSON([LearningSegment].self, from: legacy.segments)
        let base = legacySegments.map { segment in
            var value = segment
            value.translation = ""
            return value
        }
        try writeJSON(base, to: legacy.rawTranscription)
        return true
    }

    func migrateLegacySegmentRecordsIfNeeded(
        _ records: [SegmentRecord],
        episodeID: String,
        target: TranslationTarget,
        destination: TranslationVariantFiles
    ) throws -> Bool {
        guard !records.isEmpty else {
            return fileManager.fileExists(atPath: destination.segments.fileSystemPath)
        }
        let mapped = records
            .sorted { $0.sequence < $1.sequence }
            .map {
                LearningSegment(
                    sequence: $0.sequence,
                    startMS: $0.startMS,
                    endMS: $0.endMS,
                    text: $0.text,
                    learningText: $0.learningText,
                    translation: $0.translation,
                    speaker: $0.speaker,
                    notes: $0.notes
                )
            }
        let episode = try episodeFiles(episodeID: episodeID)
        if !fileManager.fileExists(atPath: episode.rawTranscription.fileSystemPath) {
            let english = mapped.map { segment in
                var value = segment
                value.translation = ""
                return value
            }
            try writeJSON(english, to: episode.rawTranscription)
        }
        if target == .simplifiedChinese,
           !fileManager.fileExists(atPath: destination.segments.fileSystemPath) {
            try writeJSON(mapped, to: destination.segments)
        }
        return fileManager.fileExists(atPath: destination.segments.fileSystemPath)
    }

    private func atomicCopy(from source: URL, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.copyItem(at: source, to: temporary)
        try fileManager.moveItem(at: temporary, to: destination)
    }

    func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)

        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        Self.writeLock.lock()
        defer { Self.writeLock.unlock() }

        let legacyTemp = url.appendingPathExtension("tmp")
        if fileManager.fileExists(atPath: legacyTemp.fileSystemPath) {
            try? fileManager.removeItem(at: legacyTemp)
        }

        try data.write(to: url, options: .atomic)
    }

    func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - Cloud artifact cache (V10 / WP11)

    /// Stored ETags for cloud artifact downloads, keyed "<target>|<fileName>".
    /// Returns an empty table when the sidecar is absent or unreadable.
    func cloudArtifactETags(episodeID: String) -> [String: String] {
        guard let files = try? episodeFiles(episodeID: episodeID),
              let etags = try? readJSON([String: String].self, from: files.cloudArtifactETags)
        else { return [:] }
        return etags
    }

    /// Persists the ETag sidecar. Called only after every artifact in a batch
    /// installed successfully, so an interrupted download keeps the previous
    /// table consistent with the previous on-disk cache.
    func writeCloudArtifactETags(_ etags: [String: String], episodeID: String) throws {
        let files = try episodeFiles(episodeID: episodeID)
        try writeJSON(etags, to: files.cloudArtifactETags)
    }

    /// Verifies `data` against the manifest SHA-256 without writing anything.
    func verifyArtifact(_ data: Data, sha256: String) throws {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256.lowercased() else {
            throw CloudArtifactCacheError.checksumMismatch(expected: sha256, actual: digest)
        }
    }

    /// Verifies `data` against the manifest SHA-256, then atomically replaces
    /// `destination` (temp sibling + rename). A checksum failure or an
    /// interrupted download (which never reaches this call) leaves the
    /// existing cache byte-identical.
    func installVerifiedArtifact(_ data: Data, sha256: String, to destination: URL) throws {
        try verifyArtifact(data, sha256: sha256)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporary = destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).cloud.\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        if fileManager.fileExists(atPath: destination.fileSystemPath) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporary, to: destination)
    }
}
