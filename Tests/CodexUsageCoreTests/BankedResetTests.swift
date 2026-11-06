import Foundation
import Testing
@testable import CodexUsageCore

private let resetInventory = Data(#"{"available_count":2,"credits":[{"status":"available","expires_at":"2099-01-01T00:00:00.123456Z"},{"status":"available","expires_at":null},{"status":"redeemed","expires_at":"2099-01-01T00:00:00Z"},{"status":"future_status","expires_at":null}]}"#.utf8)

@Test func bankedResetInventoryDecodesOnlyAvailableUnexpiredCredits() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let balance = try BankedResets.decode(resetInventory, expectedAccountID: "workspace-a")
    #expect(balance.availableCount(at: now) == 2)
    #expect(balance.availableExpirations(at: now).count == 2)
    #expect(balance.availableExpirations(at: now).first! != nil)
    #expect(balance.availableCount(at: Date(timeIntervalSince1970: 4_200_000_000)) == 1)
    for body in [#"{}"#, #"{"available_count":true,"credits":[]}"#,
                 #"{"available_count":-1,"credits":[]}"#, #"{"available_count":1.5,"credits":[]}"#,
                 #"{"available_count":1,"credits":[{"status":"available","expires_at":"bad"}]}"#,
                 #"{"available_count":2,"credits":[]}"#] {
        #expect(throws: UsageError.invalidResponse) {
            try BankedResets.decode(Data(body.utf8), expectedAccountID: "workspace-a")
        }
    }
    #expect(throws: UsageError.identityChanged) {
        try BankedResets.decode(Data(#"{"account_id":"other","credits":[],"available_count":0}"#.utf8),
                               expectedAccountID: "workspace-a")
    }
    let zero = try BankedResets.decode(Data(#"{"credits":[],"available_count":0}"#.utf8), expectedAccountID: "workspace-a")
    #expect(zero.availableCount(at: now) == 0)
    let expired = try BankedResets.decode(Data(#"{"credits":[{"status":"available","expires_at":"2020-01-01T00:00:00Z"}],"available_count":1}"#.utf8), expectedAccountID: "workspace-a")
    #expect(expired.availableCount(at: now) == 0)
}

@Test func bankedResetFetchIsReadOnlyAccountScopedAndNeverRenewsOnSupplementFailure() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("auth.json")
    let original = try authData()
    try original.write(to: file)
    let repo = try AccountRepository(root: root.appendingPathComponent("app"))
    let account = try await repo.addLinked(file: file, label: "Mock")
    for response in [HTTPResponse(status: 200, data: resetInventory), .init(status: 401, data: Data()),
                     .init(status: 403, data: Data()), .init(status: 429, data: Data()),
                     .init(status: 503, data: Data()), .init(status: 200, data: Data(#"{}"#.utf8))] {
        let http = MockTransport([.init(status: 200, data: usageFixture), response])
        let snapshot = try await UsageService(repository: repo, transport: http).fetch(account)
        #expect(snapshot.windows[0].remainingPercent == 77)
        #expect((snapshot.bankedResets != nil) == (response.data == resetInventory))
        let requests = await http.recorded()
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
        let reset = try #require(requests.last)
        #expect(reset.url?.absoluteString == "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")
        #expect(reset.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "workspace-a")
        #expect(reset.value(forHTTPHeaderField: "Authorization") == requests[0].value(forHTTPHeaderField: "Authorization"))
        #expect(reset.value(forHTTPHeaderField: "OpenAI-Beta") == "codex-1")
        #expect(reset.value(forHTTPHeaderField: "originator") == "Codex Desktop")
        #expect(reset.timeoutInterval == 4)
        #expect(try Data(contentsOf: file) == original)
    }
}

@Test func bankedResetsPersistAndLegacySnapshotsRemainReadable() throws {
    let balance = try BankedResets.decode(resetInventory, expectedAccountID: "workspace-a")
    let snapshot = UsageSnapshot(plan: "plus", windows: [], bankedResets: balance)
    #expect(try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
    let old = Data(#"{"windows":[],"fetchedAt":0}"#.utf8)
    #expect(try JSONDecoder().decode(UsageSnapshot.self, from: old).bankedResets == nil)
    for count in [-1, 2] {
        let corrupt = Data("{\"reportedAvailableCount\":\(count),\"expirations\":[]}".utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(BankedResets.self, from: corrupt) }
    }
}

@Test func quotaRequestPolicyRejectsMutationsBeforeTransport() throws {
    for path in ["/wham/usage", "/wham/rate-limit-reset-credits", "/accounts/workspace-a/spend-controls/current-user/monthly-usage"] {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api" + path)!)
        request.httpMethod = "GET"
        try ReadOnlyUsageRequest.validate(request)
        for method in ["POST", "PUT", "PATCH", "DELETE"] {
            request.httpMethod = method
            #expect(throws: UsageError.invalidResponse) { try ReadOnlyUsageRequest.validate(request) }
        }
    }
    for path in ["/wham/rate-limit-reset-credits/consume", "/wham/reset", "/accounts/a/settings"] {
        let request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api" + path)!)
        #expect(throws: UsageError.invalidResponse) { try ReadOnlyUsageRequest.validate(request) }
    }
    var body = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
    body.httpBody = Data("{}".utf8)
    #expect(throws: UsageError.invalidResponse) { try ReadOnlyUsageRequest.validate(body) }
    for url in ["http://chatgpt.com/backend-api/wham/usage", "https://example.invalid/backend-api/wham/usage",
                "https://chatgpt.com/backend-api/wham/usage?action=reset"] {
        #expect(throws: UsageError.invalidResponse) { try ReadOnlyUsageRequest.validate(URLRequest(url: URL(string: url)!)) }
    }
}

@Test func managedInventoryUnauthorizedNeverRotatesCredentials() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try AccountRepository(root: root)
    let stage = try await repo.makeLoginDirectory()
    try authData().write(to: stage.appendingPathComponent("auth.json"))
    let account = try await repo.finishLogin(directory: stage, label: "Managed mock")
    let original = try await repo.readCredentials(account).data
    let http = MockTransport([.init(status: 200, data: usageFixture), .init(status: 401, data: Data())])
    let snapshot = try await UsageService(repository: repo, transport: http).fetch(account)
    #expect(snapshot.bankedResets == nil && snapshot.windows[0].remainingPercent == 77)
    #expect(await http.recorded().allSatisfy { $0.httpMethod == "GET" })
    #expect(await http.recorded().count == 2)
    #expect(try await repo.readCredentials(account).data == original)
}

@Test func resetOnlyAccountsPublishPositiveInventoryWithoutInventingQuotaOrZeroBalance() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("auth.json")
    try authData().write(to: file)
    let repo = try AccountRepository(root: root.appendingPathComponent("app"))
    let account = try await repo.addLinked(file: file, label: "Reset-only mock")
    let main = Data(#"{"account_id":"workspace-a","plan_type":"plus","rate_limit":null,"credits":null}"#.utf8)
    for (response, positive) in [
        (HTTPResponse(status: 200, data: resetInventory), true),
        (.init(status: 200, data: Data(#"{"available_count":0,"credits":[]}"#.utf8)), false),
        (.init(status: 200, data: Data(#"{"available_count":1,"credits":[{"status":"available","expires_at":"2020-01-01T00:00:00Z"}]}"#.utf8)), false),
        (.init(status: 200, data: Data(#"{}"#.utf8)), false),
        (.init(status: 503, data: Data()), false),
    ] {
        let http = MockTransport([.init(status: 200, data: main), response])
        let service = UsageService(repository: repo, transport: http)
        do {
            let reading = try await service.fetch(account)
            #expect(positive)
            #expect(reading.windows.isEmpty && reading.credits == nil)
            #expect(reading.bankedResets?.availableCount(at: Date()) == 2)
            try await repo.cacheUsage(reading, for: account)
            #expect(try await repo.cachedUsage(for: account) == reading)
        } catch {
            #expect(!positive)
            #expect(error as? UsageError == .invalidResponse)
        }
        let requests = await http.recorded()
        #expect(requests.count == 2 && requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
    }
}

@Test @MainActor func bankedResetCacheKeepsOldReadingOnMainFailureAndMarksSupplementFailureUnavailable() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("auth.json")
    try authData().write(to: file)
    let repo = try AccountRepository(root: root.appendingPathComponent("app"))
    let account = try await repo.addLinked(file: file, label: "Mock")
    let http = MockTransport([.init(status: 200, data: usageFixture), .init(status: 200, data: resetInventory),
                              .init(status: 503, data: Data()),
                              .init(status: 200, data: usageFixture), .init(status: 503, data: Data()),
                              .init(status: 200, data: usageFixture),
                              .init(status: 200, data: Data(#"{"account_id":"foreign","credits":[],"available_count":0}"#.utf8))])
    let store = AccountStore(repository: repo, fetcher: UsageService(repository: repo, transport: http))
    await store.load()
    store.refresh(account.id)
    await store.waitForRefreshes()
    let initial = try #require(store.rows[0].snapshot)
    #expect(initial.bankedResets?.availableCount(at: Date()) == 2)
    store.refresh(account.id)
    await store.waitForRefreshes()
    #expect(store.rows[0].snapshot == initial && store.rows[0].errorMessage != nil)
    #expect(try await repo.cachedUsage(for: account) == initial)
    store.refresh(account.id)
    await store.waitForRefreshes()
    #expect(store.rows[0].snapshot?.bankedResets == nil
            && store.rows[0].snapshot?.windows.map(\.remainingPercent) == initial.windows.map(\.remainingPercent))
    #expect(store.rows[0].errorMessage == nil)
    let recovered = try await repo.cachedUsage(for: account)
    #expect(recovered?.bankedResets == nil
            && recovered?.windows.map(\.remainingPercent) == initial.windows.map(\.remainingPercent))
    store.refresh(account.id)
    await store.waitForRefreshes()
    #expect(store.rows[0].snapshot == nil && store.rows[0].errorMessage == UsageError.identityChanged.message)
    #expect(try await repo.cachedUsage(for: account) == nil)
}
