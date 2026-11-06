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
    for expected in [RefreshInterval.twoMinutes, .fiveMinutes, .fifteenMinutes, .thirtyMinutes, .thirtyMinutes] {
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
    #expect(policy.interval == .fifteenMinutes)
    policy.record(snapshot: UsageSnapshot(plan: "pro", windows: [
        UsageWindow(id: "session", title: "Renamed by service", usedPercent: 20, resetsAt: nil)
    ]))
    #expect(policy.interval == .thirtyMinutes)
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

@Test func failureDoesNotAccelerateAnAlreadyQuietAccount() {
    var policy = AdaptiveRefreshPolicy()
    for _ in 0..<3 { policy.record(snapshot: reading(20)) }
    #expect(policy.interval == .thirtyMinutes)
    policy.record(snapshot: nil)
    #expect(policy.interval == .thirtyMinutes)
}
