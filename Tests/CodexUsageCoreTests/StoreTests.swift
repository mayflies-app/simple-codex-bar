import Foundation
import Testing
@testable import CodexUsageCore

private actor DelayedFetcher: UsageFetching {
    private var continuation: CheckedContinuation<UsageSnapshot, Error>?
    private var calls = 0
    func fetch(_ account: Account) async throws -> UsageSnapshot {
        calls += 1
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func started() -> Bool { continuation != nil }
    func count() -> Int { calls }
    func complete() { continuation?.resume(returning: UsageSnapshot(plan: "plus", windows: [])); continuation = nil }
}

@Test @MainActor func duplicateRefreshesCoalesceAndRemovedRowsRejectLateResults() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("auth.json")
    try authData().write(to: file)
    let repository = try AccountRepository(root: root.appendingPathComponent("app"))
    let account = try await repository.addLinked(file: file, label: "")
    let fetcher = DelayedFetcher()
    let store = AccountStore(repository: repository, fetcher: fetcher)
    await store.load()
    store.refresh(account.id); store.refresh(account.id); store.refreshAll()
    while !(await fetcher.started()) { await Task.yield() }
    #expect(await fetcher.count() == 1)
    #expect(store.isRefreshing)
    await store.remove(account.id)
    await fetcher.complete()
    await Task.yield()
    #expect(store.rows.isEmpty)
    #expect(!store.isRefreshing)
}

@Test @MainActor func disablingAutomaticRefreshKeepsInflightResultAndManualActionAvailable() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("auth.json")
    try authData().write(to: file)
    let repository = try AccountRepository(root: root.appendingPathComponent("app"))
    _ = try await repository.addLinked(file: file, label: "")
    let fetcher = DelayedFetcher()
    let store = AccountStore(repository: repository, fetcher: fetcher)
    await store.load()
    let refresh = RefreshController(defaults: nil) { store.refreshAll() }
    defer { refresh.stop() }
    refresh.start()
    while !(await fetcher.started()) { await Task.yield() }
    refresh.setAutomaticRefreshEnabled(false)
    #expect(store.isRefreshing)
    await fetcher.complete()
    await store.waitForRefreshes()
    #expect(store.rows[0].snapshot != nil)
    #expect(store.rows[0].errorMessage == nil)
    refresh.handleWake()
    #expect(await fetcher.count() == 1)
    refresh.refreshManually()
    while !(await fetcher.started()) { await Task.yield() }
    #expect(await fetcher.count() == 2)
    await fetcher.complete()
    await store.waitForRefreshes()
}

@Test @MainActor func accountOptOutDuringRequestKeepsResultAndSkipsNextAutomaticRefresh() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("auth.json")
    try authData().write(to: file)
    let repository = try AccountRepository(root: root.appendingPathComponent("app"))
    let account = try await repository.addLinked(file: file, label: "")
    let fetcher = DelayedFetcher()
    let store = AccountStore(repository: repository, fetcher: fetcher)
    await store.load()
    store.refreshAutomatically()
    while !(await fetcher.started()) { await Task.yield() }
    await store.setAutomaticRefreshEnabled(account.id, enabled: false)
    #expect(store.rows[0].refreshing)
    await fetcher.complete()
    await store.waitForRefreshes()
    #expect(store.rows[0].snapshot != nil && !store.rows[0].refreshing)
    store.refreshAutomatically()
    await store.waitForRefreshes()
    #expect(await fetcher.count() == 1)
    store.refresh(account.id)
    while !(await fetcher.started()) { await Task.yield() }
    #expect(await fetcher.count() == 2)
    await fetcher.complete()
    await store.waitForRefreshes()
}
