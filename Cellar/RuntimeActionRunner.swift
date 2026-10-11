import Foundation

enum RuntimeActionRunner {
    static func verificationStatus(
        before: RuntimeSnapshot?,
        after: RuntimeSnapshot?,
        relatedActionIDs: [String] = []
    ) -> RuntimeDiagnosticVerificationStatus {
        guard let before, let after else { return .failed }
        if relatedActionIDs.contains(RuntimeTrustedPathUnion.currentSessionActionID) {
            return sessionAlignmentStatus(snapshots: [after])
        }

        let actionIDSet = Set(relatedActionIDs)
        let beforeProblems = problems(in: before, relatedActionIDs: actionIDSet)
        let afterProblems = problems(in: after, relatedActionIDs: actionIDSet)
        if beforeProblems.isEmpty {
            return .notRequired
        }
        if afterProblems.count < beforeProblems.count {
            return .passed
        }

        let beforeMax = beforeProblems.map(\.severity).max() ?? .info
        let afterMax = afterProblems.map(\.severity).max() ?? .info
        return afterMax < beforeMax ? .passed : .unchanged
    }

    static func sessionAlignmentStatus(snapshots: [RuntimeSnapshot]) -> RuntimeDiagnosticVerificationStatus {
        guard !snapshots.isEmpty else { return .failed }
        return snapshots.allSatisfy { $0.environmentHealth == .healthy } ? .passed : .needsAttention
    }

    static func sessionAlignmentDetail(snapshots: [RuntimeSnapshot]) -> String {
        let remaining = snapshots.flatMap { snapshot in
            snapshot.issues.filter { $0.severity >= .warning }.map { "\(snapshot.runtimeDisplayName)：\($0.title)" }
        }
        if remaining.isEmpty {
            return "当前会话 PATH 已对齐；已扫描的运行时均健康。这不代表全局工具都已更新。"
        }
        return "当前会话 PATH 已对齐，但仍需关注：\(remaining.joined(separator: "；"))。对齐不会切换登录 Shell 的主来源；请查看对应指引。"
    }

    private static func problems(
        in snapshot: RuntimeSnapshot,
        relatedActionIDs: Set<String>
    ) -> [RuntimeDiagnosticIssue] {
        snapshot.diagnosticIssues.filter { issue in
            guard issue.severity >= .warning else { return false }
            guard !relatedActionIDs.isEmpty else { return true }
            return issue.recommendedActions.contains { relatedActionIDs.contains($0.id) }
        }
    }

    static func event(
        result: RuntimeDiagnosticActionResult,
        title: String,
        detail: String,
        relatedActionID: String?,
        verificationStatus: RuntimeDiagnosticVerificationStatus
    ) -> RuntimeDiagnosticEvent {
        let kind: RuntimeDiagnosticEventKind
        switch result {
        case .copiedCommand, .waitingForManualExecution:
            kind = .commandCopied
        case .succeeded, .failed, .skipped:
            kind = .actionFinished
        }

        return RuntimeDiagnosticEvent(
            kind: kind,
            title: title,
            detail: detail,
            relatedActionID: relatedActionID,
            verificationStatus: verificationStatus
        )
    }
}
