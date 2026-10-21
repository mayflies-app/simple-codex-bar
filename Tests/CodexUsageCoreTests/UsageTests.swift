import Foundation
import Testing
@testable import CodexUsageCore

let usageFixture = Data(#"""
{
  "account_id":"workspace-a", "plan_type":"plus",
  "rate_limit": {
    "primary_window":{"used_percent":23,"reset_at":1800000000,"limit_window_seconds":18000},
    "secondary_window":{"used_percent":78,"reset_after_seconds":3600,"limit_window_seconds":604800}
  },
  "additional_rate_limits":[
    {"limit_name":"Spark","rate_limit":{"primary_window":{"used_percent":9,"reset_at":1800000000,"limit_window_seconds":18000}}},
    {"limit_name":"broken","rate_limit":{"primary_window":{"used_percent":"bad"}}}
  ],
  "unrelated_future_field": true
}
"""#.utf8)

@Test func mapsCurrentWindowsAndToleratesMalformedOptionalExtras() throws {
    let now = Date(timeIntervalSince1970: 1700000000)
    let usage = try UsageSnapshot.decode(usageFixture, expectedAccountID: "workspace-a", at: now)
    #expect(usage.plan == "plus")
    #expect(usage.windows.count == 3)
    #expect(usage.windows[0].remainingPercent == 77)
    #expect(usage.windows[0].title == "5 小时")
    #expect(usage.windows[1].title == "每周")
    #expect(usage.windows[1].resetsAt == now.addingTimeInterval(3600))
    #expect(usage.fetchedAt == now)
}

@Test func emptyOrMalformedUsageMustNotBecomeZeroUsage() {
    for json in [#"{}"#, #"{"rate_limit":{}}"#,
                 #"{"rate_limit":{"primary_window":{"used_percent":"bad"}}}"#] {
        #expect(throws: UsageError.self) {
            try UsageSnapshot.decode(Data(json.utf8), expectedAccountID: "workspace-a")
        }
    }
}

@Test func refusesWrongWorkspace() {
    #expect(throws: UsageError.self) {
        try UsageSnapshot.decode(usageFixture, expectedAccountID: "workspace-b")
    }
}

@Test func clampsPercentAndDoesNotInventResetTime() throws {
    let data = Data(#"{"rate_limit":{"primary_window":{"used_percent":110,"limit_window_seconds":18000}}}"#.utf8)
    let usage = try UsageSnapshot.decode(data, expectedAccountID: "a")
    #expect(usage.windows[0].remainingPercent == 0)
    #expect(usage.windows[0].resetsAt == nil)
}

@Test func zeroAndOneAreValidUsageButJSONBooleansAreNot() throws {
    for value in ["0", "1"] {
        let data = Data("{\"rate_limit\":{\"primary_window\":{\"used_percent\":\(value)}}}".utf8)
        let usage = try UsageSnapshot.decode(data, expectedAccountID: "a")
        #expect(usage.windows[0].usedPercent == Double(value))
    }
    #expect(throws: UsageError.self) {
        try UsageSnapshot.decode(Data(#"{"rate_limit":{"primary_window":{"used_percent":true}}}"#.utf8), expectedAccountID: "a")
    }
}

@Test func monthlyQuotaWorksWithoutSessionWindowsAndNeverInventsUsage() throws {
    let data = Data(#"{"spend_control":{"individual_limit":{"limit":"1000","used":"200","reset_at":1800000000}}}"#.utf8)
    let usage = try UsageSnapshot.decode(data, expectedAccountID: "a")
    #expect(usage.windows[0].title == "每月额度")
    #expect(usage.windows[0].remainingPercent == 80)
    #expect(throws: UsageError.self) {
        try UsageSnapshot.decode(Data(#"{"individual_limit":{"limit":1000}}"#.utf8), expectedAccountID: "a")
    }
}

@Test func preservesCreditBalanceAndMonthlyCountersWithoutInventingMissingValues() throws {
    let data = Data(#"{"credits":{"has_credits":true,"unlimited":false,"balance":"123.4567"},"individual_limit":{"limit":"1000","used":"201.125"}}"#.utf8)
    let usage = try UsageSnapshot.decode(data, expectedAccountID: "a")
    #expect(usage.credits?.balance == 123.4567)
    #expect(usage.credits?.hasCredits == true)
    #expect(usage.credits?.unlimited == false)
    #expect(usage.windows[0].usedAmount == 201.125)
    #expect(usage.windows[0].limitAmount == 1000)
    #expect(abs(usage.windows[0].remainingPercent - 79.8875) < 0.000001)
    for credits in [#"{}"#, #"{"balance":true}"#, #"{"balance":"NaN"}"#, #"{"balance":-1}"#] {
        let json = "{\"credits\":\(credits),\"rate_limit\":{\"primary_window\":{\"used_percent\":12.3456}}}"
        let result = try UsageSnapshot.decode(Data(json.utf8), expectedAccountID: "a")
        #expect(result.credits == nil)
        #expect(result.windows[0].usedPercent == 12.3456)
        #expect(result.windows[0].usedAmount == nil)
    }
    let flags = try UsageSnapshot.decode(Data(#"{"credits":{"unlimited":true},"rate_limit":{"primary_window":{"used_percent":0}}}"#.utf8), expectedAccountID: "a")
    #expect(flags.credits?.unlimited == true)
    #expect(flags.credits?.balance == nil)
    #expect(flags.credits?.hasCredits == nil)
    let creditOnly = try UsageSnapshot.decode(Data(#"{"credits":{"balance":0,"has_credits":false}}"#.utf8), expectedAccountID: "a")
    #expect(creditOnly.windows.isEmpty && creditOnly.credits?.balance == 0)
    let monthly = try UsageSnapshot.decodeMonthly(Data(#"{"effective_monthly_limit":{"limit":100},"current_month_usage":125}"#.utf8), expectedAccountID: "a")
    guard case let .window(window) = monthly else { Issue.record("Missing monthly quota"); return }
    #expect(window.usedAmount == 125)
    #expect(window.limitAmount == 100)
    #expect(window.remainingPercent == 0)
}
