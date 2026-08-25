import Foundation

enum PackageSizeEstimateContext: String, Codable, Sendable {
    case installedList
    case upgradeCandidate
}

enum PackageSizeEstimate: Codable, Hashable, Sendable {
    case knownInstalledSize(Int64)
    case knownDownloadSize(Int64)
    case knownInstalledReferenceSize(Int64)
    case unknown(reason: String)

    static func estimate(for package: BrewPackage, context: PackageSizeEstimateContext) -> PackageSizeEstimate {
        switch context {
        case .installedList:
            if let installedSizeBytes = package.installedSizeBytes {
                return .knownInstalledSize(installedSizeBytes)
            }
            return .unknown(reason: "尚未能从本机安装路径或 Homebrew 元数据稳定计算大小。")
        case .upgradeCandidate:
            if let installedSizeBytes = package.installedSizeBytes {
                return .knownInstalledReferenceSize(installedSizeBytes)
            }
            if package.type == .cask && package.autoUpdates {
                return .unknown(reason: "未能读取当前 App bundle；Caskroom receipt 目录不会作为当前 App 体量，该值不是 Homebrew outdated 下载大小。")
            }
            return .unknown(reason: "Homebrew outdated 元数据未提供下载大小，本机安装大小尚未完成探测。")
        }
    }

    var knownBytes: Int64? {
        switch self {
        case .knownInstalledSize(let bytes), .knownDownloadSize(let bytes), .knownInstalledReferenceSize(let bytes):
            return bytes
        case .unknown:
            return nil
        }
    }

    var unknownReason: String? {
        if case .unknown(let reason) = self {
            return reason
        }
        return nil
    }

    var statusText: String {
        switch self {
        case .knownInstalledSize:
            return "已知安装大小"
        case .knownDownloadSize:
            return "已知下载大小"
        case .knownInstalledReferenceSize:
            return "当前体量参考"
        case .unknown:
            return "大小未知"
        }
    }

    func displayText(using formatter: ByteCountFormatter) -> String {
        switch self {
        case .knownInstalledSize(let bytes), .knownDownloadSize(let bytes):
            return formatter.string(fromByteCount: bytes)
        case .knownInstalledReferenceSize(let bytes):
            return "当前 \(formatter.string(fromByteCount: bytes))"
        case .unknown:
            return "未知"
        }
    }

    func confirmationText(using formatter: ByteCountFormatter) -> String {
        switch self {
        case .knownInstalledSize(let bytes):
            return "安装大小 \(formatter.string(fromByteCount: bytes))"
        case .knownDownloadSize(let bytes):
            return "下载大小 \(formatter.string(fromByteCount: bytes))"
        case .knownInstalledReferenceSize(let bytes):
            return "当前体量 \(formatter.string(fromByteCount: bytes))（仅作参考，不代表下载量）"
        case .unknown(let reason):
            return "大小未知：\(reason)"
        }
    }

    func confirmationShortText(using formatter: ByteCountFormatter) -> String {
        switch self {
        case .knownInstalledSize(let bytes), .knownInstalledReferenceSize(let bytes):
            return "当前包 \(formatter.string(fromByteCount: bytes))"
        case .knownDownloadSize(let bytes):
            return "下载 \(formatter.string(fromByteCount: bytes))"
        case .unknown:
            return "下载未知"
        }
    }

    var helpText: String {
        switch self {
        case .knownInstalledSize:
            return "这是当前本机安装路径测得的大小，不等同于升级下载量。"
        case .knownDownloadSize:
            return "这是 Homebrew 元数据提供的下载大小。"
        case .knownInstalledReferenceSize:
            return "这是当前 App 或当前已安装旧包的本机体量，仅用于判断升级影响范围；不代表下载量、同步后大小、升级后大小或耗时承诺。"
        case .unknown(let reason):
            return "未知：\(reason)"
        }
    }
}

struct PackageSizeUnknownReasonSummary: Equatable, Sendable {
    let reason: String
    let count: Int
}

struct PackageSizeEstimateSummary: Equatable, Sendable {
    let knownBytes: Int64
    let knownCount: Int
    let knownInstalledBytes: Int64
    let knownInstalledCount: Int
    let knownDownloadBytes: Int64
    let knownDownloadCount: Int
    let knownInstalledReferenceBytes: Int64
    let knownInstalledReferenceCount: Int
    let unknownReasons: [PackageSizeUnknownReasonSummary]

