import Foundation

/// Port of upstream's `alignEpisodeRatings` (`EpisodeRatingsAlignment.kt`, 1.2.0-beta.2,
/// e2ecb1c5f): which external episode an addon's episode is, when the two number seasons
/// differently.
///
/// Anime is where it shows. An addon that splits Black Clover into 2 seasons and a provider that
/// splits it into 5 share episode numbers only by accident, so matching by number put one
/// episode's details on another, or none at all. Upstream's rule, kept as written:
/// - the same set of seasons on both sides keeps the numbers;
/// - otherwise, when both have aired the same number of regular episodes, they pair in order;
/// - otherwise, episodes pair by air date (a day either side allowed) where a day has as many
///   episodes on both sides;
/// - specials (season 0) keep their numbers.
///
/// Upstream aligns external episode *ratings* with it. Ours pairs every field TMDB fills — title,
/// overview, still, air date, runtime and rating — because they come from the same answer and the
/// same wrong match.
enum EpisodeAlignment {
    struct Number: Hashable, Sendable {
        var season: Int
        var episode: Int
    }

    struct Episode: Sendable {
        var number: Number
        /// `yyyy-MM-dd…`, as both addons and TMDB send it.
        var airDate: String?
    }

    /// Addon episode → external episode, or `nil` when the numbers stand as they are.
    static func pairs(
        addon: [Episode], external: [Episode], today: Date = Date(), calendar: Calendar = .current
    ) -> [Number: Number]? {
        let todayDay = day(of: today, calendar: calendar)
        func regular(_ episodes: [Episode]) -> [(number: Number, day: Int?)] {
            var seen = Set<Number>()
            return episodes
                .filter { $0.number.season > 0 && seen.insert($0.number).inserted }
                .sorted { ($0.number.season, $0.number.episode) < ($1.number.season, $1.number.episode) }
                .map { ($0.number, airDay($0.airDate)) }
        }
        let addonRegular = regular(addon)
        let externalRegular = regular(external)
        guard !addonRegular.isEmpty, !externalRegular.isEmpty else { return nil }
        guard Set(addonRegular.map(\.number.season)) != Set(externalRegular.map(\.number.season)) else { return nil }

        var result: [Number: Number] = [:]
        // Specials keep their numbers.
        for episode in external where episode.number.season == 0 { result[episode.number] = episode.number }

        let addonAired = addonRegular.filter { $0.day.map { $0 <= todayDay } ?? true }
        let externalAired = externalRegular.filter { $0.day.map { $0 <= todayDay } ?? true }
        if addonAired.count == externalAired.count {
            for (left, right) in zip(addonAired, externalAired) { result[left.number] = right.number }
            return result
        }

        let addonByDay = Dictionary(grouping: addonRegular.filter { $0.day != nil }, by: { $0.day! })
        let externalByDay = Dictionary(grouping: externalRegular.filter { $0.day != nil }, by: { $0.day! })
        guard !addonByDay.isEmpty, !externalByDay.isEmpty else { return nil }
        for (day, sameDayAddon) in addonByDay {
            guard let sameDayExternal = externalByDay[day] ?? externalByDay[day - 1] ?? externalByDay[day + 1],
                  sameDayExternal.count == sameDayAddon.count else { continue }
            for (left, right) in zip(sameDayAddon, sameDayExternal) { result[left.number] = right.number }
        }
        return result
    }

    /// Days since 1970 of a `yyyy-MM-dd` prefix, as `LocalDate.toEpochDay` counts them.
    static func airDay(_ value: String?) -> Int? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), value.count >= 10 else { return nil }
        let parts = value.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard let date = utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        return Int((date.timeIntervalSince1970 / 86_400).rounded(.down))
    }

    private static func day(of date: Date, calendar: Calendar) -> Int {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return airDay(String(format: "%04d-%02d-%02d", components.year ?? 1970, components.month ?? 1, components.day ?? 1)) ?? 0
    }
}
