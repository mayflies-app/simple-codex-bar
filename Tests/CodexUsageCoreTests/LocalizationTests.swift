import Foundation
import Testing
@testable import CodexUsageCore

@Test @MainActor func languageFollowsSupportedSystemPreferenceAndFallsBackToEnglish() {
    #expect(LanguageController(defaults: nil, preferredLanguages: ["fr-FR", "zh-TW", "en"]).language == .simplifiedChinese)
    #expect(LanguageController(defaults: nil, preferredLanguages: ["en-US", "zh-CN"]).language == .english)
    #expect(LanguageController(defaults: nil, preferredLanguages: ["ja-JP"]).language == .english)
    #expect(LanguageController(defaults: nil, preferredLanguages: []).language == .english)
}

@Test @MainActor func languagePreferencePersistsAndInvalidStorageUsesSystemPreference() throws {
    let suite = "LocalizationTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("invalid", forKey: LanguageController.preferenceKey)
    let controller = LanguageController(defaults: defaults, preferredLanguages: ["zh-Hans"])
    #expect(controller.language == .simplifiedChinese)
    controller.toggle()
    #expect(defaults.string(forKey: LanguageController.preferenceKey) == "en")
    #expect(LanguageController(defaults: defaults, preferredLanguages: ["zh"]).language == .english)
    controller.setLanguage(.simplifiedChinese)
    #expect(defaults.string(forKey: LanguageController.preferenceKey) == "zh-Hans")
}

@Test @MainActor func ephemeralLanguageControllersRemainIndependent() {
    let first = LanguageController(defaults: nil, preferredLanguages: ["zh-CN"])
    let second = LanguageController(defaults: nil, preferredLanguages: ["en-US"])
    first.toggle()
    #expect(first.language == .english && second.language == .english)
    second.toggle()
    #expect(first.language == .english && second.language == .simplifiedChinese)
}

@Test @MainActor func explicitLanguageResolvesParametersAndExistingErrors() {
    let language = LanguageController(defaults: nil, preferredLanguages: ["zh-CN"])
    let message = UsageError.http(503).message
    #expect(language.resolve(message) == "接口服务返回 HTTP 503，请稍后刷新。")
    language.setLanguage(.english)
    #expect(language.resolve(message) == "The service returned HTTP 503. Refresh again later.")
    #expect(language.text("window.named.hours", "Research model", "8") == "Research model · 8 hours")
    #expect(LocalizedText("unknown.key").resolve(in: .english) == "unknown.key")
    #expect(RefreshInterval.fiveMinutes.title(in: .english) == "5 minutes")
    #expect(RefreshInterval.oneMinute.title(in: .english) == "1 minute")
    #expect(MacActivityState.locked.title(in: .english) == "Locked")
}

@Test func literalPresentationTextIsPreservedWithoutInterpretation() throws {
    let window = UsageWindow(id: "custom", title: "研究 · Model X · 8 小时", usedPercent: 10, resetsAt: nil)
    let snapshot = UsageSnapshot(plan: "pro", windows: [window], notice: "月额度查询失败；其它额度已更新。")
    let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(snapshot))
    #expect(decoded.windows[0].titleMessage == nil && decoded.noticeMessage == nil)
    for language in AppLanguage.allCases {
        #expect(decoded.windows[0].displayTitle(in: language) == window.title)
        #expect(decoded.displayNotice(in: language) == snapshot.notice)
    }
}

@Test func semanticSnapshotRoundTripKeepsLocalizationAndAccountNames() throws {
    let window = UsageWindow(id: "monthly", title: "每月额度", usedPercent: 50, resetsAt: nil,
                             titleMessage: LocalizedText("window.monthly"))
    let snapshot = UsageSnapshot(plan: "team", windows: [window], notice: "月额度暂不可用；未将缺失用量视为 0%。",
                                 noticeMessage: LocalizedText("notice.monthlyUnavailable"))
    let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(snapshot))
    #expect(decoded == snapshot)
    #expect(decoded.windows[0].displayTitle(in: .english) == "Monthly quota")
    #expect(decoded.displayNotice(in: .english) == "Monthly quota is unavailable; missing usage is not treated as 0%.")
    let identity = AccountIdentity(accountID: "account", userID: "user", email: nil)
    #expect(Account(label: "", identity: identity, source: .managed).displayName(in: .english) == "Codex account")
    #expect(Account(label: "我的 Codex 账号", identity: identity, source: .managed).displayName(in: .english) == "我的 Codex 账号")
    let emailIdentity = AccountIdentity(accountID: "account", userID: "user", email: "user@example.com")
    #expect(Account(label: "", identity: emailIdentity, source: .managed).displayName(in: .simplifiedChinese) == "user@example.com")
}

