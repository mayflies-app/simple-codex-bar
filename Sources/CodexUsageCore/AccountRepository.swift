import Foundation
import Darwin

public struct CredentialRead: Sendable {
    public let credentials: Credentials
    public let data: Data
    public let file: URL
}

/// Owns only its private root. Linked credentials are read-only, never copied or refreshed.
public actor AccountRepository {
    public nonisolated let root: URL
    private let lockFD: Int32
    private let rootFD: Int32
    private var saved: [Account]
    private struct Flight {
        let ticket: UUID
        let task: Task<UsageSnapshot, Error>
    }
    private var usageFlights: [UUID: Flight] = [:]
    private var shuttingDown = false
    private var rotations = 0
    private var rotationWaiters: [CheckedContinuation<Void, Never>] = []

    #if DEBUG
    @TaskLocal static var readRetryObserver: (@Sendable (URL) async throws -> Void)?
    #endif

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SimpleCodexBar")
    }

    public init(root: URL = AccountRepository.defaultRoot) throws {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        try PrivateFile.directory(self.root)
        let directoryFD = open(self.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw UsageError.storage }
        let fd = openat(directoryFD, ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { close(directoryFD); throw UsageError.storage }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); close(directoryFD); throw UsageError.alreadyRunning }
        let metadata = self.root.appendingPathComponent("accounts.json")
        let initial: [Account]
        do {
            if FileManager.default.fileExists(atPath: metadata.path) {
                initial = try JSONDecoder().decode([Account].self,
                    from: PrivateFile.readOwned(metadata, root: self.root, rootFD: directoryFD))
                guard Set(initial.map(\.id)).count == initial.count,
                      Set(initial.map { $0.identity.key }).count == initial.count else { throw UsageError.storage }
            } else { initial = [] }
        } catch { close(fd); close(directoryFD); throw UsageError.storage }
        lockFD = fd
        rootFD = directoryFD
        saved = initial
    }

    deinit { close(lockFD); close(rootFD) }
    public func accounts() -> [Account] { saved }

    private struct CachedUsage: Codable {
        let accountID: UUID
        let identityKey: String
        let snapshot: UsageSnapshot
    }

    private var cacheFile: URL { root.appendingPathComponent("usage-cache.json") }

    private func readUsageCache() -> [CachedUsage] {
        do {
            try requireOwnedPath(cacheFile)
            return try JSONDecoder().decode([CachedUsage].self, from: PrivateFile.readOwned(cacheFile, root: root, rootFD: rootFD))
        } catch { return [] } // Optional cache corruption must not prevent account startup.
    }

    public func cachedUsage(for account: Account) async throws -> UsageSnapshot? {
        try requireCurrent(account)
        guard let cached = readUsageCache().first(where: { $0.accountID == account.id && $0.identityKey == account.identity.key }),
              Self.validCache(cached.snapshot) else { return nil }
        do { _ = try await readCredentials(account) }
        catch UsageError.identityChanged { try clearUsage(account.id); return nil }
        catch is CancellationError { throw CancellationError() }
        catch { } // Offline/missing credentials do not erase an explicitly marked previous reading.
        try requireCurrent(account)
        return cached.snapshot
    }

    public func cacheUsage(_ snapshot: UsageSnapshot, for account: Account) throws {
        try requireCurrent(account)
        guard Self.validCache(snapshot) else { throw UsageError.invalidResponse }
        var entries = readUsageCache().filter { entry in
            entry.accountID != account.id && saved.contains { $0.id == entry.accountID && $0.identity.key == entry.identityKey }
        }
        entries.append(CachedUsage(accountID: account.id, identityKey: account.identity.key, snapshot: snapshot))
        try writeUsageCache(entries)
    }

    public func clearUsage(_ id: UUID) throws { try writeUsageCache(readUsageCache().filter { $0.accountID != id }) }

    private func writeUsageCache(_ entries: [CachedUsage]) throws {
        try requireOwnedPath(cacheFile)
        try PrivateFile.writeOwned(JSONEncoder().encode(entries), to: cacheFile, root: root, rootFD: rootFD)
    }

    private static func validCache(_ snapshot: UsageSnapshot) -> Bool {
        func date(_ value: Date) -> Bool { (0..<253402300800).contains(value.timeIntervalSince1970) }
        func amount(_ value: Double?) -> Bool { value.map { $0.isFinite && $0 >= 0 } ?? true }
        return date(snapshot.fetchedAt) && Set(snapshot.windows.map(\.id)).count == snapshot.windows.count
            && snapshot.windows.allSatisfy {
                $0.usedPercent.isFinite && (0...100).contains($0.usedPercent)
                    && amount($0.usedAmount) && amount($0.limitAmount) && ($0.resetsAt.map(date) ?? true)
            } && amount(snapshot.credits?.balance)
    }

    /// Shared by every service/store using this repository. A cancelled waiter never cancels token rotation.
    func performUsageFetch(_ account: Account, operation: @escaping @Sendable () async throws -> UsageSnapshot) async throws -> UsageSnapshot {
        try requireCurrent(account)
        guard !shuttingDown else { throw CancellationError() }
        try Task.checkCancellation()
        let flight: Flight
        if let existing = usageFlights[account.id] { flight = existing }
        else {
            flight = Flight(ticket: UUID(), task: Task { try await operation() })
            usageFlights[account.id] = flight
        }
        defer { if usageFlights[account.id]?.ticket == flight.ticket { usageFlights[account.id] = nil } }
        let result = await flight.task.result
        try Task.checkCancellation()
        return try result.get()
    }

    /// Once a refresh token has been sent, finish validation and atomic publication before orderly exit.
    func performCredentialRotation(operation: @escaping @Sendable () async throws -> CredentialRead) async throws -> CredentialRead {
        guard !shuttingDown else { throw CancellationError() }
        rotations += 1
        defer {
            rotations -= 1
            if rotations == 0 {
                let waiters = rotationWaiters; rotationWaiters = []
                for waiter in waiters { waiter.resume() }
            }
        }
        return try await operation()
    }

    public func shutdown() async {
        shuttingDown = true
        guard rotations > 0 else { return }
        await withCheckedContinuation { rotationWaiters.append($0) }
    }

    public func addLinked(file: URL, label: String) async throws -> Account {
        let resolved = file.standardizedFileURL.resolvingSymlinksInPath()
        guard !resolved.path.hasPrefix(root.path + "/") else { throw UsageError.invalidCredentials }
        let read = try await readFile(resolved)
        guard !saved.contains(where: { $0.identity.key == read.credentials.identity.key }) else {
            throw UsageError.duplicateAccount
        }
        let account = Account(label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                              identity: read.credentials.identity, source: .linked(path: resolved.path))
        try persist(saved + [account])
        return account
    }

    public func rename(_ id: UUID, label: String) throws {
        var next = saved
        guard let index = next.firstIndex(where: { $0.id == id }) else { throw UsageError.accountRemoved }
        next[index].label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        try persist(next)
    }

    public func setAutomaticRefreshEnabled(_ id: UUID, enabled: Bool) throws {
        var next = saved
        guard let index = next.firstIndex(where: { $0.id == id }) else { throw UsageError.accountRemoved }
        next[index].automaticRefreshEnabled = enabled
        try persist(next)
    }

    public func move(_ id: UUID, by offset: Int) throws {
        guard let index = saved.firstIndex(where: { $0.id == id }) else { throw UsageError.accountRemoved }
        guard offset == -1 || offset == 1, saved.indices.contains(index + offset) else { return }
        var next = saved
        next.swapAt(index, index + offset)
        try persist(next)
    }

    public func remove(_ id: UUID) throws {
        guard let account = saved.first(where: { $0.id == id }) else { return }
        if account.isManaged { try requireOwnedPath(managedHome(id)) }
        // Remove metadata first. Even if credential deletion fails, the account cannot reappear.
        try persist(saved.filter { $0.id != id })
        if account.isManaged, FileManager.default.fileExists(atPath: managedHome(id).path) {
            try FileManager.default.removeItem(at: managedHome(id))
        }
        try clearUsage(id)
    }

    public func makeLoginDirectory() throws -> URL {
        let directory = root.appendingPathComponent("logins/\(UUID().uuidString)")
        try requireOwnedPath(directory)
        try PrivateFile.makeOwnedDirectory(directory, root: root, rootFD: rootFD)
        return directory
    }

    public func discardLoginDirectory(_ directory: URL) throws {
        try validateLoginDirectory(directory)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    public func finishLogin(directory: URL, label: String, replacing id: UUID? = nil) throws -> Account {
        try validateLoginDirectory(directory)
        let data = try PrivateFile.readOwned(directory.appendingPathComponent("auth.json"), root: root, rootFD: rootFD)
        let credentials = try Credentials(data: data)
        let account: Account
        if let id {
            guard let existing = saved.first(where: { $0.id == id }), existing.isManaged else {
                throw UsageError.accountRemoved
            }
            guard existing.identity.key == credentials.identity.key else { throw UsageError.identityChanged }
            account = Account(id: id, label: existing.label, identity: credentials.identity, source: .managed,
                              automaticRefreshEnabled: existing.automaticRefreshEnabled)
        } else {
            guard !saved.contains(where: { $0.identity.key == credentials.identity.key }) else {
                throw UsageError.duplicateAccount
            }
            account = Account(label: label, identity: credentials.identity, source: .managed)
        }
        let destination = managedHome(account.id)
        try requireOwnedPath(destination)
        try PrivateFile.makeOwnedDirectory(destination, root: root, rootFD: rootFD)
        try requireOwnedPath(destination.appendingPathComponent("auth.json"))
        try PrivateFile.writeOwned(data, to: destination.appendingPathComponent("auth.json"), root: root, rootFD: rootFD)
        var next = saved.filter { $0.id != account.id }
        if let index = saved.firstIndex(where: { $0.id == account.id }) { next.insert(account, at: index) }
        else { next.append(account) }
        try persist(next)
        try discardLoginDirectory(directory)
        return account
    }

    public func readCredentials(_ account: Account) async throws -> CredentialRead {
        try requireCurrent(account)
        let file: URL
        switch account.source {
        case .managed:
            file = managedHome(account.id).appendingPathComponent("auth.json")
            try requireOwnedPath(file)
        case let .linked(path): file = URL(fileURLWithPath: path)
        }
        let read = try await readFile(file, owned: account.isManaged)
        try requireCurrent(account)
        guard read.credentials.identity.key == account.identity.key else { throw UsageError.identityChanged }
        return read
    }

    public func replaceCredentials(_ account: Account, original: Data, updated: Data) throws {
        try requireCurrent(account)
        guard account.isManaged else { throw UsageError.credentialsChanged }
        let file = managedHome(account.id).appendingPathComponent("auth.json")
        try requireOwnedPath(file)
        guard try PrivateFile.readOwned(file, root: root, rootFD: rootFD) == original else { throw UsageError.credentialsChanged }
        guard try Credentials(data: updated).identity.key == account.identity.key else { throw UsageError.identityChanged }
        try PrivateFile.writeOwned(updated, to: file, root: root, rootFD: rootFD)
    }

    public func validatePublication(_ account: Account, data: Data) async throws {
        let current = try await readCredentials(account)
        guard current.data == data else { throw UsageError.credentialsChanged }
    }

    private func managedHome(_ id: UUID) -> URL { root.appendingPathComponent("accounts/\(id.uuidString)") }

    private func validateLoginDirectory(_ directory: URL) throws {
        try requireOwnedPath(directory)
        let parent = root.appendingPathComponent("logins").resolvingSymlinksInPath()
        let resolved = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.deletingLastPathComponent() == parent,
              UUID(uuidString: resolved.lastPathComponent) != nil else { throw UsageError.storage }
    }

    private func requireOwnedPath(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        var pinned = stat()
        var named = stat()
        guard fstat(rootFD, &pinned) == 0, lstat(root.path, &named) == 0,
              (named.st_mode & S_IFMT) == S_IFDIR,
              pinned.st_dev == named.st_dev, pinned.st_ino == named.st_ino else { throw UsageError.storage }
        guard path.hasPrefix(root.path + "/"), url.standardizedFileURL.resolvingSymlinksInPath().path == path else {
            throw UsageError.storage
        }
    }

    private func requireCurrent(_ account: Account) throws {
        guard saved.contains(where: { $0.id == account.id && $0.identity.key == account.identity.key && $0.source == account.source }) else {
            throw UsageError.accountRemoved
        }
    }

    private func readFile(_ file: URL, owned: Bool = false) async throws -> CredentialRead {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                if owned { try requireOwnedPath(file) }
                let data = try owned ? PrivateFile.readOwned(file, root: root, rootFD: rootFD) : PrivateFile.read(file)
                if owned { try requireOwnedPath(file) }
                return CredentialRead(credentials: try Credentials(data: data), data: data, file: file)
            } catch let error as UsageError where error == .apiKeyUnsupported || error == .identityChanged || error == .storage { throw error }
            catch {
                if attempt == 2 { throw UsageError.invalidCredentials }
                #if DEBUG
                if owned, let observer = Self.readRetryObserver { try await observer(file) }
                #endif
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        throw UsageError.invalidCredentials
    }

    private func persist(_ accounts: [Account]) throws {
        try requireOwnedPath(root.appendingPathComponent("accounts.json"))
        try PrivateFile.writeOwned(JSONEncoder().encode(accounts), to: root.appendingPathComponent("accounts.json"), root: root, rootFD: rootFD)
        saved = accounts
    }
}
