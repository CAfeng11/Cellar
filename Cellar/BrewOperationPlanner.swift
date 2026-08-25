import Foundation

enum BrewOperationPlanner {
    static func affectedPackages(from packages: [BrewPackage]) -> [BrewAffectedPackage] {
        packages.map { package in
            BrewAffectedPackage(
                name: package.name,
                type: package.type,
                installedVersion: package.versionDisplay,
                targetVersion: package.currentVersionDisplay,
                sizeEstimate: PackageSizeEstimate.estimate(for: package, context: .upgradeCandidate)
            )
        }
    }

    static func runningSummary(kind: BrewOperationKind, packages: [BrewPackage] = [], startedAt: Date = Date()) -> BrewOperationSummary {
        let affected = affectedPackages(from: packages)
        let summary: String
        let progress: BrewOperationProgress?
        switch kind {
        case .checkUpdates:
            summary = "正在检查 Homebrew 更新..."
            progress = nil
        case .updateThenCheck:
            summary = "正在更新 Homebrew 仓库，然后检查可用更新..."
            progress = nil
        case .upgrade:
            progress = BrewOperationProgress(
                stage: .preparingUpgrade,
                totalPackageCount: affected.count,
                currentPackageName: nil,
                currentPackageIndex: nil
            )
            summary = progress?.summaryText ?? "正在执行 Homebrew 升级..."
        case .greedySyncCask:
            progress = BrewOperationProgress(
                stage: .preparingGreedySync,
                totalPackageCount: affected.count,
                currentPackageName: nil,
                currentPackageIndex: nil
            )
            summary = progress?.summaryText ?? "正在准备贪婪同步..."
        case .install:
            summary = "正在安装软件..."
            progress = nil
        case .uninstall:
            summary = "正在卸载软件..."
            progress = nil
        case .cleanup:
            summary = "正在清理 Homebrew 缓存..."
            progress = nil
        }
        return BrewOperationSummary(
            operationKind: kind,
            startedAt: startedAt,
            finishedAt: nil,
            status: .running,
            affectedPackages: affected,
            summaryText: summary,
            recommendedNextAction: nil,
            progress: progress
        )
    }

    static func upgradeProgressSummary(
        stage: BrewOperationStage,
        packages: [BrewPackage],
        startedAt: Date,
        currentPackage: BrewPackage? = nil,
        currentPackageIndex: Int? = nil
    ) -> BrewOperationSummary {
        let affected = affectedPackages(from: packages)
        let progress = BrewOperationProgress(
            stage: stage,
            totalPackageCount: affected.count,
            currentPackageName: currentPackage?.name,
            currentPackageIndex: currentPackageIndex
        )
        return BrewOperationSummary(
            operationKind: .upgrade,
            startedAt: startedAt,
            finishedAt: nil,
            status: .running,
            affectedPackages: affected,
            summaryText: progress.summaryText,
            recommendedNextAction: "目标包数量：\(affected.count)。不解析 Homebrew 日志来承诺剩余时间。",
            progress: progress
        )
    }

    static func greedySyncProgressSummary(
        stage: BrewOperationStage,
        packages: [BrewPackage],
        startedAt: Date,
        currentPackage: BrewPackage? = nil
    ) -> BrewOperationSummary {
        let affected = affectedPackages(from: packages)
        let progress = BrewOperationProgress(
            stage: stage,
            totalPackageCount: affected.count,
            currentPackageName: currentPackage?.name,
            currentPackageIndex: currentPackage == nil ? nil : 1
        )
        return BrewOperationSummary(
            operationKind: .greedySyncCask,
            startedAt: startedAt,
            finishedAt: nil,
            status: .running,
            affectedPackages: affected,
            summaryText: progress.summaryText,
            recommendedNextAction: "贪婪同步会通过 Homebrew 重新下载并覆盖安装 Cask；不解析日志承诺剩余时间。",
            progress: progress
        )
    }

    static func refreshFinished(kind: BrewOperationKind, startedAt: Date, updateCount: Int) -> BrewOperationSummary {
        let text = kind == .updateThenCheck
            ? "已更新 Homebrew 仓库，发现 \(updateCount) 个普通可升级项目。"
            : "检查完成，发现 \(updateCount) 个普通可升级项目。"
        return BrewOperationSummary(
            operationKind: kind,
            startedAt: startedAt,
            finishedAt: Date(),
            status: .succeeded,
            affectedPackages: [],
            summaryText: text,
            recommendedNextAction: updateCount > 0 ? "查看更新列表并选择普通升级项目。" : "当前没有普通可升级项目。"
        )
    }

