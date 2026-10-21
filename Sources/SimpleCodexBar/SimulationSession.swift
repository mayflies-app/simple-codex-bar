import Foundation
import Observation
import CodexUsageCore

/// The interactive demo cannot discover real credentials or launch the real Codex CLI.
@MainActor @Observable
final class SimulationSession {
    let repository: AccountRepository
    let store: AccountStore
    private(set) var busy = false
    private(set) var message: LocalizedText?
    let root: URL
    private let transport = SimulationTransport()
    private let runner = CodexLoginRunner()
    private let executable: URL
    private var serial = 2
    private var refreshClockOffset: TimeInterval = 0
    var refreshDate: Date { Date().addingTimeInterval(refreshClockOffset) }
    func advanceRefreshClock(by seconds: TimeInterval) { refreshClockOffset += seconds }
    @ObservationIgnored private var actionTask: Task<Void, Never>?

    init(root: URL? = nil) throws {
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("opencode/CodexBarSimulation-\(UUID())")
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        repository = try AccountRepository(root: self.root.appendingPathComponent("data"))
        store = AccountStore(repository: repository, fetcher: UsageService(repository: repository, transport: transport))
        executable = self.root.appendingPathComponent("fake-codex")
        try """
        #!/bin/sh
        printf '%s' "$CODEX_HOME" > "$CODEX_HOME/login-home.txt"
        printf '%s\\n' "$@" > "$CODEX_HOME/login-arguments.txt"
        /bin/cp "$CODEX_HOME/fixture-auth.json" "$CODEX_HOME/auth.json"
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func seed() async throws {
        _ = try await login(accountID: "sim-personal", userID: "sim-user-1", label: "个人模拟账号")
        let linked = root.appendingPathComponent("external-work.json")
        try Self.authData(accountID: "sim-work", userID: "sim-user-2").write(to: linked)
        _ = try await repository.addLinked(file: linked, label: "工作模拟账号")
        await store.load()
    }

    @discardableResult func addAccount() async throws -> Account {
        serial += 1
        let account = try await login(accountID: "sim-\(serial)", userID: "sim-user-\(serial)", label: "模拟账号 \(serial)")
        await store.load()
        store.refresh(account.id) // Explicit add is allowed even in manual-only mode.
        return account
    }

    func reauthenticate(_ account: Account) async throws {
        store.cancel(account.id)
        _ = try await login(accountID: account.identity.accountID, userID: account.identity.userID,
                            label: account.label, replacing: account.id)
        await store.load(); store.refresh(account.id)
    }

    func failNextRefresh() async {
        guard let work = store.rows.first(where: { $0.account.identity.accountID == "sim-work" }) else { return }
        await transport.failNext(work.account.identity.accountID)
        store.refresh(work.id)
    }

    func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; message = LocalizedText("simulation.working", table: "Dialogs")
        actionTask = Task {
            do { try await action(); message = nil }
            catch { message = (error as? UsageError)?.message ?? LocalizedText("simulation.failed", table: "Dialogs") }
            busy = false
            actionTask = nil
        }
    }

    func shutdown() async {
        actionTask?.cancel()
        await actionTask?.value
    }

    func cleanup() {
        for row in store.rows { store.cancel(row.id) }
        // Only this session's isolated fixture directory; never a real account directory.
        try? FileManager.default.removeItem(at: root)
    }

    private func login(accountID: String, userID: String, label: String, replacing id: UUID? = nil) async throws -> Account {
        let stage = try await repository.makeLoginDirectory()
        do {
            try Self.authData(accountID: accountID, userID: userID).write(to: stage.appendingPathComponent("fixture-auth.json"))
            try await runner.run(executable: executable, home: stage)
            let home = try String(contentsOf: stage.appendingPathComponent("login-home.txt"), encoding: .utf8)
            let arguments = try String(contentsOf: stage.appendingPathComponent("login-arguments.txt"), encoding: .utf8)
            guard home == stage.path, arguments == "-c\ncli_auth_credentials_store=\"file\"\nlogin\n" else {
                throw UsageError.loginFailed
            }
            return try await repository.finishLogin(directory: stage, label: label, replacing: id)
        } catch {
            try? await repository.discardLoginDirectory(stage)
            throw error
        }
    }

    private static func authData(accountID: String, userID: String) throws -> Data {
        let claims: [String: Any] = [
            "sub": userID, "exp": Int(Date().timeIntervalSince1970) + 86400,
            "https://api.openai.com/auth": ["chatgpt_account_id": accountID, "chatgpt_user_id": userID,
                                          "chatgpt_plan_type": accountID == "sim-work" ? "promax" : "plus"],
            "https://api.openai.com/profile": ["email": "demo@example.invalid"],
        ]
        let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return try JSONSerialization.data(withJSONObject: ["tokens": [
            "access_token": "simulation.\(payload).not-a-real-signature",
            "refresh_token": "simulation-only-\(UUID())", "account_id": accountID,
        ]])
    }
}

private actor SimulationTransport: HTTPTransport {
    private var counts: [String: Int] = [:]
    private var failures: Set<String> = []
    func failNext(_ accountID: String) { failures.insert(accountID) }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        guard request.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage",
              let token = request.value(forHTTPHeaderField: "Authorization"), token.hasPrefix("Bearer simulation."),
              let accountID = request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), accountID.hasPrefix("sim-") else {
            throw UsageError.invalidCredentials // Fail closed; there is no network fallback.
        }
        try await Task.sleep(for: .milliseconds(100))
        if failures.remove(accountID) != nil { return HTTPResponse(status: 503, data: Data()) }
        counts[accountID, default: 0] += 1
        let used = min(95, (accountID == "sim-work" ? 70 : 20) + (counts[accountID, default: 1] - 1) * 5)
        let now = Int(Date().timeIntervalSince1970)
        let data = try JSONSerialization.data(withJSONObject: [
            "account_id": accountID, "plan_type": accountID == "sim-work" ? "pro" : "plus",
            "rate_limit": [
                "primary_window": ["used_percent": used, "reset_at": now + 7200, "limit_window_seconds": 18000],
                "secondary_window": ["used_percent": 50, "reset_at": now + 172800, "limit_window_seconds": 604800],
            ],
            "credits": ["has_credits": true, "unlimited": false, "balance": "123.4567"],
            "individual_limit": ["limit": "1000", "used": "234.56789", "reset_at": now + 2592000],
        ])
        return HTTPResponse(status: 200, data: data)
    }
}
