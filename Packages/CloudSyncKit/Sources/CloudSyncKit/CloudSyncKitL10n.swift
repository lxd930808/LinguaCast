import Foundation

// 与 app 层 LocalFileStore.swift 中 URL 扩展相同的包内私有副本，
// 避免反向依赖 app 层扩展（PlayerKit 已采用同法）。
extension URL {
    var fileSystemPath: String {
        path(percentEncoded: false)
    }

    static func storedFileURL(from value: String) -> URL {
        URL(filePath: value.removingPercentEncoding ?? value)
    }
}

/// CloudSyncKit 内最小本地化回调：与 app 层 L10n 行为一致，
/// 以 `Localizable.xcstrings`（app 主 bundle）为源，提供带回退的字符串/格式化。
/// 包内独立定义，避免反向依赖 app 层的 L10n（参照 PlayerKitL10n）。
enum CloudSyncKitL10n {
    static func string(_ key: String, fallback: String) -> String {
        NSLocalizedString(key, bundle: .main, value: fallback, comment: "")
    }

    static func format(_ key: String, fallback: String, _ arguments: CVarArg...) -> String {
        let format = string(key, fallback: fallback)
        return String(format: format, locale: Locale.current, arguments: arguments)
    }
}
