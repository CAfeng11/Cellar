import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

// MARK: - GLOBAL HELPERS
@MainActor struct WindowOpener { static var open: (() -> Void)?; static var openSettings: (() -> Void)? }
enum CellarWindowCopy {
    static let mainWindowTitle = "Cellar 主窗口"
    static let settingsWindowTitle = "偏好设置"
    static let openMainWindow = "打开主窗口"
    static let openSettings = "打开偏好设置"
    static let openSettingsCommand = "偏好设置..."
}
struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let message: String
    let type: LogType

    enum LogType: Equatable {
        case info, command, success, failure, stream

        var color: Color {
            switch self {
            case .info: return .secondary
            case .command: return .blue
            case .success: return .green
            case .failure: return .red
            case .stream: return .primary
            }
        }

        var displayName: String {
            switch self {
            case .info: return "提示"
            case .command: return "命令"
            case .success: return "完成"
            case .failure: return "失败"
            case .stream: return "输出"
            }
        }
    }

    var summaryText: String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("$ export path=") {
            return "已生成当前会话 PATH 验证命令"
        }
        if lower.hasPrefix("$ brew update") {
            return "正在更新 Homebrew 仓库元数据"
        }
        if lower.hasPrefix("$ brew ") {
            return "正在执行 Homebrew 命令"
        }
        if lower.contains("zsh completions") || lower.contains("bash completions") || lower.contains("fish completions") {
            return "Homebrew 正在处理 shell completions"
        }
        if lower.contains("export path=") {
            return "运行时 PATH 命令已生成"
        }
        if type == .stream, trimmed.count > 96 {
            return String(trimmed.prefix(96)) + "..."
        }
        return trimmed
    }

    var hasRawDetail: Bool {
        summaryText != message.trimmingCharacters(in: .whitespacesAndNewlines)
            || type == .command
            || type == .stream
    }
}
enum AppTab: String, CaseIterable, Identifiable { case dashboard = "仪表盘"; case library = "我的酒窖"; case runtime = "运行时诊断"; var id: String { rawValue } }
extension BrewStatus { var badgeCount: Int { if case .outdated(let c) = self { return c }; return 0 } }
extension Notification.Name { static let runtimeRefreshRequested = Notification.Name("cellar.runtime.refreshRequested") }
class AppDelegate: NSObject, NSApplicationDelegate { func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { if !flag { Task { @MainActor in WindowOpener.open?(); NSApp.activate(ignoringOtherApps: true) } }; return true } }

enum MainContentLayout {
    static let scrollEndPadding: CGFloat = 16
    static let logPanelHeight: CGFloat = 180
    static let footerStatusBarMinHeight: CGFloat = 44
}

enum DashboardScrollLayout {
    static func topMaxHeight(totalHeight: CGFloat, showsPackageTable: Bool) -> CGFloat? {
        guard showsPackageTable else { return nil }
        if totalHeight < 360 {
            return max(96, totalHeight * 0.42)
        }
        return min(260, max(132, totalHeight * 0.44))
    }

    static func packageTableMinHeight(totalHeight: CGFloat) -> CGFloat {
        if totalHeight < 360 {
            return max(96, totalHeight * 0.36)
        }
        return min(220, max(140, totalHeight * 0.38))
    }
}

// MARK: - APP STATE
@MainActor
final class AppState: ObservableObject {
    let settings = SettingsStore()

    @Published var activeTab: AppTab = .dashboard
    @Published var status: BrewStatus = .idle
    enum Activity: Equatable {
        case idle, checking, cleaning, fetchingInfo, loadingLibrary
        case upgrading(String), uninstalling(String), pinning(String)
        case searching, installing(String), maintaining
        var isBusy: Bool { self != .idle }
        var isSearching: Bool { if case .searching = self { return true } else { return false } }
        var description: String { switch self { case .idle: return ""; case .checking: return "正在检查更新..."; case .upgrading(let n): return "正在升级 \(n)..."; case .uninstalling(let n): return "正在卸载 \(n)..."; case .pinning(let n): return "正在更新锁定状态 \(n)..."; case .cleaning: return "正在清理缓存..."; case .fetchingInfo: return "正在获取信息..."; case .loadingLibrary: return "正在清点酒窖..."; case .searching: return "正在搜索..."; case .installing(let n): return "正在安装 \(n)..."; case .maintaining: return "正在执行自动维护..." } }
    }
    @Published var activity: Activity = .idle
    @Published var outdatedPackages: [BrewPackage] = []
    @Published var installedPackages: [BrewPackage] = []
    @Published var installedNameSet: Set<String> = []
    @Published var logs: [LogEntry] = []
    @Published var searchText: String = ""
    @Published var filterType: PackageType? = nil
    @Published var showPinnedOnly: Bool = false
    @Published var showLeavesOnly: Bool = false
    @Published var packageStateFilter: PackageStateFilterKey? = nil
    @Published var showLogSheet: Bool = false
    @Published var showUpgradeConfirmation: Bool = false
    @Published var showGreedySyncConfirmation: Bool = false
    @Published var showUninstallConfirmation: Bool = false
    @Published var showInfoSheet: Bool = false
    @Published var selectedPackage: BrewPackage?
    @Published var selectedGreedySyncPackage: BrewPackage?
    @Published var selectedInfo: BrewInfo?
    @Published var lastCheckTime: Date?
    @Published var lastLibraryRefreshAt: Date?
    @Published var lastBrewUpdateAt: Date? { didSet { if let d = lastBrewUpdateAt { UserDefaults.standard.set(d, forKey: "lastBrewUpdateAt") } } }
    @Published var outdatedSnapshotProvenance: HomebrewSnapshotProvenance = .notCaptured(kind: .outdated)
    @Published var installedSnapshotProvenance: HomebrewSnapshotProvenance = .notCaptured(kind: .installedLibrary)
    @Published var processingID: String? = nil
    @Published var showInstallSheet: Bool = false
    @Published var installSearchText: String = ""
    @Published var searchResults: [BrewSearchItem] = []
    @Published var latestBrewOperationSummary: BrewOperationSummary? {
	        didSet {
	            if let latestBrewOperationSummary {
	                let issue = latestBrewOperationSummary.reliabilityIssue
	                settings.latestReliabilityIssue = issue
	                settings.focusedSection = issue?.settingsSection
	                publishAppEvent(AppEventFactory.event(from: latestBrewOperationSummary))
	            }
	        }
	    }
    @Published private(set) var activeAppEvents: [AppEvent] = []
    @Published private(set) var appEvents: [AppEvent] = []
    @Published var latestAppEvent: AppEvent?

    // --- BEGIN APPEND: AppState Logic C3-R1-STRICT-R2 ---
    @Published var repoDiffCount: Int = 0
    private var sizeProbeTask: Task<Void, Never>?
    private let sizeFormatter: ByteCountFormatter = { let f = ByteCountFormatter(); f.allowedUnits = [.useAll]; f.countStyle = .file; return f }()
    // --- END APPEND: AppState Logic C3-R1-STRICT-R2 ---

    private var mainTask: Task<Void, Never>?
    private var infoTask: Task<Void, Never>?
    private var pinTask: Task<Void, Never>?
    private var libraryTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private var maintenanceLoopTask: Task<Void, Never>?
    private var maintenanceRunTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private let service = BrewService.shared

    var isCoreBusy: Bool { mainTask != nil || infoTask != nil || pinTask != nil || libraryTask != nil || installTask != nil || maintenanceRunTask != nil }
    var isEverythingBusy: Bool { isCoreBusy || searchTask != nil }
    var isPinningUI: Bool { processingID != nil && pinTask != nil }
    var librarySummary: LibrarySummary { LibrarySummary.make(from: installedPackages) }
    var hasFailureEvent: Bool { latestAppEvent?.severity == .failure }
    var ordinaryUpgradePackages: [BrewPackage] {
        PackageUpgradeScope.ordinaryUpgradeCandidates(in: outdatedPackages)
    }
    var autoUpdatingObservationPackages: [BrewPackage] {
        PackageUpgradeScope.autoUpdatingObservationCandidates(in: outdatedPackages)
    }
    var ordinaryUpgradeCount: Int { ordinaryUpgradePackages.count }
    var autoUpdatingObservationCount: Int { autoUpdatingObservationPackages.count }
	    var upgradeConfirmationTitle: String { "确认升级 \(ordinaryUpgradeCount) 个包?" }
	    var upgradeConfirmationMessage: String {
	        let targets = ordinaryUpgradePackages
	        guard !targets.isEmpty else {
	            return autoUpdatingObservationCount > 0
	                ? "当前没有普通可升级项目；\(autoUpdatingObservationCount) 个自更新 Cask 仅作为关注项显示，不会进入普通批量升级。"
	                : "当前没有可升级项目。"
	        }
	        let estimates = targets.map { PackageSizeEstimate.estimate(for: $0, context: .upgradeCandidate) }
	        let sizeSummary = PackageSizeEstimateSummary(estimates: estimates)
	        let lines = targets.prefix(12).map { pkg in
	            let estimate = PackageSizeEstimate.estimate(for: pkg, context: .upgradeCandidate)
	            return "\(pkg.name)：\(pkg.versionDisplay) -> \(pkg.currentVersionDisplay) · \(estimate.confirmationShortText(using: sizeFormatter))"
	        }
	        let suffix = targets.count > 12 ? "\n另有 \(targets.count - 12) 个包未在确认框中展开。" : ""
	        var sections = [
	            "包数量：\(targets.count)",
	            "",
	            "版本变化：",
	            "\(lines.joined(separator: "\n"))\(suffix)",
	            "",
	            "真实下载大小：\(sizeSummary.downloadSummaryText(using: sizeFormatter))",
	            "当前/旧包参考体量：\(sizeSummary.installedReferenceSummaryText(using: sizeFormatter))",
	            "未知大小：\(sizeSummary.unknownSummaryText)",
	            "",
	            "参考体量来自当前已安装旧包，仅作判断体量使用；不代表下载量、升级后大小或升级耗时承诺。大小未知不会阻断升级。"
	        ]
	        if autoUpdatingObservationCount > 0 {
	            sections.append("已排除 \(autoUpdatingObservationCount) 个自更新 Cask；它们由应用内部更新器维护，本次普通批量升级不会处理。")
	        }
	        return sections.joined(separator: "\n")
	    }
    var greedySyncConfirmationTitle: String {
        PackageGreedySyncConfirmation.title(for: selectedGreedySyncPackage)
    }
    var greedySyncConfirmationMessage: String {
        PackageGreedySyncConfirmation.message(for: selectedGreedySyncPackage)
    }

    func openReliabilitySettings(_ section: SettingsReliabilitySection? = nil) {
        if let section {
            settings.focusedSection = section
        } else if let issue = settings.latestReliabilityIssue {
            settings.focusedSection = issue.settingsSection
        }
        WindowOpener.openSettings?()
        NSApp.activate(ignoringOtherApps: true)
    }

