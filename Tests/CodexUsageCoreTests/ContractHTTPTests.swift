import Foundation
import Testing
@testable import CodexUsageCore

private struct ContractLoopbackTransport: HTTPTransport {
    let base: URL
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        guard let original = request.url,
              let host = original.host, ["chatgpt.com", "auth.openai.com"].contains(host), original.scheme == "https" else {
            throw UsageError.invalidCredentials
        }
        var destination = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        destination.percentEncodedPath = URLComponents(url: original, resolvingAgainstBaseURL: false)!.percentEncodedPath
        var request = request
        request.url = destination.url
        return try await URLSessionTransport().send(request)
    }
}

@Test @MainActor func auditedCodexContractThroughRealLoopbackOAuthAndMonthlyHTTP() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let ready = root.appendingPathComponent("ready.json")
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/codex_contract_server.py")
    let server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    server.arguments = ["python3", script.path, "--ready-file", ready.path]
    server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.standardError
    try server.run()
    defer { if server.isRunning { server.terminate() } }
    let deadline = Date().addingTimeInterval(5)
    while !FileManager.default.fileExists(atPath: ready.path) {
        guard server.isRunning, Date() < deadline else { throw UsageError.network }
        try await Task.sleep(for: .milliseconds(20))
    }
    let port = try JSONSerialization.jsonObject(with: Data(contentsOf: ready)) as! [String: Int]
    let base = URL(string: "http://127.0.0.1:\(port["port"]!)")!
    let repo = try AccountRepository(root: root.appendingPathComponent("app"))
    let stage = try await repo.makeLoginDirectory()
    try authData(expires: 1, refresh: "loopback-r0").write(to: stage.appendingPathComponent("auth.json"))
    let account = try await repo.finishLogin(directory: stage, label: "HTTP mock")
    let transport = ContractLoopbackTransport(base: base)
    let service = UsageService(repository: repo, transport: transport)
    let otherService = UsageService(repository: repo, transport: transport)
    async let first = service.fetch(account)
    async let second = otherService.fetch(account)
    let (a, b) = try await (first, second)
    #expect(a == b)
    #expect(a.windows.map(\.remainingPercent) == [77, 39, 91, 80])
    #expect(a.windows.map(\.title) == ["5 小时", "每周", "Spark · 5 小时", "每月额度"])
    #expect(a.windows.last?.resetsAt == nil)
    #expect(try await repo.readCredentials(account).credentials.refreshToken == "loopback-r1")

    var checks = ["single-flight across two services over real HTTP", "OAuth POST body and private rotation",
                  "nullable account aliases", "reversed weekly/session slots", "mixed lossy Spark array",
                  "account-scoped monthly supplement without invented reset"]
    for (scope, status) in [("workspace-forbidden", 403), ("workspace-throttled", 429)] {
        let file = root.appendingPathComponent("\(scope).json")
        let original = try authData(account: scope)
        try original.write(to: file)
        let linked = try await repo.addLinked(file: file, label: scope)
        await #expect(throws: UsageError.http(status)) { try await service.fetch(linked) }
        #expect(try Data(contentsOf: file) == original)
        #expect(!UsageError.http(status).localizedDescription.contains("secret-sentinel"))
    }
    checks.append("403/429 do not rotate external tokens or expose response bodies")
    let failureFile = root.appendingPathComponent("monthly-failure.json")
    try authData(account: "workspace-monthly-failure").write(to: failureFile)
    let optionalFailure = try await repo.addLinked(file: failureFile, label: "optional failure")
    let partial = try await service.fetch(optionalFailure)
    #expect(partial.windows.count == 2)
    #expect(partial.notice != nil)
    #expect(partial.windows[0].remainingPercent == 77)
    checks.append("monthly HTTP 503 preserves main quota and marks unavailable data")
    let wrongFile = root.appendingPathComponent("wrong.json")
    try authData(account: "workspace-bad-identity").write(to: wrongFile)
    let wrong = try await repo.addLinked(file: wrongFile, label: "wrong identity")
    await #expect(throws: UsageError.identityChanged) { try await service.fetch(wrong) }
    checks.append("identity mismatch hidden behind JSON null is rejected before publication")

    let redirect = try await URLSessionTransport().send(URLRequest(url: base.appendingPathComponent("redirect-contract")))
    #expect(redirect.status == 302)
    let audit = try await URLSessionTransport().send(URLRequest(url: base.appendingPathComponent("audit")))
    let object = try JSONSerialization.jsonObject(with: audit.data) as! [String: Any]
    let requests = object["requests"] as! [[String: Any]]
    let oauth = requests.filter { $0["path"] as? String == "/oauth/token" }
    #expect(oauth.count == 1)
    #expect(oauth.first?["oauthContractValid"] as? Bool == true)
    #expect(!requests.contains { $0["path"] as? String == "/unexpected-target" })
    let gets = requests.filter { $0["fakeBearer"] as? Bool == true }
    #expect(gets.allSatisfy { $0["method"] as? String == "GET" && $0["accept"] as? String == "application/json"
        && $0["hasCookie"] as? Bool == false && $0["userAgent"] as? String == "SimpleCodexBar" })
    checks.append("ephemeral cookie-free GET headers and HTTP redirects blocked")
    let results = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("TestResults")
    try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
    let report: [String: Any] = ["passed": true, "checked": checks, "requests": requests,
        "upstreamRevision": "9699239f0ddc16777c84e5cc6116e526e9a4f71a",
        "realAccountsAccessed": false, "externalNetworkUsed": false,
        "timestamp": ISO8601DateFormatter().string(from: Date())]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: results.appendingPathComponent("codex-http-contract.json"))
}
