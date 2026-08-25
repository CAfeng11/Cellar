import Foundation
import Combine

// ⚠️ 严禁在此文件引入 SwiftUI 或 AppKit！

// MARK: - 1. MODELS

enum PackageType: String, Sendable, CaseIterable, Codable {
    case formula = "Formula"
    case cask = "Cask"
}

struct PackageVersionIdentity: Equatable, Hashable, Sendable {
    let rawVersion: String
    let displayVersion: String
    let comparableVersion: String
    let formulaRevision: String?
    let caskMetadata: String?

    nonisolated static func make(rawVersion: String, type: PackageType) -> PackageVersionIdentity {
        let trimmed = rawVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let display: String
        let comparable: String
        let formulaRevision: String?
        let caskMetadata: String?
        switch type {
        case .formula:
            display = trimmed
            let revisionSplit = splitFormulaRevision(trimmed)
            comparable = revisionSplit.base
            formulaRevision = revisionSplit.revision
            caskMetadata = nil
        case .cask:
            let parts = trimmed.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            let primary = parts.first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmed
            display = primary.isEmpty ? trimmed : primary
            comparable = display
            formulaRevision = nil
            caskMetadata = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : nil
        }
        return PackageVersionIdentity(
            rawVersion: rawVersion,
            displayVersion: display.isEmpty ? rawVersion : display,
            comparableVersion: comparable.isEmpty ? rawVersion : comparable,
            formulaRevision: formulaRevision,
            caskMetadata: caskMetadata?.isEmpty == false ? caskMetadata : nil
        )
    }

    nonisolated private static func splitFormulaRevision(_ version: String) -> (base: String, revision: String?) {
        guard let range = version.range(of: #"_[0-9]+$"#, options: .regularExpression) else {
            return (version, nil)
        }
        let base = String(version[..<range.lowerBound])
        let suffix = String(version[range]).dropFirst()
        return (base.isEmpty ? version : base, suffix.isEmpty ? nil : String(suffix))
    }
}

enum PackageVersionDifferenceKind: String, Codable, Sendable, CaseIterable {
    case none
    case caskMetadata
    case formulaRevision
    case autoUpdatingCask
    case outdatedCandidate
    case unknownRawDifference

    nonisolated var title: String {
        switch self {
        case .none: return "无版本差异"
        case .caskMetadata: return "Cask 元数据差异"
        case .formulaRevision: return "Formula revision 差异"
        case .autoUpdatingCask: return "自更新 App 差异"
        case .outdatedCandidate: return "可升级"
        case .unknownRawDifference: return "版本差异待确认"
        }
    }

    nonisolated var explanation: String {
        switch self {
        case .none:
            return "本机版本与仓库版本没有需要提示的差异。"
        case .caskMetadata:
            return "Cask raw version 含有逗号后的仓库元数据；基础版本一致，不作为普通版本差异或可升级项。"
        case .formulaRevision:
            return "Formula 的基础版本一致，但 Homebrew revision 后缀不同；这不等同于 brew outdated。"
        case .autoUpdatingCask:
            return "此 App 支持应用内部自更新，仓库版本与本机版本差异不直接等同于 Homebrew 可升级。"
        case .outdatedCandidate:
            return "这是 Homebrew outdated 返回的明确升级候选。"
        case .unknownRawDifference:
            return "仓库版本与本机版本存在无法归入 metadata、revision 或自更新 App 的 raw 差异；需要查看详情确认。"
        }
    }

    nonisolated var contributesToLibrarySummary: Bool {
        switch self {
        case .formulaRevision, .autoUpdatingCask, .unknownRawDifference:
            return true
        case .none, .caskMetadata, .outdatedCandidate:
            return false
        }
    }

    nonisolated var badgeKind: String {
        switch self {
        case .none: return "version-none"
        case .caskMetadata: return "cask-metadata"
        case .formulaRevision: return "formula-revision"
        case .autoUpdatingCask: return "auto-updating-version"
        case .outdatedCandidate: return "outdated-candidate"
        case .unknownRawDifference: return "version-raw-diff"
        }
    }
}

enum CaskAppBundleVersionReadResult: Equatable, Sendable {
    case found(shortVersion: String, buildVersion: String?, bundlePath: String)
    case unavailable(reason: String)

    nonisolated var shortVersion: String? {
        if case .found(let shortVersion, _, _) = self { return shortVersion }
        return nil
    }

    nonisolated var buildVersion: String? {
        if case .found(_, let buildVersion, _) = self { return buildVersion }
        return nil
    }

    nonisolated var bundlePath: String? {
        if case .found(_, _, let bundlePath) = self { return bundlePath }
        return nil
    }

    nonisolated var detailText: String {
        switch self {
        case .found(let shortVersion, let buildVersion, let bundlePath):
            let build = buildVersion.map { "，构建版本 \($0)" } ?? ""
            return "已从 \(bundlePath) 读取 App 实际版本：\(shortVersion)\(build)。"
        case .unavailable(let reason):
            return "未读到 App 实际版本：\(reason)。"
        }
    }
}

struct CaskVersionTruth: Equatable, Sendable {
    let homebrewReceiptVersion: String?
    let appBundleVersion: String?
    let appBundleBuildVersion: String?
    let appBundleReadResult: CaskAppBundleVersionReadResult
    let repositoryVersion: String

    nonisolated var homebrewReceiptIdentity: PackageVersionIdentity? {
        homebrewReceiptVersion.map { PackageVersionIdentity.make(rawVersion: $0, type: .cask) }
    }

    nonisolated var appBundleIdentity: PackageVersionIdentity? {
        appBundleVersion.map { PackageVersionIdentity.make(rawVersion: $0, type: .cask) }
    }

    nonisolated var repositoryIdentity: PackageVersionIdentity {
        PackageVersionIdentity.make(rawVersion: repositoryVersion, type: .cask)
    }

    nonisolated var preferredInstalledIdentity: PackageVersionIdentity? {
        appBundleIdentity ?? homebrewReceiptIdentity
    }

    nonisolated var preferredInstalledDisplayVersion: String {
        preferredInstalledIdentity?.displayVersion ?? "-"
    }

    nonisolated var installedSourceLabel: String? {
        if appBundleIdentity != nil {
            return "App 实际版本"
        }
        if homebrewReceiptIdentity != nil {
            return "未读到 App 实际版本，暂用 Homebrew 记录"
        }
        return "未读到 App 实际版本"
    }

    nonisolated var helpText: String {
        let appVersion = appBundleIdentity?.rawVersion ?? "-"
        let appBuild = appBundleBuildVersion ?? "-"
        let receipt = homebrewReceiptIdentity?.rawVersion ?? "-"
        return [
            "当前 App 版本：\(appVersion)",
            "App 构建版本：\(appBuild)",
            "Homebrew 记录：\(receipt)",
            "Homebrew 仓库版本：\(repositoryIdentity.rawVersion)",
            appBundleReadResult.detailText
        ].joined(separator: "。")
    }

    nonisolated static func make(
        homebrewReceiptVersion: String?,
        appBundleReadResult: CaskAppBundleVersionReadResult,
        repositoryVersion: String
    ) -> CaskVersionTruth {
        CaskVersionTruth(
            homebrewReceiptVersion: homebrewReceiptVersion?.nilIfBlank,
            appBundleVersion: appBundleReadResult.shortVersion?.nilIfBlank,
            appBundleBuildVersion: appBundleReadResult.buildVersion?.nilIfBlank,
            appBundleReadResult: appBundleReadResult,
            repositoryVersion: repositoryVersion
        )
    }
}

enum CaskSizeProbeCandidate: Equatable, Sendable {
    case appBundle(path: String)
    case caskroomVersionDirectory(path: String)

    nonisolated var path: String {
        switch self {
        case .appBundle(let path), .caskroomVersionDirectory(let path):
            return path
        }
    }
}

enum CaskAppBundlePathResolver {
    nonisolated static func candidatePaths(appArtifactNames: [String]) -> [String] {
        let cleanedNames = appArtifactNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let homeApplications = NSString(string: "~/Applications").expandingTildeInPath
        let candidates = cleanedNames.flatMap { appName -> [String] in
            let normalized = appName.hasSuffix(".app") ? appName : "\(appName).app"
            return [
                "/Applications/\(normalized)",
                "\(homeApplications)/\(normalized)"
            ]
        }
        return uniqueStable(candidates)
    }

