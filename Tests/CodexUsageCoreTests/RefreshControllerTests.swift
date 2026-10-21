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

@Test @MainActor func startupRefreshRunsExactlyOnceOnlyWhenEnabledAndActive() {
    for enabled in [false, true] {
        let scheduler = TestScheduler()
        var calls = 0
        let controller = RefreshController(defaults: nil, enabled: enabled, scheduler: scheduler) { calls += 1 }
        controller.start(); controller.start(); controller.handleWake()
        #expect(calls == (enabled ? 1 : 0))
        #expect(scheduler.jobs.count == (enabled ? 1 : 0))
        controller.stop()
    }
    let scheduler = TestScheduler()
    var calls = 0
    let controller = RefreshController(defaults: nil, scheduler: scheduler) { calls += 1 }
    controller.setActivity(.locked)
    controller.start()
    #expect(calls == 0 && scheduler.jobs.isEmpty)
    controller.setActivity(.active)
    #expect(calls == 1)
    controller.setActivity(.active)
    #expect(calls == 1)
    controller.stop()
}

@Test @MainActor func inactiveMacCancelsRequestsAndResumesOnlyWhenIntervalHasElapsed() {
    let clock = TestClock(), scheduler = TestScheduler()
    var calls = 0
    let controller = RefreshController(defaults: nil, scheduler: scheduler, now: { clock.date }) { calls += 1 }
    controller.start()
    for state in [MacActivityState.locked, .sleeping, .lidClosed, .displaySleeping, .sessionInactive, .idle] {
        controller.setActivity(state)
        let oldJob = scheduler.jobs.count - 1
        #expect(scheduler.jobs[oldJob].0.cancelled)
        scheduler.fire(oldJob); controller.handleWake()
        #expect(calls == 1)
        controller.setActivity(.active)
        #expect(calls == 1) // A quick lock/unlock is not a new refresh opportunity.
    }
    clock.advance(100)
    controller.setActivity(.idle)
    controller.setActivity(.active)
    #expect(scheduler.intervals.last == 200)
    clock.advance(199)
    scheduler.fireLatest()
    #expect(calls == 1)
    clock.advance(1)
    scheduler.fireLatest()
    #expect(calls == 2)
    controller.setActivity(.sleeping)
    clock.advance(1_200)
    controller.setActivity(.active)
    #expect(calls == 3) // One catch-up, without replaying missed ticks.
    controller.handleWake(); controller.setActivity(.active)
    #expect(calls == 3)
    controller.stop()
}

@Test @MainActor func disabledAutomaticRefreshNeverRunsOnActivityChangesButManualAlwaysWorks() {
    let clock = TestClock(), scheduler = TestScheduler()
    var automatic = 0, manual = 0
    let controller = RefreshController(defaults: nil, enabled: false, scheduler: scheduler,
                                       now: { clock.date }, onManualRefresh: { manual += 1 }) { automatic += 1 }
    controller.start()
    for state in [MacActivityState.idle, .locked, .sleeping, .lidClosed] {
        controller.setActivity(state)
        clock.advance(900)
        controller.refreshManually()
        controller.setActivity(.active)
        controller.handleWake()
    }
    #expect(automatic == 0 && manual == 4 && scheduler.jobs.isEmpty)
    controller.setActivity(.locked)
    controller.setAutomaticRefreshEnabled(true)
    #expect(automatic == 0 && scheduler.jobs.isEmpty)
    clock.advance(300)
    controller.setActivity(.active)
    #expect(automatic == 1)
    controller.setActivity(.locked)
    clock.advance(400)
    controller.refreshManually()
    controller.setActivity(.active)
    #expect(automatic == 1 && manual == 5)
    #expect(scheduler.intervals.last == 300)
    controller.stop()
}

