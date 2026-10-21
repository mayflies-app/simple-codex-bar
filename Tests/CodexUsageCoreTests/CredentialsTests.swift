import Foundation
import Testing
@testable import CodexUsageCore

func jwt(_ claims: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: claims)
    let payload = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return "header.\(payload).signature"
}

func authData(account: String = "workspace-a", user: String = "user-a",
              email: String = "a@example.com", expires: Double = Date().timeIntervalSince1970 + 3600,
              refresh: String = "refresh-a") throws -> Data {
    let token = try jwt([
        "exp": Int(expires), "sub": user,
        "https://api.openai.com/auth": ["chatgpt_account_id": account, "chatgpt_user_id": user],
        "https://api.openai.com/profile": ["email": email],
    ])
    return try JSONSerialization.data(withJSONObject: [
        "tokens": ["access_token": token, "refresh_token": refresh, "account_id": account],
        "last_refresh": "2026-10-07T00:00:00Z",
    ])
}

@Test func extractsWorkspaceUserAndExpiryWithoutTrustingEmailAsIdentity() throws {
    let credentials = try Credentials(data: authData(expires: 1000))
    #expect(credentials.identity.accountID == "workspace-a")
    #expect(credentials.identity.userID == "user-a")
    #expect(credentials.identity.email == "a@example.com")
    #expect(credentials.needsRefresh(at: Date(timeIntervalSince1970: 800)))
    #expect(!credentials.needsRefresh(at: Date(timeIntervalSince1970: 600)))
    let other = try Credentials(data: authData(user: "user-b"))
    #expect(credentials.identity.key != other.identity.key)
}

@Test func rejectsAPIKeysAndMissingAccountIdentity() throws {
    #expect(throws: UsageError.self) { try Credentials(data: Data(#"{"OPENAI_API_KEY":"sk-test"}"#.utf8)) }
    #expect(throws: UsageError.self) {
        try Credentials(data: Data(#"{"tokens":{"access_token":"opaque","refresh_token":"r"}}"#.utf8))
    }
}

@Test func idTokenCanSupplyIdentityAndEmail() throws {
    let id = try jwt(["email": "id@example.com", "sub": "id-user",
                      "https://api.openai.com/auth": ["chatgpt_account_id": "id-workspace"]])
    let data = try JSONSerialization.data(withJSONObject: [
        "tokens": ["access_token": "opaque", "id_token": id, "refresh_token": "r"],
    ])
    let c = try Credentials(data: data)
    #expect(c.identity.accountID == "id-workspace")
    #expect(c.identity.email == "id@example.com")
}
