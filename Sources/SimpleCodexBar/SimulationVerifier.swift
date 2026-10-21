import AppKit
import Foundation
import CodexUsageCore

@MainActor
enum NativeCapture {
    static func write(_ view: NSView, to file: URL) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CheckFailure("无法截图") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CheckFailure("无法编码截图") }
        try data.write(to: file)
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Drives the real AppKit status item and SwiftUI accessibility controls, using only isolated fixtures.
@MainActor
enum SimulationVerifier {
    /// A focused native flow for language changes, including already-visible errors and dialogs.
    static func runLocalization(session: SimulationSession, language: LanguageController,
                                refresh: RefreshController, item: NSStatusItem, panel: NSPanel,
                                view: NSView, dialogs: DialogPresenter,
                                loginItem: LoginItemController, dates: DateDisplayController,
                                output: URL) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await waitUntil { session.store.rows.count == 2 && !session.store.isRefreshing
            && session.store.rows.allSatisfy { $0.snapshot != nil } }
        guard let button = item.button, let surface = panel.contentView else {
            throw CheckFailure("Localization panel is unavailable")
        }
        var checks: [String] = []
        func check(_ condition: Bool, _ description: String) throws {
            guard condition else { throw CheckFailure(description) }
            checks.append(description)
        }
        func text(_ identifier: String, in root: NSView) -> String {
            guard let element = find(identifier, in: root, depth: 0) else { return "" }
            return (value("accessibilityValue", of: element) as? String)
                ?? (value("accessibilityLabel", of: element) as? String) ?? ""
        }
        func containsChinese(_ text: String) -> Bool {
            // Match ideographs, not punctuation with a shared Han script extension.
            text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        }
        func inputValue(in root: NSView) -> String? {
            if let input = root as? NSTextField, input.isEditable { return input.stringValue }
            return root.subviews.lazy.compactMap { inputValue(in: $0) }.first
        }

        guard let shortVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !shortVersion.isEmpty else {
            throw CheckFailure("Packaged app has no version metadata")
        }
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let version = build.flatMap { $0.isEmpty ? nil : "\(shortVersion) (\($0))" } ?? shortVersion

        language.setLanguage(.simplifiedChinese)
        button.performClick(nil)
        try await waitUntil { panel.isVisible && containsChinese(text("panel-title", in: surface)) }
        try check(button.toolTip == "Codex 用量 · 查看账号额度"
                  && button.accessibilityLabel() == "Codex 多账号用量",
                  "Status-item tooltip and accessibility label start in Chinese")
        try check(text("app.version", in: surface) == "版本 " + version,
                  "Footer version matches the packaged app metadata in Chinese")
        let initialLogin = loginItem.enabled
        try check(try settingState("launch-at-login", in: surface) == initialLogin,
                  "Launch-at-login menu checkmark reflects the simulated service")
        try press("launch-at-login", in: surface)
        try await waitUntil { loginItem.enabled != initialLogin }
        try check(try settingState("launch-at-login", in: surface) == loginItem.enabled,
                  "Launch-at-login action updates its native menu checkmark")
        try press("launch-at-login", in: surface)
        try await waitUntil { loginItem.enabled == initialLogin }
        try check(try settingState("launch-at-login", in: surface) == initialLogin,
                  "Launch-at-login menu action can restore the initial state without changing real login items")

        try press("automatic-refresh", in: surface)
        try await waitUntil { !refresh.automaticRefreshEnabled }
        try check(try !settingState("automatic-refresh", in: surface), "Smart refresh menu checkmark clears when disabled")
        let readingsWhileDisabled = session.store.rows.map(\.snapshot)
        try selectInterval("15 分钟", in: surface)
        try await waitUntil { refresh.refreshInterval == .fifteenMinutes }
        try check(try pickerState("refresh-interval", title: "15 分钟", in: surface),
                  "Refresh interval submenu checks the selected option")
        try check(session.store.rows.map(\.snapshot) == readingsWhileDisabled && !session.store.isRefreshing,
                  "Changing interval while smart refresh is disabled does not fetch usage")
        try press("automatic-refresh", in: surface)
        try await waitUntil { refresh.automaticRefreshEnabled && !session.store.isRefreshing
            && session.store.rows[0].snapshot != readingsWhileDisabled[0] }
        try check(refresh.refreshInterval == .fifteenMinutes && (try settingState("automatic-refresh", in: surface)),
                  "Enabling smart refresh retains the selected interval and restores its checkmark")
        try press("automatic-refresh", in: surface)
        try await waitUntil { !refresh.automaticRefreshEnabled }

        let initialDates = dates.absolute
        try check(try settingState("absolute-dates", in: surface) == initialDates,
                  "Full-date menu checkmark reflects the current display format")
        try press("absolute-dates", in: surface)
        try await waitUntil { dates.absolute != initialDates }
        try check(try settingState("absolute-dates", in: surface) == dates.absolute,
                  "Full-date menu action updates its checkmark")
        let resetID = "reset-\(session.store.rows[0].id)-codex-session"
        try check(text(resetID, in: surface).contains("重置于") == dates.absolute,
                  "Full-date menu action changes the existing reset label")
        try press("absolute-dates", in: surface)
        try await waitUntil { dates.absolute == initialDates }
        try check(try pickerState("language-select", title: "简体中文", in: surface),
                  "Language submenu initially checks Simplified Chinese")
        try writeSettingsHierarchy(in: surface, to: output.appendingPathComponent("chinese-settings-menu.json"))
        try check(panel.isVisible, "Settings toggles, interval selection and menu dismissal keep the status panel open")
        let personal = session.store.rows[0].account
        let work = session.store.rows[1].account
        let originalAccounts = session.store.rows.map(\.account)
        let originalReadings = session.store.rows.map(\.snapshot)
        let originalCredentials = try await session.repository.readCredentials(personal).data
        let originalAccountsFile = try Data(contentsOf: session.repository.root.appendingPathComponent("accounts.json"))
        let originalCache = try Data(contentsOf: session.repository.root.appendingPathComponent("usage-cache.json"))

        // This is an existing failure: changing the language must not retry or discard its last reading.
        await session.failNextRefresh()
        await session.store.waitForRefreshes()
        scrollToBottom(surface)
        try await waitUntil { text("error-\(work.id)", in: surface).contains("503") }
        try check(containsChinese(text("error-\(work.id)", in: surface)), "Existing error is initially Chinese")
        let beforeSwitch = session.store.rows.map(\.snapshot)
        try NativeCapture.write(surface, to: output.appendingPathComponent("chinese-panel.png"))

        try selectLanguage(.english, in: surface)
        try await waitUntil {
            language.language == .english && !containsChinese(text("panel-title", in: surface))
                && text("mac-activity", in: surface).contains("Manual refresh")
                && !containsChinese(text("error-\(work.id)", in: surface))
                && !containsChinese(text("window-title-\(work.id)-codex-weekly", in: surface))
        }
        try check(text("app.version", in: surface) == "Version " + version,
                  "Footer version updates immediately to English without changing bundle metadata")
        try await waitUntil { button.toolTip == "Simple Codex Bar · View account usage"
            && button.accessibilityLabel() == "Codex usage for multiple accounts" }
        try check(button.toolTip == "Simple Codex Bar · View account usage"
                  && button.accessibilityLabel() == "Codex usage for multiple accounts",
                  "Status-item tooltip and accessibility label update immediately to English")
        try check(try pickerState("language-select", title: "简体中文", in: surface) == false,
                  "Chinese language choice keeps its own name in the English menu")
        let errorText = text("error-\(work.id)", in: surface)
        try check(try pickerState("language-select", title: "English", in: surface),
                  "Language submenu checks English after the native menu selection")
        try check(try pickerState("refresh-interval", title: "15 minutes", in: surface),
                  "Refresh interval selection survives translation of the native settings menu")
        try writeSettingsHierarchy(in: surface, to: output.appendingPathComponent("english-settings-menu.json"))
        try check(panel.isVisible, "Selecting a language in the native settings menu keeps the status panel open")
        try NativeCapture.write(surface, to: output.appendingPathComponent("english-panel.png"))
        try check(errorText.contains("503") && !containsChinese(errorText), "Existing HTTP failure changes to English without another request")
        try check(text("refresh-all", in: surface).lowercased().contains("refresh"), "Refresh accessibility label is English")
        let activityText = text("mac-activity", in: surface)
        try check(!containsChinese(activityText), "Activity and manual-refresh status change to English: \(activityText)")
        let weekly = text("window-title-\(work.id)-codex-weekly", in: surface)
        try check(!weekly.isEmpty && !containsChinese(weekly), "Existing usage window title changes to English")
        try check(session.store.rows.map(\.account) == originalAccounts
                  && session.store.rows.map(\.snapshot) == beforeSwitch
                  && !session.store.isRefreshing && !refresh.automaticRefreshEnabled,
                  "Language action preserves account data, readings and refresh settings")
        try check(try await session.repository.readCredentials(personal).data == originalCredentials,
                  "Language action does not alter credentials")
        try check(try Data(contentsOf: session.repository.root.appendingPathComponent("accounts.json")) == originalAccountsFile
                  && Data(contentsOf: session.repository.root.appendingPathComponent("usage-cache.json")) == originalCache,
                  "Language action does not rewrite accounts or cached usage")
        try check(originalReadings == beforeSwitch, "Partial failure retains previous successful readings")
        try NativeCapture.write(surface, to: output.appendingPathComponent("english-panel.png"))

