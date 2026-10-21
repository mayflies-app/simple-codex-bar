import Foundation
import Testing
@testable import CodexUsageCore

private func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

@Test @MainActor func cliLoginIsIsolatedFileBackedAndCommittedWithoutTouchingSystemHome() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = try authData()
    let fixture = root.appendingPathComponent("original.json")
    try original.write(to: fixture)
    let executable = root.appendingPathComponent("fake codex")
    let script = """
    #!/bin/sh
    printf '%s\\n' "$@" > "$CODEX_HOME/arguments.txt"
    printf '%s' "$CODEX_HOME" > "$CODEX_HOME/home.txt"
    printf '%s' "$PATH" > "$CODEX_HOME/path.txt"
    cp \(shellQuote(fixture.path)) "$CODEX_HOME/auth.json"
    """
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let repository = try AccountRepository(root: root.appendingPathComponent("app"))
    let stage = try await repository.makeLoginDirectory()
    try await CodexLoginRunner().run(executable: executable, home: stage)
    #expect(try String(contentsOf: stage.appendingPathComponent("arguments.txt"), encoding: .utf8)
            == "-c\ncli_auth_credentials_store=\"file\"\nlogin\n")
    #expect(try String(contentsOf: stage.appendingPathComponent("home.txt"), encoding: .utf8) == stage.path)
    #expect(try String(contentsOf: stage.appendingPathComponent("path.txt"), encoding: .utf8).hasPrefix(root.path + ":"))
    let account = try await repository.finishLogin(directory: stage, label: "登录测试")
    #expect(account.isManaged)
    #expect(try await repository.readCredentials(account).data == original)
    #expect(!FileManager.default.fileExists(atPath: stage.path))
    #expect(try Data(contentsOf: fixture) == original)
    try await repository.remove(account.id)
    #expect(!FileManager.default.fileExists(atPath: repository.root.appendingPathComponent("accounts/\(account.id)").path))
}

@Test @MainActor func timedOutOrCancelledLoginStopsChildAndRunnerCanBeReused() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("fake-codex")
    let pidFile = root.appendingPathComponent("pid")
    try "#!/bin/sh\nprintf '%s' $$ > \(shellQuote(pidFile.path))\nexec /bin/sleep 20\n"
        .write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let runner = CodexLoginRunner()
    await #expect(throws: UsageError.loginTimedOut) {
        try await runner.run(executable: executable, home: root, timeout: 2)
    }
    let timedOutPID = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
    #expect(kill(timedOutPID, 0) == -1)
    try FileManager.default.removeItem(at: pidFile)
    let task = Task { try await runner.run(executable: executable, home: root) }
    let deadline = Date().addingTimeInterval(5)
    while !FileManager.default.fileExists(atPath: pidFile.path) {
        guard Date() < deadline else { task.cancel(); throw UsageError.loginFailed }
        try await Task.sleep(for: .milliseconds(20))
    }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    let cancelledPID = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
    #expect(kill(cancelledPID, 0) == -1)
}

@Test func processLockAndCorruptMetadataFailClosed() throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try AccountRepository(root: root.appendingPathComponent("app"))
    #expect(throws: UsageError.alreadyRunning) { try AccountRepository(root: repository.root) }
    let corrupt = root.appendingPathComponent("corrupt")
    try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: corrupt.appendingPathComponent("accounts.json"))
    #expect(throws: UsageError.storage) { try AccountRepository(root: corrupt) }
    // A failed initializer must release its lock, not erase unknown user data.
    #expect(throws: UsageError.storage) { try AccountRepository(root: corrupt) }
    #expect(try String(contentsOf: corrupt.appendingPathComponent("accounts.json"), encoding: .utf8) == "not json")
}
