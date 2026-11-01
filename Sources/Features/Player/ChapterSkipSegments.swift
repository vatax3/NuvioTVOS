import Foundation

/// Skip segments read from the file's own chapter titles.
///
/// Port of upstream's `ChapterSkipIntervals.kt` and `mergeSkipIntervals`. A release that names
/// its chapters "Opening", "OP 2" or "Ending" has already said where the intro is, exactly, for
/// this cut of the episode — which an online database keyed by episode number cannot promise.
/// So chapters win, category by category, and the providers fill what chapters leave out.
enum ChapterSkipSegments {
    /// Shorter than this is a chapter marker, not a sequence; longer is a whole act titled badly.
    static let minimumLength: Double = 5
    static let maximumLength: Double = 240

    enum Category: Equatable { case opening, ending, recap, intro, postCredits }

    private static func pattern(_ source: String) -> NSRegularExpression {
        // The patterns are literals; a failure here is a programming error caught by the tests.
        try! NSRegularExpression(pattern: source, options: [.caseInsensitive])
    }

    private static let postCredits = pattern(#"(post|mid|after)[\s-]credits"#)
    private static let opening = pattern(#"^\s*(op(ening)?)(\s*(credits|theme))?\s*\d*\s*$"#)
    private static let ending = pattern(#"^\s*(ed|ending)(\s*(credits|theme))?\s*\d*\s*$"#)
    private static let credits = pattern(#"^\s*(end|closing)?\s*credits\s*$"#)
    private static let recap = pattern(#"^\s*(recap|previously(\s+on.*)?)\s*$"#)
    private static let intro = pattern(#"^\s*intro\s*$"#)

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// What a chapter title says it is. Post-credits is matched anywhere in the title and checked
    /// first, so "Post-Credits Scene" is never mistaken for the credits themselves.
    static func category(of title: String?) -> Category? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
        else { return nil }
        if matches(postCredits, title) { return .postCredits }
        if matches(opening, title) { return .opening }
        if matches(ending, title) || matches(credits, title) { return .ending }
        if matches(recap, title) { return .recap }
        if matches(intro, title) { return .intro }
        return nil
    }

    /// - Parameters:
    ///   - chapters: normalised, in order. Each ends where the next begins; the last ends at
    ///     `duration`.
    ///   - duration: the file's length. Nothing is derived without it, since the last chapter
    ///     would have no end.
    static func segments(from chapters: [PlayerChapter], duration: Double) -> [SkipSegment] {
        guard chapters.count >= 2, duration.isFinite, duration > 0 else { return [] }
        let spans: [(Category, Double, Double)] = chapters.indices.compactMap { index in
            guard let category = category(of: chapters[index].title) else { return nil }
            let start = chapters[index].start
            let end = index + 1 < chapters.count ? chapters[index + 1].start : duration
            return (category, start, end)
        }
        // "Intro" is an opening only in a file that has no chapter calling itself one; next to an
        // "Opening" it is usually the cold open before it.
        let hasOpening = spans.contains { $0.0 == .opening }
        return spans.compactMap { category, start, end in
            let length = end - start
            guard length >= minimumLength, length <= maximumLength else { return nil }
            let kind: SkipSegment.Kind
            switch category {
            case .opening: kind = .intro
            case .intro:
                guard !hasOpening else { return nil }
                kind = .intro
            case .ending: kind = .outro
            case .recap: kind = .recap
            case .postCredits: return nil
            }
            return SkipSegment(kind: kind, start: start, end: end)
        }
    }

    /// Chapters first, per kind, for an episode. A film keeps the providers' answer whenever there
    /// is one: IntroDB's credits marks are what the post-play card measures the ending against,
    /// and a chapter called "Credits" is often the whole crawl including a scene inside it.
    static func merge(api: [SkipSegment], chapters: [SkipSegment], isMovie: Bool) -> [SkipSegment] {
        if chapters.isEmpty { return api }
        if api.isEmpty { return SkipIntroClient.merge([chapters]) }
        if isMovie { return api }
        return SkipIntroClient.merge([chapters, api])
    }
}
