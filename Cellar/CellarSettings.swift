import SwiftUI
import Combine
import Network

// MARK: - NOTIFICATIONS
extension Notification.Name {
    static let settingsIntervalChanged = Notification.Name("cellar.settings.intervalChanged")
    static let settingsProxyChanged = Notification.Name("cellar.settings.proxyChanged")
}

// MARK: - 1. SETTINGS MODEL

enum ProxyProtocol: String, Codable, CaseIterable, Identifiable {
    case http = "HTTP"
    case socks5 = "SOCKS5"
    var id: String { rawValue }
}

enum SettingsReliabilitySection: String, Codable, CaseIterable, Identifiable, Sendable {
    case connection
    case homebrewService
    case maintenance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connection: return "连接"
        case .homebrewService: return "Homebrew 服务"
        case .maintenance: return "维护"
        }
    }
}

extension BrewReliabilityIssue {
    var settingsSection: SettingsReliabilitySection {
        switch kind {
        case .network, .dns, .proxy:
            return .connection
        case .endpoint, .brewMissing, .permission, .unknown:
            return .homebrewService
        }
    }
}

// === BEGIN PATCH BLOCK: SettingsModel v1 ===
// [Intent] Add autoMaintenanceEnabled field to persistent settings.
// [Invariants] Defaults to true. Codable for storage.
// [Risk] low
struct AppSettings: Codable, Equatable, Sendable {
    // Proxy
    var brewProxyEnabled: Bool = false
    var proxyProtocol: ProxyProtocol = .http
    var proxyHost: String = "127.0.0.1"
    var proxyPort: Int = 7897

    // Maintenance
    var autoMaintenanceEnabled: Bool = true
    var refreshIntervalSec: Int = 7200
    var updateIntervalSec: Int = 86400

    var proxyPortString: String {
        get { String(proxyPort) }
        set { if let v = Int(newValue), v > 0, v <= 65535 { proxyPort = v } }
    }
}
// --- code ends ---
// === END PATCH BLOCK: SettingsModel v1 ===

@MainActor
final class SettingsStore: ObservableObject {
    @Published var config: AppSettings
    @Published var latestReliabilityIssue: BrewReliabilityIssue?
    @Published var focusedSection: SettingsReliabilitySection?
    private var lastSavedConfig: AppSettings
    private var cancellables = Set<AnyCancellable>()

    init() {
        let key = "cellar.appSettings.v1.4.1"
        let initialSettings: AppSettings

        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            initialSettings = decoded
        } else {
            initialSettings = AppSettings()
        }

        self.config = initialSettings
        self.lastSavedConfig = initialSettings

        $config
            .removeDuplicates()
            .debounce(for: 0.5, scheduler: RunLoop.main)
            .sink { [weak self] newConfig in
                self?.handleConfigChange(newConfig, key: key)
            }
            .store(in: &cancellables)
    }

// === BEGIN PATCH BLOCK: ConfigChangeHandler v1 ===
// [Intent] Detect changes to maintenance settings and notify the app to restart loop.
// [Invariants] Triggers .settingsIntervalChanged for autoMaintenanceEnabled or interval changes.
// [Risk] low
    private func handleConfigChange(_ newConfig: AppSettings, key: String) {
        if let data = try? JSONEncoder().encode(newConfig) { UserDefaults.standard.set(data, forKey: key) }
        let old = lastSavedConfig

        if old.autoMaintenanceEnabled != newConfig.autoMaintenanceEnabled || old.refreshIntervalSec != newConfig.refreshIntervalSec || old.updateIntervalSec != newConfig.updateIntervalSec {
            NotificationCenter.default.post(name: .settingsIntervalChanged, object: nil)
        }

        if old.brewProxyEnabled != newConfig.brewProxyEnabled || old.proxyProtocol != newConfig.proxyProtocol || old.proxyHost != newConfig.proxyHost || old.proxyPort != newConfig.proxyPort {
            NotificationCenter.default.post(name: .settingsProxyChanged, object: nil)
        }
        lastSavedConfig = newConfig
    }
// --- code ends ---
// === END PATCH BLOCK: ConfigChangeHandler v1 ===
}