    // === BEGIN PATCH BLOCK: MaintenanceInit v2 ===
    // [Intent] Control initial startup refresh based on the auto-maintenance toggle.
    // [Invariants] Skips warm-up task if autoMaintenanceEnabled is false.
    // [Risk] low
    // --- code starts ---
    init() {
        if let saved = UserDefaults.standard.object(forKey: "lastBrewUpdateAt") as? Date { self.lastBrewUpdateAt = saved }
        updateProxyConfig()
        NotificationCenter.default.publisher(for: .settingsIntervalChanged).sink { [weak self] _ in Task { @MainActor [weak self] in self?.addLog("调度配置变更，重启维护任务", type: .info); self?.restartMaintenanceLoop() } }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: .settingsProxyChanged).sink { [weak self] _ in Task { @MainActor [weak self] in self?.updateProxyConfig(); self?.addLog("代理配置已更新", type: .info) } }.store(in: &cancellables)
        startMaintenanceLoop()
        if settings.config.autoMaintenanceEnabled {
            Task { try? await Task.sleep(nanoseconds: 1_000_000_000); await performMaintenance() }
        }
    }
    // --- code ends ---
    // === END PATCH BLOCK: MaintenanceInit v2 ===

    private func updateProxyConfig() {
        let config = settings.config
        var env: [String: String] = [:]
        if config.brewProxyEnabled {
            switch config.proxyProtocol {
            case .http:
                let urlStr = "http://\(config.proxyHost):\(config.proxyPort)"
                env["ALL_PROXY"] = urlStr; env["HTTP_PROXY"] = urlStr; env["HTTPS_PROXY"] = urlStr; env["http_proxy"] = urlStr; env["https_proxy"] = urlStr; env["all_proxy"] = urlStr
            case .socks5:
                let urlStr = "socks5://\(config.proxyHost):\(config.proxyPort)"
                env["ALL_PROXY"] = urlStr; env["all_proxy"] = urlStr
            }
        }
        Task { await service.configureProxy(env: env) }
    }

    var displayPackages: [BrewPackage] {
        let filtered = outdatedPackages.filter { match(pkg: $0) }
        return filtered.sorted { ($0.isPinned != $1.isPinned) ? $0.isPinned : $0.name < $1.name }
    }
    var displayLibrary: [BrewPackage] {
        let filtered = installedPackages.filter { match(pkg: $0) }
        return filtered.sorted { ($0.isPinned != $1.isPinned) ? $0.isPinned : $0.name < $1.name }
    }
    private func match(pkg: BrewPackage) -> Bool {
        let s = searchText.isEmpty || pkg.name.localizedCaseInsensitiveContains(searchText)
        let t = filterType == nil || pkg.type == filterType
        let p = !showPinnedOnly || pkg.isPinned
        let l = !showLeavesOnly || (activeTab == .library ? pkg.isLeaf : true)
        let state = activeTab != .library || packageStateFilter.map { PackageStateDescriptor.contains($0, package: pkg, isLibrary: true) } ?? true
        return s && t && p && l && state
    }
    func applyLibraryStateFilter(_ filter: PackageStateFilterKey?) {
        withAnimation {
            activeTab = .library
            packageStateFilter = filter
            showLeavesOnly = filter == .leaf
            searchText = ""
        }
        let stale = (lastLibraryRefreshAt == nil) || (Date().timeIntervalSince(lastLibraryRefreshAt!) > 600)
        if installedPackages.isEmpty || stale {
            refreshLibrary(silent: !installedPackages.isEmpty)
        }
    }
    @discardableResult
    private func applyOutdatedSnapshot(source: HomebrewSnapshotSource = .brewOutdated) async throws -> [BrewPackage] {
        do {
            let installedTruth = try await installedPackagesForOutdatedTruth()
            async let outTask = service.checkOutdated(); async let pinnedTask = service.getPinnedList()
            let (pkgs, pins) = try await (outTask, pinnedTask)
            let merged = pkgs.map { p -> BrewPackage in var np = p; if pins.contains(p.name) { np.isPinned = true }; return np }
            let reconciled = reconcileOutdatedPackages(merged, using: installedTruth)
            let capturedAt = Date()
            withAnimation {
                self.outdatedPackages = reconciled
                self.status = ordinaryUpgradeStatus(for: reconciled)
                self.lastCheckTime = capturedAt
                self.outdatedSnapshotProvenance = .succeeded(kind: .outdated, source: source, capturedAt: capturedAt)
            }
            self.updateDock(PackageUpgradeScope.ordinaryUpgradeCandidates(in: reconciled).count)
            return reconciled
        } catch {
            recordOutdatedSnapshotFailure(error, source: source)
            throw error
        }
    }

    private func installedPackagesForOutdatedTruth() async throws -> [BrewPackage] {
        if let libraryTask {
            await libraryTask.value
        }

        let isStale = (lastLibraryRefreshAt == nil) || (Date().timeIntervalSince(lastLibraryRefreshAt!) > 600)
        if installedPackages.isEmpty || isStale {
            return try await applyInstalledLibrarySnapshot()
        }

        return installedPackages
    }

    private func reconcileOutdatedPackages(
        _ candidates: [BrewPackage],
        using installedTruth: [BrewPackage]
    ) -> [BrewPackage] {
        let truthMerged = PackageCaskTruthMerger.mergeInstalledCaskTruth(into: candidates, from: installedTruth)
        return PackageSizeReferenceMerger.mergeInstalledSizes(into: truthMerged, from: installedTruth)
    }

    private func ordinaryUpgradeStatus(for packages: [BrewPackage]) -> BrewStatus {
        let count = PackageUpgradeScope.ordinaryUpgradeCandidates(in: packages).count
        return count == 0 ? .upToDate : .outdated(count)
    }

    private func reconcileCurrentOutdatedPackagesWithInstalledTruth() {
        guard !outdatedPackages.isEmpty else { return }
        let reconciled = reconcileOutdatedPackages(outdatedPackages, using: installedPackages)
        let ordinaryCount = PackageUpgradeScope.ordinaryUpgradeCandidates(in: reconciled).count
        withAnimation {
            self.outdatedPackages = reconciled
            self.status = ordinaryCount == 0 ? .upToDate : .outdated(ordinaryCount)
        }
        self.updateDock(ordinaryCount)
    }
    private func scheduleOutdatedSnapshot() {
        snapshotTask?.cancel()
        snapshotTask = Task { @MainActor in
            defer { snapshotTask = nil }
            do {
                try await Task.sleep(nanoseconds: 400 * 1_000_000)
                let deadline = Date().addingTimeInterval(20)
                while mainTask != nil && Date() < deadline { try await Task.sleep(nanoseconds: 200 * 1_000_000) }
                try await applyOutdatedSnapshot()
        } catch is CancellationError { } catch { addLog("后台校准失败: \(error.localizedDescription)", type: .info) }
        }
    }
    private func optimisticRemoveFromOutdated(id: String) {
        withAnimation {
            outdatedPackages.removeAll { $0.id == id }
            let count = ordinaryUpgradeCount
            status = count == 0 ? .upToDate : .outdated(count)
            updateDock(count)
        }
    }
    private func optimisticRemoveEverywhere(pkg: BrewPackage) {
        withAnimation {
            outdatedPackages.removeAll { $0.id == pkg.id }
            installedPackages.removeAll { $0.id == pkg.id }
            installedNameSet.remove(pkg.name.lowercased())
            let count = ordinaryUpgradeCount
            status = count == 0 ? .upToDate : .outdated(count)
            updateDock(count)
        }
    }
    // === BEGIN PATCH BLOCK: MaintenanceControl v1 ===
    // [Intent] Control maintenance task lifecycle including clean teardown and switch gating.
    // [Invariants] restart sets task to nil. start skips if autoMaintenanceEnabled is false.
    // [Risk] low
    // --- code starts ---
    private func restartMaintenanceLoop() {
        maintenanceLoopTask?.cancel()
        maintenanceLoopTask = nil
        startMaintenanceLoop()
    }
    private func startMaintenanceLoop() {
        guard settings.config.autoMaintenanceEnabled else { return }
        let interval = Double(settings.config.refreshIntervalSec)
        maintenanceLoopTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            if Task.isCancelled { return }
            await performMaintenance()
            while !Task.isCancelled {
                let sleepNs = UInt64(interval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: sleepNs)
                if Task.isCancelled { return }
                await performMaintenance()
            }
        }
    }
    // --- code ends ---
    // === END PATCH BLOCK: MaintenanceControl v1 ===
    // === BEGIN PATCH BLOCK: MaintenanceLogic v3 ===
    // [Intent] Perform background maintenance tasks with decoupled update/snapshot logic and failure logging.
    // [Invariants] Brew update runs past threshold. Snapshot runs every tick.
    // [Risk] low
    // --- code starts ---
    private func performMaintenance() async {
        guard maintenanceRunTask == nil else { return }
        let isBusyWithUser = mainTask != nil || infoTask != nil || pinTask != nil || libraryTask != nil || installTask != nil
        guard !isBusyWithUser else { return }
        maintenanceRunTask = Task { @MainActor in
            defer { self.maintenanceRunTask = nil; if case .maintaining = self.activity { self.activity = .idle } }
            let last = lastBrewUpdateAt ?? Date.distantPast
            let threshold = Double(settings.config.updateIntervalSec)
            if Date().timeIntervalSince(last) > threshold {
                withAnimation { activity = .maintaining }; addLog("开始自动维护 (brew update)...", type: .info)
                do {
                    for try await _ in await service.updateTap() { if Task.isCancelled { throw CancellationError() } }
                    self.lastBrewUpdateAt = Date(); addLog("自动维护完成", type: .success)
                } catch {
                    if error is CancellationError { addLog("自动维护已终止", type: .info) }
                    else { addLog("自动维护失败: \(error.localizedDescription)", type: .info) }
                }
            }
            do { try await applyOutdatedSnapshot() } catch {
                if error is CancellationError { addLog("后台刷新已终止", type: .info) }
                else { addLog("后台刷新失败: \(error.localizedDescription)", type: .info) }
            }
        }
        await maintenanceRunTask?.value
    }
    // --- code ends ---
    // === END PATCH BLOCK: MaintenanceLogic v3 ===
    func cancelOperation() {
        if infoTask != nil { infoTask?.cancel(); showInfoSheet = false; return }
        if libraryTask != nil { libraryTask?.cancel(); return }
        if pinTask != nil { pinTask?.cancel(); return }
        if searchTask != nil { searchTask?.cancel(); return }
        if installTask != nil { installTask?.cancel(); return }
        if snapshotTask != nil { snapshotTask?.cancel(); return }
        if maintenanceRunTask != nil { addLog("正在停止自动维护...", type: .info); maintenanceRunTask?.cancel(); return }
        if mainTask != nil { addLog("⛔️ 用户请求中止主任务...", type: .info); mainTask?.cancel(); return }
    }
    func refreshLibrary(silent: Bool = false) {
        guard libraryTask == nil else { return }
        if !silent { withAnimation { activity = .loadingLibrary } }
        libraryTask = Task { @MainActor in
            defer { self.libraryTask = nil; if case .loadingLibrary = self.activity { self.activity = .idle } }
            do {
                try await self.applyInstalledLibrarySnapshot()
            } catch { if !(error is CancellationError) { addLog("加载列表失败: \(error.localizedDescription)", type: .failure) } }
        }
    }

    @discardableResult
    private func applyInstalledLibrarySnapshot() async throws -> [BrewPackage] {
        do {
            let list = try await service.fetchInstalledList()
            let capturedAt = Date()
            withAnimation {
                self.installedPackages = list
                self.installedNameSet = Set(list.map { $0.name.lowercased() })
                self.installedSnapshotProvenance = .succeeded(kind: .installedLibrary, source: .brewInstalledInfo, capturedAt: capturedAt)
            }
            self.lastLibraryRefreshAt = capturedAt
            self.repoDiffCount = PackageStateDescriptor.count(.repoDiff, in: list, isLibrary: true)
            self.fetchAllPackageSizes()
            self.reconcileCurrentOutdatedPackagesWithInstalledTruth()
            return list
        } catch {
            recordInstalledSnapshotFailure(error)
            throw error
        }
    }

    private func recordOutdatedSnapshotFailure(_ error: Error, source: HomebrewSnapshotSource) {
        outdatedSnapshotProvenance = .failed(kind: .outdated, source: source, error: error, previous: outdatedSnapshotProvenance)
    }

    private func recordInstalledSnapshotFailure(_ error: Error) {
        installedSnapshotProvenance = .failed(kind: .installedLibrary, source: .brewInstalledInfo, error: error, previous: installedSnapshotProvenance)
    }

    private func refreshLibrarySnapshotAfterUpgrade() async {
        if let libraryTask {
            await libraryTask.value
        }

        do {
            try await applyInstalledLibrarySnapshot()
        } catch {
            if !(error is CancellationError) {
                addLog("升级后刷新我的酒窖失败: \(error.localizedDescription)", type: .info)
            }
        }
    }
    func refresh(full: Bool = false) {
        guard mainTask == nil else { return }
        let startedAt = Date()
        let operationKind: BrewOperationKind = full ? .updateThenCheck : .checkUpdates
        latestBrewOperationSummary = BrewOperationPlanner.runningSummary(kind: operationKind, startedAt: startedAt)
        withAnimation { self.activity = .checking; self.processingID = nil }
        mainTask = Task { @MainActor in
            defer { self.mainTask = nil; if case .checking = self.activity { self.activity = .idle } }
            do {
                if full {
                    addLog("正在更新 Homebrew 仓库...", type: .command)
                    for try await line in await service.updateTap() { addLog(line, type: .stream) }
                    self.lastBrewUpdateAt = Date()
                }
                try await applyOutdatedSnapshot(source: operationKind == .updateThenCheck ? .brewUpdateThenOutdated : .brewOutdated)
                let ordinaryCount = ordinaryUpgradeCount
                let observationCount = autoUpdatingObservationCount
                let observationSuffix = observationCount > 0 ? "，另有 \(observationCount) 个自更新 Cask 仅作为关注项显示" : ""
                addLog("检查完成，发现 \(ordinaryCount) 个普通可升级项目\(observationSuffix)", type: .success)
                latestBrewOperationSummary = BrewOperationPlanner.refreshFinished(kind: operationKind, startedAt: startedAt, updateCount: ordinaryCount)
            } catch {
                recordOutdatedSnapshotFailure(error, source: operationKind == .updateThenCheck ? .brewUpdateThenOutdated : .brewOutdated)
                latestBrewOperationSummary = BrewOperationPlanner.failureSummary(kind: operationKind, startedAt: startedAt, error: error)
                handleError(error)
            }
        }
    }
    func fetchInfo(for pkg: BrewPackage) {
        infoTask?.cancel(); withAnimation { activity = .fetchingInfo }
        infoTask = Task { @MainActor in
            defer { self.infoTask = nil; if case .fetchingInfo = self.activity { self.activity = .idle } }
            do {
                let info = try await service.getInfo(name: pkg.name)
                if !Task.isCancelled { self.selectedInfo = info; self.showInfoSheet = true }
            } catch { if !(error is CancellationError) { addLog("获取信息失败: \(error.localizedDescription)", type: .failure) } }
        }
    }
    func togglePin(for pkg: BrewPackage) {
        guard pinTask == nil else { return }
        let originalState: Bool = {
            if let i = outdatedPackages.firstIndex(where: { $0.id == pkg.id }) { return outdatedPackages[i].isPinned }
            if let i = installedPackages.firstIndex(where: { $0.id == pkg.id }) { return installedPackages[i].isPinned }
            return pkg.isPinned
        }()
        let targetState = !originalState
        if let i = outdatedPackages.firstIndex(where: { $0.id == pkg.id }) { outdatedPackages[i].isPinned = targetState }
        if let i = installedPackages.firstIndex(where: { $0.id == pkg.id }) { installedPackages[i].isPinned = targetState }
        withAnimation { activity = .pinning(pkg.name); processingID = pkg.id }
        pinTask = Task { @MainActor in
            defer { self.pinTask = nil; self.processingID = nil; if case .pinning(_) = self.activity { self.activity = .idle } }
            addLog("\(targetState ? "锁定" : "解锁") \(pkg.name)...", type: .command)
            do { let stream = await service.pinAction(name: pkg.name, pin: targetState); for try await _ in stream { }; addLog("操作成功", type: .success) } catch { if let i = outdatedPackages.firstIndex(where: { $0.id == pkg.id }) { outdatedPackages[i].isPinned = originalState }; if let i = installedPackages.firstIndex(where: { $0.id == pkg.id }) { installedPackages[i].isPinned = originalState }; addLog("操作失败: \(error.localizedDescription)", type: .failure) }
        }
    }
    func upgrade(pkgs: [BrewPackage]? = nil) {
        guard mainTask == nil else { return }
        let startedAt = Date()
        let requestedPackages = pkgs ?? ordinaryUpgradePackages
        let targetPackages = PackageUpgradeScope.ordinaryUpgradeCandidates(in: requestedPackages)
        guard !targetPackages.isEmpty else { return }
        latestBrewOperationSummary = BrewOperationPlanner.upgradeProgressSummary(
            stage: .preparingUpgrade,
            packages: targetPackages,
            startedAt: startedAt
        )
        let title = pkgs == nil ? "全部" : (pkgs!.count == 1 ? pkgs![0].name : "批量")
        withAnimation { activity = .upgrading(title); processingID = pkgs?.count == 1 ? pkgs![0].id : nil }
        mainTask = Task { @MainActor in
            defer { self.mainTask = nil; self.processingID = nil; if case .upgrading(_) = self.activity { self.activity = .idle } }
            do {
                if let single = pkgs?.first, pkgs?.count == 1 {
                    var args = [single.name]; if single.type == .cask { args.insert("--cask", at: 0) }
                    addLog("开始升级 \(single.name)：brew upgrade \(args.joined(separator: " "))", type: .command)
                    self.latestBrewOperationSummary = BrewOperationPlanner.upgradeProgressSummary(
                        stage: .upgradingPackage,
                        packages: targetPackages,
                        startedAt: startedAt,
                        currentPackage: single,
                        currentPackageIndex: 1
                    )
                    for try await line in await service.upgrade(args: args) { addLog(line, type: .stream) }
                    addLog("升级成功，正在复核可升级列表...", type: .success)
                    self.latestBrewOperationSummary = BrewOperationPlanner.upgradeProgressSummary(
                        stage: .verifyingOutdated,
                        packages: targetPackages,
                        startedAt: startedAt
                    )
                    let finishedSummary: BrewOperationSummary
                    do {
                        let remaining = try await self.applyOutdatedSnapshot()
                        finishedSummary = BrewOperationPlanner.upgradeFinished(
                            startedAt: startedAt,
                            targetPackages: targetPackages,
                            remainingOutdatedPackages: remaining
                        )
                    } catch {
                        finishedSummary = BrewOperationPlanner.upgradeFinished(
                            startedAt: startedAt,
                            targetPackages: targetPackages,
                            remainingOutdatedPackages: self.outdatedPackages,
                            verificationError: error
                        )
                        self.addLog("升级后复核失败: \(error.localizedDescription)", type: .info)
                    }
                    self.latestBrewOperationSummary = BrewOperationPlanner.upgradeProgressSummary(
                        stage: .refreshingLibrary,
                        packages: targetPackages,
                        startedAt: startedAt
                    )
                    await self.refreshLibrarySnapshotAfterUpgrade()
                    self.latestBrewOperationSummary = finishedSummary
                } else {
                    addLog("开始全部升级...", type: .command)
                    self.latestBrewOperationSummary = BrewOperationPlanner.upgradeProgressSummary(
                        stage: .upgradingPackage,
                        packages: targetPackages,
                        startedAt: startedAt
                    )
                    let argumentGroups = PackageUpgradeScope.upgradeArgumentGroups(for: targetPackages)
                    for (index, args) in argumentGroups.enumerated() {
                        addLog("开始批量升级第 \(index + 1)/\(argumentGroups.count) 组：brew upgrade \(args.joined(separator: " "))", type: .command)
                        for try await line in await service.upgrade(args: args) { addLog(line, type: .stream) }
                    }
                    addLog("批量升级流程结束，正在复核可升级列表...", type: .success)
                    self.latestBrewOperationSummary = BrewOperationPlanner.upgradeProgressSummary(
                        stage: .verifyingOutdated,
                        packages: targetPackages,
                        startedAt: startedAt
                    )
                    let finishedSummary: BrewOperationSummary
                    do {
                        let remaining = try await self.applyOutdatedSnapshot()
                        finishedSummary = BrewOperationPlanner.upgradeFinished(
                            startedAt: startedAt,
                            targetPackages: targetPackages,
                            remainingOutdatedPackages: remaining
                        )
                    } catch {
                        finishedSummary = BrewOperationPlanner.upgradeFinished(
                            startedAt: startedAt,
                            targetPackages: targetPackages,
                            remainingOutdatedPackages: self.outdatedPackages,
                            verificationError: error
                        )
                        self.addLog("升级后复核失败: \(error.localizedDescription)", type: .info)
                    }
                    self.latestBrewOperationSummary = BrewOperationPlanner.upgradeProgressSummary(
                        stage: .refreshingLibrary,
                        packages: targetPackages,
                        startedAt: startedAt
                    )
                    await self.refreshLibrarySnapshotAfterUpgrade()
                    self.latestBrewOperationSummary = finishedSummary
                }
            } catch {
                self.latestBrewOperationSummary = BrewOperationPlanner.failureSummary(kind: .upgrade, startedAt: startedAt, packages: targetPackages, error: error)
                handleError(error); self.scheduleOutdatedSnapshot()
            }
        }
    }
    func confirmGreedySync(_ pkg: BrewPackage) {
        guard PackageGreedySyncScope.isEligible(pkg) else { return }
        selectedGreedySyncPackage = pkg
        showGreedySyncConfirmation = true
    }

    func greedySyncSelectedCask() {
        guard let selectedGreedySyncPackage else { return }
        showGreedySyncConfirmation = false
        greedySync(selectedGreedySyncPackage)
    }

    func greedySync(_ pkg: BrewPackage) {
        guard mainTask == nil, PackageGreedySyncScope.isEligible(pkg), let args = PackageGreedySyncScope.upgradeArguments(for: pkg) else { return }
        let startedAt = Date()
        let targetPackages = [pkg]
        latestBrewOperationSummary = BrewOperationPlanner.greedySyncProgressSummary(
            stage: .preparingGreedySync,
            packages: targetPackages,
            startedAt: startedAt,
            currentPackage: pkg
        )
        withAnimation { activity = .upgrading("贪婪同步 \(pkg.name)"); processingID = pkg.id }
        mainTask = Task { @MainActor in
            defer {
                self.mainTask = nil
                self.processingID = nil
                self.selectedGreedySyncPackage = nil
                if case .upgrading(_) = self.activity { self.activity = .idle }
            }
            do {
                addLog("开始贪婪同步 \(pkg.name)：brew upgrade \(args.joined(separator: " "))", type: .command)
                self.latestBrewOperationSummary = BrewOperationPlanner.greedySyncProgressSummary(
                    stage: .syncingCask,
                    packages: targetPackages,
                    startedAt: startedAt,
                    currentPackage: pkg
                )
                for try await line in await service.upgrade(args: args) { addLog(line, type: .stream) }
                addLog("贪婪同步命令结束，正在复核更新关注列表...", type: .success)
                self.latestBrewOperationSummary = BrewOperationPlanner.greedySyncProgressSummary(
                    stage: .verifyingGreedySync,
                    packages: targetPackages,
                    startedAt: startedAt,
                    currentPackage: pkg
                )
                let finishedSummary: BrewOperationSummary
                do {
                    let remaining = try await self.applyOutdatedSnapshot()
                    finishedSummary = BrewOperationPlanner.greedySyncFinished(
                        startedAt: startedAt,
                        targetPackages: targetPackages,
                        remainingOutdatedPackages: remaining
                    )
                } catch {
                    finishedSummary = BrewOperationPlanner.greedySyncFinished(
                        startedAt: startedAt,
                        targetPackages: targetPackages,
                        remainingOutdatedPackages: self.outdatedPackages,
                        verificationError: error
                    )
                    self.addLog("贪婪同步后复核失败: \(error.localizedDescription)", type: .info)
                }
                self.latestBrewOperationSummary = BrewOperationPlanner.greedySyncProgressSummary(
                    stage: .refreshingLibrary,
                    packages: targetPackages,
                    startedAt: startedAt,
                    currentPackage: pkg
                )
                await self.refreshLibrarySnapshotAfterUpgrade()
                self.latestBrewOperationSummary = finishedSummary
            } catch {
                self.latestBrewOperationSummary = BrewOperationPlanner.failureSummary(kind: .greedySyncCask, startedAt: startedAt, packages: targetPackages, error: error)
                handleError(error)
                self.scheduleOutdatedSnapshot()
            }
        }
    }
    func uninstall(_ pkg: BrewPackage) {
        guard mainTask == nil else { return }
        let startedAt = Date()
        latestBrewOperationSummary = BrewOperationPlanner.runningSummary(kind: .uninstall, packages: [pkg], startedAt: startedAt)
        withAnimation { activity = .uninstalling(pkg.name); processingID = pkg.id }
        mainTask = Task { @MainActor in
            defer { self.mainTask = nil; self.processingID = nil; if case .uninstalling(_) = self.activity { self.activity = .idle } }
            addLog("开始卸载 \(pkg.name)...", type: .command)
            do {
                for try await line in await service.uninstall(pkg) { addLog(line, type: .stream) }
                addLog("卸载完成", type: .success)
                self.optimisticRemoveEverywhere(pkg: pkg)
                self.latestBrewOperationSummary = BrewOperationPlanner.finishedSummary(
                    kind: .uninstall,
                    startedAt: startedAt,
                    packages: [pkg],
                    summaryText: "卸载完成：已处理 \(pkg.name)。",
                    recommendedNextAction: "建议刷新“我的酒窖”，确认依赖和可用更新状态。"
                )
                self.scheduleOutdatedSnapshot()
            } catch {
                self.latestBrewOperationSummary = BrewOperationPlanner.failureSummary(kind: .uninstall, startedAt: startedAt, packages: [pkg], error: error)
                handleError(error)
            }
        }
    }
    func runCleanup() {
        guard mainTask == nil else { return }
        let startedAt = Date()
        latestBrewOperationSummary = BrewOperationPlanner.runningSummary(kind: .cleanup, startedAt: startedAt)
        withAnimation { activity = .cleaning }
        mainTask = Task { @MainActor in
            defer { self.mainTask = nil; if case .cleaning = self.activity { self.activity = .idle } }
            addLog("执行 brew cleanup...", type: .command)
            do {
                for try await line in await service.cleanup() { addLog(line, type: .stream) }
                addLog("清理完成", type: .success)
                self.latestBrewOperationSummary = BrewOperationPlanner.finishedSummary(
                    kind: .cleanup,
                    startedAt: startedAt,
                    summaryText: "清理完成：Homebrew 缓存和旧版本清理流程已结束。",
                    recommendedNextAction: "建议刷新“我的酒窖”，确认剩余安装项和大小状态。"
                )
            } catch {
                self.latestBrewOperationSummary = BrewOperationPlanner.failureSummary(kind: .cleanup, startedAt: startedAt, error: error)
                handleError(error)
            }
        }
    }
    func searchOnline() {
        guard !installSearchText.isEmpty else { return }
        searchTask?.cancel()
        withAnimation { activity = .searching; searchResults = [] }
        searchTask = Task { @MainActor in
            defer { self.searchTask = nil; if case .searching = self.activity { self.activity = .idle } }
            do {
                let results = try await service.search(query: installSearchText)
                if !Task.isCancelled { withAnimation { self.searchResults = results } }
            } catch { if !(error is CancellationError) { addLog("搜索失败: \(error.localizedDescription)", type: .failure) } }
        }
    }
    func installPackage(_ item: BrewSearchItem) {
        guard !isCoreBusy else { return }
        searchTask?.cancel()
        let startedAt = Date()
        latestBrewOperationSummary = BrewOperationPlanner.runningSummary(kind: .install, startedAt: startedAt)
        withAnimation { activity = .installing(item.name) }
        installTask = Task { @MainActor in
            defer { self.installTask = nil; if case .installing(_) = self.activity { self.activity = .idle } }
            var isCask = item.type == .cask
            if item.type == nil {
                addLog("正在确认 \(item.name) 的类型...", type: .info)
                do {
                    let (type, _) = try await service.getInfoTyped(name: item.name)
                    isCask = (type == .cask)
                } catch { addLog("类型确认失败，将按默认(Formula)尝试", type: .info) }
            }
            let targetPackage = BrewPackage(
                name: item.name,
                desc: nil,
                installedVersions: [],
                currentVersion: "待安装",
                isPinned: false,
                isLeaf: true,
                type: isCask ? .cask : .formula,
                autoUpdates: false,
                installedSizeBytes: nil,
                appArtifactNames: []
            )
            self.latestBrewOperationSummary = BrewOperationPlanner.runningSummary(kind: .install, packages: [targetPackage], startedAt: startedAt)
            addLog("开始安装 \(item.name) (\(isCask ? "Cask" : "Formula"))...", type: .command)
            do {
                let stream = await service.install(item.name, isCask: isCask)
                for try await line in stream { addLog(line, type: .stream) }
                addLog("安装成功: \(item.name)", type: .success)
                self.latestBrewOperationSummary = BrewOperationPlanner.finishedSummary(
                    kind: .install,
                    startedAt: startedAt,
                    packages: [targetPackage],
                    summaryText: "安装完成：已处理 \(item.name)。",
                    recommendedNextAction: "建议刷新“我的酒窖”，确认安装版本、大小和状态标签。"
                )
                self.refreshLibrary(silent: true)
            } catch {
                self.latestBrewOperationSummary = BrewOperationPlanner.failureSummary(kind: .install, startedAt: startedAt, packages: [targetPackage], error: error)
                handleError(error)
            }
        }
    }
    func exportBrewfile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Brewfile"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                Task { @MainActor in
                    self.addLog("正在导出 Brewfile...", type: .command)
                    do { try await self.service.exportBrewfile(to: url); self.addLog("导出成功: \(url.path)", type: .success) }
                    catch { self.handleError(error) }
                }
            }
        }
    }
    func prepareInstallSheet() {
        showInstallSheet = true
        let stale = (lastLibraryRefreshAt == nil) || (Date().timeIntervalSince(lastLibraryRefreshAt!) > 600)
        if installedNameSet.isEmpty || stale { refreshLibrary(silent: true) }
    }
    func getLogsString() -> String { logs.map { "[\($0.timestamp.formatted(.iso8601))] \($0.message)" }.joined(separator: "\n") }
    func publishAppEvent(_ event: AppEvent) {
        AppEventReducer.publish(event, activeEvents: &activeAppEvents, historyEvents: &appEvents)
        latestAppEvent = event
    }
    func recordExternalLog(_ msg: String, type: LogEntry.LogType, reveal: Bool = false) {
        addLog(msg, type: type)
        if reveal && !showLogSheet {
            withAnimation { showLogSheet = true }
        }
    }

    // P1-1 Fix: 直接同步更新，不使用 Task 包装
    private func addLog(_ msg: String, type: LogEntry.LogType) {
        let prefix = (type == .command) ? "$ " : ""
        let entry = LogEntry(timestamp: Date(), message: prefix + msg, type: type)
        logs.append(entry); if logs.count > 2000 { logs.removeFirst(200) }
        if type == .failure && !showLogSheet { withAnimation { showLogSheet = true } }
    }
    private func handleError(_ error: Error) {
        if error is CancellationError || (error as? BrewError) == .cancelled { addLog("操作已取消", type: .info) }
        else { addLog("❌ \(error.localizedDescription)", type: .failure) }
    }
    private func updateDock(_ count: Int) { NSApplication.shared.dockTile.badgeLabel = count > 0 ? "\(count)" : nil }

    // --- BEGIN APPEND: AppState Logic C3-R1-STRICT-R2 ---
    private func fetchAllPackageSizes() {
        sizeProbeTask?.cancel()
        let pkgs = self.installedPackages
        sizeProbeTask = Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            await withTaskGroup(of: (String, Int64?).self) { group in
                var iterator = pkgs.makeIterator()
                for _ in 0..<4 {
                    if let p = iterator.next() {
                        group.addTask { await (p.id, self.computeInstalledSizeBytes(for: p)) }
                    }
                }
                while let (pid, size) = await group.next() {
                    if Task.isCancelled { break }
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        if let idx = self.installedPackages.firstIndex(where: { $0.id == pid }) {
                            self.installedPackages[idx].installedSizeBytes = size
                        }
                        PackageSizeReferenceMerger.updateInstalledSize(
                            packageID: pid,
                            installedSizeBytes: size,
                            in: &self.outdatedPackages
                        )
                    }
                    if let next = iterator.next() {
                        group.addTask { await (next.id, self.computeInstalledSizeBytes(for: next)) }
                    }
                }
            }
        }
    }

    nonisolated private func computeInstalledSizeBytes(for pkg: BrewPackage) async -> Int64? {
        if pkg.type == .cask {
            for candidate in CaskAppBundlePathResolver.sizeProbeCandidates(for: pkg) {
                switch candidate {
                case .appBundle(let path):
                    if let size = await computeAppBundleSizeBytes(at: path) {
                        return size
                    }
                case .caskroomVersionDirectory(let path):
                    for appPath in CaskAppBundlePathResolver.appBundleCandidates(inCaskroomVersionDirectory: path) {
                        if let size = await computeAppBundleSizeBytes(at: appPath) {
                            return size
                        }
                    }
                }
            }
            return nil
        }

        var pathsToTry: [String] = []
        let fm = FileManager.default
        if let ver = pkg.installedVersions.first {
            pathsToTry.append("/opt/homebrew/Cellar/\(pkg.name)/\(ver)")
        }

        for path in pathsToTry {
            if fm.fileExists(atPath: path) {
                do {
                    let out = try await ShellService.runSynchronous(executable: "/usr/bin/du", args: ["-sk", path])
                    let kbStr = out.components(separatedBy: .whitespaces).first ?? "0"
                    if let kb = Int64(kbStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        return kb * 1024
                    }
                } catch { continue }
            }
        }
        return nil
    }

    nonisolated private func computeAppBundleSizeBytes(at path: String) async -> Int64? {
        guard path.hasSuffix(".app") else { return nil }
        let fm = FileManager.default
        let isSymlink = (try? fm.destinationOfSymbolicLink(atPath: path)) != nil
        guard isSymlink || fm.fileExists(atPath: path) else { return nil }
        do {
            let args = isSymlink ? ["-skL", path] : ["-sk", path]
            let out = try await ShellService.runSynchronous(executable: "/usr/bin/du", args: args)
            let kbStr = out.components(separatedBy: .whitespaces).first ?? "0"
            if let kb = Int64(kbStr.trimmingCharacters(in: .whitespacesAndNewlines)), kb > 0 {
                return kb * 1024
            }
        } catch {
            return nil
        }
        return nil
    }

    func formatSize(_ bytes: Int64?) -> String {
        guard let b = bytes else { return "未知" }
        return sizeFormatter.string(fromByteCount: b)
    }

    func formatPackageSize(_ estimate: PackageSizeEstimate) -> String {
        estimate.displayText(using: sizeFormatter)
    }
    // --- END APPEND: AppState Logic C3-R1-STRICT-R2 ---
}

