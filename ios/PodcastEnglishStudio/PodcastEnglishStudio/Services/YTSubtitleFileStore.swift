import Foundation
import PodcastEnglishStudioCore

struct YTSubtitleFiles {
    let directory: URL
    let englishVTT: URL
    let chineseVTT: URL
    let segments: URL
    let baseSegments: URL

    var asrCheckpoint: URL {
        directory.appending(path: "asr_checkpoint.json")
    }

    var asrDownloadedResult: URL {
        directory.appending(path: "asr_result.json")
    }

    func sourceAudio(fileExtension: String) -> URL {
        let ext = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        return directory.appending(path: "source.\(ext.isEmpty ? "m4a" : ext)")
    }
}

final class YTSubtitleFileStore {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func files(videoID: String) throws -> YTSubtitleFiles {
        let directory = try subtitleDirectory(videoID: videoID, in: preferredStorageDirectory, create: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try migrateLegacyCacheIfNeeded(videoID: videoID, to: directory)
        return YTSubtitleFiles(
            directory: directory,
            englishVTT: directory.appending(path: "en.vtt"),
            chineseVTT: directory.appending(path: "zh.vtt"),
            segments: directory.appending(path: "segments.json"),
            baseSegments: directory.appending(path: "base_segments.json")
        )
    }

    func translationFiles(videoID: String, target: TranslationTarget) throws -> TranslationVariantFiles {
        let files = try files(videoID: videoID)
        let directory = files.directory
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

    private func subtitleDirectory(
        videoID: String,
        in searchPathDirectory: FileManager.SearchPathDirectory,
        create: Bool
    ) throws -> URL {
        let base = try fileManager.url(
            for: searchPathDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: create
        )
        return base
            .appending(path: "PodcastEnglishStudio")
            .appending(path: "YouTube")
            .appending(path: videoID)
    }

    private var preferredStorageDirectory: FileManager.SearchPathDirectory {
        LocalArtifactStoragePolicy.runtimeDirectory
    }

    private func migrateLegacyCacheIfNeeded(videoID: String, to directory: URL) throws {
        guard preferredStorageDirectory != .cachesDirectory else { return }
        guard let legacyDirectory = try? subtitleDirectory(videoID: videoID, in: .cachesDirectory, create: false),
              fileManager.fileExists(atPath: legacyDirectory.fileSystemPath)
        else {
            return
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for fileName in ["en.vtt", "zh.vtt", "segments.json"] {
            let legacyURL = legacyDirectory.appending(path: fileName)
            let destinationURL = directory.appending(path: fileName)
            guard fileManager.fileExists(atPath: legacyURL.fileSystemPath),
                  !fileManager.fileExists(atPath: destinationURL.fileSystemPath)
            else {
                continue
            }
            try fileManager.copyItem(at: legacyURL, to: destinationURL)
        }
    }

    func hasLocalSubtitles(videoID: String) throws -> Bool {
        let files = try files(videoID: videoID)
        return fileManager.fileExists(atPath: files.englishVTT.fileSystemPath)
            && fileManager.fileExists(atPath: files.chineseVTT.fileSystemPath)
    }

    func deleteAllFiles(videoID: String) throws {
        let directory = try subtitleDirectory(videoID: videoID, in: preferredStorageDirectory, create: false)
        if fileManager.fileExists(atPath: directory.fileSystemPath) {
            try fileManager.removeItem(at: directory)
        }
        if preferredStorageDirectory != .cachesDirectory,
           let legacy = try? subtitleDirectory(videoID: videoID, in: .cachesDirectory, create: false),
           fileManager.fileExists(atPath: legacy.fileSystemPath) {
            try fileManager.removeItem(at: legacy)
        }
    }

    func readVTT(at path: String) throws -> String {
        try String(contentsOf: URL.storedFileURL(from: path), encoding: .utf8)
    }

    func readVTTIfExists(at path: String) -> String? {
        let url = URL.storedFileURL(from: path)
        guard fileManager.fileExists(atPath: url.fileSystemPath) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func readVTTIfExists(at url: URL) -> String? {
        guard fileManager.fileExists(atPath: url.fileSystemPath) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func writeVTT(_ value: String, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try value.write(to: url, atomically: true, encoding: .utf8)
    }

    func writeSegments(_ segments: [LearningSegment], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(segments)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func writeManifest(_ manifest: TranslationArtifactManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func readManifestIfExists(at url: URL) -> TranslationArtifactManifest? {
        guard fileManager.fileExists(atPath: url.fileSystemPath),
              let data = try? Data(contentsOf: url)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TranslationArtifactManifest.self, from: data)
    }

    func migrateLegacySimplifiedChineseIfNeeded(
        videoID: String,
        to destination: TranslationVariantFiles
    ) throws -> Bool {
        let legacy = try files(videoID: videoID)
        let hasLegacySegments = fileManager.fileExists(atPath: legacy.segments.fileSystemPath)
        let hasLegacyTranslationVTT = fileManager.fileExists(atPath: legacy.chineseVTT.fileSystemPath)
        guard hasLegacySegments || hasLegacyTranslationVTT else {
            return false
        }

        try fileManager.createDirectory(at: destination.directory, withIntermediateDirectories: true)
        if hasLegacySegments,
           !fileManager.fileExists(atPath: destination.segments.fileSystemPath) {
            try atomicCopy(from: legacy.segments, to: destination.segments)
        }
        if hasLegacyTranslationVTT,
           !fileManager.fileExists(atPath: destination.targetVTT.fileSystemPath) {
            try atomicCopy(from: legacy.chineseVTT, to: destination.targetVTT)
        }
        if !fileManager.fileExists(atPath: legacy.baseSegments.fileSystemPath),
           let legacySegments = readSegmentsIfExists(at: legacy.segments) {
            let base = legacySegments.map { segment in
                var value = segment
                value.translation = ""
                return value
            }
            try writeSegments(base, to: legacy.baseSegments)
        }
        if !fileManager.fileExists(atPath: legacy.baseSegments.fileSystemPath),
           let englishVTT = readVTTIfExists(at: legacy.englishVTT) {
            try writeSegments(
                YTVTTParser.learningSegments(from: YTVTTParser.parse(englishVTT)),
                to: legacy.baseSegments
            )
        }
        if !fileManager.fileExists(atPath: destination.segments.fileSystemPath),
           let base = readSegmentsIfExists(at: legacy.baseSegments),
           let translatedVTT = readVTTIfExists(at: destination.targetVTT) {
            let migrated = YTVTTParser.applyingTranslations(
                from: YTVTTParser.parse(translatedVTT),
                to: base
            )
            try writeSegments(migrated, to: destination.segments)
        }
        return fileManager.fileExists(atPath: destination.segments.fileSystemPath)
            || fileManager.fileExists(atPath: destination.targetVTT.fileSystemPath)
    }

    private func atomicCopy(from source: URL, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.copyItem(at: source, to: temporary)
        try fileManager.moveItem(at: temporary, to: destination)
    }

    func readSegments(at path: String) throws -> [LearningSegment] {
        let data = try Data(contentsOf: URL.storedFileURL(from: path))
        return try JSONDecoder().decode([LearningSegment].self, from: data)
    }

    func readSegmentsIfExists(at url: URL) -> [LearningSegment]? {
        guard fileManager.fileExists(atPath: url.fileSystemPath),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode([LearningSegment].self, from: data)
    }
}
