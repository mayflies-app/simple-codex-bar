import Foundation
import Observation

public enum RefreshInterval: Int, CaseIterable, Identifiable, Sendable {
    case oneMinute = 1, twoMinutes = 2, fiveMinutes = 5, fifteenMinutes = 15, thirtyMinutes = 30
    public var id: Int { rawValue }
    public var seconds: TimeInterval { TimeInterval(rawValue * 60) }
    public var title: String { title(in: .simplifiedChinese) }
    public func title(in language: AppLanguage) -> String {
        LocalizedText(rawValue == 1 ? "refresh.minute" : "refresh.minutes", String(rawValue)).resolve(in: language)
    }
}

@MainActor public protocol RefreshSchedule: AnyObject {
    func cancel()
}

@MainActor public protocol RefreshScheduler {
    func schedule(every interval: TimeInterval, action: @escaping @MainActor () -> Void) -> any RefreshSchedule
}

@MainActor private final class TimerSchedule: RefreshSchedule {
    let timer: Timer
    init(timer: Timer) { self.timer = timer }
    func cancel() { timer.invalidate() }
}

@MainActor public struct TimerRefreshScheduler: RefreshScheduler {
    public init() {}
    public func schedule(every interval: TimeInterval, action: @escaping @MainActor () -> Void) -> any RefreshSchedule {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor in action() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return TimerSchedule(timer: timer)
    }
}

/// Each account owns its cadence; all automatic entry points share activity and opt-out policy.
@MainActor @Observable
public final class RefreshController {
    private struct ResetDeadline: Hashable {
        let accountID: UUID
        let windowID: String
        let date: Date
    }

    private struct AccountSchedule {
        let identity: String
        var policy = AdaptiveRefreshPolicy()
        var nextRegularAt: Date
        var observedAttempt: UUID?
        var processedCompletion: UUID?
        var isResetRequest = false
    }

    public private(set) var automaticRefreshEnabled: Bool
    public private(set) var activity: MacActivityState = .active
    private var accounts: [UUID: AccountSchedule] = [:]
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let scheduler: any RefreshScheduler
    @ObservationIgnored private let accountStore: AccountStore
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let activityProvider: (@MainActor () -> MacActivityState)?
    @ObservationIgnored private var schedule: (any RefreshSchedule)?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var observationGeneration = UUID()
    @ObservationIgnored private var attemptedResets: Set<ResetDeadline> = []
    @ObservationIgnored private var started = false
    public static let preferenceKey = "AutomaticRefreshEnabled"

    public init(defaults: UserDefaults? = .standard, enabled: Bool = true,
                scheduler: any RefreshScheduler = TimerRefreshScheduler(),
                accountStore: AccountStore,
                now: @escaping @MainActor () -> Date = { Date() },
                activityProvider: (@MainActor () -> MacActivityState)? = nil) {
        self.defaults = defaults; self.scheduler = scheduler; self.accountStore = accountStore
        self.now = now; self.activityProvider = activityProvider
        automaticRefreshEnabled = (defaults?.object(forKey: Self.preferenceKey) as? Bool) ?? enabled
        // The former global RefreshIntervalMinutes preference no longer controls account schedules.
    }

    public func refreshInterval(for id: UUID) -> RefreshInterval { accounts[id]?.policy.interval ?? .fiveMinutes }

    public func nextRefreshAt(for id: UUID) -> Date? {
        guard started && automaticRefreshEnabled && activity.isActive,
              let row = accountStore.rows.first(where: { $0.id == id }),
              row.account.automaticRefreshEnabled && !row.refreshing,
              let account = accounts[id] else { return nil }
        return min(account.nextRegularAt, pendingResets(for: row).map(\.date).min() ?? account.nextRegularAt)
    }

    public func start() {
        guard !started else { return }
        started = true
        observeAccounts()
        refreshIfDue(force: true)
        reconfigure()
    }

    public func stop() {
        started = false
        generation = UUID(); observationGeneration = UUID()
        schedule?.cancel(); schedule = nil
    }

    public func setAutomaticRefreshEnabled(_ enabled: Bool) {
        guard automaticRefreshEnabled != enabled else { return }
        automaticRefreshEnabled = enabled
        defaults?.set(enabled, forKey: Self.preferenceKey)
        if enabled { refreshIfDue(force: true) }
        reconfigure()
    }

    public func setActivity(_ state: MacActivityState) {
        guard activity != state else { return }
        activity = state
        if state.isActive { refreshIfDue() }
        reconfigure()
    }

