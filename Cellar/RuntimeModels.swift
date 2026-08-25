import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

enum RuntimeKind: String, Sendable, CaseIterable, Codable {
    case node
    case python

    var displayName: String {
        switch self {
        case .node: return "Node"
        case .python: return "Python"
        }
    }

    var reportStem: String {
        switch self {
        case .node: return "Node-Runtime"
        case .python: return "Python-Runtime"
        }
    }
}

enum RuntimeProvider: String, Sendable {
    case homebrew = "Homebrew-managed"
    case nvm = "Shell-managed by nvm"
    case fnm = "Shell-managed by fnm"
    case volta = "Shell-managed by Volta"
    case pyenv = "Shell-managed by pyenv"
    case conda = "Managed by conda"
    case officialPkg = "Official pkg"
    case legacyManual = "Legacy manual install"
    case embedded = "Embedded in app bundle"
    case system = "System"
    case unknown = "Unknown"
}

typealias RuntimeSourceKind = RuntimeProvider

enum RuntimeHealth: String, Sendable {
    case healthy = "Healthy"
    case warning = "Warning"
    case conflict = "Conflict"

    var color: Color {
        switch self {
        case .healthy: return .green
        case .warning: return .orange
        case .conflict: return .red
        }
    }

    var symbol: String {
        switch self {
        case .healthy: return "checkmark.shield"
        case .warning: return "exclamationmark.triangle"
        case .conflict: return "xmark.octagon"
        }
    }
}

enum RuntimeIssueSeverity: Int, Comparable, Sendable, Codable {
    case info = 0
    case warning = 1
    case high = 2

    static func < (lhs: RuntimeIssueSeverity, rhs: RuntimeIssueSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .info: return "Normal"
        case .warning: return "Watch"
        case .high: return "High"
        }
    }

    var color: Color {
        switch self {
        case .info: return .secondary
        case .warning: return .orange
        case .high: return .red
        }
    }

    var symbol: String {
        switch self {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .high: return "exclamationmark.octagon"
        }
    }
}

struct RuntimeInstallation: Identifiable, Hashable, Sendable {
    let path: String
    let resolvedPath: String
    let version: String
    let source: RuntimeSourceKind
    let pathPriority: Int?
    let isActive: Bool
    let health: RuntimeHealth
    let note: String

    var id: String { path }
    var priorityLabel: String { pathPriority.map { "#\($0 + 1)" } ?? "-" }
    var statusLabel: String {
        if isActive { return "当前生效" }
        switch health {
        case .healthy: return "健康"
        case .warning: return "观察"
        case .conflict: return "冲突"
        }
    }
}

struct RuntimeExecutableSnapshot: Hashable, Sendable {
    let name: String
    let version: String?
    let path: String?
    let provider: RuntimeProvider
}

struct RuntimePackageManagerSnapshot: Hashable, Sendable {
    let identifier: String
    let displayName: String
    let guiVersion: String?
    let guiPath: String?
    let loginShellVersion: String?
    let loginShellPath: String?
    let prefix: String?
    let globalBinPath: String?
    let globalRootPath: String?
    let shellToolCount: Int?

    var id: String { identifier }
}

struct RuntimePathSnapshot: Hashable, Sendable {
    let guiEntries: [String]
    let loginShellEntries: [String]
}

enum RuntimeLatestCheckState: Hashable, Sendable {
    case notChecked(source: String)
    case failed(reason: String, source: String, checkedAt: Date)
    case missingLatest(source: String, checkedAt: Date)
    case upToDate(version: String, source: String, checkedAt: Date)
    case outdated(current: String, latest: String, source: String, checkedAt: Date)

    var latestVersion: String? {
        switch self {
        case .upToDate(let version, _, _):
            return version
        case .outdated(_, let latest, _, _):
            return latest
        case .notChecked, .failed, .missingLatest:
            return nil
        }
    }

    var isOutdated: Bool {
        if case .outdated = self { return true }
        return false
    }

    var source: String {
        switch self {
        case .notChecked(let source),
             .failed(_, let source, _),
             .missingLatest(let source, _),
             .upToDate(_, let source, _),
             .outdated(_, _, let source, _):
            return source
        }
    }

    var checkedAt: Date? {
        switch self {
        case .notChecked:
            return nil
        case .failed(_, _, let checkedAt),
             .missingLatest(_, let checkedAt),
             .upToDate(_, _, let checkedAt),
             .outdated(_, _, _, let checkedAt):
            return checkedAt
        }
    }

    var displayText: String {
        switch self {
        case .notChecked:
            return "未查询 registry"
        case .failed:
            return "查询失败"
        case .missingLatest:
            return "没有 latest 字段"
        case .upToDate(let version, _, _):
            return "已是最新版 \(version)"
        case .outdated(_, let latest, _, _):
            return "可更新到 \(latest)"
        }
    }

    var helpText: String {
        switch self {
        case .notChecked(let source):
            return "来源：\(source)。尚未执行 registry 查询。下一步：刷新 Runtime Doctor；如长期未查询，请查看诊断报告确认包管理器路径。"
        case .failed(let reason, let source, let checkedAt):
            return "来源：\(source)；检查时间：\(Self.format(checkedAt))。查询 registry 失败：\(reason)。下一步：检查网络、代理或 registry 设置后刷新 Runtime Doctor。"
        case .missingLatest(let source, let checkedAt):
            return "来源：\(source)；检查时间：\(Self.format(checkedAt))。registry 查询成功，但该条目没有 latest 字段。下一步：查看包页面或诊断报告确认该工具是否发布 latest。"
        case .upToDate(let version, let source, let checkedAt):
            return "来源：\(source)；检查时间：\(Self.format(checkedAt))。当前版本 \(version) 与 latest 一致。"
        case .outdated(let current, let latest, let source, let checkedAt):
            return "来源：\(source)；检查时间：\(Self.format(checkedAt))。当前版本 \(current)，latest 为 \(latest)。下一步：可通过当前 npm 更新该工具。"
        }
    }

    var reportSummary: String {
        switch self {
        case .notChecked(let source):
            return "not checked via \(source)"
        case .failed(let reason, let source, let checkedAt):
            return "failed via \(source) at \(Self.format(checkedAt)): \(reason)"
        case .missingLatest(let source, let checkedAt):
            return "missing latest via \(source) at \(Self.format(checkedAt))"
        case .upToDate(let version, let source, let checkedAt):
            return "up to date \(version) via \(source) at \(Self.format(checkedAt))"
        case .outdated(let current, let latest, let source, let checkedAt):
            return "outdated \(current) -> \(latest) via \(source) at \(Self.format(checkedAt))"
        }
    }

    nonisolated private static func format(_ date: Date) -> String {
        date.formatted(date: .numeric, time: .shortened)
    }
}

struct RuntimeTrustedPathUnion: Equatable, Sendable {
    static let currentSessionActionID = "runtime.session.align-minimal-trusted-union"

    let displayEntries: [String]
    let processEntries: [String]
    let includedRuntimeKinds: [RuntimeKind]

    init(snapshots: [RuntimeSnapshot]) {
        let orderedSnapshots = RuntimeKind.allCases.compactMap { kind in
            snapshots.first(where: { $0.kind == kind })
        }
        let systemDefaults = Self.systemDefaultEntries
        var entries: [String] = []

        for snapshot in orderedSnapshots {
            entries.append(contentsOf: snapshot.minimalTrustedPathEntries.filter { !systemDefaults.contains($0) })
            if snapshot.kind == .python, let pythonToolBinPath = snapshot.pythonToolBinPath {
                entries.append(Self.displayPath(pythonToolBinPath))
            }
        }

        if !entries.isEmpty || orderedSnapshots.contains(where: { !$0.minimalTrustedPathEntries.isEmpty }) {
            entries.append(contentsOf: systemDefaults)
        }

        self.displayEntries = Self.uniqueStable(entries.filter { !$0.isEmpty })
        self.processEntries = displayEntries.map(Self.processPath(_:))
        self.includedRuntimeKinds = orderedSnapshots.map(\.kind)
    }

