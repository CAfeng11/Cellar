import Foundation

enum AppEventSource: String, Codable, Sendable {
    case homebrew = "Homebrew"
    case runtime = "Runtime"
    case network = "网络与权限"
    case system = "Cellar"
}

enum AppEventSeverity: Int, Codable, Comparable, Sendable {
    case info = 0
    case success = 1
    case attention = 2
    case failure = 3

    static func < (lhs: AppEventSeverity, rhs: AppEventSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum AppEventPhase: String, Codable, Sendable {
    case active
    case history
}

struct AppEvent: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let date: Date
    let source: AppEventSource
    let severity: AppEventSeverity
    let phase: AppEventPhase
    let operationKey: String?
    let statusText: String
    let title: String
    let detail: String
    let opensLog: Bool

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        source: AppEventSource,
        severity: AppEventSeverity,
        phase: AppEventPhase = .history,
        operationKey: String? = nil,
        statusText: String,
        title: String,
        detail: String,
        opensLog: Bool
    ) {
        self.id = id
        self.date = date
        self.source = source
        self.severity = severity
        self.phase = phase
        self.operationKey = operationKey
        self.statusText = statusText
        self.title = title
        self.detail = detail
        self.opensLog = opensLog
    }
}

enum AppEventFactory {
    static func event(from summary: BrewOperationSummary) -> AppEvent {
        if let issue = summary.reliabilityIssue {
            return AppEvent(
                source: .network,
                severity: .failure,
                phase: .history,
                operationKey: operationKey(for: summary),
                statusText: summary.status.displayName,
                title: issue.title,
                detail: "\(issue.explanation) \(issue.nextStep)",
                opensLog: true
            )
        }
        return AppEvent(
            source: .homebrew,
            severity: severity(for: summary.status),
            phase: phase(for: summary.status),
            operationKey: operationKey(for: summary),
            statusText: summary.status.displayName,
            title: summary.operationKind.displayName,
            detail: summary.recommendedNextAction.map { "\(summary.summaryText) \($0)" } ?? summary.summaryText,
            opensLog: summary.status == .failed || summary.status == .running
        )
    }

    static func event(from runtimeEvent: RuntimeDiagnosticEvent) -> AppEvent {
        AppEvent(
            source: .runtime,
            severity: severity(for: runtimeEvent.verificationStatus),
            phase: phase(for: runtimeEvent),
            operationKey: operationKey(for: runtimeEvent),
            statusText: runtimeEvent.verificationStatus.displayName,
            title: runtimeEvent.title,
            detail: runtimeEvent.detail,
            opensLog: runtimeEvent.verificationStatus == .failed || runtimeEvent.verificationStatus == .unchanged
        )
    }

    private static func severity(for status: BrewOperationStatus) -> AppEventSeverity {
        switch status {
        case .running: return .attention
        case .succeeded: return .success
        case .failed: return .failure
        case .cancelled: return .info
        }
    }

    private static func phase(for status: BrewOperationStatus) -> AppEventPhase {
        status == .running ? .active : .history
    }

    private static func phase(for event: RuntimeDiagnosticEvent) -> AppEventPhase {
        event.kind == .actionStarted ? .active : .history
    }

    private static func operationKey(for summary: BrewOperationSummary) -> String {
        "homebrew.\(summary.operationKind.rawValue)"
    }

    private static func operationKey(for event: RuntimeDiagnosticEvent) -> String? {
        guard event.kind != .commandCopied, let relatedActionID = event.relatedActionID else {
            return nil
        }
        return "runtime.\(relatedActionID)"
    }

    private static func severity(for status: RuntimeDiagnosticVerificationStatus) -> AppEventSeverity {
        switch status {
        case .notRequired, .pendingManualAction: return .attention
        case .passed: return .success
        case .unchanged, .failed: return .failure
        }
    }
}

enum AppEventReducer {
    static func publish(
        _ event: AppEvent,
        activeEvents: inout [AppEvent],
        historyEvents: inout [AppEvent],
        maxActive: Int = 20,
        maxHistory: Int = 80
    ) {
        switch event.phase {
        case .active:
            if let operationKey = event.operationKey {
                activeEvents.removeAll { $0.operationKey == operationKey }
            }
            activeEvents.insert(event, at: 0)
            trim(&activeEvents, to: maxActive)
        case .history:
            if let operationKey = event.operationKey {
                activeEvents.removeAll { $0.operationKey == operationKey }
            }
            removeShortIntervalDuplicate(of: event, from: &historyEvents)
            historyEvents.insert(event, at: 0)
            trim(&historyEvents, to: maxHistory)
        }
    }

