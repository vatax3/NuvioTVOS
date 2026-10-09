import Foundation

/// What to tell a viewer when libmpv gives up, and what to keep underneath it.
///
/// Port of `mpvNonHttpExplanationKind` / `mpvNonHttpExplanationText`. Ours showed
/// `mpv_error_string(end.error)` directly, which is how a viewer came to read **"unrecognized
/// file format"** on their television — accurate, untranslated, and no use at all: it does not
/// say whether to try another source, switch engine, or give up on the file.
///
/// The classification is deliberately coarse. There are a dozen mpv error codes and only three
/// things a viewer can do about any of them, so three is what the message distinguishes. The raw
/// text is kept below the explanation rather than replaced: it is the only thing worth having
/// when someone reports the failure, and discarding it to look tidy would cost more than it saves.
enum MPVPlaybackFailure {
    enum Kind: Equatable {
        /// The bytes arrived and are not a playable file — a dead link that answered with an
        /// error page, or a truncated download.
        case invalidContent
        /// A real file this build cannot decode. The other engine is worth a try.
        case unsupportedFormat
        /// It never opened. Usually the source, not the file.
        case openFailed
    }

    /// mpv's `file_error` text, plus the last line it logged, which carries the detail the error
    /// code flattens away — a missing codec shows up there and nowhere else.
    static func kind(fileError: String?, logLine: String?) -> Kind {
        let file = fileError?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let log = logLine?.lowercased() ?? ""

        if file == "unrecognized file format"
            || file == "no audio or video data played"
            || log.contains("unrecognized file format") {
            return .invalidContent
        }
        if file == "audio output initialization failed"
            || file == "video output initialization failed"
            || file == "not supported"
            || log.contains("codec")
            || log.contains("decoder")
            || log.contains("hwdec") {
            return .unsupportedFormat
        }
        return .openFailed
    }

    static func explanation(for kind: Kind) -> String {
        switch kind {
        case .invalidContent:
            return L10n.text(
                "player.error_invalid_content",
                fallback: "That source did not send a playable file. Try another one."
            )
        case .unsupportedFormat:
            return L10n.text(
                "player.error_unsupported_format",
                fallback: "This file uses something the player cannot decode. Try the other engine, or another source."
            )
        case .openFailed:
            return L10n.text(
                "player.error_stream_unavailable",
                fallback: "That source could not be opened. It may have expired — try another one."
            )
        }
    }

    /// The explanation with mpv's own words kept beneath it.
    ///
    /// Not concatenated when the technical text says nothing the explanation does not: repeating
    /// "loading failed" under "that source could not be opened" is noise that makes the useful
    /// cases harder to spot.
    static func message(fileError: String?, logLine: String?) -> String {
        let explanation = explanation(for: kind(fileError: fileError, logLine: logLine))
        guard let detail = fileError?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
              detail.caseInsensitiveCompare("loading failed") != .orderedSame
        else { return explanation }
        return "\(explanation)\n\n\(detail)"
    }
}
