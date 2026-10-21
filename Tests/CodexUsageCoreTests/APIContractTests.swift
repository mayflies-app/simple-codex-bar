import Foundation
import Testing
@testable import CodexUsageCore

@Test func responseIdentityAliasesCannotBeHiddenByNullBadTypeOrConflict() throws {
    for hidden: Any in [NSNull(), 42, ""] {
        let data = try JSONSerialization.data(withJSONObject: [
            "account_id": hidden, "accountId": "workspace-b",
            "rate_limit": ["primary_window": ["used_percent": 23]],
        ])
        #expect(throws: UsageError.identityChanged) { try UsageSnapshot.decode(data, expectedAccountID: "workspace-a") }
    }
    let conflict = Data(#"{"account_id":"workspace-a","accountId":"workspace-b","rate_limit":{"primary_window":{"used_percent":23}}}"#.utf8)
    #expect(throws: UsageError.identityChanged) { try UsageSnapshot.decode(conflict, expectedAccountID: "workspace-a") }
}

@Test func credentialAliasesUseConvertedValuesAndJWTUserConflictsFailClosed() throws {
    let original = try JSONSerialization.jsonObject(with: authData()) as! [String: Any]
    let tokens = original["tokens"] as! [String: Any]
    let aliased = try JSONSerialization.data(withJSONObject: ["tokens": [
        "access_token": NSNull(), "accessToken": tokens["access_token"]!,
        "account_id": NSNull(), "accountId": "workspace-a",
        "refresh_token": "", "refreshToken": "valid-refresh",
    ]])
    let c = try Credentials(data: aliased)
    #expect(c.refreshToken == "valid-refresh")
    #expect(c.identity.accountID == "workspace-a")
    let wrongID = try jwt(["email": "wrong@example.invalid",
                           "https://api.openai.com/auth": ["chatgpt_user_id": "user-b", "chatgpt_account_id": "workspace-a"]])
    var inconsistent = tokens
    inconsistent["id_token"] = wrongID
    let data = try JSONSerialization.data(withJSONObject: ["tokens": inconsistent])
    #expect(throws: UsageError.identityChanged) { try Credentials(data: data) }
}

@Test func explicitWorkspaceSelectionIsNotConfusedWithJWTDefaultWorkspace() throws {
    var object = try JSONSerialization.jsonObject(with: authData()) as! [String: Any]
    var tokens = object["tokens"] as! [String: Any]
    tokens["account_id"] = "selected-workspace"
    object["tokens"] = tokens
    #expect(try Credentials(data: JSONSerialization.data(withJSONObject: object)).identity.accountID == "selected-workspace")
}

@Test func refreshMustContainFreshUserEvidenceRatherThanOnlyAnOldIDToken() throws {
    let id = try jwt(["sub": "user-a", "email": "a@example.invalid"])
    let original = try JSONSerialization.data(withJSONObject: ["tokens": [
        "access_token": "old-opaque", "id_token": id, "refresh_token": "old-r", "account_id": "workspace-a",
    ]])
    let unverifiable = Data(#"{"access_token":"new-opaque","refresh_token":"new-r"}"#.utf8)
    #expect(throws: UsageError.invalidRefreshResponse) { try Credentials.applyingRefresh(unverifiable, to: original) }
    let verifiable = try JSONSerialization.data(withJSONObject: ["access_token": "new-opaque", "id_token": id, "refresh_token": "new-r"])
    #expect(try Credentials(data: Credentials.applyingRefresh(verifiable, to: original)).refreshToken == "new-r")
}

@Test func unchangedCanonicalUserCannotHideChangedIDTokenSubject() throws {
    let access = try jwt(["sub": "access-sub-a", "https://api.openai.com/auth": [
        "chatgpt_user_id": "user-a", "chatgpt_account_id": "jwt-default",
    ]])
    let id = try jwt(["sub": "id-sub-a", "email": "a@example.invalid"])
    let original = try JSONSerialization.data(withJSONObject: ["tokens": [
        "access_token": access, "id_token": id, "refresh_token": "old-r", "account_id": "selected-workspace",
    ]])
    let wrongID = try jwt(["sub": "id-sub-b", "email": "b@example.invalid"])
    let wrong = try JSONSerialization.data(withJSONObject: ["access_token": access, "id_token": wrongID, "refresh_token": "new-r"])
    #expect(throws: UsageError.identityChanged) { try Credentials.applyingRefresh(wrong, to: original) }
    let stable = try JSONSerialization.data(withJSONObject: ["access_token": access, "id_token": id, "refresh_token": "new-r"])
    let saved = try Credentials(data: Credentials.applyingRefresh(stable, to: original))
    #expect(saved.identity.accountID == "selected-workspace")
    #expect(saved.identity.userID == "user-a")
}

@Test func mixedExtraArrayKeepsValidSiblingsAndSemanticIDsSurviveReordering() throws {
    let valid: [String: Any] = ["limit_name": "Spark", "metered_feature": "codex-spark",
        "rate_limit": ["primary_window": ["used_percent": 9, "limit_window_seconds": 18000]]]
    let other: [String: Any] = ["limit_name": "Other Model",
        "rate_limit": ["primary_window": ["used_percent": 31, "limit_window_seconds": 18000]]]
    func decode(_ extras: [Any]) throws -> UsageSnapshot {
        let data = try JSONSerialization.data(withJSONObject: [
            "rate_limit": ["primary_window": ["used_percent": 23]], "additional_rate_limits": extras,
        ])
        return try UsageSnapshot.decode(data, expectedAccountID: "a")
    }
    let a = try decode([NSNull(), "bad", 7, valid, other])
    let b = try decode([other, valid, NSNull()])
    #expect(a.windows.count == 3)
    #expect(Set(a.windows.map(\.id)) == Set(b.windows.map(\.id)))
    #expect(a.windows.first(where: { $0.title.contains("Spark") })?.remainingPercent == 91)
}

@Test func monthlyAliasesAndSourcePrecedenceDoNotInventMissingUsage() throws {
    let data = Data(#"{"individual_limit":null,"spend_control":null,"spendControl":{"individualLimit":{"limit":"1000","remaining_percent":null,"remainingPercent":80,"reset_at":null,"resets_at":1800000000}}}"#.utf8)
    let usage = try UsageSnapshot.decode(data, expectedAccountID: "a")
    #expect(usage.windows.count == 1)
    #expect(usage.windows[0].remainingPercent == 80)
    #expect(usage.windows[0].resetsAt == Date(timeIntervalSince1970: 1800000000))
    let missing = Data(#"{"individual_limit":{"limit":1000},"rate_limit":{"primary_window":{"used_percent":23},"individual_limit":{"limit":1000,"used":200}}}"#.utf8)
    #expect(try UsageSnapshot.decode(missing, expectedAccountID: "a").windows.count == 1)
}

@Test func windowRolesAreNormalizedAndIDsDoNotDependOnWireSlot() throws {
    func decode(_ primary: Int?, _ secondary: Int?) throws -> UsageSnapshot {
        var windows: [String: Any] = [:]
        if let primary { windows["primary_window"] = ["used_percent": 20, "limit_window_seconds": primary] }
        if let secondary { windows["secondary_window"] = ["used_percent": 40, "limit_window_seconds": secondary] }
        return try UsageSnapshot.decode(JSONSerialization.data(withJSONObject: ["rate_limit": windows]), expectedAccountID: "a")
    }
    let normal = try decode(18000, 604800)
    let reversed = try decode(604800, 18000)
    #expect(reversed.windows.map(\.title) == ["5 小时", "每周"])
    #expect(normal.windows.map(\.id) == reversed.windows.map(\.id))
    #expect(try decode(604800, nil).windows[0].id == normal.windows[1].id)
    #expect(try decode(nil, 18000).windows[0].id == normal.windows[0].id)
}
