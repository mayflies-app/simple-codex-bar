import Foundation
import Testing
@testable import CodexUsageCore

@MainActor private final class TestSchedule: RefreshSchedule {
    var cancelled = false
    func cancel() { cancelled = true }
}

@MainActor private final class TestScheduler: RefreshScheduler {
    var jobs: [(TestSchedule, @MainActor () -> Void)] = []
    var intervals: [TimeInterval] = []
    func schedule(every interval: TimeInterval, action: @escaping @MainActor () -> Void) -> any RefreshSchedule {
        intervals.append(interval)
        let token = TestSchedule()
        jobs.append((token, action))
        return token
    }
    func fire(_ index: Int) { jobs[index].1() }
    func fireLatest() { jobs.last!.1() }
}

@MainActor private final class TestClock {
    var date = Date(timeIntervalSince1970: 1_000)
    func advance(_ seconds: TimeInterval) { date.addTimeInterval(seconds) }
}

@MainActor private final class TestActivitySource {
    var signals = MacActivitySignals(lidClosed: true, hasAwakeExternalDisplay: true)
}

private actor ResetFetcher: UsageFetching {
    var snapshots: [UUID: UsageSnapshot] = [:]
    var requested: [UUID] = []
    var failing = false
    var failingIDs: Set<UUID> = []
    var holding = false
    var pending: [CheckedContinuation<Void, Never>] = []
    func fetch(_ account: Account) async throws -> UsageSnapshot {
        requested.append(account.id)
        if holding { await withCheckedContinuation { pending.append($0) } }
        if failing || failingIDs.contains(account.id) { throw UsageError.network }
        return snapshots[account.id]!
    }
    func set(_ snapshot: UsageSnapshot, for id: UUID) { snapshots[id] = snapshot }
    func fail() { failing = true }
    func fail(_ id: UUID) { failingIDs.insert(id) }
    func recover() { failing = false; failingIDs = [] }
    func hold() { holding = true }
    func release() {
        holding = false
        for continuation in pending { continuation.resume() }
        pending = []
    }
    func ids() -> [UUID] { requested }
}

