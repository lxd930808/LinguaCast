import Foundation

/// 轻量本地化助手：以 `Localizable.xcstrings` 为源，提供带回退的字符串/格式化/复数。
/// 独立成文件以便 PlayerKit / CloudSyncKit 等下层包复用（它们不应反向依赖 app 的配置模型）。
enum L10n {
    static func string(_ key: String, fallback: String) -> String {
        NSLocalizedString(key, bundle: .main, value: fallback, comment: "")
    }

    static func format(_ key: String, fallback: String, _ arguments: CVarArg...) -> String {
        let format = string(key, fallback: fallback)
        return String(format: format, locale: Locale.current, arguments: arguments)
    }

    static func plural(_ key: String, fallback: String, count: Int) -> String {
        let format = string(key, fallback: fallback)
        return String.localizedStringWithFormat(format, Int64(count))
    }
}
