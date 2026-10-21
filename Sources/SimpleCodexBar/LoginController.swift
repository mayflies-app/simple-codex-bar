import AppKit
import Foundation
import Observation
import CodexUsageCore

@MainActor @Observable
final class LoginController {
    private(set) var busy = false
    private(set) var message: LocalizedText?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let runner = CodexLoginRunner()
    @ObservationIgnored private let repository: AccountRepository
    @ObservationIgnored private let store: AccountStore
    @ObservationIgnored private let language: LanguageController

    init(repository: AccountRepository, store: AccountStore, language: LanguageController) {
        self.repository = repository; self.store = store; self.language = language
    }

    func start(replacing account: Account? = nil) {
        guard !busy else { return }
        guard let executable = findExecutable() ?? chooseExecutable() else { return }
        busy = true
        if let account {
            if let name = account.label.isEmpty ? account.identity.email : account.label {
                message = LocalizedText("login.browserAccount", name, table: "Dialogs")
            } else {
                message = LocalizedText("login.browserDefaultAccount", table: "Dialogs")
            }
        } else {
            message = LocalizedText("login.browserNewAccount", table: "Dialogs")
        }
        if let account { store.cancel(account.id) }
        task = Task {
            var directory: URL?
            do {
                let stage = try await repository.makeLoginDirectory()
                directory = stage
                try Task.checkCancellation()
                try await runner.run(executable: executable, home: stage)
                try Task.checkCancellation()
                let added = try await repository.finishLogin(directory: stage, label: "", replacing: account?.id)
                directory = nil
                await store.load()
                store.refresh(added.id)
                message = nil
            } catch is CancellationError { message = nil }
            catch {
                message = (error as? UsageError)?.message ?? UsageError.loginFailed.message
            }
            if let directory { try? await repository.discardLoginDirectory(directory) }
            busy = false
            task = nil
        }
    }

    func cancel() { task?.cancel() }

    func shutdown() async {
        task?.cancel()
        await task?.value
    }

    private func findExecutable() -> URL? {
        var paths: [String] = []
        if let configured = UserDefaults.standard.string(forKey: "CodexCLIPath") { paths.append(configured) }
        let envPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .filter { $0.hasPrefix("/") }.map { String($0) + "/codex" }
        paths += envPaths
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        paths += ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex",
                  "\(home)/.npm-global/bin/codex", "\(home)/.volta/bin/codex",
                  "/Applications/Codex.app/Contents/Resources/codex",
                  "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"]
        return paths.first(where: { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }

    private func chooseExecutable() -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = language.text("login.chooseCLI", table: "Dialogs")
        panel.message = language.text("login.cliNotFound", table: "Dialogs")
        panel.prompt = language.text("dialog.choose", table: "Dialogs")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        UserDefaults.standard.set(url.path, forKey: "CodexCLIPath")
        return url
    }
}
