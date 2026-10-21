import Foundation
import Observation

public enum AppLanguage: String, CaseIterable, Sendable {
    case simplifiedChinese = "zh-Hans", english = "en"

    public var locale: Locale { Locale(identifier: rawValue) }
    public var name: String { self == .simplifiedChinese ? "简体中文" : "English" }

    static func preferred(from languages: [String]) -> Self {
        for language in languages {
            switch language.lowercased().split(separator: "-").first?.split(separator: "_").first {
            case "zh": return .simplifiedChinese
            case "en": return .english
            default: continue
            }
        }
        return .english
    }
}

/// Store the meaning of app-generated text, so existing state can follow a language change.
public struct LocalizedText: Codable, Equatable, Sendable {
    public let key: String
    public let arguments: [String]
    public let table: String

    public init(_ key: String, _ arguments: String..., table: String = "Core") {
        self.init(key, arguments: arguments, table: table)
    }

    init(_ key: String, arguments: [String], table: String = "Core") {
        self.key = key; self.arguments = arguments; self.table = table
    }

    static var resources: Bundle {
        LocalizationResources.bundle(named: "SimpleCodexBar_CodexUsageCore.bundle", fallback: { Bundle.module })
    }

    public func resolve(in language: AppLanguage) -> String {
        guard !arguments.isEmpty else {
            return LocalizationResources.string(key, language: language.rawValue, table: table, bundle: Self.resources)
        }
        return LocalizationResources.format(key, language: language.rawValue, table: table, bundle: Self.resources,
                                            arguments: arguments.map { $0 as CVarArg })
    }
}

@MainActor @Observable public final class LanguageController {
    public private(set) var language: AppLanguage
    public static let preferenceKey = "AppLanguage"
    @ObservationIgnored private let defaults: UserDefaults?

    public init(defaults: UserDefaults? = .standard, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.defaults = defaults
        language = defaults?.string(forKey: Self.preferenceKey).flatMap(AppLanguage.init(rawValue:))
            ?? AppLanguage.preferred(from: preferredLanguages)
    }

    public func setLanguage(_ language: AppLanguage) {
        self.language = language
        defaults?.set(language.rawValue, forKey: Self.preferenceKey)
    }

    public func toggle() { setLanguage(language == .simplifiedChinese ? .english : .simplifiedChinese) }

    public func text(_ key: String, _ arguments: String..., table: String = "Core") -> String {
        LocalizedText(key, arguments: arguments, table: table).resolve(in: language)
    }

    public func resolve(_ text: LocalizedText) -> String { text.resolve(in: language) }
}
