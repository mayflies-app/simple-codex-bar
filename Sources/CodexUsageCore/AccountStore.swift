import Foundation
import Observation

public struct AccountRow: Identifiable, Sendable {
    public var account: Account
    public var snapshot: UsageSnapshot?
    public var errorMessage: LocalizedText?
    public var refreshing = false
    public var restoredFromCache = false
    public var id: UUID { account.id }
    public init(account: Account, snapshot: UsageSnapshot? = nil,
                errorMessage: LocalizedText? = nil) {
        self.account = account; self.snapshot = snapshot; self.errorMessage = errorMessage
    }
}

@MainActor @Observable
public final class AccountStore {
    public private(set) var rows: [AccountRow] = []
    public private(set) var storageMessage: LocalizedText?
    public var isRefreshing: Bool { rows.contains(where: \.refreshing) }
    @ObservationIgnored private let repository: AccountRepository?
    @ObservationIgnored private let fetcher: (any UsageFetching)?
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var tickets: [UUID: UUID] = [:]
    @ObservationIgnored private var loadTicket = UUID()

    public init(repository: AccountRepository, fetcher: any UsageFetching) {
        self.repository = repository; self.fetcher = fetcher
    }

    public init(demoRows: [AccountRow]) {
        self.repository = nil; self.fetcher = nil; rows = demoRows
    }

    public func load() async {
        guard let repository else { return }
        let ticket = UUID()
        loadTicket = ticket
        let accounts = await repository.accounts()
        var cached: [UUID: UsageSnapshot] = [:]
        for account in accounts where !rows.contains(where: { $0.id == account.id && $0.account.identity.key == account.identity.key }) {
            cached[account.id] = try? await repository.cachedUsage(for: account)
        }
        guard loadTicket == ticket else { return }
        rows = accounts.map { account in
            if var row = rows.first(where: { $0.id == account.id && $0.account.identity.key == account.identity.key }) {
                row.account = account
                return row
            }
            var row = AccountRow(account: account, snapshot: cached[account.id])
            row.restoredFromCache = row.snapshot != nil
            return row
        }
    }

    public func refreshAll() { for row in rows { refresh(row.id) } }

    public func refreshAutomatically() {
        for row in rows where row.account.automaticRefreshEnabled { refresh(row.id) }
    }

    public func setAutomaticRefreshEnabled(_ id: UUID, enabled: Bool) async {
        guard let repository else { return }
        do { try await repository.setAutomaticRefreshEnabled(id, enabled: enabled); storageMessage = nil }
        catch { storageMessage = UsageError.storage.message }
        await load()
    }

    public func move(_ id: UUID, by offset: Int) async {
        guard let repository else { return }
        do { try await repository.move(id, by: offset); storageMessage = nil }
        catch { storageMessage = UsageError.storage.message }
        await load()
    }

    public func refresh(_ id: UUID) {
        guard let fetcher, tasks[id] == nil, let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let account = rows[index].account
        let ticket = UUID()
        tickets[id] = ticket
        rows[index].refreshing = true
        tasks[id] = Task { [weak self] in
            let outcome: Result<UsageSnapshot, Error>
            do { outcome = .success(try await fetcher.fetch(account)) }
            catch { outcome = .failure(error) }
            guard let self, self.tickets[id] == ticket else { return }
            var cacheMessage: LocalizedText?
            if let repository = self.repository {
                do {
                    switch outcome {
                    case let .success(snapshot): try await repository.cacheUsage(snapshot, for: account)
                    case let .failure(error) where error as? UsageError == .identityChanged: try await repository.clearUsage(id)
                    default: break
                    }
                } catch { cacheMessage = LocalizedText("storage.cache") }
            }
            guard self.tickets[id] == ticket else { return }
            self.tasks[id] = nil
            self.tickets[id] = nil
            guard let index = self.rows.firstIndex(where: { $0.id == id }) else { return }
            self.rows[index].refreshing = false
            switch outcome {
            case let .success(snapshot):
                self.rows[index].snapshot = snapshot
                self.rows[index].errorMessage = nil
                self.rows[index].restoredFromCache = false
            case let .failure(error):
                if error is CancellationError { return }
                if error as? UsageError == .identityChanged {
                    self.rows[index].snapshot = nil
                    self.rows[index].restoredFromCache = false
                }
                self.rows[index].errorMessage = ((error as? UsageError) ?? .network).message
            }
            if let cacheMessage { self.storageMessage = cacheMessage }
            else if case .success = outcome, self.storageMessage == LocalizedText("storage.cache") {
                self.storageMessage = nil
            }
        }
    }

    public func waitForRefreshes() async {
        let running = Array(tasks.values)
        for task in running { await task.value }
    }

    public func cancel(_ id: UUID) {
        tickets[id] = nil
        tasks.removeValue(forKey: id)?.cancel()
        if let index = rows.firstIndex(where: { $0.id == id }) { rows[index].refreshing = false }
    }

    public func remove(_ id: UUID) async {
        guard let repository else { return }
        cancel(id)
        do { try await repository.remove(id); storageMessage = nil }
        catch { storageMessage = UsageError.storage.message }
        await load()
    }

    public func rename(_ id: UUID, label: String) async {
        guard let repository else { return }
        do { try await repository.rename(id, label: label); storageMessage = nil }
        catch { storageMessage = UsageError.storage.message }
        await load()
    }
}
