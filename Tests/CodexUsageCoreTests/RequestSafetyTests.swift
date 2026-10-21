import Foundation
import Testing
@testable import CodexUsageCore

private func managedAccount(_ repo: AccountRepository, expired: Bool = false) async throws -> Account {
    let stage = try await repo.makeLoginDirectory()
    try authData(expires: expired ? 1 : Date().timeIntervalSince1970 + 3600)
        .write(to: stage.appendingPathComponent("auth.json"))
    return try await repo.finishLogin(directory: stage, label: "Mock")
}

private func refreshFixture() throws -> Data {
    let access = try jwt(["sub": "user-a", "exp": Date().timeIntervalSince1970 + 3600,
                         "https://api.openai.com/auth": ["chatgpt_account_id": "workspace-a", "chatgpt_user_id": "user-a"]])
    return try JSONSerialization.data(withJSONObject: ["access_token": access, "refresh_token": "rotated-once"])
}

private actor RefreshBarrierTransport: HTTPTransport {
    let fresh: Data
    var barrier: CheckedContinuation<Void, Never>?
    var refreshCount = 0
    var usageCount = 0
    init(fresh: Data) { self.fresh = fresh }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        if request.url?.path == "/oauth/token" {
            refreshCount += 1
            // Every exchange waits briefly, allowing concurrent services to expose duplicate redemption.
            if refreshCount == 1 { await withCheckedContinuation { barrier = $0 } }
            return HTTPResponse(status: 200, data: fresh)
        }
        usageCount += 1
        return HTTPResponse(status: 200, data: usageFixture)
    }
    func started() -> Bool { barrier != nil }
    func release() { barrier?.resume(); barrier = nil }
    func counts() -> (Int, Int) { (refreshCount, usageCount) }
}

@Test func sharedRepositorySingleFlightPreventsRefreshReuseAcrossServicesAndCancellation() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try AccountRepository(root: root)
    let account = try await managedAccount(repo, expired: true)
    let transport = RefreshBarrierTransport(fresh: try refreshFixture())
    let firstService = UsageService(repository: repo, transport: transport)
    let secondService = UsageService(repository: repo, transport: transport)
    let first = Task { try await firstService.fetch(account) }
    let deadline = Date().addingTimeInterval(5)
    while !(await transport.started()) {
        guard Date() < deadline else { first.cancel(); throw UsageError.network }
        try await Task.sleep(for: .milliseconds(10))
    }
    let second = Task { try await secondService.fetch(account) }
    first.cancel()
    let third = Task { try await secondService.fetch(account) }
    try await Task.sleep(for: .milliseconds(100))
    await transport.release()
    await #expect(throws: CancellationError.self) { try await first.value }
    let b = try await second.value
    let c = try await third.value
    #expect(b == c)
    #expect(await transport.counts().0 == 1)
    #expect(await transport.counts().1 == 1)
    #expect(try await repo.readCredentials(account).credentials.refreshToken == "rotated-once")
}

@Test func freshWrongUserAndMalformedRotatedTokenNeverReplacePrivateCredentials() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try AccountRepository(root: root)
    let account = try await managedAccount(repo, expired: true)
    let original = try await repo.readCredentials(account).data
    let wrong = try jwt(["sub": "user-b", "https://api.openai.com/auth": ["chatgpt_user_id": "user-b"]])
    for body in [try JSONSerialization.data(withJSONObject: ["access_token": wrong, "refresh_token": "foreign-r"]),
                 Data(#"{"access_token":"opaque","refresh_token":42}"#.utf8)] {
        let http = MockTransport([.init(status: 200, data: body)])
        await #expect(throws: UsageError.self) { try await UsageService(repository: repo, transport: http).fetch(account) }
        #expect(try await repo.readCredentials(account).data == original)
        #expect(await http.recorded().count == 1)
    }
}