    var isEmpty: Bool { processEntries.isEmpty }
    var displayPathValue: String { displayEntries.joined(separator: ":") }
    var processPathValue: String { processEntries.joined(separator: ":") }

    var exportCommand: String? {
        guard !displayEntries.isEmpty else { return nil }
        return "export PATH=\"\(displayPathValue)\""
    }

    var runtimeNames: String {
        includedRuntimeKinds.map(\.displayName).joined(separator: " / ")
    }

    var scopeDescription: String {
        if runtimeNames.isEmpty {
            return "当前会话 PATH 是 Cellar 进程全局共享状态。"
        }
        return "当前会话 PATH 是 Cellar 进程全局共享状态；本次 union 同时服务 \(runtimeNames)。"
    }

    var repairHistoryDetail: String {
        "\(scopeDescription) 已按 Minimal Trusted PATH 合并可信入口，避免后一次运行时对齐移除另一种运行时所需 bin。"
    }

    var rollbackNote: String {
        "当前会话 union PATH 只作用于本次 Cellar 进程；重启 Cellar 即可回滚。Cellar 不会静默写入 shell 配置。"
    }

    var verificationActionIDs: [String] {
        includedRuntimeKinds.map { "\($0.rawValue).align-current-session" } + [Self.currentSessionActionID]
    }

    nonisolated private static var systemDefaultEntries: [String] {
        ["/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    }

    nonisolated private static func displayPath(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "$HOME")
    }

    nonisolated private static func processPath(_ path: String) -> String {
        path.replacingOccurrences(of: "$HOME", with: NSHomeDirectory())
    }

    nonisolated private static func uniqueStable(_ entries: [String]) -> [String] {
        var seen = Set<String>()
        return entries.filter { seen.insert($0).inserted }
    }
}

struct RuntimeToolEntry: Identifiable, Hashable, Sendable {
    let name: String
    let currentVersion: String
    let latestCheckState: RuntimeLatestCheckState
    let binaries: [String]
    let installLocation: String
    let prefix: String
    let managedByCurrentRuntime: Bool
    let sourceLabel: String
    let shellPath: String?
    let guiPath: String?
    let isVisibleInShell: Bool
    let isVisibleInGUI: Bool
    let hasNameConflict: Bool
    let statusNote: String

    var id: String { name }
    var latestVersion: String? { latestCheckState.latestVersion }
    var isOutdated: Bool { latestCheckState.isOutdated }
}

typealias RuntimeGlobalPackage = RuntimeToolEntry

enum RuntimeGlobalToolAttentionStatusKind: Int, Hashable, Sendable {
    case outdated = 0
    case failed = 1
    case notChecked = 2
    case missingLatest = 3
    case upToDate = 4

    var displayName: String {
        switch self {
        case .outdated: return "可更新"
        case .failed: return "查询失败"
        case .notChecked: return "未查询"
        case .missingLatest: return "缺 latest"
        case .upToDate: return "已是最新版"
        }
    }

    var attentionRank: Int {
        switch self {
        case .outdated: return 0
        case .failed: return 1
        case .notChecked: return 2
        case .missingLatest: return 3
        case .upToDate: return 4
        }
    }
}

struct RuntimeGlobalToolAttentionItem: Identifiable, Hashable, Sendable {
    static let staleInterval: TimeInterval = 24 * 60 * 60

    let runtimeKind: RuntimeKind
    let toolName: String
    let currentVersion: String
    let latestOrStatusText: String
    let source: String
    let checkedAt: Date?
    let statusKind: RuntimeGlobalToolAttentionStatusKind
    let isStale: Bool
    let detailText: String
    let helpText: String

    var id: String { "\(runtimeKind.rawValue):\(toolName)" }

    var displayStatusText: String {
        switch statusKind {
        case .outdated:
            return isStale ? "上次发现可更新，待复核" : "可更新"
        case .failed:
            return isStale ? "上次查询失败，待复核" : "查询失败"
        case .notChecked:
            return "未查询"
        case .missingLatest:
            return isStale ? "上次缺 latest，待复核" : "缺 latest"
        case .upToDate:
            return isStale ? "上次已是最新版，待复核" : "已是最新版"
        }
    }

    var shortTitle: String {
        switch statusKind {
        case .outdated:
            return isStale ? "上次发现 \(toolName) 可更新，待复核" : "\(toolName) 可更新"
        case .failed:
            return isStale ? "\(toolName) 上次查询失败，待复核" : "\(toolName) 查询失败"
        case .notChecked:
            return "\(toolName) 未查询"
        case .missingLatest:
            return isStale ? "\(toolName) 上次缺 latest，待复核" : "\(toolName) 缺 latest"
        case .upToDate:
            return isStale ? "\(toolName) 上次已是最新版，待复核" : "\(toolName) 已是最新版"
        }
    }

    static func make(
        runtimeKind: RuntimeKind,
        package: RuntimeGlobalPackage,
        referenceDate: Date = Date()
    ) -> RuntimeGlobalToolAttentionItem? {
        switch package.latestCheckState {
        case .outdated(let current, let latest, let source, let checkedAt):
            let stale = Self.isStale(checkedAt: checkedAt, referenceDate: referenceDate)
            let checkedText = Self.format(checkedAt)
            return RuntimeGlobalToolAttentionItem(
                runtimeKind: runtimeKind,
                toolName: package.name,
                currentVersion: current,
                latestOrStatusText: latest,
                source: source,
                checkedAt: checkedAt,
                statusKind: .outdated,
                isStale: stale,
                detailText: "\(package.name)：当前 \(current)，latest \(latest)；来源 \(source)，检查时间 \(checkedText)。",
                helpText: stale
                    ? "上次检查已超过 24 小时，建议先刷新 Runtime Doctor 复核；Runtime 全局工具不会进入 Homebrew 普通升级。"
                    : "这是 Runtime / 开发环境关注项，不是 Homebrew 普通升级目标；如需处理，请在对应包管理器中手动复核。"
            )
        case .failed(let reason, let source, let checkedAt):
            let stale = Self.isStale(checkedAt: checkedAt, referenceDate: referenceDate)
            let checkedText = Self.format(checkedAt)
            return RuntimeGlobalToolAttentionItem(
                runtimeKind: runtimeKind,
                toolName: package.name,
                currentVersion: package.currentVersion,
                latestOrStatusText: reason,
                source: source,
                checkedAt: checkedAt,
                statusKind: .failed,
                isStale: stale,
                detailText: "\(package.name)：当前 \(package.currentVersion)；\(source) 查询失败：\(reason)；检查时间 \(checkedText)。",
                helpText: "下一步：检查网络、代理或 registry 设置后刷新 Runtime Doctor；该失败不会生成 Homebrew 更新候选。"
            )
        case .notChecked(let source):
            return RuntimeGlobalToolAttentionItem(
                runtimeKind: runtimeKind,
                toolName: package.name,
                currentVersion: package.currentVersion,
                latestOrStatusText: "尚未查询 registry",
                source: source,
                checkedAt: nil,
                statusKind: .notChecked,
                isStale: false,
                detailText: "\(package.name)：当前 \(package.currentVersion)；来源 \(source)，尚未执行 latest 查询。",
                helpText: "下一步：刷新 Runtime Doctor；如长期未查询，请确认包管理器路径和 registry 设置。"
            )
        case .missingLatest(let source, let checkedAt):
            let stale = Self.isStale(checkedAt: checkedAt, referenceDate: referenceDate)
            let checkedText = Self.format(checkedAt)
            return RuntimeGlobalToolAttentionItem(
                runtimeKind: runtimeKind,
                toolName: package.name,
                currentVersion: package.currentVersion,
                latestOrStatusText: "registry 未返回 latest",
                source: source,
                checkedAt: checkedAt,
                statusKind: .missingLatest,
                isStale: stale,
                detailText: "\(package.name)：当前 \(package.currentVersion)；来源 \(source) 未返回 latest 字段，检查时间 \(checkedText)。",
                helpText: stale
                    ? "上次检查已超过 24 小时，建议刷新 Runtime Doctor 后再判断。"
                    : "registry 查询成功但缺少 latest 字段；可查看包页面或导出诊断报告复核。"
            )
        case .upToDate:
            return nil
        }
    }

