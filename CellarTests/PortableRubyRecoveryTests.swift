import CryptoKit
import Darwin
import XCTest
@testable import Cellar

@MainActor
final class PortableRubyRecoveryTests: XCTestCase {
    func testQuarantinesOnlyConfirmedArchiveAndRetries() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let sibling = fixture.archive.appendingPathExtension("incomplete")
        try Data("partial download".utf8).write(to: sibling)
        let attempts = Attempts()

        let result = try await fixture.run {
            if await attempts.next() == 1 { throw fixture.failure() }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.archive.path))
            return "fresh snapshot"
        }

        XCTAssertEqual(result, "fresh snapshot")
        let backups = try fixture.backups()
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), fixture.badData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
    }

    func testSecondChecksumFailureDoesNotQuarantineAgain() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let attempts = Attempts()
        do {
            _ = try await fixture.run {
                if await attempts.next() == 2 { try fixture.badData.write(to: fixture.archive) }
                throw fixture.failure()
            }
            XCTFail("A repeated checksum failure must remain a failure.")
        } catch {
            XCTAssertEqual(error as? BrewError, fixture.failure())
        }

        let count = await attempts.count
        XCTAssertEqual(count, 2)
        XCTAssertEqual(try fixture.backups().count, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.badData)
    }

    func testDeclinesArchiveOutsideEffectiveCacheAndSymlink() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let outside = fixture.root.appendingPathComponent(fixture.archive.lastPathComponent)
        try fixture.badData.write(to: outside)

        do {
            _ = try await fixture.run { throw fixture.failure(archive: outside) }
            XCTFail("A path outside the configured cache must remain untouched.")
        } catch {
            XCTAssertEqual(error as? BrewError, fixture.failure(archive: outside))
        }
        try FileManager.default.removeItem(at: fixture.archive)
        try FileManager.default.createSymbolicLink(at: fixture.archive, withDestinationURL: outside)

        do {
            _ = try await fixture.run { throw fixture.failure() }
            XCTFail("A symlink must remain untouched.")
        } catch {
            XCTAssertEqual(error as? BrewError, fixture.failure())
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.archive.path), outside.path)
        XCTAssertEqual(try Data(contentsOf: outside), fixture.badData)
        XCTAssertTrue(try fixture.backups().isEmpty)
    }

    func testAlreadyReplacedValidArchiveIsKept() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.goodData.write(to: fixture.archive)
        let attempts = Attempts()

        _ = try await fixture.run {
            if await attempts.next() == 1 { throw fixture.failure() }
            return "fresh snapshot"
        }
        XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.goodData)
        XCTAssertTrue(try fixture.backups().isEmpty)
    }

    func testWaitingForVendorLockDoesNotTouchArchive() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let fd = open(fixture.lock.path, O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)

        let attempts = Attempts()
        let retry = Task {
            try await fixture.run {
                if await attempts.next() == 1 {
                    throw BrewError.executionFailed(
                        code: 1, message: "lockf: 200: already locked\nAnother `brew vendor-install ruby` process is already running."
                    )
                }
                return "fresh snapshot"
            }
        }
        defer { retry.cancel() }
        try await Task.sleep(for: .milliseconds(200))
        let count = await attempts.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.badData)
        XCTAssertEqual(flock(fd, LOCK_UN), 0)
        let result = try await retry.value
        XCTAssertEqual(result, "fresh snapshot")
        XCTAssertTrue(try fixture.backups().isEmpty)
    }

    func testDiagnosticDistinguishesPortableRubyChecksumAndLockFromEndpoint() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let failure = fixture.failure()
        XCTAssertEqual(BrewReliabilityDiagnostics.diagnose(error: failure).kind, .portableRubyChecksum)
        XCTAssertEqual(BrewReliabilityDiagnostics.diagnose(
            text: "Error: Another `brew vendor-install ruby` process is already running."
        ).kind, .portableRubyLock)
        XCTAssertNil(PortableRubyChecksumFailure.parse(
            failure.localizedDescription.replacingOccurrences(of: "portable-ruby-4.0.10", with: "unrelated-1.0")
        ))
    }

    private actor Attempts {
        private(set) var count = 0

        func next() -> Int {
            count += 1
            return count
        }
    }

    private struct Fixture: Sendable {
        let root: URL
        let cache: URL
        let archive: URL
        let lock: URL
        let executable: URL
        let badData = Data("truncated archive".utf8)
        let goodData = Data("complete archive".utf8)

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            cache = root.appendingPathComponent("Homebrew Cache")
            archive = cache.appendingPathComponent("portable-ruby-4.0.10.arm64_big_sur.bottle.tar.gz")
            lock = root.appendingPathComponent("var/homebrew/locks/vendor-install-ruby")
            executable = root.appendingPathComponent("brew")
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: lock)
            try badData.write(to: archive)
            try """
            #!/bin/sh
            case "$1" in
              --prefix) printf '%s\\n' "$CELLAR_TEST_PREFIX" ;;
              --cache) printf '%s\\n' "$CELLAR_TEST_CACHE" ;;
              *) exit 2 ;;
            esac
            """.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        nonisolated func failure(archive: URL? = nil) -> BrewError {
            let expected = SHA256.hash(data: goodData).map { String(format: "%02x", $0) }.joined()
            let actual = SHA256.hash(data: badData).map { String(format: "%02x", $0) }.joined()
            return .executionFailed(code: 1, message: """
            ==> Downloading https://ghcr.io/v2/homebrew/core/portable-ruby/blobs/sha256:\(expected)
            Error: Checksum mismatch.
            Expected: \(expected)
              Actual: \(actual)
             Archive: \((archive ?? self.archive).path)
            Error: Failed to upgrade Homebrew Portable Ruby!
            """)
        }

        func run(_ operation: @Sendable () async throws -> String) async throws -> String {
            try await PortableRubyRecovery.run(
                executable: executable.path,
                environment: ["CELLAR_TEST_PREFIX": root.path, "CELLAR_TEST_CACHE": cache.path],
                log: { _ in }, operation: operation
            )
        }

        func backups() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(".cellar-corrupt-") }
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
