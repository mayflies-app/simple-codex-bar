import Foundation
import Darwin

/// Owner-only from creation, fsynced then atomically renamed; no world-readable staging file.
enum PrivateFile {
    static func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func writeOwned(_ data: Data, to url: URL, root: URL, rootFD: Int32) throws {
        try withParent(url, root: root, rootFD: rootFD) { parent, name in
            let temporary = ".write-\(UUID().uuidString)"
            let fd = openat(parent, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw UsageError.storage }
            defer { close(fd); unlinkat(parent, temporary, 0) }
            guard fchmod(fd, 0o600) == 0 else { throw UsageError.storage }
            try writeBytes(data, descriptor: fd)
            guard fsync(fd) == 0, renameat(parent, temporary, parent, name) == 0 else { throw UsageError.storage }
        }
    }

    /// Every directory component and the leaf are opened without following symlinks, relative to a pinned root FD.
    static func readOwned(_ url: URL, root: URL, rootFD: Int32) throws -> Data {
        try withParent(url, root: root, rootFD: rootFD) { parent, name in
            let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw errno == ENOENT ? UsageError.invalidCredentials : UsageError.storage }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_size >= 0, info.st_size <= 1_048_576 else { throw UsageError.storage }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if n < 0 && errno == EINTR { continue }
                guard n >= 0 else { throw UsageError.storage }
                if n == 0 { return data }
                guard data.count + n <= 1_048_576 else { throw UsageError.storage }
                data.append(contentsOf: buffer.prefix(n))
            }
        }
    }

    static func makeOwnedDirectory(_ url: URL, root: URL, rootFD: Int32) throws {
        let parts = try ownedComponents(url, root: root)
        try withDirectory(parts, rootFD: rootFD, create: true) { _ in }
    }

    private static func withParent<T>(_ url: URL, root: URL, rootFD: Int32,
                                      body: (Int32, String) throws -> T) throws -> T {
        let parts = try ownedComponents(url, root: root)
        return try withDirectory(Array(parts.dropLast()), rootFD: rootFD) { try body($0, parts.last!) }
    }

    private static func ownedComponents(_ url: URL, root: URL) throws -> [String] {
        let path = url.standardizedFileURL.path
        let prefix = root.standardizedFileURL.path + "/"
        guard path.hasPrefix(prefix) else { throw UsageError.storage }
        let parts = String(path.dropFirst(prefix.count)).split(separator: "/").map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw UsageError.storage
        }
        return parts
    }

    private static func withDirectory<T>(_ parts: [String], rootFD: Int32, create: Bool = false,
                                         body: (Int32) throws -> T) throws -> T {
        var current = rootFD
        var opened: [Int32] = []
        defer { for fd in opened.reversed() { close(fd) } }
        for part in parts {
            if create, mkdirat(current, part, 0o700) != 0 && errno != EEXIST { throw UsageError.storage }
            let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw errno == ENOENT ? UsageError.invalidCredentials : UsageError.storage }
            opened.append(next)
            if create, fchmod(next, 0o700) != 0 { throw UsageError.storage }
            current = next
        }
        return try body(current)
    }

    private static func writeBytes(_ data: Data, descriptor fd: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw UsageError.storage }
                offset += count
            }
        }
    }

    static func read(_ url: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 1_048_576 else {
            throw UsageError.invalidCredentials
        }
        return try Data(contentsOf: url)
    }
}
