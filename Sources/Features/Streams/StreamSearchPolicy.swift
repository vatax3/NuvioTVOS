import Foundation

/// Where a source's section goes as the sources answer one by one — upstream's
/// `StreamAutoPlaySelector.orderAddonStreams`.
///
/// Addons in the order they are installed, then plugin sections in the order they answered.
/// Upstream also puts direct-debrid and native-server sources first; neither exists here.
enum StreamGroupOrdering {
    /// Replaces the section with the same name, or inserts it. An empty section is removed.
    static func merging(
        _ group: AddonStreams,
        into groups: [AddonStreams],
        installedOrder: [String],
        pluginOrder: [String]
    ) -> [AddonStreams] {
        var merged = groups.filter { $0.id != group.id }
        if !group.streams.isEmpty { merged.append(group) }
        return ordered(merged, installedOrder: installedOrder, pluginOrder: pluginOrder)
    }

    static func ordered(
        _ groups: [AddonStreams],
        installedOrder: [String],
        pluginOrder: [String]
    ) -> [AddonStreams] {
        var addonRank: [String: Int] = [:]
        for (index, name) in installedOrder.enumerated() where addonRank[name] == nil {
            addonRank[name] = index
        }
        let addons = groups
            .filter { addonRank[$0.addonName] != nil }
            .sorted { addonRank[$0.addonName]! < addonRank[$1.addonName]! }
        let plugins = groups
            .filter { addonRank[$0.addonName] == nil }
            .sorted {
                (pluginOrder.firstIndex(of: $0.addonName) ?? .max)
                    < (pluginOrder.firstIndex(of: $1.addonName) ?? .max)
            }
        return addons + plugins
    }
}

/// One filter chip per source asked — upstream's `SourceChipItem`.
struct SourceChip: Identifiable, Equatable {
    enum Status: Equatable {
        case loading
        case success
        case error
    }

    let name: String
    var status: Status
    var id: String { name }
}

/// Upstream's chip lifecycle, from `StreamScreenViewModel`.
///
/// Every source starts loading. A source turns to success once it has published streams; one
/// that answered with nothing stays loading until the whole search is over, and is then marked
/// in error — the same as one that failed — and removed shortly after.
enum SourceChips {
    /// How long an error chip stays before it is removed (`scheduleErrorChipRemoval`).
    static let errorDismissDelay: Duration = .milliseconds(1600)

    static func fetchStart(names: [String]) -> [SourceChip] {
        var seen = Set<String>()
        return names
            .filter { seen.insert($0).inserted }
            .map { SourceChip(name: $0, status: .loading) }
    }

    /// `mergeSourceChipStatuses`.
    static func marking(succeeded names: [String], in chips: [SourceChip]) -> [SourceChip] {
        guard !names.isEmpty else { return chips }
        let succeeded = Set(names)
        var updated = chips.map { chip in
            var chip = chip
            if succeeded.contains(chip.name) { chip.status = .success }
            return chip
        }
        var known = Set(updated.map(\.name))
        for name in names where known.insert(name).inserted {
            updated.append(SourceChip(name: name, status: .success))
        }
        return updated
    }

    /// `markRemainingSourceChipsAsError`.
    static func markingRemainingAsError(_ chips: [SourceChip]) -> [SourceChip] {
        chips.map { chip in
            var chip = chip
            if chip.status == .loading { chip.status = .error }
            return chip
        }
    }

    static func removingErrors(_ chips: [SourceChip]) -> [SourceChip] {
        chips.filter { $0.status != .error }
    }

    /// The row's order (`orderedAddonNames`): sections on screen first, in list order, then every
    /// chip not yet among them.
    static func displayOrder(available: [String], chips: [SourceChip]) -> [String] {
        var names = available
        for chip in chips where !names.contains(chip.name) {
            names.append(chip.name)
        }
        return names
    }
}

/// When auto-play picks — upstream's direct auto-play flow in `StreamScreenViewModel.loadStreams`.
///
/// The wait (`stream_auto_play_timeout_seconds`) is counted from the start of the search:
/// - **0, instant**: each answer is offered to the selector; the first one with nothing suitable
///   ends auto-play.
/// - **1–30 s, bounded**: before the wait is over only an exact release match (binge group) is
///   taken. Once it is, the selector picks from what has arrived; nothing suitable ends auto-play.
/// - **Unlimited**: each answer is offered to the selector, and nothing suitable keeps waiting —
///   until every source has answered, or the 60-second hard limit.
///
/// Every source having answered always gives the selector a last look, then ends auto-play. A
/// debrid cache check still out holds the "nothing suitable" verdict until its answer arrives.
enum StreamAutoPlayPolicy {
    static let unlimitedTimeout = Int.max
    static let timeoutValues = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 15, 20, 25, 30, unlimitedTimeout]
    /// `DIRECT_AUTOPLAY_HARD_TIMEOUT_MS`, counted after the bounded wait.
    static let hardTimeout: Duration = .seconds(60)

    /// `applyLegacyTimeoutSentinelMigration`: a value the slider cannot show moves to the
    /// nearest one it can; 11 was the old unlimited sentinel.
    static func normalizedTimeout(_ stored: Int) -> Int {
        if stored == 11 { return unlimitedTimeout }
        if timeoutValues.contains(stored) { return stored }
        return timeoutValues
            .filter { $0 != unlimitedTimeout }
            .min { abs($0 - stored) < abs($1 - stored) } ?? 10
    }

    static func isBounded(_ timeout: Int) -> Bool {
        timeout > 0 && timeout != unlimitedTimeout
    }

    /// `StreamAutoPlayPolicy.isRegexSelectionConfigured`: a blank pattern, one with no letter or
    /// digit, or one that does not compile turns regex auto-play off.
    static func isRegexSelectionConfigured(_ pattern: String) -> Bool {
        let pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty, pattern.contains(where: { $0.isLetter || $0.isNumber }) else { return false }
        return (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)) != nil
    }

    enum Moment: Equatable {
        /// A source answered, or a cache check came back.
        case arrival
        /// The bounded wait ran out.
        case windowElapsed
        /// Every source has answered.
        case allAnswered
        case hardTimeout
    }

    struct Step: Equatable {
        /// Offer what has arrived to the full selector.
        var select = false
        /// End auto-play if the selector finds nothing (or at once, when `select` is false).
        var giveUpIfNoMatch = false

        static let wait = Step()
    }

    static func step(
        at moment: Moment,
        timeout: Int,
        windowElapsed: Bool,
        hasStreams: Bool,
        cacheCheckPending: Bool,
        directFlow: Bool
    ) -> Step {
        let unlimited = timeout == unlimitedTimeout
        switch moment {
        case .arrival, .windowElapsed:
            guard windowElapsed, hasStreams else { return .wait }
            return Step(select: true, giveUpIfNoMatch: directFlow && !unlimited && !cacheCheckPending)
        case .allAnswered:
            return Step(select: hasStreams, giveUpIfNoMatch: directFlow)
        case .hardTimeout:
            return Step(select: false, giveUpIfNoMatch: directFlow)
        }
    }
}