// MARK: - 2. NETWORK SERVICE & MODELS

struct ProbeResult: Sendable {
    let success: Bool
    let value: String?
    let duration: Double
    let error: String?
    let attempts: Int
}

struct EgressResult: Sendable {
    let ipv4: ProbeResult
    let ipv6: ProbeResult
}

struct ConnectivityResult: Identifiable, Sendable {
    var id: String { url }
    let url: String
    let direct: ProbeResult
    let proxy: ProbeResult
}

struct NetworkService {

    static func getProxyEnv(config: AppSettings) -> [String: String] {
        var env: [String: String] = [:]
        let urlStr = config.proxyProtocol == .http ? "http://\(config.proxyHost):\(config.proxyPort)" : "socks5://\(config.proxyHost):\(config.proxyPort)"
        env["ALL_PROXY"] = urlStr; env["all_proxy"] = urlStr
        if config.proxyProtocol == .http {
            env["HTTP_PROXY"] = urlStr; env["HTTPS_PROXY"] = urlStr; env["http_proxy"] = urlStr; env["https_proxy"] = urlStr
        }
        return env
    }

    static func checkSingleEgress(mode: NetworkMode, useIPv6: Bool) async -> ProbeResult {
        let candidates = ["https://icanhazip.com", "https://ifconfig.me/ip", "https://api.ipify.org", "https://ipinfo.io/ip"]
        let flag = useIPv6 ? "-6" : "-4"

        var lastErr = "All candidates failed"
        var totalDuration: Double = 0
        var attempts = 0

        for url in candidates {
            attempts += 1
            let start = Date()
            var args = [flag, "-sS", "--max-time", "4", url]
            if case .direct = mode {
                args.append(contentsOf: ["--noproxy", "*"])
            }

            do {
                let out = try await ShellService.runWithMode(executable: "/usr/bin/curl", args: args, mode: mode, isCurl: true)
                let duration = Date().timeIntervalSince(start)
                totalDuration += duration

                let ipRaw = out.trimmingCharacters(in: .whitespacesAndNewlines)
                let ip = useIPv6 ? String(ipRaw.split(separator: "%").first ?? "") : ipRaw
                let isValid = useIPv6 ? (IPv6Address(ip) != nil) : (IPv4Address(ip) != nil)

                if isValid {
                    return ProbeResult(success: true, value: ip, duration: totalDuration, error: nil, attempts: attempts)
                } else {
                    lastErr = "Invalid format: \(String(ip.prefix(20)))"
                }
            } catch let BrewError.executionFailed(code, msg) {
                totalDuration += Date().timeIntervalSince(start)
                lastErr = msg.isEmpty ? "Code \(code) Error" : String(msg.prefix(500))
            } catch {
                totalDuration += Date().timeIntervalSince(start)
                lastErr = String(error.localizedDescription.prefix(500))
            }
        }
        return ProbeResult(success: false, value: nil, duration: totalDuration, error: lastErr, attempts: attempts)
    }

    static func checkEgress(config: AppSettings) async -> (direct: EgressResult, proxy: EgressResult) {
        async let d4 = checkSingleEgress(mode: .direct, useIPv6: false)
        async let d6 = checkSingleEgress(mode: .direct, useIPv6: true)

        let proxy4: ProbeResult
        let proxy6: ProbeResult

        if config.brewProxyEnabled {
            let proxyMode = NetworkMode.proxyInjected(getProxyEnv(config: config))
            async let p4 = checkSingleEgress(mode: proxyMode, useIPv6: false)
            async let p6 = checkSingleEgress(mode: proxyMode, useIPv6: true)
            proxy4 = await p4; proxy6 = await p6
        } else {
            proxy4 = ProbeResult(success: false, value: "Disabled", duration: 0, error: "Proxy not enabled", attempts: 0)
            proxy6 = ProbeResult(success: false, value: "Disabled", duration: 0, error: "Proxy not enabled", attempts: 0)
        }

        return (EgressResult(ipv4: await d4, ipv6: await d6), EgressResult(ipv4: proxy4, ipv6: proxy6))
    }

