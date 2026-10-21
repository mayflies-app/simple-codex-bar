import Foundation
import Testing
@testable import CodexUsageCore

private actor CacheFetcher: UsageFetching {
    var result: Result<UsageSnapshot, UsageError>
    var requests = 0
    init(_ result: Result<UsageSnapshot, UsageError>) { self.result = result }
    func fetch(_ account: Account) throws -> UsageSnapshot { requests += 1; return try result.get() }
    func fail(_ error: UsageError) { result = .failure(error) }
    func count() -> Int { requests }
}

@Test @MainActor func latestUsageSurvivesRepositoryRelaunchAndFailureButNotIdentityChange() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let external = root.appendingPathComponent("auth.json")
    try authData().write(to: external)
    let snapshot = UsageSnapshot(plan: "pro", windows: [.init(id: "weekly", title: "每周", usedPercent: 12.345,
                                resetsAt: Date(timeIntervalSince1970: 1800000000))],
                                fetchedAt: Date(timeIntervalSince1970: 1700000000),
                                credits: .init(balance: 123.4567, hasCredits: true, unlimited: false), authPlan: "promax")
    func firstLaunch() async throws -> Account {
        let repo = try AccountRepository(root: root.appendingPathComponent("app"))
        let account = try await repo.addLinked(file: external, label: "Saved")
        let store = AccountStore(repository: repo, fetcher: CacheFetcher(.success(snapshot)))
        await store.load()
        store.refresh(account.id)
        await store.waitForRefreshes()
        #expect(store.rows[0].snapshot == snapshot && !store.rows[0].restoredFromCache)
        return account
    }
    let account = try await firstLaunch()
    let repo = try AccountRepository(root: root.appendingPathComponent("app"))
    let fetcher = CacheFetcher(.failure(.network))
    let store = AccountStore(repository: repo, fetcher: fetcher)
    await store.load()
    #expect(store.rows[0].snapshot == snapshot && store.rows[0].restoredFromCache)
    #expect(await fetcher.count() == 0)
    let cache = repo.root.appendingPathComponent("usage-cache.json")
    let bytes = try Data(contentsOf: cache)
    #expect((try FileManager.default.attributesOfItem(atPath: cache.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    store.refresh(account.id)
    await store.waitForRefreshes()
    #expect(store.rows[0].snapshot == snapshot && store.rows[0].errorMessage != nil)
    #expect(store.rows[0].errorMessage?.resolve(in: .english) == "The network request failed. Check your connection and refresh again.")
    #expect(try Data(contentsOf: cache) == bytes)
    await fetcher.fail(.identityChanged)
    store.refresh(account.id)
    await store.waitForRefreshes()
    #expect(store.rows[0].snapshot == nil)
    let reloaded = AccountStore(repository: repo, fetcher: fetcher)
    await reloaded.load()
    #expect(reloaded.rows[0].snapshot == nil)
}

@Test @MainActor func corruptOptionalCacheDoesNotPreventStartupAndRemovedAccountCannotRestoreUsage() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try AccountRepository(root: root.appendingPathComponent("app"))
    let file = root.appendingPathComponent("auth.json")
    try authData().write(to: file)
    let account = try await repo.addLinked(file: file, label: "")
    let snapshot = UsageSnapshot(plan: "plus", windows: [])
    try await repo.cacheUsage(snapshot, for: account)
    try await repo.remove(account.id)
    let replacement = try await repo.addLinked(file: file, label: "")
    #expect(try await repo.cachedUsage(for: replacement) == nil)
    let cache = repo.root.appendingPathComponent("usage-cache.json")
    try Data("corrupt".utf8).write(to: cache)
    // Cache reads are isolated from required account metadata reads.
    #expect(try await repo.cachedUsage(for: replacement) == nil)
    #expect(await repo.accounts().count == 1)
}

@Test @MainActor func cacheWriteFailureKeepsLiveReadingAndLaterSuccessClearsWarning() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try AccountRepository(root: root.appendingPathComponent("app"))
    let file = root.appendingPathComponent("auth.json")
    try authData().write(to: file)
    let account = try await repo.addLinked(file: file, label: "")
    let cache = repo.root.appendingPathComponent("usage-cache.json")
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
    let snapshot = UsageSnapshot(plan: "plus", windows: [])
    let store = AccountStore(repository: repo, fetcher: CacheFetcher(.success(snapshot)))
    await store.load()
    store.refresh(account.id)
    await store.waitForRefreshes()
    #expect(store.rows[0].snapshot == snapshot && store.rows[0].errorMessage == nil)
    #expect(store.storageMessage != nil)
    #expect(store.storageMessage?.resolve(in: .english) == "Unable to save the usage cache. Current readings are still available.")
    try FileManager.default.removeItem(at: cache)
    store.refresh(account.id)
    await store.waitForRefreshes()
    #expect(store.storageMessage == nil)
    #expect(try await repo.cachedUsage(for: account) == snapshot)
}

