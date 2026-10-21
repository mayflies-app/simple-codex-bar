import Foundation
import Testing
@testable import CodexUsageCore

actor MockTransport: HTTPTransport {
    private var responses: [HTTPResponse]
    private var requests: [URLRequest] = []
    init(_ responses: [HTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw UsageError.network }
        return responses.removeFirst()
    }
    func recorded() -> [URLRequest] { requests }
}

func testRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("opencode/SimpleCodexBarTests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func linkedAccountsStayReadOnlyAndRequestsRemainAccountScoped() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("external")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let file = home.appendingPathComponent("auth.json")
    let original = try authData(expires: 1)
    try original.write(to: file)
    let repository = try AccountRepository(root: root.appendingPathComponent("app"))
    let account = try await repository.addLinked(file: file, label: "Personal")
    let http = MockTransport([HTTPResponse(status: 200, data: usageFixture)])
    let service = UsageService(repository: repository, transport: http)
    let result = try await service.fetch(account)
    #expect(result.windows[0].remainingPercent == 77)
    #expect(try Data(contentsOf: file) == original)
    let requests = await http.recorded()
    #expect(requests.count == 1)
    #expect(requests[0].value(forHTTPHeaderField: "ChatGPT-Account-Id") == "workspace-a")
    #expect(requests[0].url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
}

@Test func managedLoginRefreshesPrivatelyAndPersistsRotatedToken() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try AccountRepository(root: root.appendingPathComponent("app"))
    let stage = try await repo.makeLoginDirectory()
    try authData(expires: 1).write(to: stage.appendingPathComponent("auth.json"))
    let account = try await repo.finishLogin(directory: stage, label: "Managed")
    let freshAccess = try jwt([
        "exp": Date().timeIntervalSince1970 + 3600, "sub": "user-a",
        "https://api.openai.com/auth": ["chatgpt_account_id": "workspace-a", "chatgpt_user_id": "user-a"],
    ])
    let refreshResponse = try JSONSerialization.data(withJSONObject: [
        "access_token": freshAccess, "refresh_token": "rotated-private-token",
    ])
    let http = MockTransport([HTTPResponse(status: 200, data: refreshResponse),
                              HTTPResponse(status: 200, data: usageFixture)])
    let service = UsageService(repository: repo, transport: http)
    _ = try await service.fetch(account)
    let saved = try await repo.readCredentials(account)
    #expect(saved.credentials.refreshToken == "rotated-private-token")
    let requests = await http.recorded()
    #expect(requests.count == 2)
    #expect(requests[0].url?.host == "auth.openai.com")
    #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer \(freshAccess)")
    let metadata = try String(contentsOf: repo.root.appendingPathComponent("accounts.json"), encoding: .utf8)
    #expect(!metadata.contains("rotated-private-token"))
    let attributes = try FileManager.default.attributesOfItem(atPath: saved.file.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func linkedUnauthorizedDoesNotRotateSharedRefreshTokens() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("auth.json")
    let data = try authData()
    try data.write(to: file)
    let repo = try AccountRepository(root: root.appendingPathComponent("app"))
    let account = try await repo.addLinked(file: file, label: "")
    let http = MockTransport([HTTPResponse(status: 401, data: Data())])
    let service = UsageService(repository: repo, transport: http)
    await #expect(throws: UsageError.self) { try await service.fetch(account) }
    #expect(await http.recorded().count == 1)
    #expect(try Data(contentsOf: file) == data)
}

@Test func changedExternalIdentityIsNotSilentlyPublished() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("auth.json")
    try authData().write(to: file)
    let repo = try AccountRepository(root: root.appendingPathComponent("app"))
    let account = try await repo.addLinked(file: file, label: "")
    try authData(account: "workspace-b").write(to: file)
    let http = MockTransport([])
    let service = UsageService(repository: repo, transport: http)
    await #expect(throws: UsageError.self) { try await service.fetch(account) }
    #expect(await http.recorded().isEmpty)
}

@Test func duplicateIdentityAndWrongReauthenticationAreRejected() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try AccountRepository(root: root.appendingPathComponent("app"))
    let stage = try await repo.makeLoginDirectory()
    try authData().write(to: stage.appendingPathComponent("auth.json"))
    let account = try await repo.finishLogin(directory: stage, label: "one")
    let other = try await repo.makeLoginDirectory()
    try authData(account: "wrong").write(to: other.appendingPathComponent("auth.json"))
    await #expect(throws: UsageError.self) {
        try await repo.finishLogin(directory: other, label: "", replacing: account.id)
    }
    #expect(try await repo.readCredentials(account).credentials.identity.key == account.identity.key)
    try authData().write(to: other.appendingPathComponent("auth.json"))
    await #expect(throws: UsageError.self) { try await repo.finishLogin(directory: other, label: "two") }
}

