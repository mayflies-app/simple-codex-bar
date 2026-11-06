import Foundation

/// Uses only observed usage, never timestamps, cached failures or missing values as zero.
struct AdaptiveRefreshPolicy {
    private(set) var interval: RefreshInterval = .fiveMinutes
    private var previous: UsageSnapshot?
    private var failures = 0

    mutating func record(snapshot: UsageSnapshot?) {
        guard let snapshot else {
            failures = min(3, failures + 1)
            let backoff: RefreshInterval = failures == 1 ? .fiveMinutes : failures == 2 ? .fifteenMinutes : .thirtyMinutes
            if backoff.rawValue > interval.rawValue { interval = backoff }
            return
        }
        let recovering = failures > 0
        failures = 0
        defer { previous = snapshot }
        guard let previous else { interval = .fiveMinutes; return }
        var comparisons: [Bool] = []
        for window in snapshot.windows {
            guard let old = previous.windows.first(where: { $0.id == window.id }) else { continue }
            comparisons.append(window.usedPercent != old.usedPercent)
            if let used = window.usedAmount, let oldUsed = old.usedAmount { comparisons.append(used != oldUsed) }
        }
        if let balance = snapshot.credits?.balance, let oldBalance = previous.credits?.balance {
            comparisons.append(balance != oldBalance)
        }
        if comparisons.contains(true) { interval = .oneMinute }
        else if comparisons.isEmpty || recovering { interval = .fiveMinutes }
        else {
            switch interval {
            case .oneMinute: interval = .twoMinutes
            case .twoMinutes: interval = .fiveMinutes
            case .fiveMinutes: interval = .fifteenMinutes
            case .fifteenMinutes, .thirtyMinutes: interval = .thirtyMinutes
            }
        }
    }
}
