import Foundation

enum RuntimeDiagnosticEventKind: String, Codable, Sendable {
    case actionStarted
    case actionFinished
    case commandCopied
    case verificationFinished
}

enum RuntimeDiagnosticVerificationStatus: String, Codable, Sendable {
    case notRequired
    case pendingManualAction
    case passed
    case unchanged
    case failed

    var displayName: String {
        switch self {
        case .notRequired: return "无需验证"
        case .pendingManualAction: return "等待手动执行"
        case .passed: return "验证通过"
        case .unchanged: return "验证未通过"
        case .failed: return "验证失败"
        }
    }
}

enum RuntimeDiagnosticActionResult: String, Codable, Sendable {
    case succeeded
    case failed
    case copiedCommand
    case skipped
    case waitingForManualExecution
}

struct RuntimeDiagnosticEvent: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let date: Date
    let kind: RuntimeDiagnosticEventKind
    let title: String
    let detail: String
    let relatedActionID: String?
    let verificationStatus: RuntimeDiagnosticVerificationStatus

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        kind: RuntimeDiagnosticEventKind,
        title: String,
        detail: String,
        relatedActionID: String?,
        verificationStatus: RuntimeDiagnosticVerificationStatus
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.title = title
        self.detail = detail
        self.relatedActionID = relatedActionID
        self.verificationStatus = verificationStatus
    }
}
