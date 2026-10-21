import Foundation

public enum UsageError: Error, LocalizedError, Equatable, Sendable {
    case invalidCredentials, apiKeyUnsupported, identityChanged, duplicateAccount
    case reauthenticationRequired, invalidResponse, invalidRefreshResponse, network, http(Int)
    case accountRemoved, credentialsChanged, storage, alreadyRunning, loginFailed, loginTimedOut

    public var errorDescription: String? { message.resolve(in: .simplifiedChinese) }
    public var message: LocalizedText {
        switch self {
        case .invalidCredentials: LocalizedText("error.invalidCredentials")
        case .apiKeyUnsupported: LocalizedText("error.apiKeyUnsupported")
        case .identityChanged: LocalizedText("error.identityChanged")
        case .duplicateAccount: LocalizedText("error.duplicateAccount")
        case .reauthenticationRequired: LocalizedText("error.reauthenticationRequired")
        case .invalidResponse: LocalizedText("error.invalidResponse")
        case .invalidRefreshResponse: LocalizedText("error.invalidRefreshResponse")
        case .network: LocalizedText("error.network")
        case let .http(status): LocalizedText("error.http", String(status))
        case .accountRemoved: LocalizedText("error.accountRemoved")
        case .credentialsChanged: LocalizedText("error.credentialsChanged")
        case .storage: LocalizedText("error.storage")
        case .alreadyRunning: LocalizedText("error.alreadyRunning")
        case .loginFailed: LocalizedText("error.loginFailed")
        case .loginTimedOut: LocalizedText("error.loginTimedOut")
        }
    }
}

public struct AccountIdentity: Codable, Equatable, Sendable {
    public let accountID: String
    public let userID: String
    public let email: String?
    public var key: String { "\(accountID.utf8.count):\(accountID)\(userID)" }
    public init(accountID: String, userID: String, email: String?) {
        self.accountID = accountID; self.userID = userID; self.email = email
    }
}

public enum AccountSource: Codable, Equatable, Sendable {
    case managed
    case linked(path: String)
}

public struct Account: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var label: String
    public let identity: AccountIdentity
    public let source: AccountSource
    public var automaticRefreshEnabled: Bool
    public var displayName: String { displayName(in: .simplifiedChinese) }
    public func displayName(in language: AppLanguage) -> String {
        if !label.isEmpty { return label }
        if let email = identity.email, !email.isEmpty { return email }
        return LocalizedText("account.fallback").resolve(in: language)
    }
    public var isManaged: Bool { source == .managed }
    public init(id: UUID = UUID(), label: String, identity: AccountIdentity, source: AccountSource,
                automaticRefreshEnabled: Bool = true) {
        self.id = id; self.label = label; self.identity = identity; self.source = source
        self.automaticRefreshEnabled = automaticRefreshEnabled
    }

    private enum CodingKeys: String, CodingKey { case id, label, identity, source, automaticRefreshEnabled }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        identity = try container.decode(AccountIdentity.self, forKey: .identity)
        source = try container.decode(AccountSource.self, forKey: .source)
        automaticRefreshEnabled = try container.decodeIfPresent(Bool.self, forKey: .automaticRefreshEnabled) ?? true
    }
}

public struct UsageWindow: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let titleMessage: LocalizedText?
    public let usedPercent: Double
    public let resetsAt: Date?
    public let usedAmount: Double?
    public let limitAmount: Double?
    public var remainingPercent: Double { 100 - usedPercent }
    public func displayTitle(in language: AppLanguage) -> String {
        titleMessage?.resolve(in: language) ?? title
    }
    public init(id: String, title: String, usedPercent: Double, resetsAt: Date?,
                usedAmount: Double? = nil, limitAmount: Double? = nil, titleMessage: LocalizedText? = nil) {
        self.id = id; self.title = title; self.usedPercent = min(100, max(0, usedPercent)); self.resetsAt = resetsAt
        self.usedAmount = usedAmount; self.limitAmount = limitAmount
        self.titleMessage = titleMessage
    }
}

public struct CreditBalance: Codable, Equatable, Sendable {
    public let balance: Double?
    public let hasCredits: Bool?
    public let unlimited: Bool?
    public init(balance: Double?, hasCredits: Bool?, unlimited: Bool?) {
        self.balance = balance; self.hasCredits = hasCredits; self.unlimited = unlimited
    }
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public let plan: String?
    public let windows: [UsageWindow]
    public let fetchedAt: Date
    public let notice: String?
    public let noticeMessage: LocalizedText?
    public let credits: CreditBalance?
    public let authPlan: String?
    public func displayNotice(in language: AppLanguage) -> String? {
        noticeMessage?.resolve(in: language) ?? notice
    }
    public init(plan: String?, windows: [UsageWindow], fetchedAt: Date = Date(), notice: String? = nil,
                credits: CreditBalance? = nil, authPlan: String? = nil, noticeMessage: LocalizedText? = nil) {
        self.plan = plan; self.windows = windows; self.fetchedAt = fetchedAt; self.notice = notice
        self.credits = credits
        self.authPlan = authPlan
        self.noticeMessage = noticeMessage
    }
}
