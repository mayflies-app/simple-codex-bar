import Foundation

/// Polls successful readings at least every five minutes so quiet accounts can detect resumed usage.
/// Uses only observed usage, never timestamps, cached failures or missing values as zero.
struct AdaptiveRefreshPolicy {
    private(set) var interval: RefreshInterval = .fiveMinutes
    // Keep scheduling baselines across partial responses; never synthesize displayed usage.
    private var previousWindows: [String: UsageWindow] = [:]
    private var previousBalance: Double?
    private var failures = 0

    /// Successful reset-time samples update comparisons without changing cadence or failure backoff.
    mutating func recordSupplemental(snapshot: UsageSnapshot) {
        for window in snapshot.windows { previousWindows[window.id] = window }
        if let balance = snapshot.credits?.balance { previousBalance = balance }
    }

    mutating func record(snapshot: UsageSnapshot?) {
        guard let snapshot else {
            failures = min(3, failures + 1)
            let backoff: RefreshInterval = failures == 1 ? .fiveMinutes : failures == 2 ? .fifteenMinutes : .thirtyMinutes
            if backoff.rawValue > interval.rawValue { interval = backoff }
            return
        }
        let recovering = failures > 0
        failures = 0
        var comparisons: [Bool] = []
        for window in snapshot.windows {
            if let old = previousWindows[window.id] {
                // Raw counters distinguish consumption from quota changes, including above 100%.
                if let used = window.usedAmount, let oldUsed = old.usedAmount {
                    comparisons.append(used > oldUsed)
                } else if window.limitAmount == old.limitAmount {
                    comparisons.append(window.usedPercent > old.usedPercent)
                }
            }
        }
        if let balance = snapshot.credits?.balance, let oldBalance = previousBalance {
            comparisons.append(balance < oldBalance)
        }
        recordSupplemental(snapshot: snapshot)
        if comparisons.contains(true) { interval = .oneMinute }
        else if comparisons.isEmpty || recovering { interval = .fiveMinutes }
        else {
            switch interval {
            case .oneMinute: interval = .twoMinutes
            case .twoMinutes: interval = .fiveMinutes
            case .fiveMinutes, .fifteenMinutes, .thirtyMinutes: interval = .fiveMinutes
            }
        }
    }
}
