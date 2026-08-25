import Foundation

enum RuntimeActionRunner {
    static func verificationStatus(
        before: RuntimeSnapshot?,
        after: RuntimeSnapshot?,
        relatedActionIDs: [String] = []
    ) -> RuntimeDiagnosticVerificationStatus {
        guard let before, let after else { return .failed }

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
