import Foundation

enum RuntimePATHPolicyKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case minimalTrusted
    case mirrorShell
    case customExpert
    case observeOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .minimalTrusted: return "Minimal Trusted PATH"
        case .mirrorShell: return "Mirror Shell PATH"
        case .customExpert: return "Custom PATH Expert"
        case .observeOnly: return "Disabled / Observe Only"
        }
    }
}

struct RuntimePATHPolicy: Identifiable, Codable, Hashable, Sendable {
    let kind: RuntimePATHPolicyKind
    let title: String
    let summary: String
    let impactScope: [String]
    let riskLevel: RuntimeDiagnosticActionRisk
    let executableActions: [String]
    let rollbackDescription: String

    var id: RuntimePATHPolicyKind { kind }
}

enum RuntimePATHPolicyCatalog {
    static func currentPolicy(for snapshot: RuntimeSnapshot) -> RuntimePATHPolicy {
        policy(.minimalTrusted, runtimeName: snapshot.runtimeDisplayName)
    }

    static func policies(for snapshot: RuntimeSnapshot) -> [RuntimePATHPolicy] {
        RuntimePATHPolicyKind.allCases.map { policy($0, runtimeName: snapshot.runtimeDisplayName) }
    }

    static func policy(_ kind: RuntimePATHPolicyKind, runtimeName: String) -> RuntimePATHPolicy {
        switch kind {
        case .minimalTrusted:
            return RuntimePATHPolicy(
                kind: kind,
                title: "Minimal Trusted PATH（默认）",
                summary: "只让 Cellar 接入 \(runtimeName)、包管理器和用户级工具所需的核心可信路径，不完整复制登录 Shell 的全部 PATH。",
                impactScope: ["Cellar 当前会话", "GUI 运行时可见性", "Node / Python 工具入口", "Homebrew 与用户级 bin 目录"],
                riskLevel: .currentSession,
                executableActions: ["当前会话全局 PATH union 对齐", "GUI PATH 写入", "复制 Shell PATH 补丁"],
                rollbackDescription: "当前会话对齐可重启 Cellar 回滚；GUI PATH 写入可执行 `launchctl unsetenv PATH`。"
            )
        case .mirrorShell:
            return RuntimePATHPolicy(
                kind: kind,
                title: "Mirror Shell PATH（高级排障）",
                summary: "把登录 Shell 的完整 PATH 临时镜像到 Cellar 当前进程，用于确认问题是否来自 GUI 环境缺失。",
                impactScope: ["Cellar 当前会话", "所有运行时探测", "全局工具列表", "后续命令执行环境"],
                riskLevel: .highRiskManual,
                executableActions: ["临时镜像完整 Shell PATH"],
                rollbackDescription: "重启 Cellar 即可回滚当前会话镜像；不写入 shell 配置。"
            )
        case .customExpert:
            return RuntimePATHPolicy(
                kind: kind,
                title: "Custom PATH Expert（明确选择）",
                summary: "由用户明确指定 PATH 片段，仅适合知道每个目录来源和顺序影响的专家场景。",
                impactScope: ["用户指定的运行时入口", "显式选择的包管理器", "显式选择的全局工具目录"],
                riskLevel: .highRiskManual,
                executableActions: ["复制自定义 PATH 命令", "手动验证 PATH 顺序"],
                rollbackDescription: "删除手动加入的 PATH 片段，或恢复执行前保存的命令。Cellar 不保存完整私密环境变量。"
            )
        case .observeOnly:
            return RuntimePATHPolicy(
                kind: kind,
                title: "Disabled / Observe Only",
                summary: "只观察 Shell、GUI 与工具入口差异，不主动改写 Cellar 当前会话、GUI PATH 或 shell 配置。",
                impactScope: ["诊断报告", "事件记录", "运行时来源说明"],
                riskLevel: .readOnly,
                executableActions: ["刷新诊断", "导出报告", "复制命令供手动执行"],
                rollbackDescription: "无运行时改写；不需要回滚。"
            )
        }
    }
}

struct RuntimeRepairHistoryEntry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let date: Date
    let runtimeKind: RuntimeKind
    let actionID: String
    let title: String
    let detail: String
    let riskLevel: RuntimeDiagnosticActionRisk
    let executionResult: RuntimeDiagnosticActionResult
    let verificationResult: RuntimeDiagnosticVerificationStatus
    let rollbackCommandOrNote: String
}

enum RuntimeRepairHistoryRecorder {
    static func entry(
        runtimeKind: RuntimeKind,
        actionID: String?,
        title: String,
        detail: String,
        riskLevel: RuntimeDiagnosticActionRisk,
        executionResult: RuntimeDiagnosticActionResult,
        verificationResult: RuntimeDiagnosticVerificationStatus,
        rollbackCommandOrNote: String?
    ) -> RuntimeRepairHistoryEntry? {
        guard let actionID, !actionID.isEmpty else { return nil }
        switch executionResult {
        case .copiedCommand, .waitingForManualExecution:
            return nil
        case .succeeded, .failed, .skipped:
            return RuntimeRepairHistoryEntry(
                id: UUID(),
                date: Date(),
                runtimeKind: runtimeKind,
                actionID: actionID,
                title: title,
                detail: detail,
                riskLevel: riskLevel,
                executionResult: executionResult,
                verificationResult: verificationResult,
                rollbackCommandOrNote: rollbackCommandOrNote ?? "未提供回滚命令；请参考对应动作说明。"
            )
        }
    }
}

