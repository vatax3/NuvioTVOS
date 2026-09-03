import Foundation

/// `episode_options_overlay_style`: what sits behind the episode options dialog.
///
/// Ported from upstream 0.8.12. The dialog itself shipped here in 1.0.29; this is the appearance
/// control that arrived with it upstream and did not come across.
enum EpisodeOptionsOverlayStyle: String, SettingsOption {
    /// A plain scrim. The cheapest, and the only one that never fights the dialog for attention.
    case none = "NONE"
    /// The episode still behind the dialog, dimmed.
    case artwork = "ARTWORK"
    /// The same still, blurred — upstream's default, and ours.
    case blur = "BLUR"

    var displayName: String {
        switch self {
        case .none: return L10n.text("settings.layout.episode_overlay_none", fallback: "None")
        case .artwork: return L10n.text("settings.layout.episode_overlay_artwork", fallback: "Artwork")
        case .blur: return L10n.text("settings.layout.episode_overlay_blur", fallback: "Blur")
        }
    }

    var subtitle: String {
        switch self {
        case .none:
            return L10n.text("settings.layout.episode_overlay_none_sub", fallback: "A plain dimmed background.")
        case .artwork:
            return L10n.text("settings.layout.episode_overlay_artwork_sub", fallback: "Show the episode still behind the options.")
        case .blur:
            return L10n.text("settings.layout.episode_overlay_blur_sub", fallback: "Show the episode still, blurred.")
        }
    }
}
