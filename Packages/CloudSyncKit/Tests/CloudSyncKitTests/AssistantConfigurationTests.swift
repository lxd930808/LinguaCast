import Foundation
import XCTest
@testable import CloudSyncKit

final class AssistantConfigurationTests: XCTestCase {
    func testAssistantDefaultsAreOffAndDoNotReuseContentService() {
        var configuration = AppConfiguration()
        XCTAssertFalse(configuration.assistantServiceEnabled)
        XCTAssertFalse(configuration.isAssistantServiceUsable)
        XCTAssertNotEqual(configuration.normalizedAssistantServiceBaseURL, configuration.normalizedContentServiceBaseURL)
        configuration.assistantServiceEnabled = true
        configuration.assistantServiceToken = "assistant-token"
        XCTAssertTrue(configuration.isAssistantServiceUsable)
        XCTAssertTrue(AppConfigurationKey.assistantServiceToken.isSecret)
        XCTAssertFalse(AppConfigurationKey.assistantServiceEnabled.isSecret)
    }
}