    static func sorted(_ items: [RuntimeGlobalToolAttentionItem]) -> [RuntimeGlobalToolAttentionItem] {
        items.sorted { lhs, rhs in
            if lhs.statusKind.attentionRank != rhs.statusKind.attentionRank {
                return lhs.statusKind.attentionRank < rhs.statusKind.attentionRank
            }
            if lhs.runtimeKind.rawValue != rhs.runtimeKind.rawValue {
                return lhs.runtimeKind.rawValue < rhs.runtimeKind.rawValue
            }
            return lhs.toolName.localizedCaseInsensitiveCompare(rhs.toolName) == .orderedAscending
        }
    }

    private static func isStale(checkedAt: Date, referenceDate: Date) -> Bool {
        referenceDate.timeIntervalSince(checkedAt) > staleInterval
    }

    nonisolated private static func format(_ date: Date) -> String {
        date.formatted(date: .numeric, time: .shortened)
    }
}

struct RuntimeGlobalToolStatusGroup: Identifiable, Hashable, Sendable {
    let statusKind: RuntimeGlobalToolAttentionStatusKind
    let packages: [RuntimeGlobalPackage]

    var id: String { statusKind.displayName }
    var title: String { statusKind.displayName }
    var count: Int { packages.count }
    var toolNames: [String] { packages.map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending } }
    var summaryText: String {
        guard !toolNames.isEmpty else { return "无" }
        return toolNames.joined(separator: "、")
    }

    static func make(packages: [RuntimeGlobalPackage]) -> [RuntimeGlobalToolStatusGroup] {
        RuntimeGlobalToolAttentionStatusKind.allDisplayKinds.compactMap { kind in
            let matching = packages.filter { package in
                package.latestCheckState.globalToolStatusKind == kind
            }
            guard !matching.isEmpty else { return nil }
            return RuntimeGlobalToolStatusGroup(
                statusKind: kind,
                packages: matching.sorted { lhs, rhs in
                    lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
            )
        }
    }
}

private extension RuntimeGlobalToolAttentionStatusKind {
    static var allDisplayKinds: [RuntimeGlobalToolAttentionStatusKind] {
        [.outdated, .failed, .notChecked, .missingLatest, .upToDate]
    }
}

private extension RuntimeLatestCheckState {
    var globalToolStatusKind: RuntimeGlobalToolAttentionStatusKind {
        switch self {
        case .outdated: return .outdated
        case .failed: return .failed
        case .notChecked: return .notChecked
        case .missingLatest: return .missingLatest
        case .upToDate: return .upToDate
        }
    }
}

struct RuntimeGlobalToolsDashboardSummary: Hashable, Sendable {
    struct RuntimeBreakdown: Hashable, Sendable {
        let kind: RuntimeKind
        let toolCount: Int
        let outdatedCount: Int
        let latestCheckFailedCount: Int
        let notCheckedCount: Int
        let missingLatestCount: Int
        let sources: [String]
        let latestCheckedAt: Date?
    }

    let runtimeBreakdowns: [RuntimeBreakdown]
    let attentionItems: [RuntimeGlobalToolAttentionItem]

    static let empty = RuntimeGlobalToolsDashboardSummary(runtimeBreakdowns: [], attentionItems: [])

    static func make(snapshots: [RuntimeSnapshot], referenceDate: Date = Date()) -> RuntimeGlobalToolsDashboardSummary {
        let attentionItems = RuntimeGlobalToolAttentionItem.sorted(
            snapshots.flatMap { snapshot in
                snapshot.globalPackages.compactMap { package in
                    RuntimeGlobalToolAttentionItem.make(
                        runtimeKind: snapshot.kind,
                        package: package,
                        referenceDate: referenceDate
                    )
                }
            }
        )
        let breakdowns = RuntimeKind.allCases.compactMap { kind -> RuntimeBreakdown? in
            guard let snapshot = snapshots.first(where: { $0.kind == kind }) else { return nil }
            let packages = snapshot.globalPackages
            guard !packages.isEmpty else {
                return RuntimeBreakdown(
                    kind: kind,
                    toolCount: 0,
                    outdatedCount: 0,
                    latestCheckFailedCount: 0,
                    notCheckedCount: 0,
                    missingLatestCount: 0,
                    sources: [],
                    latestCheckedAt: nil
                )
            }
            return RuntimeBreakdown(
                kind: kind,
                toolCount: packages.count,
                outdatedCount: packages.filter(\.latestCheckState.isOutdated).count,
                latestCheckFailedCount: packages.filter { package in
                    if case .failed = package.latestCheckState { return true }
                    return false
                }.count,
                notCheckedCount: packages.filter { package in
                    if case .notChecked = package.latestCheckState { return true }
                    return false
                }.count,
                missingLatestCount: packages.filter { package in
                    if case .missingLatest = package.latestCheckState { return true }
                    return false
                }.count,
                sources: Self.uniqueStable(packages.map(\.latestCheckState.source)),
                latestCheckedAt: packages.compactMap(\.latestCheckState.checkedAt).max()
            )
        }
        return RuntimeGlobalToolsDashboardSummary(runtimeBreakdowns: breakdowns, attentionItems: attentionItems)
    }

    var toolCount: Int { runtimeBreakdowns.reduce(0) { $0 + $1.toolCount } }
    var outdatedCount: Int { runtimeBreakdowns.reduce(0) { $0 + $1.outdatedCount } }
    var latestCheckFailedCount: Int { runtimeBreakdowns.reduce(0) { $0 + $1.latestCheckFailedCount } }
    var notCheckedCount: Int { runtimeBreakdowns.reduce(0) { $0 + $1.notCheckedCount } }
    var missingLatestCount: Int { runtimeBreakdowns.reduce(0) { $0 + $1.missingLatestCount } }
    var latestCheckedAt: Date? { runtimeBreakdowns.compactMap(\.latestCheckedAt).max() }
    var sources: [String] { Self.uniqueStable(runtimeBreakdowns.flatMap(\.sources)) }

    var attentionCount: Int {
        outdatedCount + latestCheckFailedCount + notCheckedCount + missingLatestCount
    }

    var hasAttention: Bool { !attentionItems.isEmpty }
    var primaryAttentionItem: RuntimeGlobalToolAttentionItem? { attentionItems.first }

    var dashboardSeverity: DashboardSeverity {
        if outdatedCount > 0 || latestCheckFailedCount > 0 { return .warning }
        if notCheckedCount > 0 || missingLatestCount > 0 { return .attention }
        return .clear
    }