    nonisolated static func sizeProbeCandidates(for package: BrewPackage) -> [CaskSizeProbeCandidate] {
        var candidates: [CaskSizeProbeCandidate] = []
        if let bundlePath = package.caskVersionTruth?.appBundleReadResult.bundlePath {
            candidates.append(.appBundle(path: bundlePath))
        }
        candidates.append(contentsOf: candidatePaths(appArtifactNames: package.appArtifactNames).map { .appBundle(path: $0) })
        if let version = package.installedVersions.first?.nilIfBlank {
            candidates.append(.caskroomVersionDirectory(path: "/opt/homebrew/Caskroom/\(package.name)/\(version)"))
            candidates.append(.caskroomVersionDirectory(path: "/usr/local/Caskroom/\(package.name)/\(version)"))
        }
        return uniqueStable(candidates)
    }

    nonisolated static func sizeProbeCandidatePaths(for package: BrewPackage) -> [String] {
        sizeProbeCandidates(for: package).map(\.path)
    }

    nonisolated static func appBundleCandidates(inCaskroomVersionDirectory directoryPath: String) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directoryPath) else { return [] }
        return entries
            .filter { $0.hasSuffix(".app") }
            .map { URL(fileURLWithPath: directoryPath).appendingPathComponent($0).path }
            .sorted()
    }

    nonisolated private static func uniqueStable(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    nonisolated private static func uniqueStable(_ values: [CaskSizeProbeCandidate]) -> [CaskSizeProbeCandidate] {
        var seen = Set<String>()
        return values.filter { candidate in
            let key: String
            switch candidate {
            case .appBundle(let path):
                key = "app:\(path)"
            case .caskroomVersionDirectory(let path):
                key = "caskroom:\(path)"
            }
            return seen.insert(key).inserted
        }
    }
}

enum PackageVersionOrdering: Sendable {
    case ascending
    case same
    case descending
    case unknown
}

enum PackageVersionComparator {
    nonisolated static func compare(_ lhs: String?, _ rhs: String?) -> PackageVersionOrdering {
        guard let lhs = lhs?.nilIfBlank, let rhs = rhs?.nilIfBlank else { return .unknown }
        let left = components(from: lhs)
        let right = components(from: rhs)
        guard !left.isEmpty, !right.isEmpty else { return lhs == rhs ? .same : .unknown }

        for index in 0..<max(left.count, right.count) {
            let leftComponent = index < left.count ? left[index] : .number(0)
            let rightComponent = index < right.count ? right[index] : .number(0)
            switch compare(leftComponent, rightComponent) {
            case .orderedAscending: return .ascending
            case .orderedDescending: return .descending
            case .orderedSame: continue
            }
        }
        return .same
    }

    private enum Component: Equatable {
        case number(Int)
        case text(String)
    }

    nonisolated private static func components(from version: String) -> [Component] {
        version
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .compactMap { token -> Component? in
                let value = String(token)
                guard !value.isEmpty else { return nil }
                if let number = Int(value) {
                    return .number(number)
                }
                return .text(value)
            }
    }

    nonisolated private static func compare(_ lhs: Component, _ rhs: Component) -> ComparisonResult {
        switch (lhs, rhs) {
        case (.number(let left), .number(let right)):
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
            return .orderedSame
        case (.text(let left), .text(let right)):
            return left.compare(right, options: [.numeric])
        case (.number, .text):
            return .orderedAscending
        case (.text, .number):
            return .orderedDescending
        }
    }
}

enum AutoUpdatingCaskUpdateState: Equatable, Sendable {
    case notAutoUpdatingCask
    case appHasNewRepositoryVersion
    case appMatchesRepositoryReceiptLagging
    case appAheadOfRepositoryReceiptLagging
    case appVersionUnavailable
    case recordDifference

    nonisolated var title: String {
        switch self {
        case .notAutoUpdatingCask:
            return "普通更新"
        case .appHasNewRepositoryVersion:
            return "自更新 App 有新仓库版本"
        case .appMatchesRepositoryReceiptLagging:
            return "App 已是仓库版本，Homebrew 记录滞后"
        case .appAheadOfRepositoryReceiptLagging:
            return "App 高于仓库版本，Homebrew 记录滞后"
        case .appVersionUnavailable:
            return "未读到 App 实际版本"
        case .recordDifference:
            return "版本记录差异"
        }
    }

    nonisolated var explanation: String {
        switch self {
        case .notAutoUpdatingCask:
            return "此项目属于普通 Homebrew 升级候选。"
        case .appHasNewRepositoryVersion:
            return "App 支持内部自更新，仓库已有更高版本；普通批量升级不会处理它，可在后续自更新同步入口复核。"
        case .appMatchesRepositoryReceiptLagging:
            return "当前 App 已达到仓库版本，但 Homebrew receipt 仍记录旧版本；这不计入普通可升级数量。"
        case .appAheadOfRepositoryReceiptLagging:
            return "当前 App 版本已经高于 Homebrew 仓库记录，Homebrew receipt 仍可能滞后；这不计入普通可升级数量。"
        case .appVersionUnavailable:
            return "Cellar 未读到 App bundle 实际版本，已降级使用 Homebrew 记录；需要先确认 App 是否暴露版本信息。"
        case .recordDifference:
            return "App 实际版本、Homebrew 记录和仓库版本之间存在记录差异；这不等同于普通 Homebrew 可升级。"
        }
    }

    nonisolated var updateListGroupKind: PackageUpdateListGroupKind {
        switch self {
        case .appHasNewRepositoryVersion, .appVersionUnavailable:
            return .selfUpdatingAttention
        case .appMatchesRepositoryReceiptLagging, .appAheadOfRepositoryReceiptLagging, .recordDifference:
            return .versionRecordDifference
        case .notAutoUpdatingCask:
            return .ordinary
        }
    }
}

struct CaskAppBundleVersionReader {
    nonisolated static func readVersion(appArtifactNames: [String]) -> CaskAppBundleVersionReadResult {
        let cleanedNames = appArtifactNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleanedNames.isEmpty else {
            return .unavailable(reason: "Homebrew 元数据没有提供 .app artifact 名称")
        }
        let candidatePaths = CaskAppBundlePathResolver.candidatePaths(appArtifactNames: cleanedNames)

        for bundlePath in candidatePaths where FileManager.default.fileExists(atPath: bundlePath) {
            let infoURL = URL(fileURLWithPath: bundlePath)
                .appendingPathComponent("Contents")
                .appendingPathComponent("Info.plist")
            guard FileManager.default.fileExists(atPath: infoURL.path) else { continue }
            do {
                let data = try Data(contentsOf: infoURL)
                guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                    continue
                }
                let shortVersion = (plist["CFBundleShortVersionString"] as? String)?.nilIfBlank
                let buildVersion = (plist["CFBundleVersion"] as? String)?.nilIfBlank
                if let shortVersion {
                    return .found(shortVersion: shortVersion, buildVersion: buildVersion, bundlePath: bundlePath)
                }
                if let buildVersion {
                    return .found(shortVersion: buildVersion, buildVersion: buildVersion, bundlePath: bundlePath)
                }
            } catch {
                continue
            }
        }

        return .unavailable(reason: "未在 /Applications 或 ~/Applications 找到可读取版本的 App bundle")
    }
}

struct BrewPackage: Identifiable, Equatable, Sendable {
    nonisolated var id: String { "\(type.rawValue):\(name)" }
    let name: String
    let desc: String?
    let installedVersions: [String]
    let currentVersion: String
    var isPinned: Bool
    let isLeaf: Bool
    let type: PackageType

    // --- BEGIN APPEND: BrewPackage C3-R1-STRICT-R2 ---
    let autoUpdates: Bool
    var installedSizeBytes: Int64?
    let appArtifactNames: [String]
    let caskVersionTruth: CaskVersionTruth?

    nonisolated init(
        name: String,
        desc: String?,
        installedVersions: [String],
        currentVersion: String,
        isPinned: Bool,
        isLeaf: Bool,
        type: PackageType,
        autoUpdates: Bool,
        installedSizeBytes: Int64?,
        appArtifactNames: [String],
        caskVersionTruth: CaskVersionTruth? = nil
    ) {
        self.name = name
        self.desc = desc
        self.installedVersions = installedVersions
        self.currentVersion = currentVersion
        self.isPinned = isPinned
        self.isLeaf = isLeaf
        self.type = type
        self.autoUpdates = autoUpdates
        self.installedSizeBytes = installedSizeBytes
        self.appArtifactNames = appArtifactNames
        self.caskVersionTruth = caskVersionTruth
    }