@Test @MainActor func changedLinkedCredentialsCannotRestorePreviousIdentityCache() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try AccountRepository(root: root.appendingPathComponent("app"))
    let file = root.appendingPathComponent("auth.json")
    try authData().write(to: file)
    let account = try await repo.addLinked(file: file, label: "")
    try await repo.cacheUsage(UsageSnapshot(plan: "plus", windows: []), for: account)
    try authData(account: "different-workspace").write(to: file)
    #expect(try await repo.cachedUsage(for: account) == nil)
    let store = AccountStore(repository: repo, fetcher: CacheFetcher(.failure(.network)))
    await store.load()
    #expect(store.rows[0].snapshot == nil)
}

@Test func cacheCleanupFailureDoesNotPreventManagedCredentialRemoval() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try AccountRepository(root: root.appendingPathComponent("app"))
    let stage = try await repo.makeLoginDirectory()
    try authData().write(to: stage.appendingPathComponent("auth.json"))
    let account = try await repo.finishLogin(directory: stage, label: "")
    let credentialFile = try await repo.readCredentials(account).file
    try FileManager.default.createDirectory(at: repo.root.appendingPathComponent("usage-cache.json"), withIntermediateDirectories: false)
    do { try await repo.remove(account.id); Issue.record("Expected optional cache cleanup failure") }
    catch { #expect(error as? UsageError == .storage) }
    #expect(await repo.accounts().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: credentialFile.path))
}

// This exercises a real Foundation timer through the cache consumer. The 25ms
// cadence is a test stimulus, not an assertion about RefreshController's policy.
@Test @MainActor func realTimerRefreshPersistsOnlyInsideItsExplicitRepositoryRoot() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixtureRoot = root.appendingPathComponent("fixture-data/data")
    let otherRoot = root.appendingPathComponent("other-user-data")
    try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
    let otherCache = otherRoot.appendingPathComponent("usage-cache.json")
    let unchangedCache = Data("unrelated cached reading".utf8)
    try unchangedCache.write(to: otherCache)
    let linked = root.appendingPathComponent("fixture-auth.json")
    let unchangedAuth = try authData()
    try unchangedAuth.write(to: linked)

    let repository = try AccountRepository(root: fixtureRoot)
    let account = try await repository.addLinked(file: linked, label: "Timer fixture")
    let transport = MockTransport([HTTPResponse(status: 200, data: usageFixture)])
    let store = AccountStore(repository: repository,
                             fetcher: UsageService(repository: repository, transport: transport))
    await store.load()
    let cache = fixtureRoot.appendingPathComponent("usage-cache.json")
    #expect(store.rows.first?.snapshot == nil)
    #expect(!FileManager.default.fileExists(atPath: cache.path))
    var timerFirings = 0
    var schedule: (any RefreshSchedule)?
    defer { schedule?.cancel(); schedule = nil }
    schedule = TimerRefreshScheduler().schedule(every: 0.025) {
        schedule?.cancel()
        schedule = nil
        timerFirings += 1
        store.refreshAutomatically()
    }
    // Swift Testing need not drive Foundation's main run loop while awaiting.
    func runTimerSource() {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    let deadline = Date().addingTimeInterval(3)
    while store.rows.first?.snapshot == nil && Date() < deadline {
        runTimerSource()
        try await Task.sleep(for: .milliseconds(5))
    }
    await store.waitForRefreshes()
    try #require(timerFirings == 1)
    let snapshot = try #require(store.rows.first?.snapshot)
    #expect(store.rows.first?.errorMessage == nil && store.storageMessage == nil)
    #expect(await transport.recorded().count == 1)
    #expect(!snapshot.windows.isEmpty)
    #expect(FileManager.default.fileExists(atPath: cache.path))
    #expect(try await repository.cachedUsage(for: account) == snapshot)
    #expect(try Data(contentsOf: otherCache) == unchangedCache)
    #expect(try Data(contentsOf: linked) == unchangedAuth)
    let caches = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        .compactMap { $0 as? URL }.filter { $0.lastPathComponent == "usage-cache.json" }
    #expect(Set(caches.map(\.standardizedFileURL.path)) == Set([cache.path, otherCache.path]))
}
