import Foundation
import Darwin

/// User-initiated login only. Codex opens the browser; tokens remain in the isolated file-backed home.
@MainActor
public final class CodexLoginRunner {
    private var process: Process?
    public init() {}

    public func run(executable: URL, home: URL, timeout: TimeInterval = 300) async throws {
        guard process == nil else { throw UsageError.loginFailed }
        try Task.checkCancellation()
        let child = Process()
        child.executableURL = executable
        child.arguments = ["-c", "cli_auth_credentials_store=\"file\"", "login"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home.path
        let inherited = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":").filter { $0.hasPrefix("/") }.map(String.init)
        environment["PATH"] = ([executable.deletingLastPathComponent().path,
                                 "/opt/homebrew/bin", "/usr/local/bin"] + inherited).joined(separator: ":")
        environment.removeValue(forKey: "OPENAI_API_KEY")
        environment.removeValue(forKey: "CODEX_API_KEY")
        child.environment = environment
        child.currentDirectoryURL = home
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        process = child
        do {
            try child.run()
            let deadline = Date().addingTimeInterval(timeout)
            while child.isRunning {
                try Task.checkCancellation()
                guard Date() < deadline else { throw UsageError.loginTimedOut }
                try await Task.sleep(for: .milliseconds(100))
            }
            try Task.checkCancellation()
            guard child.terminationStatus == 0 else { throw UsageError.loginFailed }
            process = nil
        } catch {
            await stop(child)
            process = nil
            if error is CancellationError { throw CancellationError() }
            throw (error as? UsageError) ?? UsageError.loginFailed
        }
    }

    private func stop(_ process: Process) async {
        guard process.isRunning else { return }
        process.terminate()
        // A cancelled login still needs a cleanup grace period, independent of its task cancellation.
        await Task.detached { try? await Task.sleep(for: .milliseconds(500)) }.value
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        await Task.detached { try? await Task.sleep(for: .milliseconds(100)) }.value
    }
}