@Test @MainActor func changingIntervalReplacesTimerWithoutBurstAndPersistsInManualMode() {
    let suite = "SimpleCodexBarIntervalTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let scheduler = TestScheduler(), clock = TestClock()
    var calls = 0
    let controller = RefreshController(defaults: defaults, scheduler: scheduler, now: { clock.date }) { calls += 1 }
    controller.start()
    #expect(scheduler.intervals == [300])
    clock.advance(20)
    controller.setRefreshInterval(.oneMinute)
    #expect(scheduler.jobs[0].0.cancelled)
    #expect(scheduler.intervals.last == 40)
    #expect(calls == 1)
    clock.advance(40)
    scheduler.fire(0)
    #expect(calls == 1)
    scheduler.fireLatest()
    #expect(calls == 2)
    controller.setAutomaticRefreshEnabled(false)
    controller.setRefreshInterval(.fifteenMinutes)
    let reopened = RefreshController(defaults: defaults, scheduler: TestScheduler()) { calls += 1 }
    #expect(reopened.refreshInterval == .fifteenMinutes && !reopened.automaticRefreshEnabled)
    reopened.start()
    #expect(calls == 2)
    controller.setAutomaticRefreshEnabled(true)
    #expect(scheduler.intervals.last == 900 && calls == 3)
    controller.stop(); reopened.stop()
}

@Test @MainActor func unsupportedStoredIntervalsFallBackToSafeDefault() {
    let suite = "SimpleCodexBarInvalidIntervals.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    for invalid: Any in [0, -1, 999, 1.5, true, "1", "bad"] {
        defaults.set(invalid, forKey: RefreshController.intervalPreferenceKey)
        let controller = RefreshController(defaults: defaults) { }
        #expect(controller.refreshInterval == .fiveMinutes)
    }
}

@Test @MainActor func refreshPreferenceSurvivesRelaunchAndQueuedTimersStayCancelled() {
    let suite = "SimpleCodexBarTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let scheduler = TestScheduler(), clock = TestClock()
    var calls = 0
    let controller = RefreshController(defaults: defaults, scheduler: scheduler, now: { clock.date }) { calls += 1 }
    controller.start()
    controller.setAutomaticRefreshEnabled(false)
    let reopened = RefreshController(defaults: defaults, scheduler: TestScheduler()) { calls += 1 }
    reopened.start()
    #expect(!reopened.automaticRefreshEnabled && calls == 1)
    controller.setAutomaticRefreshEnabled(true)
    clock.advance(300)
    scheduler.fire(0)
    #expect(calls == 2)
    scheduler.fireLatest()
    #expect(calls == 3)
    controller.stop()
    scheduler.fireLatest()
    #expect(calls == 3)
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

@Test @MainActor func timerRechecksLiveActivityEvenBeforeSystemNotificationArrives() {
    let clock = TestClock(), scheduler = TestScheduler()
    let source = TestActivitySource()
    var calls = 0
    let controller = RefreshController(defaults: nil, scheduler: scheduler, now: { clock.date },
                                       activityProvider: { source.signals.state }) { calls += 1 }
    controller.start()
    let queuedBeforeLock = scheduler.jobs.count - 1
    source.signals.locked = true
    clock.advance(600)
    scheduler.fire(queuedBeforeLock)
    #expect(calls == 1 && controller.activity == .locked)
    #expect(scheduler.jobs[queuedBeforeLock].0.cancelled)
    source.signals.locked = false
    controller.setActivity(.active)
    #expect(calls == 2)
    scheduler.fire(queuedBeforeLock)
    #expect(calls == 2)
    controller.stop()
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

@Test @MainActor func clamshellRefreshContinuesAndReconnectCatchesUpOnlyOnce() throws {
    let clock = TestClock(), scheduler = TestScheduler()
    let source = TestActivitySource()
    var calls = 0
    let controller = RefreshController(defaults: nil, scheduler: scheduler, now: { clock.date },
                                       activityProvider: { source.signals.state }) { calls += 1 }
    controller.start()
    defer { controller.stop() }
    #expect(controller.activity == .active && calls == 1)
    try #require(scheduler.jobs.count == 1)
    clock.advance(300)
    scheduler.fireLatest()
    #expect(calls == 2)
    let queuedBeforeDisconnect = scheduler.jobs.count - 1
    source.signals.hasAwakeExternalDisplay = false
    // Each automatic request must also sample the hardware, even before the display notification.
    clock.advance(300)
    scheduler.fire(queuedBeforeDisconnect)
    #expect(controller.activity == .lidClosed && calls == 2)
    #expect(scheduler.jobs[queuedBeforeDisconnect].0.cancelled)
    clock.advance(600)
    source.signals.hasAwakeExternalDisplay = true
    controller.setActivity(source.signals.state)
    #expect(controller.activity == .active && calls == 3)
    controller.setActivity(source.signals.state); controller.handleWake()
    scheduler.fire(queuedBeforeDisconnect)
    #expect(calls == 3)
}
