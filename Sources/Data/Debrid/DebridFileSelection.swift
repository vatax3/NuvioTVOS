import Foundation

/// Which file of a debrid torrent to play — upstream's `selectDebridFile`
/// (`core/debrid/DebridFileSelection.kt`, 1.2.0-beta.4), ported line for line.
///
/// The order is upstream's, and it matters for season packs: the addon's filename first, then the
/// requested episode's `SxxEyy` / `NxM` in a file name, and when either hint was given and nothing
/// answers it, no file at all — the largest file of a season pack is the wrong episode, and an
/// error the fallback can act on is better than playing it. Only a hint-less request falls back to
/// the addon's file index and then the largest file.
enum DebridFileSelection {
    static let videoExtensions: Set<String> = ["mp4", "mkv", "webm", "avi", "mov", "m4v", "ts", "m2ts", "wmv", "flv"]

    /// - Parameters:
    ///   - paths: each file's path inside the torrent, in the provider's order.
    ///   - isPlayable: the provider's own test, by index (Premiumize also needs a link).
    ///   - fileIndex: the addon's `fileIdx`, an index into `paths`.
    ///   - filenames: the addon's filename hints, most specific first.
    /// - Returns: the index into `paths`, or nil when nothing playable answers the hints.
    static func select(
        paths: [String],
        sizes: [Int64],
        isPlayable: (Int) -> Bool,
        fileIndex: Int?,
        filenames: [String?],
        season: Int?,
        episode: Int?
    ) -> Int? {
        let playable = paths.indices.filter(isPlayable)
        guard !playable.isEmpty else { return nil }

        var names: [String] = []
        for name in filenames.compactMap({ $0.map(normalizedPath) }) where !name.isEmpty && !names.contains(name) {
            names.append(name)
        }
        for name in names {
            let matches = matchingFiles(playable, paths: paths, name: name)
            if !matches.isEmpty { return matches.count == 1 ? matches[0] : nil }
        }

        let pattern = episodePattern(season: season, episode: episode)
        if let pattern {
            let matches = playable.filter { index in
                let basename = lastComponent(normalizedPath(paths[index]))
                return pattern.firstMatch(in: basename, range: NSRange(basename.startIndex..., in: basename)) != nil
            }
            if !matches.isEmpty { return matches.count == 1 ? matches[0] : nil }
        }

        if !names.isEmpty || pattern != nil { return nil }

        if let fileIndex {
            return paths.indices.contains(fileIndex) && isPlayable(fileIndex) ? fileIndex : nil
        }

        func size(_ index: Int) -> Int64 { sizes.indices.contains(index) ? sizes[index] : 0 }
        return playable.max { size($0) < size($1) }
    }

    /// `hasDebridVideoExtension`.
    static func hasVideoExtension(_ path: String) -> Bool {
        videoExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    private static func matchingFiles(_ files: [Int], paths: [String], name: String) -> [Int] {
        // The plain pass, then both sides with " & " read as " and ".
        for normalizesAmpersand in [false, true] {
            let transform: (String) -> String = normalizesAmpersand ? normalizeAmpersandConjunction : { $0 }
            let candidate = transform(name)
            for ignoreCase in [false, true] {
                let matches = files.filter { index in
                    let filePath = transform(normalizedPath(paths[index]))
                    return equals(filePath, candidate, ignoreCase: ignoreCase)
                        || (candidate.contains("/") && hasSuffix(filePath, "/" + candidate, ignoreCase: ignoreCase))
                }
                if !matches.isEmpty { return matches }
            }
            let basename = lastComponent(candidate)
            for ignoreCase in [false, true] {
                let matches = files.filter { index in
                    equals(transform(lastComponent(normalizedPath(paths[index]))), basename, ignoreCase: ignoreCase)
                }
                if !matches.isEmpty { return matches }
            }
        }
        return []
    }

    private static func normalizedPath(_ path: String) -> String {
        var path = path.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\", with: "/")
        if path.hasPrefix("/") { path.removeFirst() }
        return path
    }

    private static func normalizeAmpersandConjunction(_ text: String) -> String {
        text.replacingOccurrences(of: " & ", with: " and ")
    }

    private static func lastComponent(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? path
    }

    private static func equals(_ lhs: String, _ rhs: String, ignoreCase: Bool) -> Bool {
        ignoreCase ? lhs.caseInsensitiveCompare(rhs) == .orderedSame : lhs == rhs
    }

    private static func hasSuffix(_ text: String, _ suffix: String, ignoreCase: Bool) -> Bool {
        ignoreCase ? text.lowercased().hasSuffix(suffix.lowercased()) : text.hasSuffix(suffix)
    }

    private static func episodePattern(season: Int?, episode: Int?) -> NSRegularExpression? {
        guard let season, let episode else { return nil }
        return try? NSRegularExpression(
            pattern: "(?<![a-z0-9])(?:s0*\(season)e0*\(episode)|0*\(season)x0*\(episode))(?![0-9])",
            options: .caseInsensitive
        )
    }
}
