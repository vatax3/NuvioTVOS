import Foundation

/// The audio settings that are decided once and handed to mpv, rather than driven from the
/// player's own controls.
///
/// Kept apart from `MPVEngine` because the interesting part is the arithmetic: a viewer picks
/// decibels and libmpv wants something else in every case — a percentage for volume, a linear
/// level for the centre channel. Getting one of those conversions wrong is inaudible in code
/// review and very audible on a television.
enum PlayerAudioMix {
    /// The three settled once, at engine start.
    ///
    /// Grouped because they travel together through four layers and because none of them can be
    /// changed mid-playback: mpv builds its audio chain from these, and changing one would mean
    /// rebuilding it under the film.
    struct Options: Equatable {
        var amplificationDb: Int = 0
        var centerMixLevelDb: Int = 0
        var normalizesDownmix: Bool = false
    }

    // MARK: Amplification

    /// Post-decode gain, Android's "Amplification (PCM)".
    static let amplificationRangeDb = 0...10

    /// mpv expresses volume as a percentage of the source, so the decibels the viewer picked are
    /// converted. `10^(dB/20)` is amplitude decibels, which is what the control means and what
    /// upstream's `GainAudioProcessor` uses.
    static func volumePercent(amplificationDb: Int) -> Double {
        let clamped = min(amplificationRangeDb.upperBound, max(amplificationRangeDb.lowerBound, amplificationDb))
        return pow(10.0, Double(clamped) / 20.0) * 100
    }

    // MARK: Centre mix level

    /// Upstream's range, and it is asymmetric for a reason: the control exists because dialogue
    /// is too quiet in a downmix, so there is far more room above than below.
    static let centerMixRangeDb = -10...30

    /// libswresample's own default centre level, `M_SQRT1_2` — the standard −3 dB a centre
    /// channel is folded in at. Zero on the viewer's dial means exactly this, so the setting
    /// starts out changing nothing.
    static let defaultCenterMixLevel = 0.7071067811865476

    /// The linear level libswresample wants.
    ///
    /// The option is a float in `[-32, 32]` with a default of 0.707, so it is a level and not a
    /// number of decibels — which is why this multiplies the default rather than passing the
    /// viewer's figure through. At the top of the range that lands near 22, comfortably inside
    /// what the option accepts.
    static func centerMixLevel(db: Int) -> Double {
        let clamped = min(centerMixRangeDb.upperBound, max(centerMixRangeDb.lowerBound, db))
        return defaultCenterMixLevel * pow(10.0, Double(clamped) / 20.0)
    }

    /// `--audio-swresample-o`, or nothing at all when the dial is at zero.
    ///
    /// Nothing at all is the point: passing the default back explicitly would still build a
    /// resampler context for a setting the viewer never touched.
    static func swresampleOptions(centerMixDb: Int) -> String? {
        guard centerMixDb != 0 else { return nil }
        return String(format: "center_mix_level=%.4f", centerMixLevel(db: centerMixDb))
    }
}
