import Foundation

struct LibrarySummary: Codable, Hashable, Sendable {
    let repoDiffCount: Int
    let autoUpdatesCount: Int
    let sizeUnknownCount: Int
    let leafCount: Int

    var hasAttentionItems: Bool {
        repoDiffCount > 0 || autoUpdatesCount > 0 || sizeUnknownCount > 0 || leafCount > 0
    }

    var attentionCount: Int {
        repoDiffCount + autoUpdatesCount + sizeUnknownCount + leafCount
    }

    var firstAttentionFilter: PackageStateFilterKey? {
        if repoDiffCount > 0 { return .repoDiff }
        if autoUpdatesCount > 0 { return .autoUpdates }
        if sizeUnknownCount > 0 { return .sizeUnknown }
        if leafCount > 0 { return .leaf }
        return nil
    }

    static func make(from packages: [BrewPackage]) -> LibrarySummary {
        LibrarySummary(
            repoDiffCount: PackageStateDescriptor.count(.repoDiff, in: packages, isLibrary: true),
            autoUpdatesCount: PackageStateDescriptor.count(.autoUpdates, in: packages, isLibrary: true),
            sizeUnknownCount: PackageStateDescriptor.count(.sizeUnknown, in: packages, isLibrary: true),
            leafCount: PackageStateDescriptor.count(.leaf, in: packages, isLibrary: true)
        )
    }
}
