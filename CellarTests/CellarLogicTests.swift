import XCTest
@testable import Cellar

final class CellarLogicTests: XCTestCase {
    @MainActor
    func testMultiKegLinkedLatestVersionIgnoresRetainedOlderKegs() throws {
        for (name, old, latest) in [("simdjson", "5.0.2", "5.0.3"), ("node", "26.10.0_2", "26.11.1"), ("uv", "0.12.23", "0.13.0")] {
            for versions in [[old, latest], [latest, old]] {
                let package = try multiKegPackage(name: name, versions: versions, current: latest, linked: latest)
                XCTAssertEqual(package.versionDifferenceKind, .none, name)
                XCTAssertFalse(package.hasRepoDiff, name)
                XCTAssertTrue(package.versionDisplay.hasPrefix(latest), name)
                XCTAssertTrue(package.installedVersionHelpText.contains("已链接版本：\(latest)"))
                XCTAssertEqual(Set(package.installedVersions), Set(versions))
            }
        }
    }

    @MainActor
    func testMultiKegLinkedOldVersionDoesNotHideActualVersionDifference() throws {
        let package = try multiKegPackage(versions: ["2.0", "1.0"], current: "2.0", linked: "1.0")
        XCTAssertEqual(package.versionDifferenceKind, .unknownRawDifference)
        XCTAssertTrue(package.versionDisplay.hasPrefix("1.0"))
    }

    @MainActor
    func testMultiKegWithoutLinkedMetadataUsesNumericLatestInstalledVersion() throws {
        for versions in [["1.9", "1.10"], ["1.10", "1.9"]] {
            let package = try multiKegPackage(versions: versions, current: "1.10", linked: nil)
            XCTAssertEqual(package.versionDifferenceKind, .none)
        }
        let revision = try multiKegPackage(versions: ["1.0_2", "1.0_10"], current: "1.0_10", linked: nil)
        XCTAssertEqual(revision.versionDifferenceKind, .none)
    }

    @MainActor
    func testLinkedKegMissingFromInstalledMetadataCannotClaimCurrentVersion() throws {
        let package = try multiKegPackage(versions: ["1.0"], current: "2.0", linked: "2.0")
        XCTAssertEqual(package.versionDifferenceKind, .unknownRawDifference)
        XCTAssertTrue(package.hasRepoDiff)
    }

    @MainActor
    func testMultiKegComparisonCannotOverrideExplicitOutdatedCandidate() throws {
        let package = try multiKegPackage(versions: ["1.0", "2.0"], current: "2.0", linked: "2.0")
        XCTAssertEqual(package.versionDifferenceKind(isOutdatedCandidate: true), .outdatedCandidate)
    }

    @MainActor
    func testFailureReplayPreservesEarlySSLCauseAndUsefulTailInBothCommandPaths() async throws {
        let text = sslReplayOutput()
        for streaming in [false, true] {
            let error = try await replayCommandFailure(text, streaming: streaming)
            guard case .executionFailed(let code, let message) = error else { return XCTFail("Expected execution failure") }
            XCTAssertEqual(code, 1)
            XCTAssertTrue(message.contains("SSL_ERROR_SYSCALL"))
            XCTAssertTrue(message.contains("Failed to download resource \"node\""))
            XCTAssertTrue(message.contains("==> Upgraded 1 dependent"))
            XCTAssertTrue(message.contains("node 26.10.0_2 -> 26.11.1"))
            XCTAssertLessThanOrEqual(message.count, 3600)
            XCTAssertEqual(BrewReliabilityDiagnostics.diagnose(error: error).kind, .endpoint)
        }
    }

    @MainActor
    func testUnclassifiedLongFailureRetainsBeginningAndEnd() async throws {
        let text = "custom-tool stopped: early detail\n" + String(repeating: "ordinary output\n", count: 400) + "final detail\n"
        let error = try await replayCommandFailure(text, streaming: true)
        XCTAssertTrue(error.localizedDescription.contains("custom-tool stopped: early detail"))
        XCTAssertTrue(error.localizedDescription.contains("final detail"))
    }

    @MainActor
    func testShortFailureOutputIsUnchanged() async throws {
        let text = "Permission denied: test-only directory\n"
        let error = try await replayCommandFailure(text, streaming: false)
        XCTAssertEqual(error, .executionFailed(code: 1, message: text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    @MainActor
    func testSSLReplayKeepsOverallFailureAndVerifiedPartialCompletion() async throws {
        let error = try await replayCommandFailure(sslReplayOutput(), streaming: true)
        let package = try multiKegPackage(name: "simdjson", versions: ["5.0.2", "5.0.3"], current: "5.0.3", linked: "5.0.3")
        let summary = BrewOperationPlanner.upgradeFailureSummary(startedAt: Date(), targetPackages: [package], attemptedPackageIDs: [package.id], failedPackageIDs: [package.id], remainingOutdatedPackages: [], error: error)
        XCTAssertEqual(summary.status, .failed)
        XCTAssertEqual(summary.packageVerificationResults.first?.status, .completed)
        XCTAssertTrue(summary.summaryText.contains("SSL_ERROR_SYSCALL"))
        XCTAssertTrue(summary.summaryText.contains("部分处理"))
    }

    @MainActor
    private func multiKegPackage(name: String = "sample", versions: [String], current: String, linked: String?) throws -> BrewPackage {
        var formula: [String: Any] = ["name": name, "versions": ["stable": current], "installed": versions.map { ["version": $0] }]
        if let linked { formula["linked_keg"] = linked }
        let data = try JSONSerialization.data(withJSONObject: ["formulae": [formula], "casks": []])
        return try XCTUnwrap(JSONParser.parseInstalled(String(decoding: data, as: UTF8.self), leaves: []).first)
    }

    @MainActor
    private func sslReplayOutput() -> String {
        // Public error block and completion lines from the real GUI acceptance log.
        """
        Error: Failed to download resource "node"
        Download failed: https://ghcr.io/v2/homebrew/core/node/blobs/sha256:f00f5a12c1bbfa5394d145c7bbf44d616fd461187cd9d5817161d1b59ae0a4da
        curl: (35) LibreSSL SSL_connect: SSL_ERROR_SYSCALL in connection to ghcr.io:443
        """ + "\n" + String(repeating: "Warning: The sandbox cannot prevent formulae from reading a required cache directory.\n", count: 80) + "==> Upgraded 1 dependent\nnode 26.10.0_2 -> 26.11.1\n"
    }

    @MainActor
    private func replayCommandFailure(_ text: String, streaming: Bool) async throws -> BrewError {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cellar-error-replay-\(UUID().uuidString).txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let args = ["-c", "cat \"$1\" >&2; exit 1", "cellar-error-replay", url.path]
        do {
            if streaming { for try await _ in ShellService.stream(executable: "/bin/sh", args: args) { } }
            else { _ = try await ShellService.runSynchronous(executable: "/bin/sh", args: args) }
            XCTFail("Failed command must not succeed")
            throw BrewError.parseError("Replay unexpectedly succeeded")
        } catch let error as BrewError { return error }
    }

    @MainActor
    func testCommandStreamCancelledBeforeLaunchDoesNotRunProcess() async throws {
        let marker = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let result = await Task { () -> BrewError? in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                for try await _ in ShellService.stream(executable: "/usr/bin/touch", args: [marker.path]) { }
                return nil
            } catch { return error as? BrewError }
        }.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    @MainActor
    func testCommandStreamCancellationWhileWaitingThrowsInsteadOfSucceeding() async {
        let ready = expectation(description: "process output received")
        let consumer = Task { () -> BrewError? in
            do {
                for try await _ in ShellService.stream(executable: "/bin/sh", args: ["-c", "printf 'ready\\n'; exec /bin/sleep 30"]) {
                    ready.fulfill()
                }
                return nil
            } catch { return error as? BrewError }
        }
        await fulfillment(of: [ready], timeout: 3)
        consumer.cancel()
        let result = await consumer.value
        XCTAssertEqual(result, .cancelled)
    }

    @MainActor
    func testCommandStreamCancellationAfterBufferedOutputCannotReachSuccess() async {
        let result = await Task { () -> BrewError? in
            let stream = ShellCommandStream { continuation in
                continuation.yield("download started\n")
                continuation.finish()
            }
            do {
                for try await _ in stream { withUnsafeCurrentTask { $0?.cancel() } }
                return nil
            } catch { return error as? BrewError }
        }.value
        XCTAssertEqual(result, .cancelled)
    }

    @MainActor
    func testCommandStreamPreservesSuccessfulOutput() async throws {
        var output = ""
        for try await line in ShellService.stream(executable: "/usr/bin/printf", args: ["ok\n"]) { output += line }
        XCTAssertEqual(output, "ok\n")
    }

    @MainActor
    func testCommandStreamPreservesExecutionFailure() async {
        do {
            for try await _ in ShellService.stream(executable: "/bin/sh", args: ["-c", "printf failure >&2; exit 7"]) { }
            XCTFail("failed command must not reach success")
        } catch {
            guard let brewError = error as? BrewError, case .executionFailed(let code, let message) = brewError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(code, 7)
            XCTAssertTrue(message.contains("failure"))
        }
    }

    @MainActor
    func testProcessOwnedDependencyGrowthExtendsFullIdleWindow() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cellar-owned-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("different-dependency.incomplete")
        let process = try startTestDownloadOwner(at: file)
        defer { process.terminate(); process.waitUntilExit() }
        let monitor = HomebrewDownloadEvidenceMonitor(directories: [root.path], targetTokens: ["parent"])
        monitor.bindProcess(process)
        XCTAssertTrue(monitor.sample().trustedDiscovery)
        let writer = try FileHandle(forWritingTo: file)
        defer { try? writer.close() }
        try writer.seekToEnd()
        try writer.write(contentsOf: Data(repeating: 1, count: 32))
        let growth = monitor.sample()
        XCTAssertTrue(growth.trustedByteGrowth)
        XCTAssertFalse(growth.uncertainActivity)
        XCTAssertTrue(monitor.summary().detailText.contains("打开文件关联"))
        var state = HomebrewStreamIdleTimeoutState()
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(HomebrewStreamIdleTimeoutPolicy.decision(idleSeconds: 300, timeoutSeconds: 180, sample: growth, now: now, state: &state), .continueWaiting)
        XCTAssertEqual(HomebrewStreamIdleTimeoutPolicy.decision(idleSeconds: 315, timeoutSeconds: 180, sample: nil, now: now.addingTimeInterval(15), state: &state), .continueWaiting)
        XCTAssertEqual(HomebrewStreamIdleTimeoutPolicy.decision(idleSeconds: 480, timeoutSeconds: 180, sample: nil, now: now.addingTimeInterval(180), state: &state), .terminate)
    }

    @MainActor
    func testUnrelatedDownloadCannotExtendBoundProcessEvenWithMatchingName() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cellar-unrelated-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("parent.incomplete")
        let unrelated = try startTestDownloadOwner(at: file)
        defer { unrelated.terminate(); unrelated.waitUntilExit() }
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/bin/sleep")
        command.arguments = ["10"]
        try command.run()
        defer { command.terminate(); command.waitUntilExit() }
        let monitor = HomebrewDownloadEvidenceMonitor(directories: [root.path], targetTokens: ["parent"])
        monitor.bindProcess(command)
        XCTAssertFalse(monitor.sample().trustedDiscovery)
        let writer = try FileHandle(forWritingTo: file)
        defer { try? writer.close() }
        try writer.seekToEnd()
        try writer.write(contentsOf: Data(repeating: 1, count: 32))
        let growth = monitor.sample()
        XCTAssertFalse(growth.trustedByteGrowth)
        XCTAssertTrue(growth.uncertainActivity)
        var state = HomebrewStreamIdleTimeoutState()
        let now = Date(timeIntervalSince1970: 2_000)
        XCTAssertEqual(HomebrewStreamIdleTimeoutPolicy.decision(idleSeconds: 180, timeoutSeconds: 180, sample: growth, now: now, state: &state), .continueWaiting)
        XCTAssertEqual(HomebrewStreamIdleTimeoutPolicy.decision(idleSeconds: 196, timeoutSeconds: 180, sample: growth, now: now.addingTimeInterval(16), state: &state), .terminate)
    }

    @MainActor
    func testClosedProcessFileAssociationDoesNotTrustLaterUnrelatedGrowth() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cellar-closed-owner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("parent.incomplete")
        let process = try startTestDownloadOwner(at: file)
        let monitor = HomebrewDownloadEvidenceMonitor(directories: [root.path], targetTokens: ["parent"])
        monitor.bindProcess(process)
        XCTAssertTrue(monitor.sample().trustedDiscovery)
        process.terminate()
        process.waitUntilExit()
        let writer = try FileHandle(forWritingTo: file)
        defer { try? writer.close() }
        try writer.seekToEnd()
        try writer.write(contentsOf: Data(repeating: 1, count: 32))
        let sample = monitor.sample()
        XCTAssertFalse(sample.trustedByteGrowth)
        XCTAssertTrue(sample.uncertainActivity)
    }

    private func startTestDownloadOwner(at file: URL) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // A real child owns fd 3. The parent trap stops only this fixture child.
        process.arguments = ["-c", "trap 'kill \"$child\" 2>/dev/null; wait \"$child\"' TERM INT EXIT; /bin/sh -c 'exec 3> \"$1\"; printf x >&3; exec /bin/sleep 10' fixture \"$1\" & child=$!; wait \"$child\"", "fixture", file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
               (attrs[.size] as? NSNumber)?.intValue == 1 { return process }
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.terminate()
        process.waitUntilExit()
        throw NSError(domain: "CellarTestDownloadOwner", code: 1)
    }

    func testDashboardSummaryDoesNotTreatUnscannedRuntimeAsClear() {
        let summary = DashboardHealthSummary.make(
            brewStatus: .upToDate,
            outdatedPackages: [],
            operationSummary: nil,
            runtimeSnapshots: [],
            librarySummary: LibrarySummary(repoDiffCount: 0, autoUpdatesCount: 0, sizeUnknownCount: 0, leafCount: 0)
        )

        XCTAssertEqual(summary.severity, .attention)
        XCTAssertEqual(summary.headline, "Homebrew 无可升级包")
        XCTAssertEqual(summary.domains.first { $0.id == "runtime" }?.value, "未检查")
        XCTAssertEqual(summary.domains.map(\.title), ["Homebrew 更新", "Runtime 环境", "酒窖清点", "最近任务"])
        XCTAssertTrue(summary.items.isEmpty)
    }

    func testDashboardSummaryCombinesUpToDateHomebrewWithLibraryAttentionWithoutConflict() {
        let summary = DashboardHealthSummary.make(
            brewStatus: .upToDate,
            outdatedPackages: [],
            operationSummary: nil,
            runtimeSnapshots: [],
            librarySummary: LibrarySummary(repoDiffCount: 0, autoUpdatesCount: 1, sizeUnknownCount: 1, leafCount: 0)
        )

        XCTAssertEqual(summary.headline, "Homebrew 无可升级包，仍有环境/清点事项需关注")
        XCTAssertFalse(summary.headline.contains("2 项"))
        XCTAssertFalse(summary.detail.contains("2 项"))
        XCTAssertFalse(summary.headline.contains("需要处理"))
        XCTAssertTrue(summary.domains.contains { $0.title == "Homebrew 更新" && $0.value == "无普通可升级" })
        XCTAssertTrue(summary.domains.contains { $0.title == "酒窖清点" && $0.detail.contains("酒窖大小未知 1") })
    }

    func testDashboardEmptyNextStepDoesNotPrioritizeBrewUpdateAfterCheck() {
        let nextStep = ProductCopy.emptyStateNextStep(for: .dashboard)

        XCTAssertTrue(nextStep.contains("手动检查"))
        XCTAssertTrue(nextStep.contains("刷新菜单"))
        XCTAssertFalse(nextStep.hasPrefix("下一步：点击“更新 Homebrew 仓库后检查”"))
    }

    func testDashboardEmptyTitleUsesListStateInsteadOfMainHeadlineTerms() {
        let title = DashboardView.dashboardEmptyTitle()

        XCTAssertEqual(title, "更新列表为空")
        XCTAssertFalse(title.contains("无可升级包"))
        XCTAssertFalse(title.contains("仍有事项"))
        XCTAssertFalse(title.contains("环境/清点事项"))
    }

