import CryptoKit
import Darwin
import Foundation

struct PortableRubyChecksumFailure: Sendable {
    let archive: URL
    let expectedHash: String
    let actualHash: String

    nonisolated static func parse(_ output: String) -> Self? {
        let pattern = #"(?mi)^Error: Checksum mismatch\.[ \t]*\r?\n[ \t]*Expected:[ \t]*([0-9a-f]{64})[ \t]*\r?\n[ \t]*Actual:[ \t]*([0-9a-f]{64})[ \t]*\r?\n[ \t]*Archive:[ \t]*(/[^\r\n]+/portable-ruby-[0-9]+(?:\.[0-9]+)+(?:_[0-9]+)?\.[a-z0-9_]+\.bottle\.tar\.gz)[ \t]*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let expected = Range(match.range(at: 1), in: output),
              let actual = Range(match.range(at: 2), in: output),
              let path = Range(match.range(at: 3), in: output) else { return nil }

        let expectedHash = output[expected].lowercased()
        let actualHash = output[actual].lowercased()
        guard expectedHash != actualHash else { return nil }
        return Self(archive: URL(fileURLWithPath: String(output[path])), expectedHash: expectedHash, actualHash: actualHash)
    }
}

enum PortableRubyRecovery {
    typealias Log = @MainActor @Sendable (String) -> Void

    nonisolated static func isLockContention(_ output: String) -> Bool {
        output.contains("Another `brew vendor-install ruby` process is already running.")
    }

    nonisolated static func run<Result: Sendable>(
        executable: String,
        environment: [String: String],
        log: Log,
        operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        var checkedArchive = false
        var waitedForInstaller = false

        while true {
            try Task.checkCancellation()
            do {
                return try await operation()
            } catch let failure as BrewError {
                guard case .executionFailed(_, let output) = failure else { throw failure }
                let checksum = PortableRubyChecksumFailure.parse(output)
                let isContention = checksum == nil && isLockContention(output)
                guard (checksum != nil && !checkedArchive) || (isContention && !waitedForInstaller) else {
                    throw failure
                }

                do {
                    let prefix = try await brewDirectory("--prefix", executable: executable, environment: environment)
                    let lock = prefix.appendingPathComponent("var/homebrew/locks/vendor-install-ruby")
                    if let checksum {
                        checkedArchive = true
                        await log("Homebrew 报告 Portable Ruby 缓存校验失败，正在复核 \(checksum.archive.lastPathComponent)。")
                        let cache = try await brewDirectory("--cache", executable: executable, environment: environment)
                        let backup = try await withVendorLock(at: lock) {
                            try quarantine(checksum, in: cache)
                        }
                        if let backup {
                            await log("已隔离损坏的 Portable Ruby 缓存：\(backup.path)。将重试原命令，由 Homebrew 下载并校验。")
                        } else {
                            await log("Portable Ruby 缓存已被移走或已通过校验，将重试原命令。")
                        }
                    } else {
                        waitedForInstaller = true
                        await log("Portable Ruby 安装锁正在使用，等待安装任务释放后重试。")
                        try await withVendorLock(at: lock) {}
                    }
                } catch {
                    try Task.checkCancellation()
                    await log("Portable Ruby 缓存恢复未完成：\(error.localizedDescription)")
                    throw failure
                }
            }
        }
    }

    private nonisolated static func brewDirectory(
        _ option: String, executable: String, environment: [String: String]
    ) async throws -> URL {
        // These Homebrew options are handled by the shell before loading Ruby.
        let path = try await ShellService.runSynchronous(
            executable: executable, args: [option], environment: environment, timeoutSeconds: 5
        )
        guard path.hasPrefix("/"), path.rangeOfCharacter(from: .newlines) == nil else {
            throw RecoveryError.unsafePath
        }
        return URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
    }

    private nonisolated static func withVendorLock<Result>(
        at lock: URL, operation: () throws -> Result
    ) async throws -> Result {
        // On macOS, Homebrew's lockf uses the same BSD flock as this descriptor.
        let fd = open(lock.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard clock.now < deadline else { throw RecoveryError.lockBusy }
            try await Task.sleep(for: .milliseconds(500))
        }
        try Task.checkCancellation()
        _ = try regularFile(at: lock, matching: fd)
        return try operation()
    }

    private nonisolated static func quarantine(_ failure: PortableRubyChecksumFailure, in cache: URL) throws -> URL? {
        let parent = failure.archive.deletingLastPathComponent().resolvingSymlinksInPath()
        guard parent.path == cache.path else { throw RecoveryError.unsafePath }
        let archive = cache.appendingPathComponent(failure.archive.lastPathComponent)
        let fd = open(archive.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let before = try regularFile(at: archive, matching: fd)

        var hash = SHA256()
        while let data = try file.read(upToCount: 256 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        let actualHash = hash.finalize().map { String(format: "%02x", $0) }.joined()
        if actualHash == failure.expectedHash { return nil }
        let after = try regularFile(at: archive, matching: fd)
        guard actualHash == failure.actualHash,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw RecoveryError.archiveChanged }

        try Task.checkCancellation()
        let backup = cache.appendingPathComponent(".cellar-corrupt-\(UUID().uuidString)-\(archive.lastPathComponent)")
        guard renamex_np(archive.path, backup.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return backup
    }

    private nonisolated static func regularFile(at url: URL, matching fd: Int32) throws -> stat {
        var opened = stat()
        var named = stat()
        guard fstat(fd, &opened) == 0, lstat(url.path, &named) == 0,
              named.st_mode & S_IFMT == S_IFREG, opened.st_dev == named.st_dev,
              opened.st_ino == named.st_ino else { throw RecoveryError.unsafePath }
        return named
    }

    private enum RecoveryError: LocalizedError, Sendable {
        case unsafePath
        case lockBusy
        case archiveChanged

        nonisolated var errorDescription: String? {
            switch self {
            case .unsafePath: return "无法确认缓存或锁文件的位置与类型。"
            case .lockBusy: return "等待 Portable Ruby 安装锁超时。"
            case .archiveChanged: return "缓存文件已变化，保留当前文件。"
            }
        }
    }
}
