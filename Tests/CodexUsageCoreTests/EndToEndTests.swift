import Foundation
import Testing
@testable import CodexUsageCore

private struct LoopbackTransport: HTTPTransport {
    let base: URL
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        // The production endpoint is fixed. Only this test adapter reroutes fake tokens to loopback.
        var request = request
        request.url = base.appendingPathComponent("usage")
        return try await URLSessionTransport().send(request)
    }
}

@Test @MainActor func multipleAccountsFromDiskThroughHTTPToVisibleState() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let ready = root.appendingPathComponent("ready.json")
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/usage_server.py")
    let server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    server.arguments = ["python3", script.path, "--ready-file", ready.path]
    server.standardOutput = FileHandle.nullDevice
    server.standardError = FileHandle.standardError
    try server.run()
    defer { if server.isRunning { server.terminate() } }
    let deadline = Date().addingTimeInterval(5)
    while !FileManager.default.fileExists(atPath: ready.path) {
        guard server.isRunning, Date() < deadline else { throw UsageError.network }
        try await Task.sleep(for: .milliseconds(50))
    }
    let portData = try JSONSerialization.jsonObject(with: Data(contentsOf: ready)) as! [String: Int]
    let base = URL(string: "http://127.0.0.1:\(portData["port"]!)")!
    let repository = try AccountRepository(root: root.appendingPathComponent("app"))
    let fileA = root.appendingPathComponent("a.json")
    let fileB = root.appendingPathComponent("b.json")
    let originalA = try authData()
    let originalB = try authData(account: "workspace-b", user: "user-b", email: "a@example.com")
    try originalA.write(to: fileA); try originalB.write(to: fileB)
    let a = try await repository.addLinked(file: fileA, label: "个人")
    let b = try await repository.addLinked(file: fileB, label: "工作")
    let store = AccountStore(repository: repository,
                             fetcher: UsageService(repository: repository, transport: LoopbackTransport(base: base)))
    await store.load()
    let refresh = RefreshController(defaults: nil, enabled: false) { store.refreshAll() }
    defer { refresh.stop() }
    refresh.start()
    refresh.handleWake()
    #expect(store.rows.allSatisfy { $0.snapshot == nil && !$0.refreshing })
    refresh.refreshManually()
    await store.waitForRefreshes()
    #expect(store.rows.count == 2)
    #expect(store.rows[0].snapshot?.windows[0].remainingPercent == 80)
    #expect(store.rows[1].snapshot?.windows[0].remainingPercent == 30)
    #expect(store.rows.allSatisfy { $0.errorMessage == nil && !$0.refreshing })

    // A partial failure retains that account's old reading, but never labels it as newly fetched.
    let oldB = store.rows[1].snapshot
    refresh.setAutomaticRefreshEnabled(true)
    await store.waitForRefreshes()
    refresh.setAutomaticRefreshEnabled(false)
    #expect(store.rows[0].errorMessage == nil)
    #expect(store.rows[1].errorMessage == UsageError.http(503).message)
    #expect(store.rows[1].snapshot == oldB)

    // Recovery clears the error and publishes the latest reading for B only.
    store.refresh(b.id)
    await store.waitForRefreshes()
    #expect(store.rows[1].errorMessage == nil)
    #expect(store.rows[1].snapshot?.windows[0].remainingPercent == 15)

    // A changed source identity must remove, not recycle, A's previously visible usage.
    try authData(account: "workspace-c").write(to: fileA)
    store.refresh(a.id)
    await store.waitForRefreshes()
    #expect(store.rows[0].snapshot == nil)
    #expect(store.rows[0].errorMessage != nil)
    await store.remove(a.id)
    #expect(store.rows.map(\.id) == [b.id])
    #expect(try Data(contentsOf: fileB) == originalB)
    #expect(FileManager.default.fileExists(atPath: fileA.path))

    // Reload retains identity, label, and only the latest successful cached usage.
    let reopenedView = AccountStore(repository: repository,
                                    fetcher: UsageService(repository: repository, transport: LoopbackTransport(base: base)))
    await reopenedView.load()
    #expect(reopenedView.rows.count == 1)
    #expect(reopenedView.rows[0].account.label == "工作")
    #expect(reopenedView.rows[0].snapshot == store.rows[0].snapshot)
    #expect(reopenedView.rows[0].restoredFromCache)
    let metadata = try JSONDecoder().decode([Account].self,
                                            from: Data(contentsOf: repository.root.appendingPathComponent("accounts.json")))
    #expect(metadata.map(\.id) == [b.id])

    let redirect = try await URLSessionTransport().send(URLRequest(url: base.appendingPathComponent("redirect")))
    #expect(redirect.status == 302)

    let artifact = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("TestResults")
    try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
    let report: [String: Any] = [
        "scenario": "multiple accounts → real loopback HTTP → visible state",
        "checked": ["same-email distinct workspaces", "per-account partial failure", "stale timestamp retained",
                    "recovery", "identity change clears usage", "remove preserves linked files",
                    "latest usage cache restored on reload", "HTTP redirects blocked",
                    "manual-only startup and wake", "manual refresh while automatic is off",
                    "enabling automatic refresh triggers account-scoped HTTP"],
        "fixture": "Tests/Fixtures/usage_server.py", "timestamp": ISO8601DateFormatter().string(from: Date()),
    ]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: artifact.appendingPathComponent("multi-account-flow.json"))
}