    nonisolated var hasRepoDiff: Bool {
        versionDifferenceKind.contributesToLibrarySummary
    }
    // --- END APPEND: BrewPackage C3-R1-STRICT-R2 ---

    nonisolated var installedVersionIdentities: [PackageVersionIdentity] {
        if type == .cask, autoUpdates, let identity = caskVersionTruth?.preferredInstalledIdentity {
            return [identity]
        }
        return installedVersions.map { PackageVersionIdentity.make(rawVersion: $0, type: type) }
    }

    nonisolated var currentVersionIdentity: PackageVersionIdentity {
        PackageVersionIdentity.make(rawVersion: currentVersion, type: type)
    }

    nonisolated var versionDisplay: String {
        if type == .cask, autoUpdates, let caskVersionTruth {
            return caskVersionTruth.preferredInstalledDisplayVersion
        }
        let versions = installedVersionIdentities.map(\.displayVersion)
        return versions.isEmpty ? "-" : versions.joined(separator: ", ")
    }

    nonisolated var installedVersionHelpText: String {
        if type == .cask, autoUpdates, let caskVersionTruth {
            return caskVersionTruth.helpText
        }
        let raw = installedVersions.isEmpty ? "-" : installedVersions.joined(separator: ", ")
        return "已安装版本：\(raw)"
    }

    nonisolated var currentVersionDisplay: String {
        currentVersionIdentity.displayVersion
    }

    nonisolated var currentVersionHelpText: String {
        versionHelpText(isOutdatedCandidate: false)
    }

    nonisolated var versionDifferenceKind: PackageVersionDifferenceKind {
        versionDifferenceKind(isOutdatedCandidate: false)
    }

    nonisolated var autoUpdatingCaskUpdateState: AutoUpdatingCaskUpdateState {
        guard type == .cask, autoUpdates else { return .notAutoUpdatingCask }
        guard let truth = caskVersionTruth else {
            return .appVersionUnavailable
        }
        guard let appComparable = truth.appBundleIdentity?.comparableVersion.nilIfBlank else {
            return .appVersionUnavailable
        }

        let repositoryComparable = truth.repositoryIdentity.comparableVersion
        let appToRepository = PackageVersionComparator.compare(appComparable, repositoryComparable)
        let receiptToRepository = PackageVersionComparator.compare(
            truth.homebrewReceiptIdentity?.comparableVersion,
            repositoryComparable
        )

        switch appToRepository {
        case .ascending:
            return .appHasNewRepositoryVersion
        case .same:
            if case .ascending = receiptToRepository {
                return .appMatchesRepositoryReceiptLagging
            }
            return .recordDifference
        case .descending:
            switch receiptToRepository {
            case .ascending, .same:
                return .appAheadOfRepositoryReceiptLagging
            case .descending, .unknown:
                return .recordDifference
            }
        case .unknown:
            return .recordDifference
        }
    }

    nonisolated func versionDifferenceKind(isOutdatedCandidate: Bool) -> PackageVersionDifferenceKind {
        if isOutdatedCandidate {
            if type == .cask, autoUpdates {
                return .autoUpdatingCask
            }
            return .outdatedCandidate
        }
        guard let installed = installedVersionIdentities.first else { return .none }
        let current = currentVersionIdentity
        guard installed.comparableVersion != "?", current.comparableVersion != "?" else { return .none }

        switch type {
        case .formula:
            if installed.comparableVersion == current.comparableVersion {
                if installed.formulaRevision != current.formulaRevision {
                    return .formulaRevision
                }
                return .none
            }
            return .unknownRawDifference
        case .cask:
            if installed.comparableVersion == current.comparableVersion {
                if installed.rawVersion != current.rawVersion, installed.caskMetadata != current.caskMetadata {
                    return .caskMetadata
                }
                return .none
            }
            return autoUpdates ? .autoUpdatingCask : .unknownRawDifference
        }
    }

    nonisolated func versionHelpText(isOutdatedCandidate: Bool) -> String {
        let identity = currentVersionIdentity
        let installedRaw = installedVersions.isEmpty ? "-" : installedVersions.joined(separator: ", ")
        let installedComparable = installedVersionIdentities.map(\.comparableVersion).joined(separator: ", ")
        let difference = versionDifferenceKind(isOutdatedCandidate: isOutdatedCandidate)
        var lines = [
            "仓库显示版本：\(identity.displayVersion)",
            "Homebrew 原始仓库版本：\(identity.rawVersion)",
            "本机原始版本：\(installedRaw)",
            "比较版本：本机 \(installedComparable.isEmpty ? "-" : installedComparable) / 仓库 \(identity.comparableVersion)",
            "差异分类：\(difference.title)。\(difference.explanation)"
        ]
        if type == .cask, autoUpdates, let caskVersionTruth {
            lines.append(caskVersionTruth.helpText)
        }
        return lines.joined(separator: "。")
    }
}

private extension String {
    nonisolated var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct PackageVersionTablePresentation: Equatable, Sendable {
    let versionText: String
    let differenceLabel: String?
    let helpText: String
    let differenceKind: PackageVersionDifferenceKind

    nonisolated var visibleText: String {
        guard let differenceLabel else { return versionText }
        return "\(versionText)（\(differenceLabel)）"
    }

    nonisolated static func make(for package: BrewPackage, isLibrary: Bool) -> PackageVersionTablePresentation {
        let difference = package.versionDifferenceKind(isOutdatedCandidate: !isLibrary)
        let label = (!isLibrary && package.type == .cask && package.autoUpdates)
            ? package.autoUpdatingCaskUpdateState.title
            : tableLabel(for: difference)
        let help = (!isLibrary && package.type == .cask && package.autoUpdates)
            ? [
                package.autoUpdatingCaskUpdateState.explanation,
                package.versionHelpText(isOutdatedCandidate: !isLibrary)
            ].joined(separator: "。")
            : package.versionHelpText(isOutdatedCandidate: !isLibrary)
        return PackageVersionTablePresentation(
            versionText: package.currentVersionDisplay,
            differenceLabel: label,
            helpText: help,
            differenceKind: difference
        )
    }

    nonisolated private static func tableLabel(for difference: PackageVersionDifferenceKind) -> String? {
        switch difference {
        case .none:
            return nil
        case .caskMetadata:
            return "同主版本，Cask 元数据差异"
        case .formulaRevision:
            return "同主版本，revision 差异"
        case .autoUpdatingCask:
            return "自更新 App 差异"
        case .outdatedCandidate:
            return "可升级"
        case .unknownRawDifference:
            return "版本差异待确认"
        }
    }
}

struct PackageInstalledVersionPresentation: Equatable, Sendable {
    let versionText: String
    let sourceLabel: String?
    let secondaryText: String?
    let helpText: String

    nonisolated var visibleText: String {
        [versionText, sourceLabel, secondaryText]
            .compactMap { $0 }
            .joined(separator: "，")
    }

    nonisolated static func make(for package: BrewPackage) -> PackageInstalledVersionPresentation {
        guard package.type == .cask, package.autoUpdates, let truth = package.caskVersionTruth else {
            return PackageInstalledVersionPresentation(
                versionText: package.versionDisplay,
                sourceLabel: nil,
                secondaryText: nil,
                helpText: package.installedVersionHelpText
            )
        }

        let receiptDisplay = truth.homebrewReceiptIdentity?.displayVersion
        let hasAppBundleVersion = truth.appBundleIdentity != nil
        let secondary: String?
        if let receiptDisplay {
            secondary = hasAppBundleVersion
                ? "Homebrew 记录 \(receiptDisplay)"
                : "暂用 Homebrew 记录 \(receiptDisplay)"
        } else {
            secondary = nil
        }

        return PackageInstalledVersionPresentation(
            versionText: truth.preferredInstalledDisplayVersion,
            sourceLabel: truth.installedSourceLabel,
            secondaryText: secondary,
            helpText: truth.helpText
        )
    }
}

enum PackageCaskTruthMerger {
    nonisolated static func mergeInstalledCaskTruth(
        into candidates: [BrewPackage],
        from installedPackages: [BrewPackage]
    ) -> [BrewPackage] {
        let installedByID = Dictionary(uniqueKeysWithValues: installedPackages.map { ($0.id, $0) })
        return candidates.map { candidate in
            guard candidate.type == .cask, let installed = installedByID[candidate.id] else {
                return candidate
            }
            guard installed.autoUpdates || installed.caskVersionTruth != nil || !installed.appArtifactNames.isEmpty else {
                return candidate
            }

            let mergedTruth = installed.caskVersionTruth.map { truth in
                CaskVersionTruth.make(
                    homebrewReceiptVersion: truth.homebrewReceiptVersion ?? installed.installedVersions.first,
                    appBundleReadResult: truth.appBundleReadResult,
                    repositoryVersion: candidate.currentVersion
                )
            }

            return BrewPackage(
                name: candidate.name,
                desc: candidate.desc ?? installed.desc,
                installedVersions: installed.installedVersions.isEmpty ? candidate.installedVersions : installed.installedVersions,
                currentVersion: candidate.currentVersion,
                isPinned: candidate.isPinned,
                isLeaf: installed.isLeaf,
                type: candidate.type,
                autoUpdates: installed.autoUpdates,
                installedSizeBytes: candidate.installedSizeBytes ?? installed.installedSizeBytes,
                appArtifactNames: installed.appArtifactNames,
                caskVersionTruth: mergedTruth
            )
        }
    }
}

enum PackageUpgradeScope {
    nonisolated static func isOrdinaryUpgradeCandidate(_ package: BrewPackage) -> Bool {
        !(package.type == .cask && package.autoUpdates)
    }

