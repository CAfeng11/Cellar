import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

struct RuntimeDoctorView: View {
    @ObservedObject var model: RuntimeDoctorViewModel
    @EnvironmentObject private var appState: AppState

    var body: some View {
        GeometryReader { proxy in
            let contentWidth = max(proxy.size.width - 40, 320)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    RuntimeToolbar(model: model, availableWidth: contentWidth)
                    if !model.dashboardSnapshots.isEmpty {
                        RuntimeDashboardSection(
                            snapshots: model.dashboardSnapshots,
                            currentRuntime: model.currentRuntime,
                            availableWidth: contentWidth,
                            selectRuntime: model.selectRuntime(_:))
                    }
                    if let snapshot = model.snapshot {
                        RuntimeDecisionPanel(snapshot: snapshot, model: model)
                        RuntimeOverviewGrid(snapshot: snapshot, availableWidth: contentWidth)
                        RuntimeManagersSection(snapshot: snapshot)
                        if snapshot.supportsPackageActions || snapshot.kind == .python {
                            RuntimePackagesSection(snapshot: snapshot, model: model)
                        }
                        RuntimePathDiffPanel(snapshot: snapshot)
                        RuntimeRepairPanel(snapshot: snapshot, model: model)
                        RuntimeRepairHistoryPanel(entries: model.repairHistory)
                        RuntimeGovernancePanel(snapshot: snapshot, model: model)
                        RuntimeInstalledSection(snapshot: snapshot, model: model)
                        RuntimeDiagnosticsSection(snapshot: snapshot)
                    } else if model.isLoading {
                        ProgressView("正在整理 Runtime Doctor 快照...")
                            .frame(maxWidth: .infinity, minHeight: 320)
                    } else if let errorMessage = model.errorMessage {
                        ErrorView(msg: errorMessage, nextStep: "下一步：刷新 Runtime Doctor；如仍失败，请导出报告或查看高级日志。")
                            .frame(maxWidth: .infinity, minHeight: 320)
                    } else {
                        EmptyView(title: "还没有 Runtime Doctor 快照", nextStep: ProductCopy.emptyStateNextStep(for: .runtime))
                            .frame(maxWidth: .infinity, minHeight: 320)
                    }
                }
                .frame(width: contentWidth, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .padding(.bottom, MainContentLayout.scrollEndPadding)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .task {
            model.installLogger { message, type, reveal in
                appState.recordExternalLog(message, type: type, reveal: reveal)
            }
            model.refreshIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .runtimeRefreshRequested)) { _ in
            model.refresh()
        }
        .alert("确认卸载全局包?", isPresented: Binding(get: { model.uninstallCandidate != nil }, set: { if !$0 { model.uninstallCandidate = nil } })) {
            Button("取消", role: .cancel) { model.uninstallCandidate = nil }
            Button("卸载", role: .destructive) { model.uninstallConfirmed() }
        } message: {
            Text("将通过当前激活的 npm 卸载 \(model.uninstallCandidate?.name ?? "")。")
        }
        .alert("查看修复指引", isPresented: Binding(get: { model.pendingRepairPlan != nil }, set: { if !$0 { model.pendingRepairPlan = nil } })) {
            Button("关闭", role: .cancel) { model.pendingRepairPlan = nil }
            Button("复制指引") { model.copyRepairPlanGuide() }
            if model.pendingRepairPlan?.canRunAutomatedFixes == true {
                Button("执行可自动修复项", role: .none) { model.runRepairPlan() }
            }
        } message: {
            Text(([model.pendingRepairPlan?.summary] + (model.pendingRepairPlan?.steps ?? [])).compactMap { $0 }.joined(separator: "\n\n"))
        }
    }
}

struct RuntimeRepairPlan {
    let summary: String
    let steps: [String]
    let canRunAutomatedFixes: Bool
}

