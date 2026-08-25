import Foundation

enum DashboardSeverity: Int, Codable, Comparable, Sendable {
    case clear = 0
    case attention = 1
    case warning = 2
    case critical = 3

    static func < (lhs: DashboardSeverity, rhs: DashboardSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .clear: return "当前无需处理"
        case .attention: return "建议关注"
        case .warning: return "需要处理"
        case .critical: return "操作失败或环境异常"
        }
    }
}

enum DashboardAction: Hashable, Codable, Sendable {
    case checkUpdates
    case updateThenCheck
    case showUpdates
    case showRuntime
    case showRuntimeGlobalTool(String)
    case showLibrary(PackageStateFilterKey)
    case showSettings(SettingsReliabilitySection?)
}

struct DashboardActionItem: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let source: String
    let title: String
    let detail: String
    let severity: DashboardSeverity
    let actionTitle: String
    let action: DashboardAction
}

struct DashboardDomainStatus: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let severity: DashboardSeverity
    let action: DashboardAction?
    let actionTitle: String?
}

struct DashboardHealthSummary: Codable, Hashable, Sendable {
    let severity: DashboardSeverity
    let headline: String
    let detail: String
    let domains: [DashboardDomainStatus]
    let items: [DashboardActionItem]

    var hasActionItems: Bool { !items.isEmpty }