        let reloaded = AccountStore(repository: session.repository, fetcher: NoNetworkFetcher())
        await reloaded.load()
        try check(reloaded.rows.allSatisfy { $0.restoredFromCache }
                  && reloaded.rows.flatMap { $0.snapshot?.windows ?? [] }.allSatisfy { !containsChinese($0.displayTitle(in: .english)) },
                  "Persisted readings restore with English window titles")
        if let suite = ProcessInfo.processInfo.environment["MACOS_LOCALIZATION_TEST_SUITE"],
           let defaults = UserDefaults(suiteName: suite) {
            try check(defaults.string(forKey: LanguageController.preferenceKey) == "en",
                      "Visible language change persists immediately in the isolated preference suite")
            try check(defaults.synchronize(), "Isolated preference writes are synchronized before failure injection")
            try check(LanguageController(defaults: defaults, preferredLanguages: ["zh-Hans"]).language == .english,
                      "A new controller reads English from the isolated preference suite")
        }
        let environment = ProcessInfo.processInfo.environment
        let mode = environment["MACOS_LOCALIZATION_TEST_MODE"] ?? "normal"
        guard ["normal", "fail", "hold"].contains(mode) else {
            throw CheckFailure("Unknown localization test mode: \(mode)")
        }
        let progressURL = output.appendingPathComponent("localization-progress.json").standardizedFileURL.resolvingSymlinksInPath()
        if let supplied = environment["MACOS_LOCALIZATION_TEST_PROGRESS"] {
            guard URL(fileURLWithPath: supplied).standardizedFileURL.resolvingSymlinksInPath() == progressURL else {
                throw CheckFailure("Localization progress path must belong to the test output")
            }
        }
        let progress: [String: Any] = ["stage": "english-visible", "language": language.language.rawValue,
                                      "pid": getpid(), "mode": mode]
        try JSONSerialization.data(withJSONObject: progress, options: [.prettyPrinted, .sortedKeys])
            .write(to: progressURL, options: .atomic)
        if mode == "fail" { throw CheckFailure("Controlled failure after the visible English language change") }
        if mode == "hold" {
            while true { try await Task.sleep(for: .milliseconds(100)) }
        }
        button.performClick(nil)
        try await waitUntil { !panel.isVisible }

        dialogs.rename(personal) { _ in }
        guard let renameWindow = dialogs.window, let renameView = renameWindow.contentView else {
            throw CheckFailure("Rename dialog is unavailable")
        }
        try await waitUntil { renameWindow.firstResponder is NSTextView }
        let unfinishedName = "个人 / Work — unsaved"
        try setName(unfinishedName, in: renameView)
        try check(!containsChinese(renameWindow.title), "Rename window title starts in English")
        try selectLanguage(.simplifiedChinese, in: view)
        try await waitUntil { language.language == .simplifiedChinese && containsChinese(renameWindow.title) }
        try check(dialogs.window === renameWindow, "Language change retains the existing rename window")
        try check(inputValue(in: renameView) == unfinishedName && renameWindow.firstResponder is NSTextView,
                  "Live dialog translation preserves unfinished input and keyboard focus")
        try check(containsChinese(text("dialog-title", in: renameView)), "Open rename content changes to Chinese")
        try NativeCapture.write(renameView, to: output.appendingPathComponent("rename-live-switch.png"))
        try press("dialog-cancel", in: renameView)
        try check(session.store.rows[0].account == personal, "Cancel after switching languages leaves account name unchanged")

        dialogs.message(title: LocalizedText("dialog.operationIncomplete", table: "Dialogs"), detail: UsageError.identityChanged.message)
        guard let errorWindow = dialogs.window, let errorView = errorWindow.contentView else {
            throw CheckFailure("Error dialog is unavailable")
        }
        try selectLanguage(.english, in: view)
        try await waitUntil { language.language == .english && !containsChinese(errorWindow.title) }
        try check(dialogs.window === errorWindow, "Language change retains the existing error window")
        let detail = text("dialog-detail", in: errorView)
        try check(!detail.isEmpty && !containsChinese(detail), "Open error detail and native window title change to English")
        errorView.layoutSubtreeIfNeeded()
        try check(errorView.fittingSize.height <= errorView.bounds.height + 1,
                  "Long English error fits the open dialog after switching languages")
        try NativeCapture.write(errorView, to: output.appendingPathComponent("english-error-dialog.png"))
        try press("dialog-confirm", in: errorView)
        dialogs.confirmRemoval(work) { }
        guard let removal = dialogs.window?.contentView else { throw CheckFailure("Removal dialog is unavailable") }
        try check(!containsChinese(text("dialog-detail", in: removal)), "Read-only removal explanation is English")
        try selectLanguage(.simplifiedChinese, in: view)
        try await waitUntil { language.language == .simplifiedChinese && containsChinese(text("dialog-detail", in: removal)) }
        try press("dialog-cancel", in: removal)
        try check(session.store.rows.count == 2, "Switching language in removal confirmation never removes an account")