    func testHomebrewSnapshotFailureKeepsFallbackVisible() {
        let previous = HomebrewSnapshotProvenance.succeeded(
            kind: .outdated,
            source: .brewOutdated,
            capturedAt: Date(timeIntervalSince1970: 100)
        )
        let failed = HomebrewSnapshotProvenance.failed(
            kind: .outdated,
            source: .brewUpdateThenOutdated,
            error: BrewError.executionFailed(code: 1, message: "/opt/homebrew/Cellar is not writable"),
            previous: previous,
            capturedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(failed.commandStatus, .failed)
        XCTAssertEqual(failed.fallbackState, .usingLastSuccessfulSnapshot)
        XCTAssertEqual(failed.lastSuccessfulCapturedAt, previous.lastSuccessfulCapturedAt)
        XCTAssertTrue(failed.statusTitle.contains("显示上次成功快照"))
        XCTAssertTrue(failed.detailText.contains("brew update + brew outdated"))
        XCTAssertTrue(failed.warnings.joined(separator: "\n").contains("Homebrew 目录不可写"))
        XCTAssertTrue(failed.reportLines.joined(separator: "\n").contains("Fallback state"))
    }

    func testDashboardSummaryDoesNotTreatFallbackSnapshotAsCertainLatest() {
        let previous = HomebrewSnapshotProvenance.succeeded(
            kind: .outdated,
            source: .brewOutdated,
            capturedAt: Date(timeIntervalSince1970: 100)
        )
        let failed = HomebrewSnapshotProvenance.failed(
            kind: .outdated,
            source: .brewOutdated,
            error: BrewError.executionFailed(code: 1, message: "Failed to connect to api.github.com"),
            previous: previous,
            capturedAt: Date(timeIntervalSince1970: 200)
        )

        let summary = DashboardHealthSummary.make(
            brewStatus: .upToDate,
            outdatedPackages: [],
            operationSummary: nil,
            runtimeSnapshots: [],
            librarySummary: LibrarySummary(repoDiffCount: 0, autoUpdatesCount: 0, sizeUnknownCount: 0, leafCount: 0),
            homebrewSnapshotProvenance: failed
        )

        XCTAssertTrue(summary.headline.contains("状态待确认"))
        XCTAssertFalse(summary.headline.contains("Homebrew 无可升级包"))
        XCTAssertTrue(summary.domains.contains { domain in
            domain.id == "homebrew"
                && domain.value == "状态待确认"
                && domain.detail.contains("基于上次成功快照")
        })
    }

    func testDashboardScrollLayoutKeepsSpaceForUpdateTable() {
        let topHeight = DashboardScrollLayout.topMaxHeight(totalHeight: 600, showsPackageTable: true)
        let tableMinHeight = DashboardScrollLayout.packageTableMinHeight(totalHeight: 600)

        XCTAssertNotNil(topHeight)
        XCTAssertLessThanOrEqual(topHeight ?? 0, 260)
        XCTAssertGreaterThanOrEqual(tableMinHeight, 140)
        XCTAssertLessThan((topHeight ?? 0) + tableMinHeight, 600)
        XCTAssertNil(DashboardScrollLayout.topMaxHeight(totalHeight: 600, showsPackageTable: false))
    }

    func testAppEventFactoryMapsFailedBrewSummaryToLoggableFailure() {
        let summary = BrewOperationPlanner.failureSummary(
            kind: .checkUpdates,
            startedAt: Date(),
            error: BrewError.executionFailed(code: 1, message: "Failed to connect")
        )

        let event = AppEventFactory.event(from: summary)

        XCTAssertEqual(event.source, .network)
        XCTAssertEqual(event.severity, .failure)
        XCTAssertTrue(event.opensLog)
        XCTAssertTrue(event.detail.contains("代理"))
    }

    func testAppEventFactoryKeepsCopiedRuntimeActionPending() {
        let runtimeEvent = RuntimeActionRunner.event(
            result: .copiedCommand,
            title: "治理验证命令已复制",
            detail: "命令尚未由 Cellar 执行，等待用户手动验证。",
            relatedActionID: "node.copy-governance-guide",
            verificationStatus: .pendingManualAction
        )

        let event = AppEventFactory.event(from: runtimeEvent)

        XCTAssertEqual(event.source, .runtime)
        XCTAssertEqual(event.severity, .attention)
        XCTAssertFalse(event.opensLog)
        XCTAssertTrue(event.detail.contains("等待用户手动验证"))
    }

    func testAppEventReducerMovesCompletedHomebrewOperationFromActiveToHistory() {
        let startedAt = Date()
        let running = AppEventFactory.event(from: BrewOperationPlanner.runningSummary(kind: .checkUpdates, startedAt: startedAt))
        let finished = AppEventFactory.event(from: BrewOperationPlanner.refreshFinished(kind: .checkUpdates, startedAt: startedAt, updateCount: 0))
        var activeEvents: [AppEvent] = []
        var historyEvents: [AppEvent] = []

        AppEventReducer.publish(running, activeEvents: &activeEvents, historyEvents: &historyEvents)
        AppEventReducer.publish(finished, activeEvents: &activeEvents, historyEvents: &historyEvents)

        XCTAssertTrue(activeEvents.isEmpty)
        XCTAssertEqual(historyEvents.first?.operationKey, "homebrew.checkUpdates")
        XCTAssertEqual(historyEvents.first?.phase, .history)
        XCTAssertEqual(historyEvents.first?.statusText, "已完成")
        XCTAssertEqual(historyEvents.first?.title, "检查更新")
        XCTAssertFalse(historyEvents.first?.title.contains("已完成") ?? true)
    }

    func testAppEventReducerReplacesShortIntervalDuplicateHistoryEvents() {
        let first = AppEvent(
            date: Date(),
            source: .homebrew,
            severity: .success,
            phase: .history,
            operationKey: "homebrew.checkUpdates",
            statusText: "已完成",
            title: "检查更新",
            detail: "检查完成，发现 0 个更新。",
            opensLog: false
        )
        let duplicate = AppEvent(
            date: first.date.addingTimeInterval(2),
            source: .homebrew,
            severity: .success,
            phase: .history,
            operationKey: "homebrew.checkUpdates",
            statusText: "已完成",
            title: "检查更新",
            detail: "检查完成，发现 0 个更新。",
            opensLog: false
        )
        var activeEvents: [AppEvent] = []
        var historyEvents: [AppEvent] = []

        AppEventReducer.publish(first, activeEvents: &activeEvents, historyEvents: &historyEvents)
        AppEventReducer.publish(duplicate, activeEvents: &activeEvents, historyEvents: &historyEvents)

        XCTAssertEqual(historyEvents.count, 1)
        XCTAssertEqual(historyEvents.first?.date, duplicate.date)
    }

    func testAppEventReducerKeepsDistinctOperationsWithDifferentTimes() {
        let first = AppEvent(
            date: Date(),
            source: .homebrew,
            severity: .success,
            phase: .history,
            operationKey: "homebrew.checkUpdates",
            statusText: "已完成",
            title: "检查更新",
            detail: "检查完成，发现 0 个更新。",
            opensLog: false
        )
        let later = AppEvent(
            date: first.date.addingTimeInterval(90),
            source: .homebrew,
            severity: .success,
            phase: .history,
            operationKey: "homebrew.checkUpdates",
            statusText: "已完成",
            title: "检查更新",
            detail: "检查完成，发现 0 个更新。",
            opensLog: false
        )
        var activeEvents: [AppEvent] = []
        var historyEvents: [AppEvent] = []

        AppEventReducer.publish(first, activeEvents: &activeEvents, historyEvents: &historyEvents)
        AppEventReducer.publish(later, activeEvents: &activeEvents, historyEvents: &historyEvents)

        XCTAssertEqual(historyEvents.count, 2)
        XCTAssertEqual(historyEvents.first?.date, later.date)
    }

    func testFooterTimeStatusUsesLatestKeyTime() {
        let now = Date()
        let snapshot = FooterTimeSnapshot(
            lastCheckTime: now.addingTimeInterval(-300),
            lastLibraryRefreshAt: now.addingTimeInterval(-120),
            lastBrewUpdateAt: now.addingTimeInterval(-30)
        )

        let text = FooterTimeStatusFormatter.statusText(from: snapshot, now: now)

        XCTAssertTrue(text.contains("最后 brew update"))
        XCTAssertFalse(text.contains("Homebrew："))
    }

    func testFooterTimeStatusShowsEmptyStateWithoutHistoryEventFallback() {
        let snapshot = FooterTimeSnapshot(lastCheckTime: nil, lastLibraryRefreshAt: nil, lastBrewUpdateAt: nil)

        XCTAssertEqual(FooterTimeStatusFormatter.statusText(from: snapshot), "等待首次检查或刷新")
    }

    func testFooterStatusGroupIncludesKeyTimesAndRuntimePathState() {
        let now = Date()
        let snapshot = FooterTimeSnapshot(
            lastCheckTime: now.addingTimeInterval(-300),
            lastLibraryRefreshAt: now.addingTimeInterval(-120),
            lastBrewUpdateAt: now.addingTimeInterval(-30),
            runtimePathStatus: "当前会话已对齐",
            runtimePathDetail: "当前会话 PATH 是 Cellar 进程全局共享状态；不代表 Runtime 全局工具 latest 已全部复核。"
        )

        let items = FooterStatusGroupFormatter.items(from: snapshot, now: now)

        XCTAssertTrue(items.contains { $0.title == "最后检查" })
        XCTAssertTrue(items.contains { $0.title == "最后刷新酒窖" })
        XCTAssertTrue(items.contains { $0.title == "最后 brew update" })
        XCTAssertTrue(items.contains { $0.title == "PATH" && $0.value == "当前会话已对齐" })
        XCTAssertTrue(items.first { $0.title == "PATH" }?.detail.contains("不代表 Runtime 全局工具 latest 已全部复核") == true)
    }

    func testFooterRecentStatusLayoutCollapsesToLatestItemForNarrowWidth() throws {
        let now = Date()
        let snapshot = FooterTimeSnapshot(
            lastCheckTime: now.addingTimeInterval(-300),
            lastLibraryRefreshAt: now.addingTimeInterval(-120),
            lastBrewUpdateAt: now.addingTimeInterval(-30),
            runtimePathStatus: "当前会话已对齐",
            runtimePathDetail: "当前会话 PATH 是 Cellar 进程全局共享状态。"
        )
        let items = FooterStatusGroupFormatter.items(from: snapshot, now: now)
        let latest = try XCTUnwrap(FooterRecentStatusLayout.latestItem(from: items, snapshot: snapshot))
        let runtimePathItem = try XCTUnwrap(items.first { $0.id == "runtime-path" })

        XCTAssertEqual(latest.title, "最后 brew update")
        XCTAssertEqual(runtimePathItem.title, "PATH")
        XCTAssertEqual(FooterRecentStatusLayout.expandedItems(from: items, latestItem: latest).count, 4)
        XCTAssertEqual(FooterRecentStatusLayout.mediumItems(from: items, latestItem: latest).count, 2)
        XCTAssertEqual(FooterRecentStatusLayout.compactItems(latestItem: latest).map(\.id), [latest.id])
        XCTAssertLessThan(FooterRecentStatusLayout.compactMaxWidth, FooterRecentStatusLayout.mediumMaxWidth)
        XCTAssertLessThan(FooterRecentStatusLayout.mediumMaxWidth, FooterRecentStatusLayout.expandedMaxWidth)
    }

    func testFooterRecentStatusLayoutPrioritizesActiveRuntimeItem() {
        let snapshot = FooterTimeSnapshot(
            lastCheckTime: Date().addingTimeInterval(-30),
            lastLibraryRefreshAt: nil,
            lastBrewUpdateAt: nil,
            runtimePathStatus: "正在检查更新 · 日志 3 条",
            runtimePathDetail: "当前有任务正在执行，底栏优先显示活动状态；完成后恢复最近关键状态组。"
        )
        let items = FooterStatusGroupFormatter.items(from: snapshot)

        XCTAssertEqual(FooterRecentStatusLayout.latestItem(from: items, snapshot: snapshot)?.id, "runtime-path")
    }

    func testMenuAndWindowCopyUsesChineseMainWindowEntryTerms() {
        let visibleCopy = [
            CellarWindowCopy.mainWindowTitle,
            CellarWindowCopy.settingsWindowTitle,
            CellarWindowCopy.openMainWindow,
            CellarWindowCopy.openSettings,
            CellarWindowCopy.openSettingsCommand
        ].joined(separator: "\n")

        XCTAssertTrue(visibleCopy.contains("打开主窗口"))
        XCTAssertTrue(visibleCopy.contains("偏好设置"))
        XCTAssertFalse(visibleCopy.contains("Cellar Manager"))
        XCTAssertFalse(visibleCopy.contains("Preferences"))
        XCTAssertFalse(visibleCopy.contains("Settings"))
    }

    func testLogEntrySummarizesRawCommandsWithoutDroppingOriginalMessage() {
        let command = LogEntry(timestamp: Date(), message: "$ export PATH=\"/opt/homebrew/bin:$PATH\"", type: .command)
        let stream = LogEntry(timestamp: Date(), message: "==> zsh completions have been installed to /opt/homebrew/share/zsh/site-functions", type: .stream)

        XCTAssertEqual(command.summaryText, "已生成当前会话 PATH 验证命令")
        XCTAssertEqual(command.message, "$ export PATH=\"/opt/homebrew/bin:$PATH\"")
        XCTAssertTrue(command.hasRawDetail)
        XCTAssertEqual(stream.summaryText, "Homebrew 正在处理 shell completions")
        XCTAssertTrue(stream.hasRawDetail)
    }

    func testAppEventReducerKeepsRuntimeCopiedCommandOutOfActiveEvents() {
        let runtimeEvent = RuntimeActionRunner.event(
            result: .copiedCommand,
            title: "治理验证命令已复制",
            detail: "命令尚未由 Cellar 执行。",
            relatedActionID: "node.copy-governance-guide",
            verificationStatus: .pendingManualAction
        )
        let event = AppEventFactory.event(from: runtimeEvent)
        var activeEvents: [AppEvent] = []
        var historyEvents: [AppEvent] = []

        AppEventReducer.publish(event, activeEvents: &activeEvents, historyEvents: &historyEvents)

        XCTAssertTrue(activeEvents.isEmpty)
        XCTAssertEqual(historyEvents.count, 1)
        XCTAssertNil(historyEvents.first?.operationKey)
        XCTAssertEqual(historyEvents.first?.phase, .history)
    }

    func testDashboardSummaryPromotesHomebrewUpdates() {
        let package = makePackage(name: "git", installedVersion: "2.0", currentVersion: "2.1")
        let summary = DashboardHealthSummary.make(
            brewStatus: .outdated(1),
            outdatedPackages: [package],
            operationSummary: nil,
            runtimeSnapshots: [],
            librarySummary: LibrarySummary(repoDiffCount: 0, autoUpdatesCount: 0, sizeUnknownCount: 0, leafCount: 0)
        )

        XCTAssertEqual(summary.severity, .warning)
        XCTAssertTrue(summary.items.contains { $0.id == "brew.outdated" && $0.action == .showUpdates })
    }

    func testDashboardSummaryPromotesRuntimeHighIssue() {
        let issue = RuntimeIssue(
            title: "npm prefix 与当前 Node 不一致",
            currentState: "当前 Node 来自 Homebrew，但 npm prefix 指向 /usr/local。",
            explanation: "全局包可能继续落到旧目录。",
            recommendation: "把 npm prefix 调整到用户级目录。",
            severity: .high
        )
        let summary = DashboardHealthSummary.make(
            brewStatus: .upToDate,
            outdatedPackages: [],
            operationSummary: nil,
            runtimeSnapshots: [makeNodeSnapshot(issues: [issue])],
            librarySummary: LibrarySummary(repoDiffCount: 0, autoUpdatesCount: 0, sizeUnknownCount: 0, leafCount: 0)
        )

        XCTAssertEqual(summary.severity, .critical)
        XCTAssertTrue(summary.items.contains { $0.source == "Runtime" && $0.action == .showRuntime })
    }

    func testSplitPathFiltersEmptyEntriesAndDeduplicates() {
        let result = RuntimeDoctorService.splitPath("/opt/homebrew/bin::/usr/bin:/opt/homebrew/bin:/bin")

        XCTAssertEqual(result, ["/opt/homebrew/bin", "/usr/bin", "/bin"])
    }

    func testRuntimeProviderClassification() {
        XCTAssertEqual(
            RuntimeDoctorService.classifyNodeSource(path: "/opt/homebrew/bin/node", resolvedPath: "/opt/homebrew/Cellar/node/24/bin/node"),
            .homebrew
        )
        XCTAssertEqual(
            RuntimeDoctorService.classifyPythonSource(path: "/Users/me/.pyenv/shims/python3", resolvedPath: "/Users/me/.pyenv/versions/3.12.0/bin/python3"),
            .pyenv
        )
    }

    func testDiagnosticActionMappingForNpmPrefix() {
        let issue = RuntimeIssue(
            title: "npm prefix 与当前 Node 不一致",
            currentState: "当前 Node 来自 Homebrew，但 npm prefix 指向 /usr/local。",
            explanation: "全局包可能继续落到旧目录。",
            recommendation: "把 npm prefix 调整到用户级目录。",
            severity: .high
        )
        let snapshot = makeNodeSnapshot(issues: [issue])

        let actions = RuntimeDiagnosticEngine.recommendedActions(for: issue, snapshot: snapshot)

        XCTAssertTrue(actions.contains { $0.id == "node.repair-npm-prefix" && $0.risk == .userPersistent })
    }

    func testTargetedRuntimeVerificationIgnoresUnrelatedIssueRemoval() {
        let targetIssue = RuntimeIssue(
            title: "npm prefix 与当前 Node 不一致",
            currentState: "当前 Node 来自 Homebrew，但 npm prefix 指向 /usr/local。",
            explanation: "全局包可能继续落到旧目录。",
            recommendation: "把 npm prefix 调整到用户级目录。",
            severity: .high
        )
        let unrelatedIssue = RuntimeIssue(
            title: "GUI 当前未接入 Homebrew Node",
            currentState: "GUI PATH 缺少 /opt/homebrew/bin。",
            explanation: "Cellar 可能看不到终端中的 Node。",
            recommendation: "先对齐当前会话 PATH。",
            severity: .warning
        )
        let before = makeNodeSnapshot(issues: [targetIssue, unrelatedIssue])
        let after = makeNodeSnapshot(issues: [targetIssue])

        let status = RuntimeActionRunner.verificationStatus(
            before: before,
            after: after,
            relatedActionIDs: ["node.repair-npm-prefix"]
        )

        XCTAssertEqual(status, .unchanged)
    }

    func testBrewOperationPlannerRecommendationsCoverCommonFailures() {
        XCTAssertEqual(
            BrewOperationPlanner.recommendation(for: BrewError.brewNotFound),
            "请先安装 Homebrew，或确认 brew 是否位于 /opt/homebrew/bin/brew 或 /usr/local/bin/brew。"
        )
        XCTAssertEqual(
            BrewOperationPlanner.recommendation(for: BrewError.executionFailed(code: 1, message: "Failed to connect to github.com")),
            "请在偏好设置测试核心服务可达性；必要时启用代理后重试。"
        )
        XCTAssertEqual(
            BrewOperationPlanner.recommendation(for: BrewError.executionFailed(code: 1, message: "/opt/homebrew is not writable")),
            "请先人工核对目录所有者和写入权限，再按 Homebrew 官方建议处理。"
        )
    }

    func testFailedCheckOverridesIdleHeadlineAndDeduplicatesMatchingOperation() {
        let error = BrewError.executionFailed(code: 1, message: "You have not agreed to the Xcode license.")
        let failure = HomebrewSnapshotProvenance.failed(kind: .outdated, source: .brewOutdated,
            error: error, previous: .notCaptured(kind: .outdated))
        let operation = BrewOperationPlanner.failureSummary(kind: .checkUpdates, startedAt: Date(), error: error)
        let summary = DashboardHealthSummary.make(brewStatus: .idle, outdatedPackages: [],
            operationSummary: operation, runtimeSnapshots: [],
            librarySummary: LibrarySummary(repoDiffCount: 0, autoUpdatesCount: 0, sizeUnknownCount: 0, leafCount: 0),
            homebrewSnapshotProvenance: failure)
        XCTAssertTrue(summary.headline.contains("检查失败"))
        XCTAssertFalse(summary.headline.contains("尚未检查"))
        XCTAssertFalse(summary.items.contains { $0.id == "brew.not-checked" })
        XCTAssertFalse(DashboardView.shouldShowOperationSummary(operation, diagnosticFailure: failure.failureMessage))
        XCTAssertTrue(DashboardView.shouldShowOperationSummary(operation, diagnosticFailure: "another failure"))
        XCTAssertTrue(DashboardView.shouldShowOperationSummary(operation, diagnosticFailure: nil))
        XCTAssertEqual(summary.domains.first { $0.id == "recent-task" }?.value, "检查更新失败")
    }

    func testXcodeLicenseErrorsHaveActionableDiagnosis() {
        for message in [
            "Error: You have not agreed to the Xcode license. sudo xcodebuild -license accept",
            "You have not agreed to the Xcode license agreements. Please run sudo xcodebuild -license",
            "YOU HAVE NOT AGREED TO THE XCODE LICENSE. github.com proxy permission denied"
        ] {
            let issue = BrewReliabilityDiagnostics.diagnose(text: message)
            XCTAssertEqual(issue.kind, .xcodeLicense)
            XCTAssertEqual(issue.settingsSection, .homebrewService)
            XCTAssertTrue(issue.nextStep.contains("重新检查"))
            XCTAssertEqual(issue.manualCommands, ["sudo xcodebuild -license"])
        }
        XCTAssertEqual(BrewReliabilityDiagnostics.diagnose(text: "Xcode build failed: unknown compiler error").kind, .unknown)
    }

    func testRuntimeScanFailureOverridesEmptyAndPreviousHealthySnapshots() {
        for snapshots in [[], [makeNodeSnapshot(issues: [])]] {
            let summary = DashboardHealthSummary.make(
                brewStatus: .upToDate, outdatedPackages: [], operationSummary: nil,
                runtimeSnapshots: snapshots,
                librarySummary: LibrarySummary(repoDiffCount: 0, autoUpdatesCount: 0, sizeUnknownCount: 0, leafCount: 0),
                runtimeScanState: .failed("You have not agreed to the Xcode license agreements.")
            )
            let runtime = summary.domains.first { $0.id == "runtime" }
            XCTAssertEqual(runtime?.value, "扫描失败")
            XCTAssertEqual(runtime?.severity, .critical)
            XCTAssertEqual(summary.severity, .critical)
            XCTAssertTrue(summary.items.contains { $0.id == "runtime.scan.failed" })
            XCTAssertTrue(runtime?.detail.contains(snapshots.isEmpty ? "尚无可用快照" : "上次成功快照") == true)
        }
    }

    func testRuntimeUncheckedAndScanningAreNotHealthy() {
        for (state, expected) in [(RuntimeScanState.notChecked, "未检查"), (.scanning, "扫描中"), (.succeeded, "正常")] {
            let summary = DashboardHealthSummary.make(
                brewStatus: .upToDate, outdatedPackages: [], operationSummary: nil,
                runtimeSnapshots: [makeNodeSnapshot(issues: [])],
                librarySummary: LibrarySummary(repoDiffCount: 0, autoUpdatesCount: 0, sizeUnknownCount: 0, leafCount: 0),
                runtimeScanState: state
            )
            XCTAssertEqual(summary.domains.first { $0.id == "runtime" }?.value, expected)
            XCTAssertFalse(summary.items.contains { $0.id == "runtime.scan.failed" })
        }
    }

    func testBrewReliabilityDiagnosticsClassifiesBrewMissing() {
        let issue = BrewReliabilityDiagnostics.diagnose(error: BrewError.brewNotFound)

        XCTAssertEqual(issue.kind, .brewMissing)
        XCTAssertEqual(issue.title, "未找到 brew")
        XCTAssertTrue(issue.manualCommands.contains("which brew"))
    }

    func testBrewReliabilityDiagnosticsClassifiesDNSAndNetworkText() {
        let dnsIssue = BrewReliabilityDiagnostics.diagnose(
            text: "curl: (6) Could not resolve host: formulae.brew.sh"
        )
        let networkIssue = BrewReliabilityDiagnostics.diagnose(
            text: "Failed to connect to api.github.com port 443 after 75001 ms: Operation timed out"
        )
        let plainNetworkIssue = BrewReliabilityDiagnostics.diagnose(
            text: "Network is unreachable while fetching Homebrew metadata"
        )

        XCTAssertEqual(dnsIssue.kind, .dns)
        XCTAssertEqual(networkIssue.kind, .endpoint)
        XCTAssertEqual(plainNetworkIssue.kind, .network)
        XCTAssertTrue(dnsIssue.nextStep.contains("偏好设置"))
        XCTAssertTrue(networkIssue.nextStep.contains("代理"))
    }

    func testBrewReliabilityDiagnosticsClassifiesPermissionWithoutAutoRepair() {
        let issue = BrewReliabilityDiagnostics.diagnose(
            error: BrewError.executionFailed(code: 1, message: "/opt/homebrew/Cellar is not writable")
        )

        XCTAssertEqual(issue.kind, .permission)
        XCTAssertTrue(issue.impact.contains("不会自动修改"))
        XCTAssertFalse(issue.manualCommands.contains { $0.contains("chmod") || $0.contains("chown") })
    }

    func testDashboardSummaryPromotesReliabilityIssueToSettingsAction() {
        let summary = BrewOperationPlanner.failureSummary(
            kind: .upgrade,
            startedAt: Date(),
            error: BrewError.executionFailed(code: 1, message: "/opt/homebrew/Cellar is not writable")
        )
        let dashboard = DashboardHealthSummary.make(
            brewStatus: .upToDate,
            outdatedPackages: [],
            operationSummary: summary,
            runtimeSnapshots: [],
            librarySummary: LibrarySummary(repoDiffCount: 0, autoUpdatesCount: 0, sizeUnknownCount: 0, leafCount: 0)
        )

        XCTAssertEqual(dashboard.severity, .critical)
        XCTAssertTrue(dashboard.items.contains { $0.id.contains("permission") && $0.actionTitle == "查看核对建议" })
    }

    func testDashboardSummaryRoutesNetworkReliabilityIssueToConnectionSettings() {
        let summary = BrewOperationPlanner.failureSummary(
            kind: .checkUpdates,
            startedAt: Date(),
            error: BrewError.executionFailed(code: 1, message: "proxyconnect tcp: connect tunnel failed")
        )
        let dashboard = DashboardHealthSummary.make(
            brewStatus: .upToDate,
            outdatedPackages: [],
            operationSummary: summary,
            runtimeSnapshots: [],
            librarySummary: LibrarySummary(repoDiffCount: 0, autoUpdatesCount: 0, sizeUnknownCount: 0, leafCount: 0)
        )

        XCTAssertTrue(dashboard.items.contains { item in
            item.id.contains("proxy") && item.action == .showSettings(.connection)
        })
    }

    func testUpgradeSummaryUsesPostUpgradeOutdatedSnapshot() {
        let package = makePackage(name: "git", installedVersion: "2.0", currentVersion: "2.1")

        let summary = BrewOperationPlanner.upgradeFinished(
            startedAt: Date(),
            targetPackages: [package],
            remainingOutdatedPackages: []
        )

        XCTAssertTrue(summary.summaryText.contains("目标 1 个包"))
        XCTAssertTrue(summary.summaryText.contains("复核后已不在 outdated 的数量 1"))
        XCTAssertTrue(summary.summaryText.contains("仍在 outdated 的包：无"))
        XCTAssertFalse(summary.summaryText.contains("已升级"))
        XCTAssertEqual(summary.compactRecapText, "已升级 1 个包，复核通过")
    }

    func testUpgradeSummaryReportsTargetsStillOutdatedAfterVerification() {
        let package = makePackage(name: "git", installedVersion: "2.0", currentVersion: "2.1")

        let summary = BrewOperationPlanner.upgradeFinished(
            startedAt: Date(),
            targetPackages: [package],
            remainingOutdatedPackages: [package]
        )

        XCTAssertTrue(summary.summaryText.contains("仍在 outdated 的包：git"))
        XCTAssertEqual(summary.compactRecapText, "已处理 1 个包，仍有 1 个需复核")
        XCTAssertTrue(summary.recommendedNextAction?.contains("Homebrew 输出跳过") ?? false)
    }

    func testUpgradeSummaryListsPerPackageVerificationResults() {
        let done = makePackage(name: "node", installedVersion: "1.0", currentVersion: "1.1")
        let still = makePackage(name: "pandoc", installedVersion: "3.11", currentVersion: "3.12")

        let summary = BrewOperationPlanner.upgradeFinished(
            startedAt: Date(),
            targetPackages: [done, still],
            remainingOutdatedPackages: [still]
        )

        XCTAssertEqual(summary.packageVerificationResults.map(\.status), [.completed, .stillOutdated])
        XCTAssertTrue(summary.summaryText.contains("node：已完成"))
        XCTAssertTrue(summary.summaryText.contains("pandoc：仍 outdated"))
    }

    func testUpgradeFailureSummaryMarksAttemptedTimedOutAndUnexecutedPackages() {
        let attempted = makePackage(name: "pandoc", installedVersion: "3.11", currentVersion: "3.12")
        let notExecuted = makePackage(name: "mlx", installedVersion: "0.32.1", currentVersion: "0.32.3")
        let error = BrewError.timedOut(command: "brew upgrade pandoc；下载证据：无输出且 .incomplete 字节无增长", seconds: 180)

        let summary = BrewOperationPlanner.upgradeFailureSummary(
            startedAt: Date(),
            targetPackages: [attempted, notExecuted],
            attemptedPackageIDs: [attempted.id],
            failedPackageIDs: [attempted.id],
            error: error
        )

        XCTAssertEqual(summary.packageVerificationResults.map(\.status), [.timedOut, .notExecuted])
        XCTAssertTrue(summary.summaryText.contains("pandoc：被超时终止"))
        XCTAssertTrue(summary.summaryText.contains("mlx：未执行"))
    }

    func testUpgradeFailureSummaryKeepsCompletedGroupWhenLaterGroupTimesOut() {
        let completed = makePackage(name: "node", installedVersion: "1.0", currentVersion: "1.1")
        let failed = makePackage(name: "pandoc", installedVersion: "3.11", currentVersion: "3.12")
        let notExecuted = makePackage(name: "mlx", installedVersion: "0.32.1", currentVersion: "0.32.3")
        let error = BrewError.timedOut(command: "brew upgrade pandoc", seconds: 180)

        let summary = BrewOperationPlanner.upgradeFailureSummary(
            startedAt: Date(),
            targetPackages: [completed, failed, notExecuted],
            attemptedPackageIDs: [completed.id, failed.id],
            completedPackageIDs: [completed.id],
            failedPackageIDs: [failed.id],
            remainingOutdatedPackages: [failed, notExecuted],
            error: error
        )

        XCTAssertEqual(summary.packageVerificationResults.map(\.status), [.completed, .timedOut, .notExecuted])
        XCTAssertTrue(summary.summaryText.contains("node：已完成"))
        XCTAssertTrue(summary.summaryText.contains("pandoc：被超时终止"))
        XCTAssertTrue(summary.summaryText.contains("mlx：未执行"))
    }

    func testUpgradeFailureSummaryUsesUnknownWhenCompletedGroupCannotBeVerified() {
        let completed = makePackage(name: "node", installedVersion: "1.0", currentVersion: "1.1")
        let failed = makePackage(name: "pandoc", installedVersion: "3.11", currentVersion: "3.12")
        let error = BrewError.executionFailed(code: 1, message: "network failed")
        let verificationError = BrewError.executionFailed(code: 1, message: "outdated check failed")

        let summary = BrewOperationPlanner.upgradeFailureSummary(
            startedAt: Date(),
            targetPackages: [completed, failed],
            attemptedPackageIDs: [completed.id, failed.id],
            completedPackageIDs: [completed.id],
            failedPackageIDs: [failed.id],
            verificationError: verificationError,
            error: error
        )

        XCTAssertEqual(summary.packageVerificationResults.map(\.status), [.unknown, .commandFailed])
        XCTAssertTrue(summary.summaryText.contains("命令失败"))
        XCTAssertTrue(summary.summaryText.contains("失败后复核失败"))
    }

    func testDownloadIdleTimeoutStartsSamplingBeforeIdleThreshold() {
        XCTAssertEqual(
            HomebrewStreamIdleTimeoutPolicy.initialTimerDelay(idleTimeoutSeconds: 180, hasDownloadMonitor: true),
            HomebrewStreamIdleTimeoutPolicy.downloadSamplingInterval
        )
        XCTAssertEqual(
            HomebrewStreamIdleTimeoutPolicy.initialTimerDelay(idleTimeoutSeconds: 180, hasDownloadMonitor: false),
            180
        )
        var state = HomebrewStreamIdleTimeoutState()
        let now = Date(timeIntervalSince1970: 1_000)
        let trustedSample = HomebrewDownloadEvidenceSample(trustedDiscovery: true, trustedByteGrowth: false, uncertainActivity: false, message: nil)
        XCTAssertEqual(
            HomebrewStreamIdleTimeoutPolicy.decision(
                idleSeconds: 180,
                timeoutSeconds: 180,
                sample: trustedSample,
                now: now,
                state: &state
            ),
            .continueWaiting
        )
        XCTAssertEqual(
            HomebrewStreamIdleTimeoutPolicy.decision(
                idleSeconds: 196,
                timeoutSeconds: 180,
                sample: nil,
                now: now.addingTimeInterval(16),
                state: &state
            ),
            .terminate
        )
    }

    func testDownloadIdleTimeoutGivesBoundaryTargetFileObservationWindow() {
        var state = HomebrewStreamIdleTimeoutState()
        let now = Date(timeIntervalSince1970: 2_000)
        let newTargetFile = HomebrewDownloadEvidenceSample(trustedDiscovery: true, trustedByteGrowth: false, uncertainActivity: false, message: "发现 pandoc.incomplete")

        XCTAssertEqual(
            HomebrewStreamIdleTimeoutPolicy.decision(
                idleSeconds: 180,
                timeoutSeconds: 180,
                sample: newTargetFile,
                now: now,
                state: &state
            ),
            .continueWaiting
        )
        XCTAssertEqual(
            HomebrewStreamIdleTimeoutPolicy.decision(
                idleSeconds: 190,
                timeoutSeconds: 180,
                sample: nil,
                now: now.addingTimeInterval(10),
                state: &state
            ),
            .continueWaiting
        )
        XCTAssertEqual(
            HomebrewStreamIdleTimeoutPolicy.decision(
                idleSeconds: 196,
                timeoutSeconds: 180,
                sample: nil,
                now: now.addingTimeInterval(16),
                state: &state
            ),
            .terminate
        )
    }

    func testDownloadIdleTimeoutDoesNotLetUnscopedGrowthExtendForever() {
        var state = HomebrewStreamIdleTimeoutState()
        let now = Date(timeIntervalSince1970: 3_000)
        let unscoped = HomebrewDownloadEvidenceSample(trustedDiscovery: false, trustedByteGrowth: false, uncertainActivity: true, message: "发现 dependency.incomplete")

        XCTAssertEqual(
            HomebrewStreamIdleTimeoutPolicy.decision(
                idleSeconds: 180,
                timeoutSeconds: 180,
                sample: unscoped,
                now: now,
                state: &state
            ),
            .continueWaiting
        )
        XCTAssertEqual(
            HomebrewStreamIdleTimeoutPolicy.decision(
                idleSeconds: 190,
                timeoutSeconds: 180,
                sample: nil,
                now: now.addingTimeInterval(10),
                state: &state
            ),
            .continueWaiting
        )
        XCTAssertEqual(
            HomebrewStreamIdleTimeoutPolicy.decision(
                idleSeconds: 196,
                timeoutSeconds: 180,
                sample: unscoped,
                now: now.addingTimeInterval(16),
                state: &state
            ),
            .terminate
        )
    }

    func testDownloadIdleTimeoutExtendsWhenBoundaryTargetFileGrows() {
        var state = HomebrewStreamIdleTimeoutState()
        let now = Date(timeIntervalSince1970: 4_000)
        let trusted = HomebrewDownloadEvidenceSample(trustedDiscovery: false, trustedByteGrowth: true, uncertainActivity: false, message: nil)

        XCTAssertEqual(
            HomebrewStreamIdleTimeoutPolicy.decision(idleSeconds: 180, timeoutSeconds: 180, sample: trusted, now: now, state: &state),
            .continueWaiting
        )
        XCTAssertEqual(
            HomebrewStreamIdleTimeoutPolicy.decision(idleSeconds: 196, timeoutSeconds: 180, sample: trusted, now: now.addingTimeInterval(16), state: &state),
            .continueWaiting
        )
        XCTAssertEqual(
            HomebrewStreamIdleTimeoutPolicy.decision(idleSeconds: 210, timeoutSeconds: 180, sample: nil, now: now.addingTimeInterval(30), state: &state),
            .continueWaiting
        )
    }

    func testTrustedByteGrowthResetsFullIdleWindow() {
        var state = HomebrewStreamIdleTimeoutState()
        let outputAtZero = Date(timeIntervalSince1970: 5_000)
        let growthAt300 = outputAtZero.addingTimeInterval(300)
        let growth = HomebrewDownloadEvidenceSample(trustedDiscovery: false, trustedByteGrowth: true, uncertainActivity: false, message: nil)

        XCTAssertEqual(
            HomebrewStreamIdleTimeoutPolicy.decision(
                idleSeconds: 300,
                timeoutSeconds: 180,
                sample: growth,
                now: growthAt300,
                state: &state
            ),
            .continueWaiting
        )
        XCTAssertEqual(
            HomebrewStreamIdleTimeoutPolicy.decision(
                idleSeconds: 315,
                timeoutSeconds: 180,
                sample: nil,
                now: outputAtZero.addingTimeInterval(315),
                state: &state
            ),
            .continueWaiting
        )
        XCTAssertEqual(
            HomebrewStreamIdleTimeoutPolicy.decision(
                idleSeconds: 480,
                timeoutSeconds: 180,
                sample: nil,
                now: outputAtZero.addingTimeInterval(480),
                state: &state
            ),
            .terminate
        )
    }

    func testContinuousTrustedByteGrowthKeepsWaiting() {
        var state = HomebrewStreamIdleTimeoutState()
        let outputAtZero = Date(timeIntervalSince1970: 6_000)
        let growth = HomebrewDownloadEvidenceSample(trustedDiscovery: false, trustedByteGrowth: true, uncertainActivity: false, message: nil)

        XCTAssertEqual(HomebrewStreamIdleTimeoutPolicy.decision(idleSeconds: 200, timeoutSeconds: 180, sample: growth, now: outputAtZero.addingTimeInterval(200), state: &state), .continueWaiting)
        XCTAssertEqual(HomebrewStreamIdleTimeoutPolicy.decision(idleSeconds: 360, timeoutSeconds: 180, sample: growth, now: outputAtZero.addingTimeInterval(360), state: &state), .continueWaiting)
        XCTAssertEqual(HomebrewStreamIdleTimeoutPolicy.decision(idleSeconds: 530, timeoutSeconds: 180, sample: nil, now: outputAtZero.addingTimeInterval(530), state: &state), .continueWaiting)
    }

    func testRepeatedDiscoveryWithoutByteGrowthEventuallyTerminates() {
        var state = HomebrewStreamIdleTimeoutState()
        let now = Date(timeIntervalSince1970: 7_000)
        let discovery = HomebrewDownloadEvidenceSample(trustedDiscovery: true, trustedByteGrowth: false, uncertainActivity: false, message: nil)

        XCTAssertEqual(HomebrewStreamIdleTimeoutPolicy.decision(idleSeconds: 180, timeoutSeconds: 180, sample: discovery, now: now, state: &state), .continueWaiting)
        XCTAssertEqual(HomebrewStreamIdleTimeoutPolicy.decision(idleSeconds: 196, timeoutSeconds: 180, sample: discovery, now: now.addingTimeInterval(16), state: &state), .terminate)
    }

    func testDownloadEvidenceMonitorTreatsGrowingIncompleteAsProgress() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cellar-download-evidence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let incomplete = root.appendingPathComponent("pandoc--archive.tar.gz.incomplete")
        try Data(repeating: 1, count: 4).write(to: incomplete)
        let monitor = HomebrewDownloadEvidenceMonitor(directories: [root.path], targetTokens: ["pandoc"])

        XCTAssertEqual(monitor.sample().message?.contains(".incomplete"), true)
        try Data(repeating: 1, count: 12).write(to: incomplete)
        let growth = monitor.sample()

        XCTAssertTrue(growth.grew)
        XCTAssertTrue(monitor.summary().didGrow)
        XCTAssertTrue(monitor.summary().detailText.contains("检测到 .incomplete 字节增长"))
    }

