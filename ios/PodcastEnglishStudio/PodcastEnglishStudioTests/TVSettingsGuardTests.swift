import XCTest

final class TVSettingsGuardTests: XCTestCase {
    func testTVOSSettingsSourcesDoNotUseForbiddenControls() throws {
        let files = try settingsTVOSSources()
        XCTAssertFalse(files.isEmpty, "Expected Features/Settings/*+tvOS.swift files")
        let forbidden = [
            "\\bPicker\\(",
            "\\bToggle\\(",
            "\\bTextField\\(",
            "\\bSecureField\\(",
            "\\bStepper\\(",
            "\\bDisclosureGroup\\(",
            "Form \\{",
            "LazyVStack",
            "LazyVGrid",
            "LinguaFocusableCardStyle"
        ]
        var violations: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for pattern in forbidden {
                let regex = try NSRegularExpression(pattern: pattern)
                if regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil {
                    violations.append("\(file.lastPathComponent): contains \(pattern)")
                }
            }
        }
        XCTAssertTrue(violations.isEmpty, violations.joined(separator: "\n"))
    }

    func testSubtitlePresentationSettingsSectionIsIOSOnly() throws {
        let file = try settingsDirectory().appendingPathComponent("SubtitlePresentationSettingsSection.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(source.contains("#if os(iOS)"), "SubtitlePresentationSettingsSection must be iOS-only")
        XCTAssertTrue(source.contains("#endif"))
    }

    func testRequiredAccessibilityIdentifiersExistInTVOSSettings() throws {
        let files = try settingsTVOSSources()
        let joined = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        let required = [
            "screen.settings",
            "settings.cloud-enabled",
            "settings.generation-backend",
            "settings.cloud-status",
            "settings.cloud-token",
            "settings.cloud-active-jobs",
            "settings.subtitle.english-size",
            "settings.subtitle.target-scale",
            "settings.subtitle.order"
        ]
        var missing: [String] = []
        for identifier in required where !joined.contains(identifier) {
            missing.append(identifier)
        }
        XCTAssertTrue(missing.isEmpty, "Missing identifiers: \(missing.joined(separator: ", "))")
    }

    private func settingsDirectory() throws -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("PodcastEnglishStudio/Features/Settings")
    }

    private func settingsTVOSSources() throws -> [URL] {
        let directory = try settingsDirectory()
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return files.filter { $0.lastPathComponent.hasSuffix("+tvOS.swift") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
