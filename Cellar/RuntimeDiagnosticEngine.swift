import Foundation

enum RuntimeDiagnosticEngine {
    static func issues(for snapshot: RuntimeSnapshot) -> [RuntimeDiagnosticIssue] {
        snapshot.issues.map { issue in
            RuntimeDiagnosticIssue(
                id: "\(snapshot.kind.rawValue).\(stableIdentifier(issue.id))",
                runtimeKind: snapshot.kind,
                severity: issue.severity,
                title: issue.title,
                summary: issue.currentState,
                impact: issue.explanation,
                evidence: evidence(for: issue, snapshot: snapshot),
                recommendedActions: recommendedActions(for: issue, snapshot: snapshot)
            )
        }
    }

    static func recommendedActions(for issue: RuntimeIssue, snapshot: RuntimeSnapshot) -> [RuntimeDiagnosticAction] {
        var actions: [RuntimeDiagnosticAction] = []

        if issue.title.contains("GUI 当前未接入") || issue.title.contains("GUI 与终端默认") {
            if snapshot.currentSessionValidationCommand != nil {
                actions.append(RuntimeDiagnosticAction(
                    id: "\(snapshot.kind.rawValue).align-current-session",
                    title: "最小可信对齐",
                    description: "只更新 Cellar 当前进程的全局 PATH；执行时会使用 Node / Python 的 Minimal Trusted PATH union。",
                    risk: .currentSession,
                    executionMode: .automatic,
                    commandPreview: "export PATH=\"<Node / Python Minimal Trusted PATH union>\"",
                    rollbackCommand: "重新启动 Cellar"
                ))
            }

            if let command = snapshot.persistentPathCommand {
                actions.append(RuntimeDiagnosticAction(
                    id: "\(snapshot.kind.rawValue).persist-gui-path",
                    title: "复制 GUI PATH 写入命令",
                    description: "为后续新启动的 GUI 应用写入 launchd 用户会话 PATH。",
                    risk: .userPersistent,
                    executionMode: snapshot.kind == .node ? .automatic : .copyCommand,
                    commandPreview: command,
                    rollbackCommand: snapshot.guiRollbackCommand
                ))
            }
        }

        if issue.title.contains("npm prefix"), let npmPath = snapshot.activeNpmPath ?? snapshot.loginNpmPath {
            actions.append(RuntimeDiagnosticAction(
                id: "\(snapshot.kind.rawValue).repair-npm-prefix",
                title: "修复 npm prefix",
                description: "将 npm 全局 prefix 调整到用户目录，避免继续写入 /usr/local。",
                risk: .userPersistent,
                executionMode: .automatic,
                commandPreview: "\(npmPath) config set prefix \(snapshot.recommendedUserPrefixPath)",
                rollbackCommand: "npm config delete prefix"
            ))
        }

        if issue.title.contains("PATH") || issue.title.contains("bin 未进入") || issue.title.contains("工具入口目录") {
            actions.append(RuntimeDiagnosticAction(
                id: "\(snapshot.kind.rawValue).copy-shell-patch",
                title: "复制 Shell PATH 补丁",
                description: "生成需要手动写入 shell 启动配置的 PATH 补丁。",
                risk: .highRiskManual,
                executionMode: .copyCommand,
                commandPreview: snapshot.shellPatchSnippet,
                rollbackCommand: "从 \(snapshot.suggestedShellConfigFile) 中移除 Cellar runtime alignment 片段"
            ))
        }

        if issue.title.contains("conda base") {
            actions.append(RuntimeDiagnosticAction(
                id: "\(snapshot.kind.rawValue).conda-base-guidance",
                title: "复制 conda base 处理命令",
                description: "只提供手动命令，避免 Cellar 静默改变 conda 初始化策略。",
                risk: .highRiskManual,
                executionMode: .copyCommand,
                commandPreview: "conda config --set auto_activate_base false",
                rollbackCommand: "conda config --set auto_activate_base true"
            ))
        }

        if issue.title.contains("旧") || issue.title.contains("Legacy") || issue.title.contains("多套") || issue.title.contains("混用") || issue.title.contains("并存") {
            actions.append(RuntimeDiagnosticAction(
                id: "\(snapshot.kind.rawValue).copy-governance-guide",
                title: "复制来源治理建议",
                description: "列出主来源、旧来源候选和核对命令；清理动作必须由用户手动确认。",
                risk: .highRiskManual,
                executionMode: .copyCommand,
                commandPreview: snapshot.governancePlanLines.joined(separator: "\n"),
                rollbackCommand: nil
            ))
        }

        if actions.isEmpty, issue.severity >= .warning {
            actions.append(RuntimeDiagnosticAction(
                id: "\(snapshot.kind.rawValue).export-diagnostic-report",
                title: "导出诊断报告",
                description: "保留当前快照、证据和建议，便于进一步排查。",
                risk: .readOnly,
                executionMode: .automatic,
                commandPreview: nil,
                rollbackCommand: nil
            ))
        }

        return actions.map { action in
            if action.risk == .highRiskManual && action.executionMode == .automatic {
                return RuntimeDiagnosticAction(
                    id: action.id,
                    title: action.title,
                    description: action.description,
                    risk: action.risk,
                    executionMode: .manualInstruction,
                    commandPreview: action.commandPreview,
                    rollbackCommand: action.rollbackCommand
                )
            }
            return action
        }
    }

    private static func evidence(for issue: RuntimeIssue, snapshot: RuntimeSnapshot) -> [String] {
        var values: [String] = [issue.currentState]
        if let guiPath = snapshot.activeNodePath {
            values.append("GUI: \(guiPath)")
        }
        if let shellPath = snapshot.loginNodePath {
            values.append("Shell: \(shellPath)")
        }
        if let prefix = snapshot.npmPrefix {
            values.append("prefix: \(prefix)")
        }
        return values
    }

    private static func stableIdentifier(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }.reduce(into: "") { $0.append($1) }
    }
}

extension RuntimeSnapshot {
    var diagnosticIssues: [RuntimeDiagnosticIssue] {
        RuntimeDiagnosticEngine.issues(for: self)
    }
}