    var dashboardValue: String {
        guard toolCount > 0 else { return "未发现全局工具" }
        if let primaryAttentionItem { return primaryAttentionItem.shortTitle }
        if outdatedCount > 0 { return "\(outdatedCount) 个工具可更新" }
        if latestCheckFailedCount > 0 { return "\(latestCheckFailedCount) 个查询失败" }
        if notCheckedCount > 0 { return "\(notCheckedCount) 个未查询" }
        if missingLatestCount > 0 { return "\(missingLatestCount) 个缺少 latest" }
        return "\(toolCount) 个工具已复核"
    }

    var dashboardDetail: String {
        guard toolCount > 0 else {
            return "Runtime Doctor 暂未检测到 npm / pip / uv tool 全局工具入口。"
        }
        var parts = ["全局工具 \(toolCount) 个"]
        if outdatedCount > 0 { parts.append("可更新 \(outdatedCount)") }
        if latestCheckFailedCount > 0 { parts.append("查询失败 \(latestCheckFailedCount)") }
        if notCheckedCount > 0 { parts.append("未查询 \(notCheckedCount)") }
        if missingLatestCount > 0 { parts.append("缺 latest \(missingLatestCount)") }
        if !sources.isEmpty { parts.append("来源 \(sources.joined(separator: ", "))") }
        if let latestCheckedAt {
            parts.append("最近检查 \(Self.format(latestCheckedAt))")
        }
        if let primaryAttentionItem {
            parts.append(primaryAttentionItem.detailText)
        }
        if attentionItems.count > 1 {
            parts.append("另有 \(attentionItems.count - 1) 项需关注")
        }
        return parts.joined(separator: " · ")
    }

    var actionTitle: String {
        if let primaryAttentionItem {
            switch primaryAttentionItem.statusKind {
            case .outdated: return "查看可更新工具"
            case .failed: return "查看查询失败"
            case .notChecked: return "查看未查询工具"
            case .missingLatest: return "查看缺 latest"
            case .upToDate: return "查看 Runtime Doctor"
            }
        }
        return "查看 Runtime Doctor"
    }

    var actionItemTitle: String {
        if let primaryAttentionItem { return "Runtime 全局工具：\(primaryAttentionItem.shortTitle)" }
        if outdatedCount > 0 { return "Runtime 全局工具有 \(outdatedCount) 个可更新" }
        if latestCheckFailedCount > 0 { return "Runtime 全局工具最新版查询失败 \(latestCheckFailedCount) 个" }
        if notCheckedCount > 0 { return "Runtime 全局工具尚未查询 \(notCheckedCount) 个" }
        if missingLatestCount > 0 { return "Runtime 全局工具缺少 latest 信息 \(missingLatestCount) 个" }
        return "Runtime 全局工具已复核"
    }

    var actionItemDetail: String {
        if let primaryAttentionItem {
            return "\(primaryAttentionItem.detailText)\(attentionItems.count > 1 ? " 另有 \(attentionItems.count - 1) 项需关注。" : "") \(primaryAttentionItem.helpText) 这些属于 Runtime / 开发环境关注事项，不进入 Homebrew 普通升级。"
        }
        return "\(dashboardDetail)。这些属于 Runtime / 开发环境关注事项，不进入 Homebrew 普通升级。"
    }

    var reportLines: [String] {
        var lines = [
            "- Total tools: \(toolCount)",
            "- Outdated tools: \(outdatedCount)",
            "- Latest check failed: \(latestCheckFailedCount)",
            "- Not checked: \(notCheckedCount)",
            "- Missing latest: \(missingLatestCount)"
        ]
        if !sources.isEmpty {
            lines.append("- Sources: \(sources.joined(separator: ", "))")
        }
        if let latestCheckedAt {
            lines.append("- Latest checked at: \(Self.format(latestCheckedAt))")
        }
        if !attentionItems.isEmpty {
            lines.append("- Attention details:")
            for item in attentionItems {
                lines.append("  - \(item.runtimeKind.displayName) \(item.toolName): \(item.displayStatusText); current \(item.currentVersion); latest/status \(item.latestOrStatusText); source \(item.source); checked at \(item.checkedAt.map(Self.format) ?? "not checked")")
            }
        }
        if runtimeBreakdowns.isEmpty {
            lines.append("- Runtime breakdown: No Runtime Doctor snapshot available.")
        } else {
            for item in runtimeBreakdowns {
                lines.append("- \(item.kind.displayName): tools \(item.toolCount), outdated \(item.outdatedCount), failed \(item.latestCheckFailedCount), not checked \(item.notCheckedCount), missing latest \(item.missingLatestCount)")
                if !item.sources.isEmpty {
                    lines.append("  Sources: \(item.sources.joined(separator: ", "))")
                }
                if let latestCheckedAt = item.latestCheckedAt {
                    lines.append("  Checked at: \(Self.format(latestCheckedAt))")
                }
            }
        }
        lines.append("- Scope: Runtime global tools are dashboard attention items only; they are not Homebrew outdated candidates or ordinary upgrade targets.")
        return lines
    }

    private static func uniqueStable(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    nonisolated private static func format(_ date: Date) -> String {
        date.formatted(date: .numeric, time: .shortened)
    }
}

struct RuntimeIssue: Identifiable, Hashable, Sendable {
    let title: String
    let currentState: String
    let explanation: String
    let recommendation: String
    let severity: RuntimeIssueSeverity

    var id: String { "\(severity.rawValue):\(title):\(currentState)" }
}

struct RuntimeSnapshot: Sendable {
    let kind: RuntimeKind
    let activeExecutable: RuntimeExecutableSnapshot?
    let loginShellExecutable: RuntimeExecutableSnapshot?
    let guiExecutable: RuntimeExecutableSnapshot?
    let packageManagers: [RuntimePackageManagerSnapshot]
    let pathSnapshot: RuntimePathSnapshot
    let installations: [RuntimeInstallation]
    let toolEntries: [RuntimeToolEntry]
    let issues: [RuntimeIssue]
    let pathPolicy: RuntimePATHPolicy
    let reportMarkdown: String

    private var primaryPackageManager: RuntimePackageManagerSnapshot? {
        packageManagers.first
    }

    var runtimeDisplayName: String { kind.displayName }
    var pathPolicyOptions: [RuntimePATHPolicy] { RuntimePATHPolicyCatalog.policies(for: self) }

    var primaryPackageManagerDisplayName: String {
        primaryPackageManager?.displayName ?? "包管理器"
    }

    var isObservationOnly: Bool { kind == .python }
    var supportsPackageActions: Bool { kind == .node }
    var supportsAlignmentActions: Bool { kind == .node }

    var activeNodeVersion: String? { guiExecutable?.version }
    var activeNodePath: String? { guiExecutable?.path }
    var activeNodeSource: RuntimeSourceKind { guiExecutable?.provider ?? .unknown }
    var loginNodeVersion: String? { loginShellExecutable?.version }
    var activeNpmVersion: String? { primaryPackageManager?.guiVersion }
    var activeNpmPath: String? { primaryPackageManager?.guiPath }
    var loginNpmPath: String? { primaryPackageManager?.loginShellPath }
    var loginNpmVersion: String? { primaryPackageManager?.loginShellVersion }
    var npmPrefix: String? { primaryPackageManager?.prefix }
    var globalBinPath: String? { primaryPackageManager?.globalBinPath }
    var globalRootPath: String? { primaryPackageManager?.globalRootPath }
    var guiPathEntries: [String] { pathSnapshot.guiEntries }
    var loginPathEntries: [String] { pathSnapshot.loginShellEntries }
    var loginNodePath: String? { loginShellExecutable?.path }
    var runtimes: [RuntimeInstallation] { installations }
    var globalPackages: [RuntimeGlobalPackage] { toolEntries }
    var shellGlobalPackageCount: Int? { primaryPackageManager?.shellToolCount }

