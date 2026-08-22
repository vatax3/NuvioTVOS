import Foundation

/// Everything the filter/sort rules need, parsed once out of a stream's free-form text.
/// Addons encode all of this in the title/description, so this parser is what turns the
/// debrid preference matrix into behaviour rather than decoration.
struct ParsedStreamAttributes: Hashable, Sendable {
    var resolution: DebridStreamResolution = .unknown
    var quality: DebridStreamQuality = .unknown
    var visualTags: [DebridStreamVisualTag] = []
    var audioTags: [DebridStreamAudioTag] = []
    var audioChannels: [DebridStreamAudioChannel] = []
    var encode: DebridStreamEncode = .unknown
    var languages: [DebridStreamLanguage] = []
    var releaseGroup: String?
    var sizeBytes: Int64?
    var seeders: Int?

    var sizeGb: Double? {
        guard let sizeBytes else { return nil }
        return Double(sizeBytes) / 1_073_741_824
    }
}

enum StreamAttributeParser {
    static func parse(_ stream: Stream) -> ParsedStreamAttributes {
        let haystack = [
            stream.name, stream.title, stream.description, stream.behaviorHints?.filename
        ]
        .compactMap { $0 }
        .joined(separator: " ")

        let lower = haystack.lowercased()
        var attributes = ParsedStreamAttributes()

        attributes.resolution = resolution(in: lower)
        attributes.quality = quality(in: lower)
        attributes.visualTags = visualTags(in: lower)
        attributes.audioTags = audioTags(in: lower)
        attributes.audioChannels = audioChannels(in: lower)
        attributes.encode = encode(in: lower)
        attributes.languages = languages(in: lower)
        attributes.releaseGroup = releaseGroup(in: haystack)
        attributes.sizeBytes = stream.behaviorHints?.videoSize ?? size(in: haystack)
        attributes.seeders = QualityParser.seeders(haystack)

        return attributes
    }

    // MARK: Resolution

    private static func resolution(in text: String) -> DebridStreamResolution {
        let patterns: [(String, DebridStreamResolution)] = [
            ("2160p", .p2160), ("4k", .p2160), ("uhd", .p2160),
            ("1440p", .p1440), ("2k", .p1440),
            ("1080p", .p1080), ("fullhd", .p1080), ("full hd", .p1080), ("fhd", .p1080),
            ("720p", .p720), ("hd ", .p720),
            ("576p", .p576), ("480p", .p480), ("360p", .p360)
        ]
        for (needle, value) in patterns where text.contains(needle) { return value }
        return .unknown
    }

    // MARK: Quality

    private static func quality(in text: String) -> DebridStreamQuality {
        // Ordered longest-first so "bluray remux" is not swallowed by "bluray".
        let patterns: [(String, DebridStreamQuality)] = [
            ("remux", .blurayRemux),
            ("bluray", .bluray), ("blu-ray", .bluray), ("brrip", .bluray), ("bdrip", .bluray),
            ("web-dl", .webDl), ("webdl", .webDl), ("web dl", .webDl),
            ("webrip", .webrip), ("web-rip", .webrip),
            ("hc hd-rip", .hcHdRip), ("hdrip", .hdrip),
            ("dvdrip", .dvdrip), ("hdtv", .hdtv),
            ("cam", .cam), ("telesync", .ts), ("hdts", .ts), ("hdtc", .tc), ("screener", .scr), ("scr", .scr)
        ]
        for (needle, value) in patterns where text.contains(needle) { return value }
        if text.contains("web") { return .webDl }
        return .unknown
    }

    // MARK: Visual tags

