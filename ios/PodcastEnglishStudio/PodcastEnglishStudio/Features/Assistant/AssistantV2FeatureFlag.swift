import Foundation

/// Device-local gate for the V15 workspace research UI.
/// Default is off so the V1 assistant remains the shipping experience.
enum AssistantV2FeatureFlag {
    static let defaultsKey = "assistant.v2WorkspaceEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }
}
