import SwiftUI
import UIKit

/// Turns a held Select on the remote into something a card can act on.
///
/// `.onLongPressGesture` looks like the answer and is not: on a focused tvOS `Button` the
/// platform's own press handling consumes the hold and fires the button's *primary* action on
/// release, so the gesture never runs. The poster options dialog shipped in 1.0.18 attached
/// exactly that way and was unreachable for thirteen releases — holding Select on a poster
/// opened the title instead. `PosterOptionsUITests` is what caught it, and is what stops it
/// coming back.
///
/// Same shape as the player's `MenuPressGate` and `PlayerHoldSeekGate`: press recognizers are
/// the only place the platform exposes the button still being down, and they live on the
/// hosting controller's view so they sit outside the focus graph entirely.
@Observable
@MainActor
final class SelectHoldReporter {
    /// Bumped once per hold. Cards watch it rather than being called back, because the gate has
    /// no idea which card is focused and the focused card is the only one that should answer.
    private(set) var holdCount = 0

    func report() { holdCount += 1 }
}

private struct SelectHoldGateView: UIViewRepresentable {
    let onHold: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = GateView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onHold = onHold
    }

    func makeCoordinator() -> Coordinator { Coordinator(onHold: onHold) }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onHold: () -> Void

        init(onHold: @escaping () -> Void) {
            self.onHold = onHold
            super.init()
        }

        @objc func held(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began else { return }
            onHold()
        }

        /// The recognizer must never take the press away from anything. Every other Select in
        /// the app — settings rows, dialog buttons, the transport — has to keep working exactly
        /// as before, and a card suppresses its own primary action itself rather than having it
        /// cancelled out from under it here.
        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }
    }

    /// A zero-size view that finds the hosting controller, hangs the recognizer off it, and
    /// takes it away again on the way out.
    private final class GateView: UIView {
        weak var coordinator: Coordinator?
        private weak var host: UIView?
        private var recognizer: UILongPressGestureRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                detach()
                return
            }
            attach()
        }

        private func attach() {
            guard recognizer == nil, let host = hostingControllerView, let coordinator else { return }
            let hold = UILongPressGestureRecognizer(
                target: coordinator, action: #selector(Coordinator.held(_:))
            )
            hold.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
            // Long enough that an ordinary click is never mistaken for a hold, short enough that
            // the dialog appears while the viewer is still holding the button down — which is
            // what tells them the gesture exists at all.
            hold.minimumPressDuration = 0.55
            hold.cancelsTouchesInView = false
            hold.delaysTouchesBegan = false
            hold.delegate = coordinator
            host.addGestureRecognizer(hold)
            self.host = host
            recognizer = hold
        }

        private func detach() {
            if let recognizer { host?.removeGestureRecognizer(recognizer) }
            recognizer = nil
            host = nil
        }

        private var hostingControllerView: UIView? {
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController { return controller.viewIfLoaded }
                responder = current.next
            }
            return nil
        }

        deinit {
            // `deinit` can run off the main actor; the recognizer must be released on it.
            guard let recognizer, let host else { return }
            Task { @MainActor in host.removeGestureRecognizer(recognizer) }
        }
    }
}

extension View {
    /// Installs the app-wide Select-hold recognizer. Once, at the root.
    func selectHoldGate(reporting reporter: SelectHoldReporter) -> some View {
        background(SelectHoldGateView { reporter.report() }.frame(width: 0, height: 0))
    }
}

/// What a card does with the hold: open something, and swallow the press that follows.
///
/// The primary action still arrives on release — the recognizer deliberately does not cancel it,
/// because doing so would break Select everywhere else. So the card that answered the hold is
/// the one that drops the next press, and only that card.
struct SelectHoldResponder: ViewModifier {
    let isFocused: Bool
    let action: () -> Void

    @Environment(SelectHoldReporter.self) private var reporter
    @Binding var swallowsNextPress: Bool

    func body(content: Content) -> some View {
        content.onChange(of: reporter.holdCount) {
            guard isFocused else { return }
            swallowsNextPress = true
            action()
        }
    }
}

extension View {
    /// Answers a held Select while this view has focus.
    func onSelectHold(
        isFocused: Bool,
        swallowsNextPress: Binding<Bool>,
        perform action: @escaping () -> Void
    ) -> some View {
        modifier(SelectHoldResponder(
            isFocused: isFocused, action: action, swallowsNextPress: swallowsNextPress
        ))
    }
}
