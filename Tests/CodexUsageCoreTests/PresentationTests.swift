import Foundation
import Testing
@testable import CodexUsageCore

@Test @MainActor func dateModeIsSharedAndPersistsWhileDemoDoesNotWritePreferences() {
    let suite = "DateModeTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = DateDisplayController(defaults: defaults)
    #expect(!controller.absolute)
    controller.toggle()
    #expect(controller.absolute)
    #expect(DateDisplayController(defaults: defaults).absolute)
    let demo = DateDisplayController(defaults: nil)
    demo.toggle()
    #expect(DateDisplayController(defaults: defaults).absolute)
    controller.toggle()
    #expect(!DateDisplayController(defaults: defaults).absolute)
}

@Test func detailedPlanDoesNotInventTierAndKeepsConflictingSourcesVisible() throws {
    #expect(PlanPresentation.title(usage: "pro", auth: nil) == "Pro")
    #expect(PlanPresentation.title(usage: "promax", auth: nil) == "Pro Max")
    #expect(PlanPresentation.title(usage: "pro", auth: "prolite") == "Pro Lite")
    #expect(PlanPresentation.title(usage: "pro", auth: "pro") == "Pro More")
    #expect(PlanPresentation.title(usage: "plus", auth: "promax") == "Plus")
    #expect(PlanPresentation.title(usage: "future-plan", auth: nil) == "future-plan")
    let token = try jwt(["sub": "u", "https://api.openai.com/auth": [
        "chatgpt_account_id": "default", "chatgpt_user_id": "u", "chatgpt_plan_type": "promax",
    ]])
    func credentials(selected: String) throws -> Credentials {
        try Credentials(data: JSONSerialization.data(withJSONObject: ["tokens": ["access_token": token, "account_id": selected]]))
    }
    #expect(try credentials(selected: "default").planHint == "promax")
    #expect(try credentials(selected: "other-workspace").planHint == nil)
    for plan in ["prolite", "promax"] {
        let data = Data("{\"plan_type\":\"\(plan)\",\"spend_control\":{},\"rate_limit\":{\"primary_window\":{\"used_percent\":1}}}".utf8)
        #expect(try !UsageSnapshot.parse(data, expectedAccountID: "a", at: Date()).shouldFetchMonthly)
    }
}
