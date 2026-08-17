import Foundation

/// Port of the catalog-presentation preferences: how a rail is titled, whether unreleased
/// titles are hidden, and how release dates are formatted. Bundled so screens can pass one
/// value around instead of reaching into `LayoutSettingsStore` from every call site.
struct CatalogPresentation: Equatable {
    var showsAddonName: Bool = true
    var showsTypeSuffix: Bool = false
    var customTitles: [String: String] = [:]
    var hidesUnreleased: Bool = false
    var showsFullReleaseDate: Bool = false

    static let `default` = CatalogPresentation()

    /// Key a viewer's renamed catalog is stored under — matches the Android map key.
    static func titleKey(addonBaseUrl: String, descriptorKey: String) -> String {
        "\(addonBaseUrl)#\(descriptorKey)"
    }

    func title(addon: Addon, descriptor: CatalogDescriptor) -> String {
        let key = Self.titleKey(addonBaseUrl: addon.baseUrl, descriptorKey: descriptor.descriptorKey)
        var name = customTitles[key]?.nilIfBlank ?? descriptor.name
        if showsTypeSuffix, let suffix = typeSuffix(for: descriptor.apiType) {
            name += " \(suffix)"
        }
        return name
    }

    func subtitle(addon: Addon) -> String? {
        showsAddonName ? addon.displayName : nil
    }

    private func typeSuffix(for apiType: String) -> String? {
        switch apiType.lowercased() {
        case "movie": return "Movies"
        case "series": return "Series"
        case "channel": return "Channels"
        case "tv": return "TV"
        case "anime": return "Anime"
        default: return apiType.isEmpty ? nil : apiType.capitalized
        }
    }

    /// Drops titles whose release date is still in the future, when the viewer asked for it.
    func filter(_ items: [MetaPreview]) -> [MetaPreview] {
        guard hidesUnreleased else { return items }
        return items.filter { $0.isReleased }
    }
}

extension MetaPreview {
    /// A title counts as released unless it carries a parseable future date. Anything the
    /// addon left vague stays visible — hiding on a guess would be worse than showing it.
    var isReleased: Bool {
        if let date = releaseDate {
            return date <= Date()
        }
        // `releaseInfo` is often a bare year or a range like "2019–"; a future year is the
        // only signal worth acting on.
        if let year = leadingYear, year > Calendar.current.component(.year, from: Date()) {
            return false
        }
        return true
    }

    var releaseDate: Date? {
        guard let released, !released.isEmpty else { return nil }
        return VideoDateParser.parse(released)
    }

    private var leadingYear: Int? {
        guard let info = releaseInfo?.nilIfBlank else { return nil }
        let digits = info.prefix(while: { $0.isNumber })
        guard digits.count == 4 else { return nil }
        return Int(digits)
    }

    /// Metadata-row label: either the bare year or the full date, per `show_full_release_date`.
    func releaseLabel(fullDate: Bool) -> String? {
        guard fullDate, let date = releaseDate else { return releaseInfo?.nilIfBlank }
        return DateFormatter.nuvioMediumDate.string(from: date)
    }
}

extension DateFormatter {
    static let nuvioMediumDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
