import AVFoundation
import AVKit
import CoreMedia
import UIKit
import os

/// Frame-rate and dynamic-range matching, the Apple TV counterpart of Android's `FrameRateUtils`.
///
/// Worth being explicit about why this exists, because "tvOS handles it" is a half-truth that
/// silently costs the feature: *Match Content* in Apple TV Settings is a permission, not an
/// implementation.  An app still has to hand the display the criteria of what it is about to
/// play — `AVPlayerViewController` only does that when asked, and a custom surface like the MPV
/// one never does.  Without this the panel stays at 60 Hz for 23.976 fps film and judders, which
/// is exactly the artefact the Android build goes to great lengths to avoid.
@MainActor
enum DisplayModeMatcher {
    private static let log = Logger(subsystem: "com.nuvio.tvos", category: "DisplayMode")

    /// What mpv knows about the picture, in mpv's own vocabulary.  Kept as strings because that
    /// is what `video-params` returns, and translating at the boundary keeps the guesswork in
    /// one place.
    struct VideoFormat: Equatable {
        var codec: String?
        var width: Int32
        var height: Int32
        var frameRate: Double
        /// mpv's `video-params/gamma`: `pq`, `hlg`, `bt.1886`, …
        var transfer: String?
        /// mpv's `video-params/primaries`: `bt.2020`, `bt.709`, …
        var primaries: String?
        /// mpv's `video-params/colormatrix`.
        var matrix: String?
    }

    /// Applies the criteria for a decoded stream. Safe to call repeatedly — the display manager
    /// ignores criteria it is already honouring.
    static func apply(_ format: VideoFormat, mode: FrameRateMatchingMode) {
        guard mode != .off, format.frameRate > 1, format.width > 0, format.height > 0 else { return }
        guard let manager = displayManager else { return }
        guard let description = formatDescription(for: format) else { return }
        manager.preferredDisplayCriteria = AVDisplayCriteria(
            refreshRate: Float(format.frameRate),
            formatDescription: description
        )
        log.debug("Requested \(format.frameRate, privacy: .public) Hz for \(format.transfer ?? "sdr", privacy: .public)")
    }

    /// Hands the display back to whatever the system had chosen.  Only `startStop` does this:
    /// `start` deliberately leaves the panel in the film's mode, which avoids a second mode
    /// change — and a second black frame — every time a viewer steps out of playback.
    static func restore(mode: FrameRateMatchingMode) {
        guard mode == .startStop else { return }
        displayManager?.preferredDisplayCriteria = nil
    }

    private static var displayManager: AVDisplayManager? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .avDisplayManager
    }

    /// `AVDisplayCriteria` reads the dynamic range off a format description rather than taking
    /// it as a flag, so one has to be synthesised for a stream that never passed through
    /// VideoToolbox.  Only the colour extensions actually matter to the display server; the
    /// codec and dimensions are there to make a well-formed description.
    private static func formatDescription(for format: VideoFormat) -> CMFormatDescription? {
        let extensions: [CFString: Any] = [
            kCVImageBufferTransferFunctionKey: transferFunction(format.transfer),
            kCVImageBufferColorPrimariesKey: colorPrimaries(format.primaries),
            kCVImageBufferYCbCrMatrixKey: ycbcrMatrix(format.matrix)
        ]

        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType(format.codec),
            width: format.width,
            height: format.height,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &description
        )
        guard status == noErr else {
            log.error("Could not describe the video format: \(status)")
            return nil
        }
        return description
    }

    private static func codecType(_ codec: String?) -> CMVideoCodecType {
        switch codec?.lowercased() {
        case let value? where value.contains("hevc") || value.contains("h265"):
            return kCMVideoCodecType_HEVC
        case let value? where value.contains("av1"):
            return kCMVideoCodecType_AV1
        case let value? where value.contains("vp9"):
            return kCMVideoCodecType_VP9
        default:
            return kCMVideoCodecType_H264
        }
    }

    private static func transferFunction(_ gamma: String?) -> CFString {
        switch gamma?.lowercased() {
        case "pq", "st2084": return kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case "hlg": return kCVImageBufferTransferFunction_ITU_R_2100_HLG
        default: return kCVImageBufferTransferFunction_ITU_R_709_2
        }
    }

    private static func colorPrimaries(_ primaries: String?) -> CFString {
        primaries?.lowercased().contains("2020") == true
            ? kCVImageBufferColorPrimaries_ITU_R_2020
            : kCVImageBufferColorPrimaries_ITU_R_709_2
    }

    private static func ycbcrMatrix(_ matrix: String?) -> CFString {
        matrix?.lowercased().contains("2020") == true
            ? kCVImageBufferYCbCrMatrix_ITU_R_2020
            : kCVImageBufferYCbCrMatrix_ITU_R_709_2
    }
}