    nonisolated static func ordinaryUpgradeCandidates(in packages: [BrewPackage]) -> [BrewPackage] {
        packages.filter(isOrdinaryUpgradeCandidate)
    }

    nonisolated static func autoUpdatingObservationCandidates(in packages: [BrewPackage]) -> [BrewPackage] {
        packages.filter { $0.type == .cask && $0.autoUpdates }
    }

    nonisolated static func upgradeArgumentGroups(for packages: [BrewPackage]) -> [[String]] {
        let ordinary = ordinaryUpgradeCandidates(in: packages)
        let formulaNames = ordinary
            .filter { $0.type == .formula }
            .map(\.name)
        let caskNames = ordinary
            .filter { $0.type == .cask }
            .map(\.name)

        var groups: [[String]] = []
        if !formulaNames.isEmpty {
            groups.append(formulaNames)
        }
        if !caskNames.isEmpty {
            groups.append(["--cask"] + caskNames)
        }
        return groups
    }
}

enum PackageGreedySyncScope {
    nonisolated static func isEligible(_ package: BrewPackage) -> Bool {
        package.type == .cask && package.autoUpdates
    }

    nonisolated static func upgradeArguments(for package: BrewPackage) -> [String]? {
        guard isEligible(package) else { return nil }
        return ["--cask", "--greedy", package.name]
    }
}

enum PackageGreedySyncConfirmation {
    nonisolated static func title(for package: BrewPackage?) -> String {
        guard let package else { return "确认贪婪同步?" }
        return "确认贪婪同步 \(package.name)?"
    }

    nonisolated static func message(for package: BrewPackage?) -> String {
        guard let package else {
            return "未选择自更新 Cask。"
        }
        let appVersion: String
        let receiptVersion: String
        let repositoryVersion: String
        let readDetail: String
        if let truth = package.caskVersionTruth {
            appVersion = truth.appBundleIdentity?.displayVersion ?? "未读到 App 实际版本"
            receiptVersion = truth.homebrewReceiptIdentity?.displayVersion ?? "无 Homebrew 记录"
            repositoryVersion = truth.repositoryIdentity.displayVersion
            readDetail = truth.appBundleReadResult.detailText
        } else {
            appVersion = "未读到 App 实际版本"
            receiptVersion = package.installedVersionIdentities.first?.displayVersion ?? "无 Homebrew 记录"
            repositoryVersion = package.currentVersionDisplay
            readDetail = "未读到 App 实际版本：当前更新候选没有合并 App bundle truth。"
        }
        let command = PackageGreedySyncScope.upgradeArguments(for: package)
            .map { "brew upgrade \($0.joined(separator: " "))" } ?? "不适用"
        return [
            "当前 App 版本：\(appVersion)",
            "Homebrew 记录版本：\(receiptVersion)",
            "Homebrew 仓库版本：\(repositoryVersion)",
            readDetail,
            "将执行：\(command)",
            "该动作会通过 Homebrew 重新下载并覆盖安装此 Cask；App 可能已经由内部更新器更新。",
            "普通批量升级不会处理自更新 App；这是显式高级动作。"
        ].joined(separator: "\n")
    }
}

enum PackageUpdateListGroupKind: String, CaseIterable, Sendable {
    case ordinary
    case selfUpdatingAttention
    case versionRecordDifference

    nonisolated var title: String {
        switch self {
        case .ordinary:
            return "可升级"
        case .selfUpdatingAttention:
            return "自更新 App 可同步"
        case .versionRecordDifference:
            return "版本记录差异"
        }
    }

    nonisolated var countLabel: String {
        switch self {
        case .ordinary:
            return "普通更新"
        case .selfUpdatingAttention:
            return "关注项"
        case .versionRecordDifference:
            return "记录差异"
        }
    }

    nonisolated var subtitle: String {
        switch self {
        case .ordinary:
            return "这些项目会进入普通升级和批量升级目标集合。"
        case .selfUpdatingAttention:
            return "这些 App 由应用内部更新器维护；Cellar 仅提示仓库已有新版本，不纳入普通升级。"
        case .versionRecordDifference:
            return "这些项目的当前 App、Homebrew 记录和仓库版本存在差异；不计入普通更新数量。"
        }
    }

    nonisolated var sortOrder: Int {
        switch self {
        case .ordinary: return 0
        case .selfUpdatingAttention: return 1
        case .versionRecordDifference: return 2
        }
    }
}

struct PackageUpdateListGroup: Identifiable, Equatable, Sendable {
    let kind: PackageUpdateListGroupKind
    let packages: [BrewPackage]

    nonisolated var id: String { kind.rawValue }
    nonisolated var title: String { kind.title }
    nonisolated var subtitle: String { kind.subtitle }
    nonisolated var countText: String { "\(kind.countLabel) \(packages.count)" }
}

struct PackageUpdateListSummary: Equatable, Sendable {
    let ordinaryUpgradeCount: Int
    let selfUpdatingAttentionCount: Int
    let versionRecordDifferenceCount: Int

    nonisolated var visibleText: String {
        [
            "普通更新 \(ordinaryUpgradeCount)",
            "自更新关注 \(selfUpdatingAttentionCount)",
            "版本记录差异 \(versionRecordDifferenceCount)"
        ].joined(separator: " · ")
    }
}

enum PackageUpdateListClassifier {
    nonisolated static func groups(for packages: [BrewPackage]) -> [PackageUpdateListGroup] {
        let grouped = Dictionary(grouping: packages) { groupKind(for: $0) }
        return PackageUpdateListGroupKind.allCases
            .compactMap { kind -> PackageUpdateListGroup? in
                let groupPackages = (grouped[kind] ?? []).sorted { $0.name < $1.name }
                guard !groupPackages.isEmpty else { return nil }
                return PackageUpdateListGroup(kind: kind, packages: groupPackages)
            }
            .sorted { $0.kind.sortOrder < $1.kind.sortOrder }
    }

    nonisolated static func summary(for packages: [BrewPackage]) -> PackageUpdateListSummary {
        let groups = Dictionary(grouping: packages) { groupKind(for: $0) }
        return PackageUpdateListSummary(
            ordinaryUpgradeCount: groups[.ordinary]?.count ?? 0,
            selfUpdatingAttentionCount: groups[.selfUpdatingAttention]?.count ?? 0,
            versionRecordDifferenceCount: groups[.versionRecordDifference]?.count ?? 0
        )
    }

    nonisolated static func groupKind(for package: BrewPackage) -> PackageUpdateListGroupKind {
        guard package.type == .cask, package.autoUpdates else {
            return .ordinary
        }
        return package.autoUpdatingCaskUpdateState.updateListGroupKind
    }
}

struct BrewSearchItem: Identifiable, Equatable, Sendable {
    var id: String { "\(type?.rawValue ?? "Unknown"):\(name)" }
    let name: String
    let type: PackageType?
}

struct BrewInfo: Sendable, Decodable {
    let name: String
    let desc: String?
    let homepage: String?
    let versions: Versions?
    let caveats: String?
    let dependencies: [String]?
    let conflicts_with: [String]?
    let installed: [InstalledEntry]?

