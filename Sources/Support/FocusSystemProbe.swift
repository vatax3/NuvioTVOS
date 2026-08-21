#if canImport(UIKit)
import UIKit

/// Ground truth for "is anything focused at all".
///
/// SwiftUI's `@FocusState` is a request as much as a report: read immediately after a write it
/// gives back the value just written, whether or not the focus engine accepted it. During a
/// transition — a transport appearing as its sink leaves the focus graph, a destination being
/// swapped for another — those two answers differ, and the difference is a remote that has
/// stopped responding. UIKit's focus system knows what actually happened.
///
/// Used by the player, to decide whether a focus repair is still needed, and by the shell, to
/// know when to stop trying to hand focus to a screen that has just been opened.
@MainActor
enum FocusSystemProbe {
    static var hasFocusedItem: Bool {
        guard let window = keyWindow, let system = UIFocusSystem.focusSystem(for: window) else {
            // No window to ask: assume focus is fine rather than spin trying to repair it.
            return true
        }
        return system.focusedItem != nil
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
}
#endif
