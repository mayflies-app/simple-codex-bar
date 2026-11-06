import Foundation
import Testing
@testable import CodexUsageCore

private func reading(_ used: Double, at date: Date = Date(), reset: Date? = nil) -> UsageSnapshot {
    UsageSnapshot(plan: "plus", windows: [UsageWindow(id: "session", title: "Usage", usedPercent: used,
                                                      resetsAt: reset)], fetchedAt: date)
}

@Test func activityAcceleratesAndStableUsageGraduallySlowsWithinBounds() {
    var policy = AdaptiveRefreshPolicy()
    policy.record(snapshot: reading(20))
    #expect(policy.interval == .fiveMinutes)
    policy.record(snapshot: reading(21))
    #expect(policy.interval == .oneMinute)
    for expected in [RefreshInterval.twoMinutes, .fiveMinutes, .fiveMinutes, .fiveMinutes, .fiveMinutes] {
        policy.record(snapshot: reading(21))
        #expect(policy.interval == expected)
    }
    policy.record(snapshot: reading(22))
    #expect(policy.interval == .oneMinute)
}

@Test func timestampsAndServiceMetadataDoNotCountAsUsageActivity() {
    var policy = AdaptiveRefreshPolicy()
    policy.record(snapshot: reading(20, at: Date(timeIntervalSince1970: 1000)))
    policy.record(snapshot: reading(20, at: Date(timeIntervalSince1970: 1300), reset: Date(timeIntervalSince1970: 5000)))
    #expect(policy.interval == .fiveMinutes)
    policy.record(snapshot: UsageSnapshot(plan: "pro", windows: [
        UsageWindow(id: "session", title: "Renamed by service", usedPercent: 20, resetsAt: nil)
    ]))
    #expect(policy.interval == .fiveMinutes)
}

@Test func failuresBackOffIndependentlyAndRecoveryDoesNotTreatCachedUsageAsNew() {
    var policy = AdaptiveRefreshPolicy()
    policy.record(snapshot: reading(20))
    policy.record(snapshot: reading(21))
    for expected in [RefreshInterval.fiveMinutes, .fifteenMinutes, .thirtyMinutes, .thirtyMinutes] {
        policy.record(snapshot: nil)
        #expect(policy.interval == expected)
    }
    policy.record(snapshot: reading(21))
    #expect(policy.interval == .fiveMinutes)
    policy.record(snapshot: nil)
    policy.record(snapshot: reading(22))
    #expect(policy.interval == .oneMinute)
}

@Test func missingMeasurementsStayUnknownAndCreditConsumptionIsActivity() {
    var policy = AdaptiveRefreshPolicy()
    policy.record(snapshot: reading(20))
    policy.record(snapshot: UsageSnapshot(plan: "plus", windows: []))
    #expect(policy.interval == .fiveMinutes)
    policy.record(snapshot: UsageSnapshot(plan: "plus", windows: [], credits: .init(balance: 10, hasCredits: true, unlimited: false)))
    #expect(policy.interval == .fiveMinutes)
    policy.record(snapshot: UsageSnapshot(plan: "plus", windows: [], credits: .init(balance: 9, hasCredits: true, unlimited: false)))
    #expect(policy.interval == .oneMinute)
}

@Test func quietAccountsStillBackOffOnlyAfterRepeatedFailures() {
    var policy = AdaptiveRefreshPolicy()
    for _ in 0..<3 { policy.record(snapshot: reading(20)) }
    #expect(policy.interval == .fiveMinutes)
    policy.record(snapshot: nil)
    #expect(policy.interval == .fiveMinutes)
    policy.record(snapshot: nil)
    #expect(policy.interval == .fifteenMinutes)
    policy.record(snapshot: nil)
    #expect(policy.interval == .thirtyMinutes)
}

@Test func quotaResetAndCreditTopUpDoNotCountAsConsumption() {
    var policy = AdaptiveRefreshPolicy()
    policy.record(snapshot: reading(90))
    policy.record(snapshot: reading(0))
    #expect(policy.interval == .fiveMinutes)
    policy.record(snapshot: reading(1))
    #expect(policy.interval == .oneMinute)

    var credits = AdaptiveRefreshPolicy()
    for balance in [10.0, 20.0] {
        credits.record(snapshot: UsageSnapshot(plan: "plus", windows: [],
            credits: .init(balance: balance, hasCredits: true, unlimited: false)))
        #expect(credits.interval == .fiveMinutes)
    }
    credits.record(snapshot: UsageSnapshot(plan: "plus", windows: [],
        credits: .init(balance: 19, hasCredits: true, unlimited: false)))
    #expect(credits.interval == .oneMinute)
}

@Test func monthlyConsumptionUsesRawAmountInsteadOfQuotaPercentage() {
    var policy = AdaptiveRefreshPolicy()
    func monthly(_ used: Double, limit: Double) -> UsageSnapshot {
        UsageSnapshot(plan: "business", windows: [
            UsageWindow(id: "monthly", title: "Monthly", usedPercent: min(100, used / limit * 100),
                        resetsAt: nil, usedAmount: used, limitAmount: limit)
        ])
    }
    policy.record(snapshot: monthly(100, limit: 1000))
    policy.record(snapshot: monthly(100, limit: 500))
    #expect(policy.interval == .fiveMinutes) // A smaller allowance is not consumption.
    policy.record(snapshot: monthly(101, limit: 2000))
    #expect(policy.interval == .oneMinute) // Consumption rose even though the percentage fell.
    policy.record(snapshot: monthly(2000, limit: 2000))
    policy.record(snapshot: monthly(2001, limit: 2000))
    #expect(policy.interval == .oneMinute) // Counts can still increase above 100%.
}

@Test func temporarilyMissingMeasurementsPreserveTheirComparisonBaseline() {
    var policy = AdaptiveRefreshPolicy()
    policy.record(snapshot: UsageSnapshot(plan: "plus", windows: [
        UsageWindow(id: "session", title: "Usage", usedPercent: 20, resetsAt: nil)
    ], credits: .init(balance: 10, hasCredits: true, unlimited: false)))
    policy.record(snapshot: UsageSnapshot(plan: "plus", windows: []))
    #expect(policy.interval == .fiveMinutes)
    policy.record(snapshot: reading(21))
    #expect(policy.interval == .oneMinute)
    policy.record(snapshot: UsageSnapshot(plan: "plus", windows: [],
        credits: .init(balance: nil, hasCredits: true, unlimited: false)))
    #expect(policy.interval == .fiveMinutes)
    policy.record(snapshot: UsageSnapshot(plan: "plus", windows: [],
        credits: .init(balance: 9, hasCredits: true, unlimited: false)))
    #expect(policy.interval == .oneMinute)
}

@Test func percentageOnlyReadingsRequireComparableQuotaLimits() {
    var policy = AdaptiveRefreshPolicy()
    func monthly(_ percent: Double, limit: Double) -> UsageSnapshot {
        UsageSnapshot(plan: "business", windows: [
            UsageWindow(id: "monthly", title: "Monthly", usedPercent: percent,
                        resetsAt: nil, limitAmount: limit)
        ])
    }
    policy.record(snapshot: monthly(10, limit: 1000))
    policy.record(snapshot: monthly(20, limit: 500))
    #expect(policy.interval == .fiveMinutes)
    policy.record(snapshot: monthly(21, limit: 500))
    #expect(policy.interval == .oneMinute)
}