    static func testSingleConnectivity(url: String, mode: NetworkMode) async -> ProbeResult {
        let start = Date()
        var args = ["-sS", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", url]
        if case .direct = mode { args.append(contentsOf: ["--noproxy", "*"]) }

        do {
            let out = try await ShellService.runWithMode(executable: "/usr/bin/curl", args: args, mode: mode, isCurl: true)
            let duration = Date().timeIntervalSince(start)

            let codeStr = out.trimmingCharacters(in: .whitespacesAndNewlines)
            let code = Int(codeStr) ?? 0
            let success = code >= 200 && code < 400

            return ProbeResult(success: success, value: codeStr, duration: duration, error: nil, attempts: 1)
        } catch let BrewError.executionFailed(code, msg) {
            let duration = Date().timeIntervalSince(start)
            let isTimeout = msg.lowercased().contains("timeout") || code == 28
            let val = isTimeout ? "timeout" : "error"
            return ProbeResult(success: false, value: val, duration: duration, error: String(msg.prefix(500)), attempts: 1)
        } catch {
            let duration = Date().timeIntervalSince(start)
            return ProbeResult(success: false, value: "error", duration: duration, error: String(error.localizedDescription.prefix(500)), attempts: 1)
        }
    }

    static func checkConnectivity(config: AppSettings) async -> [ConnectivityResult] {
        let urls = [
            "https://api.github.com",
            "https://raw.githubusercontent.com/Homebrew/brew/master/README.md",
            "https://ghcr.io"
        ]

        return await withTaskGroup(of: ConnectivityResult.self) { group in
            for url in urls {
                group.addTask {
                    async let d = testSingleConnectivity(url: url, mode: .direct)
                    let p: ProbeResult

                    if config.brewProxyEnabled {
                        let proxyMode = NetworkMode.proxyInjected(getProxyEnv(config: config))
                        p = await testSingleConnectivity(url: url, mode: proxyMode)
                    } else {
                        p = ProbeResult(success: false, value: "Disabled", duration: 0, error: "Proxy not enabled", attempts: 0)
                    }

                    return ConnectivityResult(url: url, direct: await d, proxy: p)
                }
            }

            var results: [ConnectivityResult] = []
            for await res in group { results.append(res) }

            results.sort { a, b in
                let idxA = urls.firstIndex(of: a.url) ?? 0
                let idxB = urls.firstIndex(of: b.url) ?? 0
                return idxA < idxB
            }
            return results
        }
    }
}

// MARK: - 3. SETTINGS VIEW

struct SettingsView: View {
    @ObservedObject var store: SettingsStore

    // UI State
    @State private var isTestingEgress = false
    @State private var egressDirect: EgressResult?
    @State private var egressProxy: EgressResult?

    @State private var isTestingConnectivity = false
    @State private var connectivityResults: [ConnectivityResult] = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("可靠性策略中心")
                        .font(.title2.weight(.semibold))
                    Text("这些设置会影响 Cellar 如何访问 Homebrew、执行安装/升级、刷新本机状态，并为 Runtime 诊断和报告提供网络上下文。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    SettingsSectionContainer(
                        section: .connection,
                        focusedSection: store.focusedSection,
                        impacts: ["影响检查更新", "影响安装/升级", "影响 Runtime 诊断或报告"]
                    ) {
                        connectionSection
                    }

                    SettingsSectionContainer(
                        section: .homebrewService,
                        focusedSection: store.focusedSection,
                        impacts: ["影响检查更新", "影响安装/升级", "影响 Homebrew 错误复盘"]
                    ) {
                        homebrewServiceSection
                    }

