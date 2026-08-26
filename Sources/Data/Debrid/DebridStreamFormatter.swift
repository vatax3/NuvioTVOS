import Foundation

/// Turns a stream into the values a template can name, and renders the pair.
///
/// The field names are Android's, exactly, because the whole point of a template language here
/// is that a format written on the phone or the other TV app pastes in and produces the same
/// rows. A field renamed for tidiness would break that silently.
enum DebridStreamFormatter {
    struct Rendered: Equatable {
        var name: String
        var description: String

        var isEmpty: Bool {
            name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func render(
        stream: Stream,
        attributes: ParsedStreamAttributes?,
        service: DebridProvider?,
        isCached: Bool?,
        templates: DebridStreamTemplates
    ) -> Rendered {
        let values = values(
            stream: stream, attributes: attributes, service: service, isCached: isCached
        )
        return Rendered(
            name: DebridStreamTemplate.render(templates.name, values: values),
            description: DebridStreamTemplate.render(templates.description, values: values)
        )
    }

    /// Everything a template may reference. Absent fields resolve to `.absent`, which every
    /// operator treats as false or empty, so a template naming a field this stream lacks
    /// silently contributes nothing rather than printing a placeholder.
    static func values(
        stream: Stream,
        attributes: ParsedStreamAttributes?,
        service: DebridProvider?,
        isCached: Bool?
    ) -> [String: DebridTemplateValue] {
        let parsed = attributes ?? StreamAttributeParser.parse(stream)
        let title = stream.title?.nilIfBlank ?? stream.name?.nilIfBlank

        var values: [String: DebridTemplateValue] = [
            "stream.title": DebridTemplateValue(title),
            "stream.resolution": DebridTemplateValue(parsed.resolution.labelUnlessUnknown),
            "stream.quality": DebridTemplateValue(parsed.quality.labelUnlessUnknown),
            "stream.encode": DebridTemplateValue(parsed.encode.labelUnlessUnknown),
            "stream.visualTags": DebridTemplateValue(parsed.visualTags.compactMap(\.labelUnlessUnknown)),
            "stream.audioTags": DebridTemplateValue(parsed.audioTags.compactMap(\.labelUnlessUnknown)),
            "stream.audioChannels": DebridTemplateValue(parsed.audioChannels.compactMap(\.labelUnlessUnknown)),
            "stream.languages": DebridTemplateValue(parsed.languages.compactMap(\.labelUnlessUnknown)),
            "stream.releaseGroup": DebridTemplateValue(parsed.releaseGroup?.nilIfBlank),
            "stream.filename": DebridTemplateValue(
                stream.behaviorHints?.filename?.nilIfBlank ?? stream.description?.nilIfBlank
            ),
            "stream.type": .text(stream.isTorrent ? "torrent" : "http"),
            "addon.name": .text(stream.addonName)
        ]

        if let size = parsed.sizeBytes ?? stream.behaviorHints?.videoSize, size > 0 {
            values["stream.size"] = .bytes(size)
        }
        if let year = year(in: title) {
            values["stream.year"] = .number(Double(year))
        }
        if let service {
            values["service.name"] = .text(service.displayName)
            values["service.shortName"] = .text(service.shortName)
        }
        if let isCached {
            values["service.cached"] = .flag(isCached)
        }
        return values
    }

    /// A four-digit year in the release title, which is where addons put it — the metadata that
    /// would carry it properly is on the title, not the stream.
    private static func year(in title: String?) -> Int? {
        guard let title else { return nil }
        var digits = ""
        for character in title {
            if character.isNumber {
                digits.append(character)
                if digits.count == 4 {
                    if let value = Int(digits), (1900...2100).contains(value) { return value }
                    digits.removeFirst()
                }
            } else {
                digits = ""
            }
        }
        return nil
    }
}

/// The two templates, stored together because they are edited together.
struct DebridStreamTemplates: Codable, Hashable, Sendable {
    var name: String
    var description: String

    static let `default` = DebridStreamTemplates(
        name: DebridStreamTemplate.defaultName,
        description: DebridStreamTemplate.defaultDescription
    )

    /// A blank field means "use the shipped one" rather than "print nothing": an editor that
    /// can empty a row must not be able to empty every stream row on the television.
    var resolved: DebridStreamTemplates {
        DebridStreamTemplates(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? DebridStreamTemplate.defaultName : name,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? DebridStreamTemplate.defaultDescription : description
        )
    }
}