    struct Versions: Decodable, Sendable { let stable: String? }
    struct InstalledEntry: Decodable, Sendable { let version: String }

    var stableVersion: String { versions?.stable ?? "Unknown" }
    var installedVersionList: [String] { installed?.map { $0.version } ?? [] }
}

enum BrewStatus: Equatable {
    case idle, upToDate, outdated(Int), error(String)
    var description: String {
        switch self {
        case .idle: return "就绪"
        case .upToDate: return "Homebrew 无普通可升级项目"
        case .outdated(let c): return "发现 \(c) 个普通可升级项目"
        case .error(let e): return "错误: \(e)"
        }
    }
}

enum HomebrewSnapshotKind: String, Codable, Sendable {
    case outdated
    case installedLibrary

    nonisolated var title: String {
        switch self {
        case .outdated: return "更新列表快照"
        case .installedLibrary: return "酒窖清点快照"
        }
    }
}

enum HomebrewSnapshotSource: String, Codable, Sendable {
    case notCaptured
    case brewOutdated
    case brewUpdateThenOutdated
    case brewInstalledInfo

    nonisolated var displayName: String {
        switch self {
        case .notCaptured: return "尚未采集"
        case .brewOutdated: return "brew outdated --json=v2"
        case .brewUpdateThenOutdated: return "brew update + brew outdated --json=v2"
        case .brewInstalledInfo: return "brew info --json=v2 --installed"
        }
    }
}

enum HomebrewSnapshotCommandStatus: String, Codable, Sendable {
    case notRun
    case succeeded
    case failed
    case cancelled

    nonisolated var displayName: String {
        switch self {
        case .notRun: return "未执行"
        case .succeeded: return "成功"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }
}

enum HomebrewSnapshotFallbackState: String, Codable, Sendable {
    case none
    case usingLastSuccessfulSnapshot
    case noUsableSnapshot

    nonisolated var displayName: String {
        switch self {
        case .none: return "无 fallback"
        case .usingLastSuccessfulSnapshot: return "基于上次成功快照"
        case .noUsableSnapshot: return "无可用 fallback"
        }
    }
}

struct HomebrewSnapshotProvenance: Codable, Hashable, Sendable {
    let kind: HomebrewSnapshotKind
    let source: HomebrewSnapshotSource
    let capturedAt: Date?
    let lastSuccessfulCapturedAt: Date?
    let commandStatus: HomebrewSnapshotCommandStatus
    let fallbackState: HomebrewSnapshotFallbackState
    let failureMessage: String?
    let warnings: [String]

    nonisolated static func notCaptured(kind: HomebrewSnapshotKind) -> HomebrewSnapshotProvenance {
        HomebrewSnapshotProvenance(
            kind: kind,
            source: .notCaptured,
            capturedAt: nil,
            lastSuccessfulCapturedAt: nil,
            commandStatus: .notRun,
            fallbackState: .noUsableSnapshot,
            failureMessage: nil,
            warnings: ["尚未完成 \(kind.title) 采集。"]
        )
    }

    nonisolated static func succeeded(
        kind: HomebrewSnapshotKind,
        source: HomebrewSnapshotSource,
        capturedAt: Date = Date(),
        warnings: [String] = []
    ) -> HomebrewSnapshotProvenance {
        HomebrewSnapshotProvenance(
            kind: kind,
            source: source,
            capturedAt: capturedAt,
            lastSuccessfulCapturedAt: capturedAt,
            commandStatus: .succeeded,
            fallbackState: .none,
            failureMessage: nil,
            warnings: warnings
        )
    }

    nonisolated static func failed(
        kind: HomebrewSnapshotKind,
        source: HomebrewSnapshotSource,
        error: Error,
        previous: HomebrewSnapshotProvenance,
        capturedAt: Date = Date()
    ) -> HomebrewSnapshotProvenance {
        let isCancelled = error is CancellationError || (error as? BrewError) == .cancelled
        let lastSuccess = previous.lastSuccessfulCapturedAt
        let issue = isCancelled ? nil : BrewReliabilityDiagnostics.diagnose(error: error)
        var warnings: [String] = []
        if let issue {
            warnings.append("\(issue.title)：\(issue.impact) \(issue.nextStep)")
        }
        if lastSuccess != nil {
            warnings.append("本次命令失败，当前列表或酒窖状态仅代表上次成功采集结果。")
        } else {
            warnings.append("本次命令失败，当前没有可确认的新快照。")
        }
        return HomebrewSnapshotProvenance(
            kind: kind,
            source: source,
            capturedAt: capturedAt,
            lastSuccessfulCapturedAt: lastSuccess,
            commandStatus: isCancelled ? .cancelled : .failed,
            fallbackState: lastSuccess == nil ? .noUsableSnapshot : .usingLastSuccessfulSnapshot,
            failureMessage: error.localizedDescription,
            warnings: warnings
        )
    }

    nonisolated var isAuthoritativeSuccess: Bool {
        commandStatus == .succeeded && fallbackState == .none
    }

    nonisolated var statusTitle: String {
        switch commandStatus {
        case .succeeded:
            return "\(kind.title)已更新"
        case .failed:
            return fallbackState == .usingLastSuccessfulSnapshot ? "本次检查失败，显示上次成功快照" : "本次检查失败，无可确认快照"
        case .cancelled:
            return fallbackState == .usingLastSuccessfulSnapshot ? "检查已取消，显示上次成功快照" : "检查已取消"
        case .notRun:
            return "\(kind.title)尚未采集"
        }
    }

    nonisolated var detailText: String {
        let sourceText = "来源：\(source.displayName)"
        let captured = capturedAt.map { "记录时间：\($0.formatted(date: .abbreviated, time: .standard))" } ?? "记录时间：-"
        let lastSuccess = lastSuccessfulCapturedAt.map { "上次成功：\($0.formatted(date: .abbreviated, time: .standard))" } ?? "上次成功：-"
        let fallback = "fallback：\(fallbackState.displayName)"
        let failure = failureMessage.map { "失败原因：\($0)" }
        return ([sourceText, captured, lastSuccess, fallback] + [failure].compactMap { $0 }).joined(separator: "；")
    }

    nonisolated var reportLines: [String] {
        var lines = [
            "- \(kind.title): \(statusTitle)",
            "  Source: \(source.displayName)",
            "  Captured at: \(capturedAt.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "-")",
            "  Last successful snapshot: \(lastSuccessfulCapturedAt.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "-")",
            "  Command status: \(commandStatus.displayName)",
            "  Fallback state: \(fallbackState.displayName)"
        ]
        if let failureMessage {
            lines.append("  Failure: \(failureMessage)")
        }
        if warnings.isEmpty {
            lines.append("  Warnings: none")
        } else {
            lines.append("  Warnings: \(warnings.joined(separator: " | "))")
        }
        return lines
    }
}

enum BrewError: LocalizedError, Equatable {
    case brewNotFound, executionFailed(code: Int, message: String), parseError(String), timedOut(command: String, seconds: Int), cancelled
    var errorDescription: String? {
        switch self {
        case .brewNotFound: return "未找到 Homebrew"
        case .executionFailed(let c, let m): return "执行失败 (Code \(c)):\n\(m)"
        case .parseError(let m): return "数据解析错误: \(m)"
        case .timedOut(let command, let seconds): return "执行超时：\(command) 在 \(seconds) 秒内没有完成或没有继续输出。"
        case .cancelled: return "操作已取消"
        }
    }
}

// MARK: - 2. COMMAND SPEC

enum BrewCommand: Sendable {
    case listPinned, checkOutdated, info(String), update, upgrade([String]), uninstall(String, isCask: Bool)
    case pin(String), unpin(String), cleanup, listLeaves, listInstalledJSON
    case searchFormulae(String), searchCasks(String), install(String, isCask: Bool), bundleDump(String)

    var args: [String] {
        switch self {
        case .listPinned: return ["list", "--pinned"]
        case .checkOutdated: return ["outdated", "--json=v2"]
        case .info(let n): return ["info", "--json=v2", n]
        case .update: return ["update"]
        case .upgrade(let t): return ["upgrade"] + t
        case .uninstall(let n, let c): var a = ["uninstall"]; if c { a.append("--cask") }; a.append(n); return a
        case .pin(let n): return ["pin", n]
        case .unpin(let n): return ["unpin", n]
        case .cleanup: return ["cleanup"]
        case .listLeaves: return ["leaves"]
        case .listInstalledJSON: return ["info", "--json=v2", "--installed"]
        case .searchFormulae(let q): return ["search", "--formulae", q]
        case .searchCasks(let q): return ["search", "--casks", q]
        case .install(let n, let c): var a = ["install"]; if c { a.append("--cask") }; a.append(n); return a
        case .bundleDump(let p): return ["bundle", "dump", "--file=\(p)", "--force"]
        }
    }