    var outdatedPackageCount: Int { globalPackages.filter(\.isOutdated).count }
    var recommendedUserPrefixPath: String {
        switch kind {
        case .node:
            return NSString(string: "~/.npm-global").expandingTildeInPath
        case .python:
            return NSString(string: "~/.local").expandingTildeInPath
        }
    }

    var preferredRuntimeDirectoryPath: String? {
        guard let path = loginNodePath ?? activeNodePath else { return nil }
        return URL(fileURLWithPath: path).deletingLastPathComponent().path
    }

    var pythonToolBinPath: String? {
        packageManagers.first(where: { $0.globalBinPath != nil && ["pip", "python-module-pip", "uv", "pipx"].contains($0.identifier) })?.globalBinPath
    }

    var hasPyenvManager: Bool {
        runtimes.contains(where: { $0.source == .pyenv }) || packageManagers.contains(where: { $0.identifier == "pyenv" && ($0.guiPath != nil || $0.loginShellPath != nil) })
    }

    var hasCondaManager: Bool {
        runtimes.contains(where: { $0.source == .conda }) || packageManagers.contains(where: { $0.identifier == "conda" && ($0.guiPath != nil || $0.loginShellPath != nil) })
    }

    var pyenvShimsPath: String? {
        let expanded = NSString(string: "~/.pyenv/shims").expandingTildeInPath
        if loginPathEntries.contains(expanded) || guiPathEntries.contains(expanded) || hasPyenvManager {
            return expanded
        }
        return nil
    }

    var preferredPythonShellCommand: String {
        if let loginNodePath {
            let name = URL(fileURLWithPath: loginNodePath).lastPathComponent
            if name.hasPrefix("python") { return name }
        }
        if let activeNodePath {
            let name = URL(fileURLWithPath: activeNodePath).lastPathComponent
            if name.hasPrefix("python") { return name }
        }
        return "python3"
    }

    var preferredPythonModulePipCommand: String {
        "\(preferredPythonShellCommand) -m pip"
    }

    var environmentHealth: RuntimeHealth {
        let maxSeverity = issues.map(\.severity).max() ?? .info
        switch maxSeverity {
        case .info: return .healthy
        case .warning: return .warning
        case .high: return .conflict
        }
    }

    var environmentHeadline: String {
        if issues.contains(where: { $0.title.contains("Legacy") }) { return "发现旧安装" }
        if issues.contains(where: { $0.title.contains("PATH") }) { return "PATH 冲突" }
        if issues.contains(where: { $0.title.contains("multiple") || $0.title.contains("Mixed") }) { return "多来源混用" }
        switch environmentHealth {
        case .healthy: return "环境健康"
        case .warning: return "需要关注"
        case .conflict: return "存在冲突"
        }
    }

    var dashboardHeadline: String {
        switch environmentHealth {
        case .healthy: return "健康"
        case .warning: return "需关注"
        case .conflict: return "存在冲突"
        }
    }

    var dashboardVersionLine: String {
        let versionText = loginNodeVersion ?? activeNodeVersion ?? "未发现"
        let providerText = recommendedRuntimeSource
        return "\(runtimeDisplayName) \(versionText) · \(providerText)"
    }

    var dashboardExplanationLine: String {
        if activeNodePath == nil, loginNodePath != nil {
            return "Shell 可用，GUI 尚未接入同一环境。"
        }
        if activeNodePath != nil, loginNodePath != nil, activeNodePath != loginNodePath {
            return "GUI 与 Shell 存在策略性差异，但核心运行时已可见。"
        }
        if activeNodePath != nil || loginNodePath != nil {
            return "当前运行时来源与可见性已经明确。"
        }
        return "当前还没有发现可用的 \(runtimeDisplayName) 主环境。"
    }

    var dashboardToolSummary: String {
        if kind == .python {
            let shellCount = toolEntries.filter(\.isVisibleInShell).count
            let guiCount = toolEntries.filter(\.isVisibleInGUI).count
            return "Shell \(shellCount) / GUI \(guiCount)"
        }
        if let shellGlobalPackageCount {
            return "Shell \(shellGlobalPackageCount) / GUI \(globalPackages.count)"
        }
        return "GUI \(globalPackages.count)"
    }

    var activeNodeStatus: RuntimeHealth {
        guard activeNodePath != nil else { return .conflict }
        if issues.contains(where: { $0.severity == .high }) { return .conflict }
        if issues.contains(where: { $0.severity == .warning }) { return .warning }
        return .healthy
    }

    var shellEnvironmentLine: String {
        loginNodePath != nil ? "Shell 环境：正常" : "Shell 环境：未发现 \(runtimeDisplayName)"
    }

    var guiEnvironmentLine: String {
        if activeNodePath != nil, loginNodePath != nil, activeNodePath == loginNodePath {
            return "GUI 环境：已继承同一运行时"
        }
        if activeNodePath != nil {
            return "GUI 环境：可访问 \(runtimeDisplayName)，但与终端不完全一致"
        }
        if loginNodePath != nil {
            return "GUI 环境：未继承 PATH"
        }
        return "GUI 环境：未发现 \(runtimeDisplayName)"
    }

    var runtimeEnvironmentHeadline: String {
        if activeNodePath == nil, loginNodePath != nil { return "终端可用，GUI 未接入" }
        if activeNodePath != nil, loginNodePath != nil, activeNodePath == loginNodePath { return "\(runtimeDisplayName) 环境已对齐" }
        if activeNodePath != nil { return "GUI 已接入 \(runtimeDisplayName)" }
        return "尚未发现可用 \(runtimeDisplayName)"
    }

    var environmentExplanationLine: String {
        if activeNodePath == nil, loginNodePath != nil {
            return "当前 \(runtimeDisplayName) 可在终端使用，但 Cellar 没有接入同一环境。"
        }
        if activeNodePath != nil, loginNodePath != nil, activeNodePath != loginNodePath {
            return "GUI 与 Shell 采用了不同路径策略，但核心运行时都已可见。"
        }
        return "当前运行时与路径策略已经清晰，可继续查看包与 prefix 状态。"
    }

    var primarySuggestion: String {
        if kind == .python, activeNodePath == nil, loginNodePath != nil { return "状态：以 Shell 为准" }
        if activeNodePath == nil, loginNodePath != nil { return "建议：统一环境" }
        if issues.contains(where: { $0.severity == .high || $0.severity == .warning }) { return "建议：查看诊断" }
        return "状态：正常"
    }

    var npmHeadline: String {
        let packageLabel = primaryPackageManagerDisplayName
        if activeNpmPath == nil, loginNpmPath != nil || loginNodePath != nil { return "终端可用，GUI 未接入" }
        if activeNpmPath != nil, loginNpmPath != nil, activeNpmPath == loginNpmPath { return "\(packageLabel) 环境已对齐" }
        if activeNpmPath != nil { return "GUI 已接入 \(packageLabel)" }
        return "尚未发现可用 \(packageLabel)"
    }

    var npmObservationLine: String {
        if activeNpmPath != nil {
            return "GUI 视角：\(activeNpmVersion ?? "已接入")"
        }
        if loginNpmPath != nil {
            return "GUI 视角：未发现；终端视角：\(loginNpmVersion ?? "可用")"
        }
        if loginNodePath != nil {
            return "GUI 视角：未发现；终端视角：跟随 \(runtimeDisplayName) 环境"
        }
        return "GUI 视角：未发现"
    }