    func testDownloadEvidenceMonitorObservesFileCreatedAfterInitialMiss() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cellar-download-late-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = HomebrewDownloadEvidenceMonitor(directories: [root.path], targetTokens: ["pandoc"])

        XCTAssertNil(monitor.sample().message)
        let incomplete = root.appendingPathComponent("pandoc--archive.tar.gz.incomplete")
        try Data(repeating: 1, count: 4).write(to: incomplete)
        let firstObserved = monitor.sample()
        XCTAssertEqual(firstObserved.message?.contains("发现"), true)
        XCTAssertTrue(firstObserved.grew)
        try Data(repeating: 1, count: 12).write(to: incomplete)
        XCTAssertTrue(monitor.sample().grew)
        XCTAssertTrue(monitor.summary().didGrow)
        XCTAssertFalse(monitor.summary().detailText.contains("未找到相关"))
    }

    func testDownloadEvidenceMonitorExplainsNoGrowthStall() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cellar-download-stall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let incomplete = root.appendingPathComponent("ollama--archive.tar.gz.incomplete")
        try Data(repeating: 1, count: 8).write(to: incomplete)
        let monitor = HomebrewDownloadEvidenceMonitor(directories: [root.path], targetTokens: ["ollama"])

        _ = monitor.sample()
        _ = monitor.sample()
        let summary = monitor.summary()

        XCTAssertFalse(summary.didGrow)
        XCTAssertTrue(summary.detailText.contains("未检测到 .incomplete 字节增长"))
    }

    func testDownloadEvidenceMonitorUsesInheritedHomebrewCacheEnvironment() {
        let environment = HomebrewDownloadEvidenceMonitor.effectiveEnvironment(overrides: ["HOMEBREW_CACHE": ""])

        XCTAssertNil(environment["HOMEBREW_CACHE"])

        let overridden = HomebrewDownloadEvidenceMonitor.effectiveEnvironment(overrides: ["HOMEBREW_CACHE": "/tmp/custom-homebrew-cache"])
        XCTAssertEqual(overridden["HOMEBREW_CACHE"], "/tmp/custom-homebrew-cache")
        XCTAssertTrue(HomebrewDownloadEvidenceMonitor.defaultDownloadDirectories(environment: overridden).contains("/tmp/custom-homebrew-cache"))
    }

    func testDownloadEvidenceMonitorTracksDependencyAndTapTargets() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cellar-download-dependency-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = HomebrewDownloadEvidenceMonitor(
            directories: [root.path],
            targetTokens: ["homebrew/core/pandoc"],
            startedAt: Date()
        )
        let dependency = root.appendingPathComponent("unicode-collation--dependency.tar.gz.incomplete")
        try Data(repeating: 1, count: 7).write(to: dependency)

        let sample = monitor.sample()
        XCTAssertEqual(sample.message?.contains("unicode-collation"), true)
        XCTAssertFalse(sample.grew)
        XCTAssertEqual(monitor.knownFileEvidence().count, 1)
        XCTAssertTrue(monitor.summary().detailText.contains("依赖或间接下载线索"))
    }

    func testDownloadEvidenceMonitorDeduplicatesParentAndDownloadsDirectory() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cellar-download-dedup-\(UUID().uuidString)")
        let downloads = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let incomplete = downloads.appendingPathComponent("pandoc--archive.tar.gz.incomplete")
        try Data(repeating: 1, count: 5).write(to: incomplete)
        let monitor = HomebrewDownloadEvidenceMonitor(directories: [root.path, downloads.path], targetTokens: ["pandoc"])

        _ = monitor.sample()

        XCTAssertEqual(monitor.knownFileEvidence().count, 1)
        XCTAssertEqual(monitor.summary().initialBytes, 5)
    }

    func testDownloadEvidenceMonitorDistinguishesCompletedFileFromRestart() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cellar-download-complete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let completed = root.appendingPathComponent("pandoc--archive.tar.gz.incomplete")
        let growing = root.appendingPathComponent("pandoc--dependency.tar.gz.incomplete")
        try Data(repeating: 1, count: 8).write(to: completed)
        try Data(repeating: 1, count: 4).write(to: growing)
        let monitor = HomebrewDownloadEvidenceMonitor(directories: [root.path], targetTokens: ["pandoc"])

        _ = monitor.sample()
        try FileManager.default.removeItem(at: completed)
        try Data(repeating: 1, count: 12).write(to: growing)
        let sample = monitor.sample()
        let summary = monitor.summary()

        XCTAssertTrue(sample.grew)
        XCTAssertTrue(summary.didGrow)
        XCTAssertFalse(summary.suspectedRestartOrOverwrite)
        XCTAssertTrue(summary.detailText.contains("已完成、移走或不再可见"))
    }

    func testDownloadEvidenceMonitorTreatsReappearedTargetFileAsNewObservation() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cellar-download-reappear-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let incomplete = root.appendingPathComponent("pandoc--archive.tar.gz.incomplete")
        try Data(repeating: 1, count: 8).write(to: incomplete)
        let monitor = HomebrewDownloadEvidenceMonitor(directories: [root.path], targetTokens: ["pandoc"])

        _ = monitor.sample()
        try FileManager.default.removeItem(at: incomplete)
        _ = monitor.sample()
        try Data(repeating: 1, count: 8).write(to: incomplete)
        let reappeared = monitor.sample()

        XCTAssertTrue(reappeared.grew)
        XCTAssertTrue(reappeared.message?.contains("重新发现") ?? false)
    }

    func testDownloadEvidenceMonitorMarksTruncatedFileAsSuspectedRestart() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cellar-download-truncate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let incomplete = root.appendingPathComponent("pandoc--archive.tar.gz.incomplete")
        try Data(repeating: 1, count: 20).write(to: incomplete)
        let monitor = HomebrewDownloadEvidenceMonitor(directories: [root.path], targetTokens: ["pandoc"])

        _ = monitor.sample()
        try Data(repeating: 1, count: 4).write(to: incomplete)
        _ = monitor.sample()

        XCTAssertTrue(monitor.summary().suspectedRestartOrOverwrite)
        XCTAssertTrue(monitor.summary().detailText.contains("疑似重下或覆盖"))
    }

    func testDownloadEvidenceParserClassifiesRangeAndFullDownloadSignals() {
        XCTAssertEqual(HomebrewDownloadEvidenceParser.transferEvidence(from: "HTTP/2 206 Partial Content"), .rangeResume)
        XCTAssertEqual(HomebrewDownloadEvidenceParser.transferEvidence(from: "Content-Range: bytes 10-20/40"), .rangeResume)
        XCTAssertEqual(HomebrewDownloadEvidenceParser.transferEvidence(from: "HTTP/2 200 OK"), .fullDownload)
        XCTAssertEqual(HomebrewDownloadEvidenceParser.transferEvidence(from: "plain Homebrew output"), .unknown)
    }

    func testHomebrewExplicitProxyStateUsesHonestWording() {
        let disabled = HomebrewExplicitProxyState.make(environment: [:])
        XCTAssertTrue(disabled.logLine.contains("未注入 Cellar 显式代理"))
        XCTAssertTrue(disabled.logLine.contains("实际代理节点未知"))
        XCTAssertFalse(disabled.logLine.contains("直连"))

        let enabled = HomebrewExplicitProxyState.make(environment: ["ALL_PROXY": "socks5://127.0.0.1:7897"])
        XCTAssertTrue(enabled.logLine.contains("socks5 127.0.0.1:7897"))
        XCTAssertTrue(enabled.logLine.contains("实际出口节点未知"))
    }

    func testPackageSizeEstimateExplainsUnknownUpgradeSize() {
        let unknownPackage = makePackage(name: "git", installedVersion: "2.0", currentVersion: "2.1")
        let knownPackage = makePackage(
            name: "wget",
            installedVersion: "1.0",
            currentVersion: "1.1",
            installedSizeBytes: 2048
        )

        let unknown = PackageSizeEstimate.estimate(for: unknownPackage, context: .upgradeCandidate)
        let known = PackageSizeEstimate.estimate(for: knownPackage, context: .upgradeCandidate)
        let summary = PackageSizeEstimateSummary(estimates: [unknown, known])

        XCTAssertEqual(unknown.displayText(using: ByteCountFormatter()), "未知")
        XCTAssertTrue(unknown.helpText.contains("Homebrew outdated 元数据未提供下载大小"))
        XCTAssertEqual(known.statusText, "当前体量参考")
        XCTAssertTrue(known.displayText(using: ByteCountFormatter()).contains("当前"))
        XCTAssertEqual(unknown.confirmationShortText(using: ByteCountFormatter()), "下载未知")
        XCTAssertTrue(known.confirmationShortText(using: ByteCountFormatter()).contains("当前包"))
        XCTAssertFalse(known.confirmationShortText(using: ByteCountFormatter()).contains("不代表下载量"))
        XCTAssertTrue(known.confirmationText(using: ByteCountFormatter()).contains("不代表下载量"))
        XCTAssertTrue(known.helpText.contains("仅用于判断升级影响范围"))
        XCTAssertEqual(summary.knownCount, 1)
        XCTAssertEqual(summary.knownDownloadCount, 0)
        XCTAssertEqual(summary.knownInstalledReferenceCount, 1)
        XCTAssertEqual(summary.unknownCount, 1)
        XCTAssertTrue(summary.downloadSummaryText(using: ByteCountFormatter()).contains("暂无已知下载大小"))
        XCTAssertTrue(summary.installedReferenceSummaryText(using: ByteCountFormatter()).contains("当前/旧包参考体量"))
        XCTAssertTrue(summary.unknownSummaryText.contains("本机安装大小尚未完成探测"))
    }

    func testPackageSizeSummaryKeepsDownloadAndInstalledReferenceSeparate() {
        let formatter = ByteCountFormatter()
        let download = PackageSizeEstimate.knownDownloadSize(1024)
        let reference = PackageSizeEstimate.knownInstalledReferenceSize(2048)
        let summary = PackageSizeEstimateSummary(estimates: [download, reference])

        XCTAssertEqual(summary.knownDownloadCount, 1)
        XCTAssertEqual(summary.knownDownloadBytes, 1024)
        XCTAssertEqual(summary.knownInstalledReferenceCount, 1)
        XCTAssertEqual(summary.knownInstalledReferenceBytes, 2048)
        XCTAssertTrue(summary.downloadSummaryText(using: formatter).contains("下载大小合计"))
        XCTAssertTrue(summary.installedReferenceSummaryText(using: formatter).contains("参考体量合计"))
    }

    func testPackageSizeConfirmationShortLabelsSeparateDownloadReferenceAndUnknown() {
        let formatter = ByteCountFormatter()
        let download = PackageSizeEstimate.knownDownloadSize(68 * 1_024 * 1_024)
        let reference = PackageSizeEstimate.knownInstalledReferenceSize(707 * 1_024 * 1_024)
        let unknown = PackageSizeEstimate.unknown(reason: "Homebrew outdated 元数据未提供下载大小，本机安装大小尚未完成探测。")

        XCTAssertTrue(download.confirmationShortText(using: formatter).hasPrefix("下载 "))
        XCTAssertTrue(reference.confirmationShortText(using: formatter).hasPrefix("当前包 "))
        XCTAssertEqual(unknown.confirmationShortText(using: formatter), "下载未知")
        XCTAssertFalse(download.confirmationShortText(using: formatter).contains("不代表"))
        XCTAssertFalse(reference.confirmationShortText(using: formatter).contains("不代表"))
        XCTAssertFalse(unknown.confirmationShortText(using: formatter).contains("Homebrew outdated"))
    }

    func testOutdatedCandidateMergesInstalledLibrarySizeBeforeDisplay() {
        let installed = makePackage(
            name: "dotnet",
            installedVersion: "9.0.0",
            currentVersion: "9.0.0",
            installedSizeBytes: 707 * 1_024 * 1_024
        )
        let candidate = makePackage(name: "dotnet", installedVersion: "9.0.0", currentVersion: "9.0.1")

        let merged = PackageSizeReferenceMerger.mergeInstalledSizes(into: [candidate], from: [installed])
        let estimate = PackageSizeEstimate.estimate(for: merged[0], context: .upgradeCandidate)

        XCTAssertEqual(merged[0].installedSizeBytes, installed.installedSizeBytes)
        XCTAssertEqual(estimate.statusText, "当前体量参考")
        XCTAssertTrue(estimate.displayText(using: ByteCountFormatter()).contains("当前"))
    }

    func testLateInstalledSizeProbeSynchronizesOutdatedCandidates() {
        let candidate = makePackage(name: "uv", installedVersion: "0.7.0", currentVersion: "0.7.1")
        var outdated = [candidate]

        PackageSizeReferenceMerger.updateInstalledSize(
            packageID: candidate.id,
            installedSizeBytes: 64 * 1_024 * 1_024,
            in: &outdated
        )
        let estimate = PackageSizeEstimate.estimate(for: outdated[0], context: .upgradeCandidate)

        XCTAssertEqual(outdated[0].installedSizeBytes, 64 * 1_024 * 1_024)
        XCTAssertEqual(estimate.statusText, "当前体量参考")
        XCTAssertTrue(estimate.helpText.contains("不代表下载量"))
    }

    func testCaskBundlePathResolverMatchesVersionReaderStrategy() {
        let homeApplications = NSString(string: "~/Applications").expandingTildeInPath
        let paths = CaskAppBundlePathResolver.candidatePaths(appArtifactNames: [
            "Google Chrome",
            "Microsoft Edge.app",
            "Google Chrome"
        ])

        XCTAssertEqual(paths, [
            "/Applications/Google Chrome.app",
            "\(homeApplications)/Google Chrome.app",
            "/Applications/Microsoft Edge.app",
            "\(homeApplications)/Microsoft Edge.app"
        ])
    }

    func testCaskSizeProbePathsPreferTruthBundleThenApplicationAndCaskroom() {
        let package = BrewPackage(
            name: "google-chrome",
            desc: "Google Chrome",
            installedVersions: ["145.0.1"],
            currentVersion: "150.0.3",
            isPinned: false,
            isLeaf: true,
            type: .cask,
            autoUpdates: true,
            installedSizeBytes: nil,
            appArtifactNames: ["Google Chrome"],
            caskVersionTruth: CaskVersionTruth.make(
                homebrewReceiptVersion: "145.0.1",
                appBundleReadResult: .found(shortVersion: "150.0.2", buildVersion: nil, bundlePath: "/Custom/Google Chrome.app"),
                repositoryVersion: "150.0.3"
            )
        )
        let homeApplications = NSString(string: "~/Applications").expandingTildeInPath

        XCTAssertEqual(CaskAppBundlePathResolver.sizeProbeCandidates(for: package), [
            .appBundle(path: "/Custom/Google Chrome.app"),
            .appBundle(path: "/Applications/Google Chrome.app"),
            .appBundle(path: "\(homeApplications)/Google Chrome.app"),
            .caskroomVersionDirectory(path: "/opt/homebrew/Caskroom/google-chrome/145.0.1"),
            .caskroomVersionDirectory(path: "/usr/local/Caskroom/google-chrome/145.0.1")
        ])
    }

    func testCaskroomReceiptOnlyDirectoryDoesNotBecomeAppBundleCandidate() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CellarLogicTests-\(UUID().uuidString)")
        let caskroomVersion = root
            .appendingPathComponent("Caskroom")
            .appendingPathComponent("google-chrome")
            .appendingPathComponent("147.0.7727.56")
        try FileManager.default.createDirectory(at: caskroomVersion, withIntermediateDirectories: true)
        try "receipt".write(to: caskroomVersion.appendingPathComponent(".keystone_install"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertTrue(CaskAppBundlePathResolver.appBundleCandidates(inCaskroomVersionDirectory: caskroomVersion.path).isEmpty)
    }

    func testCaskroomAppSymlinkIsRecognizedWithoutUsingVersionDirectorySize() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CellarLogicTests-\(UUID().uuidString)")
        let applications = root.appendingPathComponent("Applications")
        let appBundle = applications.appendingPathComponent("Google Chrome.app")
        let caskroomVersion = root
            .appendingPathComponent("Caskroom")
            .appendingPathComponent("google-chrome")
            .appendingPathComponent("147.0.7727.56")
        try FileManager.default.createDirectory(at: appBundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: caskroomVersion, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: caskroomVersion.appendingPathComponent("Google Chrome.app"),
            withDestinationURL: appBundle
        )
        try "receipt".write(to: caskroomVersion.appendingPathComponent(".keystone_install"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            CaskAppBundlePathResolver.appBundleCandidates(inCaskroomVersionDirectory: caskroomVersion.path),
            [caskroomVersion.appendingPathComponent("Google Chrome.app").path]
        )
    }

    func testSelfUpdatingCaskUnknownSizeExplainsAppBundleAndCaskroom() {
        let package = BrewPackage(
            name: "google-chrome",
            desc: "Google Chrome",
            installedVersions: ["145.0.1"],
            currentVersion: "150.0.3",
            isPinned: false,
            isLeaf: true,
            type: .cask,
            autoUpdates: true,
            installedSizeBytes: nil,
            appArtifactNames: ["Google Chrome.app"]
        )

        let estimate = PackageSizeEstimate.estimate(for: package, context: .upgradeCandidate)

        XCTAssertEqual(estimate.displayText(using: ByteCountFormatter()), "未知")
        XCTAssertTrue(estimate.helpText.contains("当前 App bundle"))
        XCTAssertTrue(estimate.helpText.contains("Caskroom receipt 目录不会作为当前 App 体量"))
        XCTAssertTrue(estimate.helpText.contains("不是 Homebrew outdated 下载大小"))
    }

    func testUpgradeProgressSummaryReportsStageAndTargetCount() {
        let package = makePackage(name: "git", installedVersion: "2.0", currentVersion: "2.1")

        let preparing = BrewOperationPlanner.upgradeProgressSummary(
            stage: .preparingUpgrade,
            packages: [package],
            startedAt: Date()
        )
        let upgrading = BrewOperationPlanner.upgradeProgressSummary(
            stage: .upgradingPackage,
            packages: [package],
            startedAt: Date(),
            currentPackage: package,
            currentPackageIndex: 1
        )
        let verifying = BrewOperationPlanner.upgradeProgressSummary(
            stage: .verifyingOutdated,
            packages: [package],
            startedAt: Date()
        )

        XCTAssertEqual(preparing.progress?.stage, .preparingUpgrade)
        XCTAssertTrue(preparing.summaryText.contains("共 1 个目标包"))
        XCTAssertTrue(upgrading.summaryText.contains("正在升级 git"))
        XCTAssertTrue(verifying.summaryText.contains("正在复核 outdated"))
        XCTAssertTrue(verifying.recommendedNextAction?.contains("目标包数量：1") ?? false)
    }

    func testUpgradeSummaryReportsVerificationFailureReason() {
        let package = makePackage(name: "git", installedVersion: "2.0", currentVersion: "2.1")

        let summary = BrewOperationPlanner.upgradeFinished(
            startedAt: Date(),
            targetPackages: [package],
            remainingOutdatedPackages: [package],
            verificationError: BrewError.executionFailed(code: 1, message: "outdated parse failed")
        )

        XCTAssertTrue(summary.summaryText.contains("目标 1 个包"))
        XCTAssertTrue(summary.summaryText.contains("复核失败原因"))
        XCTAssertTrue(summary.summaryText.contains("outdated parse failed"))
    }

    func testBrewJSONParsersHandleFormulaAndCask() throws {
        let outdated = try JSONParser.parseOutdated("""
        {"formulae":[{"name":"git","desc":"DVCS","current_version":"2.0","installed_versions":["1.0"],"pinned":false}],"casks":[]}
        """)
        XCTAssertEqual(outdated.first?.name, "git")
        XCTAssertEqual(outdated.first?.type, .formula)

        let installed = try JSONParser.parseInstalled("""
        {"formulae":[{"name":"wget","desc":"Downloader","versions":{"stable":"1.21"},"installed":[{"version":"1.20"}]}],"casks":[{"token":"sample-app","name":["Sample App"],"desc":"App","version":"2.0","installed":"1.9","auto_updates":true,"artifacts":[{"app":["Sample.app"]}]}]}
        """, leaves: ["wget"])

        XCTAssertTrue(installed.contains { $0.name == "wget" && $0.isLeaf })
        XCTAssertTrue(installed.contains { $0.name == "sample-app" && $0.autoUpdates && $0.appArtifactNames == ["Sample.app"] })
    }

    func testParseInstalledKeepsCaskReceiptAndPrefersInjectedAppBundleVersionForAutoUpdatingCask() throws {
        let installed = try JSONParser.parseInstalled("""
        {"formulae":[],"casks":[{"token":"microsoft-edge","name":["Microsoft Edge"],"desc":"Browser","version":"148.0.3967.96,207765a9-3991-4576-80dd-92c5dd9daac0","installed":"145.0.1","auto_updates":true,"artifacts":[{"app":["Microsoft Edge.app"]}]}]}
        """, leaves: []) { appNames in
            XCTAssertEqual(appNames, ["Microsoft Edge.app"])
            return .found(shortVersion: "150.0.2", buildVersion: "300", bundlePath: "/Applications/Microsoft Edge.app")
        }

        let package = try XCTUnwrap(installed.first)

        XCTAssertEqual(package.installedVersions, ["145.0.1"])
        XCTAssertEqual(package.versionDisplay, "150.0.2")
        XCTAssertEqual(package.caskVersionTruth?.homebrewReceiptVersion, "145.0.1")
        XCTAssertEqual(package.caskVersionTruth?.appBundleVersion, "150.0.2")
        XCTAssertEqual(package.caskVersionTruth?.repositoryIdentity.displayVersion, "148.0.3967.96")
    }

    func testAutoUpdatingCaskInstalledPresentationShowsAppVersionAndHomebrewRecord() {
        let package = BrewPackage(
            name: "microsoft-edge",
            desc: "Microsoft Edge",
            installedVersions: ["145.0.1"],
            currentVersion: "148.0.3967.96",
            isPinned: false,
            isLeaf: true,
            type: .cask,
            autoUpdates: true,
            installedSizeBytes: nil,
            appArtifactNames: ["Microsoft Edge.app"],
            caskVersionTruth: CaskVersionTruth.make(
                homebrewReceiptVersion: "145.0.1",
                appBundleReadResult: .found(shortVersion: "150.0.2", buildVersion: "300", bundlePath: "/Applications/Microsoft Edge.app"),
                repositoryVersion: "148.0.3967.96"
            )
        )

        let presentation = PackageInstalledVersionPresentation.make(for: package)

        XCTAssertEqual(presentation.versionText, "150.0.2")
        XCTAssertEqual(presentation.sourceLabel, "App 实际版本")
        XCTAssertEqual(presentation.secondaryText, "Homebrew 记录 145.0.1")
        XCTAssertTrue(presentation.helpText.contains("当前 App 版本：150.0.2"))
        XCTAssertTrue(presentation.helpText.contains("Homebrew 记录：145.0.1"))
        XCTAssertTrue(presentation.helpText.contains("Homebrew 仓库版本：148.0.3967.96"))
    }

    func testAutoUpdatingCaskInstalledPresentationFallsBackToReceiptWhenAppVersionUnavailable() {
        let package = BrewPackage(
            name: "sample-app",
            desc: nil,
            installedVersions: ["1.9"],
            currentVersion: "2.0",
            isPinned: false,
            isLeaf: true,
            type: .cask,
            autoUpdates: true,
            installedSizeBytes: nil,
            appArtifactNames: ["Sample.app"],
            caskVersionTruth: CaskVersionTruth.make(
                homebrewReceiptVersion: "1.9",
                appBundleReadResult: .unavailable(reason: "未在 /Applications 或 ~/Applications 找到可读取版本的 App bundle"),
                repositoryVersion: "2.0"
            )
        )

        let presentation = PackageInstalledVersionPresentation.make(for: package)

        XCTAssertEqual(presentation.versionText, "1.9")
        XCTAssertEqual(presentation.sourceLabel, "未读到 App 实际版本，暂用 Homebrew 记录")
        XCTAssertEqual(presentation.secondaryText, "暂用 Homebrew 记录 1.9")
        XCTAssertTrue(presentation.helpText.contains("未读到 App 实际版本"))
        XCTAssertTrue(presentation.helpText.contains("Homebrew 记录：1.9"))
    }

    func testOutdatedCandidateMergesInstalledCaskTruthBeforeUpdateListDisplay() {
        let installed = BrewPackage(
            name: "microsoft-edge",
            desc: "Microsoft Edge",
            installedVersions: ["145.0.1"],
            currentVersion: "148.0.3967.96",
            isPinned: false,
            isLeaf: true,
            type: .cask,
            autoUpdates: true,
            installedSizeBytes: 900 * 1_024 * 1_024,
            appArtifactNames: ["Microsoft Edge.app"],
            caskVersionTruth: CaskVersionTruth.make(
                homebrewReceiptVersion: "145.0.1",
                appBundleReadResult: .found(shortVersion: "150.0.2", buildVersion: "300", bundlePath: "/Applications/Microsoft Edge.app"),
                repositoryVersion: "148.0.3967.96"
            )
        )
        let outdatedCandidate = BrewPackage(
            name: "microsoft-edge",
            desc: "Microsoft Edge",
            installedVersions: ["145.0.1"],
            currentVersion: "150.0.3",
            isPinned: false,
            isLeaf: true,
            type: .cask,
            autoUpdates: false,
            installedSizeBytes: nil,
            appArtifactNames: []
        )

        let merged = PackageCaskTruthMerger.mergeInstalledCaskTruth(into: [outdatedCandidate], from: [installed])
        let presentation = PackageInstalledVersionPresentation.make(for: merged[0])
        let estimate = PackageSizeEstimate.estimate(for: merged[0], context: .upgradeCandidate)
        let ordinary = PackageUpgradeScope.ordinaryUpgradeCandidates(in: merged)

        XCTAssertTrue(merged[0].autoUpdates)
        XCTAssertEqual(merged[0].installedSizeBytes, 900 * 1_024 * 1_024)
        XCTAssertEqual(merged[0].appArtifactNames, ["Microsoft Edge.app"])
        XCTAssertEqual(merged[0].caskVersionTruth?.homebrewReceiptVersion, "145.0.1")
        XCTAssertEqual(merged[0].caskVersionTruth?.appBundleVersion, "150.0.2")
        XCTAssertEqual(merged[0].caskVersionTruth?.repositoryVersion, "150.0.3")
        XCTAssertTrue(ordinary.isEmpty)
        XCTAssertEqual(presentation.versionText, "150.0.2")
        XCTAssertEqual(presentation.secondaryText, "Homebrew 记录 145.0.1")
        XCTAssertTrue(presentation.helpText.contains("Homebrew 记录：145.0.1"))
        XCTAssertEqual(estimate.statusText, "当前体量参考")
        XCTAssertTrue(estimate.displayText(using: ByteCountFormatter()).contains("当前"))
        XCTAssertTrue(estimate.helpText.contains("当前 App"))
    }

    func testUpdateListClassifierSeparatesOrdinarySelfUpdatingAndRecordDiffCounts() {
        let node = BrewPackage(
            name: "node",
            desc: nil,
            installedVersions: ["24.0.0"],
            currentVersion: "24.1.0",
            isPinned: false,
            isLeaf: true,
            type: .formula,
            autoUpdates: false,
            installedSizeBytes: nil,
            appArtifactNames: []
        )
        let edge = BrewPackage(
            name: "microsoft-edge",
            desc: "Microsoft Edge",
            installedVersions: ["145.0.1"],
            currentVersion: "150.0.3",
            isPinned: false,
            isLeaf: true,
            type: .cask,
            autoUpdates: true,
            installedSizeBytes: nil,
            appArtifactNames: ["Microsoft Edge.app"],
            caskVersionTruth: CaskVersionTruth.make(
                homebrewReceiptVersion: "145.0.1",
                appBundleReadResult: .found(shortVersion: "150.0.2", buildVersion: nil, bundlePath: "/Applications/Microsoft Edge.app"),
                repositoryVersion: "150.0.3"
            )
        )
        let chrome = BrewPackage(
            name: "google-chrome",
            desc: "Google Chrome",
            installedVersions: ["145.0.1"],
            currentVersion: "150.0.3",
            isPinned: false,
            isLeaf: true,
            type: .cask,
            autoUpdates: true,
            installedSizeBytes: nil,
            appArtifactNames: ["Google Chrome.app"],
            caskVersionTruth: CaskVersionTruth.make(
                homebrewReceiptVersion: "145.0.1",
                appBundleReadResult: .found(shortVersion: "150.0.3", buildVersion: nil, bundlePath: "/Applications/Google Chrome.app"),
                repositoryVersion: "150.0.3"
            )
        )

        let groups = PackageUpdateListClassifier.groups(for: [edge, node, chrome])
        let summary = PackageUpdateListClassifier.summary(for: [edge, node, chrome])

        XCTAssertEqual(groups.map(\.kind), [.ordinary, .selfUpdatingAttention, .versionRecordDifference])
        XCTAssertEqual(groups.first { $0.kind == .ordinary }?.packages.map(\.name), ["node"])
        XCTAssertEqual(groups.first { $0.kind == .selfUpdatingAttention }?.packages.map(\.name), ["microsoft-edge"])
        XCTAssertEqual(groups.first { $0.kind == .versionRecordDifference }?.packages.map(\.name), ["google-chrome"])
        XCTAssertEqual(summary.ordinaryUpgradeCount, 1)
        XCTAssertEqual(summary.selfUpdatingAttentionCount, 1)
        XCTAssertEqual(summary.versionRecordDifferenceCount, 1)
        XCTAssertTrue(summary.visibleText.contains("普通更新 1"))
        XCTAssertTrue(summary.visibleText.contains("自更新关注 1"))
        XCTAssertTrue(summary.visibleText.contains("版本记录差异 1"))
        XCTAssertEqual(PackageUpgradeScope.ordinaryUpgradeCandidates(in: [edge, node, chrome]).map(\.name), ["node"])
    }

    func testAutoUpdatingCaskUpdatePresentationShowsRepositoryStateWithoutOrdinaryUpgradeBadge() {
        let edge = BrewPackage(
            name: "microsoft-edge",
            desc: "Microsoft Edge",
            installedVersions: ["145.0.1"],
            currentVersion: "150.0.3",
            isPinned: false,
            isLeaf: true,
            type: .cask,
            autoUpdates: true,
            installedSizeBytes: nil,
            appArtifactNames: ["Microsoft Edge.app"],
            caskVersionTruth: CaskVersionTruth.make(
                homebrewReceiptVersion: "145.0.1",
                appBundleReadResult: .found(shortVersion: "150.0.2", buildVersion: "300", bundlePath: "/Applications/Microsoft Edge.app"),
                repositoryVersion: "150.0.3"
            )
        )

        let installed = PackageInstalledVersionPresentation.make(for: edge)
        let repository = PackageVersionTablePresentation.make(for: edge, isLibrary: false)
        let updateBadges = PackageStateBadgeFactory.badges(for: edge, isLibrary: false)

        XCTAssertEqual(installed.versionText, "150.0.2")
        XCTAssertEqual(installed.sourceLabel, "App 实际版本")
        XCTAssertEqual(installed.secondaryText, "Homebrew 记录 145.0.1")
        XCTAssertEqual(repository.versionText, "150.0.3")
        XCTAssertEqual(repository.differenceLabel, "自更新 App 有新仓库版本")
        XCTAssertTrue(repository.helpText.contains("当前 App 版本：150.0.2"))
        XCTAssertTrue(repository.helpText.contains("Homebrew 记录：145.0.1"))
        XCTAssertTrue(repository.helpText.contains("Homebrew 仓库版本：150.0.3"))
        XCTAssertFalse(repository.visibleText.contains("可升级"))
        XCTAssertFalse(updateBadges.contains { $0.kind == "outdated-candidate" || $0.title == "可升级" })
        XCTAssertTrue(updateBadges.contains { $0.kind == "auto-updating-version" && $0.title == "自更新 App 差异" })
        XCTAssertFalse(updateBadges.contains { $0.kind == "auto-updates" })
    }

    func testAutoUpdatingCaskUnavailableAppVersionFallsBackToReceiptAsAttention() {
        let package = BrewPackage(
            name: "sample-app",
            desc: nil,
            installedVersions: ["1.9"],
            currentVersion: "2.0",
            isPinned: false,
            isLeaf: true,
            type: .cask,
            autoUpdates: true,
            installedSizeBytes: nil,
            appArtifactNames: ["Sample.app"],
            caskVersionTruth: CaskVersionTruth.make(
                homebrewReceiptVersion: "1.9",
                appBundleReadResult: .unavailable(reason: "未在 /Applications 或 ~/Applications 找到可读取版本的 App bundle"),
                repositoryVersion: "2.0"
            )
        )

        let installed = PackageInstalledVersionPresentation.make(for: package)
        let repository = PackageVersionTablePresentation.make(for: package, isLibrary: false)

        XCTAssertEqual(PackageUpdateListClassifier.groupKind(for: package), .selfUpdatingAttention)
        XCTAssertEqual(installed.versionText, "1.9")
        XCTAssertEqual(installed.sourceLabel, "未读到 App 实际版本，暂用 Homebrew 记录")
        XCTAssertEqual(repository.differenceLabel, "未读到 App 实际版本")
        XCTAssertTrue(repository.helpText.contains("降级使用 Homebrew 记录"))
        XCTAssertFalse(repository.visibleText.contains("可升级"))
    }

    func testGreedySyncScopeOnlyAllowsAutoUpdatingCasksAndUsesExplicitArguments() {
        let chrome = BrewPackage(
            name: "google-chrome",
            desc: "Google Chrome",
            installedVersions: ["145.0.1"],
            currentVersion: "150.0.3",
            isPinned: false,
            isLeaf: true,
            type: .cask,
            autoUpdates: true,
            installedSizeBytes: nil,
            appArtifactNames: ["Google Chrome.app"]
        )
        let node = BrewPackage(
            name: "node",
            desc: nil,
            installedVersions: ["24.0.0"],
            currentVersion: "24.1.0",
            isPinned: false,
            isLeaf: true,
            type: .formula,
            autoUpdates: false,
            installedSizeBytes: nil,
            appArtifactNames: []
        )

        XCTAssertTrue(PackageGreedySyncScope.isEligible(chrome))
        XCTAssertEqual(PackageGreedySyncScope.upgradeArguments(for: chrome), ["--cask", "--greedy", "google-chrome"])
        XCTAssertFalse(PackageGreedySyncScope.isEligible(node))
        XCTAssertNil(PackageGreedySyncScope.upgradeArguments(for: node))
        XCTAssertEqual(PackageUpgradeScope.ordinaryUpgradeCandidates(in: [chrome, node]).map(\.name), ["node"])
    }

    func testGreedySyncConfirmationExplainsTruthSourcesAndOverwriteRisk() {
        let edge = BrewPackage(
            name: "microsoft-edge",
            desc: "Microsoft Edge",
            installedVersions: ["145.0.1"],
            currentVersion: "150.0.3",
            isPinned: false,
            isLeaf: true,
            type: .cask,
            autoUpdates: true,
            installedSizeBytes: nil,
            appArtifactNames: ["Microsoft Edge.app"],
            caskVersionTruth: CaskVersionTruth.make(
                homebrewReceiptVersion: "145.0.1",
                appBundleReadResult: .found(shortVersion: "150.0.2", buildVersion: "300", bundlePath: "/Applications/Microsoft Edge.app"),
                repositoryVersion: "150.0.3"
            )
        )

        let title = PackageGreedySyncConfirmation.title(for: edge)
        let message = PackageGreedySyncConfirmation.message(for: edge)

        XCTAssertEqual(title, "确认贪婪同步 microsoft-edge?")
        XCTAssertTrue(message.contains("当前 App 版本：150.0.2"))
        XCTAssertTrue(message.contains("Homebrew 记录版本：145.0.1"))
        XCTAssertTrue(message.contains("Homebrew 仓库版本：150.0.3"))
        XCTAssertTrue(message.contains("brew upgrade --cask --greedy microsoft-edge"))
        XCTAssertTrue(message.contains("重新下载并覆盖安装"))
        XCTAssertTrue(message.contains("App 可能已经由内部更新器更新"))
        XCTAssertTrue(message.contains("普通批量升级不会处理自更新 App"))
    }

    func testGreedySyncOperationSummariesStayDistinctFromOrdinaryUpgrade() {
        let edge = BrewPackage(
            name: "microsoft-edge",
            desc: "Microsoft Edge",
            installedVersions: ["145.0.1"],
            currentVersion: "150.0.3",
            isPinned: false,
            isLeaf: true,
            type: .cask,
            autoUpdates: true,
            installedSizeBytes: nil,
            appArtifactNames: ["Microsoft Edge.app"]
        )

        let running = BrewOperationPlanner.greedySyncProgressSummary(
            stage: .syncingCask,
            packages: [edge],
            startedAt: Date(),
            currentPackage: edge
        )
        let finished = BrewOperationPlanner.greedySyncFinished(
            startedAt: Date(),
            targetPackages: [edge],
            remainingOutdatedPackages: []
        )
        let failed = BrewOperationPlanner.failureSummary(
            kind: .greedySyncCask,
            startedAt: Date(),
            packages: [edge],
            error: BrewError.executionFailed(code: 1, message: "download failed")
        )
        let event = AppEventFactory.event(from: running)

        XCTAssertEqual(running.operationKind, .greedySyncCask)
        XCTAssertEqual(running.operationKind.displayName, "贪婪同步")
        XCTAssertTrue(running.summaryText.contains("贪婪同步"))
        XCTAssertEqual(event.title, "贪婪同步")
        XCTAssertEqual(event.operationKey, "homebrew.greedySyncCask")
        XCTAssertTrue(finished.summaryText.contains("贪婪同步完成"))
        XCTAssertTrue(finished.compactRecapText.contains("已贪婪同步"))
        XCTAssertFalse(finished.compactRecapText.contains("已升级"))
        XCTAssertTrue(failed.summaryText.contains("贪婪同步失败"))
        XCTAssertFalse(failed.summaryText.contains("升级失败"))
    }

    func testOrdinaryUpgradeScopeExcludesAutoUpdatingCasks() {
        let node = BrewPackage(
            name: "node",
            desc: nil,
            installedVersions: ["24.0.0"],
            currentVersion: "24.1.0",
            isPinned: false,
            isLeaf: false,
            type: .formula,
            autoUpdates: false,
            installedSizeBytes: nil,
            appArtifactNames: []
        )
        let chrome = BrewPackage(
            name: "google-chrome",
            desc: "Google Chrome",
            installedVersions: ["145.0.1"],
            currentVersion: "150.0.3",
            isPinned: false,
            isLeaf: true,
            type: .cask,
            autoUpdates: true,
            installedSizeBytes: nil,
            appArtifactNames: ["Google Chrome.app"]
        )
        let vlc = BrewPackage(
            name: "vlc",
            desc: "VLC",
            installedVersions: ["3.0.20"],
            currentVersion: "3.0.21",
            isPinned: false,
            isLeaf: true,
            type: .cask,
            autoUpdates: false,
            installedSizeBytes: nil,
            appArtifactNames: ["VLC.app"]
        )

        let candidates = [node, chrome, vlc]
        let ordinary = PackageUpgradeScope.ordinaryUpgradeCandidates(in: candidates)
        let observed = PackageUpgradeScope.autoUpdatingObservationCandidates(in: candidates)
        let argumentGroups = PackageUpgradeScope.upgradeArgumentGroups(for: candidates)

        XCTAssertEqual(ordinary.map(\.name), ["node", "vlc"])
        XCTAssertEqual(observed.map(\.name), ["google-chrome"])
        XCTAssertEqual(argumentGroups, [["node"], ["--cask", "vlc"]])
    }

    func testHomebrewTimeoutErrorIsClassifiedAsNetworkReliabilityIssue() {
        let error = BrewError.timedOut(command: "brew outdated --json=v2", seconds: 90)
        let issue = BrewReliabilityDiagnostics.diagnose(error: error)

        XCTAssertTrue(error.localizedDescription.contains("执行超时"))
        XCTAssertEqual(issue.kind, .network)
        XCTAssertTrue(issue.impact.contains("更新仓库") || issue.impact.contains("读取远端元数据"))
    }

    func testBrewCommandDisplayCommandIncludesArgumentsForUpgradeDiagnostics() {
        XCTAssertEqual(BrewCommand.upgrade(["node", "deno"]).displayCommand, "brew upgrade node deno")
        XCTAssertEqual(BrewCommand.upgrade(["--cask", "vlc"]).displayCommand, "brew upgrade --cask vlc")
    }

    func testPackageStateBadgeGeneration() {
        let package = BrewPackage(
            name: "sample-app",
            desc: "App",
            installedVersions: ["1.0"],
            currentVersion: "2.0",
            isPinned: false,
            isLeaf: true,
            type: .cask,
            autoUpdates: true,
            installedSizeBytes: nil,
            appArtifactNames: []
        )

        let badgeKinds = Set(PackageStateBadgeFactory.badges(for: package, isLibrary: true).map(\.kind))

        XCTAssertTrue(badgeKinds.contains("leaf"))
        XCTAssertTrue(badgeKinds.contains("auto-updating-version"))
        XCTAssertTrue(badgeKinds.contains("size-unknown"))
    }

    func testCaskVersionIdentityIgnoresCommaSuffixForRepoDiffComparison() {
        let package = BrewPackage(
            name: "microsoft-edge",
            desc: "Microsoft Edge",
            installedVersions: ["148.0.3967.96"],
            currentVersion: "148.0.3967.96,207765a9-3991-4576-80dd-92c5dd9daac0",
            isPinned: false,
            isLeaf: true,
            type: .cask,
            autoUpdates: true,
            installedSizeBytes: nil,
            appArtifactNames: ["Microsoft Edge.app"]
        )

        XCTAssertEqual(package.versionDifferenceKind, .caskMetadata)
        XCTAssertFalse(package.hasRepoDiff)
        XCTAssertEqual(package.currentVersionDisplay, "148.0.3967.96")
        XCTAssertEqual(package.currentVersionIdentity.rawVersion, "148.0.3967.96,207765a9-3991-4576-80dd-92c5dd9daac0")
        XCTAssertEqual(package.currentVersionIdentity.caskMetadata, "207765a9-3991-4576-80dd-92c5dd9daac0")
        XCTAssertFalse(PackageStateDescriptor.contains(.repoDiff, package: package, isLibrary: true))
        XCTAssertFalse(PackageStateBadgeFactory.badges(for: package, isLibrary: true).contains { $0.kind == "repo-diff" })
        XCTAssertTrue(PackageStateBadgeFactory.badges(for: package, isLibrary: true).contains { $0.kind == "cask-metadata" })
    }

    func testFormulaRevisionDifferenceIsClassifiedSeparatelyFromOutdatedCandidate() {
        let package = BrewPackage(
            name: "yt-dlp",
            desc: nil,
            installedVersions: ["2026.3.17_2"],
            currentVersion: "2026.3.17",
            isPinned: false,
            isLeaf: true,
            type: .formula,
            autoUpdates: false,
            installedSizeBytes: 1024,
            appArtifactNames: []
        )

        XCTAssertEqual(package.installedVersionIdentities.first?.comparableVersion, "2026.3.17")
        XCTAssertEqual(package.installedVersionIdentities.first?.formulaRevision, "2")
        XCTAssertEqual(package.versionDifferenceKind, .formulaRevision)
        XCTAssertTrue(PackageStateDescriptor.contains(.repoDiff, package: package, isLibrary: true))
        XCTAssertTrue(PackageStateBadgeFactory.badges(for: package, isLibrary: true).contains { $0.kind == "formula-revision" && $0.title == "Formula revision 差异" })
        XCTAssertFalse(PackageStateBadgeFactory.badges(for: package, isLibrary: true).contains { $0.title == "可升级" })
        XCTAssertTrue(PackageStateBadgeFactory.badges(for: package, isLibrary: false).contains { $0.kind == "outdated-candidate" && $0.title == "可升级" })
    }

    func testFormulaVersionIdentityKeepsCommaVersionAsUnknownRawDifference() {
        let package = BrewPackage(
            name: "sample-formula",
            desc: nil,
            installedVersions: ["1.0,build1"],
            currentVersion: "1.0,build2",
            isPinned: false,
            isLeaf: true,
            type: .formula,
            autoUpdates: false,
            installedSizeBytes: nil,
            appArtifactNames: []
        )

        XCTAssertEqual(package.versionDisplay, "1.0,build1")
        XCTAssertEqual(package.currentVersionDisplay, "1.0,build2")
        XCTAssertEqual(package.versionDifferenceKind, .unknownRawDifference)
    }

    func testVersionTablePresentationExplainsCaskMetadataWithoutUpgradeImplication() {
        let package = BrewPackage(
            name: "microsoft-edge",
            desc: "Microsoft Edge",
            installedVersions: ["148.0.3967.96"],
            currentVersion: "148.0.3967.96,207765a9-3991-4576-80dd-92c5dd9daac0",
            isPinned: false,
            isLeaf: true,
            type: .cask,
            autoUpdates: true,
            installedSizeBytes: nil,
            appArtifactNames: ["Microsoft Edge.app"]
        )

        let presentation = PackageVersionTablePresentation.make(for: package, isLibrary: true)

        XCTAssertEqual(presentation.versionText, "148.0.3967.96")
        XCTAssertEqual(presentation.differenceLabel, "同主版本，Cask 元数据差异")
        XCTAssertEqual(presentation.visibleText, "148.0.3967.96（同主版本，Cask 元数据差异）")
        XCTAssertFalse(presentation.visibleText.contains("可升级"))
        XCTAssertTrue(presentation.helpText.contains("207765a9-3991-4576-80dd-92c5dd9daac0"))
    }

    func testVersionTablePresentationExplainsFormulaRevisionDifferenceInline() {
        let package = BrewPackage(
            name: "yt-dlp",
            desc: nil,
            installedVersions: ["2026.3.17_2"],
            currentVersion: "2026.3.17",
            isPinned: false,
            isLeaf: true,
            type: .formula,
            autoUpdates: false,
            installedSizeBytes: 1024,
            appArtifactNames: []
        )

        let libraryPresentation = PackageVersionTablePresentation.make(for: package, isLibrary: true)
        let updatePresentation = PackageVersionTablePresentation.make(for: package, isLibrary: false)

        XCTAssertEqual(libraryPresentation.visibleText, "2026.3.17（同主版本，revision 差异）")
        XCTAssertFalse(libraryPresentation.visibleText.contains("可升级"))
        XCTAssertTrue(libraryPresentation.helpText.contains("本机原始版本：2026.3.17_2"))
        XCTAssertEqual(updatePresentation.visibleText, "2026.3.17（可升级）")
    }

    func testVersionTablePresentationKeepsUnknownRawDiffAndAutoUpdatingCaskDistinct() {
        let rawDiff = BrewPackage(
            name: "sample-formula",
            desc: nil,
            installedVersions: ["1.0,build1"],
            currentVersion: "1.0,build2",
            isPinned: false,
            isLeaf: true,
            type: .formula,
            autoUpdates: false,
            installedSizeBytes: nil,
            appArtifactNames: []
        )
        let autoUpdating = BrewPackage(
            name: "sample-app",
            desc: nil,
            installedVersions: ["1.0"],
            currentVersion: "1.1",
            isPinned: false,
            isLeaf: true,
            type: .cask,
            autoUpdates: true,
            installedSizeBytes: nil,
            appArtifactNames: ["Sample.app"]
        )

        XCTAssertEqual(
            PackageVersionTablePresentation.make(for: rawDiff, isLibrary: true).visibleText,
            "1.0,build2（版本差异待确认）"
        )
        XCTAssertEqual(
            PackageVersionTablePresentation.make(for: autoUpdating, isLibrary: true).visibleText,
            "1.1（自更新 App 差异）"
        )
    }

    func testLibrarySummaryAndFilterUseSameSizeUnknownSource() {
        let unknownSizePackage = makePackage(name: "git", installedVersion: "2.0", currentVersion: "2.1")
        let knownSizePackage = makePackage(
            name: "wget",
            installedVersion: "1.0",
            currentVersion: "1.1",
            installedSizeBytes: 2048
        )
        let packages = [unknownSizePackage, knownSizePackage]

        let summary = LibrarySummary.make(from: packages)
        let filtered = packages.filter {
            PackageStateDescriptor.contains(.sizeUnknown, package: $0, isLibrary: true)
        }

        XCTAssertEqual(summary.sizeUnknownCount, filtered.count)
        XCTAssertEqual(filtered.map(\.name), ["git"])
    }

    func testPackageStateBadgesDeduplicateAndKeepStableOrder() {
        let package = BrewPackage(
            name: "sample-app",
            desc: "App",
            installedVersions: ["1.0"],
            currentVersion: "2.0",
            isPinned: true,
            isLeaf: true,
            type: .cask,
            autoUpdates: true,
            installedSizeBytes: nil,
            appArtifactNames: []
        )

        let badges = PackageStateBadgeFactory.badges(for: package, isLibrary: true)
        let kinds = badges.map(\.kind)

        XCTAssertEqual(kinds, ["leaf", "auto-updating-version", "size-unknown", "pinned"])
        XCTAssertEqual(kinds.count, Set(kinds).count)
        XCTAssertFalse(userVisibleText(in: badges).containsUserFacingEnglishStateTerms)
    }

    func testDashboardRiskSummaryPresentationCompactsAndExpandsItems() {
        let items = [
            makeDashboardItem(id: "a", severity: .critical),
            makeDashboardItem(id: "b", severity: .warning),
            makeDashboardItem(id: "c", severity: .attention)
        ]

        let compact = DashboardRiskSummaryPresentation(items: items, isExpanded: false, compactLimit: 2)
        let expanded = DashboardRiskSummaryPresentation(items: items, isExpanded: true, compactLimit: 2)

        XCTAssertEqual(compact.visibleItems.map(\.id), ["a", "b"])
        XCTAssertEqual(compact.hiddenCount, 1)
        XCTAssertEqual(expanded.visibleItems.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(expanded.hiddenCount, 0)
    }

    func testPackageFilterVisibilitySummaryCountsEffectiveLibraryFilters() {
        let summary = PackageFilterVisibilitySummary.make(
            type: .cask,
            showPinnedOnly: true,
            showLeavesOnly: true,
            packageStateFilter: .repoDiff,
            isLibrary: true
        )

        XCTAssertEqual(summary.count, 4)
        XCTAssertEqual(summary.menuTitle, "筛选 4")
        XCTAssertEqual(summary.chips, ["Cask", "已锁定"])
        XCTAssertEqual(summary.overflowCount, 2)
    }

    func testPackageFilterVisibilitySummaryIgnoresLibraryOnlyFiltersOutsideLibrary() {
        let summary = PackageFilterVisibilitySummary.make(
            type: .formula,
            showPinnedOnly: false,
            showLeavesOnly: true,
            packageStateFilter: .leaf,
            isLibrary: false
        )

        XCTAssertEqual(summary.titles, ["Formula"])
        XCTAssertEqual(summary.menuTitle, "筛选 1")
    }

    func testDashboardLibraryRiskItemsDoNotExposeEnglishStateTerms() {
        let packages = [
            BrewPackage(
                name: "sample-app",
                desc: "App",
                installedVersions: ["1.0"],
                currentVersion: "2.0",
                isPinned: false,
                isLeaf: true,
                type: .cask,
                autoUpdates: true,
                installedSizeBytes: nil,
                appArtifactNames: []
            )
        ]
        let summary = LibrarySummary.make(from: packages)
        let items = DashboardHealthSummary.make(
            brewStatus: .upToDate,
            outdatedPackages: [],
            operationSummary: nil,
            runtimeSnapshots: [],
            librarySummary: summary
        ).items

        XCTAssertFalse(userVisibleText(in: items).containsUserFacingEnglishStateTerms)
        XCTAssertTrue(items.contains { $0.title.contains("叶子包") && $0.actionTitle == "查看叶子包" })
    }

    func testPackageFilterTitlesDoNotExposeEnglishStateTerms() {
        let titles = PackageStateFilterKey.allCases.map(\.title)
        let summary = PackageFilterVisibilitySummary.make(
            type: nil,
            showPinnedOnly: false,
            showLeavesOnly: true,
            packageStateFilter: .sizeUnknown,
            isLibrary: true
        )

        XCTAssertFalse(userVisibleText(in: titles + summary.titles).containsUserFacingEnglishStateTerms)
        XCTAssertTrue(summary.titles.contains("酒窖大小未知"))
    }

    func testRuntimePATHPolicyCatalogKeepsMinimalTrustedDefaultAndCoversStrategies() {
        let snapshot = makeNodeSnapshot(issues: [])
        let policyKinds = Set(snapshot.pathPolicyOptions.map(\.kind))

        XCTAssertEqual(snapshot.pathPolicy.kind, .minimalTrusted)
        XCTAssertTrue(policyKinds.contains(.minimalTrusted))
        XCTAssertTrue(policyKinds.contains(.mirrorShell))
        XCTAssertTrue(policyKinds.contains(.customExpert))
        XCTAssertTrue(policyKinds.contains(.observeOnly))
        XCTAssertTrue(snapshot.pathPolicy.summary.contains("不完整复制登录 Shell"))
    }

    func testRuntimeTrustedPathUnionCombinesNodeAndPythonTrustedBins() {
        let node = makeNodeSnapshot(issues: [])
        let python = makePythonSnapshot(issues: [])

        let union = RuntimeTrustedPathUnion(snapshots: [python, node])

        XCTAssertTrue(union.displayEntries.contains("/opt/homebrew/bin"))
        XCTAssertTrue(union.displayEntries.contains("/opt/homebrew/sbin"))
        XCTAssertTrue(union.displayEntries.contains("$HOME/.npm-global/bin"))
        XCTAssertTrue(union.displayEntries.contains("$HOME/.local/bin"))
        XCTAssertEqual(union.displayEntries.count, Set(union.displayEntries).count)
        XCTAssertEqual(union.includedRuntimeKinds, [.node, .python])
        XCTAssertTrue(union.processPathValue.contains("\(NSHomeDirectory())/.npm-global/bin"))
        XCTAssertTrue(union.processPathValue.contains("\(NSHomeDirectory())/.local/bin"))
        XCTAssertTrue(union.repairHistoryDetail.contains("全局共享"))
    }

    func testRuntimeGovernanceSessionCommandUsesUnionInsteadOfSingleSnapshotPath() {
        let node = makeNodeSnapshot(issues: [])
        let python = makePythonSnapshot(issues: [])
        let union = RuntimeTrustedPathUnion(snapshots: [node, python])

        XCTAssertNotNil(node.currentSessionValidationCommand)
        XCTAssertNil(node.governanceSourceCommand)
        XCTAssertNotEqual(union.exportCommand, node.currentSessionValidationCommand)
        XCTAssertTrue(union.exportCommand?.contains("$HOME/.npm-global/bin") == true)
        XCTAssertTrue(union.exportCommand?.contains("$HOME/.local/bin") == true)
    }

    func testRuntimeLatestCheckStateExplainsRegistryOutcomes() {
        let checkedAt = Date(timeIntervalSince1970: 1_717_398_000)
        let notChecked = RuntimeLatestCheckState.notChecked(source: "pipx metadata")
        let failed = RuntimeLatestCheckState.failed(reason: "代理连接失败", source: "npm registry", checkedAt: checkedAt)
        let missing = RuntimeLatestCheckState.missingLatest(source: "npm registry", checkedAt: checkedAt)
        let current = RuntimeLatestCheckState.upToDate(version: "1.2.3", source: "npm registry", checkedAt: checkedAt)
        let outdated = RuntimeLatestCheckState.outdated(current: "1.2.3", latest: "1.3.0", source: "npm registry", checkedAt: checkedAt)

        XCTAssertEqual(notChecked.displayText, "未查询 registry")
        XCTAssertTrue(notChecked.helpText.contains("尚未执行 registry 查询"))
        XCTAssertEqual(failed.displayText, "查询失败")
        XCTAssertTrue(failed.helpText.contains("代理连接失败"))
        XCTAssertEqual(missing.displayText, "没有 latest 字段")
        XCTAssertTrue(missing.helpText.contains("registry 查询成功"))
        XCTAssertEqual(current.displayText, "已是最新版 1.2.3")
        XCTAssertFalse(current.isOutdated)
        XCTAssertEqual(outdated.latestVersion, "1.3.0")
        XCTAssertTrue(outdated.isOutdated)
        XCTAssertTrue(outdated.helpText.contains("当前版本 1.2.3"))
    }

    func testRuntimeGlobalToolsSummaryAggregatesLatestCheckState() {
        let checkedAt = Date(timeIntervalSince1970: 1_717_398_000)
        let summary = RuntimeGlobalToolsDashboardSummary.make(snapshots: [
            makeNodeSnapshot(
                issues: [],
                toolEntries: [
                    makeRuntimeTool(
                        name: "typescript",
                        latestCheckState: .outdated(current: "5.0.0", latest: "5.1.0", source: "npm registry", checkedAt: checkedAt)
                    ),
                    makeRuntimeTool(
                        name: "eslint",
                        latestCheckState: .failed(reason: "代理连接失败", source: "npm registry", checkedAt: checkedAt.addingTimeInterval(60))
                    )
                ]
            ),
            makePythonSnapshot(
                issues: [],
                toolEntries: [
                    makeRuntimeTool(
                        name: "ruff",
                        latestCheckState: .notChecked(source: "uv tool metadata")
                    )
                ]
            )
        ], referenceDate: checkedAt.addingTimeInterval(120))

        XCTAssertEqual(summary.toolCount, 3)
        XCTAssertEqual(summary.outdatedCount, 1)
        XCTAssertEqual(summary.latestCheckFailedCount, 1)
        XCTAssertEqual(summary.notCheckedCount, 1)
        XCTAssertEqual(summary.sources, ["npm registry", "uv tool metadata"])
        XCTAssertEqual(summary.latestCheckedAt, checkedAt.addingTimeInterval(60))
        XCTAssertEqual(summary.dashboardSeverity, .warning)
        XCTAssertEqual(summary.primaryAttentionItem?.toolName, "typescript")
        XCTAssertEqual(summary.primaryAttentionItem?.statusKind, .outdated)
        XCTAssertEqual(summary.dashboardValue, "typescript 可更新")
        XCTAssertTrue(summary.actionItemTitle.contains("typescript 可更新"))
        XCTAssertTrue(summary.dashboardDetail.contains("来源 npm registry, uv tool metadata"))
        XCTAssertTrue(summary.dashboardDetail.contains("当前 5.0.0，latest 5.1.0"))
        XCTAssertTrue(summary.reportLines.joined(separator: "\n").contains("not Homebrew outdated candidates"))
    }

    func testRuntimeGlobalToolsSummaryMarksStaleOutdatedAttentionForRecheck() {
        let checkedAt = Date(timeIntervalSince1970: 1_717_398_000)
        let referenceDate = checkedAt.addingTimeInterval(RuntimeGlobalToolAttentionItem.staleInterval + 60)
        let summary = RuntimeGlobalToolsDashboardSummary.make(
            snapshots: [
                makeNodeSnapshot(
                    issues: [],
                    toolEntries: [
                        makeRuntimeTool(
                            name: "openclaw",
                            latestCheckState: .outdated(current: "2026.6.1", latest: "2026.6.2", source: "npm registry", checkedAt: checkedAt)
                        ),
                        makeRuntimeTool(
                            name: "playwright",
                            latestCheckState: .upToDate(version: "1.60.0", source: "npm registry", checkedAt: checkedAt)
                        )
                    ]
                )
            ],
            referenceDate: referenceDate
        )

        XCTAssertEqual(summary.primaryAttentionItem?.toolName, "openclaw")
        XCTAssertEqual(summary.primaryAttentionItem?.displayStatusText, "上次发现可更新，待复核")
        XCTAssertEqual(summary.dashboardValue, "上次发现 openclaw 可更新，待复核")
        XCTAssertTrue(summary.actionItemDetail.contains("超过 24 小时"))
    }

    func testRuntimeGlobalToolStatusGroupsExposeConcreteToolNames() {
        let checkedAt = Date(timeIntervalSince1970: 1_717_398_000)
        let groups = RuntimeGlobalToolStatusGroup.make(packages: [
            makeRuntimeTool(name: "openclaw", latestCheckState: .outdated(current: "2026.6.1", latest: "2026.6.2", source: "npm registry", checkedAt: checkedAt)),
            makeRuntimeTool(name: "playwright", latestCheckState: .failed(reason: "getaddrinfo ENOTFOUND registry.npmjs.org", source: "npm registry", checkedAt: checkedAt)),
            makeRuntimeTool(name: "ruff", latestCheckState: .notChecked(source: "uv tool metadata")),
            makeRuntimeTool(name: "pipx-tool", latestCheckState: .missingLatest(source: "pipx metadata", checkedAt: checkedAt)),
            makeRuntimeTool(name: "typescript", latestCheckState: .upToDate(version: "5.1.0", source: "npm registry", checkedAt: checkedAt))
        ])

        XCTAssertEqual(groups.map(\.statusKind), [.outdated, .failed, .notChecked, .missingLatest, .upToDate])
        XCTAssertEqual(groups.first(where: { $0.statusKind == .outdated })?.summaryText, "openclaw")
        XCTAssertEqual(groups.first(where: { $0.statusKind == .failed })?.summaryText, "playwright")
        XCTAssertEqual(groups.first(where: { $0.statusKind == .upToDate })?.summaryText, "typescript")
    }

    func testDashboardSummaryRoutesRuntimeGlobalToolsToRuntimeDomainOnly() throws {
        let checkedAt = Date(timeIntervalSince1970: 1_717_398_000)
        let runtimeSummary = RuntimeGlobalToolsDashboardSummary.make(snapshots: [
            makeNodeSnapshot(
                issues: [],
                toolEntries: [
                    makeRuntimeTool(
                        name: "typescript",
                        latestCheckState: .outdated(current: "5.0.0", latest: "5.1.0", source: "npm registry", checkedAt: checkedAt)
                    )
                ]
            )
        ], referenceDate: checkedAt.addingTimeInterval(120))

        let summary = DashboardHealthSummary.make(
            brewStatus: .upToDate,
            outdatedPackages: [],
            operationSummary: nil,
            runtimeSnapshots: [],
            runtimeGlobalToolsSummary: runtimeSummary,
            librarySummary: LibrarySummary(repoDiffCount: 0, autoUpdatesCount: 0, sizeUnknownCount: 0, leafCount: 0),
            runtimeScanState: .succeeded
        )

        XCTAssertEqual(summary.headline, "Homebrew 无可升级包，仍有环境/清点事项需关注")
        XCTAssertTrue(summary.domains.contains { domain in
            domain.id == "homebrew" && domain.value == "无普通可升级"
        })
        let runtimeDomain = try XCTUnwrap(summary.domains.first { $0.id == "runtime" })
        XCTAssertEqual(runtimeDomain.value, "typescript 可更新")
        XCTAssertTrue(runtimeDomain.detail.contains("全局工具 1 个"), runtimeDomain.detail)
        XCTAssertTrue(runtimeDomain.detail.contains("可更新 1"), runtimeDomain.detail)
        XCTAssertTrue(runtimeDomain.detail.contains("typescript"), runtimeDomain.detail)

        let runtimeItem = try XCTUnwrap(summary.items.first { $0.id == "runtime.global-tools" })
        XCTAssertEqual(runtimeItem.action, .showRuntimeGlobalTool("node:typescript"))
        XCTAssertTrue(runtimeItem.title.contains("typescript 可更新"), runtimeItem.title)
        XCTAssertTrue(runtimeItem.detail.contains("不进入 Homebrew 普通升级"), runtimeItem.detail)
        XCTAssertFalse(summary.items.contains { $0.id == "brew.outdated" })
    }

    func testRuntimeRepairHistoryRecorderSkipsCopyOnlyActions() {
        let copied = RuntimeRepairHistoryRecorder.entry(
            runtimeKind: .node,
            actionID: "node.copy-shell-patch",
            title: "Shell PATH 补丁已复制",
            detail: "复制命令不会被标记为已修复。",
            riskLevel: .readOnly,
            executionResult: .copiedCommand,
            verificationResult: .pendingManualAction,
            rollbackCommandOrNote: nil
        )
        let executed = RuntimeRepairHistoryRecorder.entry(
            runtimeKind: .node,
            actionID: "node.repair-npm-prefix",
            title: "npm prefix 已修复",
            detail: "已把 npm 全局 prefix 调整到用户目录。",
            riskLevel: .userPersistent,
            executionResult: .succeeded,
            verificationResult: .passed,
            rollbackCommandOrNote: "npm config delete prefix"
        )

        XCTAssertNil(copied)
        XCTAssertEqual(executed?.actionID, "node.repair-npm-prefix")
        XCTAssertEqual(executed?.rollbackCommandOrNote, "npm config delete prefix")
    }

    func testRuntimeReportComposerIncludesPolicyEventsAndRepairHistory() {
        let snapshot = makeNodeSnapshot(issues: [])
        let event = RuntimeDiagnosticEvent(
            kind: .commandCopied,
            title: "GUI PATH 写入命令已复制",
            detail: "复制命令不会被标记为已修复。",
            relatedActionID: "node.persist-gui-path",
            verificationStatus: .pendingManualAction
        )
        let history = RuntimeRepairHistoryEntry(
            id: UUID(),
            date: Date(),
            runtimeKind: .node,
            actionID: "node.align-current-session",
            title: "当前会话 PATH 已对齐",
            detail: "已按最小可信策略更新 Cellar 当前进程 PATH。",
            riskLevel: .currentSession,
            executionResult: .succeeded,
            verificationResult: .passed,
            rollbackCommandOrNote: "重新启动 Cellar"
        )
        let outdatedProvenance = HomebrewSnapshotProvenance.failed(
            kind: .outdated,
            source: .brewUpdateThenOutdated,
            error: BrewError.executionFailed(code: 1, message: "Failed to connect"),
            previous: .succeeded(kind: .outdated, source: .brewOutdated, capturedAt: Date(timeIntervalSince1970: 100)),
            capturedAt: Date(timeIntervalSince1970: 200)
        )
        let libraryProvenance = HomebrewSnapshotProvenance.succeeded(
            kind: .installedLibrary,
            source: .brewInstalledInfo,
            capturedAt: Date(timeIntervalSince1970: 300)
        )

        let report = RuntimeReportComposer.compose(
            baseReport: "# Base",
            snapshot: snapshot,
            events: [event],
            repairHistory: [history],
            outdatedSnapshotProvenance: outdatedProvenance,
            installedSnapshotProvenance: libraryProvenance
        )

        XCTAssertTrue(report.contains("## Runtime PATH Policy"))
        XCTAssertTrue(report.contains("Minimal Trusted PATH"))
        XCTAssertTrue(report.contains("## Homebrew Snapshot Provenance"))
        XCTAssertTrue(report.contains("brew update + brew outdated"))
        XCTAssertTrue(report.contains("基于上次成功快照"))
        XCTAssertTrue(report.contains("brew info --json=v2 --installed"))
        XCTAssertTrue(report.contains("## Runtime Global Tools Dashboard Summary"))
        XCTAssertTrue(report.contains("not Homebrew outdated candidates"))
        XCTAssertTrue(report.contains("## Runtime Events"))
        XCTAssertTrue(report.contains("GUI PATH 写入命令已复制"))
        XCTAssertTrue(report.contains("## Runtime Repair History"))
        XCTAssertTrue(report.contains("node.align-current-session"))
    }

    private func makeNodeSnapshot(issues: [RuntimeIssue], toolEntries: [RuntimeToolEntry] = []) -> RuntimeSnapshot {
        RuntimeSnapshot(
            kind: .node,
            activeExecutable: RuntimeExecutableSnapshot(name: "Node", version: "v24.0.0", path: "/opt/homebrew/bin/node", provider: .homebrew),
            loginShellExecutable: RuntimeExecutableSnapshot(name: "Node", version: "v24.0.0", path: "/opt/homebrew/bin/node", provider: .homebrew),
            guiExecutable: RuntimeExecutableSnapshot(name: "Node", version: "v24.0.0", path: "/opt/homebrew/bin/node", provider: .homebrew),
            packageManagers: [
                RuntimePackageManagerSnapshot(
                    identifier: "npm",
                    displayName: "npm",
                    guiVersion: "10.0.0",
                    guiPath: "/opt/homebrew/bin/npm",
                    loginShellVersion: "10.0.0",
                    loginShellPath: "/opt/homebrew/bin/npm",
                    prefix: "/usr/local",
                    globalBinPath: "/usr/local/bin",
                    globalRootPath: "/usr/local/lib/node_modules",
                    shellToolCount: 0
                )
            ],
            pathSnapshot: RuntimePathSnapshot(guiEntries: ["/opt/homebrew/bin"], loginShellEntries: ["/opt/homebrew/bin"]),
            installations: [],
            toolEntries: toolEntries,
            issues: issues,
            pathPolicy: RuntimePATHPolicyCatalog.policy(.minimalTrusted, runtimeName: RuntimeKind.node.displayName),
            reportMarkdown: ""
        )
    }

    private func makePythonSnapshot(issues: [RuntimeIssue], toolEntries: [RuntimeToolEntry] = []) -> RuntimeSnapshot {
        RuntimeSnapshot(
            kind: .python,
            activeExecutable: RuntimeExecutableSnapshot(name: "Python", version: "Python 3.13.0", path: "/opt/homebrew/bin/python3", provider: .homebrew),
            loginShellExecutable: RuntimeExecutableSnapshot(name: "Python", version: "Python 3.13.0", path: "/opt/homebrew/bin/python3", provider: .homebrew),
            guiExecutable: RuntimeExecutableSnapshot(name: "Python", version: "Python 3.13.0", path: "/opt/homebrew/bin/python3", provider: .homebrew),
            packageManagers: [
                RuntimePackageManagerSnapshot(
                    identifier: "pipx",
                    displayName: "pipx",
                    guiVersion: "1.0.0",
                    guiPath: "\(NSHomeDirectory())/.local/bin/pipx",
                    loginShellVersion: "1.0.0",
                    loginShellPath: "\(NSHomeDirectory())/.local/bin/pipx",
                    prefix: "\(NSHomeDirectory())/.local",
                    globalBinPath: "\(NSHomeDirectory())/.local/bin",
                    globalRootPath: "\(NSHomeDirectory())/.local/pipx",
                    shellToolCount: 1
                )
            ],
            pathSnapshot: RuntimePathSnapshot(
                guiEntries: ["/opt/homebrew/bin"],
                loginShellEntries: ["/opt/homebrew/bin", "/opt/homebrew/sbin", "\(NSHomeDirectory())/.local/bin"]
            ),
            installations: [],
            toolEntries: toolEntries,
            issues: issues,
            pathPolicy: RuntimePATHPolicyCatalog.policy(.minimalTrusted, runtimeName: RuntimeKind.python.displayName),
            reportMarkdown: ""
        )
    }

    private func makePackage(
        name: String,
        installedVersion: String,
        currentVersion: String,
        installedSizeBytes: Int64? = nil
    ) -> BrewPackage {
        BrewPackage(
            name: name,
            desc: nil,
            installedVersions: [installedVersion],
            currentVersion: currentVersion,
            isPinned: false,
            isLeaf: true,
            type: .formula,
            autoUpdates: false,
            installedSizeBytes: installedSizeBytes,
            appArtifactNames: []
        )
    }

    private func makeRuntimeTool(
        name: String,
        latestCheckState: RuntimeLatestCheckState
    ) -> RuntimeToolEntry {
        RuntimeToolEntry(
            name: name,
            currentVersion: "1.0.0",
            latestCheckState: latestCheckState,
            binaries: [name],
            installLocation: "/tmp/\(name)",
            prefix: "/tmp",
            managedByCurrentRuntime: true,
            sourceLabel: "test metadata",
            shellPath: "/tmp/bin/\(name)",
            guiPath: "/tmp/bin/\(name)",
            isVisibleInShell: true,
            isVisibleInGUI: true,
            hasNameConflict: false,
            statusNote: "测试工具"
        )
    }

    private func userVisibleText(in badges: [PackageStateBadge]) -> String {
        badges
            .flatMap { [$0.title, $0.explanation] }
            .joined(separator: "\n")
    }

    private func userVisibleText(in items: [DashboardActionItem]) -> String {
        items
            .flatMap { [$0.source, $0.title, $0.detail, $0.actionTitle] }
            .joined(separator: "\n")
    }

    private func userVisibleText(in strings: [String]) -> String {
        strings.joined(separator: "\n")
    }

    private func makeDashboardItem(id: String, severity: DashboardSeverity) -> DashboardActionItem {
        DashboardActionItem(
            id: id,
            source: "测试",
            title: "风险 \(id)",
            detail: "测试风险项",
            severity: severity,
            actionTitle: "查看",
            action: .showUpdates
        )
    }
}

private extension String {
    var containsUserFacingEnglishStateTerms: Bool {
        ["Leaf", "Repo diff", "Auto-updates", "Size unknown"].contains { contains($0) }
    }
}
