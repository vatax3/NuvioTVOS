import Foundation

/// Finding the next episode in the release the viewer was already watching.
///
/// `bingeGroup` is the addon's own equality marker and the right answer when it is there. The
/// trouble is how often it is not: a debrid result is a file on somebody's cache, and most of the
/// addons serving them publish no `bingeGroup` at all. So the chain fell through to the ordinary
/// ranking and the next episode could arrive as a different release — different encode, different
/// audio track, different subtitle timing — in the middle of a season.
///
/// Upstream's answer in 1.1.0-beta.7 is the filename, and it is a good one because a release names
/// its episodes to a pattern: the file that follows `Show.S01E03.1080p.GROUP.mkv` is the same
/// string with `03` incremented. Rebuilding that name and looking for it is a much stronger signal
/// than any heuristic over resolution and codec, and it costs one string comparison.
///
/// Two rules keep it from guessing. The pattern has to **match the episode that was playing** —
/// otherwise some unrelated number in the name gets incremented — and a name with no recognisable
/// pattern produces **no match at all** rather than a best effort.
enum NextEpisodeSourceMatch {
    /// What was playing, as much of it as is worth remembering.
    struct Release: Equatable, Sendable {
        var bingeGroup: String?
        var filename: String?
        var season: Int?
        var episode: Int?

        var isEmpty: Bool {
            bingeGroup?.nilIfBlank == nil && filename?.nilIfBlank == nil
        }
    }

    /// How the match was reached, which is worth distinguishing in logs and in tests: one is the
    /// addon's own statement and the other is our inference from a name.
    enum Reason: Equatable {
        case bingeGroup
        case filename
    }

    /// The stream to play for `season`/`episode`, or nil to let the ordinary ranking decide.
    static func find(
        in streams: [Stream], release: Release, season: Int?, episode: Int?
    ) -> (stream: Stream, reason: Reason)? {
        if let group = release.bingeGroup?.nilIfBlank,
           let match = bingeGroupMatch(in: streams, group: group) {
            return (match, .bingeGroup)
        }
        if let match = filenameMatch(in: streams, release: release, season: season, episode: episode) {
            return (match, .filename)
        }
        return nil
    }

    /// Exact equality on the addon's marker. Matching on anything looser would be guessing at what
    /// "the same" means on the viewer's behalf.
    static func bingeGroupMatch(in streams: [Stream], group: String) -> Stream? {
        let target = group.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        return streams.first {
            $0.behaviorHints?.bingeGroup?.trimmingCharacters(in: .whitespaces) == target
        }
    }

    /// The candidate whose filename is the played one with its episode number advanced.
    static func filenameMatch(
        in streams: [Stream], release: Release, season: Int?, episode: Int?
    ) -> Stream? {
        guard let previous = release.filename?.nilIfBlank,
              let nextEpisode = episode,
              let expected = nextFilename(
                  from: previous,
                  currentSeason: release.season,
                  currentEpisode: release.episode,
                  nextSeason: season,
                  nextEpisode: nextEpisode
              )
        else { return nil }

        return streams.first { stream in
            guard let candidate = filename(of: stream) else { return false }
            return candidate.caseInsensitiveCompare(expected) == .orderedSame
        }
    }

    /// A stream's filename: the addon's hint, or the last path component of its URL.
    ///
    /// The fallback matters more than it looks. Most addons send no `filename` hint, but a debrid
    /// link almost always *ends* in the real one — which is both what makes the match above
    /// possible for those sources and what fills the player's File row, which had been empty for
    /// them.
    static func filename(of stream: Stream) -> String? {
        if let hint = stream.behaviorHints?.filename?.nilIfBlank { return hint }
        return stream.streamURL().flatMap(filenameFromURL)
    }

    /// The last path component, when it looks like a file rather than an endpoint.
    ///
    /// Requiring a dot is what keeps `…/stream/12345` from being read as a filename. It is also
    /// why a *switched* stream cannot inherit the launch stream's name: each one answers from its
    /// own URL.
    static func filenameFromURL(_ url: String) -> String? {
        let withoutQuery = url.split(separator: "?", maxSplits: 1).first.map(String.init) ?? url
        guard let last = withoutQuery.split(separator: "/").last.map(String.init),
              last.contains("."),
              let decoded = last.removingPercentEncoding ?? last.nilIfBlank
        else { return nil }
        return decoded.nilIfBlank
    }

    // MARK: Advancing the name

