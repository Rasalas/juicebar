import Foundation

/// German source keys stay stable in persisted records. Formatting never treats user data as a format string.
public enum Localization {
    public static let language: String = {
        if let flag = CommandLine.arguments.first(where: { $0.hasPrefix("--language=") }) { return String(flag.dropFirst(11)) == "de" ? "de" : "en" }
        let selected = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
        if selected == "de" || selected == "en" { return selected }
        return Locale.preferredLanguages.first?.hasPrefix("de") == true ? "de" : "en"
    }()
    public static var locale: Locale { Locale(identifier: language) }
    static let english: [String: String] = {
        guard let url = Bundle.module.url(forResource: "en", withExtension: "json"), let data = try? Data(contentsOf: url),
              let strings = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return strings
    }()
    private static let reverse = english.reduce(into: [String: String]()) { if $0[$1.value] == nil { $0[$1.value] = $1.key } }
    private static let placeholders = try! NSRegularExpression(pattern: #"\{(\d+)\}"#)
    public static func text(_ key: String, arguments: [String] = [], language: String = language) -> String {
        guard !key.isEmpty else { return "" }
        let sourceKey = english[key] != nil ? key : reverse[key] ?? key
        let template = language == "de" ? sourceKey : english[sourceKey] ?? key
        // Scan once so braces in a provider label or error cannot substitute later arguments.
        guard !arguments.isEmpty else { return template }
        var result = template
        for match in placeholders.matches(in: template, range: NSRange(template.startIndex..., in: template)).reversed() {
            guard let numberRange = Range(match.range(at: 1), in: template), let index = Int(template[numberRange]), arguments.indices.contains(index),
                  let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: arguments[index])
        }
        return result
    }
}
public func tr(_ key: String, _ arguments: Any...) -> String {
    Localization.text(key, arguments: arguments.map { String(describing: $0) })
}