@Test func removeLinkedAccountNeverDeletesUserCredentials() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("auth.json")
    try authData().write(to: file)
    let repo = try AccountRepository(root: root.appendingPathComponent("app"))
    let account = try await repo.addLinked(file: file, label: "")
    try await repo.remove(account.id)
    #expect(await repo.accounts().isEmpty)
    #expect(FileManager.default.fileExists(atPath: file.path))
}

@Test func concurrentPublicationCannotOverwriteNewLoginOrRemovedAccount() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try AccountRepository(root: root.appendingPathComponent("app"))
    let stage = try await repo.makeLoginDirectory()
    try authData().write(to: stage.appendingPathComponent("auth.json"))
    let account = try await repo.finishLogin(directory: stage, label: "")
    let old = try await repo.readCredentials(account)
    let reauth = try await repo.makeLoginDirectory()
    try authData(refresh: "new-login").write(to: reauth.appendingPathComponent("auth.json"))
    _ = try await repo.finishLogin(directory: reauth, label: "", replacing: account.id)
    await #expect(throws: UsageError.self) {
        try await repo.replaceCredentials(account, original: old.data, updated: old.data)
    }
    try await repo.remove(account.id)
    await #expect(throws: UsageError.self) { try await repo.readCredentials(account) }
}

@Test func managedUnauthorizedRetriesOnlyOnceAfterPrivateRefresh() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try AccountRepository(root: root.appendingPathComponent("app"))
    let stage = try await repo.makeLoginDirectory()
    try authData().write(to: stage.appendingPathComponent("auth.json"))
    let account = try await repo.finishLogin(directory: stage, label: "")
    let access = try jwt(["sub": "user-a", "exp": Date().timeIntervalSince1970 + 3600,
                          "https://api.openai.com/auth": ["chatgpt_user_id": "user-a", "chatgpt_account_id": "workspace-a"]])
    let data = try JSONSerialization.data(withJSONObject: ["access_token": access, "refresh_token": "rotated"])
    let http = MockTransport([.init(status: 401, data: Data()), .init(status: 200, data: data),
                              .init(status: 401, data: Data("do-not-expose-secrets".utf8))])
    let service = UsageService(repository: repo, transport: http)
    await #expect(throws: UsageError.reauthenticationRequired) { try await service.fetch(account) }
    #expect(await http.recorded().count == 3)
    #expect(try await repo.readCredentials(account).credentials.refreshToken == "rotated")
    #expect(!UsageError.reauthenticationRequired.localizedDescription.contains("do-not-expose"))
}

@Test func failedPrivateRefreshLeavesCredentialsUnchanged() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try AccountRepository(root: root.appendingPathComponent("app"))
    let stage = try await repo.makeLoginDirectory()
    let original = try authData(expires: 1)
    try original.write(to: stage.appendingPathComponent("auth.json"))
    let account = try await repo.finishLogin(directory: stage, label: "")
    for response in [HTTPResponse(status: 400, data: Data()),
                     HTTPResponse(status: 200, data: Data(#"{"refresh_token":"r"}"#.utf8))] {
        let http = MockTransport([response])
        let service = UsageService(repository: repo, transport: http)
        await #expect(throws: UsageError.self) { try await service.fetch(account) }
        #expect(try await repo.readCredentials(account).data == original)
        #expect(await http.recorded().count == 1)
    }
}

private actor SourceChangingTransport: HTTPTransport {
    let file: URL
    let updated: Data
    let initialStatus: Int
    var count = 0
    init(file: URL, updated: Data, initialStatus: Int) {
        self.file = file; self.updated = updated; self.initialStatus = initialStatus
    }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        count += 1
        if count == 1 {
            try updated.write(to: file, options: .atomic)
            return HTTPResponse(status: initialStatus, data: usageFixture)
        }
        return HTTPResponse(status: 200, data: usageFixture)
    }
    func calls() -> Int { count }
}

@Test func linkedUnauthorizedCanRecoverFromOwnerRenewalWithoutRotatingItself() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try AccountRepository(root: root.appendingPathComponent("app"))
    let file = root.appendingPathComponent("auth.json")
    try authData().write(to: file)
    let account = try await repo.addLinked(file: file, label: "")
    let updated = try authData(refresh: "owner-renewed")
    let http = SourceChangingTransport(file: file, updated: updated, initialStatus: 401)
    let service = UsageService(repository: repo, transport: http)
    let result = try await service.fetch(account)
    #expect(result.windows[0].remainingPercent == 77)
    #expect(await http.calls() == 2)
    #expect(try Data(contentsOf: file) == updated)
}

@Test func identityChangedDuringHTTPRejectsLatePublication() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try AccountRepository(root: root.appendingPathComponent("app"))
    let file = root.appendingPathComponent("auth.json")
    try authData().write(to: file)
    let account = try await repo.addLinked(file: file, label: "")
    let http = SourceChangingTransport(file: file, updated: try authData(user: "different-user"), initialStatus: 200)
    let service = UsageService(repository: repo, transport: http)
    await #expect(throws: UsageError.identityChanged) { try await service.fetch(account) }
}