@MainActor private final class ResetFixture {
    let root: URL
    let repository: AccountRepository
    let fetcher = ResetFetcher()
    let store: AccountStore
    var accounts: [Account] = []
    init(clock: TestClock, resets: [[TimeInterval]]) async throws {
        root = try testRoot()
        repository = try AccountRepository(root: root.appendingPathComponent("data"))
        store = AccountStore(repository: repository, fetcher: fetcher)
        for (index, offsets) in resets.enumerated() {
            let file = root.appendingPathComponent("auth-\(index).json")
            try authData(account: "reset-\(index)", user: "user-\(index)").write(to: file)
            let account = try await repository.addLinked(file: file, label: "Reset \(index)")
            accounts.append(account)
            let snapshot = UsageSnapshot(plan: "plus", windows: offsets.enumerated().map { window, offset in
                UsageWindow(id: "window-\(window)", title: "Usage", usedPercent: 90,
                            resetsAt: clock.date.addingTimeInterval(offset))
            }, fetchedAt: clock.date)
            try await repository.cacheUsage(snapshot, for: account)
            await fetcher.set(snapshot, for: account.id)
        }
        await store.load()
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func setUsage(_ used: Double, for id: UUID, at date: Date) async {
        await fetcher.set(UsageSnapshot(plan: "plus", windows: [
            UsageWindow(id: "window-0", title: "Usage", usedPercent: used, resetsAt: nil)
        ], fetchedAt: date), for: id)
    }
}

@MainActor private func expectScheduledDelay(_ delay: TimeInterval, in scheduler: TestScheduler) async {
    let deadline = Date().addingTimeInterval(2)
    while scheduler.intervals.last != delay && Date() < deadline { await Task.yield() }
    #expect(scheduler.intervals.last == delay)
}

@Test @MainActor func accountsIndependentlySpeedUpSlowDownAndScheduleOnlyTheirOwnRequests() async throws {
    let clock = TestClock(), scheduler = TestScheduler()
    let fixture = try await ResetFixture(clock: clock, resets: [[10_000], [10_000]])
    defer { fixture.cleanup() }
    let active = fixture.accounts[0].id, stable = fixture.accounts[1].id
    let controller = RefreshController(defaults: nil, scheduler: scheduler, accountStore: fixture.store, now: { clock.date })
    controller.start(); controller.start()
    defer { controller.stop() }
    await fixture.store.waitForRefreshes()
    controller.handleWake()
    #expect(await fixture.fetcher.ids().count == 2)
    #expect(controller.refreshInterval(for: active) == .fiveMinutes)
    await fixture.setUsage(91, for: active, at: clock.date.addingTimeInterval(300))
    clock.advance(300)
    scheduler.fireLatest()
    await fixture.store.waitForRefreshes()
    controller.handleWake()
    #expect(controller.refreshInterval(for: active) == .oneMinute)
    #expect(controller.refreshInterval(for: stable) == .fiveMinutes)
    #expect(controller.nextRefreshAt(for: active) == clock.date.addingTimeInterval(60))
    #expect(controller.nextRefreshAt(for: stable) == clock.date.addingTimeInterval(300))
    for interval in [RefreshInterval.twoMinutes, .fiveMinutes] {
        let next = try #require(controller.nextRefreshAt(for: active))
        clock.date = next
        scheduler.fireLatest()
        await fixture.store.waitForRefreshes()
        controller.handleWake()
        #expect(controller.refreshInterval(for: active) == interval)
        #expect(await fixture.fetcher.ids().filter { $0 == stable }.count == 2)
    }
    let activeNext = controller.nextRefreshAt(for: active)
    clock.date = try #require(controller.nextRefreshAt(for: stable))
    scheduler.fireLatest()
    await fixture.store.waitForRefreshes()
    controller.handleWake()
    #expect(await fixture.fetcher.ids().filter { $0 == stable }.count == 3)
    #expect(await fixture.fetcher.ids().filter { $0 == active }.count == 4)
    #expect(controller.nextRefreshAt(for: active) == activeNext)
    await fixture.setUsage(92, for: active, at: clock.date)
    controller.refreshManually(active)
    await fixture.store.waitForRefreshes()
    controller.handleWake()
    #expect(controller.refreshInterval(for: active) == .oneMinute)
    #expect(await fixture.fetcher.ids().filter { $0 == stable }.count == 3)
}

@Test(arguments: [0.0, 90.0]) @MainActor
func quietAccountKeepsPollingAndAutomaticallyDetectsResumedUsage(used: Double) async throws {
    let clock = TestClock(), scheduler = TestScheduler()
    let fixture = try await ResetFixture(clock: clock, resets: [[]])
    defer { fixture.cleanup() }
    let id = fixture.accounts[0].id
    await fixture.setUsage(used, for: id, at: clock.date)
    let controller = RefreshController(defaults: nil, scheduler: scheduler, accountStore: fixture.store,
                                       now: { clock.date })
    controller.start()
    defer { controller.stop() }
    await fixture.store.waitForRefreshes()
    controller.handleWake()
    // An hour of unchanged readings must not leave a growing monitoring gap.
    for attempt in 1...12 {
        #expect(controller.nextRefreshAt(for: id) == clock.date.addingTimeInterval(300))
        clock.advance(300)
        scheduler.fireLatest()
        await fixture.store.waitForRefreshes()
        controller.handleWake()
        #expect(await fixture.fetcher.ids().count == attempt + 1)
    }
    await fixture.setUsage(used + 1, for: id, at: clock.date.addingTimeInterval(300))
    clock.advance(299)
    scheduler.fireLatest()
    await fixture.store.waitForRefreshes()
    #expect(await fixture.fetcher.ids().count == 13)
    clock.advance(1)
    scheduler.fireLatest()
    await fixture.store.waitForRefreshes()
    controller.handleWake()
    #expect(await fixture.fetcher.ids().count == 14)
    #expect(fixture.store.rows[0].snapshot?.windows.first?.usedPercent == used + 1)
    #expect(controller.refreshInterval(for: id) == .oneMinute)
    #expect(controller.nextRefreshAt(for: id) == clock.date.addingTimeInterval(60))
}

@Test @MainActor func partialMonthlyReadingsAndQuotaChangesKeepAccurateAutomaticCadence() async throws {
    let clock = TestClock(), scheduler = TestScheduler()
    let fixture = try await ResetFixture(clock: clock, resets: [[]])
    defer { fixture.cleanup() }
    let id = fixture.accounts[0].id
    func monthly(_ used: Double, limit: Double, balance: Double) -> UsageSnapshot {
        UsageSnapshot(plan: "business", windows: [
            UsageWindow(id: "monthly", title: "Monthly", usedPercent: used / limit * 100,
                        resetsAt: nil, usedAmount: used, limitAmount: limit)
        ], fetchedAt: clock.date, credits: .init(balance: balance, hasCredits: true, unlimited: false))
    }
    await fixture.fetcher.set(monthly(10, limit: 100, balance: 10), for: id)
    let controller = RefreshController(defaults: nil, scheduler: scheduler, accountStore: fixture.store,
                                       now: { clock.date })
    controller.start()
    defer { controller.stop() }
    await fixture.store.waitForRefreshes()
    controller.handleWake()
    for step in 0..<3 {
        // Quota adjustment and a top-up, a missing monthly reading, then actual consumption.
        clock.advance(300)
        let next = step == 0 ? monthly(10, limit: 50, balance: 20)
            : step == 1 ? UsageSnapshot(plan: "business", windows: [], fetchedAt: clock.date,
                credits: .init(balance: 20, hasCredits: true, unlimited: false))
            : monthly(11, limit: 100, balance: 20)
        await fixture.fetcher.set(next, for: id)
        scheduler.fireLatest()
        await fixture.store.waitForRefreshes()
        controller.handleWake()
        #expect(await fixture.fetcher.ids().count == step + 2)
        #expect(fixture.store.rows[0].snapshot == next)
        #expect(fixture.store.rows[0].errorMessage == nil)
        #expect(controller.refreshInterval(for: id) == (step == 2 ? .oneMinute : .fiveMinutes))
        #expect(controller.nextRefreshAt(for: id) == clock.date.addingTimeInterval(step == 2 ? 60 : 300))
    }
}

@Test @MainActor func repeatedAccountFailuresBackOffWithoutDelayingHealthyAccountAndRecover() async throws {
    let clock = TestClock(), scheduler = TestScheduler()
    let fixture = try await ResetFixture(clock: clock, resets: [[10_000], [10_000]])
    defer { fixture.cleanup() }
    let failing = fixture.accounts[0].id, healthy = fixture.accounts[1].id
    let controller = RefreshController(defaults: nil, scheduler: scheduler, accountStore: fixture.store, now: { clock.date })
    controller.start()
    defer { controller.stop() }
    await fixture.store.waitForRefreshes()
    controller.handleWake()
    let cached = fixture.store.rows[0].snapshot
    await fixture.fetcher.fail(failing)
    for expected in [RefreshInterval.fiveMinutes, .fifteenMinutes, .thirtyMinutes] {
        controller.refreshManually(failing)
        await fixture.store.waitForRefreshes()
        controller.handleWake()
        #expect(controller.refreshInterval(for: failing) == expected)
        #expect(controller.refreshInterval(for: healthy) == .fiveMinutes)
        #expect(fixture.store.rows[0].snapshot == cached)
    }
    clock.advance(300)
    scheduler.fireLatest()
    await fixture.store.waitForRefreshes()
    controller.handleWake()
    #expect(await fixture.fetcher.ids().filter { $0 == healthy }.count == 2)
    #expect(await fixture.fetcher.ids().filter { $0 == failing }.count == 4)
    await fixture.fetcher.recover()
    controller.refreshManually(failing)
    await fixture.store.waitForRefreshes()
    controller.handleWake()
    #expect(controller.refreshInterval(for: failing) == .fiveMinutes)
    #expect(fixture.store.rows[0].errorMessage == nil)
}

@Test(arguments: [MacActivityState.locked, .sleeping, .lidClosed, .displaySleeping, .sessionInactive, .idle]) @MainActor
func inactiveAccountsCatchUpOnceAndManualRefreshDoesNotShiftOtherAccounts(state: MacActivityState) async throws {
    let clock = TestClock(), scheduler = TestScheduler()
    let fixture = try await ResetFixture(clock: clock, resets: [[10_000], [10_000]])
    defer { fixture.cleanup() }
    let controller = RefreshController(defaults: nil, scheduler: scheduler, accountStore: fixture.store, now: { clock.date })
    controller.setActivity(state)
    controller.start()
    #expect(await fixture.fetcher.ids().isEmpty)
    controller.setActivity(.active)
    await fixture.store.waitForRefreshes()
    controller.handleWake()
    let oldJob = scheduler.jobs.count - 1
    controller.setActivity(state)
    clock.advance(400)
    scheduler.fire(oldJob); controller.handleWake()
    #expect(await fixture.fetcher.ids().count == 2)
    controller.refreshManually(fixture.accounts[0].id)
    await fixture.store.waitForRefreshes()
    controller.setActivity(.active)
    await fixture.store.waitForRefreshes()
    controller.handleWake(); controller.setActivity(.active); scheduler.fire(oldJob)
    #expect(await fixture.fetcher.ids().count == 4)
    #expect(await fixture.fetcher.ids().filter { $0 == fixture.accounts[0].id }.count == 2)
    controller.stop()
    scheduler.fireLatest()
    #expect(await fixture.fetcher.ids().count == 4)
}

@Test @MainActor func globalOptOutPersistsAndLegacyFixedIntervalDoesNotControlDynamicSchedules() async throws {
    let suite = "SimpleCodexBarAdaptiveTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(30, forKey: "RefreshIntervalMinutes")
    let clock = TestClock(), scheduler = TestScheduler()
    let fixture = try await ResetFixture(clock: clock, resets: [[10_000]])
    defer { fixture.cleanup() }
    let controller = RefreshController(defaults: defaults, scheduler: scheduler, accountStore: fixture.store, now: { clock.date })
    controller.start()
    await fixture.store.waitForRefreshes()
    controller.handleWake()
    #expect(controller.refreshInterval(for: fixture.accounts[0].id) == .fiveMinutes)
    controller.setAutomaticRefreshEnabled(false)
    controller.stop()
    let reopened = RefreshController(defaults: defaults, scheduler: scheduler, accountStore: fixture.store, now: { clock.date })
    reopened.start()
    defer { reopened.stop() }
    clock.advance(900)
    reopened.handleWake(); scheduler.fireLatest()
    #expect(!reopened.automaticRefreshEnabled)
    #expect(await fixture.fetcher.ids().count == 1)
    reopened.refreshManually()
    await fixture.store.waitForRefreshes()
    #expect(await fixture.fetcher.ids().count == 2)
    reopened.setAutomaticRefreshEnabled(true)
    await fixture.store.waitForRefreshes()
    reopened.handleWake()
    #expect(await fixture.fetcher.ids().count == 3)
}

@Test @MainActor func newlyAddedAccountStartsIndependentlyAndLateStoreCompletionIsObservedOnlyOnce() async throws {
    let clock = TestClock(), scheduler = TestScheduler()
    let fixture = try await ResetFixture(clock: clock, resets: [[10_000]])
    defer { fixture.cleanup() }
    let first = fixture.accounts[0].id
    let controller = RefreshController(defaults: nil, scheduler: scheduler, accountStore: fixture.store, now: { clock.date })
    controller.start()
    defer { controller.stop() }
    await fixture.store.waitForRefreshes()
    controller.handleWake()
    let originalNext = controller.nextRefreshAt(for: first)
    clock.advance(100)
    let file = fixture.root.appendingPathComponent("added.json")
    try authData(account: "added-account", user: "added-user").write(to: file)
    let added = try await fixture.repository.addLinked(file: file, label: "Added")
    await fixture.setUsage(10, for: added.id, at: clock.date)
    await fixture.store.load()
    fixture.store.refresh(added.id) // The login/add workflow explicitly starts its first request.
    await fixture.store.waitForRefreshes()
    controller.handleWake(); controller.handleWake()
    #expect(await fixture.fetcher.ids().filter { $0 == added.id }.count == 1)
    #expect(controller.refreshInterval(for: added.id) == .fiveMinutes)
    #expect(controller.nextRefreshAt(for: added.id) == clock.date.addingTimeInterval(300))
    #expect(controller.nextRefreshAt(for: first) == originalNext)
    await fixture.store.remove(added.id)
    controller.handleWake()
    #expect(controller.nextRefreshAt(for: added.id) == nil)
    #expect(controller.nextRefreshAt(for: first) == originalNext)
}

@Test @MainActor func resetDeadlineRefreshesOnlyDueAccountOnceWithoutMovingPeriodicRefresh() async throws {
    let clock = TestClock(), scheduler = TestScheduler()
    let fixture = try await ResetFixture(clock: clock, resets: [[40, 40], [80], [20]])
    defer { fixture.cleanup() }
    await fixture.store.setAutomaticRefreshEnabled(fixture.accounts[2].id, enabled: false)
    let controller = RefreshController(defaults: nil, scheduler: scheduler, accountStore: fixture.store,
                                       now: { clock.date })
    controller.start()
    defer { controller.stop() }
    await fixture.store.waitForRefreshes()
    await expectScheduledDelay(40, in: scheduler)
    clock.advance(40)
    scheduler.fireLatest()
    await fixture.store.waitForRefreshes()
    #expect(await fixture.fetcher.ids().filter { $0 == fixture.accounts[0].id }.count == 2)
    #expect(await fixture.fetcher.ids().filter { $0 == fixture.accounts[1].id }.count == 1)
    #expect(await fixture.fetcher.ids().contains(fixture.accounts[2].id) == false)
    #expect(controller.refreshInterval(for: fixture.accounts[0].id) == .fiveMinutes)
    controller.handleWake(); scheduler.fireLatest()
    await fixture.store.waitForRefreshes()
    #expect(await fixture.fetcher.ids().count == 3)
    clock.advance(40)
    scheduler.fireLatest()
    await fixture.store.waitForRefreshes()
    #expect(await fixture.fetcher.ids().count == 4)
    await expectScheduledDelay(220, in: scheduler)
    clock.advance(220)
    scheduler.fireLatest()
    await fixture.store.waitForRefreshes()
    #expect(await fixture.fetcher.ids().count == 6)
}

@Test @MainActor func resetSampleUpdatesBaselineWithoutMovingRegularRefresh() async throws {
    let clock = TestClock(), scheduler = TestScheduler()
    let fixture = try await ResetFixture(clock: clock, resets: [[40]])
    defer { fixture.cleanup() }
    let id = fixture.accounts[0].id
    let controller = RefreshController(defaults: nil, scheduler: scheduler, accountStore: fixture.store,
                                       now: { clock.date })
    controller.start()
    defer { controller.stop() }
    await fixture.store.waitForRefreshes()
    await expectScheduledDelay(40, in: scheduler)
    #expect(controller.nextRefreshAt(for: id) == clock.date.addingTimeInterval(40))
    clock.advance(40)
    await fixture.setUsage(0, for: id, at: clock.date)
    scheduler.fireLatest()
    await fixture.store.waitForRefreshes()
    controller.handleWake()
    #expect(await fixture.fetcher.ids().count == 2)
    #expect(controller.refreshInterval(for: id) == .fiveMinutes)
    #expect(controller.nextRefreshAt(for: id) == clock.date.addingTimeInterval(260))
    clock.advance(260)
    await fixture.setUsage(1, for: id, at: clock.date)
    scheduler.fireLatest()
    await fixture.store.waitForRefreshes()
    controller.handleWake()
    #expect(await fixture.fetcher.ids().count == 3)
    #expect(fixture.store.rows[0].snapshot?.windows.first?.usedPercent == 1)
    #expect(controller.refreshInterval(for: id) == .oneMinute)
    #expect(controller.nextRefreshAt(for: id) == clock.date.addingTimeInterval(60))
}

@Test @MainActor func failedResetRefreshKeepsCachedReadingAndDoesNotRetryUntilRegularInterval() async throws {
    let clock = TestClock(), scheduler = TestScheduler()
    let fixture = try await ResetFixture(clock: clock, resets: [[40]])
    defer { fixture.cleanup() }
    let controller = RefreshController(defaults: nil, scheduler: scheduler, accountStore: fixture.store,
                                       now: { clock.date })
    controller.start()
    defer { controller.stop() }
    await fixture.store.waitForRefreshes()
    let snapshot = fixture.store.rows[0].snapshot
    await fixture.fetcher.fail()
    clock.advance(40)
    scheduler.fireLatest()
    await fixture.store.waitForRefreshes()
    #expect(await fixture.fetcher.ids().count == 2)
    #expect(fixture.store.rows[0].snapshot == snapshot)
    #expect(fixture.store.rows[0].errorMessage == UsageError.network.message)
    #expect(try await fixture.repository.cachedUsage(for: fixture.accounts[0]) == snapshot)
    await expectScheduledDelay(260, in: scheduler)
    for _ in 0..<3 { controller.handleWake(); scheduler.fireLatest() }
    await fixture.store.waitForRefreshes()
    #expect(await fixture.fetcher.ids().count == 2)
    clock.advance(260)
    scheduler.fireLatest()
    await fixture.store.waitForRefreshes()
    #expect(await fixture.fetcher.ids().count == 3)
}

@Test @MainActor func resetRefreshWaitsForActiveMacAndRechecksLiveActivity() async throws {
    let clock = TestClock(), scheduler = TestScheduler(), source = TestActivitySource()
    let fixture = try await ResetFixture(clock: clock, resets: [[40]])
    defer { fixture.cleanup() }
    let controller = RefreshController(defaults: nil, scheduler: scheduler, accountStore: fixture.store,
                                       now: { clock.date }, activityProvider: { source.signals.state })
    controller.start()
    defer { controller.stop() }
    await fixture.store.waitForRefreshes()
    await expectScheduledDelay(40, in: scheduler)
    let queuedBeforeLock = scheduler.jobs.count - 1
    source.signals.locked = true
    clock.advance(40)
    scheduler.fire(queuedBeforeLock)
    controller.handleWake()
    #expect(controller.activity == .locked)
    #expect(await fixture.fetcher.ids().count == 1)
    source.signals.locked = false
    controller.setActivity(.active)
    await fixture.store.waitForRefreshes()
    #expect(await fixture.fetcher.ids().count == 2)
    #expect(controller.refreshInterval(for: fixture.accounts[0].id) == .fiveMinutes)
    scheduler.fire(queuedBeforeLock); controller.handleWake()
    await fixture.store.waitForRefreshes()
    #expect(await fixture.fetcher.ids().count == 2)
}

@Test @MainActor func disabledResetRefreshCanBeManualAndReenabledWithoutDuplicate() async throws {
    let clock = TestClock(), scheduler = TestScheduler()
    let fixture = try await ResetFixture(clock: clock, resets: [[40]])
    defer { fixture.cleanup() }
    let controller = RefreshController(defaults: nil, scheduler: scheduler, accountStore: fixture.store,
                                       now: { clock.date })
    controller.start()
    defer { controller.stop() }
    await fixture.store.waitForRefreshes()
    controller.setAutomaticRefreshEnabled(false)
    clock.advance(40)
    scheduler.fireLatest(); controller.handleWake()
    await fixture.store.waitForRefreshes()
    #expect(await fixture.fetcher.ids().count == 1)
    controller.refreshManually()
    await fixture.store.waitForRefreshes()
    #expect(await fixture.fetcher.ids().count == 2)
    controller.setAutomaticRefreshEnabled(true)
    await fixture.store.waitForRefreshes()
    await expectScheduledDelay(300, in: scheduler)
    scheduler.fireLatest(); controller.handleWake()
    await fixture.store.waitForRefreshes()
    #expect(await fixture.fetcher.ids().count == 3) // Reenabling retains the existing immediate refresh.
}

@Test @MainActor func changingResetDatesRearmsTimerAndAccountOptOutCancelsIt() async throws {
    let clock = TestClock(), scheduler = TestScheduler()
    let fixture = try await ResetFixture(clock: clock, resets: [[40]])
    defer { fixture.cleanup() }
    let account = fixture.accounts[0]
    let controller = RefreshController(defaults: nil, scheduler: scheduler, accountStore: fixture.store,
                                       now: { clock.date })
    controller.start()
    defer { controller.stop() }
    await fixture.store.waitForRefreshes()
    await expectScheduledDelay(40, in: scheduler)
    let oldJob = scheduler.jobs.count - 1
    let next = UsageSnapshot(plan: "plus", windows: [
        UsageWindow(id: "window-0", title: "Usage", usedPercent: 5, resetsAt: clock.date.addingTimeInterval(70))
    ], fetchedAt: clock.date.addingTimeInterval(40))
    await fixture.fetcher.set(next, for: account.id)
    clock.advance(40)
    scheduler.fireLatest()
    await fixture.store.waitForRefreshes()
    await expectScheduledDelay(30, in: scheduler)
    #expect(await fixture.fetcher.ids().count == 2)
    scheduler.fire(oldJob)
    #expect(await fixture.fetcher.ids().count == 2)
    await fixture.store.setAutomaticRefreshEnabled(account.id, enabled: false)
    controller.handleWake()
    #expect(controller.nextRefreshAt(for: account.id) == nil)
    #expect(scheduler.jobs.last?.0.cancelled == true)
    clock.advance(30)
    scheduler.fireLatest(); controller.handleWake()
    await fixture.store.waitForRefreshes()
    #expect(await fixture.fetcher.ids().count == 2)
    await fixture.store.setAutomaticRefreshEnabled(account.id, enabled: true)
    let deadline = Date().addingTimeInterval(2)
    while (await fixture.fetcher.ids().count) < 3 && Date() < deadline { await Task.yield() }
    await fixture.store.waitForRefreshes()
    #expect(await fixture.fetcher.ids().count == 3)
    await fixture.store.remove(account.id)
    controller.handleWake()
    #expect(controller.nextRefreshAt(for: account.id) == nil)
    #expect(scheduler.jobs.last?.0.cancelled == true)
    clock.advance(300)
    scheduler.fireLatest()
    await fixture.store.waitForRefreshes()
    #expect(await fixture.fetcher.ids().count == 3)
}

@Test(arguments: [false, true]) @MainActor
func resetCoincidingWithIntervalOrManualRefreshDoesNotDuplicateRequest(manual: Bool) async throws {
    let clock = TestClock(), scheduler = TestScheduler()
    let fixture = try await ResetFixture(clock: clock, resets: [[300]])
    defer { fixture.cleanup() }
    let controller = RefreshController(defaults: nil, scheduler: scheduler, accountStore: fixture.store,
                                       now: { clock.date })
    controller.start()
    defer { controller.stop() }
    await fixture.store.waitForRefreshes()
    clock.advance(300)
    if manual { controller.refreshManually() }
    else { scheduler.fireLatest() }
    await fixture.store.waitForRefreshes()
    await expectScheduledDelay(300, in: scheduler)
    controller.handleWake(); scheduler.fireLatest()
    await fixture.store.waitForRefreshes()
    #expect(await fixture.fetcher.ids().count == 2)
}

@Test @MainActor func productionTimerRefreshesAtResetWithoutAnOpenPanel() async throws {
    let clock = TestClock()
    clock.date = Date()
    let fixture = try await ResetFixture(clock: clock, resets: [[1.5]])
    defer { fixture.cleanup() }
    let credential = fixture.root.appendingPathComponent("auth-0.json")
    let original = try Data(contentsOf: credential)
    let controller = RefreshController(defaults: nil, accountStore: fixture.store)
    controller.start()
    defer { controller.stop() }
    await fixture.store.waitForRefreshes()
    #expect(await fixture.fetcher.ids().count == 1)
    func runTimerSource() {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    let deadline = Date().addingTimeInterval(5)
    while (await fixture.fetcher.ids().count) < 2 && Date() < deadline {
        runTimerSource()
        try await Task.sleep(for: .milliseconds(5))
    }
    await fixture.store.waitForRefreshes()
    #expect(await fixture.fetcher.ids().count == 2)
    #expect(try Data(contentsOf: credential) == original)
    #expect(fixture.store.rows[0].snapshot != nil && fixture.store.rows[0].errorMessage == nil)
}

@Test(arguments: [false, true]) @MainActor
func resetDuringInflightRequestWaitsForCompletionAndOnlyCatchesUpIfUnconfirmed(confirmed: Bool) async throws {
    let clock = TestClock(), scheduler = TestScheduler()
    let fixture = try await ResetFixture(clock: clock, resets: [[40]])
    defer { fixture.cleanup() }
    let account = fixture.accounts[0]
    let controller = RefreshController(defaults: nil, scheduler: scheduler, accountStore: fixture.store,
                                       now: { clock.date })
    controller.start()
    defer { controller.stop() }
    await fixture.store.waitForRefreshes()
    await expectScheduledDelay(40, in: scheduler)
    await fixture.fetcher.hold()
    fixture.store.refresh(account.id)
    clock.advance(40)
    scheduler.fireLatest(); controller.handleWake()
    let requestDeadline = Date().addingTimeInterval(2)
    while (await fixture.fetcher.ids().count) < 2 && Date() < requestDeadline { await Task.yield() }
    #expect(await fixture.fetcher.ids().count == 2)
    #expect(fixture.store.rows[0].refreshing)
    if confirmed {
        // The response still advertises the old date, but was obtained after it passed.
        await fixture.fetcher.set(UsageSnapshot(plan: "plus", windows: fixture.store.rows[0].snapshot!.windows,
                                               fetchedAt: clock.date), for: account.id)
    } else { await fixture.fetcher.fail() }
    await fixture.fetcher.release()
    await fixture.store.waitForRefreshes()
    if !confirmed {
        let deadline = Date().addingTimeInterval(2)
        while (await fixture.fetcher.ids().count) < 3 && Date() < deadline { await Task.yield() }
        await fixture.store.waitForRefreshes()
    }
    await expectScheduledDelay(300, in: scheduler)
    controller.handleWake(); scheduler.fireLatest()
    await fixture.store.waitForRefreshes()
    #expect(await fixture.fetcher.ids().count == (confirmed ? 2 : 3))
}


@Test func activitySignalsPrioritizeInactivityAndIdleBoundary() {
    #expect(MacActivitySignals(idleSeconds: 299).state == .active)
    #expect(MacActivitySignals(idleSeconds: 300).state == .idle)
    #expect(MacActivitySignals(locked: true, idleSeconds: 0).state == .locked)
    #expect(MacActivitySignals(sleeping: true, locked: true).state == .sleeping)
    #expect(MacActivitySignals(lidClosed: true).state == .lidClosed)
    #expect(MacActivitySignals(displaySleeping: true).state == .displaySleeping)
    #expect(MacActivitySignals(sessionActive: false).state == .sessionInactive)
    #expect(MacActivitySignals(idleSeconds: .infinity).state == .idle)
    #expect(MacActivitySignals(idleSeconds: .nan).state == .idle) // Unknown input state pauses requests.
}


@Test func closedLidWithAwakeExternalDisplayStillChecksOtherActivitySignals() {
    var signals = MacActivitySignals(lidClosed: true, hasAwakeExternalDisplay: true, idleSeconds: 299)
    #expect(signals.state == .active)
    signals.locked = true
    #expect(signals.state == .locked)
    signals.sleeping = true
    #expect(signals.state == .sleeping)
    signals.sleeping = false; signals.locked = false
    signals.sessionActive = false
    #expect(signals.state == .sessionInactive)
    signals.sessionActive = true; signals.displaySleeping = true
    #expect(signals.state == .displaySleeping)
    signals.displaySleeping = false; signals.idleSeconds = 300
    #expect(signals.state == .idle)
    signals.idleSeconds = .nan
    #expect(signals.state == .idle)
    signals.idleSeconds = 0; signals.hasAwakeExternalDisplay = false
    #expect(signals.state == .lidClosed) // Unplugged or sleeping external displays cannot enable clamshell use.
    signals.lidClosed = false
    #expect(signals.state == .active)
}
