import Foundation
import Darwin
import Testing
@testable import CodexUsageCore

@Test func managedRetryRejectsDirectorySwapBeforeAnyTokenExchange() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try AccountRepository(root: root.appendingPathComponent("app"))
    let stage = try await repo.makeLoginDirectory()
    try authData().write(to: stage.appendingPathComponent("auth.json"))
    let account = try await repo.finishLogin(directory: stage, label: "Retry fixture")
    let file = try await repo.readCredentials(account).file
    let home = file.deletingLastPathComponent()
    let external = root.appendingPathComponent("external-owner")
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    let foreign = try authData(expires: 1, refresh: "external-owner-r0")
    try foreign.write(to: external.appendingPathComponent("auth.json"))
    try Data("partial-auth-json".utf8).write(to: file)
    let http = MockTransport([])
    let service = UsageService(repository: repo, transport: http)
    // Task-local synchronization reaches the actual publication retry, without flaky sleeps or real credentials.
    await #expect(throws: UsageError.storage) {
        try await AccountRepository.$readRetryObserver.withValue({ observed in
            #expect(observed == file)
            try FileManager.default.moveItem(at: home, to: root.appendingPathComponent("preserved-private-home"))
            try FileManager.default.createSymbolicLink(at: home, withDestinationURL: external)
        }) {
            try await service.fetch(account)
        }
    }
    #expect(await http.recorded().isEmpty)
    #expect(try Data(contentsOf: external.appendingPathComponent("auth.json")) == foreign)
}

@Test func descriptorBoundIOCannotFollowRootReplacementIntoForeignFiles() throws {
    let base = try testRoot()
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appendingPathComponent("owned")
    let foreignRoot = base.appendingPathComponent("foreign")
    try PrivateFile.directory(root)
    try PrivateFile.directory(foreignRoot)
    let original = Data("private-original".utf8)
    let foreign = Data("foreign-must-not-be-read-or-overwritten".utf8)
    try original.write(to: root.appendingPathComponent("auth.json"))
    try foreign.write(to: foreignRoot.appendingPathComponent("auth.json"))
    let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    #expect(descriptor >= 0)
    guard descriptor >= 0 else { throw UsageError.storage }
    defer { close(descriptor) }
    let preserved = base.appendingPathComponent("preserved")
    try FileManager.default.moveItem(at: root, to: preserved)
    try FileManager.default.createSymbolicLink(at: root, withDestinationURL: foreignRoot)
    let file = root.appendingPathComponent("auth.json")
    #expect(try PrivateFile.readOwned(file, root: root, rootFD: descriptor) == original)
    let updated = Data("private-rotated".utf8)
    try PrivateFile.writeOwned(updated, to: file, root: root, rootFD: descriptor)
    #expect(try Data(contentsOf: preserved.appendingPathComponent("auth.json")) == updated)
    #expect(try Data(contentsOf: foreignRoot.appendingPathComponent("auth.json")) == foreign)
}

@Test func descriptorTraversalRejectsSymlinkParentAndLeaf() throws {
    let base = try testRoot()
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appendingPathComponent("owned")
    let foreign = base.appendingPathComponent("foreign")
    try PrivateFile.directory(root)
    try PrivateFile.directory(foreign)
    try Data("foreign-token".utf8).write(to: foreign.appendingPathComponent("auth.json"))
    let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw UsageError.storage }
    defer { close(fd) }
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("accounts"), withDestinationURL: foreign)
    #expect(throws: UsageError.storage) {
        try PrivateFile.readOwned(root.appendingPathComponent("accounts/auth.json"), root: root, rootFD: fd)
    }
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("auth.json"),
                                              withDestinationURL: foreign.appendingPathComponent("auth.json"))
    #expect(throws: UsageError.storage) {
        try PrivateFile.readOwned(root.appendingPathComponent("auth.json"), root: root, rootFD: fd)
    }
}

@Test func repositoryRejectsReplacedRootEvenWhenTheReplacementIsNotASymlink() async throws {
    let base = try testRoot()
    defer { try? FileManager.default.removeItem(at: base) }
    let repo = try AccountRepository(root: base.appendingPathComponent("app"))
    let stage = try await repo.makeLoginDirectory()
    try authData().write(to: stage.appendingPathComponent("auth.json"))
    let account = try await repo.finishLogin(directory: stage, label: "Root identity fixture")
    try FileManager.default.moveItem(at: repo.root, to: base.appendingPathComponent("preserved-root"))
    try PrivateFile.directory(repo.root)
    await #expect(throws: UsageError.storage) { try await repo.readCredentials(account) }
    await #expect(throws: UsageError.storage) { try await repo.remove(account.id) }
}

@Test func changedIDPrincipalRejectsRefreshBeforeWritingOrRequestingUsage() async throws {
    let base = try testRoot()
    defer { try? FileManager.default.removeItem(at: base) }
    let repo = try AccountRepository(root: base)
    let access = try jwt(["sub": "access-sub-a", "exp": 1,
                          "https://api.openai.com/auth": ["chatgpt_user_id": "user-a", "chatgpt_account_id": "default-workspace"]])
    let id = try jwt(["sub": "id-sub-a", "email": "a@example.invalid"])
    let original = try JSONSerialization.data(withJSONObject: ["tokens": [
        "access_token": access, "id_token": id, "refresh_token": "private-r0", "account_id": "selected-workspace",
    ]])
    let stage = try await repo.makeLoginDirectory()
    try original.write(to: stage.appendingPathComponent("auth.json"))
    let account = try await repo.finishLogin(directory: stage, label: "Principal fixture")
    let fresh = try jwt(["sub": "access-sub-a", "exp": Int(Date().timeIntervalSince1970) + 3600,
                         "https://api.openai.com/auth": ["chatgpt_user_id": "user-a", "chatgpt_account_id": "new-default-workspace"]])
    let foreignID = try jwt(["sub": "id-sub-b", "email": "b@example.invalid"])
    let body = try JSONSerialization.data(withJSONObject: ["access_token": fresh, "id_token": foreignID, "refresh_token": "private-r1"])
    let http = MockTransport([.init(status: 200, data: body)])
    await #expect(throws: UsageError.identityChanged) { try await UsageService(repository: repo, transport: http).fetch(account) }
    #expect(try await repo.readCredentials(account).data == original)
    #expect(await http.recorded().count == 1)

    // Token namespaces may differ; matching the old/new ID subject must not force JWT default workspace selection.
    let valid = try JSONSerialization.data(withJSONObject: ["access_token": fresh, "id_token": id, "refresh_token": "private-r1"])
    let usage = Data(#"{"account_id":"selected-workspace","plan_type":"plus","rate_limit":{"primary_window":{"used_percent":23}}}"#.utf8)
    let good = MockTransport([.init(status: 200, data: valid), .init(status: 200, data: usage)])
    let result = try await UsageService(repository: repo, transport: good).fetch(account)
    #expect(result.windows[0].remainingPercent == 77)
    #expect(try await repo.readCredentials(account).credentials.identity.accountID == "selected-workspace")
    #expect(await good.recorded().last?.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "selected-workspace")
}
