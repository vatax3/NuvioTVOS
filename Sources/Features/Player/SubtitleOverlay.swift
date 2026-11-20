import SwiftUI
import Observation

/// Holds the loaded cues for the selected external track plus the playback clock that drives
/// them. Addon subtitles are plain SRT/VTT files, which AVFoundation cannot attach to a remote
/// asset — so Nuvio draws them itself, which is also what makes the appearance settings real.
@Observable
@MainActor
final class SubtitleTrackController {
    var available: [Subtitle] = []
    private(set) var selected: Subtitle?
    private(set) var cues: [SubtitleCue] = []
    private(set) var isLoading = false
    private(set) var loadError: String?
    /// Current playback position, updated at cue resolution rather than the 5s persistence tick.
    var currentTime: Double = 0

    /// Seconds to hold the drawn cues back by, positive meaning "later".
    ///
    /// The same sign convention as mpv's `sub-delay`, and it exists because the delay control has
    /// never reached these cues at all: mpv's option adjusts what *mpv* renders — muxed tracks —
    /// while addon subtitles are parsed and drawn here. Those are the ones most viewers use, so
    /// the control appeared to do nothing for most of the files it was reached from.
    ///
    /// Not persisted: a delay corrects one release's timing against one subtitle file, and
    /// carrying it into the next thing played would be a mystery rather than a convenience.
    var delay: Double = 0

    /// Set from the viewer's subtitle settings. Changing it re-filters what is already loaded
    /// rather than forcing the track to be fetched again.
    var stripsSDH = false {
        didSet {
            guard oldValue != stripsSDH else { return }
            applyFilters()
        }
    }

    #if DEBUG
    /// Loads a track without a network, so the delay and the sync rules can be exercised against
    /// a real controller rather than a reimplementation of one.
    func adoptForTesting(_ cues: [SubtitleCue]) {
        rawCues = cues
        applyFilters()
    }
    #endif

    private var loadTask: Task<Void, Never>?
    /// The track as it was parsed. `cues` is what is drawn, which is this filtered.
    private var rawCues: [SubtitleCue] = []
    /// The longest cue in the loaded track. It bounds how far back a lookup has to walk before
    /// it can be sure nothing else is still on screen, so it is measured once with the track
    /// rather than recomputed on every tick.
    private var longestCue: Double = 0

    /// Every cue showing at `currentTime`, not just one of them.
    ///
    /// Subtitles overlap routinely — two speakers answering each other, or a translated sign
    /// held over dialogue — and returning a single cue silently dropped the other. Missing
    /// dialogue does not look like a bug on screen, which is how it went unnoticed.
    var activeCues: [SubtitleCue] {
        Self.showing(cues, at: currentTime - delay, longestCue: longestCue)
    }

    /// The position the cue list is being read at, which is the playback clock *minus* the delay.
    /// Upstream writes it `VideoMs − subtitleDelayMs`; it is the number every sync decision here
    /// is made against, so it is named once rather than recomputed.
    var cueClock: Double { currentTime - delay }

    /// Extracted from the property so it can be checked on its own: which cues are on screen at
    /// an instant is arithmetic over a sorted list, and proving it right should not need a
    /// player, a network or a loaded track.
    ///
    /// `longestCue` is the longest cue in `cues`. It is passed in rather than measured here
    /// because this runs on every playback tick and that measurement is O(n).
    nonisolated static func showing(
        _ cues: [SubtitleCue],
        at time: Double,
        longestCue: Double
    ) -> [SubtitleCue] {
        guard !cues.isEmpty else { return [] }

        // The first cue that has not started yet. Everything on screen lies before it, and a
        // seek can land anywhere, so this is a binary search rather than a walk.
        var low = 0
        var high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].start <= time { low = mid + 1 } else { high = mid }
        }

        // Walk back from there. A cue that began longer ago than the track's longest cue cannot
        // still be running, which is what keeps this to a bounded number of steps.
        let earliest = time - longestCue
        var showing: [SubtitleCue] = []
        var index = low - 1
        while index >= 0, cues[index].start >= earliest {
            if cues[index].contains(time) { showing.append(cues[index]) }
            index -= 1
        }
        // Collected newest-first; on screen they read in the order they were written.
        return Array(showing.reversed())
    }

    /// The bound `showing(_:at:longestCue:)` needs, measured once when a track is loaded.
    nonisolated static func longestCueDuration(in cues: [SubtitleCue]) -> Double {
        cues.map { $0.end - $0.start }.max() ?? 0
    }

    private func applyFilters() {
        cues = stripsSDH ? SubtitleSDHFilter.strip(rawCues) : rawCues
        longestCue = Self.longestCueDuration(in: cues)
    }

    func select(_ subtitle: Subtitle?) {
        loadTask?.cancel()
        selected = subtitle
        rawCues = []
        cues = []
        longestCue = 0
        loadError = nil

        guard let subtitle else {
            isLoading = false
            return
        }
        isLoading = true
        loadTask = Task {
            defer { isLoading = false }
            do {
                let loaded = try await SubtitleLoader.shared.cues(for: subtitle)
                guard !Task.isCancelled else { return }
                rawCues = loaded
                applyFilters()
                if loaded.isEmpty { loadError = L10n.text("player.no_readable_cues", fallback: "That track had no readable cues.") }
            } catch {
                guard !Task.isCancelled else { return }
                loadError = error.localizedDescription
            }
        }
    }
}

