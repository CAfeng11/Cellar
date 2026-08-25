import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

@MainActor
final class RuntimeDoctorViewModel: ObservableObject {
    @Published var currentRuntime: RuntimeKind = .node
    @Published var snapshot: RuntimeSnapshot?
    @Published private(set) var snapshotsByKind: [RuntimeKind: RuntimeSnapshot] = [:]
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var actionMessage: String?
    @Published var latestRuntimeEvent: RuntimeDiagnosticEvent?
    @Published private(set) var runtimeEvents: [RuntimeDiagnosticEvent] = []
    @Published private(set) var repairHistory: [RuntimeRepairHistoryEntry] = []
    @Published var activePackageActionID: String?
    @Published var uninstallCandidate: RuntimeGlobalPackage?
    @Published var pendingRepairPlan: RuntimeRepairPlan?
    @Published private(set) var focusedGlobalToolAttention: RuntimeGlobalToolAttentionItem?

    private var hasLoaded = false
    private var runtimeLogger: ((String, LogEntry.LogType, Bool) -> Void)?

    func installLogger(_ logger: @escaping (String, LogEntry.LogType, Bool) -> Void) {
        runtimeLogger = logger
    }

    private func log(_ message: String, type: LogEntry.LogType = .info, reveal: Bool = false) {
        runtimeLogger?(message, type, reveal)
    }

    private func publishRuntimeEvent(_ event: RuntimeDiagnosticEvent) {
        latestRuntimeEvent = event
        runtimeEvents.insert(event, at: 0)
        if runtimeEvents.count > 30 {
            runtimeEvents.removeLast(runtimeEvents.count - 30)
        }
        actionMessage = "\(event.title)：\(event.verificationStatus.displayName)"
    }

    private func publishCopiedEvent(title: String, detail: String, actionID: String?) {
        publishRuntimeEvent(RuntimeActionRunner.event(
            result: .copiedCommand,
            title: title,
            detail: detail,
            relatedActionID: actionID,
            verificationStatus: .pendingManualAction
        ))
    }

    private func verifyAfterAction(
        previousSnapshot: RuntimeSnapshot?,
        actionID: String?,
        verificationActionIDs: [String]? = nil,
        successTitle: String,
        successDetail: String? = nil,
        riskLevel: RuntimeDiagnosticActionRisk,
        rollbackCommandOrNote: String
    ) async {
        do {
            let newSnapshots = try await self.inspectAllRuntimes()
            self.snapshotsByKind = newSnapshots
            let kind = previousSnapshot?.kind ?? self.currentRuntime
            self.snapshot = newSnapshots[kind] ?? newSnapshots[self.currentRuntime]
            let scopedActionIDs = verificationActionIDs ?? actionID.map { [$0] } ?? []
            let status = RuntimeActionRunner.verificationStatus(
                before: previousSnapshot,
                after: self.snapshot,
                relatedActionIDs: scopedActionIDs
            )
            let detail = successDetail ?? (status == .passed
                ? "动作已执行，相关运行时问题已消失或降级。"
                : "动作已执行，但相关问题仍存在；请查看下一步建议或导出诊断报告。")
            let event = RuntimeActionRunner.event(
                result: .succeeded,
                title: successTitle,
                detail: detail,
                relatedActionID: actionID,
                verificationStatus: status
            )
            publishRuntimeEvent(event)
            recordRepairHistory(
                runtimeKind: kind,
                actionID: actionID,
                title: successTitle,
                detail: detail,
                riskLevel: riskLevel,
                executionResult: .succeeded,
                verificationResult: status,
                rollbackCommandOrNote: rollbackCommandOrNote
            )
            self.log("运行时验证结果：\(status.displayName)", type: status == .passed ? .success : .info)
        } catch {
            self.errorMessage = "动作后验证失败: \(error.localizedDescription)"
            let kind = previousSnapshot?.kind ?? self.currentRuntime
            let detail = "动作已执行，但重新扫描失败：\(error.localizedDescription)"
            publishRuntimeEvent(RuntimeActionRunner.event(
                result: .failed,
                title: successTitle,
                detail: detail,
                relatedActionID: actionID,
                verificationStatus: .failed
            ))
            recordRepairHistory(
                runtimeKind: kind,
                actionID: actionID,
                title: successTitle,
                detail: detail,
                riskLevel: riskLevel,
                executionResult: .failed,
                verificationResult: .failed,
                rollbackCommandOrNote: rollbackCommandOrNote
            )
            self.log("运行时动作后验证失败: \(error.localizedDescription)", type: .failure, reveal: true)
        }
    }