    private static func visualTags(in text: String) -> [DebridStreamVisualTag] {
        var tags: [DebridStreamVisualTag] = []
        let hasDV = text.contains("dolby vision") || text.contains("dovi")
            || text.range(of: #"\bdv\b"#, options: .regularExpression) != nil
        let hasHDR10Plus = text.contains("hdr10+") || text.contains("hdr10plus")
        let hasHDR = text.contains("hdr")

        if hasDV && hasHDR { tags.append(.hdrDv) }
        else if hasDV { tags.append(.dvOnly) }
        else if hasHDR { tags.append(.hdrOnly) }

        if hasHDR10Plus { tags.append(.hdr10Plus) }
        if text.contains("hdr10") && !hasHDR10Plus { tags.append(.hdr10) }
        if hasDV { tags.append(.dv) }
        if hasHDR { tags.append(.hdr) }
        if text.contains("hlg") { tags.append(.hlg) }
        if text.contains("10bit") || text.contains("10-bit") { tags.append(.tenBit) }
        if text.contains("imax") { tags.append(.imax) }
        if text.contains("3d") { tags.append(.threeD) }
        if text.contains("h-ou") || text.contains("hou") { tags.append(.hou) }
        if text.contains("h-sbs") || text.contains("hsbs") { tags.append(.hsbs) }
        if text.contains("sdr") { tags.append(.sdr) }
        if text.contains(" ai ") || text.contains("ai-upscale") { tags.append(.ai) }

        return tags.isEmpty ? [.unknown] : tags
    }

    // MARK: Audio

    private static func audioTags(in text: String) -> [DebridStreamAudioTag] {
        var tags: [DebridStreamAudioTag] = []
        let checks: [(String, DebridStreamAudioTag)] = [
            ("atmos", .atmos), ("dts:x", .dtsX), ("dts-x", .dtsX),
            ("dts-hd ma", .dtsHdMa), ("dts-hd", .dtsHd), ("dts-es", .dtsEs),
            ("truehd", .truehd), ("dd+", .ddPlus), ("ddp", .ddPlus), ("eac3", .ddPlus),
            ("flac", .flac), ("opus", .opus), ("aac", .aac)
        ]
        for (needle, tag) in checks where text.contains(needle) && !tags.contains(tag) {
            tags.append(tag)
        }
        if text.contains("dts") && !tags.contains(where: { [.dtsX, .dtsHdMa, .dtsHd, .dtsEs].contains($0) }) {
            tags.append(.dts)
        }
        if (text.contains("ac3") || text.contains(" dd ")) && !tags.contains(.ddPlus) {
            tags.append(.dd)
        }
        return tags.isEmpty ? [.unknown] : tags
    }

    private static func audioChannels(in text: String) -> [DebridStreamAudioChannel] {
        var channels: [DebridStreamAudioChannel] = []
        if text.contains("7.1") { channels.append(.ch71) }
        if text.contains("6.1") { channels.append(.ch61) }
        if text.contains("5.1") { channels.append(.ch51) }
        if text.contains("2.0") || text.contains("stereo") { channels.append(.ch20) }
        return channels.isEmpty ? [.unknown] : channels
    }

    // MARK: Encode

    private static func encode(in text: String) -> DebridStreamEncode {
        if text.contains("av1") { return .av1 }
        if text.contains("hevc") || text.contains("x265") || text.contains("h265") || text.contains("h.265") {
            return .hevc
        }
        if text.contains("avc") || text.contains("x264") || text.contains("h264") || text.contains("h.264") {
            return .avc
        }
        if text.contains("xvid") { return .xvid }
        if text.contains("divx") { return .divx }
        return .unknown
    }

    // MARK: Languages

    private static func languages(in text: String) -> [DebridStreamLanguage] {
        var languages: [DebridStreamLanguage] = []
        let checks: [(String, DebridStreamLanguage)] = [
            ("multi", .multi), ("english", .en), ("hindi", .hi), ("italian", .it),
            ("spanish", .es), ("french", .fr), ("vff", .fr), ("vfq", .fr), ("truefrench", .fr),
            ("german", .de), ("portuguese", .pt), ("polish", .pl), ("czech", .cs),
            ("latino", .la), ("japanese", .ja), ("korean", .ko), ("chinese", .zh)
        ]
        for (needle, language) in checks where text.contains(needle) && !languages.contains(language) {
            languages.append(language)
        }
        return languages
    }

    // MARK: Release group

    private static func releaseGroup(in text: String) -> String? {
        // Scene naming puts the group last, after a hyphen: Movie.2024.1080p.WEB-DL-GROUP
        let pattern = #"-([A-Za-z0-9_]{2,20})(?:\.\w{2,4})?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    // MARK: Size

    private static func size(in text: String) -> Int64? {
        let pattern = #"(\d+(?:[.,]\d+)?)\s?(GB|GiB|MB|MiB)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 2,
              let valueRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text),
              let value = Double(text[valueRange].replacingOccurrences(of: ",", with: "."))
        else { return nil }

        let unit = text[unitRange].lowercased()
        let multiplier: Double = unit.hasPrefix("g") ? 1_073_741_824 : 1_048_576
        return Int64(value * multiplier)
    }
}

// MARK: - Filtering & sorting

/// Applies the debrid stream preference matrix: hard filters first, then the ranked sort.
enum StreamFilterEngine {

    struct Input {
        var minimumQuality: DebridStreamMinimumQuality
        var dolbyVisionFilter: DebridStreamFeatureFilter
        var hdrFilter: DebridStreamFeatureFilter
        var codecFilter: DebridStreamCodecFilter
        var sortMode: DebridStreamSortMode
        var maxResults: Int
        var preferences: DebridStreamPreferences
    }

