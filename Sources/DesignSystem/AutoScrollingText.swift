import SwiftUI

/// Text clamped to `lineLimit`, which, when `isEnabled` and the text overflows, scrolls slowly
/// upward instead of ending in an ellipsis, then pauses and returns to the top.
///
/// Port of upstream's `AutoScrollingText` (1.1.0-beta.12), with their timings: 3 s before it
/// moves, 12 pt a second, 3 s at the end, 0.6 s back, at most three passes so an idle Home screen
/// does not animate for ever, and a fade at whichever edge has hidden text. Reduce Motion takes
/// the place of their "animations off" check. A new text restarts it from the top.
struct AutoScrollingText: View {
    let text: String
    let lineLimit: Int
    let isEnabled: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewportHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0
    @State private var offset: CGFloat = 0

    static let startDelay: Duration = .seconds(3)
    static let endPause: Duration = .seconds(3)
    static let returnDuration = 0.6
    static let maxCycles = 3
    static let fadeFraction: CGFloat = 0.18

    private var overflow: CGFloat { max(0, fullHeight - viewportHeight) }
    private var scrolls: Bool { isEnabled && !reduceMotion && overflow > 1 }

    private struct RunKey: Hashable {
        var text: String
        var overflow: CGFloat
        var scrolls: Bool
    }

    var body: some View {
        if !isEnabled || reduceMotion {
            Text(text).lineLimit(lineLimit)
        } else {
            // The clamped text sizes the box; the whole text, laid out at the same width, is
            // what moves inside it.
            Text(text)
                .lineLimit(lineLimit)
                .opacity(scrolls ? 0 : 1)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { viewportHeight = $0 }
                .background(alignment: .top) {
                    Text(text)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self, of: \.size.height) { fullHeight = $0 }
                }
                .overlay(alignment: .top) {
                    if scrolls {
                        Text(text)
                            .fixedSize(horizontal: false, vertical: true)
                            .offset(y: -offset)
                    }
                }
                .clipped()
                .mask { if scrolls { fadeMask } else { Rectangle() } }
                .task(id: RunKey(text: text, overflow: overflow, scrolls: scrolls)) { await run() }
        }
    }

    /// Each fade grows with the distance to its edge, so the top one appears as the text leaves.
    private var fadeMask: some View {
        let fade = max(1, viewportHeight * Self.fadeFraction)
        let top = min(offset, fade) / fade
        let bottom = min(overflow - offset, fade) / fade
        return VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(1 - top), .black], startPoint: .top, endPoint: .bottom)
                .frame(height: fade)
            Rectangle()
            LinearGradient(colors: [.black, .black.opacity(1 - bottom)], startPoint: .top, endPoint: .bottom)
                .frame(height: fade)
        }
    }

    private func run() async {
        offset = 0
        guard scrolls else { return }
        let distance = overflow
        let scrollSeconds = Double(distance / dp(12))
        for _ in 0..<Self.maxCycles {
            guard (try? await Task.sleep(for: Self.startDelay)) != nil else { return }
            withAnimation(.linear(duration: scrollSeconds)) { offset = distance }
            guard (try? await Task.sleep(for: .seconds(scrollSeconds) + Self.endPause)) != nil else { return }
            withAnimation(.easeInOut(duration: Self.returnDuration)) { offset = 0 }
            guard (try? await Task.sleep(for: .seconds(Self.returnDuration))) != nil else { return }
        }
    }
}
