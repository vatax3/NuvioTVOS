import Foundation

/// A chapter of the playing file, as its container lists it.
struct PlayerChapter: Identifiable, Hashable {
    /// Seconds from the start of the file. The engines speak seconds, so the model does too —
    /// upstream's milliseconds are an ExoPlayer convention and converting at every call site is
    /// how a unit mistake eventually gets made.
    let start: Double
    let title: String?

    var id: Double { start }

    /// What the list shows when the container named the chapter, and a number when it did not.
    /// Most releases title nothing, so this is the usual case rather than the fallback.
    func displayName(number: Int) -> String {
        title?.nilIfBlank ?? L10n.format("player.chapter_number", fallback: "Chapter %@", "\(number)")
    }
}

/// The rules around a chapter list, kept apart from any engine so they can be tested without one.
///
/// A port of upstream's `PlayerChapters.kt`. The thresholds are mpv's, and they are what makes
/// chapter skipping feel like chapter skipping rather than like seeking.
enum PlayerChapters {
    /// Going back within this much of a chapter's start goes to the chapter before it.
    ///
    /// Without it, *previous* at four seconds in would restart a chapter the viewer has barely
    /// entered and they would have to press it twice — which is mpv's behaviour, and every
    /// player that copied mpv.
    static let previousRestartThreshold: Double = 3

    /// Sorted, one per start time, and only when there are at least two.
    ///
    /// A lone chapter has nothing to skip to, and a single "Chapter 1" at zero is what a great
    /// many files carry — offering a chapter control for it would be offering a control that
    /// does nothing.
    static func normalize(_ chapters: [PlayerChapter]) -> [PlayerChapter] {
        var seen: Set<Double> = []
        let sorted = chapters
            .filter { $0.start >= 0 }
            .sorted { $0.start < $1.start }
            .filter { seen.insert($0.start).inserted }
        return sorted.count < 2 ? [] : sorted
    }

    /// The chapter playing at `position`, or nil before the first one starts — which happens on
    /// a file whose first chapter begins after a pre-roll.
    static func index(in chapters: [PlayerChapter], at position: Double) -> Int? {
        chapters.lastIndex { $0.start <= position }
    }

    static func nextStart(in chapters: [PlayerChapter], from position: Double) -> Double? {
        chapters.first { $0.start > position }?.start
    }

    /// The current chapter's start, or the previous one's when `position` is just past it.
    static func previousStart(in chapters: [PlayerChapter], from position: Double) -> Double? {
        guard let index = index(in: chapters, at: position) else { return nil }
        let current = chapters[index].start
        guard position - current <= previousRestartThreshold, index > 0 else { return current }
        return chapters[index - 1].start
    }
}