                    SettingsSectionContainer(
                        section: .maintenance,
                        focusedSection: store.focusedSection,
                        impacts: ["影响后台刷新", "影响 brew update 频率", "影响仪表盘新鲜度"]
                    ) {
                        maintenanceSection
                    }
                }
                .padding(24)
            }
            .onChange(of: store.focusedSection) { _, section in
                guard let section else { return }
                withAnimation {
                    proxy.scrollTo(section.id, anchor: .top)
                }
            }
        }
        .frame(width: 580, height: 620)
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("启用 Homebrew 代理 (Enable Proxy)", isOn: $store.config.brewProxyEnabled)
                .padding(.leading, 4)

            if store.config.brewProxyEnabled {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Text("协议 (Protocol):")
                        Picker("", selection: $store.config.proxyProtocol) {
                            ForEach(ProxyProtocol.allCases) { proto in Text(proto.rawValue).tag(proto) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 140)
                    }

                    HStack(spacing: 8) {
                        Text("Host:")
                        TextField("127.0.0.1", text: $store.config.proxyHost)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)

                        Text("Port:")
                            .padding(.leading, 12)
                        TextField("7897", text: $store.config.proxyPortString)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 75)
                    }
                }
                .padding(.leading, 28)
                .padding(.top, 4)
            }

            SettingsImpactText("代理设置会注入 ALL_PROXY / HTTP_PROXY / HTTPS_PROXY 等环境变量，影响 `brew update`、`brew install`、`brew upgrade` 和核心端点测试。默认开关保持现有配置，不会自动启用代理。")

            HStack {
                Button("检测本地与代理出口 IP") { runEgress() }
                    .disabled(isTestingEgress)
                    .help(isTestingEgress ? "正在检测出口 IP，请等待结果返回。" : "检测直连与代理注入后的出口 IP。")
                if isTestingEgress { ProgressView().controlSize(.small).padding(.leading, 4) }
            }
            .padding(.leading, 4)

            if let direct = egressDirect, let proxy = egressProxy {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Direct (系统直连)").font(.subheadline.bold())
                        ProbeRowView(label: "IPv4", probe: direct.ipv4)
                        ProbeRowView(label: "IPv6", probe: direct.ipv6)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("ProxyInjected (注入设定参数)")
                            .font(.subheadline.bold())
                            .foregroundStyle(store.config.brewProxyEnabled ? .primary : .secondary)
                        ProbeRowView(label: "IPv4", probe: proxy.ipv4)
                        ProbeRowView(label: "IPv6", probe: proxy.ipv6)
                    }
                }
                .padding(.leading, 24)
                .padding(.top, 4)
            }
        }
    }

    private var homebrewServiceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let issue = store.latestReliabilityIssue {
                BrewReliabilityIssueView(issue: issue)
            } else {
                SettingsImpactText("最近没有结构化 Homebrew 可靠性诊断。发生 DNS、代理、端点、权限或 brew 缺失问题后，这里会显示下一步核对建议。")
            }

            HStack {
                Button("测试核心服务可达性") { runConnectivity() }
                    .disabled(isTestingConnectivity)
                    .help(isTestingConnectivity ? "正在测试核心服务，请等待结果返回。" : "测试 GitHub、Homebrew tap 资源和容器仓库是否可达。")
                if isTestingConnectivity { ProgressView().controlSize(.small).padding(.leading, 4) }
            }
            .padding(.leading, 4)

            SettingsImpactText("核心端点包括 GitHub API、Homebrew tap 资源和容器仓库。它们会影响检查更新、安装、升级、读取元数据和失败复盘。")

            if !connectivityResults.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(connectivityResults) { res in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(res.url).font(.caption).bold().foregroundStyle(.primary)
                            ProbeRowView(label: "Direct", probe: res.direct)
                            ProbeRowView(label: "Proxy", probe: res.proxy)
                        }
                        if res.id != connectivityResults.last?.id {
                            Divider().padding(.vertical, 4)
                        }
                    }
                }
                .padding(.leading, 24)
                .padding(.top, 4)
            }
        }
    }

    private var maintenanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("开启自动维护（定时刷新与 brew update）", isOn: $store.config.autoMaintenanceEnabled)
                .padding(.leading, 4)

            SettingsImpactText("快速刷新只读取可升级列表和本机酒窖状态；`brew update` 阈值控制多久刷新 Homebrew 仓库。后台维护会影响仪表盘是否及时显示更新，但不会修改代理默认开关。")

            if store.config.autoMaintenanceEnabled {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Text("快速刷新间隔:")
                            .frame(width: 95, alignment: .leading)
                        Picker("", selection: $store.config.refreshIntervalSec) {
                            Text("10 分钟 (Debug)").tag(600)
                            Text("1 小时").tag(3600)
                            Text("2 小时 (默认)").tag(7200)
                            Text("4 小时").tag(14400)
                            Text("12 小时").tag(43200)
                            Text("24 小时 (1天)").tag(86400)
                            Text("3 天").tag(259200)
                            Text("7 天").tag(604800)
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }

                    HStack(spacing: 8) {
                        Text("brew update 阈值:")
                            .frame(width: 95, alignment: .leading)
                        Picker("", selection: $store.config.updateIntervalSec) {
                            Text("12 小时").tag(43200)
                            Text("24 小时 (默认)").tag(86400)
                            Text("48 小时 (2天)").tag(172800)
                            Text("7 天").tag(604800)
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                }
                .padding(.leading, 28)
                .padding(.top, 4)
            }
        }
    }

    private func runEgress() {
        isTestingEgress = true
        Task {
            let (d, p) = await NetworkService.checkEgress(config: store.config)
            await MainActor.run { self.egressDirect = d; self.egressProxy = p; self.isTestingEgress = false }
        }
    }

    private func runConnectivity() {
        isTestingConnectivity = true
        Task {
            let results = await NetworkService.checkConnectivity(config: store.config)
            await MainActor.run { self.connectivityResults = results; self.isTestingConnectivity = false }
        }
    }
}

