#if DEBUG
import Foundation

/// Stages a household with a locked profile in it.
///
/// The PIN screens need a second profile with a PIN on it, which means they are only ever seen
/// after setting one up by hand — so "the PIN pad runs off the edge of the screen" was reported
/// from a sofa and had no test able to see it. What is wrong there is pure layout at 1920×1080:
/// nothing below the view layer can observe it, and nothing above it can either until the screen
/// is actually on screen. Compiled out of release builds; inert without the launch argument.
enum ProfileHarness {
    static let launchArgument = "-nuvioProfileHarness"

    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// A primary and one locked profile — the smallest household that reaches the PIN challenge.
    /// The hash is a real SHA-256 of "1234", so the staged PIN is the one the test types.
    static var profiles: [Profile] {
        [
            Profile(
                id: ProfileScope.primaryProfileId,
                name: "Me",
                symbol: "person.fill",
                tintHex: "#E50914",
                pinHash: nil,
                isRestricted: false,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                remoteIndex: 1
            ),
            Profile(
                id: "harness.locked",
                name: "Alex",
                symbol: "figure.child",
                tintHex: "#1E88E5",
                pinHash: ProfileStore.hash("1234"),
                isRestricted: false,
                createdAt: Date(timeIntervalSince1970: 1_700_000_001),
                remoteIndex: 2
            )
        ]
    }
}
#endif
