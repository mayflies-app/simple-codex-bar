import Foundation
import CoreFoundation

/// JWT claims are display/scheduling hints only. The server authenticates the bearer token.
/// No secrets conform to CustomStringConvertible or appear in surfaced errors.
public struct Credentials: Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let identity: AccountIdentity
    public let expiresAt: Date?
    public let lastRefresh: Date?
    public let planHint: String?

    public init(data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.invalidCredentials
        }
        if let key = Self.text(object["OPENAI_API_KEY"]), !key.isEmpty { throw UsageError.apiKeyUnsupported }
        guard let tokens = object["tokens"] as? [String: Any],
              let access = JSONFields.text(tokens["access_token"], tokens["accessToken"]), JSONFields.safeHeader(access) else {
            throw UsageError.invalidCredentials
        }
        let accessClaims = Self.claims(access)
        let idClaims = Self.claims(JSONFields.text(tokens["id_token"], tokens["idToken"]) ?? "")
        let claims = [accessClaims, idClaims]
        // Explicit workspace selection may legitimately differ from the JWT's default workspace.
        let account = try JSONFields.accountID(tokens)
            ?? [idClaims, accessClaims].compactMap { Self.authText($0, "chatgpt_account_id") }.first
        let canonicalUsers = Set(claims.compactMap { Self.authText($0, "chatgpt_user_id") })
        guard canonicalUsers.count <= 1 else { throw UsageError.identityChanged }
        let subjects = Set(claims.compactMap { Self.text($0["sub"]) })
        if canonicalUsers.isEmpty && subjects.count > 1 { throw UsageError.identityChanged }
        let user = canonicalUsers.first
            ?? claims.compactMap { Self.text($0["sub"]) }.first
        let email = [idClaims, accessClaims].compactMap { payload -> String? in
            Self.text(payload["email"])
                ?? Self.text((payload["https://api.openai.com/profile"] as? [String: Any])?["email"])
        }.first
        guard let account, let user, JSONFields.safeHeader(account) else { throw UsageError.invalidCredentials }
        accessToken = access
        refreshToken = JSONFields.text(tokens["refresh_token"], tokens["refreshToken"]) ?? ""
        identity = AccountIdentity(accountID: account, userID: user, email: email)
        // A JWT's default workspace plan cannot describe an explicitly selected different workspace.
        planHint = claims.first { Self.authText($0, "chatgpt_account_id") == account }
            .flatMap { Self.authText($0, "chatgpt_plan_type") }
        if let exp = accessClaims["exp"] as? NSNumber, CFGetTypeID(exp) != CFBooleanGetTypeID(),
           exp.doubleValue.isFinite, exp.doubleValue.rounded(.towardZero) == exp.doubleValue,
           exp.doubleValue >= 0, exp.doubleValue < 253402300800 {
            expiresAt = Date(timeIntervalSince1970: exp.doubleValue)
        } else { expiresAt = nil }
        if let raw = Self.text(object["last_refresh"]) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            lastRefresh = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        } else { lastRefresh = nil }
    }

    public func needsRefresh(at now: Date = Date()) -> Bool {
        if let expiresAt { return expiresAt.timeIntervalSince(now) <= 300 }
        return lastRefresh.map { now.timeIntervalSince($0) > 8 * 24 * 3600 } ?? false
    }

    static func text(_ value: Any?) -> String? {
        JSONFields.text(value)
    }

    private static func authText(_ claims: [String: Any], _ key: String) -> String? {
        JSONFields.text((claims["https://api.openai.com/auth"] as? [String: Any])?[key], claims[key])
    }

    private static func claims(_ token: String) -> [String: Any] {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return [:] }
        var value = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    /// Merge only a successful refresh, retaining account/workspace selection and unknown auth fields.
    static func applyingRefresh(_ response: Data, to original: Data) throws -> Data {
        guard let refresh = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              let access = text(refresh["access_token"]),
              var object = try? JSONSerialization.jsonObject(with: original) as? [String: Any],
              var tokens = object["tokens"] as? [String: Any] else { throw UsageError.invalidRefreshResponse }
        if let type = refresh["token_type"], !(type is NSNull), text(type)?.lowercased() != "bearer" {
            throw UsageError.invalidRefreshResponse
        }
        for key in ["refresh_token", "id_token"] {
            if let value = refresh[key], !(value is NSNull), text(value) == nil { throw UsageError.invalidRefreshResponse }
        }
        let old = try Credentials(data: original)
        let freshID = text(refresh["id_token"])
        if let freshID {
            guard let freshSubject = text(claims(freshID)["sub"]) else { throw UsageError.invalidRefreshResponse }
            let oldID = JSONFields.text(tokens["id_token"], tokens["idToken"])
            if let oldSubject = text(claims(oldID ?? "")["sub"]), oldSubject != freshSubject {
                throw UsageError.identityChanged
            }
        }
        // Validate only newly returned identity hints, never old id_token material masquerading as fresh evidence.
        let freshClaims = [claims(access), claims(freshID ?? "")]
        let freshUsers = Set(freshClaims.compactMap { authText($0, "chatgpt_user_id") })
        let freshSubjects = Set(freshClaims.compactMap { text($0["sub"]) })
        guard !freshUsers.isEmpty || !freshSubjects.isEmpty else { throw UsageError.invalidRefreshResponse }
        if !freshUsers.isEmpty {
            guard freshUsers == [old.identity.userID] else { throw UsageError.identityChanged }
        } else {
            let oldClaims = [claims(JSONFields.text(tokens["access_token"], tokens["accessToken"]) ?? ""),
                             claims(JSONFields.text(tokens["id_token"], tokens["idToken"]) ?? "")]
            let oldSubjects = Set(oldClaims.compactMap { text($0["sub"]) })
            guard freshSubjects.isSubset(of: oldSubjects), !oldSubjects.isEmpty else { throw UsageError.identityChanged }
        }
        tokens["access_token"] = access
        if let value = text(refresh["refresh_token"]) { tokens["refresh_token"] = value }
        if let freshID { tokens["id_token"] = freshID }
        object["tokens"] = tokens
        object["last_refresh"] = ISO8601DateFormatter().string(from: Date())
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard try Credentials(data: data).identity.key == Credentials(data: original).identity.key else {
            throw UsageError.identityChanged
        }
        return data
    }
}
