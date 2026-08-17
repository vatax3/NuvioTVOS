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

    private var loadTask: Task<Void, Never>?
    /// Index of the last matched cue — cues are sorted, so playback walks forward from here
    /// instead of rescanning the whole track on every tick.
    private var searchHint = 0

    var activeCue: SubtitleCue? {
        guard !cues.isEmpty else { return nil }
        let time = currentTime

        if searchHint < cues.count, cues[searchHint].contains(time) {
            return cues[searchHint]
        }
        // A seek can land anywhere; binary search rather than walking from the old position.
        var low = 0
        var high = cues.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let cue = cues[mid]
            if cue.contains(time) {
                searchHint = mid
                return cue
            }
            if time < cue.start { high = mid - 1 } else { low = mid + 1 }
        }
        return nil
    }

    func select(_ subtitle: Subtitle?) {
        loadTask?.cancel()
        selected = subtitle
        cues = []
        searchHint = 0
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
                cues = loaded
                if loaded.isEmpty { loadError = "That track had no readable cues." }
            } catch {
                guard !Task.isCancelled else { return }
                loadError = error.localizedDescription
            }
        }
    }
}

/// Draws the active cue with the viewer's styling. Sits above the player but below the
/// transport bar, and never takes focus.
struct SubtitleOverlay: View {
    let cue: SubtitleCue?
    let style: SubtitleStyle

    var body: some View {
        GeometryReader { proxy in
            if let cue {
                Text(cue.text)
                    .font(.system(size: style.fontSize, weight: style.bold ? .bold : .regular))
                    .foregroundStyle(style.textColor)
                    .multilineTextAlignment(.center)
                    .lineSpacing(style.fontSize * 0.18)
                    .shadow(color: outlineShadow, radius: outlineRadius)
                    .padding(.horizontal, NuvioTheme.spacing.md)
                    .padding(.vertical, NuvioTheme.spacing.xs)
                    .background {
                        if style.backgroundColor.alphaComponent > 0.01 {
                            RoundedRectangle(cornerRadius: NuvioTheme.radii.xs, style: .continuous)
                                .fill(style.backgroundColor)
                        }
                    }
                    .frame(maxWidth: proxy.size.width * 0.8)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
                    // The transport bar occupies the bottom strip, so cues sit above it by
                    // default; the offset preference moves them from there.
                    .padding(.bottom, baseBottomInset + dp(CGFloat(style.verticalOffset)))
            }
        }
        .allowsHitTesting(false)
    }

    private var baseBottomInset: CGFloat { dp(60) }

    /// SwiftUI has no text stroke, so the outline is approximated with a tight dark shadow —
    /// visually equivalent at TV viewing distance and far cheaper than four offset copies.
    private var outlineShadow: Color {
        style.outlineEnabled ? style.outlineColor : .clear
    }

    private var outlineRadius: CGFloat {
        style.outlineEnabled ? max(1, dp(CGFloat(style.outlineWidth)) * 0.6) : 0
    }
}