    static func apply(
        to streams: [Stream],
        attributes: [String: ParsedStreamAttributes],
        input: Input
    ) -> [Stream] {
        func attrs(_ stream: Stream) -> ParsedStreamAttributes {
            attributes[stream.stableKey] ?? StreamAttributeParser.parse(stream)
        }

        var result = streams.filter { passesFilters($0, attrs($0), input) }
        result = applyCaps(result, attrs: attrs, preferences: input.preferences)
        result = sort(result, attrs: attrs, input: input)

        let cap = input.maxResults > 0 ? input.maxResults : input.preferences.maxResults
        if cap > 0 { result = Array(result.prefix(cap)) }
        return result
    }

    // MARK: Hard filters

    private static func passesFilters(
        _ stream: Stream, _ a: ParsedStreamAttributes, _ input: Input
    ) -> Bool {
        // Simple filters from the Debrid settings screen.
        if input.minimumQuality != .any, a.resolution.value < input.minimumQuality.minResolution {
            return false
        }

        let hasDV = a.visualTags.contains(.dv) || a.visualTags.contains(.dvOnly) || a.visualTags.contains(.hdrDv)
        switch input.dolbyVisionFilter {
        case .any: break
        case .exclude: if hasDV { return false }
        case .only: if !hasDV { return false }
        }

        let hasHDR = a.visualTags.contains(where: {
            [.hdr, .hdr10, .hdr10Plus, .hdrOnly, .hdrDv, .hlg].contains($0)
        })
        switch input.hdrFilter {
        case .any: break
        case .exclude: if hasHDR { return false }
        case .only: if !hasHDR { return false }
        }

        switch input.codecFilter {
        case .any: break
        case .h264: if a.encode != .avc { return false }
        case .hevc: if a.encode != .hevc { return false }
        case .av1: if a.encode != .av1 { return false }
        }

        // Full preference matrix.
        let p = input.preferences

        if !p.requiredResolutions.isEmpty, !p.requiredResolutions.contains(a.resolution) { return false }
        if p.excludedResolutions.contains(a.resolution) { return false }

        if !p.requiredQualities.isEmpty, !p.requiredQualities.contains(a.quality) { return false }
        if p.excludedQualities.contains(a.quality) { return false }

        if !p.requiredVisualTags.isEmpty, !p.requiredVisualTags.contains(where: a.visualTags.contains) { return false }
        if p.excludedVisualTags.contains(where: a.visualTags.contains) { return false }

        if !p.requiredAudioTags.isEmpty, !p.requiredAudioTags.contains(where: a.audioTags.contains) { return false }
        if p.excludedAudioTags.contains(where: a.audioTags.contains) { return false }

        if !p.requiredAudioChannels.isEmpty,
           !p.requiredAudioChannels.contains(where: a.audioChannels.contains) { return false }
        if p.excludedAudioChannels.contains(where: a.audioChannels.contains) { return false }

        if !p.requiredEncodes.isEmpty, !p.requiredEncodes.contains(a.encode) { return false }
        if p.excludedEncodes.contains(a.encode) { return false }

        if !p.requiredLanguages.isEmpty, !p.requiredLanguages.contains(where: a.languages.contains) { return false }
        if p.excludedLanguages.contains(where: a.languages.contains) { return false }

        if let group = a.releaseGroup {
            if !p.requiredReleaseGroups.isEmpty,
               !p.requiredReleaseGroups.contains(where: { $0.caseInsensitiveCompare(group) == .orderedSame }) {
                return false
            }
            if p.excludedReleaseGroups.contains(where: { $0.caseInsensitiveCompare(group) == .orderedSame }) {
                return false
            }
        } else if !p.requiredReleaseGroups.isEmpty {
            return false
        }

        if let sizeGb = a.sizeGb {
            if p.sizeMinGb > 0, sizeGb < Double(p.sizeMinGb) { return false }
            if p.sizeMaxGb > 0, sizeGb > Double(p.sizeMaxGb) { return false }
        }

        return true
    }

    // MARK: Per-bucket caps

    private static func applyCaps(
        _ streams: [Stream],
        attrs: (Stream) -> ParsedStreamAttributes,
        preferences: DebridStreamPreferences
    ) -> [Stream] {
        var result = streams

        if preferences.maxPerResolution > 0 {
            var counts: [DebridStreamResolution: Int] = [:]
            result = result.filter { stream in
                let key = attrs(stream).resolution
                let count = counts[key, default: 0]
                guard count < preferences.maxPerResolution else { return false }
                counts[key] = count + 1
                return true
            }
        }

        if preferences.maxPerQuality > 0 {
            var counts: [DebridStreamQuality: Int] = [:]
            result = result.filter { stream in
                let key = attrs(stream).quality
                let count = counts[key, default: 0]
                guard count < preferences.maxPerQuality else { return false }
                counts[key] = count + 1
                return true
            }
        }

        return result
    }

    // MARK: Sorting

