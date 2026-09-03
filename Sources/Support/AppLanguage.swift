import Foundation

/// The interface language, chosen in the app rather than taken from the television.
///
/// This was recorded as a platform constraint and it was not one. tvOS does take its language
/// from Settings, which is true and beside the point: the Android app it is matched against has
/// a picker in its own settings, so a viewer there can run the interface in English on a German
/// television. Filed under *Forced* by mistake until a second, independent tvOS port of the same
/// app was found to have ported it.
///
/// Only the languages actually shipped are offered. Upstream lists 34 because it has 34 tables;
/// offering a language with no table would give a picker that changes nothing.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system = ""
    case english = "en"
    case french = "fr"

    var id: String { rawValue }

    /// Named in its own language, as every language picker worth using does: somebody looking
    /// for French is looking for the word "Français".
    var displayName: String {
        switch self {
        case .system: return L10n.text("settings.language.system", fallback: "System")
        case .english: return "English"
        case .french: return "Français"
        }
    }

    static func from(_ raw: String?) -> AppLanguage {
        AppLanguage(rawValue: raw ?? "") ?? .system
    }
}

extension L10n {
    /// The table lookups resolve against, replaced when the viewer picks a language.
    ///
    /// Upstream overrides `AppleLanguages` and restarts the activity. A tvOS app cannot restart
    /// itself, so the bundle is swapped instead and the view tree is rebuilt on the setting —
    /// which changes the language in place, with no relaunch to explain to anybody.
    nonisolated(unsafe) private static var table: Bundle = .main

    static func use(_ language: AppLanguage) {
        guard language != .system,
              let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else {
            table = .main
            return
        }
        table = bundle
    }

    static func text(_ key: String, fallback: String? = nil) -> String {
        NSLocalizedString(key, bundle: table, value: fallback ?? key, comment: "")
    }

    static func format(_ key: String, fallback: String, _ arguments: CVarArg...) -> String {
        String(format: text(key, fallback: fallback), locale: .current, arguments: arguments)
    }
}