    static func make(
        brewStatus: BrewStatus,
        outdatedPackages: [BrewPackage],
        operationSummary: BrewOperationSummary?,
        runtimeSnapshots: [RuntimeSnapshot],
        runtimeGlobalToolsSummary: RuntimeGlobalToolsDashboardSummary = .empty,
        librarySummary: LibrarySummary,
        homebrewSnapshotProvenance: HomebrewSnapshotProvenance? = nil
    ) -> DashboardHealthSummary {
        var items: [DashboardActionItem] = []
        let runtimeAttentionCount = runtimeSnapshots.reduce(0) { count, snapshot in
            count + snapshot.diagnosticIssues.filter { $0.severity >= .warning }.count
        }
        let runtimeMaxSeverity = runtimeSnapshots
            .flatMap(\.diagnosticIssues)
            .map(\.severity)
            .max() ?? .info

        switch brewStatus {
        case .error(let message):
            items.append(DashboardActionItem(
                id: "brew.error",
                source: "Homebrew",
                title: "Homebrew 操作异常",
                detail: message,
                severity: .critical,
                actionTitle: "打开设置",
                action: .showSettings(.homebrewService)
            ))
        case .outdated(let count):
            items.append(DashboardActionItem(
                id: "brew.outdated",
                source: "Homebrew",
                title: "发现 \(count) 个普通可升级项目",
                detail: "可先查看更新列表，再决定单独升级或批量处理。",
                severity: .warning,
                actionTitle: "查看更新列表",
                action: .showUpdates
            ))
        case .idle:
            if outdatedPackages.isEmpty {
                items.append(DashboardActionItem(
                    id: "brew.not-checked",
                    source: "Homebrew",
                    title: "尚未检查更新",
                    detail: "检查后才能确认今天是否有 Homebrew 更新需要处理。",
                    severity: .attention,
                    actionTitle: "检查更新",
                    action: .checkUpdates
                ))
            }
        case .upToDate:
            break
        }

        if let operationSummary, operationSummary.status == .failed {
            if let issue = operationSummary.reliabilityIssue {
                items.append(reliabilityActionItem(from: issue, operationKind: operationSummary.operationKind))
            } else {
                items.append(DashboardActionItem(
                    id: "brew.operation.failed.\(operationSummary.operationKind.rawValue)",
                    source: "Homebrew",
                    title: "\(operationSummary.operationKind.displayName)失败",
                    detail: operationSummary.recommendedNextAction ?? operationSummary.summaryText,
                    severity: .critical,
                    actionTitle: "打开设置",
                    action: .showSettings(.homebrewService)
                ))
            }
        }

        if let runtimeItem = runtimeActionItem(from: runtimeSnapshots) {
            items.append(runtimeItem)
        }
        if let runtimeGlobalToolsItem = runtimeGlobalToolsActionItem(from: runtimeGlobalToolsSummary) {
            items.append(runtimeGlobalToolsItem)
        }

        items.append(contentsOf: libraryActionItems(from: librarySummary))

        let ordered = items.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            return $0.source < $1.source
        }
        let severity = ordered.map(\.severity).max() ?? .clear
        let domains = domainStatuses(
            brewStatus: brewStatus,
            outdatedPackages: outdatedPackages,
            homebrewSnapshotProvenance: homebrewSnapshotProvenance,
            operationSummary: operationSummary,
            runtimeAttentionCount: runtimeAttentionCount,
            runtimeMaxSeverity: runtimeMaxSeverity,
            runtimeGlobalToolsSummary: runtimeGlobalToolsSummary,
            librarySummary: librarySummary
        )
        return DashboardHealthSummary(
            severity: severity,
            headline: headline(
                brewStatus: brewStatus,
                runtimeAttentionCount: runtimeAttentionCount + runtimeGlobalToolsSummary.attentionCount,
                libraryAttentionCount: librarySummary.attentionCount,
                itemCount: ordered.count,
                severity: severity,
                homebrewSnapshotProvenance: homebrewSnapshotProvenance
            ),
            detail: detail(for: severity, itemCount: ordered.count),
            domains: domains,
            items: ordered
        )
    }

    private static func runtimeActionItem(from snapshots: [RuntimeSnapshot]) -> DashboardActionItem? {
        let ranked = snapshots.compactMap { snapshot -> (RuntimeSnapshot, RuntimeDiagnosticIssue)? in
            snapshot.diagnosticIssues
                .filter { $0.severity >= .warning }
                .sorted { $0.severity > $1.severity }
                .first
                .map { (snapshot, $0) }
        }
        guard let selected = ranked.sorted(by: { $0.1.severity > $1.1.severity }).first else {
            return nil
        }
        let severity: DashboardSeverity = selected.1.severity >= .high ? .critical : .warning
        return DashboardActionItem(
            id: "runtime.\(selected.0.kind.rawValue).\(selected.1.id)",
            source: "Runtime",
            title: "\(selected.0.kind.displayName) \(selected.1.severity.title)",
            detail: selected.1.title,
            severity: severity,
            actionTitle: "查看运行时",
            action: .showRuntime
        )
    }

    private static func runtimeGlobalToolsActionItem(
        from summary: RuntimeGlobalToolsDashboardSummary
    ) -> DashboardActionItem? {
        guard summary.hasAttention else { return nil }
        return DashboardActionItem(
            id: "runtime.global-tools",
            source: "Runtime",
            title: summary.actionItemTitle,
            detail: summary.actionItemDetail,
            severity: summary.dashboardSeverity,
            actionTitle: summary.actionTitle,
            action: .showRuntimeGlobalTool(summary.primaryAttentionItem?.id ?? "")
        )
    }

    private static func reliabilityActionItem(
        from issue: BrewReliabilityIssue,
        operationKind: BrewOperationKind
    ) -> DashboardActionItem {
        DashboardActionItem(
            id: "brew.reliability.\(operationKind.rawValue).\(issue.kind.rawValue)",
            source: "Homebrew",
            title: issue.title,
            detail: "\(issue.explanation) \(issue.impact)",
            severity: issue.kind == .network || issue.kind == .dns || issue.kind == .proxy || issue.kind == .endpoint ? .warning : .critical,
            actionTitle: issue.actionTitle,
            action: .showSettings(issue.settingsSection)
        )
    }

    private static func libraryActionItems(from summary: LibrarySummary) -> [DashboardActionItem] {
        var items: [DashboardActionItem] = []
        if summary.repoDiffCount > 0 {
            items.append(DashboardActionItem(
                id: "library.repo-diff",
                source: "我的酒窖",
                title: "\(summary.repoDiffCount) 个版本差异",
                detail: "这可能来自 Formula revision、自更新 App 或需要确认的 raw 版本差异；不直接等同于可升级。",
                severity: .attention,
                actionTitle: "查看差异",
                action: .showLibrary(.repoDiff)
            ))
        }
        if summary.sizeUnknownCount > 0 {
            items.append(DashboardActionItem(
                id: "library.size-unknown",
                source: "我的酒窖",
                title: "\(summary.sizeUnknownCount) 个酒窖大小未知项目",
                detail: "这里只统计已安装酒窖资产的本机大小探测状态，不代表更新候选的下载大小或旧包参考体量。",
                severity: .attention,
                actionTitle: "查看酒窖大小未知",
                action: .showLibrary(.sizeUnknown)
            ))
        }
        if summary.autoUpdatesCount > 0 {
            items.append(DashboardActionItem(
                id: "library.auto-updates",
                source: "我的酒窖",
                title: "\(summary.autoUpdatesCount) 个自更新 Cask",
                detail: "这类 App 可能由应用内部更新，Homebrew 不一定追踪其内部版本。",
                severity: .attention,
                actionTitle: "查看自更新",
                action: .showLibrary(.autoUpdates)
            ))
        }
        if summary.leafCount > 0 {
            items.append(DashboardActionItem(
                id: "library.leaf",
                source: "我的酒窖",
                title: "\(summary.leafCount) 个叶子包",
                detail: "叶子包可作为清点入口，但不代表一定可以删除。",
                severity: .attention,
                actionTitle: "查看叶子包",
                action: .showLibrary(.leaf)
            ))
        }
        return items
    }

    private static func detail(for severity: DashboardSeverity, itemCount: Int) -> String {
        switch severity {
        case .clear:
            return "各域暂无明显待处理项。"
        case .attention:
            return "建议关注项已归入下方域卡片和摘要。"
        case .warning:
            return "优先处理 Homebrew 更新，环境/清点事项可随后复核。"
        case .critical:
            return "失败或环境异常已归入高优先级摘要。"
        }
    }

    private static func headline(
        brewStatus: BrewStatus,
        runtimeAttentionCount: Int,
        libraryAttentionCount: Int,
        itemCount: Int,
        severity: DashboardSeverity,
        homebrewSnapshotProvenance: HomebrewSnapshotProvenance?
    ) -> String {
        let secondaryCount = runtimeAttentionCount + libraryAttentionCount
        switch brewStatus {
        case .outdated(let count):
            if secondaryCount > 0 {
                return "发现 \(count) 个普通可升级项目，环境/清点事项另行归类"
            }
            return "发现 \(count) 个普通可升级项目"
        case .upToDate:
            if let homebrewSnapshotProvenance, !homebrewSnapshotProvenance.isAuthoritativeSuccess {
                return "Homebrew 状态待确认，当前显示\(homebrewSnapshotProvenance.fallbackState.displayName)"
            }
            if secondaryCount > 0 {
                return "Homebrew 无可升级包，仍有环境/清点事项需关注"
            }
            return "Homebrew 无可升级包"
        case .idle:
            if itemCount > 0 {
                return "尚未检查 Homebrew，已有状态可先复核"
            }
            return "尚未检查 Homebrew"
        case .error:
            return severity == .critical ? "Homebrew 操作异常，需要先处理" : "Homebrew 状态需要复核"
        }
    }

    private static func domainStatuses(
        brewStatus: BrewStatus,
        outdatedPackages: [BrewPackage],
        homebrewSnapshotProvenance: HomebrewSnapshotProvenance?,
        operationSummary: BrewOperationSummary?,
        runtimeAttentionCount: Int,
        runtimeMaxSeverity: RuntimeIssueSeverity,
        runtimeGlobalToolsSummary: RuntimeGlobalToolsDashboardSummary,
        librarySummary: LibrarySummary
    ) -> [DashboardDomainStatus] {
        [
            homebrewDomainStatus(
                brewStatus: brewStatus,
                outdatedPackages: outdatedPackages,
                provenance: homebrewSnapshotProvenance
            ),
            runtimeDomainStatus(
                attentionCount: runtimeAttentionCount,
                maxSeverity: runtimeMaxSeverity,
                globalToolsSummary: runtimeGlobalToolsSummary
            ),
            libraryDomainStatus(summary: librarySummary),
            recentTaskDomainStatus(summary: operationSummary)
        ]
    }

    private static func homebrewDomainStatus(
        brewStatus: BrewStatus,
        outdatedPackages: [BrewPackage],
        provenance: HomebrewSnapshotProvenance?
    ) -> DashboardDomainStatus {
        if let provenance, !provenance.isAuthoritativeSuccess {
            return DashboardDomainStatus(
                id: "homebrew",
                title: "Homebrew 更新",
                value: provenance.fallbackState == .usingLastSuccessfulSnapshot ? "状态待确认" : "检查失败",
                detail: provenance.detailText,
                severity: provenance.commandStatus == .notRun ? .attention : .warning,
                action: provenance.commandStatus == .notRun ? .checkUpdates : .showSettings(.homebrewService),
                actionTitle: provenance.commandStatus == .notRun ? "检查更新" : "查看可靠性"
            )
        }
        switch brewStatus {
        case .outdated(let count):
            return DashboardDomainStatus(
                id: "homebrew",
                title: "Homebrew 更新",
                value: "\(count) 个普通可升级",
                detail: "普通可升级只统计 Formula 和非自更新 Cask；自更新 Cask 仅作为关注项显示。",
                severity: .warning,
                action: .showUpdates,
                actionTitle: "查看更新"
            )
        case .upToDate:
            return DashboardDomainStatus(
                id: "homebrew",
                title: "Homebrew 更新",
                value: "无普通可升级",
                detail: provenance.map { "最近一次检查没有发现普通可升级项目。 \($0.detailText)" } ?? (outdatedPackages.isEmpty ? "最近一次检查没有发现普通可升级项目。" : "状态已更新，可复核列表。"),
                severity: .clear,
                action: .checkUpdates,
                actionTitle: "重新检查"
            )
        case .idle:
            return DashboardDomainStatus(
                id: "homebrew",
                title: "Homebrew 更新",
                value: "未检查",
                detail: "检查后才能确认今天是否有可升级项目。",
                severity: .attention,
                action: .checkUpdates,
                actionTitle: "检查更新"
            )
        case .error(let message):
            return DashboardDomainStatus(
                id: "homebrew",
                title: "Homebrew 更新",
                value: "检查失败",
                detail: message,
                severity: .critical,
                action: .showSettings(.homebrewService),
                actionTitle: "打开设置"
            )
        }
    }

    private static func runtimeDomainStatus(
        attentionCount: Int,
        maxSeverity: RuntimeIssueSeverity,
        globalToolsSummary: RuntimeGlobalToolsDashboardSummary
    ) -> DashboardDomainStatus {
        let issueSeverity: DashboardSeverity
        if maxSeverity >= .high {
            issueSeverity = .critical
        } else if maxSeverity >= .warning {
            issueSeverity = .warning
        } else {
            issueSeverity = .clear
        }
        let severity = max(issueSeverity, globalToolsSummary.dashboardSeverity)
        let totalAttentionCount = attentionCount + globalToolsSummary.attentionCount
        let detail: String
        if globalToolsSummary.hasAttention {
            detail = "\(globalToolsSummary.dashboardDetail) 打开 Runtime Doctor 查看包名、source 和 checkedAt。"
        } else if attentionCount > 0 {
            detail = "查看 Runtime Doctor，确认 Node / Python / PATH Policy。"
        } else if globalToolsSummary.toolCount > 0 {
            detail = "\(globalToolsSummary.dashboardDetail)。"
        } else {
            detail = "当前没有高优先级 Runtime 事项。"
        }
        let value: String
        if let primaryAttentionItem = globalToolsSummary.primaryAttentionItem, attentionCount == 0 {
            value = primaryAttentionItem.shortTitle
        } else {
            value = totalAttentionCount > 0 ? "\(totalAttentionCount) 项需关注" : "正常"
        }
        return DashboardDomainStatus(
            id: "runtime",
            title: "Runtime 环境",
            value: value,
            detail: detail,
            severity: severity,
            action: globalToolsSummary.primaryAttentionItem.map { .showRuntimeGlobalTool($0.id) } ?? .showRuntime,
            actionTitle: "查看 Runtime"
        )
    }

    private static func libraryDomainStatus(summary: LibrarySummary) -> DashboardDomainStatus {
        DashboardDomainStatus(
            id: "library",
            title: "酒窖清点",
            value: summary.attentionCount > 0 ? "\(summary.attentionCount) 项" : "无待清点",
            detail: "版本差异 \(summary.repoDiffCount) · 自更新 \(summary.autoUpdatesCount) · 酒窖大小未知 \(summary.sizeUnknownCount) · 叶子包 \(summary.leafCount)",
            severity: summary.hasAttentionItems ? .attention : .clear,
            action: summary.firstAttentionFilter.map { .showLibrary($0) },
            actionTitle: summary.hasAttentionItems ? "查看清点" : nil
        )
    }

    private static func recentTaskDomainStatus(summary: BrewOperationSummary?) -> DashboardDomainStatus {
        guard let summary else {
            return DashboardDomainStatus(
                id: "recent-task",
                title: "最近任务",
                value: "暂无记录",
                detail: "执行检查、升级、安装或清理后会显示最近结果。",
                severity: .clear,
                action: nil,
                actionTitle: nil
            )
        }
        let severity: DashboardSeverity
        switch summary.status {
        case .running: severity = .attention
        case .succeeded: severity = .clear
        case .failed: severity = .critical
        case .cancelled: severity = .attention
        }
        return DashboardDomainStatus(
            id: "recent-task",
            title: "最近任务",
            value: summary.compactRecapText,
            detail: summary.recommendedNextAction ?? summary.summaryText,
            severity: severity,
            action: nil,
            actionTitle: nil
        )
    }
}

struct DashboardRiskSummaryPresentation: Equatable, Sendable {
    let visibleItems: [DashboardActionItem]
    let hiddenCount: Int

    nonisolated init(items: [DashboardActionItem], isExpanded: Bool, compactLimit: Int = 2) {
        if isExpanded {
            self.visibleItems = items
            self.hiddenCount = 0
        } else {
            self.visibleItems = Array(items.prefix(compactLimit))
            self.hiddenCount = max(items.count - compactLimit, 0)
        }
    }
}