    private static func sort(
        _ streams: [Stream],
        attrs: (Stream) -> ParsedStreamAttributes,
        input: Input
    ) -> [Stream] {
        // The explicit criteria list wins; otherwise fall back to the simple sort mode.
        let criteria = input.preferences.sortCriteria
        guard criteria.isEmpty else {
            return streams.sorted { lhs, rhs in
                let a = attrs(lhs), b = attrs(rhs)
                for criterion in criteria {
                    let left = rank(a, key: criterion.key, preferences: input.preferences)
                    let right = rank(b, key: criterion.key, preferences: input.preferences)
                    if left != right {
                        return criterion.direction == .desc ? left > right : left < right
                    }
                }
                return false
            }
        }

        switch input.sortMode {
        case .default:
            return streams
        case .qualityDesc:
            return streams.sorted { attrs($0).resolution.value > attrs($1).resolution.value }
        case .sizeDesc:
            return streams.sorted { (attrs($0).sizeBytes ?? 0) > (attrs($1).sizeBytes ?? 0) }
        case .sizeAsc:
            return streams.sorted { (attrs($0).sizeBytes ?? .max) < (attrs($1).sizeBytes ?? .max) }
        }
    }

    /// Higher is better. Preference-list position drives the score so a user-reordered list
    /// changes ranking exactly as it does on Android.
    private static func rank(
        _ a: ParsedStreamAttributes,
        key: DebridStreamSortKey,
        preferences p: DebridStreamPreferences
    ) -> Double {
        func score<T: Equatable>(_ value: T, in list: [T]) -> Double {
            guard let index = list.firstIndex(of: value) else { return 0 }
            return Double(list.count - index)
        }
        func bestScore<T: Equatable>(_ values: [T], in list: [T]) -> Double {
            values.map { score($0, in: list) }.max() ?? 0
        }

        switch key {
        case .resolution: return score(a.resolution, in: p.preferredResolutions)
        case .quality: return score(a.quality, in: p.preferredQualities)
        case .visualTag: return bestScore(a.visualTags, in: p.preferredVisualTags)
        case .audioTag: return bestScore(a.audioTags, in: p.preferredAudioTags)
        case .audioChannel: return bestScore(a.audioChannels, in: p.preferredAudioChannels)
        case .encode: return score(a.encode, in: p.preferredEncodes)
        case .size: return Double(a.sizeBytes ?? 0)
        case .language: return bestScore(a.languages, in: p.preferredLanguages)
        case .releaseGroup:
            guard let group = a.releaseGroup else { return 0 }
            return p.requiredReleaseGroups.contains(where: {
                $0.caseInsensitiveCompare(group) == .orderedSame
            }) ? 1 : 0
        }
    }

    // MARK: Auto-play selection

    /// Port of the auto-play rules: picks the source to start without showing the list.
    /// The source belonging to the same release as the one that was just playing.
    ///
    /// `bingeGroup` is the addon's own equality marker — same provider, same encode, same file
    /// naming — so matching on it exactly is right, and matching on anything looser would be
    /// guessing at what "the same" means on the viewer's behalf.
    static func bingeGroupMatch(in streams: [Stream], group: String) -> Stream? {
        let target = group.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        return streams.first { $0.behaviorHints?.bingeGroup?.trimmingCharacters(in: .whitespaces) == target }
    }

    static func autoPlayCandidate(
        from streams: [Stream],
        attributes: [String: ParsedStreamAttributes],
        mode: StreamAutoPlayMode,
        source: StreamAutoPlaySource,
        regex: String,
        preferredQuality: String,
        cacheStates: [String: DebridCacheResult]
    ) -> Stream? {
        guard mode != .off, !streams.isEmpty else { return nil }

        let pool = streams.filter { stream in
            switch source {
            case .anyAddon:
                return true
            case .debridOnly:
                return stream.isTorrent || stream.streamURL() != nil
            case .cachedOnly:
                guard let hash = stream.effectiveInfoHash?.lowercased() else { return false }
                return cacheStates[hash]?.state == .cached
            }
        }
        guard !pool.isEmpty else { return nil }

        switch mode {
        case .off:
            return nil
        case .first:
            return pool.first
        case .matchRegex:
            guard let expression = try? NSRegularExpression(pattern: regex, options: .caseInsensitive)
            else { return pool.first }
            return pool.first { stream in
                let text = stream.displayName + " " + (stream.displayDescription ?? "")
                return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            }
        case .preferredQuality:
            let target = DebridStreamResolution.defaultOrder.first {
                $0.displayName.caseInsensitiveCompare(preferredQuality) == .orderedSame
            }
            guard let target else { return pool.first }
            let exact = pool.first {
                (attributes[$0.stableKey] ?? StreamAttributeParser.parse($0)).resolution == target
            }
            return exact ?? pool.first
        }
    }
}