@main
struct CellarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    var body: some Scene {
        MenuBarExtra { MenuBarView(appState: appState) } label: { MenuBarLabelView(appState: appState) }.menuBarExtraStyle(.menu)
        Window(CellarWindowCopy.mainWindowTitle, id: "main") { MainView().environmentObject(appState).task { appState.refresh(); appState.refreshLibrary(silent: true) } }.windowResizability(.contentSize)
        Window(CellarWindowCopy.settingsWindowTitle, id: "settings") { SettingsView(store: appState.settings) }.windowResizability(.contentSize)
            .commands { CommandGroup(replacing: .appSettings) { Button(CellarWindowCopy.openSettingsCommand) { WindowOpener.openSettings?() }.keyboardShortcut(",", modifiers: .command) } }
    }
}
struct MenuBarLabelView: View {
    @ObservedObject var appState: AppState; @Environment(\.openWindow) var openWindow
    var body: some View {
        HStack(spacing: 2) {
            let c = appState.status.badgeCount
            if c > 0 { Text(c > 99 ? "99+" : "\(c)").monospacedDigit() }
            Image(systemName: appState.isEverythingBusy ? "arrow.triangle.2.circlepath" : "shippingbox")
        }.onAppear { WindowOpener.open = { openWindow(id: "main") }; WindowOpener.openSettings = { openWindow(id: "settings") } }
    }
}
struct MenuBarView: View {
    @ObservedObject var appState: AppState; @Environment(\.openWindow) var openWindow
    var body: some View {
        Text("Cellar: \(appState.status.description)"); Divider()
        if appState.isEverythingBusy {
	            Button("停止操作") { appState.cancelOperation() }
                    .help("停止当前正在运行的 Homebrew 或搜索任务。")
        } else {
	            Button("检查更新") { appState.refresh() }
                    .help("快速读取当前可更新项目，不强制执行 brew update。")
	            Button("更新 Homebrew 仓库后检查") { appState.refresh(full: true) }
                    .help("先执行 brew update，再读取可更新项目和版本差异分类。")
        }
        Divider()
	        Button("安装新软件...") { openWindow(id: "main"); Task { @MainActor in appState.prepareInstallSheet() } }
                .help("搜索并安装新的 Homebrew Formula 或 Cask。")
	        Button("导出 Brewfile...") { NSApp.activate(ignoringOtherApps: true); appState.exportBrewfile() }
                .help("导出当前 Homebrew bundle 清单。")
        Divider()
        Button(CellarWindowCopy.openSettings) { openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true) }
            .keyboardShortcut(",", modifiers: .command)
        Divider()
        Button(CellarWindowCopy.openMainWindow) { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button("退出") { NSApp.terminate(nil) }
    }
}
private enum MainAlertKind: Identifiable {
    case upgrade
    case greedySync
    case uninstall

