import XCTest

final class LocalizationCatalogTests: XCTestCase {
    private let supportedLanguages = Set([
        "en", "zh-Hans", "zh-Hant", "es", "pt-BR", "ja", "ko", "fr", "de", "ar"
    ])

    func testStringCatalogsHaveCompleteNonemptyTranslationsAndMatchingPlaceholders() throws {
        for name in ["Localizable", "InfoPlist"] {
            let root = try catalogRoot(named: name)
            XCTAssertEqual(root["sourceLanguage"] as? String, "en", "\(name) must use English as its source language")
            let strings = try XCTUnwrap(root["strings"] as? [String: Any])
            XCTAssertFalse(strings.isEmpty, "\(name).xcstrings must not be empty")

            for (key, rawEntry) in strings {
                guard let entry = rawEntry as? [String: Any],
                      let localizations = entry["localizations"] as? [String: Any]
                else {
                    XCTFail("\(name): \(key) has no localizations")
                    continue
                }
                XCTAssertEqual(Set(localizations.keys), supportedLanguages, "\(name): \(key)")

                let values = try localizations.mapValues { rawLocalization -> [String: String] in
                    guard let localization = rawLocalization as? [String: Any] else {
                        throw CatalogError.invalidValue(catalog: name, key: key)
                    }
                    return try leafValues(in: localization, catalog: name, key: key)
                }
                let englishValues = try XCTUnwrap(values["en"])
                let englishExemplar = try XCTUnwrap(
                    englishValues.first(where: { $0.key.hasSuffix(".plural.other") })?.value
                        ?? englishValues.values.first
                )
                for (language, localizedValues) in values {
                    for (variation, value) in localizedValues {
                        XCTAssertEqual(
                            placeholders(in: value),
                            placeholders(in: englishExemplar),
                            "\(name): \(key) [\(language)] [\(variation)]"
                        )
                    }
                }
            }
        }

        let localizable = try catalogStrings(named: "Localizable")
        for key in ["episode.sentence_count", "youtube.video_count", "settings.missing_configuration_count"] {
            let entry = try XCTUnwrap(localizable[key] as? [String: Any])
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            for language in supportedLanguages {
                let localization = try XCTUnwrap(localizations[language] as? [String: Any])
                XCTAssertNotNil(localization["variations"], "\(key) [\(language)] must define plural variations")
            }
        }
    }