private struct RuntimeToolbar: View {
    @ObservedObject var model: RuntimeDoctorViewModel
    @EnvironmentObject private var appState: AppState
    let availableWidth: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("运行时", selection: Binding(get: { model.currentRuntime }, set: { model.selectRuntime($0) })) {
                ForEach(RuntimeKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
            if availableWidth >= 760 {
                HStack(alignment: .top, spacing: 12) {
                    titleBlock
                    Spacer(minLength: 16)
                    actionButtons
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    titleBlock
                    actionButtons
                }
            }
            if let msg = model.actionMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let event = model.latestRuntimeEvent {
                HStack(spacing: 8) {
                    Image(systemName: event.verificationStatus == .passed ? "checkmark.seal.fill" : "info.circle")
                        .foregroundStyle(event.verificationStatus == .passed ? .green : .secondary)
                        .accessibilityLabel(event.verificationStatus.displayName)
                        .accessibilityHint("最近 Runtime Doctor 动作状态。")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title)
                            .font(.caption.weight(.semibold))
                        Text(event.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Runtime Doctor")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
            Text("查看 \(model.currentRuntime.displayName) 来源、路径策略与工具入口状态。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actionButtons: some View {
        Button("导出诊断报告") {
            model.exportReport(
                homebrewIssue: appState.settings.latestReliabilityIssue,
                appEvents: appState.appEvents,
                operationSummary: appState.latestBrewOperationSummary,
                outdatedSnapshotProvenance: appState.outdatedSnapshotProvenance,
                installedSnapshotProvenance: appState.installedSnapshotProvenance
            )
        }
            .buttonStyle(.bordered)
            .disabled(model.snapshot == nil)
            .help(model.snapshot == nil ? "请先刷新 Runtime Doctor，生成诊断快照后再导出。" : "导出包含当前诊断快照、PATH Policy、Homebrew 可靠性诊断、最近关键事件和 Runtime 修复历史的报告。")
    }
}

private struct RuntimeDashboardSection: View {
    let snapshots: [RuntimeSnapshot]
    let currentRuntime: RuntimeKind
    let availableWidth: CGFloat
    let selectRuntime: (RuntimeKind) -> Void

    private var nodeSnapshot: RuntimeSnapshot? {
        snapshots.first(where: { $0.kind == .node })
    }

    private var pythonSnapshot: RuntimeSnapshot? {
        snapshots.first(where: { $0.kind == .python })
    }

    private var combinedToolCount: Int {
        snapshots.reduce(into: 0) { partialResult, snapshot in
            if snapshot.kind == .python {
                partialResult += snapshot.toolEntries.filter(\.isVisibleInShell).count
            } else {
                partialResult += snapshot.globalPackages.count
            }
        }
    }

    private var needsAttentionCount: Int {
        snapshots.filter { $0.environmentHealth != .healthy }.count
    }

    var body: some View {
        RuntimePanel(title: "总览", subtitle: "先看 Node、Python、路径策略和全局工具入口，再进入单个运行时详情。") {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                if let nodeSnapshot {
                    RuntimeDashboardRuntimeCard(
                        snapshot: nodeSnapshot,
                        isSelected: currentRuntime == .node,
                        selectRuntime: selectRuntime)
                }
                if let pythonSnapshot {
                    RuntimeDashboardRuntimeCard(
                        snapshot: pythonSnapshot,
                        isSelected: currentRuntime == .python,
                        selectRuntime: selectRuntime)
                }
                RuntimeCard(
                    title: "PATH Policy",
                    line1: "Minimal Trusted PATH（推荐）",
                    line2: "当前会话 PATH 为 Cellar 全局共享",
                    line3: "默认只保留核心可信路径；一个运行时完成对齐后，另一个运行时也可能同步变得可见。",
                    status: needsAttentionCount == 0 ? "策略正常" : "关注 \(needsAttentionCount) 项",
                    tint: needsAttentionCount == 0 ? .green : .orange
                )
                RuntimeCard(
                    title: "全局工具入口",
                    line1: "\(combinedToolCount) 个入口已纳入观察",
                    line2: nodeSnapshot.map { "Node: \($0.dashboardToolSummary)" } ?? "Node: 未加载",
                    line3: pythonSnapshot.map { "Python: \($0.dashboardToolSummary)" } ?? "Python: 未加载",
                    status: "先看总览，再看详情",
                    tint: .teal
                )
            }
            .padding(16)
        }
    }

    private var columns: [GridItem] {
        let count: Int
        if availableWidth >= 1180 {
            count = 4
        } else if availableWidth >= 680 {
            count = 2
        } else {
            count = 1
        }
        return Array(repeating: GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: 12, alignment: .top), count: count)
    }
}

private struct RuntimeDashboardRuntimeCard: View {
    let snapshot: RuntimeSnapshot
    let isSelected: Bool
    let selectRuntime: (RuntimeKind) -> Void

    var body: some View {
        Button {
            selectRuntime(snapshot.kind)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(snapshot.runtimeDisplayName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(snapshot.dashboardHeadline)
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    Spacer(minLength: 8)
                    if isSelected {
                        Text("当前详情")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.blue.opacity(0.12))
                            )
                    }
                }

                Text(snapshot.dashboardVersionLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(snapshot.dashboardExplanationLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 6)

                HStack {
                    Text("工具：\(snapshot.dashboardToolSummary)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(isSelected ? "正在查看" : "查看详情")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(snapshot.environmentHealth.color)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.thinMaterial.opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke((isSelected ? Color.blue : snapshot.environmentHealth.color).opacity(isSelected ? 0.28 : 0.12), lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct RuntimeOverviewGrid: View {
    let snapshot: RuntimeSnapshot
    let availableWidth: CGFloat

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            RuntimeCard(
                title: "当前运行时",
                line1: snapshot.runtimeEnvironmentHeadline,
                line2: snapshot.guiEnvironmentLine,
                line3: snapshot.environmentExplanationLine,
                status: snapshot.primarySuggestion,
                tint: snapshot.activeNodeStatus.color
            )
            RuntimeCard(
                title: snapshot.primaryPackageManagerDisplayName,
                line1: snapshot.packageManagerHeadline,
                line2: snapshot.packageManagerObservationLine,
                line3: snapshot.packageManagerExplanationLine,
                status: packageManagerStatus,
                tint: .blue
            )
            RuntimeCard(
                title: "全局工具",
                line1: snapshot.toolEntriesHeadline,
                line2: snapshot.toolEntriesObservationLine,
                line3: snapshot.toolEntriesExplanationLine,
                status: toolsStatus,
                tint: .teal
            )
            RuntimeCard(
                title: "环境健康度",
                line1: snapshot.shellEnvironmentLine,
                line2: snapshot.guiEnvironmentLine,
                line3: snapshot.environmentExplanationLine,
                status: snapshot.primarySuggestion,
                tint: snapshot.environmentHealth.color
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var columns: [GridItem] {
        let count: Int
        if availableWidth >= 1180 {
            count = 4
        } else if availableWidth >= 680 {
            count = 2
        } else {
            count = 1
        }
        return Array(repeating: GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: 12, alignment: .top), count: count)
    }

    private var packageManagerStatus: String {
        if snapshot.isObservationOnly {
            return "Shell：\(snapshot.loginNpmVersion ?? "未发现")"
        }
        return snapshot.activeNpmPath == nil && snapshot.loginNpmPath != nil ? "建议：统一环境" : "prefix：\(snapshot.npmPrefix ?? "未发现")"
    }

    private var toolsStatus: String {
        if snapshot.isObservationOnly {
            return "观察模式"
        }
        return snapshot.globalBinPath ?? "bin：未发现"
    }

}

private struct RuntimeDecisionPanel: View {
    let snapshot: RuntimeSnapshot
    @ObservedObject var model: RuntimeDoctorViewModel

    var body: some View {
        let trustedUnion = model.currentSessionTrustedPathUnion
        RuntimePanel(title: "推荐运行时", subtitle: "先确认当前应以哪个环境为准，再决定后续操作。") {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(snapshot.recommendedRuntimeTitle, systemImage: "checkmark.shield.fill")
                            .font(.headline)
                            .foregroundStyle(.green)
                        Text(snapshot.recommendedRuntimeVersion)
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                        Text("来源：\(snapshot.recommendedRuntimeSource)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(snapshot.recommendedRuntimeReason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 16)
                    VStack(alignment: .leading, spacing: 6) {
                        Label("GUI 环境", systemImage: snapshot.activeNodePath == nil ? "exclamationmark.triangle.fill" : "display")
                            .font(.headline)
                            .foregroundStyle(snapshot.activeNodePath == nil ? .orange : .blue)
                        Text(snapshot.guiRuntimeTitle)
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                        Text(snapshot.guiRuntimeExplanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider()
                RuntimePolicySection(snapshot: snapshot)
                if snapshot.kind == .node {
                    Divider()
                    HStack(spacing: 10) {
	                        Button("最小可信对齐") { model.adoptMinimalTrustedEnvironment() }
	                            .buttonStyle(.borderedProminent)
	                            .disabled(trustedUnion.isEmpty)
                                .help(trustedUnion.isEmpty ? "当前没有可用于 Minimal Trusted PATH union 的核心路径。" : "按 Minimal Trusted PATH union 更新 Cellar 当前会话全局 PATH，同时服务 Node / Python。")
	                        Button("镜像完整 Shell PATH") { model.adoptFullShellMirror() }
	                            .buttonStyle(.bordered)
	                            .disabled(snapshot.loginPathEntries.isEmpty)
                                .help(snapshot.loginPathEntries.isEmpty ? "当前没有可镜像的登录 Shell PATH。" : "高级排障：仅临时镜像完整 Shell PATH 到当前会话，不作为默认策略。")
	                        Button("持久化 GUI 环境") { model.persistShellEnvironment() }
	                            .buttonStyle(.bordered)
	                            .disabled(!snapshot.needsPersistentGuiAlignment)
                                .help(snapshot.needsPersistentGuiAlignment ? "写入 Minimal Trusted PATH 到当前用户 GUI 会话，并提供回滚命令。" : "当前不需要写入 GUI PATH。")
	                        Button("复制 GUI 修复命令") { model.copyShellPathCommand() }
	                            .buttonStyle(.bordered)
	                            .disabled(snapshot.persistentPathCommand == nil)
                                .help(snapshot.persistentPathCommand == nil ? "当前没有可复制的 GUI PATH 修复命令。" : "复制 GUI PATH 写入命令；复制不会记入修复历史。")
	                        Button("复制 GUI 回滚命令") { model.copyGuiRollbackCommand() }
	                            .buttonStyle(.bordered)
                                .help("复制 `launchctl unsetenv PATH`，用于回滚 GUI PATH 写入。")
                    }
                    Text("“最小可信对齐”会合并 Node / Python 的核心可信入口，只更新 Cellar 当前会话的全局 PATH；这是默认模式，不会完整镜像 Shell PATH。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(snapshot.sharedPathScopeTitle + "。 " + snapshot.sharedPathScopeExplanation)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("高级模式：镜像完整 Shell PATH 可能引入临时路径、系统注入路径或 App 私有路径，仅适合排障时临时使用。")
                        .font(.caption2)
                        .foregroundStyle(.red.opacity(0.9))
                } else if snapshot.kind == .python {
                    Divider()
                    HStack(spacing: 10) {
	                        Button("最小可信对齐") { model.adoptMinimalTrustedEnvironment() }
	                            .buttonStyle(.borderedProminent)
	                            .disabled(trustedUnion.isEmpty)
                                .help(trustedUnion.isEmpty ? "当前没有可用于 Minimal Trusted PATH union 的核心路径。" : "按 Minimal Trusted PATH union 更新 Cellar 当前会话全局 PATH，同时服务 Node / Python。")
	                        Button("复制 GUI 修复命令") { model.copyShellPathCommand() }
	                            .buttonStyle(.bordered)
	                            .disabled(snapshot.persistentPathCommand == nil)
                                .help(snapshot.persistentPathCommand == nil ? "当前没有可复制的 GUI PATH 修复命令。" : "复制 GUI PATH 写入命令；Python 模式不会静默写 shell 配置。")
	                        Button("复制 GUI 回滚命令") { model.copyGuiRollbackCommand() }
	                            .buttonStyle(.bordered)
                                .help("复制 GUI PATH 回滚命令。")
                    }
                    Text("Python 模式默认只提供当前会话级 union 对齐和命令复制，不会替你静默写入 shell 配置。若需要让新启动的 GUI 应用长期继承同一套 PATH，请手动执行复制出的 GUI 修复命令。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(snapshot.sharedPathScopeTitle + "。 " + snapshot.sharedPathScopeExplanation)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(snapshot.sessionAlignmentRollbackNote)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Divider()
                    Text("当前处于 \(snapshot.runtimeDisplayName) 观察模式。这一阶段只解释主来源、Shell / GUI 差异与工具关系，不自动修改 PATH 或 shell 配置。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
    }
}

private struct RuntimeRepairPanel: View {
    let snapshot: RuntimeSnapshot
    @ObservedObject var model: RuntimeDoctorViewModel

    private var trustedUnion: RuntimeTrustedPathUnion {
        model.currentSessionTrustedPathUnion
    }

    var body: some View {
        RuntimePanel(title: "可执行操作", subtitle: "这里整理的是可以立即验证、复制或应用的运行时操作。") {
            VStack(alignment: .leading, spacing: 14) {
                if snapshot.kind == .python {
                    if snapshot.fixSummary.isEmpty {
                        Text("当前没有需要额外提示的 Python 修复建议。Shell、GUI 与工具入口关系已经足够清晰。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(snapshot.fixSummary, id: \.self) { item in
                            Label(item, systemImage: "wrench.and.screwdriver")
                                .font(.callout)
                        }
                    }

                    Divider()

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            pythonRepairButtons
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            pythonRepairButtons
                        }
                    }

                    Text("Shell 配置补丁建议写入 \(snapshot.suggestedShellConfigFile)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(snapshot.shellPatchSnippet)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.primary.opacity(0.045))
                        )
                    if !snapshot.pythonRepairCommandBlock.isEmpty {
                        Text("推荐命令")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(snapshot.pythonRepairCommandBlock)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.primary.opacity(0.045))
                            )
                    }
                    Text("回滚说明：\(snapshot.sessionAlignmentRollbackNote) Shell 补丁类变更只需从配置文件中删除新增行；conda 自动激活可用 `conda config --set auto_activate_base true` 恢复。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if snapshot.isObservationOnly {
                    Text("当前运行时仍处于观察模式。Cellar 会先解释 Python、pip、uv、pipx 与 PATH 的关系，修复建议留到下一阶段。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    if snapshot.fixSummary.isEmpty {
                        Text("当前没有需要额外执行的常规操作。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(snapshot.fixSummary, id: \.self) { item in
                            Label(item, systemImage: "wrench.and.screwdriver")
                                .font(.callout)
                        }
                    }

                    Divider()

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            repairButtons
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            repairButtons
                        }
                    }

                    Text("Shell 配置补丁建议写入 \(snapshot.suggestedShellConfigFile)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(snapshot.shellPatchSnippet)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.primary.opacity(0.045))
                        )
                    Text("GUI 最小可信 PATH")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(snapshot.persistentPathCommand ?? "launchctl setenv PATH \"/opt/homebrew/bin:/opt/homebrew/sbin:$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin\"")
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.primary.opacity(0.045))
                        )
                }
            }
            .padding(16)
        }
    }

    private var repairButtons: some View {
        Group {
	            Button("查看修复指引") { model.prepareRepairPlan() }
	                .buttonStyle(.borderedProminent)
	                .disabled(snapshot.fixSummary.isEmpty)
                    .help(snapshot.fixSummary.isEmpty ? "当前没有需要处理的 Runtime 修复建议。" : "查看按风险拆分的 Runtime 修复指引。")
	            Button("修复 npm prefix") { model.repairNpmPrefix() }
	                .buttonStyle(.bordered)
	                .disabled(!snapshot.needsNpmPrefixRepair)
                    .help(snapshot.needsNpmPrefixRepair ? "将 npm 全局 prefix 调整到用户目录，并记录到修复历史。" : "当前 npm prefix 不需要修复。")
	            Button("复制写入 Shell 的持久化补丁") { model.copyShellPatchSnippet() }
	                .buttonStyle(.bordered)
                    .help("复制 shell PATH 补丁；Cellar 不会静默写入 shell 配置。")
        }
    }

    private var pythonRepairButtons: some View {
        Group {
	            Button("查看修复指引") { model.prepareRepairPlan() }
	                .buttonStyle(.borderedProminent)
	                .disabled(snapshot.fixSummary.isEmpty)
                    .help(snapshot.fixSummary.isEmpty ? "当前没有需要处理的 Python 修复建议。" : "查看 Python 观察与修复建议。")
	            Button("最小可信对齐") { model.adoptMinimalTrustedEnvironment() }
	                .buttonStyle(.bordered)
	                .disabled(trustedUnion.isEmpty)
                    .help(trustedUnion.isEmpty ? "当前没有可用于 Minimal Trusted PATH union 的核心路径。" : "只更新 Cellar 当前会话全局 PATH，同时服务 Node / Python；重启 Cellar 即可回滚。")
	            Button("复制当前会话验证命令") { model.copyCurrentSessionValidationCommand() }
	                .buttonStyle(.bordered)
	                .disabled(trustedUnion.exportCommand == nil)
                    .help(trustedUnion.exportCommand == nil ? "当前没有可复制的 union 会话验证命令。" : "复制 union PATH 命令供手动验证；复制不会记入修复历史。")
	            Button("复制写入 Shell 的持久化补丁") { model.copyShellPatchSnippet() }
	                .buttonStyle(.bordered)
                    .help("复制 shell PATH 补丁；Cellar 不会静默写入 shell 配置。")
        }
    }
}

private struct RuntimeGovernancePanel: View {
    let snapshot: RuntimeSnapshot
    @ObservedObject var model: RuntimeDoctorViewModel

    private var trustedUnion: RuntimeTrustedPathUnion {
        model.currentSessionTrustedPathUnion
    }

    var body: some View {
        RuntimePanel(title: "主来源治理", subtitle: "确定主要运行时来源，并为其他来源保留识别与清理建议。") {
            VStack(alignment: .leading, spacing: 14) {
                Label(snapshot.governanceHeadline, systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.headline)

                Text(snapshot.governanceExplanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let preferred = snapshot.preferredPrimaryRuntime {
                    VStack(alignment: .leading, spacing: 8) {
                        RuntimeMetaPill(title: "推荐主来源", value: preferred.source.rawValue)
                        Text(preferred.path)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }

                if !snapshot.legacyRuntimeCandidates.isEmpty {
                    Divider()
                    Text("建议退场的旧来源")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(snapshot.legacyRuntimeCandidates) { runtime in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(runtime.path)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                            Text("\(runtime.source.rawValue) · \(runtime.version)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Divider()

                if snapshot.supportsAlignmentActions {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            governanceButtons
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            governanceButtons
                        }
                    }
                }

                Text("治理预览")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(snapshot.governancePlanLines.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.045))
                    )
                if let command = trustedUnion.exportCommand {
                    Text("当前会话 union PATH 验证命令")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(command)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.primary.opacity(0.045))
                        )
                }
            }
            .padding(16)
        }
    }

    private var governanceButtons: some View {
        Group {
	            Button("复制 union PATH 验证命令") { model.copyGovernanceCommand() }
	                .buttonStyle(.borderedProminent)
	                .disabled(trustedUnion.exportCommand == nil)
                    .help(trustedUnion.exportCommand == nil ? "当前没有可复制的 union PATH 验证命令。" : "复制当前会话 union PATH 验证命令；该命令不使用单运行时 PATH。")
	            Button("复制 legacy 清理建议") { model.copyLegacyCleanupGuide() }
	                .buttonStyle(.bordered)
                    .help("复制旧运行时清理建议；Cellar 不会自动删除旧来源。")
	            Button("复制写入 Shell 的持久化补丁") { model.copyShellPatchSnippet() }
	                .buttonStyle(.bordered)
                    .help("复制 shell PATH 补丁；需要用户手动写入。")
        }
    }
}

private struct RuntimePathDiffPanel: View {
    let snapshot: RuntimeSnapshot

    var body: some View {
        RuntimePanel(title: "环境差异", subtitle: "直接展示 Shell 与 GUI 的 PATH 差异，帮助判断为什么终端和 Cellar 表现不同。") {
            VStack(alignment: .leading, spacing: 14) {
                if snapshot.guiPathMissingEntries.isEmpty && snapshot.guiPathExtraEntries.isEmpty {
                    Text("当前没有明显的 PATH 差异。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    if !snapshot.guiPathMissingEntries.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Shell 有、GUI 没有")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(snapshot.guiPathMissingEntries, id: \.self) { entry in
                                Text(entry)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    if !snapshot.guiPathExtraEntries.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("GUI 有、Shell 没有")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(snapshot.guiPathExtraEntries, id: \.self) { entry in
                                Text(entry)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
    }
}

private struct RuntimeCard: View {
    let title: String
    let line1: String
    let line2: String
    let line3: String
    let status: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(line1)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .lineLimit(2)
                .minimumScaleFactor(0.75)
            Text(line2)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            Text(line3)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Text(status)
                .font(.caption.weight(.medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.12))
                )
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.thinMaterial.opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(tint.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct RuntimeInstalledSection: View {
    let snapshot: RuntimeSnapshot
    @ObservedObject var model: RuntimeDoctorViewModel

    var body: some View {
        RuntimePanel(title: "已安装运行时", subtitle: "标出谁是来源、谁在生效、谁只是潜在冲突。") {
            VStack(spacing: 0) {
                ForEach(snapshot.runtimes) { runtime in
                    VStack(alignment: .leading, spacing: 12) {
                        ViewThatFits(in: .horizontal) {
                            runtimeHeaderRow(runtime: runtime, model: model)
                            VStack(alignment: .leading, spacing: 10) {
                                runtimeHeaderLead(runtime: runtime)
                                runtimeActions(runtime: runtime, model: model)
                            }
                        }

                        Text(runtime.path)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)

                        Text(runtime.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 18) {
                            RuntimeMetaPill(title: "来源", value: runtime.source.rawValue)
                            RuntimeMetaPill(title: "优先级", value: runtime.priorityLabel)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if runtime.id != snapshot.runtimes.last?.id {
                        Divider()
                    }
                }
            }
        }
    }
}

private struct RuntimeManagersSection: View {
    let snapshot: RuntimeSnapshot

    var body: some View {
        RuntimePanel(title: "运行时工具关系", subtitle: "先说明当前解释器与工具命令是否属于同一环境，再决定是否需要后续治理。") {
            if snapshot.packageManagers.isEmpty {
                Text("当前没有检测到与 \(snapshot.runtimeDisplayName) 相关的工具入口。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else {
                VStack(spacing: 0) {
                    ForEach(snapshot.packageManagers, id: \.id) { manager in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(manager.displayName)
                                .font(.headline)

                            HStack(spacing: 18) {
                                RuntimeMetaPill(title: "GUI", value: manager.guiVersion ?? "未发现")
                                RuntimeMetaPill(title: "Shell", value: manager.loginShellVersion ?? "未发现")
                                if let globalBin = manager.globalBinPath {
                                    RuntimeMetaPill(title: "bin", value: globalBin)
                                }
                            }

                            if let guiPath = manager.guiPath {
                                Text("GUI 路径：\(guiPath)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                            }
                            if let shellPath = manager.loginShellPath {
                                Text("Shell 路径：\(shellPath)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                            }

                            Text(managerExplanation(manager))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if manager.id != snapshot.packageManagers.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func managerExplanation(_ manager: RuntimePackageManagerSnapshot) -> String {
        if manager.identifier == "python-module-pip" {
            return "`python -m pip` 会跟随当前 Python 解释器，是判断 pip 是否属于同一套环境的主参考。"
        }
        if manager.guiPath == nil, manager.loginShellPath != nil {
            return "\(manager.displayName) 在终端中可用，但 GUI 当前没有接入同一环境。"
        }
        if manager.guiPath != nil, manager.loginShellPath != nil, manager.guiPath != manager.loginShellPath {
            return "GUI 与 Shell 正在使用不同的 \(manager.displayName) 入口。"
        }
        if manager.guiPath != nil {
            return "\(manager.displayName) 已可由 Cellar 当前环境直接观察。"
        }
        return "当前没有检测到 \(manager.displayName) 命令入口。"
    }
}

private struct RuntimePackagesSection: View {
    let snapshot: RuntimeSnapshot
    @ObservedObject var model: RuntimeDoctorViewModel

    var body: some View {
        RuntimePanel(title: "全局工具入口", subtitle: "按当前运行时视角查看全局工具，减少 prefix 与 PATH 误判。") {
            if snapshot.globalPackages.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(snapshot.kind == .python ? "当前没有检测到可解释的 Python 工具入口。" : "当前没有检测到可管理的全局工具。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(emptyPackagesNextStep)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                    .padding(16)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if let attention = focusedAttention {
                        focusedAttentionBanner(attention)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                        Divider()
                    }

                    RuntimeGlobalToolStatusGroupsView(groups: RuntimeGlobalToolStatusGroup.make(packages: snapshot.globalPackages))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    Divider()

                    ForEach(snapshot.globalPackages) { package in
                        VStack(alignment: .leading, spacing: 12) {
                            if snapshot.kind == .python {
                                pythonToolRow(package: package)
                            } else {
                                ViewThatFits(in: .horizontal) {
                                    packageHeaderRow(package: package, model: model)
                                    VStack(alignment: .leading, spacing: 10) {
                                        packageHeaderLead(package: package)
                                        packageActions(package: package, model: model)
                                    }
                                }

                                HStack(spacing: 18) {
                                    RuntimeMetaPill(title: "当前版本", value: package.currentVersion)
                                    RuntimeMetaPill(title: "最新版状态", value: package.latestCheckState.displayText)
                                        .help(package.latestCheckState.helpText)
                                    RuntimeMetaPill(title: "可执行命令", value: package.binaries.isEmpty ? "未检测到可执行命令" : package.binaries.joined(separator: ", "))
                                        .help(package.binaries.isEmpty ? "该全局工具没有暴露可识别的命令入口，或当前 PATH 尚未接入对应 bin 目录。下一步：确认 PATH Policy 或重新安装该工具。" : "当前检测到的全局工具命令入口。")
                                }

                                Text(package.installLocation)
                                    .font(.system(size: 12, design: .monospaced))
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                                    .truncationMode(.middle)

                                Text("prefix：\(package.prefix)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(focusedBackground(for: package))
                        if package.id != snapshot.globalPackages.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var emptyPackagesNextStep: String {
        if snapshot.kind == .python {
            return "下一步：刷新 Runtime Doctor；如仍为空，请确认 PATH Policy 是否接入 `~/.local/bin`、pipx 或 uv tool 的工具入口，必要时导出诊断报告复核。"
        }
        return "下一步：刷新 Runtime Doctor；如仍为空，请确认 npm 全局 prefix 与 PATH Policy，或先安装/重新暴露全局工具入口。"
    }

    private var focusedAttention: RuntimeGlobalToolAttentionItem? {
        guard model.focusedGlobalToolAttention?.runtimeKind == snapshot.kind else { return nil }
        return model.focusedGlobalToolAttention
    }

    private func isFocused(_ package: RuntimeGlobalPackage) -> Bool {
        focusedAttention?.toolName == package.name
    }

    private func focusedAttentionBanner(_ attention: RuntimeGlobalToolAttentionItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("当前关注：\(attention.toolName) \(attention.displayStatusText)", systemImage: "scope")
                .font(.callout.weight(.semibold))
                .foregroundStyle(attention.statusKind == .failed ? .orange : .primary)
            Text(attention.detailText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(attention.helpText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("当前关注，\(attention.toolName)，\(attention.displayStatusText)")
        .accessibilityHint(attention.helpText)
    }

    @ViewBuilder
    private func focusedBackground(for package: RuntimeGlobalPackage) -> some View {
        if isFocused(package) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.09))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
        }
    }

    private func pythonToolRow(package: RuntimeGlobalPackage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    packageHeaderLead(package: package)
                    Spacer(minLength: 16)
                    HStack(spacing: 8) {
                        toolVisibilityPill(title: "Shell", visible: package.isVisibleInShell)
                        toolVisibilityPill(title: "GUI", visible: package.isVisibleInGUI)
                        if package.hasNameConflict {
                            RuntimeMetaPill(title: "冲突", value: "同名入口")
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    packageHeaderLead(package: package)
                    HStack(spacing: 8) {
                        toolVisibilityPill(title: "Shell", visible: package.isVisibleInShell)
                        toolVisibilityPill(title: "GUI", visible: package.isVisibleInGUI)
                        if package.hasNameConflict {
                            RuntimeMetaPill(title: "冲突", value: "同名入口")
                        }
                    }
                }
            }

            HStack(spacing: 18) {
                RuntimeMetaPill(title: "来源", value: package.sourceLabel)
                RuntimeMetaPill(title: "当前作用域", value: package.managedByCurrentRuntime ? "是" : "否")
                RuntimeMetaPill(title: "命令", value: package.name)
            }

            if let shellPath = package.shellPath {
                Text("Shell 路径：\(shellPath)")
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            if let guiPath = package.guiPath {
                Text("GUI 路径：\(guiPath)")
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            Text(package.statusNote)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !package.installLocation.isEmpty {
                Text("安装位置：\(package.installLocation)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }

    private func toolVisibilityPill(title: String, visible: Bool) -> some View {
        RuntimeMetaPill(title: title, value: visible ? "可见" : "未接入")
    }
}

private struct RuntimeGlobalToolStatusGroupsView: View {
    let groups: [RuntimeGlobalToolStatusGroup]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最新版状态分组")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(groups) { group in
                        groupPill(group)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(groups) { group in
                        groupPill(group)
                    }
                }
            }
        }
    }

    private func groupPill(_ group: RuntimeGlobalToolStatusGroup) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(group.title) \(group.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(color(for: group.statusKind))
            Text(group.summaryText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(color(for: group.statusKind).opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(color(for: group.statusKind).opacity(0.18), lineWidth: 1)
        )
        .help("\(group.title) \(group.count)：\(group.summaryText)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.title) \(group.count) 个工具")
        .accessibilityValue(group.summaryText)
    }

    private func color(for statusKind: RuntimeGlobalToolAttentionStatusKind) -> Color {
        switch statusKind {
        case .outdated, .failed:
            return .orange
        case .notChecked, .missingLatest:
            return .blue
        case .upToDate:
            return .green
        }
    }
}

private struct RuntimeDiagnosticsSection: View {
    let snapshot: RuntimeSnapshot

    var body: some View {
        RuntimePanel(title: "Runtime Findings", subtitle: "用策略视角解释当前环境，并标明哪些动作值得执行。") {
            if snapshot.issues.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("运行时诊断正常")
                    Text("当前没有发现需要处理的运行时问题。")
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            } else {
                VStack(spacing: 10) {
                    ForEach(snapshot.issues) { issue in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label(issue.title, systemImage: issue.severity.symbol)
                                    .font(.headline)
                                    .foregroundStyle(issue.severity.color)
                                    .lineLimit(2)
                                Spacer()
                                Text(localizedSeverity(issue.severity))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(issue.severity.color)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(issue.severity.color.opacity(0.10))
                                    )
                            }
                            LabeledIssueText(label: "当前", text: issue.currentState)
                            LabeledIssueText(label: "解释", text: issue.explanation)
                            LabeledIssueText(label: "建议", text: issue.recommendation)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(issue.severity.color.opacity(0.07))
                        )
                    }
                }
                .padding(14)
            }
        }
    }

    private func localizedSeverity(_ severity: RuntimeIssueSeverity) -> String {
        switch severity {
        case .info: return "正常"
        case .warning: return "观察"
        case .high: return "高风险"
        }
    }
}

private struct RuntimePolicySection: View {
    let snapshot: RuntimeSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PATH Policy 策略中心")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            RuntimeMetaPill(title: "当前策略", value: snapshot.pathPolicy.title)
            Text(snapshot.pathPolicy.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                policyPills
                VStack(alignment: .leading, spacing: 8) {
                    policyPills
                }
            }
            policyDetails
            RuntimePolicyOptionsList(policies: snapshot.pathPolicyOptions)
        }
    }

    private var policyPills: some View {
        HStack(spacing: 8) {
            RuntimeMetaPill(title: "风险", value: snapshot.pathPolicy.riskLevel.displayName)
            RuntimeMetaPill(title: "回滚", value: snapshot.pathPolicy.rollbackDescription)
        }
    }

    private var policyDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            RuntimePolicyLine(title: "影响范围", values: snapshot.pathPolicy.impactScope)
            RuntimePolicyLine(title: "可执行动作", values: snapshot.pathPolicy.executableActions)
            RuntimePolicyLine(title: snapshot.sharedPathScopeTitle, values: [snapshot.sharedPathScopeExplanation])
        }
    }
}

private struct RuntimePolicyOptionsList: View {
    let policies: [RuntimePATHPolicy]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("可选策略")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(policies) { policy in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(policy.title)
                            .font(.caption.weight(.semibold))
                        Text(policy.riskLevel.displayName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(policy.summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.035))
                )
            }
        }
    }
}

private struct RuntimePolicyLine: View {
    let title: String
    let values: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(values.joined(separator: "、"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct RuntimeRepairHistoryPanel: View {
    let entries: [RuntimeRepairHistoryEntry]

    var body: some View {
        RuntimePanel(title: "Runtime 修复历史", subtitle: "只记录 Cellar 主动执行过的 Runtime 动作；复制命令只进入事件记录。") {
            VStack(alignment: .leading, spacing: 12) {
                if entries.isEmpty {
                    Text("当前会话还没有 Cellar 主动执行过的 Runtime 修复动作。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entries.prefix(8)) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .top, spacing: 8) {
                                Label(entry.title, systemImage: entry.executionResult == .succeeded ? "checkmark.seal" : "exclamationmark.triangle")
                                    .font(.callout.weight(.semibold))
                                Spacer(minLength: 12)
                                Text(entry.runtimeKind.displayName)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                            Text(entry.actionID)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            RuntimePolicyLine(title: "结果", values: ["执行：\(entry.executionResult.rawValue)", "验证：\(entry.verificationResult.displayName)", "风险：\(entry.riskLevel.displayName)"])
                            RuntimePolicyLine(title: "回滚", values: [entry.rollbackCommandOrNote])
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                        )
                    }
                }
            }
            .padding(16)
        }
    }
}

private struct RuntimePanel<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            Divider()
            content
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RuntimeMetaPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }
}

private struct LabeledIssueText: View {
    let label: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(label == "建议" ? .caption : .callout)
                .foregroundStyle(label == "建议" ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private func runtimeHeaderLead(runtime: RuntimeInstallation) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
        Text(runtime.version)
            .font(.system(size: 15, weight: .semibold, design: .monospaced))
        Label(runtime.isActive ? "当前生效" : runtime.statusLabel, systemImage: runtime.isActive ? "checkmark.circle.fill" : runtime.health.symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(runtime.isActive ? Color.green : runtime.health.color)
    }
}

private func runtimeActions(runtime: RuntimeInstallation, model: RuntimeDoctorViewModel) -> some View {
    HStack(spacing: 8) {
        Button("启用建议") { model.copyActivationHint(for: runtime) }
            .buttonStyle(.borderless)
        Button("复制路径") { model.copy(runtime.path) }
            .buttonStyle(.borderless)
        Button("在 Finder 中显示") { model.reveal(path: runtime.path) }
            .buttonStyle(.borderless)
    }
    .font(.caption)
}

private func runtimeHeaderRow(runtime: RuntimeInstallation, model: RuntimeDoctorViewModel) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
        runtimeHeaderLead(runtime: runtime)
        Spacer(minLength: 12)
        runtimeActions(runtime: runtime, model: model)
    }
}

private func packageHeaderLead(package: RuntimeGlobalPackage) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(package.name)
            .font(.headline)
        Text(package.managedByCurrentRuntime ? "由当前运行时管理" : "不在当前运行时作用域内")
            .font(.caption)
            .foregroundStyle(package.managedByCurrentRuntime ? .green : .orange)
    }
}

private func packageActions(package: RuntimeGlobalPackage, model: RuntimeDoctorViewModel) -> some View {
    if model.activePackageActionID == package.id {
        return AnyView(ProgressView().controlSize(.small))
    }
    return AnyView(
        HStack(spacing: 8) {
            Button("更新") { model.update(package) }
                .buttonStyle(.borderless)
                .disabled(!package.isOutdated)
                .help(package.isOutdated ? "通过当前 npm 更新该全局工具。" : package.latestCheckState.helpText)
            Button("重装") { model.reinstall(package) }
                .buttonStyle(.borderless)
                .help("通过当前 npm 重新安装该全局工具。")
            Button("卸载") { model.uninstallCandidate = package }
                .buttonStyle(.borderless)
                .help("通过当前 npm 卸载该全局工具，执行前会再次确认。")
            Button("显示目录") { model.reveal(path: package.installLocation) }
                .buttonStyle(.borderless)
                .help("在 Finder 中显示该工具的安装目录。")
            Button("复制命令") { model.copy("npm install -g \(package.name)") }
                .buttonStyle(.borderless)
                .help("复制安装命令；复制不会记入 Runtime 修复历史。")
        }
        .font(.caption)
    )
}

private func packageHeaderRow(package: RuntimeGlobalPackage, model: RuntimeDoctorViewModel) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
        packageHeaderLead(package: package)
        Spacer(minLength: 12)
        packageActions(package: package, model: model)
    }
}