        let report: [String: Any] = ["passed": true, "checks": checks,
                                  "realAccountsAccessed": false, "realNetworkUsed": false,
                                  "fixtureDirectory": session.root.path,
                                  "languagePreference": language.language.rawValue,
                                  "timestamp": ISO8601DateFormatter().string(from: Date())]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("localization-flow.json"))
    }

    static func runAppearance(session: SimulationSession, panel: NSPanel, item: NSStatusItem, output: URL) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await waitUntil { session.store.rows.count == 2 && !session.store.isRefreshing && session.store.rows.allSatisfy { $0.snapshot != nil } }
        guard let button = item.button else { throw CheckFailure("菜单栏按钮缺失") }
        for _ in 0..<5 {
            try postStatusClick(button)
            try await waitUntil { panel.isVisible }
            try postStatusClick(button)
            try await waitUntil { !panel.isVisible }
        }
        button.performClick(nil)
        try await waitUntil { panel.isVisible }
        guard let delegate = NSApp.delegate as? AppDelegate, let statusWindow = button.window else {
            throw CheckFailure("菜单栏事件处理器缺失")
        }
        let slot = statusWindow.frame
        let buttonRect = statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let paddingPoints: [(String, NSPoint)] = [
            ("左侧留白", NSPoint(x: slot.minX + 2, y: slot.midY)),
            ("右侧留白", NSPoint(x: slot.maxX - 2, y: slot.midY)),
            ("顶部留白", NSPoint(x: slot.midX, y: slot.maxY - 2)),
            ("底部留白", NSPoint(x: slot.midX, y: slot.minY + 2)),
            ("左上留白", NSPoint(x: slot.minX + 2, y: slot.maxY - 2)),
            ("右上留白", NSPoint(x: slot.maxX - 2, y: slot.maxY - 2)),
            ("左下留白", NSPoint(x: slot.minX + 2, y: slot.minY + 2)),
            ("右下留白", NSPoint(x: slot.maxX - 2, y: slot.minY + 2)),
        ].filter { !buttonRect.insetBy(dx: -1, dy: -1).contains($0.1) }
        guard !paddingPoints.isEmpty else { throw CheckFailure("没有可核验的菜单栏留白") }
        let geometry: [String: Any] = ["statusWindow": NSStringFromRect(slot), "button": NSStringFromRect(buttonRect),
                                      "paddingPoints": paddingPoints.map { ["name": $0.0, "point": NSStringFromPoint($0.1)] }]
        try JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("status-hit-area.json"))
        for (name, point) in paddingPoints {
            let localPoint = statusWindow.convertPoint(fromScreen: point)
            // SystemUIServer's global copy can precede the forwarded local press.
            // Call the real global handler directly; no system event-posting permission is needed.
            delegate.handleGlobalPanelEvent(try globalMouseEvent(.leftMouseDown, at: point))
            guard panel.isVisible else { throw CheckFailure("外部点击监听误关闭菜单栏点击区域：\(name), point=\(point), currentSlot=\(statusWindow.frame), originalSlot=\(slot)") }
            try postStatusPress(button, types: [.leftMouseDown, .leftMouseUp], at: localPoint)
            try await Task.sleep(for: .milliseconds(200))
            guard !panel.isVisible else { throw CheckFailure("点击\(name)后弹窗关闭又重新打开") }
            delegate.handleGlobalPanelEvent(try globalMouseEvent(.leftMouseUp, at: point))
            try postStatusPress(button, types: [.leftMouseDown, .leftMouseUp], at: localPoint)
            try await waitUntil { panel.isVisible }
            // Also cover global copies arriving after local delivery.
            delegate.handleGlobalPanelEvent(try globalMouseEvent(.leftMouseDown, at: point))
            delegate.handleGlobalPanelEvent(try globalMouseEvent(.leftMouseUp, at: point))
            guard panel.isVisible else { throw CheckFailure("延后的留白点击事件误关闭弹窗：\(name)") }
        }
        delegate.handleGlobalPanelEvent(try globalMouseEvent(.leftMouseDown, at: NSPoint(x: slot.minX - 20, y: slot.midY)))
        guard !panel.isVisible else { throw CheckFailure("真正的菜单栏外部点击未关闭弹窗") }
        button.performClick(nil)
        try await waitUntil { panel.isVisible }
        guard let canvas = panel.contentView as? ShadowedPanelView else { throw CheckFailure("圆角阴影容器缺失") }
        canvas.layoutSubtreeIfNeeded()
        guard canvas.surface.frame.width == StatusPanelWindow.contentWidth else { throw CheckFailure("面板内容宽度改变") }
        guard let buttonWindow = button.window else { throw CheckFailure("菜单栏窗口缺失") }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let surfaceOnScreen = panel.convertToScreen(canvas.surface.convert(canvas.surface.bounds, to: nil))
        // AppKit rounds borderless window origins to whole points.
        guard abs(anchor.minY - surfaceOnScreen.maxY - 8) <= 1 else {
            throw CheckFailure("透明边距改变了面板顶部定位: anchor=\(anchor), surface=\(surfaceOnScreen), window=\(panel.frame)")
        }
        let before = session.store.rows.map(\.snapshot)
        try press("refresh-all", in: canvas)
        try await waitUntil { !session.store.isRefreshing && session.store.rows[0].snapshot != before[0] }
        guard session.store.rows[1].snapshot != before[1] else { throw CheckFailure("面板刷新按钮未生效") }
        try NativeCapture.write(canvas, to: output.appendingPathComponent("panel.png"))
        let adaptiveLayout = try await verifyAdaptivePanel(session: session, panel: panel, canvas: canvas,
                                                          button: button, output: output)
        let point = NSPoint(x: canvas.surface.frame.minX - 4, y: canvas.surface.frame.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                          context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            NSApp.postEvent(event, atStart: false)
        }
        try await waitUntil { !panel.isVisible }
        button.performClick(nil)
        try await waitUntil { panel.isVisible }
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}",
                                      charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        NSApp.postEvent(escape, atStart: false)
        try await waitUntil { !panel.isVisible }
        let report: [String: Any] = ["passed": true, "contentWidth": canvas.surface.frame.width,
                                  "contentHeight": canvas.surface.frame.height, "statusClickCycles": 5,
                                  "statusPaddingPoints": paddingPoints.count, "globalOutsideClickDismissed": true,
                                  "anchorGap": anchor.minY - surfaceOnScreen.maxY,
                                  "refreshButtonWorked": true, "shadowClickDismissed": true, "escapeDismissed": true,
                                  "adaptiveLayout": adaptiveLayout,
                                  "fixtureDirectory": session.root.path,
                                  "realAccountsAccessed": false, "realNetworkUsed": false]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("appearance-checks.json"))
    }

    /// Observe the actual status panel while account changes occur without closing it.
    /// The separate demo window deliberately does not participate in these measurements.
    private static func verifyAdaptivePanel(session: SimulationSession, panel: NSPanel,
                                            canvas: ShadowedPanelView, button: NSStatusBarButton,
                                            output: URL) async throws -> [String: Any] {
        guard let statusWindow = button.window, let screen = statusWindow.screen ?? NSScreen.main else {
            throw CheckFailure("自适应弹窗核验缺少屏幕锚点")
        }
        let anchor = statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let maximum = min(StatusPanelWindow.maximumContentHeight,
                          max(1, anchor.minY - screen.visibleFrame.minY - 14))
        let minimum = min(StatusPanelWindow.minimumContentHeight, maximum)
        var states: [[String: Any]] = []
        var addedAccounts: [Account] = []

        func capture(_ name: String, screenshot: String? = nil) async throws -> CGFloat {
            do { try await waitForPanelLayout(panel, canvas: canvas) }
            catch { throw CheckFailure("\(name): \(error), panelVisible=\(panel.isVisible), surface=\(canvas.surface.frame)") }
            let height = canvas.surface.frame.height
            let onScreen = panel.convertToScreen(canvas.surface.convert(canvas.surface.bounds, to: nil))
            guard abs(canvas.surface.frame.width - StatusPanelWindow.contentWidth) <= 1,
                  height >= minimum - 1, height <= maximum + 1 else {
                throw CheckFailure("\(name) 的弹窗尺寸超出范围: \(canvas.surface.frame.size), min=\(minimum), max=\(maximum)")
            }
            guard abs(anchor.minY - onScreen.maxY - 8) <= 1,
                  onScreen.minY >= screen.visibleFrame.minY + 5 else {
                throw CheckFailure("\(name) 的弹窗改变顶部锚点或超出屏幕: \(onScreen)")
            }
            var state: [String: Any] = ["state": name, "accountCount": session.store.rows.count,
                                        "contentWidth": canvas.surface.frame.width, "contentHeight": height,
                                        "surfaceOnScreen": NSStringFromRect(onScreen),
                                        "anchorGap": anchor.minY - onScreen.maxY]
            if let scroll = panelScrollView(in: canvas.surface), let document = scroll.documentView {
                state["documentHeight"] = document.bounds.height
                state["viewportHeight"] = scroll.contentView.bounds.height
            }
            states.append(state)
            try JSONSerialization.data(withJSONObject: ["states": states], options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("adaptive-layout-geometry.json"))
            if let screenshot { try NativeCapture.write(canvas, to: output.appendingPathComponent(screenshot)) }
            return height
        }

        let initialHeight = try await capture("two-accounts")
        var previousHeight = initialHeight
        repeat {
            let account = try await session.addAccount()
            addedAccounts.append(account)
            await session.store.waitForRefreshes()
            try await waitUntil { session.store.rows.last?.id == account.id && session.store.rows.last?.snapshot != nil }
            let height = try await capture("adding-\(session.store.rows.count)")
            guard height >= previousHeight - 1 else { throw CheckFailure("添加账号后弹窗高度缩小") }
            previousHeight = height
        } while previousHeight < maximum - 1 && addedAccounts.count < 12
        guard abs(previousHeight - maximum) <= 1 else { throw CheckFailure("多个账号未使弹窗达到高度上限") }
        if initialHeight < maximum - 1 {
            guard previousHeight > initialHeight + 1 else { throw CheckFailure("添加账号未使弹窗增长") }
        }

        let extra = try await session.addAccount()
        addedAccounts.append(extra)
        await session.store.waitForRefreshes()
        try await waitUntil { session.store.rows.last?.id == extra.id && session.store.rows.last?.snapshot != nil }
        let cappedHeight = try await capture("extra-account-at-cap", screenshot: "capped.png")
        guard abs(cappedHeight - maximum) <= 1 else { throw CheckFailure("达到上限后添加账号仍改变弹窗高度") }
        guard let scroll = panelScrollView(in: canvas.surface), let document = scroll.documentView,
              document.bounds.height > scroll.contentView.bounds.height + 1 else {
            throw CheckFailure("上限状态缺少可滚动的账号内容")
        }
        scrollToBottom(canvas.surface)
        try await Task.sleep(for: .milliseconds(100))
        let identifier = "refresh-account-\(extra.id)"
        guard let control = find(identifier, in: canvas.surface, depth: 0) else {
            try NativeCapture.write(canvas, to: output.appendingPathComponent("scroll-bottom-debug.png"))
            debugTree(canvas.surface, depth: 0)
            print("Scroll geometry: flipped=\(document.isFlipped), document=\(document.bounds), clip=\(scroll.contentView.bounds)")
            throw CheckFailure("滚动后找不到最后账号的刷新控件")
        }
        guard let controlFrame = accessibilityFrame(of: control) else {
            throw CheckFailure("最后账号的刷新控件没有屏幕坐标")
        }
        let viewport = panel.convertToScreen(scroll.contentView.convert(scroll.contentView.bounds, to: nil))
        guard viewport.intersects(controlFrame), controlFrame.intersection(viewport).height > 1 else {
            throw CheckFailure("最后账号的刷新控件未滚动进入视口: control=\(controlFrame), viewport=\(viewport)")
        }
        let lastReading = session.store.rows.last?.snapshot
        try press(identifier, in: canvas.surface)
        try await waitUntil { !session.store.isRefreshing && session.store.rows.last?.snapshot != lastReading }
        try NativeCapture.write(canvas, to: output.appendingPathComponent("capped.png"))

        for account in addedAccounts { await session.store.remove(account.id) }
        try await waitUntil { session.store.rows.count == 2 }
        let restoredTwoHeight = try await capture("two-accounts-restored")
        guard abs(restoredTwoHeight - initialHeight) <= 1 else { throw CheckFailure("移除附加账号后弹窗未恢复两个账号的高度") }
        guard let second = session.store.rows.last else { throw CheckFailure("初始账号丢失") }
        await session.store.remove(second.id)
        try await waitUntil { session.store.rows.count == 1 }
        let oneHeight = try await capture("one-account", screenshot: "one.png")
        guard oneHeight <= restoredTwoHeight + 1 else { throw CheckFailure("移除账号后弹窗未缩回") }
        guard let first = session.store.rows.first else { throw CheckFailure("剩余账号丢失") }
        await session.store.rename(first.id, label: String(repeating: "Long account name ", count: 6))
        let wrappedHeight = try await capture("one-account-wrapped-name")
        guard wrappedHeight > oneHeight + 1 || abs(oneHeight - maximum) <= 1 else {
            throw CheckFailure("账号名称换行后弹窗未适应组件高度")
        }
        await session.store.rename(first.id, label: first.account.label)
        let unwrappedHeight = try await capture("one-account-name-restored")
        guard abs(unwrappedHeight - oneHeight) <= 1 else { throw CheckFailure("恢复短名称后弹窗未缩回") }
        await session.store.remove(first.id)
        try await waitUntil { session.store.rows.isEmpty }
        let emptyHeight = try await capture("empty", screenshot: "empty.png")
        guard let empty = find("empty-accounts", in: canvas.surface, depth: 0),
              let emptyFrame = accessibilityFrame(of: empty),
              let emptyScroll = panelScrollView(in: canvas.surface),
              let emptyDocument = emptyScroll.documentView else {
            throw CheckFailure("零账号时未显示空状态")
        }
        let emptyViewport = panel.convertToScreen(emptyScroll.contentView.convert(emptyScroll.contentView.bounds, to: nil))
        guard emptyFrame.intersects(emptyViewport),
              emptyDocument.bounds.height <= emptyScroll.contentView.bounds.height + 1
                || abs(emptyHeight - maximum) <= 1 else {
            throw CheckFailure("零账号时空状态被截断且弹窗未达到屏幕高度上限")
        }
        guard emptyHeight <= oneHeight + 1 else {
            throw CheckFailure("移除最后账号后空状态高度反而增大")
        }
        if maximum > minimum + 1 {
            guard emptyHeight < cappedHeight - 1 else { throw CheckFailure("移除全部账号后弹窗未从上限缩回") }
        }
        let restored = try await session.addAccount()
        await session.store.waitForRefreshes()
        try await waitUntil { session.store.rows.count == 1 && session.store.rows.first?.snapshot != nil }
        let restoredOneHeight = try await capture("one-account-restored", screenshot: "one-restored.png")
        guard abs(restoredOneHeight - oneHeight) <= 1,
              find("refresh-account-\(restored.id)", in: canvas.surface, depth: 0) != nil else {
            throw CheckFailure("空状态添加账号后未恢复账号内容及对应高度")
        }
        button.performClick(nil)
        try await waitUntil { !panel.isVisible }
        let hiddenAccount = try await session.addAccount()
        await session.store.waitForRefreshes()
        button.performClick(nil)
        try await waitUntil { panel.isVisible }
        let reopenedHeight = try await capture("reopened-after-hidden-add")
        guard abs(reopenedHeight - initialHeight) <= 1 else { throw CheckFailure("隐藏期间添加账号后重新打开的高度不正确") }
        await session.store.remove(hiddenAccount.id)
        _ = try await capture("one-account-after-reopen")
        return ["states": states, "configuredMinimum": StatusPanelWindow.minimumContentHeight,
                "configuredMaximum": StatusPanelWindow.maximumContentHeight,
                "effectiveMinimum": minimum, "effectiveMaximum": maximum,
                "screenVisibleFrame": NSStringFromRect(screen.visibleFrame),
                "bottomAccountRefreshWorked": true,
                "bottomAccountControlFrame": NSStringFromRect(controlFrame),
                "scrollViewportOnScreen": NSStringFromRect(viewport),
                "resizedWhileVisible": true]
    }

    private static func waitForPanelLayout(_ panel: NSPanel, canvas: ShadowedPanelView) async throws {
        var previousHeight: CGFloat = -1
        var stableSamples = 0
        try await waitUntil {
            canvas.layoutSubtreeIfNeeded()
            let height = canvas.surface.frame.height
            stableSamples = abs(height - previousHeight) <= 0.5 ? stableSamples + 1 : 0
            previousHeight = height
            return panel.isVisible && stableSamples >= 2
        }
    }

    private static func panelScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { panelScrollView(in: $0) }.first
    }

    private static func accessibilityFrame(of element: NSObject) -> NSRect? {
        let selector = NSSelectorFromString("accessibilityFrame")
        guard element.responds(to: selector) else { return nil }
        // CGRect is a struct return; NSObject.perform is only valid for object returns.
        typealias Frame = @convention(c) (AnyObject, Selector) -> CGRect
        let getter = unsafeBitCast(element.method(for: selector), to: Frame.self)
        return getter(element, selector)
    }

    /// Focused keyboard acceptance independent of appearance and account-flow checks.
    static func runShortcuts(session: SimulationSession, item: NSStatusItem, panel: NSPanel,
                             dialogs: DialogPresenter, requestRename: (Account) -> Void,
                             requestRemove: (Account) -> Void, output: URL) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await waitUntil { session.store.rows.count == 2
            && session.store.rows.allSatisfy { $0.snapshot != nil && !$0.refreshing } }
        try await verifyKeyboardShortcuts(personal: session.store.rows[0].account, store: session.store,
                                         item: item, panel: panel, dialogs: dialogs,
                                         requestRename: requestRename, requestRemove: requestRemove,
                                         fixtureDirectory: session.root, output: output)
    }

    static func run(session: SimulationSession, refresh: RefreshController, item: NSStatusItem,
                    panel: NSPanel, view: NSView, dialogs: DialogPresenter,
                    loginItem: LoginItemController,
                    dates: DateDisplayController,
                    material: PanelMaterialController,
                    requestRename: (Account) -> Void, requestRemove: (Account) -> Void,
                    output: URL) async throws {
        let store = session.store
        var checks: [String] = []
        func check(_ condition: Bool, _ description: String) throws {
            guard condition else { throw CheckFailure(description) }
            checks.append(description)
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // Read-only smoke check of real OS probes. State transitions below remain simulated;
        // verification never locks, sleeps, or changes the user's real session.
        let hostActivity = MacActivityMonitor(onChange: { _ in }).currentState()
        try await waitUntil { store.rows.count == 2 && store.rows.allSatisfy { $0.snapshot != nil && !$0.refreshing } }
        let personal = store.rows[0].account
        let work = store.rows[1].account
        try await verifyKeyboardShortcuts(personal: personal, store: store, item: item, panel: panel,
                                         dialogs: dialogs, requestRename: requestRename,
                                         requestRemove: requestRemove, fixtureDirectory: session.root, output: output)
        try check(personal.identity.email == work.identity.email && personal.identity.key != work.identity.key,
                  "同邮箱的两个模拟工作区保持独立")
        guard let button = item.button else { throw CheckFailure("菜单栏按钮缺失") }
        try check(button.title.isEmpty && button.image != nil && button.imagePosition == .imageOnly
                  && item.length == NSStatusItem.squareLength, "实际菜单栏仅有图标，无文字")
        try check(button.image?.size == NSSize(width: 20, height: 20), "菜单栏图标增大为 20 点")
        try check(UserDefaults.standard.integer(forKey: "NSInitialToolTipDelay") == 200,
                  "原生 tooltip 的应用内延迟配置为 200 毫秒")
        try check(!panel.isOpaque && panel.backgroundColor == .clear,
                  "面板使用透明窗口背景，让原生材质呈现")
        if #available(macOS 26.0, *), !CommandLine.arguments.contains("--standard-appearance"),
           !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            try check(material.materialView is NSGlassEffectView && material.materialName == "liquid-glass",
                      "受支持系统使用原生 Liquid Glass 容器")
        } else {
            try check(material.materialView is NSVisualEffectView && material.materialName == "standard",
                      "标准外观回退使用原生半透明材质")
        }
        NSApp.hide(nil)
        try await waitUntil { !NSApp.isActive }
        button.performClick(nil)
        try check(panel.isVisible, "点击实际菜单栏图标打开弹窗")
        try await Task.sleep(for: .milliseconds(200))
        try check(panel.isKeyWindow,
                  "应用未激活时第一次点击图标即可聚焦非激活面板")
        if let content = panel.contentViewController?.view {
            try NativeCapture.write(content, to: output.appendingPathComponent("status-panel.png"))
        }
        let panelBefore = store.rows.map(\.snapshot)
        try press("refresh-all", in: material.content.view)
        try await waitUntil { !store.isRefreshing && store.rows[0].snapshot != panelBefore[0] }
        try check(store.rows[1].snapshot != panelBefore[1], "真实材质面板内的全量刷新按钮可交互并更新两个账号")
        try press("launch-at-login", in: material.content.view)
        try await waitUntil { loginItem.enabled }
        try press("launch-at-login", in: material.content.view)
        try await waitUntil { !loginItem.enabled }
        try check(true, "真实材质面板内的登录启动开关可交互")
        button.performClick(nil)
        try check(!panel.isVisible, "再次点击图标关闭弹窗")
        button.performClick(nil)
        // Model the focus-loss notification arriving before the same status-item click action.
        NSApp.delegate?.applicationDidResignActive?(Notification(name: NSApplication.didResignActiveNotification))
        button.performClick(nil)
        try check(!panel.isVisible, "失焦通知先于图标点击时，点击只关闭而不立即重新打开")
        try await Task.sleep(for: .milliseconds(200))
        try check(!panel.isVisible, "延后的失焦关闭回调不会重新弹出界面")
        button.performClick(nil)
        NSApp.deactivate()
        try await Task.sleep(for: .milliseconds(250))
        button.performClick(nil)
        try check(!panel.isVisible, "失焦超过旧关闭延迟后，同一次图标点击仍只关闭")
        button.performClick(nil)
        NSApp.hide(nil)
        try await waitUntil { !panel.isVisible }
        try check(true, "应用隐藏时面板关闭")
        for _ in 0..<20 {
            try postStatusClick(button)
            try await waitUntil { panel.isVisible }
            try postStatusClick(button)
            try await waitUntil { !panel.isVisible }
            try await Task.sleep(for: .milliseconds(150))
            try check(!panel.isVisible, "投递原生 mouse-down/up 事件再次点击关闭，不重新弹出")
        }
        // Repeated down deliveries within one press must not toggle twice.
        try postStatusPress(button, types: [.leftMouseDown, .leftMouseDown])
        try await waitUntil { panel.isVisible }
        try postStatusPress(button, types: [.leftMouseUp])
        try await Task.sleep(for: .milliseconds(100))
        try check(panel.isVisible, "同一按压的重复 mouse-down 只打开一次，mouse-up 不再触发开关")
        try postStatusClick(button)
        try await waitUntil { !panel.isVisible }
        button.performClick(nil)
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: panel.contentViewController?.view.window?.windowNumber ?? 0,
                                      context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                      isARepeat: false, keyCode: 53)!
        NSApp.postEvent(escape, atStart: false)
        try await waitUntil { !panel.isVisible }
        try check(true, "Escape 关闭弹窗")
        button.performClick(nil)
        guard let outsideWindow = view.window else { throw CheckFailure("模拟窗口缺失") }
        let outside = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 15, y: 15), modifierFlags: [],
                                         timestamp: 0, windowNumber: outsideWindow.windowNumber, context: nil,
                                         eventNumber: 0, clickCount: 1, pressure: 1)!
        NSApp.postEvent(outside, atStart: false)
        try await waitUntil { !panel.isVisible }
        try check(true, "点击应用内弹窗外区域关闭弹窗")
        try NativeCapture.write(button, to: output.appendingPathComponent("menu-bar-icon.png"))
        try NativeCapture.write(view, to: output.appendingPathComponent("automatic-on.png"))

        let resetID = "reset-\(personal.id)-codex-session"
        try press(resetID, in: view)
        try await waitUntil { dates.absolute }
        for id in [personal.id, work.id] {
            let reset = find("reset-\(id)-codex-session", in: view, depth: 0)
            let updated = find("updated-\(id)", in: view, depth: 0)
            try check((reset.flatMap { value("accessibilityLabel", of: $0) as? String })?.contains("重置于") == true
                      && (updated.flatMap { value("accessibilityLabel", of: $0) as? String })?.contains("-") == true,
                      "点击一个重置标签后，所有账号重置和更新时间同步显示完整日期")
        }
        try NativeCapture.write(view, to: output.appendingPathComponent("absolute-dates.png"))
        try press("updated-\(work.id)", in: view)
        try await waitUntil { !dates.absolute }
        try check(true, "点击任一更新时间恢复全局相对日期显示")
        try check(store.rows[0].snapshot?.credits?.balance == 123.4567
                  && find("credits-\(personal.id)", in: view, depth: 0) != nil,
                  "接口 credit 余额解析后显示于原生账号卡片")
        let credits = find("credits-\(personal.id)", in: view, depth: 0)
        try check((credits.flatMap { value("accessibilityValue", of: $0) as? String })?.contains("123.46") == true,
                  "余额按两位小数显示，不改变解析精度")
        let plan = find("plan-\(work.id)", in: view, depth: 0)
        try check((plan.flatMap { value("accessibilityValue", of: $0) as? String }) == "Pro Max",
                  "Pro Max 保留细分身份，移除登录后缀")
        let percentage = find("percentage-\(personal.id)-codex-weekly", in: view, depth: 0)
        try check((percentage.flatMap { value("accessibilityValue", of: $0) as? String }) == "剩余 50%",
                  "整数百分比不强制添加小数零")
        let refreshButton = find("refresh-account-\(personal.id)", in: view, depth: 0)
        try check((refreshButton.flatMap { value("accessibilityHelp", of: $0) as? String })?.contains("立即刷新") == true,
                  "刷新控件恢复 AppKit 原生 tooltip")
        try press("launch-at-login", in: view)
        try await waitUntil { loginItem.enabled }
        try press("launch-at-login", in: view)
        try await waitUntil { !loginItem.enabled }
        try check(true, "登录启动开关使用模拟服务可开关，不修改真实登录项")

        let beforePause = store.rows.map(\.snapshot)
        refresh.setActivity(.locked)
        session.advanceRefreshClock(by: 600)
        refresh.handleWake()
        try await Task.sleep(for: .milliseconds(200))
        try check(store.rows.map(\.snapshot) == beforePause, "锁屏状态即使超过刷新间隔，唤醒提示也不发起网络查询")
        let inactive = find("mac-activity", in: view, depth: 0)
        try check((inactive.flatMap { value("accessibilityValue", of: $0) as? String })?.contains("非活跃") == true,
                  "界面展示非活跃与暂停状态")
        try NativeCapture.write(view, to: output.appendingPathComponent("smart-paused.png"))
        try press("refresh-all", in: view)
        try await waitUntil { !store.isRefreshing && store.rows[0].snapshot != beforePause[0] }
        let manualDuringPause = store.rows.map(\.snapshot)
        refresh.setActivity(.active)
        try await Task.sleep(for: .milliseconds(200))
        try check(store.rows.map(\.snapshot) == manualDuringPause, "非活跃时可以手动刷新，刚手动刷新后恢复活跃不重复查询")
        refresh.setActivity(.idle)
        session.advanceRefreshClock(by: refresh.refreshInterval.seconds)
        refresh.setActivity(.active)
        try await waitUntil { !store.isRefreshing && store.rows[0].snapshot != manualDuringPause[0] }
        try check(store.rows[1].snapshot != manualDuringPause[1], "空闲后恢复活跃且间隔已到，补刷当前账号")
        try NativeCapture.write(panel.contentView!, to: output.appendingPathComponent("smart-active.png"))

        try press("move-down-\(personal.id)", in: view)
        try await waitUntil { store.rows.first?.id == work.id }
        try press("move-up-\(personal.id)", in: view)
        try await waitUntil { store.rows.first?.id == personal.id }
        try check(true, "卡片上移和下移按钮改变账号排序")
        try press("automatic-account-\(personal.id)", in: view)
        try await waitUntil { !store.rows[0].account.automaticRefreshEnabled }
        let optedOut = store.rows[0].snapshot
        let beforeWake = store.rows[1].snapshot
        refresh.setActivity(.sleeping)
        session.advanceRefreshClock(by: refresh.refreshInterval.seconds)
        refresh.setActivity(.active)
        try await waitUntil { !store.isRefreshing && store.rows[1].snapshot != beforeWake }
        try check(store.rows[0].snapshot == optedOut, "唤醒自动刷新跳过单独禁用的账号")
        try press("refresh-account-\(personal.id)", in: view)
        try await waitUntil { !store.isRefreshing && store.rows[0].snapshot != optedOut }
        try check(true, "禁用自动刷新的账号仍能通过卡片独立按钮手动刷新")
        try press("automatic-account-\(personal.id)", in: view)
        try await waitUntil { store.rows[0].account.automaticRefreshEnabled }

        try selectInterval("1 分钟", in: view)
        try await waitUntil { refresh.refreshInterval == .oneMinute }
        try check(true, "通过原生下拉控件将自动刷新间隔设置为 1 分钟")

        try press("automatic-refresh", in: view)
        try await waitUntil { !refresh.automaticRefreshEnabled }
        let before = store.rows.map(\.snapshot)
        refresh.handleWake()
        try await Task.sleep(for: .milliseconds(200))
        try check(store.rows.map(\.snapshot) == before, "通过原生开关关闭自动刷新后，唤醒不发起查询")
        try press("refresh-all", in: view)
        try await waitUntil { store.rows[0].snapshot != before[0] && !store.isRefreshing }
        try check(store.rows[1].snapshot != before[1], "自动关闭后，点击原生手动刷新按钮更新两个账号")
        try NativeCapture.write(view, to: output.appendingPathComponent("manual-only.png"))

        let untouched = store.rows[0].snapshot
        let workBefore = store.rows[1].snapshot
        try press("refresh-account-\(work.id)", in: view)
        try await waitUntil { store.rows[1].snapshot != workBefore && !store.isRefreshing }
        await store.waitForRefreshes()
        try check(store.rows[1].snapshot != workBefore && store.rows[0].snapshot == untouched,
                  "仅手动刷新单账号，不更新其它账号")
        requestRename(personal)
        guard let renameWindow = dialogs.window, let renameView = renameWindow.contentView else { throw CheckFailure("名称窗口缺失") }
        try await waitUntil { renameWindow.isKeyWindow && renameWindow.firstResponder is NSTextView }
        try check(renameView.frame.width == 408 && renameView.frame.height > 100 && renameView.frame.height < 400,
                  "名称窗口布局正常，自动激活并聚焦输入框")
        try setName("取消的名称", in: renameView)
        try press("dialog-cancel", in: renameView)
        try check(store.rows[0].account.label == personal.label && dialogs.window == nil, "取消名称编辑不修改账号")
        requestRename(personal)
        guard let saveView = dialogs.window?.contentView else { throw CheckFailure("名称窗口缺失") }
        try await Task.sleep(for: .milliseconds(100))
        try setName("已命名的模拟账号", in: saveView)
        try NativeCapture.write(saveView, to: output.appendingPathComponent("rename-dialog.png"))
        try press("dialog-confirm", in: saveView)
        try await waitUntil { store.rows[0].account.label == "已命名的模拟账号" }
        try check(dialogs.window == nil, "原生名称窗口保存生效并关闭")
        dialogs.message(title: LocalizedText("dialog.operationIncomplete", table: "Dialogs"), detail: UsageError.network.message)
        guard let errorView = dialogs.window?.contentView else { throw CheckFailure("错误窗口缺失") }
        try NativeCapture.write(errorView, to: output.appendingPathComponent("error-dialog.png"))
        try press("dialog-confirm", in: errorView)
        try check(dialogs.window == nil, "错误窗口使用同一布局并可关闭")
        var closed = 0
        dialogs.message(title: LocalizedText("dialog.operationIncomplete", table: "Dialogs"), detail: UsageError.network.message, onClose: { closed += 1 })
        dialogs.window?.performClose(nil)
        try check(dialogs.window == nil && closed == 1, "标题栏关闭提示窗口执行一次关闭回调")
        let oldCredentials = try await session.repository.readCredentials(personal).data
        try await session.reauthenticate(personal)
        await store.waitForRefreshes()
        let renewed = try await session.repository.readCredentials(personal).data
        try check(renewed != oldCredentials && store.rows[0].id == personal.id,
                  "隔离的假 Codex CLI 重新登录保留账号身份并替换模拟凭据")

        let added = try await session.addAccount()
        await store.waitForRefreshes()
        try check(store.rows.count == 3 && store.rows.last?.snapshot != nil && !refresh.automaticRefreshEnabled,
                  "自动关闭时仍可通过假 CLI 添加第三个模拟账号并获取首次额度")
        let previousWork = store.rows.first(where: { $0.id == work.id })!.snapshot
        await session.failNextRefresh()
        await store.waitForRefreshes()
        let failed = store.rows.first(where: { $0.id == work.id })!
        try check(failed.errorMessage == UsageError.http(503).message && failed.snapshot == previousWork,
                  "模拟部分失败保留原成功读数和时间，并显示错误")
        scrollToBottom(view)
        try await Task.sleep(for: .milliseconds(100))
        try NativeCapture.write(view, to: output.appendingPathComponent("partial-failure.png"))
        try press("refresh-all", in: view)
        try await waitUntil { store.rows.first(where: { $0.id == work.id })?.errorMessage == nil && !store.isRefreshing }
        try check(store.rows.first(where: { $0.id == work.id })?.snapshot != previousWork,
                  "点击原生手动刷新按钮后失败账号恢复并清除错误")

        let managedFile = try await session.repository.readCredentials(added).file
        requestRemove(added)
        guard let cancelRemoval = dialogs.window?.contentView else { throw CheckFailure("移除窗口缺失") }
        try press("dialog-cancel", in: cancelRemoval)
        try check(store.rows.contains(where: { $0.id == added.id }), "取消原生移除确认不删除账号")
        requestRemove(added)
        guard let confirmRemoval = dialogs.window?.contentView else { throw CheckFailure("移除窗口缺失") }
        try NativeCapture.write(confirmRemoval, to: output.appendingPathComponent("remove-dialog.png"))
        try press("dialog-confirm", in: confirmRemoval)
        try await waitUntil { !store.rows.contains(where: { $0.id == added.id }) }
        try check(!FileManager.default.fileExists(atPath: managedFile.path), "移除独立模拟账号删除其私有凭据")
        let linkedFile = try await session.repository.readCredentials(work).file
        let linkedData = try Data(contentsOf: linkedFile)
        await store.remove(work.id)
        try check(try Data(contentsOf: linkedFile) == linkedData, "移除关联模拟账号不修改源凭据")
        let reloaded = AccountStore(repository: session.repository, fetcher: NoNetworkFetcher())
        await reloaded.load()
        try check(reloaded.rows.count == 1 && reloaded.rows[0].account.label == "已命名的模拟账号"
                  && reloaded.rows[0].snapshot == store.rows[0].snapshot && reloaded.rows[0].restoredFromCache, "重载账号保留名称与最新读数，并标注缓存")

        let beforeEnable = store.rows[0].snapshot
        try selectInterval("15 分钟", in: view)
        try await waitUntil { refresh.refreshInterval == .fifteenMinutes }
        try press("automatic-refresh", in: view)
        try await waitUntil { refresh.automaticRefreshEnabled && !store.isRefreshing && store.rows[0].snapshot != beforeEnable }
        try check(true, "通过原生开关重新开启自动刷新，立即更新当前账号")
        try check(refresh.refreshInterval == .fifteenMinutes, "自动刷新关闭时仍可设置间隔，重新开启保留选择")
        let report: [String: Any] = [
            "passed": true, "checks": checks, "realAccountsAccessed": false,
            "panelMaterial": material.materialName,
            "hostActivityProbe": hostActivity.rawValue,
            "realNetworkUsed": false, "fixtureCLI": "isolated fake-codex",
            "fixtureDirectory": session.root.path,
            "nativeActions": ["status-item click", "native switch activation", "native refresh-button activation"],
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("simulation-flow.json"))
    }

    /// Posts native key events through NSApplication so menu equivalents and the responder chain participate.
    private static func verifyKeyboardShortcuts(personal: Account, store: AccountStore, item: NSStatusItem,
                                                panel: NSPanel, dialogs: DialogPresenter,
                                                requestRename: (Account) -> Void,
                                                requestRemove: (Account) -> Void,
                                                fixtureDirectory: URL, output: URL) async throws {
        var checks: [String] = []
        func record(_ condition: Bool, _ description: String) throws {
            guard condition else { throw CheckFailure(description) }
            checks.append(description)
            try JSONSerialization.data(withJSONObject: ["passed": false, "checks": checks], options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("keyboard-checks.json"))
        }
        guard let button = item.button else { throw CheckFailure("Shortcut check needs the status item") }
        let otherWindow = NSApp.keyWindow
        button.performClick(nil)
        try await waitUntil { panel.isKeyWindow }
        try record(panel.styleMask.contains(.nonactivatingPanel) && NSApp.activationPolicy() == .accessory,
                   "Focused status panel retains its nonactivating style and accessory activation policy")
        let otherWindowVisible = otherWindow?.isVisible
        try postKey("w", code: 13, modifiers: [.command, .shift], window: panel)
        try await Task.sleep(for: .milliseconds(150))
        try record(panel.isVisible, "Cmd+Shift+W does not masquerade as Cmd+W")
        try postKey("w", code: 13, modifiers: .command, window: panel)
        try await Task.sleep(for: .milliseconds(200))
        try record(!panel.isVisible && otherWindow?.isVisible == otherWindowVisible,
                   "Cmd+W closes the focused status panel and preserves the background window")
        button.performClick(nil)
        try await waitUntil { panel.isKeyWindow }
        try postKey("\u{1b}", code: 53, modifiers: [], window: panel)
        try await waitUntil { !panel.isVisible }
        try record(true, "Escape closes the reopened status panel")
        button.performClick(nil)
        try await waitUntil { panel.isKeyWindow }
        try await verifySettingsShortcut(in: panel)
        try record(panel.isVisible, "Cmd+, opens the existing settings gear menu and dismissal preserves the panel")
        try postKey("w", code: 13, modifiers: .command, window: panel)
        try await waitUntil { !panel.isVisible }

        requestRename(personal)
        guard let rename = dialogs.window, let content = rename.contentView else { throw CheckFailure("Rename window is missing") }
        try await waitUntil { rename.isKeyWindow && rename.firstResponder is NSTextView }
        try setName("Shortcut draft", in: content)
        guard let editor = rename.firstResponder as? NSTextView else { throw CheckFailure("Rename field editor is missing") }
        try postKey("a", code: 0, modifiers: .command, window: rename)
        try await Task.sleep(for: .milliseconds(100))
        try record(editor.selectedRange() == NSRange(location: 0, length: editor.string.utf16.count),
                   "Cmd+A selects the entire rename draft")
        let pasteboard = NSPasteboard.general
        let savedItems = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            pasteboard.clearContents()
            let restored = savedItems.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            if !restored.isEmpty { pasteboard.writeObjects(restored) }
        }
        try postKey("c", code: 8, modifiers: .command, window: rename)
        try await Task.sleep(for: .milliseconds(100))
        try record(pasteboard.string(forType: .string) == "Shortcut draft", "Cmd+C copies the selected rename text")
        try postKey("x", code: 7, modifiers: .command, window: rename)
        try await Task.sleep(for: .milliseconds(100))
        try record(editor.string.isEmpty, "Cmd+X cuts the selected rename text")
        try postKey("v", code: 9, modifiers: .command, window: rename)
        try await Task.sleep(for: .milliseconds(100))
        try record(editor.string == "Shortcut draft", "Cmd+V pastes into the rename field")
        try postKey("z", code: 6, modifiers: .command, window: rename)
        try await Task.sleep(for: .milliseconds(100))
        try record(editor.string.isEmpty, "Cmd+Z undoes the paste")
        try postKey("z", code: 6, modifiers: [.command, .shift], window: rename)
        try await Task.sleep(for: .milliseconds(100))
        try record(editor.string == "Shortcut draft", "Cmd+Shift+Z redoes the paste")
        try postKey("w", code: 13, modifiers: .command, window: rename)
        try await Task.sleep(for: .milliseconds(150))
        try record(dialogs.window == nil && store.rows[0].account.label == personal.label,
                   "Cmd+W cancels the rename draft without saving")

        requestRename(personal)
        guard let cancel = dialogs.window else { throw CheckFailure("Rename window is missing") }
        try await waitUntil { cancel.isKeyWindow && cancel.firstResponder is NSTextView }
        try postKey("\u{1b}", code: 53, modifiers: [], window: cancel)
        try await Task.sleep(for: .milliseconds(150))
        try record(dialogs.window == nil && store.rows[0].account.label == personal.label,
                   "Escape cancels rename without saving")
        requestRemove(personal)
        guard let removal = dialogs.window else { throw CheckFailure("Removal window is missing") }
        try await waitUntil { removal.isKeyWindow }
        try postKey("w", code: 13, modifiers: .command, window: removal)
        try await Task.sleep(for: .milliseconds(150))
        try record(dialogs.window == nil && store.rows.contains(where: { $0.id == personal.id }),
                   "Cmd+W cancels removal without deleting the account")
        var closed = 0
        dialogs.message(title: LocalizedText("dialog.operationIncomplete", table: "Dialogs"), detail: UsageError.network.message,
                        onClose: { closed += 1 })
        guard let message = dialogs.window else { throw CheckFailure("Message window is missing") }
        try await waitUntil { message.isKeyWindow }
        try postKey("\r", code: 36, modifiers: [], window: message)
        try await Task.sleep(for: .milliseconds(150))
        try record(dialogs.window == nil && closed == 1, "Return closes a message and calls its completion once")
        try JSONSerialization.data(withJSONObject: ["passed": true, "checks": checks,
                                                   "input": "CGEvent-backed NSEvent via NSApplication.postEvent", "liveNetworkUsed": false,
                                                   "realAccountsAccessed": false, "fixtureDirectory": fixtureDirectory.path],
                                   options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("keyboard-checks.json"))
    }

    @MainActor private final class SettingsShortcutProbe {
        var menu: NSMenu?
        var opened = false
        func inspect() {
            guard let menu, !menu.items.isEmpty else { return }
            opened = (try? SimulationVerifier.settingItem("automatic-refresh", in: menu)) != nil
                && (try? SimulationVerifier.settingItem("refresh-interval", in: menu))?.submenu != nil
                && (try? SimulationVerifier.settingItem("language-select", in: menu))?.submenu != nil
            menu.cancelTrackingWithoutAnimation()
            self.menu = nil
        }
    }

    private static func verifySettingsShortcut(in panel: NSPanel) async throws {
        let probe = SettingsShortcutProbe()
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                                               object: nil, queue: nil) { notification in
            precondition(Thread.isMainThread)
            nonisolated(unsafe) let menu = notification.object as? NSMenu
            MainActor.assumeIsolated { probe.menu = menu }
        }
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { probe.inspect() }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        defer { timer.invalidate(); NotificationCenter.default.removeObserver(observer) }
        try postKey(",", code: 43, modifiers: .command, window: panel)
        try await waitUntil { probe.opened }
    }

    private static func postKey(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags,
                                window: NSWindow) throws {
        // Keep native keyboard metadata: constructing characters by hand can make AppKit
        // reject a valid shifted equivalent even when its visible characters look correct.
        guard let keyboardEvent = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true) else {
            throw CheckFailure("Cannot create keyboard event")
        }
        keyboardEvent.flags = CGEventFlags(rawValue: UInt64(modifiers.rawValue))
        guard let event = NSEvent(cgEvent: keyboardEvent) else { throw CheckFailure("Cannot create key event") }
        NSApp.postEvent(event, atStart: false)
    }

    private static func setName(_ name: String, in view: NSView) throws {
        func field(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable { return field }
            return view.subviews.lazy.compactMap { field(in: $0) }.first
        }
        guard let input = field(in: view) else { throw CheckFailure("名称输入框缺失") }
        input.stringValue = name
        if let editor = input.currentEditor() { editor.string = name }
        input.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: input))
    }

    private static func postStatusClick(_ button: NSStatusBarButton) throws {
        try postStatusPress(button, types: [.leftMouseDown, .leftMouseUp])
    }

    private static func globalMouseEvent(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                            context: nil, eventNumber: 0, clickCount: 1,
                                            pressure: type == .leftMouseDown ? 1 : 0) else {
            throw CheckFailure("无法创建全局鼠标事件副本")
        }
        return event
    }

    private static func postStatusPress(_ button: NSStatusBarButton, types: [NSEvent.EventType], at location: NSPoint? = nil) throws {
        guard let window = button.window else { throw CheckFailure("菜单栏窗口缺失") }
        let point = location ?? button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        for type in types {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil,
                                               eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
                throw CheckFailure("无法创建菜单栏鼠标事件")
            }
            NSApp.postEvent(event, atStart: false)
        }
    }

    private static func selectInterval(_ title: String, in view: NSView) throws {
        try selectPicker("refresh-interval", title: title, in: view)
    }

    private static func selectLanguage(_ requested: AppLanguage, in view: NSView) throws {
        let title = requested.name
        try selectPicker("language-select", title: title, in: view)
    }

    /// Observe and operate the real SwiftUI menu while AppKit is tracking it.
    /// Its contents do not exist before presentation and may be discarded after dismissal.
    private static func withSettingsMenu<Value>(in view: NSView,
                                                _ operation: @escaping @MainActor (NSMenu) throws -> Value) throws -> Value {
        guard let element = find("settings-menu", in: view, depth: 0),
              let cell = (element as? NSPopUpButtonCell) ?? ((element as? NSControl)?.cell as? NSPopUpButtonCell),
              let control = cell.controlView else {
            debugTree(view, depth: 0)
            throw CheckFailure("齿轮设置菜单缺少 NSPopUpButtonCell 原生菜单 backing")
        }
        let probe = MenuTrackingProbe(cell: cell, operation: operation)
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                                               object: nil, queue: nil) { notification in
            // AppKit posts this notification synchronously during main-thread menu tracking.
            // Keep the non-Sendable AppKit object inside this test-only synchronous boundary.
            precondition(Thread.isMainThread)
            nonisolated(unsafe) let trackedMenu = notification.object as? NSMenu
            MainActor.assumeIsolated {
                if let trackedMenu { probe.didBeginTracking(trackedMenu) }
            }
        }
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { probe.inspect() }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        defer {
            timer.invalidate()
            NotificationCenter.default.removeObserver(observer)
        }
        cell.performClick(withFrame: control.bounds, in: control)
        guard let result = probe.result else { throw CheckFailure("原生设置菜单未进入 tracking 或被提前关闭") }
        return try result.get()
    }

    @MainActor private final class MenuTrackingProbe<Value> {
        let cell: NSPopUpButtonCell
        let operation: @MainActor (NSMenu) throws -> Value
        let deadline = Date().addingTimeInterval(3)
        var trackedMenu: NSMenu?
        var result: Result<Value, Error>?

        init(cell: NSPopUpButtonCell, operation: @escaping @MainActor (NSMenu) throws -> Value) {
            self.cell = cell
            self.operation = operation
        }

        func didBeginTracking(_ menu: NSMenu) {
            guard trackedMenu == nil else { return }
            trackedMenu = menu
        }

        func inspect() {
            guard result == nil else { return }
            let menu = trackedMenu ?? cell.menu
            guard let menu, !menu.items.isEmpty else {
                if Date() >= deadline {
                    result = .failure(CheckFailure("原生设置菜单 tracking 中等待条目生成超时"))
                    menu?.cancelTracking()
                    NSApp.sendAction(#selector(NSResponder.cancelOperation(_:)), to: nil, from: nil)
                }
                return
            }
            result = Result { try operation(menu) }
            menu.cancelTracking()
        }
    }

    private static func selectPicker(_ identifier: String, title: String, in view: NSView) throws {
        try withSettingsMenu(in: view) { menu in
            let parent = try settingItem(identifier, in: menu)
            guard let submenu = parent.submenu else { throw CheckFailure("设置选项不是原生子菜单：\(identifier)") }
            guard let index = submenu.items.firstIndex(where: { $0.title == title }), submenu.items[index].isEnabled else {
                throw CheckFailure("原生设置子菜单选项缺失或不可用：\(identifier)，\(title)，现有选项：\(submenu.items.map(\.title))")
            }
            submenu.performActionForItem(at: index)
        }
    }

    private static func settingItem(_ identifier: String, in menu: NSMenu) throws -> NSMenuItem {
        let titles: [String]
        switch identifier {
        case "launch-at-login": titles = ["登录时启动", "Launch at Login"]
        case "automatic-refresh": titles = ["智能刷新", "Smart refresh"]
        case "refresh-interval": titles = ["刷新间隔", "Refresh interval"]
        case "language-select": titles = ["界面语言", "Interface Language"]
        case "absolute-dates": titles = ["显示完整日期", "Show full dates"]
        default: throw CheckFailure("未知设置菜单控件：\(identifier)")
        }
        guard let item = menu.items.first(where: {
            $0.identifier?.rawValue == identifier
                || (value("accessibilityIdentifier", of: $0) as? String) == identifier
                || titles.contains($0.title)
        }) else {
            throw CheckFailure("原生设置菜单控件缺失：\(identifier)，现有条目：\(menu.items.map(\.title))")
        }
        return item
    }

    private static func activateSetting(_ identifier: String, in view: NSView) throws {
        try withSettingsMenu(in: view) { menu in
            let item = try settingItem(identifier, in: menu)
            guard item.isEnabled else { throw CheckFailure("原生设置菜单控件不可用：\(identifier)") }
            menu.performActionForItem(at: menu.index(of: item))
        }
    }

    private static func settingState(_ identifier: String, in view: NSView) throws -> Bool {
        try withSettingsMenu(in: view) { menu in
            try settingItem(identifier, in: menu).state == .on
        }
    }

    private static func pickerState(_ identifier: String, title: String, in view: NSView) throws -> Bool {
        try withSettingsMenu(in: view) { menu in
            let item = try settingItem(identifier, in: menu)
            guard let option = item.submenu?.items.first(where: { $0.title == title }) else {
                throw CheckFailure("无法核验原生子菜单勾选状态：\(identifier)，\(title)")
            }
            return option.state == .on
        }
    }

    private static func writeSettingsHierarchy(in view: NSView, to file: URL) throws {
        func entries(_ menu: NSMenu) -> [[String: Any]] {
            menu.items.map { item in
                var entry: [String: Any] = ["title": item.title, "separator": item.isSeparatorItem,
                                           "enabled": item.isEnabled, "checked": item.state == .on]
                if let submenu = item.submenu { entry["children"] = entries(submenu) }
                return entry
            }
        }
        let hierarchy = try withSettingsMenu(in: view) { entries($0) }
        try JSONSerialization.data(withJSONObject: ["nativeMenuItems": hierarchy], options: [.prettyPrinted, .sortedKeys])
            .write(to: file)
    }

    private static func waitUntil(line: UInt = #line, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { throw CheckFailure("模拟流程等待超时（核验行 \(line)）") }
            try await Task.sleep(for: .milliseconds(50))
        }
        // Allow SwiftUI to publish refreshed accessibility state before the next native interaction.
        try await Task.sleep(for: .milliseconds(100))
    }

    private static func scrollToBottom(_ view: NSView) {
        if let scroll = view as? NSScrollView, let document = scroll.documentView {
            let y = document.isFlipped ? max(0, document.bounds.height - scroll.contentView.bounds.height) : 0
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            return
        }
        for child in view.subviews { scrollToBottom(child) }
    }

    private static func press(_ identifier: String, in view: NSView) throws {
        if ["launch-at-login", "automatic-refresh", "absolute-dates"].contains(identifier) {
            try activateSetting(identifier, in: view)
            return
        }
        if let element = find(identifier, in: view, depth: 0) {
            if let control = element as? NSControl { control.performClick(nil); return }
            let selector = NSSelectorFromString("accessibilityPerformPress")
            if element.responds(to: selector) {
                typealias Press = @convention(c) (AnyObject, Selector) -> Bool
                let action = unsafeBitCast(element.method(for: selector), to: Press.self)
                if action(element, selector) { return }
            }
        }
        debugTree(view, depth: 0)
        throw CheckFailure("无法触发原生控件：\(identifier)")
    }

    private static func debugTree(_ object: Any, depth: Int) {
        guard depth < 12 else { return }
        guard let element = object as? NSObject else { return }
        print(String(repeating: " ", count: depth), type(of: object), value("accessibilityIdentifier", of: element) as? String ?? "-",
              value("accessibilityLabel", of: element) as? String ?? "-")
        for child in value("accessibilityChildren", of: element) as? [Any] ?? [] { debugTree(child, depth: depth + 1) }
    }

    private static func find(_ identifier: String, in object: Any, depth: Int) -> NSObject? {
        guard depth < 30, let element = object as? NSObject else { return nil }
        if value("accessibilityIdentifier", of: element) as? String == identifier { return element }
        for child in value("accessibilityChildren", of: element) as? [Any] ?? [] {
            if let match = find(identifier, in: child, depth: depth + 1) { return match }
        }
        return nil
    }

    // SwiftUI virtual AX nodes implement selectors without declaring the full NSAccessibility protocol.
    private static func value(_ name: String, of object: NSObject) -> Any? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }
}

private struct NoNetworkFetcher: UsageFetching {
    func fetch(_ account: Account) async throws -> UsageSnapshot { throw UsageError.network }
}