/// Draws the active cue with the viewer's styling. Sits above the player but below the
/// transport bar, and never takes focus.
///
/// Font, background roundness and drop shadow follow upstream's `StyledSubtitleText`
/// (1.2.0-beta.1): padding 10 × 5 and every size scaled by the text size against a 24-point
/// reference, the background a rounded box behind the whole block, the shadow black at the
/// viewer's opacity, offset and blurred by the shadow size.
struct SubtitleOverlay: View {
    let cues: [SubtitleCue]
    let style: SubtitleStyle
    /// What is covering the bottom of the picture. The host knows; this view is drawn over both
    /// engines and cannot see either one's chrome.
    var obstructions = SubtitlePlacement.Obstructions()
    /// mpv's current event, when the overlay draws a text track in mpv's place
    /// (`MPVEngine.styledSubtitleText`). Its top-aligned events go to the top of the picture.
    var mpvText: MpvStyledSubtitleText? = nil

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let top = mpvText?.top, !top.characters.isEmpty {
                    block(top)
                        .frame(maxWidth: proxy.size.width * 0.8)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                        .padding(.top, dp(48))
                }
                if hasBottom {
                    // Overlapping cues stack rather than replace one another, and each keeps its
                    // own background box so two speakers stay readable as two lines.
                    VStack(spacing: NuvioTheme.spacing.xxs) {
                        if let bottom = mpvText?.bottom, !bottom.characters.isEmpty {
                            block(bottom)
                        }
                        ForEach(cues) { cue in
                            block(AttributedString(cue.text))
                        }
                    }
                    .frame(maxWidth: proxy.size.width * 0.8)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
                    // Lifted clear of the transport only while the transport is there. Reserving
                    // the room permanently is what put every line a tenth of the picture too high.
                    .padding(.bottom, dp(CGFloat(SubtitlePlacement.inset(
                        offset: style.verticalOffset, obstructions: obstructions
                    ))))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var hasBottom: Bool {
        !cues.isEmpty || (mpvText.map { !$0.bottom.characters.isEmpty } ?? false)
    }

    /// Upstream's 24 sp reference size, against which padding, radius and shadow are scaled.
    private var unit: CGFloat { style.fontSize / sp(24) }

    private func block(_ text: AttributedString) -> some View {
        Text(text)
            .font(SubtitleFonts.font(for: style.fontId, size: style.fontSize, weight: style.bold ? .bold : .regular))
            .foregroundStyle(style.textColor)
            .multilineTextAlignment(.center)
            .lineSpacing(style.fontSize * 0.18)
            .shadow(color: outlineShadow, radius: outlineRadius)
            .shadow(
                color: style.shadowEnabled
                    ? .black.opacity(style.shadowOpacity / 100 * style.textColor.alphaComponent) : .clear,
                radius: style.shadowEnabled ? style.shadowSize * unit : 0,
                x: style.shadowEnabled ? style.shadowSize * unit : 0,
                y: style.shadowEnabled ? style.shadowSize * unit : 0
            )
            .padding(.horizontal, 10 * unit)
            .padding(.vertical, 5 * unit)
            .background {
                if style.backgroundColor.alphaComponent > 0.01 {
                    RoundedRectangle(cornerRadius: style.backgroundRadius * unit, style: .continuous)
                        .fill(style.backgroundColor)
                }
            }
    }

    /// SwiftUI has no text stroke, so the outline is approximated with a tight dark shadow —
    /// visually equivalent at TV viewing distance and far cheaper than four offset copies.
    private var outlineShadow: Color {
        style.outlineEnabled ? style.outlineColor : .clear
    }

    /// Upstream's outline half-width, `outlineWidth × unit / 2` since 1.2.0-beta.2 (half its old
    /// value per step, so width 2 matches the native renderer).
    private var outlineRadius: CGFloat {
        style.outlineEnabled ? max(0.5, CGFloat(style.outlineWidth) * unit / 2) : 0
    }
}