    var npmExplanationLine: String {
        if activeNpmPath == nil, loginNpmPath != nil {
            return "\(primaryPackageManagerDisplayName) 在终端中可用，但 Cellar 没有继承到同一环境。"
        }
        if activeNpmPath == nil, loginNodePath != nil {
            return "终端里的 \(runtimeDisplayName) 已可用，\(primaryPackageManagerDisplayName) 大概率也跟随同一环境；只是 Cellar 当前 GUI 进程还没有接入。"
        }
        if activeNpmPath != nil, loginNpmPath != nil, activeNpmPath != loginNpmPath {
            return "GUI 与终端正在使用不同的 \(primaryPackageManagerDisplayName)。"
        }
        return "当前 \(primaryPackageManagerDisplayName) 可由 Cellar 直接观察和管理。"
    }

    var packageManagerHeadline: String { npmHeadline }
    var packageManagerObservationLine: String { npmObservationLine }
    var packageManagerExplanationLine: String { npmExplanationLine }

    var globalPackagesHeadline: String {
        if kind == .python {
            if toolEntries.isEmpty { return "尚未发现 Python 工具入口" }
            if toolEntries.contains(where: { $0.isVisibleInShell && !$0.isVisibleInGUI }) {
                return "终端里的工具未全部接入 GUI"
            }
            return "Python 工具入口已接入"
        }
        if globalPackages.isEmpty, let shellGlobalPackageCount, shellGlobalPackageCount > 0 {
            return "GUI 未接入全局包视角"
        }
        if globalPackages.isEmpty, loginNodePath != nil, activeNodePath == nil {
            return "终端环境可能存在全局包"
        }
        return "GUI 视角已接入全局包"
    }

    var globalPackagesObservationLine: String {
        if kind == .python {
            let guiCount = toolEntries.filter(\.isVisibleInGUI).count
            let shellCount = toolEntries.filter(\.isVisibleInShell).count
            return "GUI 视角：\(guiCount) 个；终端视角：\(shellCount) 个"
        }
        if let shellGlobalPackageCount, shellGlobalPackageCount != globalPackages.count {
            return "GUI 视角：\(globalPackages.count) 个；终端视角：\(shellGlobalPackageCount) 个"
        }
        if shellGlobalPackageCount == nil, loginNodePath != nil, activeNodePath == nil {
            return "GUI 视角：\(globalPackages.count) 个；终端视角：跟随 \(runtimeDisplayName) 环境"
        }
        return "GUI 视角：\(globalPackages.count) 个"
    }

    var globalPackagesExplanationLine: String {
        if kind == .python {
            return "这里显示的是 Python 全局工具入口，而不是项目依赖包；重点是命令来自哪套来源、是否在 PATH 里、是否与当前主 Python 协同。"
        }
        if globalPackages.isEmpty, let shellGlobalPackageCount, shellGlobalPackageCount > 0 {
            return "终端里存在全局包，但 Cellar 当前 GUI 环境没有接入同一 npm 作用域。"
        }
        if globalPackages.isEmpty, loginNodePath != nil, activeNodePath == nil {
            return "终端里的全局包很可能存在，只是 Cellar 当前 GUI 环境还没有接入对应的 npm 作用域。"
        }
        return "这里显示的是 Cellar 当前 GUI 环境实际能观察到的全局包。"
    }

    var toolEntriesHeadline: String { globalPackagesHeadline }
    var toolEntriesObservationLine: String {
        if kind == .python { return globalPackagesObservationLine }
        return globalPackagesObservationLine
    }
    var toolEntriesExplanationLine: String {
        if kind == .python {
            return "当前阶段开始列出 Python 全局工具入口，帮助判断同名命令来自 `pipx`、`uv tool`、Homebrew 还是未知来源。"
        }
        return globalPackagesExplanationLine
    }

    var recommendedRuntimeTitle: String {
        loginNodePath != nil ? "Shell 环境（推荐）" : "尚未选出主运行时"
    }

    var recommendedRuntimeVersion: String {
        loginNodeVersion ?? activeNodeVersion ?? "未发现"
    }

    var recommendedRuntimeSource: String {
        if let loginNodePath, let match = runtimes.first(where: { $0.path == loginNodePath || $0.resolvedPath == loginNodePath }) {
            return match.source.rawValue
        }
        return activeNodeSource.rawValue
    }

    var recommendedRuntimeReason: String {
        if loginNodePath != nil {
            return "终端环境是当前机器上最稳定、最接近日常命令行为的真实运行环境。"
        }
        return "当前还没有找到足以作为主环境的 Shell 运行时。"
    }

    var guiRuntimeTitle: String {
        if activeNodePath == nil, loginNodePath != nil { return "未接入 Shell PATH" }
        if activeNodePath != nil, loginNodePath != nil, activeNodePath != loginNodePath { return "与 Shell 不一致" }
        if activeNodePath != nil { return "可用" }
        return "不可用"
    }

    var guiRuntimeExplanation: String {
        if activeNodePath == nil, loginNodePath != nil {
            return "仅影响 GUI 应用视角，不代表系统里的 \(runtimeDisplayName) 或 \(primaryPackageManagerDisplayName) 不可用。"
        }
        if activeNodePath != nil, loginNodePath != nil, activeNodePath != loginNodePath {
            return "GUI 已具备运行所需核心路径，但不会完整复制 Shell 的全部 PATH。"
        }
        return "Cellar 已接入当前运行时，可继续查看包、prefix 与路径策略。"
    }

    var guiPathMissingEntries: [String] {
        loginPathEntries.filter { !guiPathEntries.contains($0) }
    }

    var guiPathExtraEntries: [String] {
        guiPathEntries.filter { !loginPathEntries.contains($0) }
    }

    var minimalTrustedPathEntries: [String] {
        stablePathEntries
    }

    private var stablePathEntries: [String] {
        let homebrewNodeDir = "/opt/homebrew/bin"
        let homebrewSbinDir = "/opt/homebrew/sbin"
        let userToolCandidates = [
            "~/.local/bin",
            "~/.cargo/bin"
        ].map { NSString(string: $0).expandingTildeInPath }
        let systemDefaults = [
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]

        var result: [String] = []
        if kind == .python,
           let runtimeDir = preferredRuntimeDirectoryPath,
           !runtimeDir.isEmpty {
            result.append(runtimeDir.replacingOccurrences(of: NSHomeDirectory(), with: "$HOME"))
        }
        if kind == .python, let pyenvShimsPath {
            result.append(pyenvShimsPath.replacingOccurrences(of: NSHomeDirectory(), with: "$HOME"))
        }
        if loginPathEntries.contains(homebrewNodeDir) || runtimes.contains(where: { $0.source == .homebrew }) {
            result.append(homebrewNodeDir)
        }
        if loginPathEntries.contains(homebrewSbinDir) {
            result.append(homebrewSbinDir)
        }
        switch kind {
        case .node:
            result.append("$HOME/.npm-global/bin")
        case .python:
            if let pythonToolBinPath {
                result.append(pythonToolBinPath.replacingOccurrences(of: NSHomeDirectory(), with: "$HOME"))
            }
            if packageManagers.contains(where: { $0.globalBinPath?.contains(".local/bin") == true || $0.displayName == "uv" || $0.displayName == "pipx" }) {
                result.append("$HOME/.local/bin")
            }
        }

        for candidate in userToolCandidates where loginPathEntries.contains(candidate) {
            result.append(candidate.replacingOccurrences(of: NSHomeDirectory(), with: "$HOME"))
        }

        result.append(contentsOf: systemDefaults)

        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }

    var trustedGuiPathValue: String {
        stablePathEntries.joined(separator: ":")
    }

    var trustedGuiPathValueForProcess: String {
        stablePathEntries
            .map { $0.replacingOccurrences(of: "$HOME", with: NSHomeDirectory()) }
            .joined(separator: ":")
    }

    var persistentPathCommand: String? {
        guard !stablePathEntries.isEmpty else { return nil }
        return "launchctl setenv PATH \"\(trustedGuiPathValue)\""
    }