    private func recordRepairHistory(
        runtimeKind: RuntimeKind,
        actionID: String?,
        title: String,
        detail: String,
        riskLevel: RuntimeDiagnosticActionRisk,
        executionResult: RuntimeDiagnosticActionResult,
        verificationResult: RuntimeDiagnosticVerificationStatus,
        rollbackCommandOrNote: String
    ) {
        guard let entry = RuntimeRepairHistoryRecorder.entry(
            runtimeKind: runtimeKind,
            actionID: actionID,
            title: title,
            detail: detail,
            riskLevel: riskLevel,
            executionResult: executionResult,
            verificationResult: verificationResult,
            rollbackCommandOrNote: rollbackCommandOrNote
        ) else { return }
        repairHistory.insert(entry, at: 0)
        if repairHistory.count > 30 {
            repairHistory.removeLast(repairHistory.count - 30)
        }
    }

    func refreshIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        refresh()
    }

    func selectRuntime(_ kind: RuntimeKind) {
        guard currentRuntime != kind else { return }
        currentRuntime = kind
        snapshot = snapshotsByKind[kind]
        actionMessage = nil
        errorMessage = nil
        if snapshot == nil {
            refresh()
        }
    }

    func focusGlobalToolAttention(id: String) {
        let summary = RuntimeGlobalToolsDashboardSummary.make(snapshots: availableRuntimeSnapshots)
        let attention = summary.attentionItems.first { $0.id == id } ?? summary.primaryAttentionItem
        focusedGlobalToolAttention = attention
        if let attention {
            selectRuntime(attention.runtimeKind)
        }
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        let runtimeNames = RuntimeKind.allCases.map(\.displayName).joined(separator: " / ")
        log("运行时扫描：开始刷新 \(runtimeNames) / PATH 快照", type: .command, reveal: true)

        Task {
            do {
                let newSnapshots = try await self.inspectAllRuntimes()
                self.snapshotsByKind = newSnapshots
                self.snapshot = newSnapshots[self.currentRuntime]
                self.actionMessage = "诊断快照已更新"
                self.log("运行时扫描完成：Node / Python 总览已同步", type: .success)
            } catch {
                self.errorMessage = error.localizedDescription
                self.log("运行时扫描失败: \(error.localizedDescription)", type: .failure, reveal: true)
            }
            self.isLoading = false
        }
    }

    var dashboardSnapshots: [RuntimeSnapshot] {
        RuntimeKind.allCases.compactMap { snapshotsByKind[$0] }
    }

    var dashboardGlobalToolsSummary: RuntimeGlobalToolsDashboardSummary {
        RuntimeGlobalToolsDashboardSummary.make(snapshots: dashboardSnapshots)
    }

    var currentSessionTrustedPathUnion: RuntimeTrustedPathUnion {
        RuntimeTrustedPathUnion(snapshots: availableRuntimeSnapshots)
    }

    private var availableRuntimeSnapshots: [RuntimeSnapshot] {
        RuntimeKind.allCases.compactMap { kind in
            snapshotsByKind[kind] ?? (snapshot?.kind == kind ? snapshot : nil)
        }
    }

    private func inspectAllRuntimes() async throws -> [RuntimeKind: RuntimeSnapshot] {
        async let nodeSnapshot = RuntimeDoctorService.inspect(.node)
        async let pythonSnapshot = RuntimeDoctorService.inspect(.python)
        let node = try await nodeSnapshot
        let python = try await pythonSnapshot
        return [
            .node: node,
            .python: python
        ]
    }

    func exportReport(
        homebrewIssue: BrewReliabilityIssue? = nil,
        appEvents: [AppEvent] = [],
        operationSummary: BrewOperationSummary? = nil,
        outdatedSnapshotProvenance: HomebrewSnapshotProvenance? = nil,
        installedSnapshotProvenance: HomebrewSnapshotProvenance? = nil
    ) {
        guard let snapshot else { return }
        let runtimeGlobalToolsSummary = RuntimeGlobalToolsDashboardSummary.make(snapshots: availableRuntimeSnapshots)
        let report = RuntimeReportComposer.compose(
            baseReport: snapshot.reportMarkdown,
            snapshot: snapshot,
            events: runtimeEvents,
            repairHistory: repairHistory,
            homebrewIssue: homebrewIssue,
            appEvents: appEvents,
            operationSummary: operationSummary,
            outdatedSnapshotProvenance: outdatedSnapshotProvenance,
            installedSnapshotProvenance: installedSnapshotProvenance,
            runtimeGlobalToolsSummary: runtimeGlobalToolsSummary
        )
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Cellar-\(snapshot.kind.reportStem)-Report.md"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try report.write(to: url, atomically: true, encoding: .utf8)
                self.actionMessage = "诊断报告已导出到 \(url.lastPathComponent)"
                self.log("导出运行时报告到 \(url.path)", type: .command, reveal: true)
                self.log("运行时报告导出完成", type: .success)
            } catch {
                self.errorMessage = "导出失败: \(error.localizedDescription)"
                self.log("运行时报告导出失败: \(error.localizedDescription)", type: .failure, reveal: true)
            }
        }
    }

    func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        actionMessage = "已复制到剪贴板"
    }

    func adoptMinimalTrustedEnvironment() {
        guard let snapshot else {
            errorMessage = "还没有可用的运行时快照。"
            return
        }
        let trustedUnion = currentSessionTrustedPathUnion
        guard !trustedUnion.isEmpty else {
            errorMessage = "当前没有可用于接入的最小可信 union PATH。"
            return
        }
        log("运行时操作：按最小可信 union 策略对齐 Cellar 当前会话全局 PATH", type: .command, reveal: true)
        if let exportCommand = trustedUnion.exportCommand {
            log("$ \(exportCommand)", type: .command)
        }
        setenv("PATH", trustedUnion.processPathValue, 1)
        actionMessage = "已让 Cellar 当前会话接入最小可信 union PATH；\(trustedUnion.scopeDescription)"
        log("Cellar 当前会话已按最小可信 union 完成对齐；\(trustedUnion.scopeDescription)", type: .success)
        Task {
            await self.verifyAfterAction(
                previousSnapshot: snapshot,
                actionID: RuntimeTrustedPathUnion.currentSessionActionID,
                verificationActionIDs: trustedUnion.verificationActionIDs,
                successTitle: "当前会话 PATH 已对齐",
                successDetail: trustedUnion.repairHistoryDetail,
                riskLevel: .currentSession,
                rollbackCommandOrNote: trustedUnion.rollbackNote
            )
        }
    }

    func adoptFullShellMirror() {
        guard let snapshot else {
            errorMessage = "还没有可用的运行时快照。"
            return
        }
        guard !snapshot.loginPathEntries.isEmpty else {
            errorMessage = "当前没有可用于镜像的 Shell PATH。"
            return
        }
        let mirroredPath = snapshot.loginPathEntries.joined(separator: ":")
        log("运行时操作：镜像完整 Shell PATH（高级模式）", type: .command, reveal: true)
        if let command = snapshot.mirrorShellPathExportCommand {
            log("$ \(command)", type: .command)
        }
        setenv("PATH", mirroredPath, 1)
        actionMessage = "已让 Cellar 当前会话镜像完整 Shell PATH；这会同时影响 Node 与 Python 的可见性"
        log("Cellar 当前会话已镜像完整 Shell PATH；PATH 为当前进程全局共享", type: .success)
        Task {
            await self.verifyAfterAction(
                previousSnapshot: snapshot,
                actionID: "\(snapshot.kind.rawValue).mirror-shell-path",
                successTitle: "完整 Shell PATH 已镜像到当前会话",
                riskLevel: .highRiskManual,
                rollbackCommandOrNote: "重启 Cellar 即可回滚当前会话镜像；Cellar 不会静默写入 shell 配置。"
            )
        }
    }

    func copyShellPathCommand() {
        guard let command = snapshot?.persistentPathCommand else { return }
        copy(command)
        log("已复制 GUI 修复命令", type: .info)
        log("$ \(command)", type: .command)
        publishCopiedEvent(title: "GUI PATH 写入命令已复制", detail: "复制命令不会被标记为已修复；执行后请重新扫描验证。", actionID: snapshot.map { "\($0.kind.rawValue).persist-gui-path" })
    }

    func copyCurrentSessionValidationCommand() {
        let trustedUnion = currentSessionTrustedPathUnion
        guard let command = trustedUnion.exportCommand else { return }
        copy(command)
        log("已复制当前会话验证命令", type: .info)
        log("$ \(command)", type: .command)
        publishCopiedEvent(title: "当前会话 union PATH 验证命令已复制", detail: "命令尚未由 Cellar 执行；该 PATH 是 Cellar 当前会话全局共享状态，会同时服务 Node / Python。", actionID: RuntimeTrustedPathUnion.currentSessionActionID)
    }

    func copyShellPatchSnippet() {
        guard let snapshot else { return }
        copy(snapshot.shellPatchSnippet)
        log("已复制写入 shell 的持久化补丁", type: .info)
        for line in snapshot.shellPatchSnippet.split(separator: "\n") {
            log(String(line), type: .command)
        }
        publishCopiedEvent(title: "Shell PATH 补丁已复制", detail: "Shell 配置修改需要手动写入和确认，Cellar 不会静默改写。", actionID: "\(snapshot.kind.rawValue).copy-shell-patch")
    }

    func copyGuiRollbackCommand() {
        guard let snapshot else { return }
        copy(snapshot.guiRollbackCommand)
        log("已复制 GUI 回滚命令", type: .info)
        log("$ \(snapshot.guiRollbackCommand)", type: .command)
        publishCopiedEvent(title: "GUI PATH 回滚命令已复制", detail: "回滚命令需要用户手动执行。", actionID: "\(snapshot.kind.rawValue).rollback-gui-path")
    }

    func copyRepairPlanGuide() {
        guard let plan = pendingRepairPlan else { return }
        copy(([plan.summary] + plan.steps).joined(separator: "\n"))
        log("已复制运行时修复指引", type: .info)
        publishCopiedEvent(
            title: "运行时修复指引已复制",
            detail: "修复计划仅已复制，等待手动执行或确认自动修复。",
            actionID: snapshot.map { "\($0.kind.rawValue).repair-plan" }
        )
    }

    func copyGovernanceCommand() {
        let trustedUnion = currentSessionTrustedPathUnion
        guard let command = trustedUnion.exportCommand else { return }
        copy(command)
        log("已复制当前会话 union PATH 验证命令", type: .info)
        log("$ \(command)", type: .command)
        publishCopiedEvent(
            title: "治理区 union PATH 验证命令已复制",
            detail: "命令尚未由 Cellar 执行；该命令来自 RuntimeTrustedPathUnion，不回退到单运行时 PATH。",
            actionID: RuntimeTrustedPathUnion.currentSessionActionID
        )
    }

    func copyLegacyCleanupGuide() {
        guard let snapshot else { return }
        copy(snapshot.legacyCleanupCommandBlock)
        log("已复制 legacy 清理建议", type: .info)
        for line in snapshot.legacyCleanupCommandBlock.split(separator: "\n") where !line.isEmpty {
            log(String(line), type: .command)
        }
        publishCopiedEvent(
            title: "Legacy 清理建议已复制",
            detail: "清理建议仅已复制，Cellar 不会静默删除旧运行时。",
            actionID: "\(snapshot.kind.rawValue).copy-governance-guide"
        )
    }

    func persistShellEnvironment() {
        guard let previousSnapshot = snapshot, let command = previousSnapshot.persistentPathCommand else {
            errorMessage = "当前没有可持久化的 Shell PATH。"
            return
        }
        log("运行时操作：写入 GUI 会话 PATH", type: .command, reveal: true)
        log("$ \(command)", type: .command)
        Task {
            do {
                _ = try await RuntimeDoctorService.runLaunchctlSetenv(command: command)
                self.actionMessage = "已为当前用户会话写入 GUI PATH，对新启动的应用生效"
                self.log("GUI 会话 PATH 写入完成", type: .success)
                await self.verifyAfterAction(
                    previousSnapshot: previousSnapshot,
                    actionID: "\(previousSnapshot.kind.rawValue).persist-gui-path",
                    successTitle: "GUI PATH 已写入",
                    riskLevel: .userPersistent,
                    rollbackCommandOrNote: previousSnapshot.guiRollbackCommand
                )
            } catch {
                self.errorMessage = "持久化失败: \(error.localizedDescription)"
                self.log("GUI 会话 PATH 写入失败: \(error.localizedDescription)", type: .failure, reveal: true)
                let detail = error.localizedDescription
                self.publishRuntimeEvent(RuntimeActionRunner.event(
                    result: .failed,
                    title: "GUI PATH 写入失败",
                    detail: detail,
                    relatedActionID: "\(previousSnapshot.kind.rawValue).persist-gui-path",
                    verificationStatus: .failed
                ))
                self.recordRepairHistory(
                    runtimeKind: previousSnapshot.kind,
                    actionID: "\(previousSnapshot.kind.rawValue).persist-gui-path",
                    title: "GUI PATH 写入失败",
                    detail: detail,
                    riskLevel: .userPersistent,
                    executionResult: .failed,
                    verificationResult: .failed,
                    rollbackCommandOrNote: previousSnapshot.guiRollbackCommand
                )
            }
        }
    }

    func repairNpmPrefix() {
        guard let snapshot else {
            errorMessage = "还没有可用的运行时快照。"
            return
        }
        let npmPath = snapshot.activeNpmPath ?? snapshot.loginNpmPath
        guard let npmPath else {
            errorMessage = "当前没有可用的 npm，暂时无法修复 prefix。"
            return
        }
        let command = "\(npmPath) config set prefix \(snapshot.recommendedUserPrefixPath)"
        log("运行时操作：修复 npm 全局 prefix", type: .command, reveal: true)
        log("$ \(command)", type: .command)
        Task {
            do {
                try await RuntimeDoctorService.repairUserNpmPrefix(npmPath: npmPath, targetPrefix: snapshot.recommendedUserPrefixPath)
                self.actionMessage = "已把 npm 全局 prefix 调整到用户目录"
                self.log("npm 全局 prefix 已调整到 \(snapshot.recommendedUserPrefixPath)", type: .success)
                await self.verifyAfterAction(
                    previousSnapshot: snapshot,
                    actionID: "\(snapshot.kind.rawValue).repair-npm-prefix",
                    successTitle: "npm prefix 已修复",
                    riskLevel: .userPersistent,
                    rollbackCommandOrNote: "npm config delete prefix"
                )
            } catch {
                self.errorMessage = "prefix 修复失败: \(error.localizedDescription)"
                self.log("npm prefix 修复失败: \(error.localizedDescription)", type: .failure, reveal: true)
                let detail = error.localizedDescription
                self.publishRuntimeEvent(RuntimeActionRunner.event(
                    result: .failed,
                    title: "npm prefix 修复失败",
                    detail: detail,
                    relatedActionID: "\(snapshot.kind.rawValue).repair-npm-prefix",
                    verificationStatus: .failed
                ))
                self.recordRepairHistory(
                    runtimeKind: snapshot.kind,
                    actionID: "\(snapshot.kind.rawValue).repair-npm-prefix",
                    title: "npm prefix 修复失败",
                    detail: detail,
                    riskLevel: .userPersistent,
                    executionResult: .failed,
                    verificationResult: .failed,
                    rollbackCommandOrNote: "npm config delete prefix"
                )
            }
        }
    }

    func prepareRepairPlan() {
        guard let snapshot else {
            errorMessage = "还没有可用的运行时快照。"
            return
        }
        let steps = snapshot.fixSummary
        guard !steps.isEmpty else {
            actionMessage = "当前没有明显需要自动修复的低风险项。"
            return
        }
        log("已生成运行时修复指引", type: .info, reveal: true)
        pendingRepairPlan = RuntimeRepairPlan(
            summary: snapshot.kind == .python
                ? "以下是建议的 Python 修复指引。Cellar 只会自动处理当前会话级对齐；shell 配置与 conda / pyenv 相关动作默认只提供命令与回滚说明。"
                : "以下是建议的低风险修复指引。Shell 配置类动作默认只提供补丁和步骤，不会替你静默写入。",
            steps: snapshot.fixGuidanceLines.isEmpty ? steps : snapshot.fixGuidanceLines,
            canRunAutomatedFixes: snapshot.kind == .python
                ? snapshot.needsCurrentSessionAlignment
                : (snapshot.needsPersistentGuiAlignment || snapshot.needsNpmPrefixRepair)
        )
    }

    func runRepairPlan() {
        guard pendingRepairPlan != nil else { return }
        pendingRepairPlan = nil
        guard let snapshot else { return }
        log("运行时操作：开始执行可自动修复项", type: .command, reveal: true)
        Task {
            do {
                var verificationActionIDs: [String] = []
                if snapshot.kind == .python, snapshot.needsCurrentSessionAlignment {
                    let trustedUnion = self.currentSessionTrustedPathUnion
                    if !trustedUnion.isEmpty {
                        if let exportCommand = trustedUnion.exportCommand {
                            self.log("$ \(exportCommand)", type: .command)
                        }
                        setenv("PATH", trustedUnion.processPathValue, 1)
                        let actionID = RuntimeTrustedPathUnion.currentSessionActionID
                        verificationActionIDs.append(contentsOf: trustedUnion.verificationActionIDs)
                        self.recordRepairHistory(
                            runtimeKind: snapshot.kind,
                            actionID: actionID,
                            title: "修复计划子动作：当前会话全局 PATH 对齐",
                            detail: trustedUnion.repairHistoryDetail,
                            riskLevel: .currentSession,
                            executionResult: .succeeded,
                            verificationResult: .notRequired,
                            rollbackCommandOrNote: trustedUnion.rollbackNote
                        )
                    }
                }
                if snapshot.needsPersistentGuiAlignment, let command = snapshot.persistentPathCommand {
                    self.log("$ \(command)", type: .command)
                    _ = try await RuntimeDoctorService.runLaunchctlSetenv(command: command)
                    let actionID = "\(snapshot.kind.rawValue).persist-gui-path"
                    verificationActionIDs.append(actionID)
                    self.recordRepairHistory(
                        runtimeKind: snapshot.kind,
                        actionID: actionID,
                        title: "修复计划子动作：GUI PATH 写入",
                        detail: "已通过 launchctl 写入最小可信 GUI PATH；整体验证随修复计划重新扫描完成。",
                        riskLevel: .userPersistent,
                        executionResult: .succeeded,
                        verificationResult: .notRequired,
                        rollbackCommandOrNote: snapshot.guiRollbackCommand
                    )
                }
                if snapshot.needsNpmPrefixRepair, let npmPath = snapshot.activeNpmPath ?? snapshot.loginNpmPath {
                    self.log("$ \(npmPath) config set prefix \(snapshot.recommendedUserPrefixPath)", type: .command)
                    try await RuntimeDoctorService.repairUserNpmPrefix(npmPath: npmPath, targetPrefix: snapshot.recommendedUserPrefixPath)
                    let actionID = "\(snapshot.kind.rawValue).repair-npm-prefix"
                    verificationActionIDs.append(actionID)
                    self.recordRepairHistory(
                        runtimeKind: snapshot.kind,
                        actionID: actionID,
                        title: "修复计划子动作：npm prefix 修复",
                        detail: "已把 npm 全局 prefix 调整到用户目录；整体验证随修复计划重新扫描完成。",
                        riskLevel: .userPersistent,
                        executionResult: .succeeded,
                        verificationResult: .notRequired,
                        rollbackCommandOrNote: "npm config delete prefix"
                    )
                }
                self.actionMessage = snapshot.kind == .python
                    ? "当前会话 union PATH 已完成；共享 PATH 已更新，正在重新扫描运行时状态"
                    : "可自动处理的项目已完成，正在重新扫描运行时状态"
                self.log("可自动修复项执行完成", type: .success)
                await self.verifyAfterAction(
                    previousSnapshot: snapshot,
                    actionID: "\(snapshot.kind.rawValue).repair-plan",
                    verificationActionIDs: verificationActionIDs,
                    successTitle: "运行时修复计划已执行",
                    riskLevel: snapshot.needsPersistentGuiAlignment || snapshot.needsNpmPrefixRepair ? .userPersistent : .currentSession,
                    rollbackCommandOrNote: self.repairPlanRollbackNote(for: snapshot, actionIDs: verificationActionIDs)
                )
            } catch {
                self.errorMessage = "修复计划执行失败: \(error.localizedDescription)"
                self.log("可自动修复项执行失败: \(error.localizedDescription)", type: .failure, reveal: true)
                let detail = error.localizedDescription
                self.publishRuntimeEvent(RuntimeActionRunner.event(
                    result: .failed,
                    title: "运行时修复计划失败",
                    detail: detail,
                    relatedActionID: "\(snapshot.kind.rawValue).repair-plan",
                    verificationStatus: .failed
                ))
                self.recordRepairHistory(
                    runtimeKind: snapshot.kind,
                    actionID: "\(snapshot.kind.rawValue).repair-plan",
                    title: "运行时修复计划失败",
                    detail: detail,
                    riskLevel: snapshot.needsPersistentGuiAlignment || snapshot.needsNpmPrefixRepair ? .userPersistent : .currentSession,
                    executionResult: .failed,
                    verificationResult: .failed,
                    rollbackCommandOrNote: self.repairPlanRollbackNote(for: snapshot, actionIDs: [])
                )
            }
        }
    }

    private func repairPlanRollbackNote(for snapshot: RuntimeSnapshot, actionIDs: [String]) -> String {
        var notes: [String] = []
        if actionIDs.contains(RuntimeTrustedPathUnion.currentSessionActionID) || actionIDs.contains("\(snapshot.kind.rawValue).align-current-session") {
            notes.append(currentSessionTrustedPathUnion.rollbackNote)
        }
        if actionIDs.contains("\(snapshot.kind.rawValue).persist-gui-path") {
            notes.append(snapshot.guiRollbackCommand)
        }
        if actionIDs.contains("\(snapshot.kind.rawValue).repair-npm-prefix") {
            notes.append("npm config delete prefix")
        }
        return notes.isEmpty ? "未执行可回滚的自动子动作。" : notes.joined(separator: "；")
    }

    func reveal(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func copyActivationHint(for runtime: RuntimeInstallation) {
        let dir = URL(fileURLWithPath: runtime.path).deletingLastPathComponent().path
        let hint: String
        switch runtime.source {
        case .homebrew, .legacyManual, .officialPkg, .system, .unknown:
            hint = "export PATH=\"\(dir):$PATH\""
        case .nvm:
            hint = "nvm use \(runtime.version)"
        case .fnm:
            hint = "fnm use \(runtime.version.replacingOccurrences(of: "v", with: ""))"
        case .volta:
            hint = "volta install node@\(runtime.version.replacingOccurrences(of: "v", with: ""))"
        case .pyenv:
            hint = "pyenv shell \(runtime.version.replacingOccurrences(of: "Python ", with: ""))"
        case .conda:
            hint = "conda activate <your-env>"
        case .embedded:
            hint = "# Embedded runtime: avoid setting this as your default runtime"
        }
        copy(hint)
    }

    func update(_ package: RuntimeGlobalPackage) {
        runPackageAction(package: package, command: .update)
    }

    func reinstall(_ package: RuntimeGlobalPackage) {
        runPackageAction(package: package, command: .reinstall)
    }

    func uninstallConfirmed() {
        guard let package = uninstallCandidate else { return }
        uninstallCandidate = nil
        runPackageAction(package: package, command: .uninstall)
    }

    private enum PackageCommand {
        case update
        case reinstall
        case uninstall

        var title: String {
            switch self {
            case .update: return "更新"
            case .reinstall: return "重装"
            case .uninstall: return "卸载"
            }
        }
    }

    private func runPackageAction(package: RuntimeGlobalPackage, command: PackageCommand) {
        guard activePackageActionID == nil else { return }
        guard let npmPath = snapshot?.activeNpmPath else {
            errorMessage = "当前没有可用的 npm，可执行全局包操作。"
            return
        }
        let shellCommand: String
        switch command {
        case .update:
            shellCommand = "\(npmPath) install -g \(package.name)@latest"
        case .reinstall:
            shellCommand = "\(npmPath) install -g \(package.name) --force"
        case .uninstall:
            shellCommand = "\(npmPath) uninstall -g \(package.name)"
        }
        log("运行时操作：\(command.title)全局包 \(package.name)", type: .command, reveal: true)
        log("$ \(shellCommand)", type: .command)
        activePackageActionID = package.id
        errorMessage = nil

        Task {
            do {
                switch command {
                case .update:
                    _ = try await RuntimeDoctorService.runNpmCommand(npmPath: npmPath, args: ["install", "-g", "\(package.name)@latest"])
                case .reinstall:
                    _ = try await RuntimeDoctorService.runNpmCommand(npmPath: npmPath, args: ["install", "-g", package.name, "--force"])
                case .uninstall:
                    _ = try await RuntimeDoctorService.runNpmCommand(npmPath: npmPath, args: ["uninstall", "-g", package.name])
                }
                self.actionMessage = "\(command.title)完成: \(package.name)"
                self.log("\(command.title)完成: \(package.name)", type: .success)
                self.activePackageActionID = nil
                self.refresh()
            } catch {
                self.errorMessage = "\(command.title)失败: \(error.localizedDescription)"
                self.log("\(command.title)失败: \(package.name) - \(error.localizedDescription)", type: .failure, reveal: true)
                self.activePackageActionID = nil
            }
        }
    }
}