    func testViewsContainNoHardcodedUserFacingStringsAndAllSemanticKeysExist() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceRoot = testsDirectory.deletingLastPathComponent().appendingPathComponent("PodcastEnglishStudio")
        // UI 现按功能归入 Features/（原 Views/ 已 Feature 化）；连同 Services/ 一并扫描，
        // 递归收集其中的 .swift 文件。
        let files = try ["Features", "Services"].flatMap { directory -> [URL] in
            let root = sourceRoot.appendingPathComponent(directory)
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil
            ) else { return [] }
            return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        }
        let cjk = try NSRegularExpression(pattern: #""(?:\\.|[^"\\])*[ぁ-ヿ㐀-鿿가-힣](?:\\.|[^"\\])*""#)
        let directUIString = try NSRegularExpression(
            pattern: #"(?:Text|Label|Button|Picker|Section|TextField|SecureField|Toggle|Link)\(\s*"((?:\\.|[^"\\])*)"|\.(?:navigationTitle|alert|accessibilityLabel|accessibilityHint|confirmationDialog)\(\s*"((?:\\.|[^"\\])*)""#
        )
        let semanticKey = try NSRegularExpression(
            pattern: #"L10n\.(?:string|format|plural)\(\s*"([^"]+)""#
        )
        let permittedLiteral = try NSRegularExpression(
            pattern: #"^(?:|\\\(.*\)|(?:0\.75|1|1\.25)x)$"#
        )
        let catalogKeys = Set(try catalogStrings(named: "Localizable").keys)
        var violations: [String] = []
        var missingKeys: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for match in cjk.matches(in: source, range: range) {
                guard let matchRange = Range(match.range, in: source) else { continue }
                let line = source[..<matchRange.lowerBound].reduce(into: 1) { if $1 == "\n" { $0 += 1 } }
                let sourceLine = source.split(separator: "\n", omittingEmptySubsequences: false)[line - 1]
                if file.lastPathComponent == "LocalSetupServer.swift", sourceLine.contains("(\"Apple TV") {
                    continue
                }
                if file.lastPathComponent == "YTCaptionService.swift", sourceLine.contains(".contains(\"中文\")") {
                    continue
                }
                violations.append("\(file.lastPathComponent):\(line): \(source[matchRange])")
            }
            for match in directUIString.matches(in: source, range: range) {
                let capture = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
                guard let captureRange = Range(capture, in: source) else { continue }
                let literal = String(source[captureRange])
                let literalRange = NSRange(literal.startIndex..., in: literal)
                if permittedLiteral.firstMatch(in: literal, range: literalRange) != nil { continue }
                let matchRange = Range(match.range, in: source)!
                let line = source[..<matchRange.lowerBound].reduce(into: 1) { if $1 == "\n" { $0 += 1 } }
                violations.append("\(file.lastPathComponent):\(line): \(literal)")
            }
            for match in semanticKey.matches(in: source, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
                let key = String(source[keyRange])
                if !catalogKeys.contains(key) {
                    missingKeys.append("\(file.lastPathComponent): \(key)")
                }
            }
        }
        XCTAssertTrue(violations.isEmpty, violations.joined(separator: "\n"))
        XCTAssertTrue(missingKeys.isEmpty, missingKeys.joined(separator: "\n"))
    }

    func testSemanticKeyFallbacksMatchEnglishCatalog() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceRoot = testsDirectory.deletingLastPathComponent().appendingPathComponent("PodcastEnglishStudio")
        let catalog = try catalogStrings(named: "Localizable")
        let call = try NSRegularExpression(
            pattern: #"L10n\.(?:string|format|plural)\(\s*"([^"]+)"\s*,\s*fallback:\s*"((?:\\.|[^"\\])*)""#
        )
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: nil
        ))
        var mismatches: [String] = []
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for match in call.matches(in: source, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: source),
                      let fallbackRange = Range(match.range(at: 2), in: source)
                else { continue }
                let key = String(source[keyRange])
                let fallback = String(source[fallbackRange])
                    .replacingOccurrences(of: #"\n"#, with: "\n")
                    .replacingOccurrences(of: #"\""#, with: "\"")
                guard let entry = catalog[key] as? [String: Any],
                      let localizations = entry["localizations"] as? [String: Any],
                      let english = localizations["en"] as? [String: Any],
                      let englishValue = try? leafValues(in: english, catalog: "Localizable", key: key)
                        .first(where: { $0.key.hasSuffix(".plural.other") })?.value
                        ?? leafValues(in: english, catalog: "Localizable", key: key).values.first
                else { continue }
                if englishValue != fallback {
                    mismatches.append("\(file.lastPathComponent): \(key) catalog=\(englishValue) fallback=\(fallback)")
                }
            }
        }
        XCTAssertTrue(mismatches.isEmpty, mismatches.joined(separator: "\n"))
    }

    private func catalogRoot(named name: String) throws -> [String: Any] {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let catalogURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("PodcastEnglishStudio/Support/\(name).xcstrings")
        let data = try Data(contentsOf: catalogURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func catalogStrings(named name: String) throws -> [String: Any] {
        let root = try catalogRoot(named: name)
        return try XCTUnwrap(root["strings"] as? [String: Any])
    }

    private func placeholders(in value: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: #"%(?:\d+\$)?(?:[-+0 #]*\d*(?:\.\d+)?)?(?:hh|h|ll|l|q|z|t|j)?[@dDuUxXfFeEgGcCsSpaA]"#)
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).map {
            String(value[Range($0.range, in: value)!])
        }.sorted()
    }

    private func leafValues(
        in object: [String: Any],
        catalog: String,
        key: String,
        path: String = "value"
    ) throws -> [String: String] {
        if let unit = object["stringUnit"] as? [String: Any],
           let value = unit["value"] as? String,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [path: value]
        }
        var result: [String: String] = [:]
        for containerName in ["variations", "substitutions"] {
            guard let container = object[containerName] as? [String: Any] else { continue }
            for (axis, rawAxis) in container {
                guard let axisValues = rawAxis as? [String: Any] else { continue }
                for (variant, rawVariant) in axisValues {
                    guard let variantObject = rawVariant as? [String: Any] else { continue }
                    result.merge(
                        try leafValues(
                            in: variantObject,
                            catalog: catalog,
                            key: key,
                            path: "\(path).\(containerName).\(axis).\(variant)"
                        )
                    ) { _, new in new }
                }
            }
        }
        guard !result.isEmpty else { throw CatalogError.invalidValue(catalog: catalog, key: key) }
        return result
    }

    private enum CatalogError: Error {
        case invalidValue(catalog: String, key: String)
    }
}
