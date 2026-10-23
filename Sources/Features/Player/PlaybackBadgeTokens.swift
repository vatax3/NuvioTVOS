import Foundation

/// Everything a badge rule could be looking for in what is playing right now.
///
/// Badge packs are written for upstream's Android app and match against a *stream's* text — a
/// release name carrying "2160p.HEVC.DV.DDP.Atmos". During playback there is no release name:
/// there is what the engine reports about the file it opened. This builds the equivalent text
/// from that, so an imported pack matches the same things it was written to match.
///
/// The spellings are upstream's `playbackMatchText`, deliberately and to the letter. They are not
/// a presentation choice — they are the **vocabulary packs are authored in**. A pack looks for
/// `H.265`, `x265`, `DDP`, `DTS-HD MA`, `DV`; emitting only `HEVC` and `E-AC-3` would match none
/// of them and the feature would look broken rather than empty. This is the same argument that
/// made 1.0.23 adopt their file format unchanged.
///
/// Pure, and outside any `canImport` of the engine packages, so it is testable on its own.
func playbackBadgeTokens(_ info: PlayerStreamInfo, languages: [String] = []) -> [String] {
    var out: [String] = []
    out += resolutionTokens(width: info.videoWidth, height: info.videoHeight)
    out += videoCodecTokens(info.videoCodec)

    // **Both** range strings, because a Dolby Vision profile 8.1 file reads as plain PQ in the
    // source colorimetry — its base layer *is* HDR10 — and is named as Dolby Vision only in what
    // the engine says it is presenting. Reading `sourceRange` alone would badge every DV file
    // HDR10 and never DV. Upstream has a curated `hdr` list here and no equivalent problem.
    //
    // Matched on whole words: `dv` as a substring hits "advanced", and these strings are free
    // text composed for the information panel rather than a vocabulary.
    let range = [info.sourceRange, info.outputRange]
        .compactMap { $0?.lowercased() }.joined(separator: " ")
    if range.contains("dolby vision") || range.contains("dovi") {
        out += ["DV", "DoVi", "Dolby Vision"]
    }
    if range.contains("hdr10") || range.contains("pq") || range.contains("smpte2084") {
        out += ["HDR", "HDR10"]
    }
    if range.contains("hlg") || range.contains("arib") { out += ["HDR", "HLG"] }

    // Upstream assumes 10-bit for an HDR file whose depth the container did not state, because
    // HDR8 does not exist in practice. Same assumption, same reason.
    if let depth = info.bitDepth ?? (out.contains("HDR") ? 10 : nil) { out.append("\(depth)bit") }

    out += audioCodecTokens(info.audioCodec)
    if let channels = channelsToken(info.audioChannelCount) { out.append(channels) }
    out += languages

    // One joined candidate as well: a pattern like `2160p.*ATMOS` is written expecting a single
    // release name, and here the two facts arrive as separate tokens. Same reasoning as
    // `StreamBadgeMatcher.candidates(for:)`, which joins for exactly this case.
    var seen = Set<String>()
    let unique = out.filter { !$0.isEmpty && seen.insert($0).inserted }
    guard unique.count > 1 else { return unique }
    return unique + [unique.joined(separator: " ")]
}

private func resolutionTokens(width: Int?, height: Int?) -> [String] {
    guard let width, let height, width > 0, height > 0 else { return [] }
    switch true {
    case width >= 3800 || height >= 2100: return ["2160p", "4K", "UHD"]
    case width >= 2500 || height >= 1400: return ["1440p", "2K"]
    case width >= 1900 || height >= 1000: return ["1080p", "FHD"]
    case width >= 1260 || height >= 700: return ["720p"]
    default: return ["\(height)p", "SD"]
    }
}

private func videoCodecTokens(_ codec: String?) -> [String] {
    guard let codec = codec?.nilIfBlank else { return [] }
    switch codec.uppercased() {
    case let name where name.contains("HEVC") || name.contains("H265") || name.contains("DOLBY VISION"):
        return ["HEVC", "H.265", "H265", "x265"]
    case let name where name.contains("AVC") || name.contains("H264"):
        return ["AVC", "H.264", "H264", "x264"]
    case let name where name.contains("AV1"):
        return ["AV1"]
    default:
        return [codec]
    }
}

/// Our `audioCodec` already carries the profile, because `AetherEngineAdapter` writes
/// `"E-AC-3 · Atmos"` into the one field where upstream keeps codec and profile apart. Matching
/// on the whole string covers both shapes.
private func audioCodecTokens(_ codec: String?) -> [String] {
    guard let codec = codec?.nilIfBlank else { return [] }
    let label = codec.uppercased()
    var out: [String] = []

    if label.contains("E-AC-3") || label.contains("EAC3") {
        out += ["DD+", "DDP", "EAC3"]
    } else if label.contains("AC-3") || label.contains("AC3") {
        out += ["DD", "AC3"]
    } else if label.contains("TRUEHD") {
        out += ["TrueHD"]
    } else if label.contains("DTS") {
        out.append("DTS")
        if label.contains("HD") { out.append("DTS-HD") }
        if label.contains("MA") { out.append("DTS-HD MA") }
        if label.contains("DTS:X") || label.contains("DTSX") { out.append("DTS:X") }
    } else {
        out.append(codec)
    }

    if label.contains("JOC") || label.contains("ATMOS") { out.append("Atmos") }
    return out
}

private func channelsToken(_ channels: Int?) -> String? {
    switch channels {
    case 1: return "1.0"
    case 2: return "2.0"
    case 6: return "5.1"
    case 8: return "7.1"
    default: return nil
    }
}