    var displayCommand: String {
        "brew \(args.joined(separator: " "))"
    }
}

// MARK: - 3. THREAD SAFE HELPERS
// 恢复经受过严苛考验的 NSLock 门闩机制，最大程度避免重复读/尾部丢失，并确保 Task 取消能收敛

private final class ExecutionState: @unchecked Sendable {
    private let lock = NSLock()
    private var _didFinalize = false
    private var _didResume = false

    func checkFinalized() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _didFinalize
    }

    func markFinalized() {
        lock.lock(); defer { lock.unlock() }
        _didFinalize = true
    }

    func resumeOnce(continuation: CheckedContinuation<String, Error>, result: Result<String, Error>) {
        lock.lock()
        if _didResume { lock.unlock(); return }
        _didResume = true
        lock.unlock()
        continuation.resume(with: result)
    }
}

private final class ProcessContainer: @unchecked Sendable {
    private var process: Process?
    private var cancelled = false
    private var timeoutCommand: String?
    private var timeoutSeconds: Int?
    private let lock = NSLock()
    init() {}
    func set(_ p: Process) { lock.lock(); defer { lock.unlock() }; process = p }

    func cancel() {
        lock.lock()
        cancelled = true
        let p = process
        lock.unlock()

        guard let p, p.isRunning else { return }

        p.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            if p.isRunning { p.interrupt() }
        }
    }

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func timeOut(command: String, seconds: Int) {
        lock.lock()
        timeoutCommand = command
        timeoutSeconds = seconds
        let p = process
        lock.unlock()

        guard let p, p.isRunning else { return }
        p.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            if p.isRunning { p.interrupt() }
        }
    }

    var timeoutError: BrewError? {
        lock.lock(); defer { lock.unlock() }
        guard let timeoutCommand, let timeoutSeconds else { return nil }
        return .timedOut(command: timeoutCommand, seconds: timeoutSeconds)
    }
}

private final class SafeBuffer: @unchecked Sendable {
    private let lock = NSLock(); private var data = Data()
    init() {}
    func append(_ c: Data) { lock.lock(); defer { lock.unlock() }; data.append(c) }
    var allDataString: String { lock.lock(); defer { lock.unlock() }; return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    var tailString: String { lock.lock(); defer { lock.unlock() }; return String(String(data: data, encoding: .utf8)?.suffix(2000) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
}

private final class StreamContext: @unchecked Sendable {
    private var cancelled = false
    private var finished = false
    private var lastOutputAt = Date()
    private var timeoutCommand: String?
    private var timeoutSeconds: Int?
    private let lock = NSLock()
    init() {}
    func markCancelled() { lock.lock(); defer { lock.unlock() }; cancelled = true }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func markOutput() { lock.lock(); defer { lock.unlock() }; lastOutputAt = Date() }
    func markFinished() { lock.lock(); defer { lock.unlock() }; finished = true }
    func shouldTimeOut(after seconds: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, !finished, timeoutCommand == nil else { return false }
        return Date().timeIntervalSince(lastOutputAt) >= seconds
    }
    func markTimedOut(command: String, seconds: Int) {
        lock.lock()
        if timeoutCommand == nil {
            timeoutCommand = command
            timeoutSeconds = seconds
        }
        lock.unlock()
    }
    var timeoutError: BrewError? {
        lock.lock(); defer { lock.unlock() }
        guard let timeoutCommand, let timeoutSeconds else { return nil }
        return .timedOut(command: timeoutCommand, seconds: timeoutSeconds)
    }
}

private final class LineBuffer: @unchecked Sendable {
    private var pending = ""; private let lock = NSLock()
    init() {}
    func append(_ c: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard let s = String(data: c, encoding: .utf8) else { return [] }
        pending += s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines = [String]()
        while let range = pending.range(of: "\n") { lines.append(String(pending[..<range.lowerBound]) + "\n"); pending.removeSubrange(..<range.upperBound) }
        return lines
    }
    func flush() -> String? { lock.lock(); defer { lock.unlock() }; if pending.isEmpty { return nil }; let r = pending; pending = ""; return r.hasSuffix("\n") ? r : (r + "\n") }
}

// MARK: - 4. SERVICES

enum NetworkMode: Sendable {
    case direct
    case proxyInjected([String: String])
}

struct ShellService {

    static func runWithMode(executable: String, args: [String], mode: NetworkMode, isCurl: Bool = false) async throws -> String {
        var envOverrides: [String: String] = [:]

        if isCurl {
            // 使用临时目录代替 /dev/null，避免产生目录写入报错，并使用 UUID 隔离并发调用防止互相踩踏。
            let tempHomeDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("cellar-curl-home")
                .appendingPathComponent(UUID().uuidString)
            do {
                try FileManager.default.createDirectory(at: tempHomeDir, withIntermediateDirectories: true, attributes: nil)
                // 写入空 .curlrc，防止某些版本 curl 去层层往上找默认配置文件而产生诡异 Fallback
                let curlrcPath = tempHomeDir.appendingPathComponent(".curlrc")
                if !FileManager.default.fileExists(atPath: curlrcPath.path) {
                    try "".write(to: curlrcPath, atomically: true, encoding: .utf8)
                }
                envOverrides["HOME"] = tempHomeDir.path
                envOverrides["CURL_HOME"] = tempHomeDir.path
            } catch {
                // 如果极其罕见地创建失败，继续执行，不阻断诊断
            }
        }

        switch mode {
        case .direct:
            // 传空字符串代表在 merge 时物理删除该环境变量
            // ✅ 追加 no_proxy 和 NO_PROXY，彻底封死系统代理规则的任何隐式渗透
            let proxyKeys = [
                "http_proxy", "https_proxy", "all_proxy",
                "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
                "no_proxy", "NO_PROXY"
            ]
            for key in proxyKeys { envOverrides[key] = "" }
        case .proxyInjected(let proxyEnv):
            for (k, v) in proxyEnv { envOverrides[k] = v }
        }

        return try await runSynchronous(executable: executable, args: args, environment: envOverrides)
    }

    static func runSynchronous(executable: String, args: [String], environment: [String: String]? = nil, timeoutSeconds: TimeInterval? = nil, commandDisplay: String? = nil) async throws -> String {
        let container = ProcessContainer()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let p = Process(); container.set(p)
                p.executableURL = URL(fileURLWithPath: executable); p.arguments = args

                var env = ProcessInfo.processInfo.environment
                env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
                env["HOMEBREW_NO_ENV_HINTS"] = "1"
                env["HOMEBREW_NO_COLOR"] = "1"

                if let overrides = environment {
                    for (k, v) in overrides {
                        if v.isEmpty {
                            env.removeValue(forKey: k)
                        } else {
                            env[k] = v
                        }
                    }
                }
                p.environment = env

                let out = Pipe(); let err = Pipe(); p.standardOutput = out; p.standardError = err
                let outBuffer = SafeBuffer(); let errBuffer = SafeBuffer()
                let state = ExecutionState()
                let timeoutLabel = commandDisplay ?? ([executable] + args).joined(separator: " ")
                let timeoutItem = timeoutSeconds.map { seconds -> DispatchWorkItem in
                    let item = DispatchWorkItem {
                        container.timeOut(command: timeoutLabel, seconds: Int(seconds.rounded()))
                    }
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: item)
                    return item
                }

                out.fileHandleForReading.readabilityHandler = { h in
                    if state.checkFinalized() { return }
                    let d = h.availableData; guard !d.isEmpty else { return }
                    if state.checkFinalized() { return }
                    outBuffer.append(d)
                }
                err.fileHandleForReading.readabilityHandler = { h in
                    if state.checkFinalized() { return }
                    let d = h.availableData; guard !d.isEmpty else { return }
                    if state.checkFinalized() { return }
                    errBuffer.append(d)
                }

                p.terminationHandler = { _ in
                    timeoutItem?.cancel()
                    state.markFinalized()
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil

                    if let t = try? out.fileHandleForReading.readToEnd(), !t.isEmpty { outBuffer.append(t) }
                    if let t = try? err.fileHandleForReading.readToEnd(), !t.isEmpty { errBuffer.append(t) }

                    try? out.fileHandleForReading.close(); try? err.fileHandleForReading.close()

                    if let timeoutError = container.timeoutError {
                        state.resumeOnce(continuation: continuation, result: .failure(timeoutError))
                    } else if container.isCancelled {
                        state.resumeOnce(continuation: continuation, result: .failure(BrewError.cancelled))
                    } else if p.terminationStatus != 0 {
                        state.resumeOnce(continuation: continuation, result: .failure(BrewError.executionFailed(code: Int(p.terminationStatus), message: errBuffer.tailString)))
                    } else {
                        state.resumeOnce(continuation: continuation, result: .success(outBuffer.allDataString))
                    }
                }
                do { try p.run() } catch { timeoutItem?.cancel(); state.resumeOnce(continuation: continuation, result: .failure(error)) }
            }
        }, onCancel: { container.cancel() })
    }

    static func stream(executable: String, args: [String], environment: [String: String]? = nil, idleTimeoutSeconds: TimeInterval? = nil, commandDisplay: String? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let p = Process(); let pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: executable); p.arguments = args

            var env = ProcessInfo.processInfo.environment
            env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
            env["HOMEBREW_NO_ENV_HINTS"] = "1"
            env["HOMEBREW_NO_COLOR"] = "1"

            if let overrides = environment {
                for (k, v) in overrides {
                    if v.isEmpty {
                        env.removeValue(forKey: k)
                    } else {
                        env[k] = v
                    }
                }
            }
            p.environment = env

            p.standardOutput = pipe; p.standardError = pipe

            let errBuffer = SafeBuffer(); let lineBuffer = LineBuffer(); let context = StreamContext()
            let timeoutLabel = commandDisplay ?? ([executable] + args).joined(separator: " ")
            let timeoutSource: DispatchSourceTimer? = idleTimeoutSeconds.map { seconds in
                let source = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
                source.schedule(deadline: .now() + seconds, repeating: .seconds(5))
                source.setEventHandler {
                    guard context.shouldTimeOut(after: seconds) else { return }
                    context.markTimedOut(command: timeoutLabel, seconds: Int(seconds.rounded()))
                    if p.isRunning {
                        p.terminate()
                        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                            if p.isRunning { p.interrupt() }
                        }
                    }
                }
                source.resume()
                return source
            }

            continuation.onTermination = { @Sendable reason in
                timeoutSource?.cancel()
                if case .cancelled = reason {
                    context.markCancelled()
                    if p.isRunning {
                        p.terminate()
                        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                            if p.isRunning { p.interrupt() }
                        }
                    }
                }
            }

            pipe.fileHandleForReading.readabilityHandler = { h in
                let data = h.availableData; guard !data.isEmpty else { return }
                context.markOutput()
                errBuffer.append(data)
                for line in lineBuffer.append(data) { continuation.yield(line) }
            }

            p.terminationHandler = { _ in
                timeoutSource?.cancel()
                context.markFinished()
                pipe.fileHandleForReading.readabilityHandler = nil

                let tail = pipe.fileHandleForReading.availableData
                if !tail.isEmpty {
                    context.markOutput()
                    errBuffer.append(tail)
                    for l in lineBuffer.append(tail) { continuation.yield(l) }
                }

                if let r = lineBuffer.flush() { continuation.yield(r) }
                try? pipe.fileHandleForReading.close()

                if let timeoutError = context.timeoutError {
                    continuation.finish(throwing: timeoutError)
                } else if context.isCancelled {
                    continuation.finish(throwing: BrewError.cancelled)
                } else if p.terminationStatus != 0 {
                    continuation.finish(throwing: BrewError.executionFailed(code: Int(p.terminationStatus), message: errBuffer.tailString))
                } else {
                    continuation.finish()
                }
            }
            do { try p.run() } catch { timeoutSource?.cancel(); continuation.finish(throwing: error) }
        }
    }
}