enum RuntimeReportComposer {
    static func compose(
        baseReport: String,
        snapshot: RuntimeSnapshot,
        events: [RuntimeDiagnosticEvent],
        repairHistory: [RuntimeRepairHistoryEntry],
        homebrewIssue: BrewReliabilityIssue? = nil,
        appEvents: [AppEvent] = [],
        operationSummary: BrewOperationSummary? = nil,
        outdatedSnapshotProvenance: HomebrewSnapshotProvenance? = nil,
        installedSnapshotProvenance: HomebrewSnapshotProvenance? = nil,
        runtimeGlobalToolsSummary: RuntimeGlobalToolsDashboardSummary? = nil
    ) -> String {
        var lines = baseReport.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let globalToolsSummary = runtimeGlobalToolsSummary ?? RuntimeGlobalToolsDashboardSummary.make(snapshots: [snapshot])
        lines.append("")
        lines.append("## Product Terminology")
        lines.append(contentsOf: ProductCopy.terminologyMarkdown)
        lines.append("")
        lines.append("## Current Diagnostic Snapshot")
        lines.append("- Runtime: \(snapshot.runtimeDisplayName)")
        lines.append("- Headline: \(snapshot.runtimeEnvironmentHeadline)")
        lines.append("- GUI: \(snapshot.guiEnvironmentLine)")
        lines.append("- Shell: \(snapshot.shellEnvironmentLine)")
        lines.append("- Tools: \(snapshot.dashboardToolSummary)")
        lines.append("- Findings: \(snapshot.issues.isEmpty ? "No active Runtime findings." : "\(snapshot.issues.count) Runtime finding(s)")")
        if let operationSummary {
            lines.append("- Latest Homebrew operation: \(operationSummary.operationKind.displayName) / \(operationSummary.status.displayName)")
            lines.append("- Homebrew summary: \(operationSummary.summaryText)")
            if let next = operationSummary.recommendedNextAction {
                lines.append("- Homebrew next step: \(next)")
            }
        } else {
            lines.append("- Latest Homebrew operation: No Homebrew operation summary recorded in this session.")
        }
        lines.append("")
        lines.append("## Homebrew Snapshot Provenance")
        if let outdatedSnapshotProvenance {
            lines.append(contentsOf: outdatedSnapshotProvenance.reportLines)
        } else {
            lines.append("- Update list snapshot: No provenance recorded.")
        }
        if let installedSnapshotProvenance {
            lines.append(contentsOf: installedSnapshotProvenance.reportLines)
        } else {
            lines.append("- Installed library snapshot: No provenance recorded.")
        }
        lines.append("")
        lines.append("## Runtime Global Tools Dashboard Summary")
        lines.append(contentsOf: globalToolsSummary.reportLines)
        let policy = snapshot.pathPolicy
        lines.append("")
        lines.append("## Runtime PATH Policy")
        lines.append("- Current policy: \(policy.title)")
        lines.append("- Summary: \(policy.summary)")
        lines.append("- Risk: \(policy.riskLevel.displayName)")
        lines.append("- Impact scope: \(policy.impactScope.joined(separator: ", "))")
        lines.append("- Executable actions: \(policy.executableActions.joined(separator: ", "))")
        lines.append("- Rollback: \(policy.rollbackDescription)")
        lines.append("")
        lines.append("## Homebrew Reliability Diagnostics")
        if let homebrewIssue {
            lines.append("- Status: \(homebrewIssue.title)")
            lines.append("- Kind: \(homebrewIssue.kind.displayName)")
            lines.append("- Explanation: \(homebrewIssue.explanation)")
            lines.append("- Impact: \(homebrewIssue.impact)")
            lines.append("- Next step: \(homebrewIssue.nextStep)")
            if !homebrewIssue.manualCommands.isEmpty {
                lines.append("- Manual checks: \(homebrewIssue.manualCommands.joined(separator: ", "))")
            }
        } else {
            lines.append("- No Homebrew reliability issue recorded in this session.")
        }
        lines.append("")
        lines.append("## Recent Key Events")
        if appEvents.isEmpty {
            lines.append("- No cross-product events recorded in this Cellar session.")
        } else {
            for event in appEvents.prefix(12) {
                lines.append("- \(event.date.formatted(date: .abbreviated, time: .standard)) | \(event.source.rawValue) | \(event.title)")
                lines.append("  Detail: \(event.detail)")
            }
        }
        lines.append("")
        lines.append("## Runtime Events")
        if events.isEmpty {
            lines.append("- No runtime events recorded in this Cellar session.")
        } else {
            for event in events {
                lines.append("- \(event.date.formatted(date: .abbreviated, time: .standard)) | \(event.kind.rawValue) | \(event.title) | \(event.verificationStatus.displayName)")
                lines.append("  Detail: \(event.detail)")
                if let relatedActionID = event.relatedActionID {
                    lines.append("  Action: \(relatedActionID)")
                }
            }
        }
        lines.append("")
        lines.append("## Runtime Repair History")
        if repairHistory.isEmpty {
            lines.append("- No Cellar-executed Runtime repair actions recorded in this session.")
        } else {
            for entry in repairHistory {
                lines.append("- \(entry.date.formatted(date: .abbreviated, time: .standard)) | \(entry.runtimeKind.displayName) | \(entry.actionID)")
                lines.append("  Title: \(entry.title)")
                lines.append("  Risk: \(entry.riskLevel.displayName)")
                lines.append("  Execution: \(entry.executionResult.rawValue)")
                lines.append("  Verification: \(entry.verificationResult.displayName)")
                lines.append("  Rollback: \(entry.rollbackCommandOrNote)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