private struct SettingsSectionContainer<Content: View>: View {
    let section: SettingsReliabilitySection
    let focusedSection: SettingsReliabilitySection?
    let impacts: [String]
    let content: Content

    init(
        section: SettingsReliabilitySection,
        focusedSection: SettingsReliabilitySection?,
        impacts: [String],
        @ViewBuilder content: () -> Content
    ) {
        self.section = section
        self.focusedSection = focusedSection
        self.impacts = impacts
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(section.title)
                    .font(.headline)
                Spacer(minLength: 8)
                ForEach(impacts, id: \.self) { impact in
                    Text(impact)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.secondary.opacity(0.10)))
                }
            }
            content
        }
        .id(section.id)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isFocused ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor).opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isFocused ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.18), lineWidth: 1)
        )
    }

    private var isFocused: Bool {
        focusedSection == section
    }
}

private struct SettingsImpactText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 4)
    }
}

private struct BrewReliabilityIssueView: View {
    let issue: BrewReliabilityIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(issue.title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
            Text(issue.explanation)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(issue.impact)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(issue.nextStep)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !issue.manualCommands.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("人工核对命令")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(issue.manualCommands, id: \.self) { command in
                        Text(command)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 3)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(color.opacity(0.22), lineWidth: 1)
        )
    }

    private var color: Color {
        switch issue.kind {
        case .brewMissing, .permission: return .red
        case .network, .dns, .proxy, .endpoint: return .orange
        case .unknown: return .secondary
        }
    }

    private var symbol: String {
        switch issue.kind {
        case .brewMissing: return "questionmark.app.dashed"
        case .permission: return "lock.trianglebadge.exclamationmark"
        case .network, .dns, .proxy, .endpoint: return "network.slash"
        case .unknown: return "exclamationmark.triangle"
        }
    }
}

struct ProbeRowView: View {
    let label: String
    let probe: ProbeResult

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label)
                .frame(width: 50, alignment: .leading)
                .foregroundStyle(.secondary)
                .font(.caption.bold())

            if probe.value == "Disabled" {
                Image(systemName: "slash.circle.fill").foregroundStyle(.gray)
                Text("未启用 (Disabled)").foregroundStyle(.secondary)
            } else {
                if probe.success {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(probe.value ?? "OK").monospaced()
                } else {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    Text(probe.value ?? "Failed").monospaced()
                }

                if probe.attempts > 1 {
                    Text(String(format: "(%.0fms, %d tries)", probe.duration * 1000, probe.attempts)).foregroundStyle(.tertiary)
                } else {
                    Text(String(format: "(%.0fms)", probe.duration * 1000)).foregroundStyle(.tertiary)
                }

                if !probe.success, let err = probe.error {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .help(err) // 鼠标悬停显示完整报错日志
                }
            }
            Spacer()
        }
        .font(.caption)
    }
}
