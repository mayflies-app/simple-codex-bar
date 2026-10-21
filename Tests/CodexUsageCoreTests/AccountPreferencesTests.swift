import Foundation
import Testing
@testable import CodexUsageCore

@Test func oldAccountMetadataDefaultsToAutomaticRefresh() throws {
    let account = Account(label: "old", identity: .init(accountID: "a", userID: "u", email: nil), source: .managed)
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(account)) as! [String: Any]
    object.removeValue(forKey: "automaticRefreshEnabled")
    let decoded = try JSONDecoder().decode(Account.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.automaticRefreshEnabled)
}

private actor RecordingFetcher: UsageFetching {
    private var requested: [UUID] = []
    func fetch(_ account: Account) async throws -> UsageSnapshot {
        requested.append(account.id)
        return UsageSnapshot(plan: "plus", windows: [])
    }
    func ids() -> [UUID] { requested }
}

@Test @MainActor func accountOrderAndRefreshOptOutPersistWithoutDisablingManualRefresh() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try AccountRepository(root: root.appendingPathComponent("app"))
    var accounts: [Account] = []
    for index in 0..<3 {
        let file = root.appendingPathComponent("auth-\(index).json")
        try authData(account: "workspace-\(index)", user: "user-\(index)").write(to: file)
        accounts.append(try await repository.addLinked(file: file, label: "Account \(index)"))
    }
    let fetcher = RecordingFetcher()
    let linkedBytes = try Data(contentsOf: root.appendingPathComponent("auth-1.json"))
    let store = AccountStore(repository: repository, fetcher: fetcher)
    await store.load()
    await store.move(accounts[2].id, by: -1)
    await store.move(accounts[2].id, by: -1)
    await store.move(accounts[2].id, by: -1) // Already first: leave order intact.
    await store.setAutomaticRefreshEnabled(accounts[1].id, enabled: false)
    #expect(store.rows.map(\.id) == [accounts[2].id, accounts[0].id, accounts[1].id])
    let reopened = AccountStore(repository: repository, fetcher: fetcher)
    await reopened.load()
    #expect(reopened.rows.map(\.id) == store.rows.map(\.id))
    #expect(reopened.rows.last?.account.automaticRefreshEnabled == false)
    let persisted = try JSONDecoder().decode([Account].self, from: Data(contentsOf: repository.root.appendingPathComponent("accounts.json")))
    #expect(persisted.map(\.id) == store.rows.map(\.id))
    #expect(persisted.last?.automaticRefreshEnabled == false)
    reopened.refreshAutomatically()
    await reopened.waitForRefreshes()
    #expect(Set(await fetcher.ids()) == Set([accounts[0].id, accounts[2].id]))
    reopened.refresh(accounts[1].id)
    await reopened.waitForRefreshes()
    #expect(await fetcher.ids().last == accounts[1].id)
    reopened.refreshAll()
    await reopened.waitForRefreshes()
    #expect(await fetcher.ids().count == 6)
    #expect(try Data(contentsOf: root.appendingPathComponent("auth-1.json")) == linkedBytes)
}

@Test func managedReloginPreservesRefreshOptOutAndOrder() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try AccountRepository(root: root.appendingPathComponent("app"))
    let stage = try await repository.makeLoginDirectory()
    try authData().write(to: stage.appendingPathComponent("auth.json"))
    let account = try await repository.finishLogin(directory: stage, label: "Saved")
    try await repository.setAutomaticRefreshEnabled(account.id, enabled: false)
    let next = try await repository.makeLoginDirectory()
    try authData().write(to: next.appendingPathComponent("auth.json"))
    let renewed = try await repository.finishLogin(directory: next, label: "Ignored", replacing: account.id)
    #expect(!renewed.automaticRefreshEnabled)
    #expect(renewed.label == "Saved")
}
