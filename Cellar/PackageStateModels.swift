import Foundation

enum PackageStateSeverity: String, Codable, Sendable {
    case info
    case attention
    case warning
}

enum PackageStateFilterKey: String, Codable, CaseIterable, Identifiable, Sendable {
    case leaf
    case repoDiff
    case autoUpdates
    case sizeUnknown

    nonisolated var id: String { rawValue }

    nonisolated var title: String {
        switch self {
        case .leaf: return "叶子包"
        case .repoDiff: return "版本差异"
        case .autoUpdates: return "自更新 Cask"
        case .sizeUnknown: return "酒窖大小未知"
        }
    }
}

struct PackageStateBadge: Identifiable, Codable, Hashable, Sendable {
    let kind: String
    let title: String
    let explanation: String
    let severity: PackageStateSeverity
    let filterKey: PackageStateFilterKey?

    var id: String { kind }
}

enum PackageStateDescriptor {
    nonisolated static func filterKeys(for package: BrewPackage, isLibrary: Bool) -> [PackageStateFilterKey] {
        let difference = package.versionDifferenceKind(isOutdatedCandidate: !isLibrary)
        return uniqueStable([
            isLibrary && package.isLeaf ? .leaf : nil,
            isLibrary && difference.contributesToLibrarySummary ? .repoDiff : nil,
            package.autoUpdates ? .autoUpdates : nil,
            isLibrary && package.installedSizeBytes == nil ? .sizeUnknown : nil
        ].compactMap { $0 })
    }

    nonisolated static func contains(_ key: PackageStateFilterKey, package: BrewPackage, isLibrary: Bool) -> Bool {
        filterKeys(for: package, isLibrary: isLibrary).contains(key)
    }

    nonisolated static func count(_ key: PackageStateFilterKey, in packages: [BrewPackage], isLibrary: Bool) -> Int {
        packages.filter { contains(key, package: $0, isLibrary: isLibrary) }.count
    }

    nonisolated private static func uniqueStable(_ keys: [PackageStateFilterKey]) -> [PackageStateFilterKey] {
        var seen: Set<PackageStateFilterKey> = []
        return keys.filter { seen.insert($0).inserted }
    }
}

enum PackageStateBadgeFactory {
    nonisolated static func badges(for package: BrewPackage, isLibrary: Bool) -> [PackageStateBadge] {
        var badges: [PackageStateBadge] = []
        let difference = package.versionDifferenceKind(isOutdatedCandidate: !isLibrary)

        if difference != .none {
            badges.append(versionDifferenceBadge(for: difference))
        }

        for key in PackageStateDescriptor.filterKeys(for: package, isLibrary: isLibrary)
        where key != .repoDiff && !(key == .autoUpdates && difference == .autoUpdatingCask) {
            badges.append(badge(for: key))
        }

        if package.isPinned {
            badges.append(PackageStateBadge(
                kind: "pinned",
                title: "已锁定",
                explanation: "此 Formula 已锁定，不会参与普通升级。",
                severity: .info,
                filterKey: nil
            ))
        }

        if isLibrary && !package.isLeaf {
            badges.append(PackageStateBadge(
                kind: "action-unavailable",
                title: "操作暂不可用",
                explanation: "此项不是叶子包，可能仍被其他包依赖；默认不直接提供卸载按钮。",
                severity: .info,
                filterKey: nil
            ))
        }

        return uniqueAndSorted(badges)
    }

    nonisolated private static func versionDifferenceBadge(for difference: PackageVersionDifferenceKind) -> PackageStateBadge {
        PackageStateBadge(
            kind: difference.badgeKind,
            title: difference.title,
            explanation: difference.explanation,
            severity: severity(for: difference),
            filterKey: difference.contributesToLibrarySummary ? .repoDiff : nil
        )
    }

    nonisolated private static func severity(for difference: PackageVersionDifferenceKind) -> PackageStateSeverity {
        switch difference {
        case .none, .caskMetadata, .autoUpdatingCask:
            return .info
        case .formulaRevision:
            return .attention
        case .outdatedCandidate, .unknownRawDifference:
            return .warning
        }
    }

    nonisolated private static func badge(for key: PackageStateFilterKey) -> PackageStateBadge {
        switch key {
        case .leaf:
            return PackageStateBadge(
                kind: "leaf",
                title: "叶子包",
                explanation: "这是 Homebrew 叶子包，可优先检查是否仍然需要；Cellar 不会自动判断它一定可删除。",
                severity: .attention,
                filterKey: .leaf
            )
        case .repoDiff:
            return PackageStateBadge(
                kind: "repo-diff",
                title: "版本差异",
                explanation: "本机版本与仓库版本存在差异；具体原因会按 metadata、Formula revision、自更新 App 或待确认差异分类展示。",
                severity: .warning,
                filterKey: .repoDiff
            )
        case .autoUpdates:
            return PackageStateBadge(
                kind: "auto-updates",
                title: "自更新 Cask",
                explanation: "此 Cask 支持应用内部自更新，Homebrew 不追踪其内部版本变化。",
                severity: .info,
                filterKey: .autoUpdates
            )
        case .sizeUnknown:
            return PackageStateBadge(
                kind: "size-unknown",
                title: "酒窖大小未知",
                explanation: "暂未能从本机安装路径或 Homebrew 元数据稳定计算已安装资产大小。",
                severity: .info,
                filterKey: .sizeUnknown
            )
        }
    }

    nonisolated private static func uniqueAndSorted(_ badges: [PackageStateBadge]) -> [PackageStateBadge] {
        var byKind: [String: PackageStateBadge] = [:]
        var seen: Set<String> = []
        for badge in badges where seen.insert(badge.kind).inserted {
            byKind[badge.kind] = badge
        }
        return byKind.values.sorted { order(for: $0.kind) < order(for: $1.kind) }
    }

    nonisolated private static func order(for kind: String) -> Int {
        switch kind {
        case "leaf": return 0
        case "outdated-candidate", "formula-revision", "auto-updating-version", "version-raw-diff", "cask-metadata", "repo-diff": return 1
        case "auto-updates": return 2
        case "size-unknown": return 3
        case "pinned": return 4
        case "action-unavailable": return 5
        default: return 99
        }
    }
}

struct PackageFilterVisibilitySummary: Equatable, Sendable {
    let titles: [String]

    var count: Int { titles.count }
    var menuTitle: String { count > 0 ? "筛选 \(count)" : "筛选" }
    var chips: [String] { Array(titles.prefix(2)) }
    var overflowCount: Int { max(count - chips.count, 0) }

    nonisolated static func make(
        type: PackageType?,
        showPinnedOnly: Bool,
        showLeavesOnly: Bool,
        packageStateFilter: PackageStateFilterKey?,
        isLibrary: Bool
    ) -> PackageFilterVisibilitySummary {
        var titles: [String] = []
        if let type { titles.append(type.rawValue) }
        if showPinnedOnly { titles.append("已锁定") }
        if isLibrary {
            if showLeavesOnly && packageStateFilter != .leaf { titles.append("叶子包") }
            if let packageStateFilter { titles.append(packageStateFilter.title) }
        }
        return PackageFilterVisibilitySummary(titles: titles)
    }
}
