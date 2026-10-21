// swift-tools-version: 6.1

import PackageDescription

// The dynamic framework AetherEngine is linked into, and the only thing the app target links.
//
// Two problems, one wrapper. The app executable statically links mpv's FFmpeg (the
// `Vendor/Libav*.xcframework` archives are `ar` archives, linked with `embed: false`), so
// `_avcodec_open2` and friends are definitions *inside* the executable. An AetherEngine linked
// into the same target would bind to those instead of to its own FFmpeg and then run against
// struct layouts and a codec set it was never compiled for — AetherEngine's AE#396, which was
// reported as an audio-bridge defect and reproduced on five fixtures before anyone looked at the
// link. Declaring this product `.dynamic` resolves the engine's `_av*` references when *this*
// framework links, against `AetherLibavcodec`, and Mach-O's two-level namespace records that
// origin per reference. Whatever the executable defines for mpv no longer participates.
//
// The second problem is that XcodeGen drops a `traits:` key on a package without a word
// (through 2.46.0), so the optional components could not be asked for from project.yml at all.
// Here they are ordinary manifest code.
//
// Pinned to the minor deliberately. The engine ships a prebuilt decode stack, and its own
// manifest pins FFmpegBuild to a minor for the same reason: a floating minor silently changes
// which FFmpeg a released tag runs.
let package = Package(
    name: "PlayerEngineKit",
    platforms: [.tvOS(.v18)],
    products: [
        .library(name: "PlayerEngineKit", type: .dynamic, targets: ["PlayerEngineKit"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/superuser404notfound/AetherEngine",
            "7.44.0" ..< "7.45.0",
            // TrueHD Atmos objects rendered to APAC, and DTS:X heights unfolded to 7.1.4.
            // Not DualLayerDolbyVision: the Profile 7 FEL route runs on the software host and
            // plays a JOC track as its bed *without the objects*, which trades away the Atmos
            // this integration exists for.
            traits: ["TrueHDObjectAudio", "DTSXObjectAudio"]
        ),
    ],
    targets: [
        .target(
            name: "PlayerEngineKit",
            dependencies: [.product(name: "AetherEngine", package: "AetherEngine")]
        ),
    ]
)