    var mirrorShellPathCommand: String? {
        guard !loginPathEntries.isEmpty else { return nil }
        let joined = loginPathEntries.joined(separator: ":")
        return "launchctl setenv PATH \"\(joined)\""
    }

    var mirrorShellPathExportCommand: String? {
        guard !loginPathEntries.isEmpty else { return nil }
        return "export PATH=\"\(loginPathEntries.joined(separator: ":"))\""
    }

    var currentSessionValidationCommand: String? {
        let patchEntries = sessionValidationPathEntries
        guard !patchEntries.isEmpty else { return nil }
        return "export PATH=\"\(patchEntries.joined(separator: ":")):$PATH\""
    }

    var suggestedShellConfigFile: String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        if shell.contains("zsh") {
            return "~/.zprofile"
        }
        if shell.contains("bash") {
            return "~/.bash_profile"
        }
        return "~/.profile"
    }

    var shellPatchSnippet: String {
        [
            "# Cellar runtime alignment",
            currentSessionValidationCommand ?? "export PATH=\"/opt/homebrew/bin:/opt/homebrew/sbin:$HOME/.npm-global/bin:$PATH\""
        ].joined(separator: "\n")
    }

    var guiRollbackCommand: String {
        "launchctl unsetenv PATH"
    }

    var sharedPathScopeTitle: String {
        "当前会话 PATH 为 Cellar 全局共享"
    }

    var sharedPathScopeExplanation: String {
        "“最小可信对齐”会更新 Cellar 当前进程的全局 PATH。当前策略会合并 Node / Python 的可信入口，避免后一次对齐移除另一种运行时所需路径。"
    }

    var sessionAlignmentRollbackNote: String {
        kind == .python ? "当前会话对齐只作用于本次 Cellar 进程；重启 Cellar 即可恢复。" : "如需撤销当前会话中的环境对齐，可重新启动 Cellar。"
    }

    var needsCurrentSessionAlignment: Bool {
        activeNodePath == nil && loginNodePath != nil
    }

    var needsPersistentGuiAlignment: Bool {
        if kind != .node { return false }
        return activeNodePath == nil && loginNodePath != nil || guiPathEntries != loginPathEntries
    }

    var needsNpmPrefixRepair: Bool {
        if kind != .node { return false }
        guard let npmPrefix else { return false }
        return npmPrefix.hasPrefix("/usr/local")
    }

    var needsShellPathPatch: Bool {
        if kind != .node { return false }
        guard let globalBinPath else { return false }
        return !loginPathEntries.contains(globalBinPath)
    }

    var needsPythonUserBinPatch: Bool {
        if kind != .python { return false }
        guard let pythonToolBinPath else { return false }
        return !loginPathEntries.contains(pythonToolBinPath)
    }

    var needsPythonPipGuidance: Bool {
        if kind != .python { return false }
        return issues.contains(where: {
            $0.title.contains("`pip` 与当前 Python") || $0.title.contains("默认 pip 不同")
        })
    }

    var needsPyenvOrderGuidance: Bool {
        if kind != .python || !hasPyenvManager { return false }
        guard let pyenvShimsPath else { return false }
        guard let pyenvIndex = loginPathEntries.firstIndex(of: pyenvShimsPath),
              let homebrewIndex = loginPathEntries.firstIndex(of: "/opt/homebrew/bin") else {
            return false
        }
        return pyenvIndex > homebrewIndex
    }

    var needsCondaBaseGuidance: Bool {
        if kind != .python { return false }
        return issues.contains(where: { $0.title.contains("conda base") })
    }

    var supportsGuidedRepairs: Bool {
        kind == .node || kind == .python
    }

    var fixSummary: [String] {
        if kind == .python {
            var items: [String] = []
            if needsCurrentSessionAlignment {
                items.append("让 Cellar 当前会话接入 Node / Python 最小可信 union PATH")
            }
            if needsPythonUserBinPatch {
                items.append("把 \(pythonToolBinPath ?? "$HOME/.local/bin") 补进 \(suggestedShellConfigFile)")
            }
            if needsPythonPipGuidance {
                items.append("把安装命令切换为 \(preferredPythonModulePipCommand)")
            }
            if needsPyenvOrderGuidance {
                items.append("确认 pyenv shims 是否应排在 Homebrew 之前")
            }
            if needsCondaBaseGuidance {
                items.append("检查 conda base 是否应继续自动激活")
            }
            return items
        }
        var items: [String] = []
        if needsPersistentGuiAlignment {
            items.append("为 GUI 会话写入最小可信 PATH")
        }
        if needsNpmPrefixRepair {
            items.append("把 npm 全局 prefix 切到用户目录")
        }
        if needsShellPathPatch {
            items.append("把 \(globalBinPath ?? "$HOME/.npm-global/bin") 补进 \(suggestedShellConfigFile)")
        }
        return items
    }

    var fixGuidanceLines: [String] {
        if kind == .python {
            var lines: [String] = []
            if needsCurrentSessionAlignment {
                lines.append("当前会话：可点击“最小可信对齐”，让 Cellar 当前会话的全局 PATH 接入 Node / Python 的最小可信入口。")
                lines.append("回滚方式：\(sessionAlignmentRollbackNote)")
            }
            if needsPythonUserBinPatch {
                lines.append("Shell PATH：将下面这段补丁写入 \(suggestedShellConfigFile)。")
                lines.append(shellPatchSnippet)
                let expandedConfigFile = NSString(string: suggestedShellConfigFile).expandingTildeInPath
                lines.append("写入后执行：source \(expandedConfigFile)")
                lines.append("或者直接关闭并重新打开终端。")
                if packageManagers.contains(where: { $0.identifier == "pipx" && ($0.loginShellPath != nil || $0.guiPath != nil) }) {
                    lines.append("如果你主要依赖 pipx，也可以先执行：pipx ensurepath")
                    lines.append("回滚方式：从 \(suggestedShellConfigFile) 中移除对应 PATH 补丁。")
                }
            }
            if needsPythonPipGuidance {
                lines.append("安装命令：优先使用 \(preferredPythonModulePipCommand) install <package>，避免 `pip` 指到另一套环境。")
                lines.append("回滚方式：无需回滚；这是安装命令选择策略，而不是环境改写。")
            }
            if needsPyenvOrderGuidance {
                lines.append("pyenv：如果你希望 pyenv 作为主来源，请确认 `~/.pyenv/shims` 在 Homebrew 之前，并保留 `eval \"$(pyenv init -)\"`。")
                lines.append("核对命令：which -a python3")
                lines.append("回滚方式：移除或调整你刚写入的 pyenv 初始化片段。")
            }
            if needsCondaBaseGuidance {
                lines.append("conda：如果你不希望 base 环境默认抢占 Python，可执行：conda config --set auto_activate_base false")
                lines.append("回滚命令：conda config --set auto_activate_base true")
            }
            return lines
        }
        var lines: [String] = []
        if needsPersistentGuiAlignment {
            lines.append("GUI 环境：可点击“持久化 GUI 环境”，或先复制 GUI 修复命令自行执行。")
        }
        if needsNpmPrefixRepair {
            lines.append("npm prefix：可点击“修复 npm prefix”，把全局目录切到 \(recommendedUserPrefixPath)。")
        }
        if needsShellPathPatch {
            lines.append("Shell PATH：将下面这段补丁写入 \(suggestedShellConfigFile)。")
            lines.append(shellPatchSnippet)
            let expandedConfigFile = NSString(string: suggestedShellConfigFile).expandingTildeInPath
            lines.append("写入后执行：source \(expandedConfigFile)")
            lines.append("或者直接关闭并重新打开终端。")
        }
        return lines
    }