    init(estimates: [PackageSizeEstimate]) {
        var knownBytes: Int64 = 0
        var knownCount = 0
        var knownInstalledBytes: Int64 = 0
        var knownInstalledCount = 0
        var knownDownloadBytes: Int64 = 0
        var knownDownloadCount = 0
        var knownInstalledReferenceBytes: Int64 = 0
        var knownInstalledReferenceCount = 0
        var reasonCounts: [String: Int] = [:]

        for estimate in estimates {
            switch estimate {
            case .knownInstalledSize(let bytes):
                knownBytes += bytes
                knownCount += 1
                knownInstalledBytes += bytes
                knownInstalledCount += 1
            case .knownDownloadSize(let bytes):
                knownBytes += bytes
                knownCount += 1
                knownDownloadBytes += bytes
                knownDownloadCount += 1
            case .knownInstalledReferenceSize(let bytes):
                knownBytes += bytes
                knownCount += 1
                knownInstalledReferenceBytes += bytes
                knownInstalledReferenceCount += 1
            case .unknown(let reason):
                reasonCounts[reason, default: 0] += 1
            }
        }

        self.knownBytes = knownBytes
        self.knownCount = knownCount
        self.knownInstalledBytes = knownInstalledBytes
        self.knownInstalledCount = knownInstalledCount
        self.knownDownloadBytes = knownDownloadBytes
        self.knownDownloadCount = knownDownloadCount
        self.knownInstalledReferenceBytes = knownInstalledReferenceBytes
        self.knownInstalledReferenceCount = knownInstalledReferenceCount
        self.unknownReasons = reasonCounts
            .map { PackageSizeUnknownReasonSummary(reason: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count == rhs.count {
                    return lhs.reason < rhs.reason
                }
                return lhs.count > rhs.count
            }
    }

    var unknownCount: Int {
        unknownReasons.reduce(0) { $0 + $1.count }
    }

    func knownSummaryText(using formatter: ByteCountFormatter) -> String {
        guard knownCount > 0 else {
            return "暂无已知大小"
        }
        return "\(knownCount) 个包，合计 \(formatter.string(fromByteCount: knownBytes))"
    }

    func downloadSummaryText(using formatter: ByteCountFormatter) -> String {
        guard knownDownloadCount > 0 else {
            return "暂无已知下载大小"
        }
        return "\(knownDownloadCount) 个包，下载大小合计 \(formatter.string(fromByteCount: knownDownloadBytes))"
    }

    func installedReferenceSummaryText(using formatter: ByteCountFormatter) -> String {
        guard knownInstalledReferenceCount > 0 else {
            return "暂无当前/旧包参考体量"
        }
        return "\(knownInstalledReferenceCount) 个包，当前/旧包参考体量合计 \(formatter.string(fromByteCount: knownInstalledReferenceBytes))"
    }

    var unknownSummaryText: String {
        guard unknownCount > 0 else {
            return "0 个"
        }
        let reasons = unknownReasons
            .map { "\($0.count) 个：\($0.reason)" }
            .joined(separator: "；")
        return "\(unknownCount) 个（\(reasons)）"
    }
}

enum PackageSizeReferenceMerger {
    nonisolated static func mergeInstalledSizes(
        into candidates: [BrewPackage],
        from installedPackages: [BrewPackage]
    ) -> [BrewPackage] {
        let sizesByID = Dictionary(
            uniqueKeysWithValues: installedPackages.compactMap { package -> (String, Int64)? in
                guard let installedSizeBytes = package.installedSizeBytes else { return nil }
                return (package.id, installedSizeBytes)
            }
        )

        return candidates.map { candidate in
            guard candidate.installedSizeBytes == nil, let installedSizeBytes = sizesByID[candidate.id] else {
                return candidate
            }
            var merged = candidate
            merged.installedSizeBytes = installedSizeBytes
            return merged
        }
    }

    nonisolated static func updateInstalledSize(
        packageID: String,
        installedSizeBytes: Int64?,
        in packages: inout [BrewPackage]
    ) {
        guard let index = packages.firstIndex(where: { $0.id == packageID }) else { return }
        packages[index].installedSizeBytes = installedSizeBytes
    }
}