    static func greedySyncFinished(
        startedAt: Date,
        targetPackages: [BrewPackage],
        remainingOutdatedPackages: [BrewPackage],
        verificationError: Error? = nil
    ) -> BrewOperationSummary {
        let affected = affectedPackages(from: targetPackages)
        let remainingIDs = Set(remainingOutdatedPackages.map(\.id))
        let stillAttention = targetPackages.filter { remainingIDs.contains($0.id) }
        let handledCount = targetPackages.count
        let clearedCount = handledCount - stillAttention.count

        let summary: String
        let nextAction: String
        if let verificationError {
            summary = "贪婪同步命令已结束：目标 \(handledCount) 个自更新 Cask，复核后已不在更新关注列表的数量无法确认，复核失败原因：\(verificationError.localizedDescription)"
            nextAction = "建议重新检查更新，并刷新我的酒窖确认 App 实际版本、Homebrew 记录和仓库版本。"
        } else if handledCount == 0 {
            summary = "贪婪同步完成：没有可复盘的自更新 Cask。"
            nextAction = "普通升级链路未执行；如需继续，请从自更新 Cask 行显式发起同步。"
        } else if stillAttention.isEmpty {
            summary = "贪婪同步完成：目标 \(handledCount) 个自更新 Cask，复核后已不在更新关注列表的数量 \(clearedCount)，仍在更新关注列表：无。"
            nextAction = "建议刷新“我的酒窖”，确认 App 实际版本和 Homebrew 记录已对齐。"
        } else {
            let names = stillAttention.prefix(5).map(\.name).joined(separator: "、")
            let suffix = stillAttention.count > 5 ? " 等 \(stillAttention.count) 个自更新 Cask" : names
            summary = "贪婪同步命令已结束：目标 \(handledCount) 个自更新 Cask，复核后已不在更新关注列表的数量 \(clearedCount)，仍在更新关注列表：\(suffix)。"
            nextAction = "请查看日志确认 Homebrew 是否跳过、App 内部更新器是否已领先，或是否仍存在版本记录差异。"
        }

        let names = affected.prefix(5).map(\.name).joined(separator: "、")
        let suffix = affected.count > 5 ? " 等 \(affected.count) 个自更新 Cask" : (names.isEmpty ? "自更新 Cask" : names)
        return BrewOperationSummary(
            operationKind: .greedySyncCask,
            startedAt: startedAt,
            finishedAt: Date(),
            status: .succeeded,
            affectedPackages: affected,
            summaryText: summary,
            recommendedNextAction: nextAction + " 本次目标：\(suffix)。"
        )
    }

    static func upgradeFinished(
        startedAt: Date,
        targetPackages: [BrewPackage],
        remainingOutdatedPackages: [BrewPackage],
        verificationError: Error? = nil
    ) -> BrewOperationSummary {
        let affected = affectedPackages(from: targetPackages)
        let remainingIDs = Set(remainingOutdatedPackages.map(\.id))
        let stillOutdated = targetPackages.filter { remainingIDs.contains($0.id) }
        let handledCount = targetPackages.count
        let clearedCount = handledCount - stillOutdated.count

        let summary: String
        let nextAction: String
        if let verificationError {
            summary = "升级命令已结束：目标 \(handledCount) 个包，复核后已不在 outdated 的数量无法确认，复核失败原因：\(verificationError.localizedDescription)"
            nextAction = "建议重新检查更新，确认是否仍有目标包留在可升级列表。"
        } else if handledCount == 0 {
            summary = "升级完成：没有可复盘的目标包。"
            nextAction = "建议刷新“我的酒窖”，确认当前状态。"
        } else if stillOutdated.isEmpty {
            summary = "升级完成：目标 \(handledCount) 个包，复核后已不在 outdated 的数量 \(clearedCount)，仍在 outdated 的包：无。"
            nextAction = "建议刷新“我的酒窖”，确认已安装版本和大小状态。"
        } else {
            let names = stillOutdated.prefix(5).map(\.name).joined(separator: "、")
            let suffix = stillOutdated.count > 5 ? " 等 \(stillOutdated.count) 个包" : names
            summary = "升级命令已结束：目标 \(handledCount) 个包，复核后已不在 outdated 的数量 \(clearedCount)，仍在 outdated 的包：\(suffix)。"
            nextAction = "请查看日志确认是否被 pin、依赖约束、外部状态变化或 Homebrew 输出跳过。"
        }

        let names = affected.prefix(5).map(\.name).joined(separator: "、")
        let suffix = affected.count > 5 ? " 等 \(affected.count) 个包" : (names.isEmpty ? "包" : names)
        return BrewOperationSummary(
            operationKind: .upgrade,
            startedAt: startedAt,
            finishedAt: Date(),
            status: .succeeded,
            affectedPackages: affected,
            summaryText: summary,
            recommendedNextAction: nextAction + " 本次目标：\(suffix)。"
        )
    }

    static func finishedSummary(
        kind: BrewOperationKind,
        startedAt: Date,
        packages: [BrewPackage] = [],
        summaryText: String,
        recommendedNextAction: String
    ) -> BrewOperationSummary {
        BrewOperationSummary(
            operationKind: kind,
            startedAt: startedAt,
            finishedAt: Date(),
            status: .succeeded,
            affectedPackages: affectedPackages(from: packages),
            summaryText: summaryText,
            recommendedNextAction: recommendedNextAction
        )
    }

    static func failureSummary(kind: BrewOperationKind, startedAt: Date, packages: [BrewPackage] = [], error: Error) -> BrewOperationSummary {
        let text = error.localizedDescription
        let isCancelled = error is CancellationError || (error as? BrewError) == .cancelled
        let reliabilityIssue = isCancelled ? nil : BrewReliabilityDiagnostics.diagnose(error: error)
        let failureText: String
        let cancelledText: String
        switch kind {
        case .greedySyncCask:
            failureText = "贪婪同步失败：\(text)"
            cancelledText = "贪婪同步已取消。"
        case .upgrade:
            failureText = "升级失败：\(text)"
            cancelledText = "升级已取消。"
        default:
            failureText = "操作失败：\(text)"
            cancelledText = "操作已取消。"
        }
        return BrewOperationSummary(
            operationKind: kind,
            startedAt: startedAt,
            finishedAt: Date(),
            status: isCancelled ? .cancelled : .failed,
            affectedPackages: affectedPackages(from: packages),
            summaryText: isCancelled ? cancelledText : failureText,
            recommendedNextAction: isCancelled ? "如需继续，请重新发起操作。" : reliabilityIssue?.nextStep,
            reliabilityIssue: reliabilityIssue
        )
    }

    static func recommendation(for error: Error) -> String {
        if error is CancellationError || (error as? BrewError) == .cancelled {
            return "如需继续，请重新发起操作。"
        }
        return BrewReliabilityDiagnostics.recommendation(for: error)
    }
}