    /// `previous` with its episode number advanced to `nextEpisode`, or nil when no pattern in it
    /// describes the episode that was playing.
    ///
    /// Patterns are tried most specific first and the first one that matches wins, so an unrelated
    /// number — a year, a resolution, a release group's own digits — is never the one rewritten.
    static func nextFilename(
        from previous: String,
        currentSeason: Int?,
        currentEpisode: Int?,
        nextSeason: Int?,
        nextEpisode: Int
    ) -> String? {
        guard !previous.trimmingCharacters(in: .whitespaces).isEmpty,
              let currentEpisode
        else { return nil }

        for pattern in patterns {
            if let rewritten = pattern(
                previous, currentSeason, currentEpisode, nextSeason ?? currentSeason, nextEpisode
            ) {
                return rewritten
            }
        }
        return nil
    }

    private typealias Pattern = (String, Int?, Int, Int?, Int) -> String?

    private static let patterns: [Pattern] = [seasonEpisode, seasonXEpisode, episodeOnly]

    /// `S01E03`, `s1e3`, `S 01 E 03`. The season has to be known and has to match.
    private static func seasonEpisode(
        _ name: String, _ currentSeason: Int?, _ currentEpisode: Int,
        _ nextSeason: Int?, _ nextEpisode: Int
    ) -> String? {
        guard let currentSeason else { return nil }
        return rewrite(name, expression: #"([Ss])\s*(\d{1,3})\s*([Ee])\s*(\d{1,4})"#) { groups in
            guard Int(groups[2]) == currentSeason, Int(groups[4]) == currentEpisode else {
                return nil
            }
            // The original's own letter case and zero-padding are kept: a release names every one
            // of its files the same way, so a rebuilt name that differs in either matches nothing.
            return groups[1] + pad(nextSeason ?? currentSeason, like: groups[2])
                + groups[3] + pad(nextEpisode, like: groups[4])
        }
    }

    /// `1x03`, `01x03`.
    private static func seasonXEpisode(
        _ name: String, _ currentSeason: Int?, _ currentEpisode: Int,
        _ nextSeason: Int?, _ nextEpisode: Int
    ) -> String? {
        guard let currentSeason else { return nil }
        return rewrite(name, expression: #"(?<!\d)(\d{1,2})([xX])(\d{1,4})"#) { groups in
            guard Int(groups[1]) == currentSeason, Int(groups[3]) == currentEpisode else {
                return nil
            }
            return pad(nextSeason ?? currentSeason, like: groups[1])
                + groups[2] + pad(nextEpisode, like: groups[3])
        }
    }

    /// `E03`, `EP03`, `Ep 03`, `EP.03` — no season in the name at all, so a season change cannot
    /// be expressed and the rewrite is refused rather than producing the wrong file.
    private static func episodeOnly(
        _ name: String, _ currentSeason: Int?, _ currentEpisode: Int,
        _ nextSeason: Int?, _ nextEpisode: Int
    ) -> String? {
        guard currentSeason == nil || nextSeason == nil || currentSeason == nextSeason else {
            return nil
        }
        // The separator is captured rather than merely consumed — `Ep.03` has to come back as
        // `Ep.04` and not `Ep04`, because the name is compared for equality against real files.
        return rewrite(name, expression: #"(?<![A-Za-z0-9])([Ee][Pp]?)([\s.]?)(\d{1,4})"#) { groups in
            guard Int(groups[3]) == currentEpisode else { return nil }
            return groups[1] + groups[2] + pad(nextEpisode, like: groups[3])
        }
    }

    // MARK: Plumbing

    /// Replaces the first match of `expression` with whatever `replacement` makes of its groups,
    /// or nil when nothing matched or the replacement declined.
    private static func rewrite(
        _ name: String, expression: String, replacement: ([String]) -> String?
    ) -> String? {
        guard let regex = try? NSRegularExpression(pattern: expression) else { return nil }
        let full = NSRange(name.startIndex..., in: name)
        guard let match = regex.firstMatch(in: name, range: full) else { return nil }

        var groups: [String] = []
        for index in 0..<match.numberOfRanges {
            guard let range = Range(match.range(at: index), in: name) else {
                groups.append("")
                continue
            }
            groups.append(String(name[range]))
        }
        guard let replaced = replacement(groups),
              let matched = Range(match.range, in: name)
        else { return nil }

        return name.replacingCharacters(in: matched, with: replaced)
    }

    /// `number` zero-padded to the width `original` was written at, and never shorter — episode 10
    /// of a season written `E3` becomes `E10`, not `E0`.
    private static func pad(_ number: Int, like original: String) -> String {
        String(format: "%0\(original.count)d", number)
    }
}
