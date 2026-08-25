import Foundation

enum BrewReliabilityIssueKind: String, Codable, CaseIterable, Sendable {
    case network
    case dns
    case proxy
    case endpoint
    case permission
    case brewMissing
    case unknown

    var displayName: String {
        switch self {
        case .network: return "网络连接异常"
        case .dns: return "DNS 解析异常"
        case .proxy: return "代理可能不可用"
        case .endpoint: return "Homebrew 端点异常"
        case .permission: return "Homebrew 权限异常"
        case .brewMissing: return "未找到 Homebrew"
        case .unknown: return "Homebrew 异常"
        }
    }
}

struct BrewReliabilityIssue: Identifiable, Codable, Hashable, Sendable {
    let kind: BrewReliabilityIssueKind
    let title: String
    let explanation: String
    let impact: String
    let nextStep: String
    let actionTitle: String
    let manualCommands: [String]

    var id: String { kind.rawValue }
}

enum BrewReliabilityDiagnostics {
    static func diagnose(error: Error) -> BrewReliabilityIssue {
        if error is CancellationError || (error as? BrewError) == .cancelled {
            return issue(for: .unknown)
        }
        if (error as? BrewError) == .brewNotFound {
            return issue(for: .brewMissing)
        }
        return diagnose(text: error.localizedDescription)
    }

    static func diagnose(text: String) -> BrewReliabilityIssue {
        let normalized = text.lowercased()

        if containsAny(normalized, [
            "not writable",
            "permission denied",
            "operation not permitted",
            "cannot create",
            "is not owned",
            "must be writable"
        ]) {
            return issue(for: .permission)
        }

        if containsAny(normalized, [
            "could not resolve",
            "couldn't resolve",
            "temporary failure in name resolution",
            "nodename nor servname",
            "name or service not known",
            "no address associated",
            "dns"
        ]) {
            return issue(for: .dns)
        }

        if containsAny(normalized, [
            "proxy",
            "socks",
            "connect tunnel failed",
            "proxyconnect",
            "received http code"
        ]) {
            return issue(for: .proxy)
        }

        if containsAny(normalized, [
            "formulae.brew.sh",
            "api.github.com",
            "github.com",
            "raw.githubusercontent.com",
            "ghcr.io",
            "homebrew-core",
            "homebrew-cask"
        ]) {
            return issue(for: .endpoint)
        }

        if containsAny(normalized, [
            "failed to connect",
            "connection refused",
            "connection reset",
            "network is unreachable",
            "operation timed out",
            "timeout",
            "执行超时",
            "没有继续输出",
            "ssl_connect",
            "tls"
        ]) {
            return issue(for: .network)
        }

        return issue(for: .unknown)
    }

    static func recommendation(for error: Error) -> String {
        diagnose(error: error).nextStep
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func issue(for kind: BrewReliabilityIssueKind) -> BrewReliabilityIssue {
        switch kind {
        case .brewMissing:
            return BrewReliabilityIssue(
                kind: kind,
                title: "未找到 brew",
                explanation: "Cellar 没有在常见路径中找到 Homebrew 命令。",
                impact: "更新检查、安装、卸载、清理和酒窖列表都无法继续。",
                nextStep: "请先安装 Homebrew，或确认 brew 是否位于 /opt/homebrew/bin/brew 或 /usr/local/bin/brew。",
                actionTitle: "查看设置",
                manualCommands: ["which brew", "brew --version"]
            )
        case .dns:
            return BrewReliabilityIssue(
                kind: kind,
                title: "DNS 无法解析 Homebrew 相关地址",
                explanation: "命令输出显示域名解析失败，通常发生在 DNS、网络出口或代理链路不可用时。",
                impact: "Homebrew API、GitHub 或 formulae.brew.sh 无法访问，更新检查可能失败。",
                nextStep: "可到偏好设置检查直连与代理连通性，启用代理后重试。",
                actionTitle: "检查代理设置",
                manualCommands: ["scutil --dns", "curl -I https://formulae.brew.sh"]
            )
        case .network:
            return BrewReliabilityIssue(
                kind: kind,
                title: "Homebrew 网络连接失败",
                explanation: "命令无法连接远端服务，可能是当前网络、出口策略或临时链路异常。",
                impact: "更新仓库、下载包或读取远端元数据可能失败。",
                nextStep: "请在偏好设置测试核心端点；如直连失败，可启用代理后重试。",
                actionTitle: "打开代理设置",
                manualCommands: ["curl -I https://api.github.com", "brew update"]
            )
        case .proxy:
            return BrewReliabilityIssue(
                kind: kind,
                title: "代理可能不可用",
                explanation: "命令输出包含代理连接或隧道错误，说明当前代理地址、端口或协议可能不可用。",
                impact: "启用代理后 brew 仍可能无法访问 GitHub、Homebrew API 或镜像端点。",
                nextStep: "请确认代理 Host、Port 和协议，再在偏好设置中重新测试代理出口。",
                actionTitle: "检查代理设置",
                manualCommands: ["curl -I https://api.github.com", "brew update"]
            )
        case .endpoint:
            return BrewReliabilityIssue(
                kind: kind,
                title: "Homebrew 核心端点不可达",
                explanation: "失败文本指向 GitHub、Homebrew API、formulae.brew.sh 或容器仓库等核心端点。",
                impact: "Homebrew 可能无法刷新配方、读取元数据或下载资源。",
                nextStep: "请在偏好设置测试核心服务可达性；必要时启用代理后重试。",
                actionTitle: "测试核心端点",
                manualCommands: ["curl -I https://api.github.com", "curl -I https://formulae.brew.sh"]
            )
        case .permission:
            return BrewReliabilityIssue(
                kind: kind,
                title: "Homebrew 目录不可写",
                explanation: "命令输出显示 Cellar、prefix 或缓存目录没有当前用户写入权限。",
                impact: "安装、升级、卸载或清理可能失败；Cellar 不会自动修改目录所有者或权限。",
                nextStep: "请先人工核对目录所有者和写入权限，再按 Homebrew 官方建议处理。",
                actionTitle: "查看核对建议",
                manualCommands: [
                    "brew --prefix",
                    "ls -ld $(brew --prefix) $(brew --cellar)",
                    "brew doctor"
                ]
            )
        case .unknown:
            return BrewReliabilityIssue(
                kind: kind,
                title: "Homebrew 操作失败",
                explanation: "当前错误无法稳定归因到网络、代理、端点、权限或 brew 缺失。",
                impact: "本次操作没有完成，需要结合日志判断是否可重试。",
                nextStep: "请查看高级日志中的完整命令输出，再决定是否重试。",
                actionTitle: "查看日志",
                manualCommands: ["brew doctor"]
            )
        }
    }
}
