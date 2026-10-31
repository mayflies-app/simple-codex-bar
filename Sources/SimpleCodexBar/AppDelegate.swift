import AppKit
import SwiftUI
import CodexUsageCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem?
    private let panel = StatusPanelWindow()
    private var panelHost: NSHostingController<UsagePopover>?
    private var repository: AccountRepository?
    private var store: AccountStore?
    private var login: LoginController?
    private var refreshController: RefreshController?
    private var activityMonitor: MacActivityMonitor?
    private var loginItem: LoginItemController?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var statusPressActive = false
    private var simulation: SimulationSession?
    private var demoWindow: NSWindow?
    private var startupTask: Task<Void, Never>?
    private var terminating = false
    private var terminationReady = false
    private let language: LanguageController
    private let fixtureDefaults: UserDefaults?
    private let dialogs: DialogPresenter

    private static var usesSimulation: Bool {
        ["--demo", "--verify-simulation", "--verify-shortcuts", "--verify-panel-appearance", "--verify-localization"]
            .contains(where: CommandLine.arguments.contains)
    }

    private static var localizationTestSuite: String? {
        guard CommandLine.arguments.contains("--verify-localization"),
              let suite = ProcessInfo.processInfo.environment["MACOS_LOCALIZATION_TEST_SUITE"] else { return nil }
        let prefix = "app.mayfiles.SimpleCodexBar.localization-test."
        guard suite.hasPrefix(prefix) else { return nil }
        let suffix = suite.dropFirst(prefix.count)
        guard suffix.count == 64, suffix.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return suite
    }

    private static func localizationTestDirectory() throws -> URL? {
        guard let index = CommandLine.arguments.firstIndex(of: "--verify-localization"),
              let directory = ProcessInfo.processInfo.environment["MACOS_LOCALIZATION_TEST_DIRECTORY"] else { return nil }
        guard CommandLine.arguments.indices.contains(index + 1), directory.hasPrefix("/") else {
            throw UsageError.storage
        }
        let supplied = URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath()
        let expected = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            .appendingPathComponent("fixture-data").standardizedFileURL.resolvingSymlinksInPath()
        guard supplied == expected else { throw UsageError.storage }
        return supplied
    }

    override init() {
        let demo = Self.usesSimulation
        let isolatedDefaults = Self.localizationTestSuite.flatMap { UserDefaults(suiteName: $0) }
        fixtureDefaults = isolatedDefaults
        language = LanguageController(defaults: demo ? isolatedDefaults : .standard,
                                      preferredLanguages: demo ? ["zh-Hans"] : Locale.preferredLanguages)
        dialogs = DialogPresenter(language: language)
        super.init()
        // Demo language overrides are isolated from the user's saved preference.
        if demo, let index = CommandLine.arguments.firstIndex(of: "--language"),
           CommandLine.arguments.indices.contains(index + 1),
           let selected = AppLanguage(rawValue: CommandLine.arguments[index + 1]) {
            language.setLanguage(selected)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Process-local AppKit preference, in milliseconds; no global defaults or persisted settings.
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["NSInitialToolTipDelay"] = 200
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        do {
            let demo = Self.usesSimulation
            let model: AccountStore
            if demo {
                let simulation = try SimulationSession(root: Self.localizationTestDirectory())
                self.simulation = simulation
                repository = simulation.repository
                model = simulation.store
            }
            else {
                let repo = try AccountRepository()
                repository = repo
                model = AccountStore(repository: repo, fetcher: UsageService(repository: repo))
                login = LoginController(repository: repo, store: model, language: language)
            }
            store = model
            let monitor = MacActivityMonitor { [weak self] state in self?.refreshController?.setActivity(state) }
            if !demo { activityMonitor = monitor }
            let activityProvider: (@MainActor () -> MacActivityState)? = demo ? nil : { @MainActor [weak monitor] in
                monitor?.currentState() ?? .sessionInactive
            }
            let refresh = RefreshController(defaults: demo ? fixtureDefaults : .standard,
                                            now: { [weak self] in self?.simulation?.refreshDate ?? Date() },
                                            activityProvider: activityProvider,
                                            onManualRefresh: { model.refreshAll() }) { model.refreshAutomatically() }
            refreshController = refresh
            if !demo { monitor.start() }
            let loginItem = LoginItemController(service: demo ? SimulationLoginItemService() : SystemLoginItemService())
            self.loginItem = loginItem
            let dates = DateDisplayController(defaults: demo ? fixtureDefaults : .standard)
            let view = UsagePopover(store: model, login: login, simulation: simulation, refreshController: refresh, loginItem: loginItem, dates: dates,
                                    language: language, languageChanged: { [weak self] in self?.updateLocalizedChrome() },
                                    addLinked: { [weak self] in self?.addLinked() },
                                    linkCurrent: { [weak self] in self?.linkCurrent() },
                                    rename: { [weak self] account in self?.rename(account) },
                                    remove: { [weak self] account in self?.remove(account) },
                                    reauthenticate: { [weak self] account in self?.reauthenticate(account) },
                                    heightChanged: { [weak self] height in self?.resizePanel(to: height) })
            let controller = NSHostingController(rootView: view)
            panelHost = controller
            let material = PanelMaterialController(content: controller,
                                                   forceStandard: CommandLine.arguments.contains("--standard-appearance"))
            panel.contentViewController = material
            panel.setContentSize(material.view.frame.size)
            panel.roundWindowFrame()
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            self.item = item
            if let button = item.button {
                button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: language.text("dialog.statusDescription", table: "Dialogs"))?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
                button.image?.isTemplate = true
                button.title = ""
                button.imagePosition = .imageOnly
                updateLocalizedChrome()
                button.target = self
                button.action = #selector(togglePanel)
                button.sendAction(on: [.leftMouseUp])
            }
            installPanelMonitors()
            startupTask = Task {
                do {
                    if let simulation { try await simulation.seed() }
                    await model.load()
                    try Task.checkCancellation()
                    refresh.start()
                } catch is CancellationError { }
                catch { showError(error) }
            }
            if demo { showDemo(controller: controller, material: material) }
        } catch {
            dialogs.message(title: LocalizedText("dialog.startupFailure", table: "Dialogs"),
                            detail: (error as? UsageError ?? .storage).message) {
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        removePanelMonitors()
        refreshController?.stop()
        activityMonitor?.stop()
        simulation?.cleanup()
        dialogs.dismiss()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationReady { return .terminateNow }
        guard repository != nil || login?.busy == true else { return .terminateNow }
        guard !terminating else { return .terminateCancel }
        terminating = true
        refreshController?.stop()
        activityMonitor?.stop()
        // Keep the normal main run loop alive while async CLI cancellation/cleanup completes.
        // terminateLater's AppKit termination loop can stall Swift main-actor continuations.
        Task {
            startupTask?.cancel()
            await startupTask?.value
            await simulation?.shutdown()
            await login?.shutdown()
            await repository?.shutdown()
            terminationReady = true
            sender.terminate(nil)
        }
        return .terminateCancel
    }

    func applicationDidBecomeActive(_ notification: Notification) { loginItem?.reload() }

    private func updateLocalizedChrome() {
        item?.button?.toolTip = nil
        item?.button?.setAccessibilityLabel(language.text("dialog.statusDescription", table: "Dialogs"))
        demoWindow?.title = language.text("dialog.demoTitle", table: "Dialogs")
        installMainMenu()
    }

    /// Accessory apps still need a main menu for standard text-system key equivalents.
    private func installMainMenu() {
        let main = NSMenu()
        func menu(_ title: String) -> NSMenu {
            let root = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            root.submenu = NSMenu(title: title)
            main.addItem(root)
            return root.submenu!
        }
        func add(_ menu: NSMenu, _ key: String, _ action: Selector, _ equivalent: String,
                 target: AnyObject? = nil, modifiers: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: language.text(key, table: "Dialogs"), action: action, keyEquivalent: equivalent)
            item.target = target
            item.keyEquivalentModifierMask = modifiers
            menu.addItem(item)
        }
        let app = menu("Simple Codex Bar")
        add(app, "menu.settings", #selector(showSettingsMenu), ",", target: self)
        app.addItem(.separator())
        add(app, "menu.quit", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        let file = menu(language.text("menu.file", table: "Dialogs"))
        add(file, "menu.close", #selector(closeKeyWindow), "w", target: self)
        let edit = menu(language.text("menu.edit", table: "Dialogs"))
        add(edit, "menu.undo", NSSelectorFromString("undo:"), "z")
        add(edit, "menu.redo", NSSelectorFromString("redo:"), "Z", modifiers: [.command, .shift])
        edit.addItem(.separator())
        add(edit, "menu.cut", #selector(NSText.cut(_:)), "x")
        add(edit, "menu.copy", #selector(NSText.copy(_:)), "c")
        add(edit, "menu.paste", #selector(NSText.paste(_:)), "v")
        add(edit, "menu.selectAll", #selector(NSText.selectAll(_:)), "a")
        NSApp.mainMenu = main
    }

    @objc private func closeKeyWindow() {
        guard let window = NSApp.keyWindow else { return }
        if window === panel { closePanel() }
        else { window.performClose(nil) }
    }

    @objc private func showSettingsMenu() {
        if !panel.isVisible { togglePanel() }
        guard let root = panelHost?.view else { return }
        // SwiftUI Menu has no imperative presentation API; use its native accessibility backing.
        func settingsCell(in object: NSObject, depth: Int = 0) -> NSPopUpButtonCell? {
            guard depth < 30 else { return nil }
            if let element = object as? NSAccessibilityProtocol,
               element.accessibilityIdentifier() == "settings-menu" {
                return (object as? NSPopUpButtonCell) ?? ((object as? NSControl)?.cell as? NSPopUpButtonCell)
            }
            let children = (object as? NSAccessibilityProtocol)?.accessibilityChildren() ?? []
            return children.lazy.compactMap { child in
                (child as? NSObject).flatMap { settingsCell(in: $0, depth: depth + 1) }
            }.first
        }
        guard let cell = settingsCell(in: root), let control = cell.controlView else { return }
        cell.performClick(withFrame: control.bounds, in: control)
    }

    private func closePanel() { panel.orderOut(nil) }

    private func reauthenticate(_ account: Account) {
        if let simulation { simulation.perform { try await simulation.reauthenticate(account) } }
        else { login?.start(replacing: account) }
    }

    @objc private func togglePanel() {
        guard item?.button?.window != nil else { return }
        if panel.isVisible { closePanel(); return }
        if let activityMonitor { refreshController?.setActivity(activityMonitor.currentState()) }
        loginItem?.reload()
        updatePanelHeightLimit()
        positionPanel()
        NSApp.unhideWithoutActivation()
        panel.makeKeyAndOrderFront(nil)
    }

    private func maximumPanelHeight() -> CGFloat {
        guard let button = item?.button, let window = button.window else {
            return StatusPanelWindow.maximumContentHeight
        }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        return min(StatusPanelWindow.maximumContentHeight, max(1, anchor.minY - visible.minY - 14))
    }

    private func updatePanelHeightLimit() {
        let maximum = maximumPanelHeight()
        panelHost?.rootView.maximumHeight = maximum
        if let canvas = panel.contentView as? ShadowedPanelView, canvas.surface.frame.height > maximum {
            resizePanel(to: maximum)
        }
    }

    private func resizePanel(to height: CGFloat) {
        let top = panel.frame.maxY
        let size = NSSize(width: StatusPanelWindow.contentWidth + ShadowedPanelView.shadowInset * 2,
                          height: min(height, maximumPanelHeight()) + ShadowedPanelView.shadowInset * 2)
        guard panel.contentView?.frame.size != size else { return }
        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: top - panel.frame.height))
        panel.contentView?.layoutSubtreeIfNeeded()
        if panel.isVisible { positionPanel() }
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        updatePanelHeightLimit()
        if panel.isVisible { positionPanel() }
    }

    private func positionPanel() {
        guard let button = item?.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let inset = ShadowedPanelView.shadowInset
        let x = max(visible.minX + 6 - inset, min(anchor.midX - panel.frame.width / 2, visible.maxX - panel.frame.width - 6 + inset))
        let y = max(visible.minY + 6 - inset, anchor.minY - panel.frame.height + inset - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func installPanelMonitors() {
        removePanelMonitors()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .keyDown]) { [weak self] event in
            let consume = MainActor.assumeIsolated {
                guard let self else { return false }
                if event.type == .leftMouseUp {
                    let handled = self.statusPressActive
                    self.statusPressActive = false
                    return handled || self.isStatusButtonEvent(event)
                }
                if self.isStatusButtonEvent(event), event.type == .leftMouseDown {
                    if !self.statusPressActive {
                        self.statusPressActive = true
                        self.togglePanel()
                    }
                    return true // Do not also dispatch the status button's target/action for this click.
                }
                guard self.panel.isVisible else { return false }
                if event.type == .keyDown {
                    // A nonactivating panel can receive keys while another app owns the menu bar.
                    // Keep Close scoped to this panel rather than the other app's active window.
                    let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
                    if event.window === self.panel || self.panel.isKeyWindow {
                        if event.charactersIgnoringModifiers?.lowercased() == "w" && modifiers == .command { self.closePanel(); return true }
                        if event.charactersIgnoringModifiers == "," && modifiers == .command {
                            self.showSettingsMenu(); return true
                        }
                    }
                    if event.keyCode == 53 { self.closePanel(); return true }
                    if event.keyCode == 48 && event.modifierFlags.contains(.command) { self.closePanel() }
                    return false
                }
                if event.window === self.panel {
                    if let canvas = self.panel.contentView as? ShadowedPanelView,
                       !canvas.containsSurface(canvas.convert(event.locationInWindow, from: nil)) {
                        self.closePanel()
                        return true
                    }
                    return false
                }
                if event.window?.level == .popUpMenu { return false }
                self.closePanel()
                return false
            }
            return consume ? nil : event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleGlobalPanelEvent(event)
            }
        }
    }

    // Global event copies may arrive before or after the status item's local events.
    func handleGlobalPanelEvent(_ event: NSEvent) {
        if event.type == .leftMouseUp { statusPressActive = false; return }
        if !isStatusButtonEvent(event) { closePanel() }
    }

    private func isStatusButtonEvent(_ event: NSEvent) -> Bool {
        guard let button = item?.button, let window = button.window else { return false }
        if event.window === window { return true }
        // The status-item window includes system-managed padding outside button.bounds.
        // Global copies have no local window identity, so protect the same full slot
        // that local status-window events already treat as one click target.
        let frame = window.frame.union(window.convertToScreen(button.convert(button.bounds, to: nil)))
        let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        return frame.insetBy(dx: -1, dy: -1).contains(point)
    }

    private func removePanelMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil; globalMonitor = nil
    }

    private func addLinked() {
        guard let repository, let store, login?.busy != true else { return }
        closePanel()
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = language.text("dialog.chooseAuthFile", table: "Dialogs")
        panel.message = language.text("dialog.authFileReadOnly", table: "Dialogs")
        panel.prompt = language.text("dialog.choose", table: "Dialogs")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let added = try await repository.addLinked(file: url, label: "")
                await store.load(); store.refresh(added.id)
                togglePanel()
            } catch { showError(error) }
        }
    }

    private func linkCurrent() {
        guard let repository, let store, login?.busy != true else { return }
        let environment = ProcessInfo.processInfo.environment
        let home = environment["CODEX_HOME"].flatMap { path -> URL? in
            guard path.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: path)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        Task {
            do {
                let added = try await repository.addLinked(file: home.appendingPathComponent("auth.json"), label: "")
                await store.load(); store.refresh(added.id)
            } catch { showError(error) }
        }
    }

    private func rename(_ account: Account) {
        closePanel()
        dialogs.rename(account) { [weak self] name in
            Task { await self?.store?.rename(account.id, label: name) }
        }
    }

    private func remove(_ account: Account) {
        closePanel()
        dialogs.confirmRemoval(account) { [weak self] in
            Task { await self?.store?.remove(account.id) }
        }
    }

    private func showError(_ error: Error) {
        closePanel()
        dialogs.message(title: LocalizedText("dialog.operationIncomplete", table: "Dialogs"),
                        detail: (error as? UsageError ?? .storage).message)
    }

    private func showDemo(controller: NSHostingController<UsagePopover>, material: PanelMaterialController) {
        // Same view as the panel; fake CLI + isolated fixture credentials, never real accounts.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: StatusPanelWindow.contentWidth,
                                                 height: StatusPanelWindow.minimumContentHeight),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = language.text("dialog.demoTitle", table: "Dialogs")
        // The status panel owns the material and content throughout the demo too.
        // A separate hosting view supplies the accessibility/screenshot harness.
        var demoView = controller.rootView
        let titleHeight = window.frame.height - window.contentRect(forFrameRect: window.frame).height
        demoView.maximumHeight = min(StatusPanelWindow.maximumContentHeight,
                                     (NSScreen.main?.visibleFrame.height ?? 800)
                                        - ShadowedPanelView.shadowInset * 2 - titleHeight - 12)
        demoView.heightChanged = { [weak window] height in
            guard let window else { return }
            let top = window.frame.maxY
            window.setContentSize(NSSize(width: StatusPanelWindow.contentWidth + ShadowedPanelView.shadowInset * 2,
                                         height: height + ShadowedPanelView.shadowInset * 2))
            let visible = (window.screen ?? NSScreen.main)?.visibleFrame
            let y = max(visible?.minY ?? -CGFloat.infinity,
                        min(top, visible?.maxY ?? top) - window.frame.height)
            window.setFrameOrigin(NSPoint(x: window.frame.minX, y: y))
        }
        let demoController = NSHostingController(rootView: demoView)
        window.contentViewController = PanelMaterialController(content: demoController,
                                                               forceStandard: CommandLine.arguments.contains("--standard-appearance"))
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        demoWindow = window
        if let index = CommandLine.arguments.firstIndex(of: "--verify-shortcuts"),
           CommandLine.arguments.indices.contains(index + 1), let simulation, let item {
            let output = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task {
                do {
                    try await SimulationVerifier.runShortcuts(session: simulation, item: item, panel: panel,
                        dialogs: dialogs, requestRename: { self.rename($0) }, requestRemove: { self.remove($0) },
                        output: output)
                    print("Keyboard shortcut verification passed: \(output.path)")
                    NSApp.terminate(nil)
                } catch {
                    print("Keyboard shortcut verification failed: \(error)")
                    refreshController?.stop()
                    await simulation.shutdown()
                    simulation.cleanup()
                    exit(1)
                }
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--verify-localization"),
           CommandLine.arguments.indices.contains(index + 1), let simulation, let item, let refreshController {
            let output = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task {
                do {
                    try await SimulationVerifier.runLocalization(session: simulation, language: language,
                        refresh: refreshController, item: item, panel: panel, view: demoController.view,
                        dialogs: dialogs, loginItem: controller.rootView.loginItem,
                        dates: controller.rootView.dates, output: output)
                    print("Localization checks passed: \(output.path)")
                    NSApp.terminate(nil)
                } catch {
                    print("Localization checks failed: \(error)")
                    refreshController.stop()
                    await simulation.shutdown()
                    simulation.cleanup()
                    exit(1)
                }
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--verify-panel-appearance"),
           CommandLine.arguments.indices.contains(index + 1), let simulation, let item {
            let output = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task {
                do {
                    try await SimulationVerifier.runAppearance(session: simulation, panel: panel, item: item, output: output)
                    print("Panel appearance checks passed: \(output.path)")
                    NSApp.terminate(nil)
                } catch {
                    print("Panel appearance checks failed: \(error)")
                    await simulation.shutdown()
                    simulation.cleanup()
                    exit(1)
                }
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--verify-simulation"),
           CommandLine.arguments.indices.contains(index + 1), let simulation, let refreshController, let item, let loginItem {
            let output = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task {
                do {
                    try await SimulationVerifier.run(session: simulation, refresh: refreshController, item: item,
                                                     panel: panel, view: demoController.view, dialogs: dialogs,
                                                     loginItem: loginItem,
                                                     dates: controller.rootView.dates,
                                                     material: material,
                                                     requestRename: { self.rename($0) }, requestRemove: { self.remove($0) },
                                                     output: output)
                    print("Native simulation verification passed: \(output.path)")
                    NSApp.terminate(nil)
                } catch {
                    print("Native simulation verification failed: \(error)")
                    refreshController.stop()
                    await simulation.shutdown()
                    simulation.cleanup()
                    exit(1)
                }
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--screenshot"),
           CommandLine.arguments.indices.contains(index + 1) {
            let path = CommandLine.arguments[index + 1]
            Task {
                await startupTask?.value
                await store?.waitForRefreshes()
                try? await Task.sleep(for: .milliseconds(200))
                do {
                    try NativeCapture.write(window.contentView!, to: URL(fileURLWithPath: path))
                    NSApp.terminate(nil)
                } catch {
                    simulation?.cleanup()
                    print("Screenshot write failed: \(error)")
                    exit(1)
                }
            }
        }
    }

}