    var preferredPrimaryRuntime: RuntimeInstallation? {
        if let loginNodePath {
            return runtimes.first(where: { $0.path == loginNodePath || $0.resolvedPath == loginNodePath })
        }
        return runtimes.first(where: \.isActive) ?? runtimes.first
    }

    var governanceHeadline: String {
        guard let preferredPrimaryRuntime else { return "尚未确定主要运行时来源" }
        switch preferredPrimaryRuntime.source {
        case .homebrew:
            return "Homebrew 适合作为主要来源"
        case .nvm, .fnm, .volta:
            return "当前应以 shell 级版本管理器为准"
        case .pyenv:
            return "当前应以 pyenv 管理的 Python 为准"
        case .conda:
            return "当前应把 conda 看作独立主来源"
        case .legacyManual, .officialPkg:
            return "旧式安装不适合作为主要来源"
        case .system:
            return "系统自带运行时不适合作为主要来源"
        case .embedded:
            return "应用私有运行时不应成为主要来源"
        case .unknown:
            return "建议先确认当前主要来源归属"
        }
    }

    var governanceExplanation: String {
        guard let preferredPrimaryRuntime else {
            return "当前还没有足够稳定的主要来源，暂时更适合先观察与核对路径。"
        }
        switch preferredPrimaryRuntime.source {
        case .homebrew:
            return "Homebrew 路径稳定、可升级，也更适合作为长期默认来源。"
        case .nvm, .fnm, .volta:
            return "当前 \(runtimeDisplayName) 由 shell 级版本管理器控制，Cellar 会优先解释状态并辅助操作。"
        case .pyenv:
            return "pyenv 会通过 shims 控制默认 Python，Cellar 当前阶段只负责解释它与 GUI 的关系。"
        case .conda:
            return "conda 往往同时影响解释器、PATH 和 base 激活，当前阶段先把它当作独立来源观察。"
        case .legacyManual, .officialPkg:
            return "这类安装通常会占据 /usr/local，容易与 Homebrew 或用户级 prefix 混用。"
        case .system:
            return "系统路径通常只是保底存在，不适合作为开发环境的长期默认来源。"
        case .embedded:
            return "应用内置 runtime 只应该服务该应用本身，不应参与全局 PATH 竞争。"
        case .unknown:
            return "来源未明时，更适合先把路径和来源澄清，再决定后续处理方式。"
        }
    }

    var governanceSourceCommand: String? {
        guard let preferredPrimaryRuntime else { return nil }
        switch preferredPrimaryRuntime.source {
        case .homebrew, .legacyManual, .officialPkg, .system, .unknown:
            return nil
        case .nvm:
            return "nvm use \(preferredPrimaryRuntime.version)"
        case .fnm:
            return "fnm use \(preferredPrimaryRuntime.version.replacingOccurrences(of: "v", with: ""))"
        case .volta:
            return "volta install node@\(preferredPrimaryRuntime.version.replacingOccurrences(of: "v", with: ""))"
        case .pyenv:
            return "pyenv shell \(preferredPrimaryRuntime.version.replacingOccurrences(of: "Python ", with: ""))"
        case .conda:
            return "conda activate <your-env>"
        case .embedded:
            return nil
        }
    }

    var legacyRuntimeCandidates: [RuntimeInstallation] {
        runtimes.filter {
            !$0.isActive && ($0.source == .legacyManual || $0.source == .officialPkg || $0.source == .system)
        }
    }

    var governancePlanLines: [String] {
        var lines: [String] = [governanceHeadline]
        if let preferredPrimaryRuntime {
            lines.append("主来源：\(preferredPrimaryRuntime.version) · \(preferredPrimaryRuntime.path)")
        }
        if !legacyRuntimeCandidates.isEmpty {
            lines.append("旧来源候选：\(legacyRuntimeCandidates.map(\.path).joined(separator: "、"))")
        }
        if kind == .python && needsPythonUserBinPatch {
            lines.append("建议把 \(pythonToolBinPath ?? "~/.local/bin") 写入 \(suggestedShellConfigFile)")
        }
        if kind == .python && needsPythonPipGuidance {
            lines.append("建议优先使用 \(preferredPythonModulePipCommand) 处理安装与升级")
        }
        if needsShellPathPatch {
            lines.append("建议把 \(globalBinPath ?? "~/.npm-global/bin") 写入 \(suggestedShellConfigFile)")
        }
        return lines
    }

    var legacyCleanupCommandBlock: String {
        guard !legacyRuntimeCandidates.isEmpty else {
            return "# 当前没有需要额外提示的 legacy 运行时清理对象"
        }
        var lines = ["# 先确认这些路径是否仍在参与 PATH 竞争"]
        if kind == .python {
            lines.append("which -a python3")
            lines.append("which -a pip")
        } else {
            lines.append("which -a node")
            lines.append("which -a npm")
        }
        for runtime in legacyRuntimeCandidates {
            let dir = URL(fileURLWithPath: runtime.path).deletingLastPathComponent().path
            lines.append("# 如需退出竞争，先从 shell 配置中移除 \(dir)")
        }
        if legacyRuntimeCandidates.contains(where: { $0.resolvedPath.hasPrefix("/usr/local/") || $0.path.hasPrefix("/usr/local/") }) {
            lines.append("# 最后才考虑手动清理旧链接，确认无依赖后再执行")
            if kind == .python {
                lines.append("ls -l /usr/local/bin/python3 /usr/local/bin/pip3")
            } else {
                lines.append("ls -l /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx")
            }
        }
        return lines.joined(separator: "\n")
    }

    var pythonRepairCommandBlock: String {
        guard kind == .python else { return "" }
        var lines: [String] = []
        if let command = currentSessionValidationCommand {
            lines.append("# 当前会话验证")
            lines.append(command)
        }
        if needsPythonPipGuidance {
            lines.append("# 跟随当前 Python 安装")
            lines.append("\(preferredPythonModulePipCommand) install <package>")
        }
        if packageManagers.contains(where: { $0.identifier == "pipx" && ($0.loginShellPath != nil || $0.guiPath != nil) }) {
            lines.append("# 让 pipx 补齐用户级工具入口")
            lines.append("pipx ensurepath")
        }
        if needsCondaBaseGuidance {
            lines.append("# 关闭 conda base 自动激活")
            lines.append("conda config --set auto_activate_base false")
            lines.append("# 回滚")
            lines.append("conda config --set auto_activate_base true")
        }
        if needsPyenvOrderGuidance {
            lines.append("# 核对 pyenv shims 与 Homebrew 的顺序")
            lines.append("which -a python3")
        }
        return lines.joined(separator: "\n")
    }

    private var shellPatchEntries: [String] {
        var result: [String] = []
        if stablePathEntries.contains("/opt/homebrew/bin") {
            result.append("/opt/homebrew/bin")
        }
        if stablePathEntries.contains("/opt/homebrew/sbin") {
            result.append("/opt/homebrew/sbin")
        }
        if stablePathEntries.contains("$HOME/.npm-global/bin") {
            result.append("$HOME/.npm-global/bin")
        }
        for candidate in ["$HOME/.local/bin", "$HOME/.cargo/bin"] where stablePathEntries.contains(candidate) {
            result.append(candidate)
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }

    private var sessionValidationPathEntries: [String] {
        var result: [String] = []
        if kind == .python, let runtimeDir = preferredRuntimeDirectoryPath {
            result.append(runtimeDir.replacingOccurrences(of: NSHomeDirectory(), with: "$HOME"))
        }
        if kind == .python, let pyenvShimsPath {
            result.append(pyenvShimsPath.replacingOccurrences(of: NSHomeDirectory(), with: "$HOME"))
        }
        result.append(contentsOf: shellPatchEntries)
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }
}