actor BrewService {
    static let shared = BrewService()
    private init() {}
    private var proxyEnvironment: [String: String] = [:]
    func configureProxy(env: [String: String]) { self.proxyEnvironment = env }

    private func getBrewPath() throws -> String {
        let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew", "/usr/bin/brew"]
        if let f = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) { return f }
        throw BrewError.brewNotFound
    }
    private func runSync(_ cmd: BrewCommand) async throws -> String {
        let b = try getBrewPath()
        return try await ShellService.runSynchronous(
            executable: b,
            args: cmd.args,
            environment: proxyEnvironment,
            timeoutSeconds: syncTimeout(for: cmd),
            commandDisplay: cmd.displayCommand
        )
    }
    private func safeSearchRun(_ cmd: BrewCommand) async throws -> String {
        do { return try await runSync(cmd) } catch let BrewError.executionFailed(code, _) where code == 1 { return "" } catch { throw error }
    }
    private func runStream(_ cmd: BrewCommand) async -> AsyncThrowingStream<String, Error> {
        guard let b = try? getBrewPath() else { return .init { $0.finish(throwing: BrewError.brewNotFound) } }
        return ShellService.stream(
            executable: b,
            args: cmd.args,
            environment: proxyEnvironment,
            idleTimeoutSeconds: streamIdleTimeout(for: cmd),
            commandDisplay: cmd.displayCommand
        )
    }

    private nonisolated func syncTimeout(for cmd: BrewCommand) -> TimeInterval? {
        switch cmd {
        case .listPinned:
            return 30
        case .checkOutdated, .info(_):
            return 90
        case .listInstalledJSON:
            return 120
        case .searchFormulae(_), .searchCasks(_):
            return 45
        case .bundleDump(_):
            return 60
        default:
            return 120
        }
    }

    private nonisolated func streamIdleTimeout(for cmd: BrewCommand) -> TimeInterval? {
        switch cmd {
        case .upgrade(_), .install(_, _):
            return 180
        case .update:
            return 120
        case .uninstall(_, _), .cleanup:
            return 120
        case .pin(_), .unpin(_):
            return 60
        default:
            return nil
        }
    }

    func getPinnedList() async throws -> Set<String> {
        let out = try await runSync(.listPinned)
        return Set(out.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }
    func checkOutdated() async throws -> [BrewPackage] {
        let out = try await runSync(.checkOutdated)
        return try await Task.detached(priority: .utility) { try JSONParser.parseOutdated(out) }.value
    }
    func getInfo(name: String) async throws -> BrewInfo {
        let out = try await runSync(.info(name))
        let infos = try await Task.detached(priority: .utility) { try JSONParser.parseInfo(out) }.value
        guard let info = infos.first else { throw BrewError.parseError("Empty info info") }
        return info
    }
    func getInfoTyped(name: String) async throws -> (PackageType, BrewInfo) {
        let out = try await runSync(.info(name))
        return try await Task.detached(priority: .utility) { try JSONParser.parseInfoTyped(out) }.value
    }
    func fetchInstalledList() async throws -> [BrewPackage] {
        async let leavesTask = runSync(.listLeaves)
        async let infoTask = runSync(.listInstalledJSON)
        let (leavesOut, infoOut) = try await (leavesTask, infoTask)
        return try await Task.detached(priority: .utility) {
            let leavesSet = Set(leavesOut.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) })
            return try JSONParser.parseInstalled(infoOut, leaves: leavesSet)
        }.value
    }
    func search(query: String) async throws -> [BrewSearchItem] {
        async let formulaOut = safeSearchRun(.searchFormulae(query))
        async let caskOut = safeSearchRun(.searchCasks(query))
        let (fText, cText) = try await (formulaOut, caskOut)
        let tokenRegex = #"^[A-Za-z0-9@._+\-]+$"#
        let fItems = fText.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty && $0.range(of: tokenRegex, options: .regularExpression) != nil }.map { BrewSearchItem(name: $0, type: .formula) }
        let cItems = cText.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty && $0.range(of: tokenRegex, options: .regularExpression) != nil }.map { BrewSearchItem(name: $0, type: .cask) }
        var uniqueMap: [String: BrewSearchItem] = [:]
        for item in fItems { uniqueMap[item.name.lowercased()] = item }
        for item in cItems { uniqueMap[item.name.lowercased()] = item }
        return uniqueMap.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
    func install(_ name: String, isCask: Bool) async -> AsyncThrowingStream<String, Error> { await runStream(.install(name, isCask: isCask)) }
    func exportBrewfile(to url: URL) async throws { _ = try await runSync(.bundleDump(url.path)) }
    func updateTap() async -> AsyncThrowingStream<String, Error> { await runStream(.update) }
    func upgrade(args: [String]) async -> AsyncThrowingStream<String, Error> { await runStream(.upgrade(args)) }
    func uninstall(_ pkg: BrewPackage) async -> AsyncThrowingStream<String, Error> { await runStream(.uninstall(pkg.name, isCask: pkg.type == .cask)) }
    func pinAction(name: String, pin: Bool) async -> AsyncThrowingStream<String, Error> { await runStream(pin ? .pin(name) : .unpin(name)) }
    func cleanup() async -> AsyncThrowingStream<String, Error> { await runStream(.cleanup) }
}

