import Foundation

/// Display-only inventory. No credit identifiers or redemption capability are retained.
public struct BankedResets: Codable, Equatable, Sendable {
    public let reportedAvailableCount: Int
    private let expirations: [Date?]

    private enum CodingKeys: String, CodingKey { case reportedAvailableCount, expirations }

    private init(reportedAvailableCount: Int, expirations: [Date?]) {
        self.reportedAvailableCount = reportedAvailableCount
        self.expirations = expirations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reportedAvailableCount = try container.decode(Int.self, forKey: .reportedAvailableCount)
        expirations = try container.decode([Date?].self, forKey: .expirations)
        guard reportedAvailableCount >= 0, reportedAvailableCount <= expirations.count else {
            throw DecodingError.dataCorruptedError(forKey: .reportedAvailableCount, in: container,
                                                   debugDescription: "Invalid reset inventory count")
        }
    }

    public func availableExpirations(at now: Date) -> [Date?] {
        Array(expirations.filter { $0.map { $0 > now } ?? true }
            .sorted { ($0 ?? .distantFuture) < ($1 ?? .distantFuture) }
            .prefix(reportedAvailableCount))
    }

    public func availableCount(at now: Date) -> Int { availableExpirations(at: now).count }

    static func decode(_ data: Data, expectedAccountID: String) throws -> Self {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.invalidResponse
        }
        try JSONFields.validateAccount(object, expected: expectedAccountID)
        guard let count = JSONFields.number(object["available_count"]), count >= 0,
              count.rounded(.towardZero) == count, count < Double(Int.max),
              let credits = object["credits"] as? [[String: Any]] else { throw UsageError.invalidResponse }
        let formatter = ISO8601DateFormatter()
        var expirations: [Date?] = []
        for credit in credits {
            guard let status = JSONFields.text(credit["status"]) else { throw UsageError.invalidResponse }
            guard status == "available" else { continue }
            var expiry: Date?
            if let raw = credit["expires_at"], !(raw is NSNull) {
                guard let text = raw as? String else { throw UsageError.invalidResponse }
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                expiry = formatter.date(from: text)
                if expiry == nil {
                    formatter.formatOptions = [.withInternetDateTime]
                    expiry = formatter.date(from: text)
                }
                guard expiry != nil else { throw UsageError.invalidResponse }
            }
            expirations.append(expiry)
        }
        // An incomplete inventory is unavailable, never a fabricated zero.
        guard Int(count) <= expirations.count else { throw UsageError.invalidResponse }
        return Self(reportedAvailableCount: Int(count), expirations: expirations)
    }
}

/// Every account-usage request passes this gate before reaching any transport.
/// Credential renewal is a separate authentication operation, outside quota access.
enum ReadOnlyUsageRequest {
    static func validate(_ request: URLRequest) throws {
        guard request.httpMethod == "GET", request.httpBody == nil, request.httpBodyStream == nil,
              let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == "chatgpt.com", parts.port == nil,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw UsageError.invalidResponse
        }
        let path = parts.percentEncodedPath
        if ["/backend-api/wham/usage", "/backend-api/wham/rate-limit-reset-credits"].contains(path) { return }
        let prefix = "/backend-api/accounts/"
        let suffix = "/spend-controls/current-user/monthly-usage"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { throw UsageError.invalidResponse }
        let account = path.dropFirst(prefix.count).dropLast(suffix.count)
        guard !account.isEmpty, !account.contains("/"), account != ".", account != ".." else {
            throw UsageError.invalidResponse
        }
    }
}
