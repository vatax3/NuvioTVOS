import Foundation

/// Recognising the release the party is on, among the sources this device can see.
///
/// Upstream's model, and the one thing to understand about watch parties before reading the
/// rest: **everyone plays from their own sources**. The host's resolved link is an option — it
/// runs through their debrid account — not the mechanism. What travels as a matter of course is
/// a *description* of the file, and each member finds it in their own list.
///
/// A port of `PartySourceMatch.kt`, with its ordering intact: the infoHash is the identity when
/// both sides have one, and the filename is the fallback for everything resolved to a link.
extension PartySource {
    /// Whether `stream` is the release the party is watching.
    func matches(_ stream: Stream) -> Bool {
        matches(
            infoHash: stream.effectiveInfoHash,
            fileIdx: stream.fileIdx,
            filename: stream.behaviorHints?.filename
        )
    }

    /// The rule itself, over the three values that decide it.
    ///
    /// `fileIdx` only narrows a match: one torrent carries a season, and the hash alone cannot
    /// say which episode. But an index is often absent on one side, and treating that as a
    /// mismatch would reject the very file it describes — so it disqualifies only when **both**
    /// sides state one and they differ.
    func matches(infoHash: String?, fileIdx: Int?, filename: String?) -> Bool {
        let ours = self.infoHash?.trimmed.lowercased().nilIfBlank
        let theirs = infoHash?.trimmed.lowercased().nilIfBlank
        if let ours, let theirs {
            guard ours == theirs else { return false }
            guard let mine = self.fileIdx, let other = fileIdx else { return true }
            return mine == other
        }

        // Filenames come from addons, debrid providers and URLs alike, so they agree on the name
        // and not on its case.
        guard let expected = self.filename?.trimmed.nilIfBlank,
              let candidate = filename?.trimmed.nilIfBlank
        else { return false }
        return expected.caseInsensitiveCompare(candidate) == .orderedSame
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