    public func handleWake() {
        refreshIfDue()
        reconfigure()
    }

    public func refreshManually(_ id: UUID? = nil) {
        synchronizeAccounts()
        for row in accountStore.rows where id == nil || row.id == id {
            request(row, at: now(), resetOnly: false)
        }
        reconfigure()
    }

    private func refreshIfDue(force: Bool = false) {
        synchronizeAccounts()
        if let activityProvider { activity = activityProvider() }
        guard started && automaticRefreshEnabled && activity.isActive else { return }
        let date = now()
        for row in accountStore.rows where row.account.automaticRefreshEnabled && !row.refreshing {
            guard let account = accounts[row.id] else { continue }
            if force || account.nextRegularAt <= date { request(row, at: date, resetOnly: false) }
            else if pendingResets(for: row).contains(where: { $0.date <= date }) {
                request(row, at: date, resetOnly: true)
            }
        }
    }

    private func request(_ row: AccountRow, at date: Date, resetOnly: Bool) {
        guard !row.refreshing, var account = accounts[row.id] else { return }
        // Consume before requesting: errors and unchanged reset dates must not cause a loop.
        attemptedResets.formUnion(pendingResets(for: row).filter { $0.date <= date })
        account.isResetRequest = resetOnly
        if !resetOnly { account.nextRegularAt = date.addingTimeInterval(account.policy.interval.seconds) }
        accountStore.refresh(row.id)
        account.observedAttempt = accountStore.rows.first(where: { $0.id == row.id })?.refreshAttemptID
        accounts[row.id] = account
    }

    private func resetDeadlines(for row: AccountRow) -> Set<ResetDeadline> {
        Set((row.snapshot?.windows ?? []).compactMap { window -> ResetDeadline? in
            guard let date = window.resetsAt, date.timeIntervalSince1970.isFinite else { return nil }
            return ResetDeadline(accountID: row.id, windowID: window.id, date: date)
        })
    }

    private func pendingResets(for row: AccountRow) -> Set<ResetDeadline> {
        guard let snapshot = row.snapshot else { return [] }
        // A reading obtained after a deadline already checked that reset with the service.
        return resetDeadlines(for: row).filter { $0.date > snapshot.fetchedAt }.subtracting(attemptedResets)
    }

    private func synchronizeAccounts() {
        let date = now(), rows = accountStore.rows
        accounts = accounts.filter { id, _ in rows.contains(where: { $0.id == id }) }
        attemptedResets.formIntersection(Set(rows.flatMap { resetDeadlines(for: $0) }))
        for row in rows {
            var account = accounts[row.id].flatMap { $0.identity == row.account.identity.key ? $0 : nil }
                ?? AccountSchedule(identity: row.account.identity.key, nextRegularAt: date)
            if let attempt = row.refreshAttemptID, attempt != account.observedAttempt {
                // Card refreshes, login and other explicit store consumers also update only this account.
                account.observedAttempt = attempt
                account.isResetRequest = false
                account.nextRegularAt = date.addingTimeInterval(account.policy.interval.seconds)
            }
            if let completion = row.completedRefreshID, completion == row.refreshAttemptID,
               !row.refreshing, completion != account.processedCompletion {
                account.processedCompletion = completion
                if !account.isResetRequest {
                    account.policy.record(snapshot: row.errorMessage == nil ? row.snapshot : nil)
                    account.nextRegularAt = date.addingTimeInterval(account.policy.interval.seconds)
                }
                // Reset attempts remain additional samples and preserve the regular cadence.
            }
            accounts[row.id] = account
        }
    }

    private func observeAccounts() {
        guard started else { return }
        let current = observationGeneration
        withObservationTracking { _ = accountStore.rows } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.started, self.observationGeneration == current else { return }
                self.observeAccounts()
                self.refreshIfDue()
                self.reconfigure()
            }
        }
    }

    private func reconfigure() {
        generation = UUID()
        schedule?.cancel(); schedule = nil
        guard started && automaticRefreshEnabled && activity.isActive else { return }
        guard let next = accountStore.rows.compactMap({ nextRefreshAt(for: $0.id) }).min() else { return }
        let current = generation
        schedule = scheduler.schedule(every: max(1, next.timeIntervalSince(now()))) { [weak self] in
            guard let self, self.started, self.automaticRefreshEnabled, self.activity.isActive,
                  self.generation == current else { return }
            self.refreshIfDue()
            self.reconfigure()
        }
    }
}
