import Foundation

enum BrewOperationKind: String, Codable, Sendable {
    case checkUpdates
    case updateThenCheck
    case upgrade
    case greedySyncCask
    case install
    case uninstall
    case cleanup

    var displayName: String {
        switch self {
        case .checkUpdates: return "检查更新"
        case .updateThenCheck: return "更新仓库后检查"
        case .upgrade: return "升级"
        case .greedySyncCask: return "贪婪同步"
        case .install: return "安装"
        case .uninstall: return "卸载"
        case .cleanup: return "清理"
        }
    }
}

enum BrewOperationStatus: String, Codable, Sendable {
    case running
    case succeeded
    case failed
    case cancelled

    var displayName: String {
        switch self {
        case .running: return "执行中"
        case .succeeded: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }
}

struct BrewAffectedPackage: Identifiable, Codable, Hashable, Sendable {
    let name: String
    let type: PackageType
    let installedVersion: String
    let targetVersion: String
    let sizeEstimate: PackageSizeEstimate

    var id: String { "\(type.rawValue):\(name)" }
    var versionChangeText: String { "\(installedVersion) -> \(targetVersion)" }
    var sizeStatus: String { sizeEstimate.statusText }
}

enum BrewOperationStage: String, Codable, Hashable, Sendable {
    case preparingUpgrade
    case upgradingPackage
    case verifyingOutdated
    case preparingGreedySync
    case syncingCask
    case verifyingGreedySync
    case refreshingLibrary

    var displayName: String {
        switch self {
        case .preparingUpgrade: return "正在准备"
        case .upgradingPackage: return "正在升级"
        case .verifyingOutdated: return "正在复核 outdated"
        case .preparingGreedySync: return "正在准备贪婪同步"
        case .syncingCask: return "正在贪婪同步"
        case .verifyingGreedySync: return "正在复核贪婪同步"
        case .refreshingLibrary: return "正在刷新我的酒窖"
        }
    }
}

struct BrewOperationProgress: Codable, Hashable, Sendable {
    let stage: BrewOperationStage
    let totalPackageCount: Int
    let currentPackageName: String?
    let currentPackageIndex: Int?

    var summaryText: String {
        switch stage {
        case .preparingUpgrade:
            return totalPackageCount > 0
                ? "正在准备升级，共 \(totalPackageCount) 个目标包。"
                : "正在准备升级。"
        case .upgradingPackage:
            if let currentPackageName {
                let position = currentPackageIndex.map { "\($0)/\(max(totalPackageCount, 1))" } ?? "目标包"
                return "正在升级 \(currentPackageName)（\(position)）。"
            }
            return totalPackageCount > 0
                ? "正在升级目标包，共 \(totalPackageCount) 个。"
                : "正在执行 Homebrew 升级。"
        case .verifyingOutdated:
            return totalPackageCount > 0
                ? "正在复核 outdated，确认 \(totalPackageCount) 个目标包是否仍可升级。"
                : "正在复核 outdated。"
        case .preparingGreedySync:
            return totalPackageCount > 0
                ? "正在准备贪婪同步，共 \(totalPackageCount) 个自更新 Cask。"
                : "正在准备贪婪同步。"
        case .syncingCask:
            if let currentPackageName {
                return "正在用 Homebrew 贪婪同步 \(currentPackageName)。"
            }
            return totalPackageCount > 0
                ? "正在用 Homebrew 贪婪同步自更新 Cask，共 \(totalPackageCount) 个。"
                : "正在执行 Homebrew 贪婪同步。"
        case .verifyingGreedySync:
            return totalPackageCount > 0
                ? "正在复核贪婪同步结果，确认 \(totalPackageCount) 个自更新 Cask 是否仍在关注列表。"
                : "正在复核贪婪同步结果。"
        case .refreshingLibrary:
            return "正在刷新我的酒窖，更新版本和大小状态。"
        }
    }
}

struct BrewOperationSummary: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let operationKind: BrewOperationKind
    let startedAt: Date
    let finishedAt: Date?
    let status: BrewOperationStatus
    let affectedPackages: [BrewAffectedPackage]
    let summaryText: String
    let recommendedNextAction: String?
    let reliabilityIssue: BrewReliabilityIssue?
    let progress: BrewOperationProgress?

    init(
        id: UUID = UUID(),
        operationKind: BrewOperationKind,
        startedAt: Date,
        finishedAt: Date?,
        status: BrewOperationStatus,
        affectedPackages: [BrewAffectedPackage],
        summaryText: String,
        recommendedNextAction: String?,
        reliabilityIssue: BrewReliabilityIssue? = nil,
        progress: BrewOperationProgress? = nil
    ) {
        self.id = id
        self.operationKind = operationKind
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.affectedPackages = affectedPackages
        self.summaryText = summaryText
        self.recommendedNextAction = recommendedNextAction
        self.reliabilityIssue = reliabilityIssue
        self.progress = progress
    }

    var compactRecapText: String {
        if status == .running {
            return progress?.summaryText ?? summaryText
        }
        if operationKind == .upgrade, status == .succeeded {
            let total = affectedPackages.count
            if total == 0 {
                return "升级完成，无目标包"
            }
            if let remaining = remainingOutdatedCount {
                if remaining == 0 {
                    return "已升级 \(total) 个包，复核通过"
                }
                return "已处理 \(total) 个包，仍有 \(remaining) 个需复核"
            }
            return "已处理 \(total) 个包，复核状态待确认"
        }
        if operationKind == .greedySyncCask, status == .succeeded {
            let total = affectedPackages.count
            if total == 0 {
                return "贪婪同步完成，无目标 Cask"
            }
            if let remaining = remainingGreedySyncAttentionCount {
                if remaining == 0 {
                    return "已贪婪同步 \(total) 个自更新 Cask，复核通过"
                }
                return "已贪婪同步 \(total) 个自更新 Cask，仍有 \(remaining) 个需复核"
            }
            return "已贪婪同步 \(total) 个自更新 Cask，复核状态待确认"
        }
        return summaryText
    }

    var remainingOutdatedCount: Int? {
        guard operationKind == .upgrade, status == .succeeded else { return nil }
        if summaryText.contains("仍在 outdated 的包：无") {
            return 0
        }
        guard let range = summaryText.range(of: "仍在 outdated 的包：") else {
            return nil
        }
        let suffix = summaryText[range.upperBound...]
            .split(separator: "。", maxSplits: 1)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let suffix, !suffix.isEmpty, suffix != "无" else { return 0 }
        return suffix.split(separator: "、").count
    }

    var remainingGreedySyncAttentionCount: Int? {
        guard operationKind == .greedySyncCask, status == .succeeded else { return nil }
        if summaryText.contains("仍在更新关注列表：无") {
            return 0
        }
        guard let range = summaryText.range(of: "仍在更新关注列表：") else {
            return nil
        }
        let suffix = summaryText[range.upperBound...]
            .split(separator: "。", maxSplits: 1)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let suffix, !suffix.isEmpty, suffix != "无" else { return 0 }
        return suffix.split(separator: "、").count
    }
}