// MARK: - 5. PARSERS

struct JSONParser {

    // 兼容 Cask 安装版本的多种形态
    private struct InstalledCaskValue: Decodable {
        let versions: [String]
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            // 形态 A: "installed": "4.6.2"
            if let singleString = try? container.decode(String.self) {
                self.versions = [singleString]
            }
            // 形态 B: "installed": [{"version":"4.6.2"}]
            else if let array = try? container.decode([InstalledEntry].self) {
                self.versions = array.map { $0.version }
            }
            else {
                self.versions = []
            }
        }
        struct InstalledEntry: Decodable { let version: String }
    }

    // --- BEGIN APPEND: JSONParser C3-R1-STRICT-R2 ---
    private struct CaskArtifact: Decodable {
        let app: [String]?
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicCodingKeys.self)
            self.app = try? container.decode([String].self, forKey: DynamicCodingKeys(stringValue: "app")!)
        }
        private struct DynamicCodingKeys: CodingKey {
            var stringValue: String; init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int?; init?(intValue: Int) { return nil }
        }
    }
    // --- END APPEND: JSONParser C3-R1-STRICT-R2 ---

    static func parseOutdated(_ text: String) throws -> [BrewPackage] {
        let cleanJSON = extractBalancedJSON(from: text) ?? text
        guard let data = cleanJSON.data(using: .utf8) else { throw BrewError.parseError("Encoding Error") }
        struct Root: Decodable { let formulae: [F]; let casks: [C] }
        struct F: Decodable { let name: String; let desc: String?; let current_version: String?; let installed_versions: [String]?; let pinned: Bool? }
        struct C: Decodable { let name: String; let desc: String?; let current_version: String?; let installed_versions: [String]? }
        do {
            let r = try JSONDecoder().decode(Root.self, from: data)
            let f = r.formulae.map { BrewPackage(name: $0.name, desc: $0.desc, installedVersions: $0.installed_versions ?? [], currentVersion: $0.current_version ?? "?", isPinned: $0.pinned ?? false, isLeaf: false, type: .formula, autoUpdates: false, installedSizeBytes: nil, appArtifactNames: []) }
            let c = r.casks.map { BrewPackage(name: $0.name, desc: $0.desc, installedVersions: $0.installed_versions ?? [], currentVersion: $0.current_version ?? "?", isPinned: false, isLeaf: true, type: .cask, autoUpdates: false, installedSizeBytes: nil, appArtifactNames: []) }
            return (f + c).sorted { $0.name < $1.name }
        } catch { if cleanJSON == "[]" { return [] }; throw error }
    }

    static func parseInstalled(
        _ text: String,
        leaves: Set<String>,
        appBundleVersionReader: ([String]) -> CaskAppBundleVersionReadResult = CaskAppBundleVersionReader.readVersion(appArtifactNames:)
    ) throws -> [BrewPackage] {
        let cleanJSON = extractBalancedJSON(from: text) ?? text
        guard let data = cleanJSON.data(using: .utf8) else { throw BrewError.parseError("Encoding Error") }
        struct Root: Decodable { let formulae: [FormulaInfo]; let casks: [CaskInfo] }
        struct FormulaInfo: Decodable { let name: String; let desc: String?; let versions: Versions?; let installed: [InstalledEntry]?; struct Versions: Decodable { let stable: String? }; struct InstalledEntry: Decodable { let version: String } }

        // --- BEGIN APPEND: CaskInfo C3-R1-STRICT-R2 ---
        struct CaskInfo: Decodable {
            let token: String; let name: [String]?; let desc: String?; let version: String?
            let installed: InstalledCaskValue?
            let bundle_short_version: String?; let bundle_version: String?
            let auto_updates: Bool?
            let artifacts: [CaskArtifact]?
        }
        // --- END APPEND: CaskInfo C3-R1-STRICT-R2 ---

        do {
            let r = try JSONDecoder().decode(Root.self, from: data)
            let f = r.formulae.map { info in BrewPackage(name: info.name, desc: info.desc, installedVersions: info.installed?.map { $0.version } ?? [], currentVersion: info.versions?.stable ?? "?", isPinned: false, isLeaf: leaves.contains(info.name), type: .formula, autoUpdates: false, installedSizeBytes: nil, appArtifactNames: []) }

            // --- BEGIN MAPPER: Cask C3-R1-STRICT-R2 ---
            let c = r.casks.compactMap { info -> BrewPackage? in
                let receiptVersions = info.installed?.versions.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? []
                var installedVers = receiptVersions
                if installedVers.isEmpty, let bsv = info.bundle_short_version, !bsv.isEmpty { installedVers = [bsv] }
                else if installedVers.isEmpty, let bv = info.bundle_version, !bv.isEmpty { installedVers = [bv] }

                let apps = info.artifacts?.compactMap { $0.app }.flatMap { $0 } ?? []
                let appReadResult = appBundleVersionReader(apps)
                let versionTruth = CaskVersionTruth.make(
                    homebrewReceiptVersion: receiptVersions.first,
                    appBundleReadResult: appReadResult,
                    repositoryVersion: info.version ?? "?"
                )
                guard !installedVers.isEmpty || versionTruth.appBundleVersion != nil else { return nil }

                return BrewPackage(
                    name: info.token,
                    desc: info.desc ?? (info.name?.first ?? info.token),
                    installedVersions: installedVers,
                    currentVersion: info.version ?? "?",
                    isPinned: false, isLeaf: true, type: .cask,
                    autoUpdates: info.auto_updates ?? false,
                    installedSizeBytes: nil,
                    appArtifactNames: apps,
                    caskVersionTruth: versionTruth
                )
            }
            // --- END MAPPER: Cask C3-R1-STRICT-R2 ---
            return (f + c).sorted { $0.name < $1.name }
        } catch { throw error }
    }

    static func parseInfo(_ text: String) throws -> [BrewInfo] {
        let cleanJSON = extractBalancedJSON(from: text) ?? text
        guard let data = cleanJSON.data(using: .utf8) else { throw BrewError.parseError("Encoding Error") }
        struct Root: Decodable { let formulae: [BrewInfo]; let casks: [BrewInfo] }
        let r = try JSONDecoder().decode(Root.self, from: data)
        return r.formulae + r.casks
    }

    static func parseInfoTyped(_ text: String) throws -> (PackageType, BrewInfo) {
        let cleanJSON = extractBalancedJSON(from: text) ?? text
        guard let data = cleanJSON.data(using: .utf8) else { throw BrewError.parseError("Encoding Error") }
        struct Root: Decodable { let formulae: [BrewInfo]; let casks: [BrewInfo] }
        let r = try JSONDecoder().decode(Root.self, from: data)
        if let f = r.formulae.first { return (.formula, f) }
        if let c = r.casks.first { return (.cask, c) }
        throw BrewError.parseError("Empty info")
    }

    static func extractBalancedJSON(from text: String) -> String? {
        let markers = ["{\"formulae\"", "{\"casks\"", "{\"formulae\":", "{\"casks\":"]
        let startIndex: String.Index
        if let m = markers.compactMap({ text.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) { startIndex = m.lowerBound }
        else if let fallback = text.firstIndex(of: "{") { startIndex = fallback }
        else if let sa = text.firstIndex(of: "["), let ea = text.lastIndex(of: "]") { return String(text[sa...ea]) }
        else { return nil }
        var count = 0; var inStr = false; var esc = false; var cur = startIndex
        while cur < text.endIndex {
            let c = text[cur]
            if inStr { if esc { esc = false } else if c == "\\" { esc = true } else if c == "\"" { inStr = false } }
            else { if c == "\"" { inStr = true } else if c == "{" { count += 1 } else if c == "}" { count -= 1; if count == 0 { return String(text[startIndex...cur]) } } }
            cur = text.index(after: cur)
        }
        return nil
    }
}