    private static func removeShortIntervalDuplicate(
        of event: AppEvent,
        from historyEvents: inout [AppEvent],
        interval: TimeInterval = 10
    ) {
        guard let operationKey = event.operationKey else { return }
        historyEvents.removeAll { existing in
            existing.operationKey == operationKey
                && existing.statusText == event.statusText
                && existing.title == event.title
                && existing.detail == event.detail
                && abs(existing.date.timeIntervalSince(event.date)) <= interval
        }
    }

    private static func trim(_ events: inout [AppEvent], to limit: Int) {
        if events.count > limit {
            events.removeLast(events.count - limit)
        }
    }
}

struct FooterTimeSnapshot: Equatable, Sendable {
    let lastCheckTime: Date?
    let lastLibraryRefreshAt: Date?
    let lastBrewUpdateAt: Date?
    var runtimePathStatus: String? = nil
    var runtimePathDetail: String? = nil
}

struct FooterStatusItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let date: Date?

    var shortText: String {
        "\(title)：\(value)"
    }
}

enum FooterTimeStatusFormatter {
    nonisolated static func statusText(from snapshot: FooterTimeSnapshot, now: Date = Date()) -> String {
        FooterStatusGroupFormatter.latestText(from: snapshot, now: now)
    }
}

enum FooterStatusGroupFormatter {
    nonisolated static func items(from snapshot: FooterTimeSnapshot, now: Date = Date()) -> [FooterStatusItem] {
        let candidates: [(label: String, date: Date?)] = [
            ("最后检查", snapshot.lastCheckTime),
            ("最后刷新酒窖", snapshot.lastLibraryRefreshAt),
            ("最后 brew update", snapshot.lastBrewUpdateAt)
        ]

        var items = candidates.compactMap { candidate -> FooterStatusItem? in
            guard let date = candidate.date else { return nil }
            return FooterStatusItem(
                id: candidate.label,
                title: candidate.label,
                value: relativeTimeText(for: date, now: now),
                detail: detailText(for: candidate.label),
                date: date
            )
        }

        let runtimeStatus = snapshot.runtimePathStatus ?? "未扫描"
        items.append(FooterStatusItem(
            id: "runtime-path",
            title: "PATH",
            value: runtimeStatus,
            detail: snapshot.runtimePathDetail ?? "打开运行时诊断后，Cellar 会显示当前会话 PATH 是否已按最小可信 union 对齐；这不代表 Runtime 全局工具 latest 已全部复核。",
            date: nil
        ))

        if items.isEmpty {
            return [
                FooterStatusItem(
                    id: "empty",
                    title: "状态",
                    value: "等待首次检查或刷新",
                    detail: "下一步：检查更新、刷新我的酒窖，或打开运行时诊断同步 PATH 当前会话状态。",
                    date: nil
                )
            ]
        }

        return items
    }

    nonisolated static func latestText(from snapshot: FooterTimeSnapshot, now: Date = Date()) -> String {
        let candidates: [(label: String, date: Date?)] = [
            ("最后检查", snapshot.lastCheckTime),
            ("最后刷新酒窖", snapshot.lastLibraryRefreshAt),
            ("最后 brew update", snapshot.lastBrewUpdateAt)
        ]

        guard let latest = candidates
            .compactMap({ candidate -> (label: String, date: Date)? in
                guard let date = candidate.date else { return nil }
                return (candidate.label, date)
            })
            .max(by: { $0.date < $1.date }) else {
            return "等待首次检查或刷新"
        }

        return "\(latest.label)：\(relativeTimeText(for: latest.date, now: now))"
    }

    private nonisolated static func detailText(for label: String) -> String {
        switch label {
        case "最后检查":
            return "最近一次读取 Homebrew 可升级列表的时间，不代表已经执行 brew update。"
        case "最后刷新酒窖":
            return "最近一次刷新已安装资产清点的时间。"
        case "最后 brew update":
            return "最近一次更新 Homebrew 仓库元数据的时间。"
        default:
            return "最近关键状态。"
        }
    }

    private nonisolated static func relativeTimeText(for date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) {
            return "今天 \(time)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨天 \(time)"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
