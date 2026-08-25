import Foundation

enum RuntimeDiagnosticActionRisk: String, Codable, Sendable {
    case readOnly
    case currentSession
    case userPersistent
    case highRiskManual

    var displayName: String {
        switch self {
        case .readOnly: return "只读"
        case .currentSession: return "当前会话级"
        case .userPersistent: return "用户级持久化"
        case .highRiskManual: return "高风险手动"
        }
    }
}

enum RuntimeDiagnosticExecutionMode: String, Codable, Sendable {
    case automatic
    case copyCommand
    case manualInstruction
}

struct RuntimeDiagnosticAction: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let description: String
    let risk: RuntimeDiagnosticActionRisk
    let executionMode: RuntimeDiagnosticExecutionMode
    let commandPreview: String?
    let rollbackCommand: String?
}

struct RuntimeDiagnosticIssue: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let runtimeKind: RuntimeKind
    let severity: RuntimeIssueSeverity
    let title: String
    let summary: String
    let impact: String
    let evidence: [String]
    let recommendedActions: [RuntimeDiagnosticAction]
}