@Test func everyCoreStateHasBothTranslations() {
    let errors: [UsageError] = [.invalidCredentials, .apiKeyUnsupported, .identityChanged, .duplicateAccount,
                               .reauthenticationRequired, .invalidResponse, .invalidRefreshResponse, .network,
                               .http(429), .accountRemoved, .credentialsChanged, .storage, .alreadyRunning,
                               .loginFailed, .loginTimedOut]
    for language in AppLanguage.allCases {
        for error in errors {
            #expect(error.message.resolve(in: language) != error.message.key)
        }
        for key in ["window.session", "window.weekly", "window.monthly", "window.primary", "window.secondary",
                    "notice.monthlyUnavailable", "notice.monthlyFailed", "storage.cache", "loginItem.error"] {
            #expect(LocalizedText(key).resolve(in: language) != key)
        }
    }
}

@Test func decodedDurationsUseEnglishSingularAndRetainUnknownModelNames() throws {
    for (duration, expected) in [(60, "1 minute"), (3600, "1 hour"), (86400, "1 day")] {
        let window: [String: Any] = ["used_percent": 12, "limit_window_seconds": duration]
        let payload: [String: Any] = [
            "rate_limit": ["primary_window": window],
            "additional_rate_limits": [["limit_name": "研究 · Model X", "rate_limit": ["primary_window": window]]],
        ]
        let snapshot = try UsageSnapshot.decode(JSONSerialization.data(withJSONObject: payload), expectedAccountID: "account")
        #expect(snapshot.windows[0].displayTitle(in: .english) == expected)
        #expect(snapshot.windows[1].displayTitle(in: .english) == "研究 · Model X · \(expected)")
        #expect(snapshot.windows.allSatisfy { $0.titleMessage != nil })
    }
}

@Test func languageChoicesAlwaysUseTheirOwnLanguageNames() {
    #expect(AppLanguage.simplifiedChinese.name == "简体中文")
    #expect(AppLanguage.english.name == "English")
    for language in AppLanguage.allCases {
        #expect(LocalizedText("panel.language.chinese", table: "Panel").resolve(in: language) == "简体中文")
        #expect(LocalizedText("panel.language.english", table: "Panel").resolve(in: language) == "English")
    }
}