@Test func monthlyOnlyAccountAndPersonalPlanGatingDoNotFabricateLimits() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try AccountRepository(root: root)
    let account = try await managedAccount(repo)
    let monthly = Data(#"{"current_month_usage":200,"effective_monthly_limit":{"limit":1000}}"#.utf8)
    let team = MockTransport([.init(status: 200, data: Data(#"{"plan_type":"team","spend_control":{}}"#.utf8)),
                              .init(status: 200, data: monthly)])
    let result = try await UsageService(repository: repo, transport: team).fetch(account)
    #expect(result.windows.count == 1)
    #expect(result.windows[0].remainingPercent == 80)
    let personal = MockTransport([.init(status: 200, data: Data(#"{"plan_type":"plus","spend_control":{},"rate_limit":{"primary_window":{"used_percent":23}}}"#.utf8))])
    _ = try await UsageService(repository: repo, transport: personal).fetch(account)
    #expect(await personal.recorded().count == 1)
}

@Test func monthlyResponseScopeMismatchAndEncodedAccountPathStayIsolated() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try AccountRepository(root: root.appendingPathComponent("app"))
    let file = root.appendingPathComponent("external.json")
    try authData(account: "workspace/a?#%").write(to: file)
    let account = try await repo.addLinked(file: file, label: "")
    let http = MockTransport([
        .init(status: 200, data: Data(#"{"plan_type":"team","spend_control":{},"rate_limit":{"primary_window":{"used_percent":23}}}"#.utf8)),
        .init(status: 200, data: Data(#"{"account_id":null,"accountId":"foreign","current_month_usage":200,"effective_monthly_limit":{"limit":1000}}"#.utf8)),
    ])
    await #expect(throws: UsageError.identityChanged) { try await UsageService(repository: repo, transport: http).fetch(account) }
    let requests = await http.recorded()
    #expect(requests.last?.url?.absoluteString == "https://chatgpt.com/backend-api/accounts/workspace%2Fa%3F%23%25/spend-controls/current-user/monthly-usage")
    #expect(requests.last?.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "workspace/a?#%")
}

private actor ParallelQuotaTransport: HTTPTransport {
    var active = 0
    var peak = 0
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        active += 1; peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(100))
        let data = try JSONSerialization.data(withJSONObject: [
            "account_id": request.value(forHTTPHeaderField: "ChatGPT-Account-Id")!,
            "rate_limit": ["primary_window": ["used_percent": 23]],
        ])
        return HTTPResponse(status: 200, data: data)
    }
    func maximum() -> Int { peak }
}

@Test func separateAccountsRemainParallelWithSharedSingleFlightRepository() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try AccountRepository(root: root.appendingPathComponent("app"))
    var accounts: [Account] = []
    for scope in ["workspace-a", "workspace-b"] {
        let file = root.appendingPathComponent("\(scope).json")
        try authData(account: scope).write(to: file)
        accounts.append(try await repo.addLinked(file: file, label: scope))
    }
    let http = ParallelQuotaTransport()
    let service = UsageService(repository: repo, transport: http)
    async let a = service.fetch(accounts[0])
    async let b = service.fetch(accounts[1])
    _ = try await (a, b)
    #expect(await http.maximum() == 2)
}

@Test func managedHomeCannotBeAliasedToAnotherApplicationsCredentialDirectory() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try AccountRepository(root: root.appendingPathComponent("app"))
    let account = try await managedAccount(repo)
    let home = try await repo.readCredentials(account).file.deletingLastPathComponent()
    let external = root.appendingPathComponent("external-codex")
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    let data = try authData(refresh: "external-owner-token")
    try data.write(to: external.appendingPathComponent("auth.json"))
    try FileManager.default.removeItem(at: home)
    try FileManager.default.createSymbolicLink(at: home, withDestinationURL: external)
    await #expect(throws: UsageError.storage) { try await repo.readCredentials(account) }
    #expect(try Data(contentsOf: external.appendingPathComponent("auth.json")) == data)
}

private actor ShutdownFlag {
    var finished = false
    func mark() { finished = true }
    func value() -> Bool { finished }
}

@Test func orderlyShutdownFinishesIssuedRotationAndBlocksNewRequests() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try AccountRepository(root: root)
    let account = try await managedAccount(repo, expired: true)
    let transport = RefreshBarrierTransport(fresh: try refreshFixture())
    let service = UsageService(repository: repo, transport: transport)
    let fetch = Task { try await service.fetch(account) }
    let deadline = Date().addingTimeInterval(5)
    while !(await transport.started()) {
        guard Date() < deadline else { throw UsageError.network }
        try await Task.sleep(for: .milliseconds(10))
    }
    let flag = ShutdownFlag()
    let shutdown = Task { await repo.shutdown(); await flag.mark() }
    try await Task.sleep(for: .milliseconds(50))
    #expect(!(await flag.value()))
    await transport.release()
    await shutdown.value
    #expect(try await repo.readCredentials(account).credentials.refreshToken == "rotated-once")
    _ = try await fetch.value
    await #expect(throws: CancellationError.self) { try await service.fetch(account) }
    #expect(await transport.counts().0 == 1)
}

@Test func usageForbiddenAndThrottledNeverRotateOrLeakResponseBodies() async throws {
    for status in [403, 429] {
        let root = try testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try AccountRepository(root: root)
        let account = try await managedAccount(repo)
        let original = try await repo.readCredentials(account).data
        let transport = MockTransport([.init(status: status, data: Data("secret-token-and-body".utf8))])
        await #expect(throws: UsageError.http(status)) {
            try await UsageService(repository: repo, transport: transport).fetch(account)
        }
        #expect(await transport.recorded().count == 1)
        #expect(try await repo.readCredentials(account).data == original)
        #expect(!UsageError.http(status).localizedDescription.contains("secret"))
    }
}

@Test func refreshErrorCodesDistinguishRevocationFromClientOrPolicyFailure() async throws {
    for (status, code, expected) in [(400, "invalid_grant", UsageError.reauthenticationRequired),
                                    (403, "refresh_token_reused", .reauthenticationRequired),
                                    (400, "invalid_client", .http(400)),
                                    (403, "policy_denied", .http(403))] {
        let root = try testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try AccountRepository(root: root)
        let account = try await managedAccount(repo, expired: true)
        let original = try await repo.readCredentials(account).data
        let body = try JSONSerialization.data(withJSONObject: ["error": ["code": code, "message": "secret"]])
        let transport = MockTransport([.init(status: status, data: body)])
        await #expect(throws: expected) { try await UsageService(repository: repo, transport: transport).fetch(account) }
        #expect(try await repo.readCredentials(account).data == original)
    }
}

@Test func teamMonthlyUsageIsAccountScopedAndOptionalFailuresPreserveMainQuota() async throws {
    let primary = Data(#"{"plan_type":"team","spend_control":{},"rate_limit":{"primary_window":{"used_percent":23}}}"#.utf8)
    let monthly = Data(#"{"current_month_usage":"200","effective_monthly_limit":{"limit":"1000","enforcement_mode":"hard"}}"#.utf8)
    for (status, data, expectedCount) in [(200, monthly, 2), (503, Data(), 1),
                                        (200, Data(#"{"effective_monthly_limit":{"limit":1000}}"#.utf8), 1),
                                        (200, Data(#"{"current_month_usage":200,"effective_monthly_limit":{"limit":1000,"enforcement_mode":"off"}}"#.utf8), 1)] {
        let root = try testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try AccountRepository(root: root)
        let account = try await managedAccount(repo)
        let transport = MockTransport([.init(status: 200, data: primary), .init(status: status, data: data)])
        let snapshot = try await UsageService(repository: repo, transport: transport).fetch(account)
        #expect(snapshot.windows.count == expectedCount)
        #expect(snapshot.windows[0].remainingPercent == 77)
        if expectedCount == 2 { #expect(snapshot.windows.dropFirst().first?.remainingPercent == 80) }
        let requests = await transport.recorded()
        #expect(requests.count == 2)
        #expect(requests.last?.url?.path == "/backend-api/accounts/workspace-a/spend-controls/current-user/monthly-usage")
        #expect(requests.last?.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "workspace-a")
        #expect(requests.last?.timeoutInterval == 4)
    }
}

private actor MetadataChangingTransport: HTTPTransport {
    let file: URL
    let fresh: Data
    var requests: [URLRequest] = []
    init(file: URL, fresh: Data) { self.file = file; self.fresh = fresh }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        if requests.count == 1 {
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            object["metadata"] = "owner write unrelated to tokens"
            try JSONSerialization.data(withJSONObject: object).write(to: file, options: .atomic)
        }
        if request.url?.path == "/oauth/token" { return HTTPResponse(status: 200, data: fresh) }
        return HTTPResponse(status: requests.count <= 2 ? 401 : 200, data: usageFixture)
    }
    func count() -> Int { requests.count }
}

@Test func rereadAfter401DoesNotSkipTheOneManagedRefresh() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try AccountRepository(root: root)
    let account = try await managedAccount(repo)
    let file = try await repo.readCredentials(account).file
    let transport = MetadataChangingTransport(file: file, fresh: try refreshFixture())
    let result = try await UsageService(repository: repo, transport: transport).fetch(account)
    #expect(result.windows[0].remainingPercent == 77)
    #expect(await transport.count() == 4)
}
