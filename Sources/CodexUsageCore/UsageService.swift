import Foundation

public struct HTTPResponse: Sendable {
    public let status: Int
    public let data: Data
    public init(status: Int, data: Data) { self.status = status; self.data = data }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

/// A dedicated ephemeral session: no cookie import, caches, credential persistence or redirects.
public final class URLSessionTransport: NSObject, HTTPTransport, URLSessionTaskDelegate, Sendable {
    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForResource = 45
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, data.count <= 2_097_152 else {
                throw UsageError.invalidResponse
            }
            return HTTPResponse(status: response.statusCode, data: data)
        } catch is CancellationError { throw CancellationError() }
        catch let error as UsageError { throw error }
        catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw UsageError.network
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                           completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public protocol UsageFetching: Sendable {
    func fetch(_ account: Account) async throws -> UsageSnapshot
}

public struct UsageService: UsageFetching {
    private let repository: AccountRepository
    private let transport: any HTTPTransport
    public init(repository: AccountRepository, transport: any HTTPTransport = URLSessionTransport()) {
        self.repository = repository; self.transport = transport
    }

    public func fetch(_ account: Account) async throws -> UsageSnapshot {
        try await repository.performUsageFetch(account) { try await fetchUncoordinated(account) }
    }

    private func fetchUncoordinated(_ account: Account) async throws -> UsageSnapshot {
        var read = try await repository.readCredentials(account)
        var refreshed = false
        if account.isManaged, read.credentials.needsRefresh() {
            read = try await refresh(account, read: read)
            refreshed = true
        }
        var response = try await usage(read.credentials)
        if response.status == 401 {
            // Reread first: its owner may have renewed a linked file while the request was running.
            let latest = try await repository.readCredentials(account)
            if latest.data != read.data {
                read = latest
                response = try await usage(read.credentials)
            }
            if response.status == 401 && account.isManaged && !refreshed {
                read = try await refresh(account, read: read)
                response = try await usage(read.credentials)
            }
        }
        try Task.checkCancellation()
        guard (200..<300).contains(response.status) else {
            if response.status == 401 { throw UsageError.reauthenticationRequired }
            throw UsageError.http(response.status)
        }
        let observedAt = Date()
        let payload = try UsageSnapshot.parse(response.data, expectedAccountID: account.identity.accountID, at: observedAt)
        var windows = payload.windows
        var noticeMessage: LocalizedText?
        if payload.shouldFetchMonthly {
            do {
                let monthly = try await monthlyUsage(read.credentials)
                guard (200..<300).contains(monthly.status) else { throw UsageError.http(monthly.status) }
                switch try UsageSnapshot.decodeMonthly(monthly.data, expectedAccountID: account.identity.accountID) {
                case let .window(window): windows.append(window)
                case .inactive: break
                case .unavailable: noticeMessage = LocalizedText("notice.monthlyUnavailable")
                }
            } catch is CancellationError { throw CancellationError() }
            catch let error as UsageError where error == .identityChanged { throw error }
            catch { noticeMessage = LocalizedText("notice.monthlyFailed") }
        }
        guard !windows.isEmpty || payload.credits != nil else { throw UsageError.invalidResponse }
        let snapshot = UsageSnapshot(plan: payload.plan, windows: windows, fetchedAt: observedAt,
                                     notice: noticeMessage?.resolve(in: .simplifiedChinese),
                                     credits: payload.credits, authPlan: read.credentials.planHint,
                                     noticeMessage: noticeMessage)
        // Prevent a late response from appearing after a relogin, switch, or removal.
        try await repository.validatePublication(account, data: read.data)
        return snapshot
    }

    private func usage(_ credentials: Credentials) async throws -> HTTPResponse {
        try await transport.send(authenticatedRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!, credentials: credentials))
    }

    private func authenticatedRequest(url: URL, credentials: Credentials, timeout: TimeInterval = 30) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.identity.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("SimpleCodexBar", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func monthlyUsage(_ credentials: Credentials) async throws -> HTTPResponse {
        var allowed = CharacterSet.urlPathAllowed
        allowed.subtract(CharacterSet(charactersIn: "/?#%"))
        guard let encoded = credentials.identity.accountID.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://chatgpt.com/backend-api/accounts/\(encoded)/spend-controls/current-user/monthly-usage") else {
            throw UsageError.invalidCredentials
        }
        return try await transport.send(authenticatedRequest(url: url, credentials: credentials, timeout: 4))
    }

    private func refresh(_ account: Account, read: CredentialRead) async throws -> CredentialRead {
        try await repository.performCredentialRotation { try await rotate(account, read: read) }
    }

    private func rotate(_ account: Account, read: CredentialRead) async throws -> CredentialRead {
        guard !read.credentials.refreshToken.isEmpty else { throw UsageError.reauthenticationRequired }
        var request = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": "app_EMoamEEZ73f0CkXaXp7hrann", "grant_type": "refresh_token",
            "refresh_token": read.credentials.refreshToken, "scope": "openid profile email",
        ])
        let response = try await transport.send(request)
        try Task.checkCancellation()
        guard response.status == 200 else {
            let object = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any]
            let error = JSONFields.object(object?["error"])
            let code = JSONFields.text(error?["code"], object?["error"], object?["code"])?.lowercased()
            if response.status == 401 || ["refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated", "invalid_grant"].contains(code ?? "") {
                throw UsageError.reauthenticationRequired
            }
            throw UsageError.http(response.status)
        }
        let updated = try Credentials.applyingRefresh(response.data, to: read.data)
        try await repository.replaceCredentials(account, original: read.data, updated: updated)
        return CredentialRead(credentials: try Credentials(data: updated), data: updated, file: read.file)
    }
}
