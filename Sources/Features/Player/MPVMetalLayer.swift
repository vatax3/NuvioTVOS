#if canImport(Libmpv)
import UIKit
import QuartzCore

/// The surface mpv draws into.
///
/// mpv's `moltenvk` GPU context takes a `CAMetalLayer` pointer through the `wid` option and owns
/// the swapchain itself — there is no render callback and no framebuffer to hand it.
///
/// The one override exists because mpv drives this layer from its own video-output thread: a
/// zero or one-pixel drawable makes the swapchain invalid, and mpv polls the size rather than
/// being told, so the guard has to live on the property itself. Lifted from the Nuvio iOS
/// client, which found it the hard way.
///
/// That client also overrides `wantsExtendedDynamicRangeContent` to dodge a main-thread
/// deadlock. tvOS marks that property unavailable — HDR is negotiated with the display rather
/// than per-layer — so the deadlock cannot arise here and the override is not needed.
final class MPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            guard Int(newValue.width) > 1, Int(newValue.height) > 1 else { return }
            super.drawableSize = newValue
        }
    }
}
#endif