    var id: String {
        switch self {
        case .upgrade: return "upgrade"
        case .greedySync: return "greedySync"
        case .uninstall: return "uninstall"
        }
    }
}

struct MainView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var runtimeModel = RuntimeDoctorViewModel()
    @State private var eventMonitor: Any?
    @State private var optionKeyPressed = false
    private var activeAlert: Binding<MainAlertKind?> {
        Binding(
            get: {
                if appState.showUpgradeConfirmation { return .upgrade }
                if appState.showGreedySyncConfirmation { return .greedySync }
                if appState.showUninstallConfirmation { return .uninstall }
                return nil
            },
            set: { newValue in
                if newValue == nil {
                    appState.showUpgradeConfirmation = false
                    appState.showGreedySyncConfirmation = false
                    appState.showUninstallConfirmation = false
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(optionKeyPressed: $optionKeyPressed); Divider()
            MainContentPanel {
                if appState.activeTab == .dashboard { DashboardView(optionKeyPressed: optionKeyPressed, runtimeModel: runtimeModel).transition(.move(edge: .leading)) }
                else if appState.activeTab == .library { LibraryView(optionKeyPressed: optionKeyPressed).transition(.move(edge: .trailing)) }
                else { RuntimeDoctorView(model: runtimeModel).transition(.opacity.combined(with: .move(edge: .trailing))) }
            }
            .animation(.easeInOut(duration: 0.2), value: appState.activeTab)
            Divider()
            FooterArea(runtimeModel: runtimeModel)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { optionKeyPressed = $0.modifierFlags.contains(.option); return $0 }
            runtimeModel.installLogger { message, type, reveal in
                appState.recordExternalLog(message, type: type, reveal: reveal)
            }
            runtimeModel.refreshIfNeeded()
        }
        .onDisappear { if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil } }
        .onChange(of: appState.activeTab) { _, newTab in
            if newTab == .library {
                let stale = (appState.lastLibraryRefreshAt == nil) || (Date().timeIntervalSince(appState.lastLibraryRefreshAt!) > 600)
                if appState.installedPackages.isEmpty || stale { appState.refreshLibrary(silent: !appState.installedPackages.isEmpty) }
            }
        }
        .onChange(of: runtimeModel.latestRuntimeEvent) { _, event in
            if let event {
                appState.publishAppEvent(AppEventFactory.event(from: event))
            }
        }
        .alert(item: activeAlert) { alert in
            switch alert {
            case .upgrade:
                return Alert(
                    title: Text(appState.upgradeConfirmationTitle),
                    message: Text(appState.upgradeConfirmationMessage),
                    primaryButton: .destructive(Text("开始升级")) { appState.upgrade() },
                    secondaryButton: .cancel(Text("取消"))
                )
            case .greedySync:
                return Alert(
                    title: Text(appState.greedySyncConfirmationTitle),
                    message: Text(appState.greedySyncConfirmationMessage),
                    primaryButton: .destructive(Text("用 Homebrew 贪婪同步")) { appState.greedySyncSelectedCask() },
                    secondaryButton: .cancel(Text("取消"))
                )
            case .uninstall:
                return Alert(
                    title: Text("确认卸载?"),
                    message: Text("此操作将移除 \(appState.selectedPackage?.name ?? "") 及其相关文件。"),
                    primaryButton: .destructive(Text("确认卸载")) {
                        if let p = appState.selectedPackage { appState.uninstall(p) }
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            }
        }
        .sheet(isPresented: $appState.showInfoSheet) { if let info = appState.selectedInfo { InfoView(info: info) } }
        .sheet(isPresented: $appState.showInstallSheet) { InstallView() }
    }
}

struct MainContentPanel<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
        .clipped()
    }
}

