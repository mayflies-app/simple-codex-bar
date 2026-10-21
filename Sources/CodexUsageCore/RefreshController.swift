import Foundation
import Observation
import CoreFoundation

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

/// All automatic entry points share one policy; manual refresh is independent of that policy.
@MainActor @Observable
public final class RefreshController {
    public private(set) var automaticRefreshEnabled: Bool
    public private(set) var refreshInterval: RefreshInterval
    public private(set) var activity: MacActivityState = .active
    public private(set) var lastRefreshAt: Date?
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let scheduler: any RefreshScheduler
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let activityProvider: (@MainActor () -> MacActivityState)?
    @ObservationIgnored private let onRefresh: @MainActor () -> Void
    @ObservationIgnored private let onManualRefresh: @MainActor () -> Void
    @ObservationIgnored private var schedule: (any RefreshSchedule)?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var started = false
    public static let preferenceKey = "AutomaticRefreshEnabled"
    public static let intervalPreferenceKey = "RefreshIntervalMinutes"

    public init(defaults: UserDefaults? = .standard, enabled: Bool = true,
                scheduler: any RefreshScheduler = TimerRefreshScheduler(),
                now: @escaping @MainActor () -> Date = { Date() },
                activityProvider: (@MainActor () -> MacActivityState)? = nil,
                onManualRefresh: (@MainActor () -> Void)? = nil,
                onRefresh: @escaping @MainActor () -> Void) {
        self.defaults = defaults; self.scheduler = scheduler; self.onRefresh = onRefresh; self.now = now
        self.activityProvider = activityProvider
        self.onManualRefresh = onManualRefresh ?? onRefresh
        automaticRefreshEnabled = (defaults?.object(forKey: Self.preferenceKey) as? Bool) ?? enabled
        if let stored = defaults?.object(forKey: Self.intervalPreferenceKey) as? NSNumber,
           CFGetTypeID(stored) != CFBooleanGetTypeID(),
           let interval = RefreshInterval.allCases.first(where: { Double($0.rawValue) == stored.doubleValue }) {
            refreshInterval = interval
        } else { refreshInterval = .fiveMinutes }
    }

    public func start() {
        guard !started else { return }
        started = true
        refreshIfDue(force: true)
        reconfigure()
    }

    public func stop() {
        started = false
        generation = UUID()
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

    /// Wake notifications are hints, never an exemption from the activity and elapsed-time policy.
    public func handleWake() {
        let previousActivity = activity, previousRefresh = lastRefreshAt
        refreshIfDue()
        if previousActivity != activity || previousRefresh != lastRefreshAt { reconfigure() }
    }

    public func refreshManually() {
        lastRefreshAt = now()
        onManualRefresh()
        reconfigure()
    }

    public func setRefreshInterval(_ interval: RefreshInterval) {
        guard refreshInterval != interval else { return }
        refreshInterval = interval
        defaults?.set(interval.rawValue, forKey: Self.intervalPreferenceKey)
        reconfigure() // Use the last refresh time without issuing requests from the settings action.
    }

    private func refreshIfDue(force: Bool = false) {
        if let activityProvider { activity = activityProvider() }
        guard started && automaticRefreshEnabled && activity.isActive else { return }
        let date = now()
        guard force || lastRefreshAt == nil || date.timeIntervalSince(lastRefreshAt!) >= refreshInterval.seconds else { return }
        // Record attempts too: errors or offline state must not cause repeated resume requests.
        lastRefreshAt = date
        onRefresh()
    }

    private func reconfigure() {
        generation = UUID()
        schedule?.cancel(); schedule = nil
        guard started && automaticRefreshEnabled && activity.isActive else { return }
        let current = generation
        let elapsed = lastRefreshAt.map { now().timeIntervalSince($0) } ?? refreshInterval.seconds
        let delay = max(1, min(refreshInterval.seconds, refreshInterval.seconds - elapsed))
        schedule = scheduler.schedule(every: delay) { [weak self] in
            guard let self, self.started, self.automaticRefreshEnabled, self.activity.isActive,
                  self.generation == current else { return }
            self.refreshIfDue()
            self.reconfigure()
        }
    }
}