@Test func runtimeResourceCatalogsHaveMatchingKeysAndFormatArguments() throws {
    let resources = LocalizedText.resources
    let formatArguments = try NSRegularExpression(pattern: #"%(?:[0-9]+\$)?[@dfsu]"#)
    for table in ["Core", "Panel", "Dialogs"] {
        let english = LocalizationResources.catalog(language: "en", table: table, bundle: resources)
        let chinese = LocalizationResources.catalog(language: "zh-Hans", table: table, bundle: resources)
        #expect(!english.isEmpty)
        #expect(english.keys.sorted() == chinese.keys.sorted())
        for key in english.keys {
            let englishText = try #require(english[key])
            let chineseText = try #require(chinese[key])
            #expect(!englishText.isEmpty && !chineseText.isEmpty)
            let parameters = [englishText, chineseText].map { value in
                formatArguments.matches(in: value, range: NSRange(value.startIndex..., in: value)).map {
                    (value as NSString).substring(with: $0.range)
                }
            }
            #expect(parameters[0] == parameters[1])
            #expect(LocalizedText(key, table: table).resolve(in: .english) == englishText)
            #expect(LocalizedText(key, table: table).resolve(in: .simplifiedChinese) == chineseText)
        }
    }
}

@Test func explicitLanguageLookupFallsBackWithoutContaminatingCatalogs() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    for language in ["en", "zh-hans"] {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("\(language).lproj"),
                                               withIntermediateDirectories: true)
    }
    let info: [String: Any] = ["CFBundleIdentifier": "LocalizationFixture.\(UUID().uuidString)",
                             "CFBundleDevelopmentRegion": "en", "CFBundleLocalizations": ["en", "zh-hans"]]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: directory.appendingPathComponent("Info.plist"))
    let english = ["englishOnly": "English fallback", "shared": "English", "greeting": "Hello %@",
                   "literalPercent": "50% complete", "escapedPercent": "100%%"]
    let chinese = ["shared": "中文", "greeting": "你好 %@"]
    for (language, catalog) in [("en", english), ("zh-hans", chinese)] {
        try PropertyListSerialization.data(fromPropertyList: catalog, format: .xml, options: 0)
            .write(to: directory.appendingPathComponent("\(language).lproj/Panel.strings"))
    }
    let resources = try #require(Bundle(url: directory))
    #expect(LocalizationResources.catalog(language: "zh-Hans", table: "Panel", bundle: resources) == chinese)
    #expect(LocalizationResources.string("shared", language: "ZH-HANS", table: "Panel", bundle: resources) == "中文")
    #expect(LocalizationResources.string("englishOnly", language: "zh-Hans", table: "Panel", bundle: resources) == "English fallback")
    #expect(LocalizationResources.string("shared", language: "fr", table: "Panel", bundle: resources) == "English")
    #expect(LocalizationResources.string("unknown", language: "zh-Hans", table: "Panel", bundle: resources) == "unknown")
    #expect(LocalizationResources.format("greeting", language: "zh-Hans", table: "Panel", bundle: resources,
                                         arguments: ["Research model"]) == "你好 Research model")
    #expect(LocalizationResources.format("literalPercent", language: "en", table: "Panel", bundle: resources,
                                         arguments: []) == "50% complete")
    #expect(LocalizationResources.format("escapedPercent", language: "en", table: "Panel", bundle: resources,
                                         arguments: []) == "100%%")
}

@Test func embeddedResourcesAvoidEvaluatingModuleFallback() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let applicationURL = directory.appendingPathComponent("LocalizationFixture.app", isDirectory: true)
    let resourcesURL = applicationURL.appendingPathComponent("Contents/Resources/SimpleCodexBar_CodexUsageCore.bundle", isDirectory: true)
    try FileManager.default.createDirectory(at: resourcesURL.appendingPathComponent("en.lproj"),
                                           withIntermediateDirectories: true)
    let applicationInfo = ["CFBundleIdentifier": "LocalizationApplication.\(UUID().uuidString)",
                           "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: applicationInfo, format: .xml, options: 0)
        .write(to: applicationURL.appendingPathComponent("Contents/Info.plist"))
    let resourcesInfo = ["CFBundleIdentifier": "LocalizationResources.\(UUID().uuidString)",
                         "CFBundleDevelopmentRegion": "en", "CFBundlePackageType": "BNDL"]
    try PropertyListSerialization.data(fromPropertyList: resourcesInfo, format: .xml, options: 0)
        .write(to: resourcesURL.appendingPathComponent("Info.plist"))
    try PropertyListSerialization.data(fromPropertyList: ["value": "Embedded resources"], format: .xml, options: 0)
        .write(to: resourcesURL.appendingPathComponent("en.lproj/Panel.strings"))
    let application = try #require(Bundle(url: applicationURL))
    var fallbackCalls = 0
    let embedded = LocalizationResources.bundle(named: "SimpleCodexBar_CodexUsageCore.bundle", application: application) {
        fallbackCalls += 1
        return application
    }
    #expect(fallbackCalls == 0)
    #expect(embedded.bundleURL == resourcesURL)
    #expect(LocalizationResources.string("value", language: "en", table: "Panel", bundle: embedded) == "Embedded resources")
    let missing = LocalizationResources.bundle(named: "Missing.bundle", application: application) {
        fallbackCalls += 1
        return application
    }
    #expect(fallbackCalls == 1)
    #expect(missing.bundleURL == applicationURL)
}
