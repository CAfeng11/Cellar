import Foundation

struct ProductTerm: Identifiable, Hashable, Sendable {
    let key: String
    let displayName: String
    let explanation: String

    var id: String { key }
}

enum ProductCopy {
    static let dashboard = "仪表盘"
    static let library = "我的酒窖"
    static let runtimeDoctor = "Runtime Doctor"
    static let pathPolicy = "PATH Policy"
    static let minimalTrustedPath = "Minimal Trusted PATH"
    static let repoVersionDiff = "版本差异"
    static let autoUpdatingCask = "自更新 Cask"
    static let sizeUnknown = "酒窖大小未知"
    static let repairHistory = "修复历史"

    static let terminology: [ProductTerm] = [
        ProductTerm(key: "dashboard", displayName: dashboard, explanation: "第一层决策入口，先回答是否需要处理，再给下一步。"),
        ProductTerm(key: "library", displayName: library, explanation: "已安装项目视图，展示本机安装状态、资产标签和可安全执行的操作。"),
        ProductTerm(key: "runtimeDoctor", displayName: runtimeDoctor, explanation: "本机 Node / Python 运行时的观察、解释、PATH 策略和修复入口。"),
        ProductTerm(key: "pathPolicy", displayName: pathPolicy, explanation: "Cellar 如何接入 GUI、Shell、运行时和全局工具入口的路径策略。"),
        ProductTerm(key: "minimalTrustedPath", displayName: minimalTrustedPath, explanation: "默认路径策略，只接入核心可信路径，不完整镜像 Shell PATH。"),
        ProductTerm(key: "repoVersionDiff", displayName: repoVersionDiff, explanation: "本机版本与仓库版本存在差异；Cellar 会区分 Cask 元数据、Formula revision、自更新 App 和可升级项。"),
        ProductTerm(key: "autoUpdatingCask", displayName: autoUpdatingCask, explanation: "应用可自行更新，Homebrew 不追踪其内部更新进度。"),
        ProductTerm(key: "sizeUnknown", displayName: sizeUnknown, explanation: "只统计“我的酒窖”中已安装资产的大小探测状态；不代表更新候选的下载大小或参考体量。"),
        ProductTerm(key: "repairHistory", displayName: repairHistory, explanation: "只记录 Cellar 主动执行过的 Runtime 修复动作；复制命令只进入事件记录。")
    ]

    static var terminologyMarkdown: [String] {
        terminology.map { "- \($0.displayName): \($0.explanation)" }
    }

    static func termHelp(_ displayName: String) -> String {
        terminology.first(where: { $0.displayName == displayName })?.explanation ?? displayName
    }

    static func emptyStateNextStep(for tab: AppTab) -> String {
        switch tab {
        case .dashboard:
            return "下一步：保持当前状态；需要复核时可手动检查更新或从刷新菜单更新仓库后检查。"
        case .library:
            return "下一步：点击刷新，重新读取我的酒窖。"
        case .runtime:
            return "下一步：点击刷新，重新扫描 Runtime Doctor。"
        }
    }
}