struct HeaderView: View {
    @EnvironmentObject var appState: AppState; @Binding var optionKeyPressed: Bool
    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 24) {
                ZStack { Image(systemName: "shippingbox.fill").resizable().aspectRatio(contentMode: .fit).frame(width: 32, height: 32).foregroundStyle(appState.activeTab == .dashboard ? .orange : .blue, .brown).opacity(appState.isEverythingBusy ? 0.2 : 1.0).accessibilityHidden(true); if appState.isEverythingBusy { ProgressView().controlSize(.small).accessibilityLabel("正在执行任务") } }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(appState.isEverythingBusy ? "Cellar 正在执行任务" : "Cellar")
                VStack(alignment: .leading, spacing: 3) {
	                    Picker("", selection: $appState.activeTab) { ForEach(AppTab.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width: 260).accessibilityLabel("主导航").accessibilityHint("在仪表盘、我的酒窖和运行时诊断之间切换。")
                    Text(headerStatusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }.padding(.leading, 4)
            }
            Spacer()
            if appState.activeTab == .runtime {
                runtimeHeaderControls
            } else {
                brewHeaderControls
            }
        }.padding(.horizontal, 16).padding(.vertical, 12).background(VisualEffectView(material: .headerView, blendingMode: .withinWindow).ignoresSafeArea())
    }

    private var runtimeHeaderControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Text("Runtime Doctor：先看结论，再看路径策略")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                runtimeRefreshButton(showText: true)
            }
            HStack(spacing: 8) {
                Text("运行时诊断")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                runtimeRefreshButton(showText: false)
            }
        }
    }

    private var brewHeaderControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                searchField(width: 220)
                packageTypePicker
                pinnedToggle
                if appState.activeTab == .library { leavesToggle.transition(.scale.combined(with: .opacity)) }
                if appState.activeTab == .library { libraryStateMenu.frame(width: 120) }
                filterChips
                Divider().frame(height: 20)
                installOrStopButton
                refreshControls
            }
            HStack(spacing: 8) {
                searchField(width: 150)
                filterMenu
                installOrStopButton
                refreshControls
            }
            HStack(spacing: 8) {
                compactActionsMenu
                installOrStopButton
                refreshButton
            }
        }
    }

    private func searchField(width: CGFloat) -> some View {
        TextField("筛选名称...", text: $appState.searchText)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: min(width, 140), maxWidth: width)
            .help("按包名筛选当前列表。")
            .accessibilityLabel("按名称筛选")
            .accessibilityHint("输入包名，筛选当前列表。")
    }

    private var packageTypePicker: some View {
        Picker("", selection: $appState.filterType) {
            Text("全部").tag(PackageType?.none)
            Text("Formula").tag(PackageType?.some(.formula))
            Text("Cask").tag(PackageType?.some(.cask))
        }
        .pickerStyle(.segmented)
        .frame(width: 180)
        .help("按 Homebrew 项目类型筛选。")
        .accessibilityLabel("项目类型筛选")
        .accessibilityHint("选择全部、Formula 或 Cask。")
    }

    private var pinnedToggle: some View {
        Toggle(isOn: $appState.showPinnedOnly) { Image(systemName: "pin.fill").font(.body).accessibilityHidden(true) }
            .toggleStyle(.button)
            .help("只显示已锁定的包")
            .accessibilityLabel("只显示已锁定")
            .accessibilityHint("切换是否只显示已锁定的 Homebrew 项目。")
            .tint(.orange)
    }

    private var leavesToggle: some View {
        Toggle(isOn: $appState.showLeavesOnly) { Image(systemName: "leaf.fill").font(.body).accessibilityHidden(true) }
            .toggleStyle(.button)
            .help("只显示叶子节点")
            .accessibilityLabel("只显示叶子包")
            .accessibilityHint("切换是否只显示当前没有被其他包依赖的项目。")
            .tint(.green)
    }

    private var libraryStateMenu: some View {
        Menu {
            Button("全部状态") { appState.packageStateFilter = nil; appState.showLeavesOnly = false }
            Divider()
            ForEach(PackageStateFilterKey.allCases) { key in
                Button(key.title) { appState.applyLibraryStateFilter(key) }
            }
        } label: {
            Label(appState.packageStateFilter?.title ?? "状态", systemImage: "tag")
        }
        .menuStyle(.borderedButton)
        .help("按我的酒窖资产标签筛选：版本差异、自更新 Cask、酒窖大小未知、叶子包。")
        .accessibilityLabel("资产状态筛选")
        .accessibilityHint("按版本差异、自更新 Cask、酒窖大小未知、叶子包筛选。")
    }

    private var filterMenu: some View {
        Menu {
            Button("全部类型") { appState.filterType = nil }
            Button("Formula") { appState.filterType = .formula }
            Button("Cask") { appState.filterType = .cask }
            Divider()
            Toggle("只显示已锁定", isOn: $appState.showPinnedOnly)
            if appState.activeTab == .library {
                Toggle("只显示叶子包", isOn: $appState.showLeavesOnly)
                Divider()
                Button("全部状态") { appState.packageStateFilter = nil; appState.showLeavesOnly = false }
                ForEach(PackageStateFilterKey.allCases) { key in
                    Button(key.title) { appState.applyLibraryStateFilter(key) }
                }
            }
        } label: {
            Label(filterMenuTitle, systemImage: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderedButton)
        .help(activeFilterCount > 0 ? "当前启用 \(activeFilterCount) 个筛选：\(activeFilterTitles.joined(separator: "、"))。" : "打开筛选菜单。")
        .accessibilityLabel(activeFilterCount > 0 ? "筛选菜单，已启用 \(activeFilterCount) 个筛选" : "筛选菜单")
        .accessibilityHint("收纳类型、锁定、叶子包和资产状态筛选。")
    }

    @ViewBuilder
    private var filterChips: some View {
        if activeFilterCount > 0 {
            HStack(spacing: 4) {
                ForEach(filterSummary.chips, id: \.self) { title in
                    Text(title)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                        .foregroundStyle(.secondary)
                        .help("当前筛选：\(title)")
                        .accessibilityLabel("当前筛选：\(title)")
                }
                if filterSummary.overflowCount > 0 {
                    Text("+\(filterSummary.overflowCount)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        .foregroundStyle(.secondary)
                        .help("另有 \(filterSummary.overflowCount) 个筛选。")
                        .accessibilityLabel("另有 \(filterSummary.overflowCount) 个筛选")
                }
            }
        }
    }

    private var filterMenuTitle: String {
        filterSummary.menuTitle
    }

    private var activeFilterCount: Int {
        filterSummary.count
    }

    private var activeFilterTitles: [String] {
        filterSummary.titles
    }

    private var filterSummary: PackageFilterVisibilitySummary {
        PackageFilterVisibilitySummary.make(
            type: appState.filterType,
            showPinnedOnly: appState.showPinnedOnly,
            showLeavesOnly: appState.showLeavesOnly,
            packageStateFilter: appState.packageStateFilter,
            isLibrary: appState.activeTab == .library
        )
    }

    private var compactActionsMenu: some View {
        Menu {
            Button(appState.activeTab == .dashboard ? "检查更新" : "刷新我的酒窖") { refreshPrimary() }
            if appState.activeTab == .dashboard {
                Button("更新 Homebrew 仓库后检查") { appState.refresh(full: true) }
                Button("刷新已安装列表") { appState.refreshLibrary() }
            }
            Button("清除筛选") { clearHeaderFilters() }
        } label: {
            Label("操作", systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderedButton)
        .help("窄窗口下收纳刷新和筛选操作。")
        .accessibilityLabel("更多操作")
        .accessibilityHint("打开刷新、仓库更新和清除筛选操作。")
    }

    private var installOrStopButton: some View {
        Group {
            if appState.isEverythingBusy {
                Button(role: .destructive) { appState.cancelOperation() } label: { Image(systemName: "stop.circle.fill").font(.title2).foregroundStyle(.red).accessibilityHidden(true) }
                    .buttonStyle(.plain)
                    .help("停止当前任务，停止后可继续刷新、安装或升级。")
                    .accessibilityLabel("停止当前任务")
                    .accessibilityHint("停止当前正在运行的 Homebrew 或搜索任务。")
            } else {
                Button { appState.prepareInstallSheet() } label: { Image(systemName: "plus").font(.title2).accessibilityHidden(true) }
                    .buttonStyle(.plain)
                    .help("安装新软件")
                    .accessibilityLabel("安装新软件")
                    .accessibilityHint("打开 Homebrew Formula 或 Cask 搜索安装窗口。")
            }
        }
    }

    private var refreshControls: some View {
        HStack(spacing: 6) {
            refreshButton
            if appState.activeTab == .dashboard {
                Menu {
                    Button("检查更新") { appState.refresh() }
                    Button("更新 Homebrew 仓库后检查") { appState.refresh(full: true) }
                    Button("刷新已安装列表") { appState.refreshLibrary() }
                } label: {
                    Image(systemName: "chevron.down.circle").font(.body).accessibilityHidden(true)
                }
                .menuStyle(.borderlessButton)
                .help("更多刷新方式")
                .accessibilityLabel("更多刷新方式")
                .accessibilityHint("选择检查更新、更新仓库后检查或刷新已安装列表。")
            }
        }
    }

    private var refreshButton: some View {
        Button { refreshPrimary() } label: { Image(systemName: "arrow.clockwise").font(.title2).accessibilityHidden(true) }
            .buttonStyle(.plain)
            .help(refreshHelpText)
            .accessibilityLabel(appState.activeTab == .dashboard ? "检查更新" : "刷新我的酒窖")
            .accessibilityHint(refreshHelpText)
    }

    private func runtimeRefreshButton(showText: Bool) -> some View {
        Button {
            NotificationCenter.default.post(name: .runtimeRefreshRequested, object: nil)
        } label: {
            if showText {
                Label("刷新", systemImage: "arrow.clockwise")
            } else {
                Image(systemName: "arrow.clockwise").accessibilityHidden(true)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .help("重新扫描 Node、Python、PATH Policy 和全局工具入口。")
        .accessibilityLabel("刷新运行时诊断")
        .accessibilityHint("重新扫描 Node、Python、PATH Policy 和全局工具入口。")
    }

    private var refreshHelpText: String {
        appState.activeTab == .dashboard
            ? (optionKeyPressed ? "更新 Homebrew 仓库后检查：先 brew update，再检查可更新项目。" : "检查更新：快速读取可更新项目。")
            : "刷新我的酒窖：重新读取已安装项目和状态标签。"
    }

    private func refreshPrimary() {
        if appState.activeTab == .dashboard {
            let full = NSEvent.modifierFlags.contains(.option)
            appState.refresh(full: full)
        } else {
            appState.refreshLibrary()
        }
    }

    private func clearHeaderFilters() {
        appState.searchText = ""
        appState.filterType = nil
        appState.showPinnedOnly = false
        appState.showLeavesOnly = false
        appState.packageStateFilter = nil
    }

    private var headerStatusText: String {
        if appState.activity.isBusy { return appState.activity.description }
        switch appState.activeTab {
        case .dashboard:
            return appState.status.description
        case .library:
            return "已安装 \(appState.installedPackages.count) 个包"
        case .runtime:
            return "Runtime Doctor 已就绪"
        }
    }
}
struct InstallView: View {
    @EnvironmentObject var appState: AppState; @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                TextField("搜索 Homebrew (例如: git, vscode)...", text: $appState.installSearchText).textFieldStyle(.plain).font(.title3).onSubmit { appState.searchOnline() }
                if appState.activity.isSearching { ProgressView().controlSize(.small) }
	                Button("搜索") { appState.searchOnline() }.disabled(appState.installSearchText.isEmpty || appState.activity.isSearching).help(appState.installSearchText.isEmpty ? "请输入关键词后再搜索。" : (appState.activity.isSearching ? "正在搜索，请等待结果返回。" : "搜索 Homebrew Formula 和 Cask。"))
	                Button("关闭") { dismiss() }.buttonStyle(.bordered).padding(.leading, 8).help("关闭安装搜索窗口。")
            }.padding().background(.ultraThinMaterial); Divider()
            if appState.searchResults.isEmpty && !appState.activity.isSearching {
	                VStack(spacing: 20) { Spacer(); Image(systemName: "archivebox").font(.system(size: 48)).foregroundStyle(.tertiary); Text("输入关键词开始搜索").foregroundStyle(.secondary); Text("下一步：输入软件名称，例如 git 或 visual-studio-code。").font(.caption).foregroundStyle(.secondary); Spacer() }
            } else {
                List(appState.searchResults) { item in
                    HStack {
                        Image(systemName: item.type == .cask ? "app.dashed" : "terminal").foregroundStyle(item.type == .cask ? .blue : .gray)
                        VStack(alignment: .leading) { Text(item.name).font(.headline).monospaced(); if let t = item.type { Text(t.rawValue).font(.caption).foregroundStyle(.secondary) } }
                        Spacer()
                        if appState.installedNameSet.contains(item.name.lowercased()) {
                            Text("已安装").font(.caption.bold()).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 4).background(Capsule().fill(Color.secondary.opacity(0.1)))
                        } else {
	                            Button("安装") { appState.installPackage(item) }.buttonStyle(.borderedProminent).disabled(appState.isCoreBusy).help(appState.isCoreBusy ? "当前有 Homebrew 任务正在运行，完成或停止后再安装。" : "安装该 Homebrew 项目。")
                        }
                    }.padding(.vertical, 4)
                }
            }
        }.frame(minWidth: 600, minHeight: 400)
    }
}
struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    var optionKeyPressed: Bool
    @ObservedObject var runtimeModel: RuntimeDoctorViewModel

    var body: some View {
        let dashboardSummary = DashboardHealthSummary.make(
            brewStatus: appState.status,
            outdatedPackages: appState.outdatedPackages,
            operationSummary: appState.latestBrewOperationSummary,
            runtimeSnapshots: runtimeModel.dashboardSnapshots,
            runtimeGlobalToolsSummary: runtimeModel.dashboardGlobalToolsSummary,
            librarySummary: appState.librarySummary,
            homebrewSnapshotProvenance: appState.outdatedSnapshotProvenance
        )
        GeometryReader { proxy in
            let showsPackageTable = shouldShowPackageTable
            VStack(spacing: 0) {
                DashboardScrollableContent {
                    dashboardExpandableContent(dashboardSummary)
                    if !showsPackageTable {
                        dashboardStandaloneState(dashboardSummary)
                    }
                }
                .frame(maxHeight: DashboardScrollLayout.topMaxHeight(totalHeight: proxy.size.height, showsPackageTable: showsPackageTable))
                .layoutPriority(showsPackageTable ? 0 : 1)

                if showsPackageTable {
                    UpdatePackageGroupsView(
                        packages: appState.displayPackages,
                        optionKeyPressed: optionKeyPressed,
                        snapshotProvenance: appState.outdatedSnapshotProvenance
                    )
                        .frame(minHeight: DashboardScrollLayout.packageTableMinHeight(totalHeight: proxy.size.height))
                        .layoutPriority(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            if appState.installedPackages.isEmpty && !appState.isEverythingBusy {
                appState.refreshLibrary(silent: true)
            }
        }
    }

    private var shouldShowPackageTable: Bool {
        if case .error = appState.status { return false }
        return !appState.outdatedPackages.isEmpty || appState.isEverythingBusy
    }

    @ViewBuilder
    private func dashboardExpandableContent(_ dashboardSummary: DashboardHealthSummary) -> some View {
        DashboardHealthSummaryView(summary: dashboardSummary) { action in
            performDashboardAction(action)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)

        if let summary = appState.latestBrewOperationSummary {
            BrewOperationSummaryView(summary: summary)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
        }

        if !appState.installedPackages.isEmpty {
            LibrarySummaryView(summary: appState.librarySummary) { filter in
                appState.applyLibraryStateFilter(filter)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private func dashboardStandaloneState(_ dashboardSummary: DashboardHealthSummary) -> some View {
        if case .error(let m) = appState.status {
            ErrorView(msg: m, nextStep: "下一步：打开事件中心或高级日志，确认失败原因；网络、代理或权限问题可跳到偏好设置核对。")
                .padding(.horizontal, 16)
                .padding(.vertical, 24)
        } else if appState.outdatedPackages.isEmpty && !appState.isEverythingBusy {
            EmptyView(title: Self.dashboardEmptyTitle(), nextStep: ProductCopy.emptyStateNextStep(for: .dashboard))
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.vertical, 24)
        }
    }

    static func dashboardEmptyTitle() -> String {
        "更新列表为空"
    }

    private func performDashboardAction(_ action: DashboardAction) {
        switch action {
        case .checkUpdates:
            appState.refresh()
        case .updateThenCheck:
            appState.refresh(full: true)
        case .showUpdates:
            appState.activeTab = .dashboard
            appState.searchText = ""
            appState.filterType = nil
            appState.showPinnedOnly = false
        case .showRuntime:
            appState.activeTab = .runtime
            NotificationCenter.default.post(name: .runtimeRefreshRequested, object: nil)
        case .showRuntimeGlobalTool(let focusID):
            runtimeModel.focusGlobalToolAttention(id: focusID)
            appState.activeTab = .runtime
            NotificationCenter.default.post(name: .runtimeRefreshRequested, object: nil)
        case .showLibrary(let filter):
            appState.applyLibraryStateFilter(filter)
	        case .showSettings(let section):
	            appState.openReliabilitySettings(section)
	        }
	    }
}

private struct DashboardScrollableContent<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.bottom, MainContentLayout.scrollEndPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DashboardHealthSummaryView: View {
    let summary: DashboardHealthSummary
    let perform: (DashboardAction) -> Void
    @State private var showsAllItems = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(summary.headline, systemImage: symbol)
                    .font(.headline)
                    .foregroundStyle(color)
                Text(summary.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 12)
                if summary.items.isEmpty {
                    Button {
                        perform(.checkUpdates)
                    } label: {
                        Label("手动检查", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("当前没有明显待处理项；需要复核时可手动检查。更新仓库后检查保留在刷新菜单中。")
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    ForEach(summary.domains) { domain in
                        DashboardDomainStatusView(domain: domain) {
                            if let action = domain.action {
                                perform(action)
                            }
                        }
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(summary.domains) { domain in
                        DashboardDomainStatusView(domain: domain) {
                            if let action = domain.action {
                                perform(action)
                            }
                        }
                    }
                }
            }
            if !summary.items.isEmpty {
                if showsAllItems {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(presentation.visibleItems) { item in
                            DashboardActionItemView(item: item) {
                                perform(item.action)
                            }
                        }
                    }
                } else {
                    ViewThatFits(in: .horizontal) {
                        compactActionsRow
                        compactActionsColumn
                    }
                }
                if summary.items.count > compactItemLimit {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showsAllItems.toggle()
                        }
                    } label: {
                        Label(showsAllItems ? "收起" : "展开全部 \(summary.items.count) 项", systemImage: showsAllItems ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(showsAllItems ? "收起风险摘要，给更新列表保留更多空间。" : "展开查看全部待关注项。")
                    .accessibilityLabel(showsAllItems ? "收起风险摘要" : "展开全部 \(summary.items.count) 项风险摘要")
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(0.08))
        )
        .onChange(of: summary.items.map(\.id)) { _, _ in
            showsAllItems = false
        }
    }

    private var compactItemLimit: Int { 2 }

    private var visibleItems: ArraySlice<DashboardActionItem> {
        summary.items.prefix(compactItemLimit)
    }

    private var remainingCount: Int {
        max(summary.items.count - visibleItems.count, 0)
    }

    private var compactActionsRow: some View {
        HStack(spacing: 8) {
            ForEach(Array(visibleItems)) { item in
                DashboardCompactActionButton(item: item) {
                    perform(item.action)
                }
            }
            if presentation.hiddenCount > 0 {
                remainingLabel
            }
            Spacer(minLength: 0)
        }
    }

    private var compactActionsColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(visibleItems)) { item in
                DashboardCompactActionButton(item: item) {
                    perform(item.action)
                }
            }
            if presentation.hiddenCount > 0 {
                remainingLabel
            }
        }
    }

    private var remainingLabel: some View {
        Text("还有 \(presentation.hiddenCount) 项待关注")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityLabel("还有 \(presentation.hiddenCount) 项待关注，可展开查看全部")
    }

    private var presentation: DashboardRiskSummaryPresentation {
        DashboardRiskSummaryPresentation(items: summary.items, isExpanded: showsAllItems, compactLimit: compactItemLimit)
    }

    private var color: Color {
        switch summary.severity {
        case .clear: return .green
        case .attention: return .blue
        case .warning: return .orange
        case .critical: return .red
        }
    }

    private var symbol: String {
        switch summary.severity {
        case .clear: return "checkmark.seal.fill"
        case .attention: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        }
    }
}

private struct DashboardDomainStatusView: View {
    let domain: DashboardDomainStatus
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(color)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(domain.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(domain.value)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text(domain.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
            .padding(8)
        }
        .buttonStyle(.plain)
        .disabled(domain.action == nil)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(color.opacity(0.18), lineWidth: 1)
        )
        .help(helpText)
        .accessibilityLabel("\(domain.title)：\(domain.value)")
        .accessibilityHint(helpText)
    }

    private var helpText: String {
        if let actionTitle = domain.actionTitle {
            return "\(domain.detail) 下一步：\(actionTitle)。"
        }
        return domain.detail
    }

    private var color: Color {
        switch domain.severity {
        case .clear: return .green
        case .attention: return .blue
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

private struct DashboardCompactActionButton: View {
    let item: DashboardActionItem
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 6) {
                Text(item.source)
                    .font(.caption2.weight(.semibold))
                Text(item.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(color)
        .help("\(item.detail) 下一步：\(item.actionTitle)。")
    }

    private var color: Color {
        switch item.severity {
        case .clear: return .green
        case .attention: return .blue
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

private struct DashboardActionItemView: View {
    let item: DashboardActionItem
    let perform: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.source)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(color)
                Text(item.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(item.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Button(item.actionTitle, action: perform)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(item.detail)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(color.opacity(0.25), lineWidth: 1)
        )
    }

    private var color: Color {
        switch item.severity {
        case .clear: return .green
        case .attention: return .blue
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

struct LibrarySummaryView: View {
    let summary: LibrarySummary
    let select: (PackageStateFilterKey) -> Void

    var body: some View {
        HStack(spacing: 8) {
            SummaryButton(title: ProductCopy.repoVersionDiff, count: summary.repoDiffCount, symbol: "bolt.fill", color: .orange, helpText: ProductCopy.termHelp(ProductCopy.repoVersionDiff)) { select(.repoDiff) }
            SummaryButton(title: ProductCopy.autoUpdatingCask, count: summary.autoUpdatesCount, symbol: "arrow.triangle.2.circlepath.circle.fill", color: .blue, helpText: ProductCopy.termHelp(ProductCopy.autoUpdatingCask)) { select(.autoUpdates) }
            SummaryButton(title: ProductCopy.sizeUnknown, count: summary.sizeUnknownCount, symbol: "questionmark.circle.fill", color: .secondary, helpText: ProductCopy.termHelp(ProductCopy.sizeUnknown)) { select(.sizeUnknown) }
            SummaryButton(title: "叶子包", count: summary.leafCount, symbol: "leaf.fill", color: .green, helpText: "叶子包当前没有被其他包依赖，通常更适合直接卸载。") { select(.leaf) }
            Spacer(minLength: 0)
        }
    }
}

private struct SummaryButton: View {
    let title: String
    let count: Int
    let symbol: String
    let color: Color
    let helpText: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title)
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            }
            .font(.caption)
        }
        .buttonStyle(.bordered)
        .tint(count > 0 ? color : .secondary)
        .disabled(count == 0)
        .help(count > 0 ? "\(helpText) 点击查看对应项目。" : "当前没有\(title)项目。\(helpText)")
    }
}

struct BrewOperationSummaryView: View {
    let summary: BrewOperationSummary
    @EnvironmentObject private var appState: AppState
    @State private var showsDetails = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .font(.body)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(summary.operationKind.displayName)
                        .font(.caption.weight(.semibold))
                    Text(summary.status.displayName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(color)
                }
                if let progress = summary.progress {
                    HStack(spacing: 6) {
                        Text(progress.stage.displayName)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(color)
                        Text("目标 \(progress.totalPackageCount) 个")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(summary.compactRecapText)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
                if shouldFoldDetails {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showsDetails.toggle()
                        }
                    } label: {
                        Label(showsDetails ? "收起复盘详情" : "展开复盘详情", systemImage: showsDetails ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(showsDetails ? "收起逐包版本变化和复核详情。" : "展开查看逐包版本变化、复核详情和日志入口。")
                }
                if detailsVisible {
                    if !summary.summaryText.isEmpty, summary.summaryText != summary.compactRecapText {
                        Text(summary.summaryText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !summary.affectedPackages.isEmpty {
                        Text(packageLine)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .help(packageDetailHelp)
                    }
                    Button("打开高级日志") {
                        withAnimation { appState.showLogSheet = true }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .help("打开底部高级日志，查看 Homebrew 输出和复核过程。")
                }
                if let next = summary.recommendedNextAction, detailsVisible {
                    Text(next)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(0.08))
        )
        .onChange(of: summary.id) { _, _ in
            showsDetails = false
        }
    }

    private var shouldFoldDetails: Bool {
        (summary.operationKind == .upgrade || summary.operationKind == .greedySyncCask) && summary.status == .succeeded
    }

    private var detailsVisible: Bool {
        !shouldFoldDetails || showsDetails
    }

    private var color: Color {
        switch summary.status {
        case .running: return .blue
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }

    private var symbol: String {
        switch summary.status {
        case .running: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.seal.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "stop.circle"
        }
    }

    private var packageLine: String {
        let names = summary.affectedPackages.prefix(6).map { "\($0.name) \($0.versionChangeText) · \($0.sizeStatus)" }.joined(separator: "、")
        if summary.affectedPackages.count > 6 {
            return "\(names) 等 \(summary.affectedPackages.count) 个包"
        }
        return names
    }

    private var packageDetailHelp: String {
        "逐包版本变化使用 Homebrew outdated 目标快照；大小列保留“当前/旧包参考体量”和下载大小分离语义，不代表升级耗时。"
    }
}
struct LibraryView: View {
    @EnvironmentObject var appState: AppState; var optionKeyPressed: Bool
    var body: some View {
        Group {
            if appState.installedPackages.isEmpty && !appState.isEverythingBusy { EmptyView(title: "我的酒窖暂无可显示项目", nextStep: ProductCopy.emptyStateNextStep(for: .library)) }
            else if appState.displayLibrary.isEmpty { EmptyView(title: libraryFilterEmptyTitle, nextStep: "下一步：清除筛选条件，或刷新我的酒窖后再查看当前状态。") }
            else { PackageTable(packages: appState.displayLibrary, isLibrary: true, optionKeyPressed: optionKeyPressed) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var libraryFilterEmptyTitle: String {
        let filters = activeFilterDescriptions
        guard !filters.isEmpty else { return "我的酒窖暂无符合当前条件的项目" }
        return "没有符合\(filters.joined(separator: "、"))的项目"
    }

    private var activeFilterDescriptions: [String] {
        var filters: [String] = []
        if !appState.searchText.isEmpty { filters.append("“\(appState.searchText)”") }
        if let type = appState.filterType { filters.append("“\(type.rawValue)”") }
        if appState.showPinnedOnly { filters.append("“已锁定”") }
        if appState.showLeavesOnly && appState.packageStateFilter != .leaf { filters.append("“叶子包”") }
        if let state = appState.packageStateFilter { filters.append("“\(state.title)”") }
        return filters
    }
}

struct UpdatePackageGroupsView: View {
    var packages: [BrewPackage]
    var optionKeyPressed: Bool
    var snapshotProvenance: HomebrewSnapshotProvenance

    var body: some View {
        let groups = PackageUpdateListClassifier.groups(for: packages)
        let summary = PackageUpdateListClassifier.summary(for: packages)

        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Image(systemName: "square.stack.3d.up")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(summary.visibleText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    Text(snapshotProvenance.statusTitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(snapshotProvenance.isAuthoritativeSuccess ? Color.secondary : Color.orange)
                    Text(snapshotProvenance.detailText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .help("普通更新、自更新关注和版本记录差异独立计数；自更新 Cask 不进入普通批量升级。\(snapshotProvenance.detailText)")
                .accessibilityElement(children: .combine)
                .accessibilityLabel("更新列表分组摘要：\(summary.visibleText)。\(snapshotProvenance.statusTitle)。\(snapshotProvenance.detailText)")

                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        UpdatePackageGroupHeader(group: group)
                            .padding(.horizontal, 12)
                        PackageTable(packages: group.packages, isLibrary: false, optionKeyPressed: optionKeyPressed)
                            .frame(minHeight: tableHeight(for: group.packages.count), maxHeight: tableHeight(for: group.packages.count))
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }

    private func tableHeight(for count: Int) -> CGFloat {
        let rowHeight: CGFloat = 34
        let chromeHeight: CGFloat = 48
        return min(260, max(128, CGFloat(count) * rowHeight + chromeHeight))
    }
}

struct UpdatePackageGroupHeader: View {
    let group: PackageUpdateListGroup

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(group.title)
                .font(.caption.bold())
            Text(group.countText)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
            Text(group.subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .help("\(group.title)：\(group.subtitle)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.title)，\(group.countText)。\(group.subtitle)")
    }
}

struct PackageTable: View {
    var packages: [BrewPackage]; var isLibrary: Bool; var optionKeyPressed: Bool; @EnvironmentObject var appState: AppState
    var body: some View {
        Table(packages) {
            TableColumn("名称") { pkg in
                HStack {
                    Image(systemName: pkg.type == .cask ? "app.dashed" : "terminal")
                        .foregroundStyle(pkg.type == .cask ? .blue : .gray)
                        .accessibilityLabel(pkg.type == .cask ? "Cask 应用" : "Formula 命令行工具")
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(pkg.name).monospaced().fontWeight(.medium)
                            ForEach(PackageStateBadgeFactory.badges(for: pkg, isLibrary: isLibrary)) { badge in
                                PackageStateBadgeView(badge: badge)
                            }
                        }
                        if let d = pkg.desc { Text(d).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                    }
                }
                .contextMenu {
                    Button("查看详情") { appState.fetchInfo(for: pkg) }; Divider()
                    if pkg.type == .formula { Button(pkg.isPinned ? "解锁 (Unpin)" : "锁定 (Pin)") { appState.togglePin(for: pkg) }.disabled(appState.isPinningUI).help(appState.isPinningUI ? "锁定状态正在更新，完成后可再次操作。" : "Formula 可以锁定，避免被批量升级。") }
                    Button("复制名称") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(pkg.name, forType: .string) }; Divider()
                    if optionKeyPressed || (isLibrary && pkg.isLeaf) { Button("卸载 (危险)...") { appState.selectedPackage = pkg; appState.showUninstallConfirmation = true }.disabled(appState.isEverythingBusy).help(appState.isEverythingBusy ? "当前有任务正在运行，不能同时卸载。" : "卸载前会再次确认；非叶子包默认不直接提供卸载入口。") }
                    else { Text(isLibrary ? "仅叶子节点可直接卸载" : "按住 Option 键以卸载").foregroundStyle(.secondary) }
                }
            }
            TableColumn("类型") { Text($0.type.rawValue).font(.system(size: 10, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 2).background($0.type == .cask ? Color.blue.opacity(0.1) : Color.gray.opacity(0.1)).foregroundStyle($0.type == .cask ? .blue : .primary).cornerRadius(4) }.width(60)
            TableColumn("已安装") { pkg in
                let presentation = PackageInstalledVersionPresentation.make(for: pkg)
                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.versionText)
                        .foregroundStyle(.secondary)
                    if let sourceLabel = presentation.sourceLabel {
                        Text(sourceLabel)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if let secondaryText = presentation.secondaryText {
                        Text(secondaryText)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .help(presentation.helpText)
                .accessibilityLabel(presentation.visibleText)
            }
            TableColumn(isLibrary ? "仓库最新版" : "最新版") { pkg in
                // --- BEGIN APPEND: UI RepoVersion C3-R1-STRICT-R2 ---
                let presentation = PackageVersionTablePresentation.make(for: pkg, isLibrary: isLibrary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.versionText)
                        .bold()
                    if let label = presentation.differenceLabel {
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(versionDifferenceLabelColor(for: presentation.differenceKind))
                    }
                }
                .help(presentation.helpText)
                .accessibilityLabel(presentation.visibleText)
                // --- END APPEND: UI RepoVersion C3-R1-STRICT-R2 ---
            }

            // --- BEGIN APPEND: UI Column Size C3-R1-STRICT-R2 ---
            TableColumn("大小") { pkg in
                let estimate = PackageSizeEstimate.estimate(
                    for: pkg,
                    context: isLibrary ? .installedList : .upgradeCandidate
                )
                Text(appState.formatPackageSize(estimate))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    .help(estimate.helpText)
            }.width(75)
            // --- END APPEND: UI Column Size C3-R1-STRICT-R2 ---

            TableColumn("操作") { pkg in
                if appState.processingID == pkg.id { ProgressView().controlSize(.small).scaleEffect(0.8).accessibilityLabel("正在处理 \(pkg.name)") }
	                else if appState.isEverythingBusy { Text("-").foregroundStyle(.tertiary).help("当前有任务正在运行，完成或停止后可继续操作。").accessibilityLabel("操作暂不可用").accessibilityHint("当前有任务正在运行，完成或停止后可继续操作。") }
                else if isLibrary {
                    if pkg.isLeaf { Button("卸载") { appState.selectedPackage = pkg; appState.showUninstallConfirmation = true }.buttonStyle(.bordered).controlSize(.small).tint(.red).help("叶子包通常没有被其他包依赖，卸载前仍会再次确认。").accessibilityHint("卸载前会再次确认。") }
                    else { Text("-").foregroundStyle(.tertiary).help("此项不是叶子包，可能仍被其他包依赖；默认不直接提供卸载按钮。").accessibilityLabel("卸载暂不可用").accessibilityHint("此项不是叶子包，可能仍被其他包依赖。") }
                } else if !PackageUpgradeScope.isOrdinaryUpgradeCandidate(pkg) {
                    Button("贪婪同步") { appState.confirmGreedySync(pkg) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("显式高级动作：通过 Homebrew 重新下载并覆盖安装此自更新 Cask；普通批量升级不会处理它。")
                        .accessibilityLabel("贪婪同步 \(pkg.name)")
                        .accessibilityHint("打开确认弹窗，说明重新下载、覆盖安装和 App 可能已由内部更新器更新。")
                } else { Button("升级") { appState.upgrade(pkgs: [pkg]) }.buttonStyle(.bordered).controlSize(.small).accessibilityHint("升级 \(pkg.name)。") }
            }.width(90)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func versionDifferenceLabelColor(for difference: PackageVersionDifferenceKind) -> Color {
        switch difference {
        case .none, .caskMetadata, .autoUpdatingCask:
            return .secondary
        case .formulaRevision:
            return .green
        case .outdatedCandidate, .unknownRawDifference:
            return .orange
        }
    }
}

struct PackageStateBadgeView: View {
    let badge: PackageStateBadge

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(color)
            .font(.caption2)
            .help("\(badge.title)：\(badge.explanation)")
            .accessibilityLabel(accessibilityTitle)
            .accessibilityHint(badge.explanation)
    }

    private var symbol: String {
        switch badge.kind {
        case "leaf": return "leaf.fill"
        case "pinned": return "pin.fill"
        case "auto-updates": return "arrow.triangle.2.circlepath.circle.fill"
        case "outdated-candidate", "formula-revision", "auto-updating-version", "version-raw-diff", "repo-diff": return "bolt.fill"
        case "cask-metadata": return "info.circle"
        case "size-unknown": return "questionmark.circle"
        case "action-unavailable": return "minus.circle"
        default: return "tag"
        }
    }

    private var color: Color {
        switch badge.severity {
        case .info: return .secondary
        case .attention: return .green
        case .warning: return .orange
        }
    }

    private var accessibilityTitle: String {
        switch badge.kind {
        case "leaf": return "叶子包"
        case "pinned": return "已锁定"
        case "auto-updates": return "自更新 Cask"
        case "outdated-candidate": return "可升级"
        case "formula-revision": return "Formula revision 差异"
        case "auto-updating-version": return "自更新 App 差异"
        case "version-raw-diff": return "版本差异待确认"
        case "cask-metadata": return "Cask 元数据差异"
        case "repo-diff": return "版本差异"
        case "size-unknown": return "酒窖大小未知"
        case "action-unavailable": return "操作暂不可用"
        default: return "状态标签"
        }
    }
}
struct FooterArea: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var runtimeModel: RuntimeDoctorViewModel

    var body: some View {
        VStack(spacing: 0) {
            if appState.showLogSheet {
                LogListView()
                    .frame(height: MainContentLayout.logPanelHeight)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(spacing: 10) {
                Button {
                    withAnimation { appState.showLogSheet.toggle() }
                } label: {
                    Label(appState.showLogSheet ? "隐藏日志" : "查看日志", systemImage: "list.bullet.rectangle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                if appState.activeTab != .runtime {
                    Button {
                        appState.runCleanup()
                    } label: {
                        Image(systemName: "trash").accessibilityHidden(true)
                    }
                    .buttonStyle(.plain)
                    .disabled(appState.isEverythingBusy)
                    .help(appState.isEverythingBusy ? "当前有任务正在运行，不能同时清理缓存。" : "清理 Homebrew 缓存和旧版本。")
                    .accessibilityLabel("清理缓存")
                    .accessibilityHint(appState.isEverythingBusy ? "当前有任务正在运行，不能同时清理缓存。" : "清理 Homebrew 缓存和旧版本。")
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)
                }
                EventCenterMenu()
                Spacer()
                FooterRecentStatusView(snapshot: footerSnapshot, isFailure: appState.hasFailureEvent)
                    .layoutPriority(-1)
                if appState.activeTab == .dashboard {
                    Menu {
                        Button("全部升级") { appState.showUpgradeConfirmation = true }
                        Button("导出 Brewfile...") { appState.exportBrewfile() }
                    } label: {
                        Text("批量操作")
                    }
                    .menuStyle(.borderedButton)
                    .disabled(appState.ordinaryUpgradeCount == 0 || appState.isEverythingBusy)
                    .help(appState.isEverythingBusy ? "当前有任务正在运行，完成或停止后再批量操作。" : (appState.ordinaryUpgradeCount == 0 ? "当前没有普通可升级项目；自更新 Cask 仅作为关注项显示，Brewfile 可从菜单栏导出。" : "升级全部普通可更新项目；自更新 Cask 不会进入本次批量升级。"))
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)
                }
            }
            .frame(minHeight: MainContentLayout.footerStatusBarMinHeight)
            .padding(.horizontal, 10)
            .background(.ultraThinMaterial)
        }
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .clipped()
    }

    private var footerSnapshot: FooterTimeSnapshot {
        if appState.activity.isBusy {
            return FooterTimeSnapshot(
                lastCheckTime: appState.lastCheckTime,
                lastLibraryRefreshAt: appState.lastLibraryRefreshAt,
                lastBrewUpdateAt: appState.lastBrewUpdateAt,
                runtimePathStatus: "\(appState.activity.description) · 日志 \(appState.logs.count) 条",
                runtimePathDetail: "当前有任务正在执行，底栏优先显示活动状态；完成后恢复最近关键状态组。"
            )
        }
        return FooterTimeSnapshot(
            lastCheckTime: appState.lastCheckTime,
            lastLibraryRefreshAt: appState.lastLibraryRefreshAt,
            lastBrewUpdateAt: appState.lastBrewUpdateAt,
            runtimePathStatus: runtimePathStatus.value,
            runtimePathDetail: runtimePathStatus.detail
        )
    }

    private var runtimePathStatus: (value: String, detail: String) {
        if runtimeModel.isLoading {
            return ("扫描中", "Runtime Doctor 正在刷新 Node / Python 与 PATH 快照。")
        }
        if let event = runtimeModel.latestRuntimeEvent,
           event.relatedActionID == RuntimeTrustedPathUnion.currentSessionActionID {
            switch event.verificationStatus {
            case .passed:
                return ("当前会话已对齐", "\(event.detail) 这只代表 PATH 当前会话状态，不代表 Runtime 全局工具 latest 已全部复核。")
            case .pendingManualAction:
                return ("验证命令已复制", "\(event.detail) 这只代表 PATH 当前会话验证命令，不代表 Runtime 全局工具 latest 已全部复核。")
            case .failed, .unchanged:
                return ("需要复核", event.detail)
            case .notRequired:
                return ("无需验证", event.detail)
            }
        }
        let union = runtimeModel.currentSessionTrustedPathUnion
        if union.isEmpty {
            return ("未形成 union", "当前没有可用于 Minimal Trusted PATH union 的可信入口；下一步：打开运行时诊断并刷新。")
        }
        return ("可对齐 union", "\(union.scopeDescription) 当前会话 PATH 是 Cellar 进程全局共享状态；这不代表 Runtime 全局工具 latest 已全部复核。")
    }
}

enum FooterRecentStatusLayout {
    static let expandedMaxWidth: CGFloat = 520
    static let mediumMaxWidth: CGFloat = 360
    static let compactMaxWidth: CGFloat = 240

    nonisolated static func latestItem(from items: [FooterStatusItem], snapshot: FooterTimeSnapshot) -> FooterStatusItem? {
        if snapshot.runtimePathDetail?.contains("当前有任务") == true,
           let runtimeItem = items.first(where: { $0.id == "runtime-path" }) {
            return runtimeItem
        }
        return items
            .filter { $0.date != nil }
            .max(by: { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) })
            ?? items.first
    }

    nonisolated static func expandedItems(from items: [FooterStatusItem], latestItem: FooterStatusItem) -> [FooterStatusItem] {
        uniqueStable([latestItem] + items).prefix(4).map { $0 }
    }

    nonisolated static func mediumItems(from items: [FooterStatusItem], latestItem: FooterStatusItem) -> [FooterStatusItem] {
        uniqueStable([latestItem] + items).prefix(2).map { $0 }
    }

    nonisolated static func compactItems(latestItem: FooterStatusItem) -> [FooterStatusItem] {
        [latestItem]
    }

    nonisolated private static func uniqueStable(_ items: [FooterStatusItem]) -> [FooterStatusItem] {
        var seen: Set<String> = []
        return items.filter { seen.insert($0.id).inserted }
    }
}

struct FooterRecentStatusView: View {
    let snapshot: FooterTimeSnapshot
    let isFailure: Bool

    private var items: [FooterStatusItem] {
        FooterStatusGroupFormatter.items(from: snapshot)
    }

    private var latestItem: FooterStatusItem {
        FooterRecentStatusLayout.latestItem(from: items, snapshot: snapshot) ?? items.first!
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                ForEach(FooterRecentStatusLayout.expandedItems(from: items, latestItem: latestItem)) { item in
                    FooterStatusPill(item: item, isProminent: item.id == latestItem.id)
                }
                FooterStatusMenu(items: items)
            }
            .frame(maxWidth: FooterRecentStatusLayout.expandedMaxWidth, alignment: .trailing)

            HStack(spacing: 8) {
                ForEach(FooterRecentStatusLayout.mediumItems(from: items, latestItem: latestItem)) { item in
                    FooterStatusPill(item: item, isProminent: item.id == latestItem.id)
                }
                FooterStatusMenu(items: items)
            }
            .frame(maxWidth: FooterRecentStatusLayout.mediumMaxWidth, alignment: .trailing)

            HStack(spacing: 8) {
                ForEach(FooterRecentStatusLayout.compactItems(latestItem: latestItem)) { item in
                    FooterStatusPill(item: item, isProminent: true)
                }
                FooterStatusMenu(items: items)
            }
            .frame(maxWidth: FooterRecentStatusLayout.compactMaxWidth, alignment: .trailing)
        }
        .frame(maxWidth: FooterRecentStatusLayout.expandedMaxWidth, alignment: .trailing)
        .foregroundStyle(isFailure ? .red : .secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("最近关键状态")
        .accessibilityValue(items.map(\.shortText).joined(separator: "，"))
    }
}

struct FooterStatusPill: View {
    let item: FooterStatusItem
    let isProminent: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(item.title)
                .foregroundStyle(.secondary)
            Text(item.value)
                .foregroundStyle(isProminent ? .primary : .secondary)
        }
        .font(.caption2)
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor).opacity(isProminent ? 0.7 : 0.35), in: Capsule())
        .frame(maxWidth: 150)
        .help("\(item.shortText)。\(item.detail)")
        .accessibilityLabel(item.title)
        .accessibilityValue(item.value)
        .accessibilityHint(item.detail)
    }
}

struct FooterStatusMenu: View {
    let items: [FooterStatusItem]

    var body: some View {
        Menu {
            ForEach(items) { item in
                VStack(alignment: .leading) {
                    Text(item.shortText)
                    Text(item.detail)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .accessibilityHidden(true)
        }
        .menuStyle(.borderlessButton)
        .help("查看最近检查、刷新、brew update 和 PATH 当前会话状态。")
        .accessibilityLabel("最近状态详情")
        .accessibilityHint("打开最近关键状态组。")
    }
}

struct EventCenterMenu: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Menu {
            Section("正在执行") {
                if appState.activeAppEvents.isEmpty {
                    Text("当前没有正在执行的任务")
                } else {
                    ForEach(appState.activeAppEvents.prefix(5)) { event in
                        eventButton(event)
                    }
                }
            }
            Section("最近事件") {
                if appState.appEvents.isEmpty {
                    Text("暂无历史事件")
                } else {
                    ForEach(appState.appEvents.prefix(8)) { event in
                        eventButton(event)
                    }
                }
            }
            Divider()
            Button("打开高级日志") {
                withAnimation { appState.showLogSheet = true }
            }
        } label: {
            Label(eventTitle, systemImage: eventSymbol)
                .foregroundStyle(eventColor)
        }
        .menuStyle(.borderlessButton)
        .help("结构化事件中心：区分正在执行和最近历史事件。")
        .accessibilityLabel("事件中心")
        .accessibilityHint("查看正在执行的任务和最近事件。")
    }

    private func eventButton(_ event: AppEvent) -> some View {
        Button {
            withAnimation { appState.showLogSheet = true }
        } label: {
            VStack(alignment: .leading) {
                Text("\(event.source.rawValue)：\(event.title)")
                Text("\(event.date.formatted(date: .omitted, time: .standard)) · \(event.statusText)")
                Text(event.detail)
            }
        }
        .accessibilityLabel("\(event.source.rawValue)，\(event.title)，\(event.statusText)")
        .accessibilityHint("打开高级日志查看详情。")
    }

    private var visibleEvent: AppEvent? {
        appState.activeAppEvents.first ?? appState.appEvents.first
    }

    private var eventTitle: String {
        if let event = appState.activeAppEvents.first {
            return "\(event.source.rawValue)：\(event.title)"
        }
        if let event = appState.appEvents.first {
            return "\(event.source.rawValue)：\(event.title)"
        }
        return "事件中心"
    }

    private var eventSymbol: String {
        switch visibleEvent?.severity {
        case .failure?: return "exclamationmark.triangle.fill"
        case .attention?: return "info.circle.fill"
        case .success?: return "checkmark.circle.fill"
        case .info?, nil: return "list.bullet.clipboard"
        }
    }

    private var eventColor: Color {
        switch visibleEvent?.severity {
        case .failure?: return .red
        case .attention?: return .orange
        case .success?: return .green
        case .info?, nil: return .secondary
        }
    }
}

struct LogListView: View {
    @EnvironmentObject var appState: AppState
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("运行日志")
                        .font(.caption)
                        .bold()
                        .foregroundStyle(.secondary)
                    Text("默认显示摘要；原始命令和输出可在每行详情中查看或复制。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("复制全部原始日志") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(appState.getLogsString(), forType: .string)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("复制完整原始日志，包含命令、brew 输出、PATH 命令和系统返回，便于审计和排障。")
            }
            .padding(8)
            .background(Color(nsColor: .separatorColor))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(appState.logs) { log in
                            LogRowView(log: log)
                                .id(log.id)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: appState.logs) { _, logs in
                    if let last = logs.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }.background(Color(nsColor: .textBackgroundColor))
    }
}

struct LogRowView: View {
    let log: LogEntry
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(log.timestamp.formatted(.dateTime.hour().minute().second()))
                    .font(.caption2)
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)
                Text(log.type.displayName)
                    .font(.caption2)
                    .foregroundStyle(log.type.color)
                    .frame(width: 36, alignment: .leading)
                Text(log.summaryText)
                    .font(.caption)
                    .foregroundStyle(log.type.color)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if log.hasRawDetail {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up.circle" : "chevron.down.circle")
                            .accessibilityHidden(true)
                    }
                    .buttonStyle(.borderless)
                    .help(isExpanded ? "收起原始日志详情。" : "展开原始命令或输出详情。")
                    .accessibilityLabel(isExpanded ? "收起原始日志详情" : "展开原始日志详情")
                }
            }

            if isExpanded, log.hasRawDetail {
                VStack(alignment: .leading, spacing: 6) {
                    Text(log.message)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                    Button("复制此条原始日志") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(log.message, forType: .string)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .help("复制这一条原始日志，保留命令、PATH 或 brew 输出原文。")
                }
                .padding(.leading, 104)
                .padding(.vertical, 4)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(log.type.displayName)，\(log.summaryText)")
        .accessibilityHint(log.hasRawDetail ? "可展开查看或复制原始日志。" : "该条日志没有额外原始详情。")
    }
}
struct InfoView: View { let info: BrewInfo; @Environment(\.dismiss) var dismiss; var body: some View { VStack(alignment: .leading, spacing: 16) { HStack { Text(info.name).font(.title.bold()); Spacer(); Button("关闭") { dismiss() } }; if let desc = info.desc { Text(desc).font(.body) }; Divider(); Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) { if let hp = info.homepage, let url = URL(string: hp) { GridRow { Text("官网:").bold(); Link(hp, destination: url) } }; GridRow { Text("版本:").bold(); Text(info.stableVersion) }; if let deps = info.dependencies, !deps.isEmpty { GridRow(alignment: .top) { Text("依赖:").bold(); Text(deps.joined(separator: ", ")) } }; if let conf = info.conflicts_with, !conf.isEmpty { GridRow(alignment: .top) { Text("冲突:").bold(); Text(conf.joined(separator: ", ")).foregroundStyle(.red) } } }; if let cav = info.caveats { Divider(); Text("注意事项:").font(.headline); ScrollView { Text(cav).font(.caption.monospaced()) } } }.padding().frame(width: 500, height: 400) } }
struct EmptyView: View {
    let title: String
    var nextStep: String = "下一步：刷新当前页面。"
    @EnvironmentObject var appState: AppState
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green.opacity(0.8))
                .accessibilityLabel("空状态")
            Text(title).font(.title3).foregroundStyle(.secondary)
            Text(nextStep).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)

            // --- BEGIN APPEND: EmptyView Extend C3-R1-STRICT-R2 ---
            if appState.repoDiffCount > 0 {
                VStack(spacing: 4) {
                    Text("发现 \(appState.repoDiffCount) 个版本差异（不计入更新总数）").font(.caption).foregroundStyle(.secondary)
                    Text("可在列表中查看 Formula revision、自更新 App 或待确认 raw 差异。").font(.system(size: 10)).foregroundStyle(.tertiary)
                }.padding(.top, 4).multilineTextAlignment(.center)
            }
            // --- END APPEND: EmptyView Extend C3-R1-STRICT-R2 ---
        }
    }
}
struct ErrorView: View {
    let msg: String
    var nextStep: String = "下一步：复制错误信息，查看事件中心或高级日志后再重试。"
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 48)).foregroundStyle(.red.opacity(0.8))
                .accessibilityLabel("需要处理")
            Text("需要处理")
                .font(.headline)
            Text(msg)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .multilineTextAlignment(.center)
            Text(nextStep)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("复制错误信息") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(msg, forType: .string)
            }
            .help("复制错误信息，便于在高级日志或审计记录中定位问题。")
        }
    }
}
struct VisualEffectView: NSViewRepresentable { let material: NSVisualEffectView.Material; let blendingMode: NSVisualEffectView.BlendingMode; func makeNSView(context: Context) -> NSVisualEffectView { let v = NSVisualEffectView(); v.material = material; v.blendingMode = blendingMode; v.state = .active; return v }; func updateNSView(_ nsView: NSVisualEffectView, context: Context) { } }
