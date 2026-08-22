import Foundation

/// Every field of `TmdbCollectionFilters`, as something a settings screen can enumerate.
///
/// The collection editor used to expose three of the eighteen. The other fifteen survived a sync
/// round trip untouched — which is the important half — but a collection built on Android could
/// not be *adjusted* here without silently losing the ability to see what it was filtering on.
/// Describing the fields once, in one place, is what lets the editor draw all of them without
/// eighteen bindings and an eighteen-arm assignment that would drift out of step.
enum TmdbFilterField: String, CaseIterable, Identifiable, Hashable, Sendable {
    case withGenres, withoutGenres
    case year, releaseDateGte, releaseDateLte
    case voteAverageGte, voteAverageLte, voteCountGte
    case withOriginalLanguage, withOriginCountry
    case withKeywords, withoutKeywords
    case withCompanies, withoutCompanies, withNetworks
    case watchRegion, withWatchProviders, withoutWatchProviders

    var id: String { rawValue }

    enum Group: String, CaseIterable, Identifiable {
        case genres, dates, ratings, origin, keywords, companies, providers

        var id: String { rawValue }

        var title: String {
            switch self {
            case .genres: return "Genres"
            case .dates: return "Dates"
            case .ratings: return "Ratings"
            case .origin: return "Language and origin"
            case .keywords: return "Keywords"
            case .companies: return "Studios and networks"
            case .providers: return "Streaming providers"
            }
        }

        var footnote: String? {
            switch self {
            case .genres:
                return "TMDB genre ids, comma separated. 28 is Action, 35 Comedy, 27 Horror."
            case .dates:
                return "Year is a shortcut for a whole calendar year; the two date bounds are ISO dates and win where both are set."
            case .providers:
                return "Watch region is a two-letter country code, and TMDB ignores provider ids without one."
            case .ratings, .origin, .keywords, .companies:
                return nil
            }
        }
    }

    var group: Group {
        switch self {
        case .withGenres, .withoutGenres: return .genres
        case .year, .releaseDateGte, .releaseDateLte: return .dates
        case .voteAverageGte, .voteAverageLte, .voteCountGte: return .ratings
        case .withOriginalLanguage, .withOriginCountry: return .origin
        case .withKeywords, .withoutKeywords: return .keywords
        case .withCompanies, .withoutCompanies, .withNetworks: return .companies
        case .watchRegion, .withWatchProviders, .withoutWatchProviders: return .providers
        }
    }

    var title: String {
        switch self {
        case .withGenres: return "Include genres"
        case .withoutGenres: return "Exclude genres"
        case .year: return "Year"
        case .releaseDateGte: return "Released on or after"
        case .releaseDateLte: return "Released on or before"
        case .voteAverageGte: return "Minimum rating"
        case .voteAverageLte: return "Maximum rating"
        case .voteCountGte: return "Minimum number of votes"
        case .withOriginalLanguage: return "Original language"
        case .withOriginCountry: return "Country of origin"
        case .withKeywords: return "Include keywords"
        case .withoutKeywords: return "Exclude keywords"
        case .withCompanies: return "Include studios"
        case .withoutCompanies: return "Exclude studios"
        case .withNetworks: return "Networks"
        case .watchRegion: return "Watch region"
        case .withWatchProviders: return "Include providers"
        case .withoutWatchProviders: return "Exclude providers"
        }
    }

    var hint: String? {
        switch self {
        case .voteCountGte:
            return "Keeps obscure titles with one glowing review out of the results"
        case .withOriginalLanguage:
            return "ISO 639-1, e.g. ja for Japanese"
        case .withOriginCountry, .watchRegion:
            return "ISO 3166-1, e.g. FR"
        case .withKeywords, .withoutKeywords, .withCompanies, .withoutCompanies,
             .withNetworks, .withWatchProviders, .withoutWatchProviders:
            return "TMDB ids, comma separated"
        default:
            return nil
        }
    }

    var placeholder: String {
        switch self {
        case .withGenres, .withoutGenres: return "28,12"
        case .year: return "2024"
        case .releaseDateGte, .releaseDateLte: return "2020-01-01"
        case .voteAverageGte: return "7.5"
        case .voteAverageLte: return "9.5"
        case .voteCountGte: return "500"
        case .withOriginalLanguage: return "ja"
        case .withOriginCountry, .watchRegion: return "FR"
        default: return "123,456"
        }
    }

    /// Reads the field out of a stored filter set, so an existing source can be edited rather
    /// than only created.
    func text(in filters: TmdbCollectionFilters) -> String {
        switch self {
        case .withGenres: return filters.withGenres ?? ""
        case .withoutGenres: return filters.withoutGenres ?? ""
        case .year: return filters.year.map(String.init) ?? ""
        case .releaseDateGte: return filters.releaseDateGte ?? ""
        case .releaseDateLte: return filters.releaseDateLte ?? ""
        case .voteAverageGte: return filters.voteAverageGte.map { String($0) } ?? ""
        case .voteAverageLte: return filters.voteAverageLte.map { String($0) } ?? ""
        case .voteCountGte: return filters.voteCountGte.map(String.init) ?? ""
        case .withOriginalLanguage: return filters.withOriginalLanguage ?? ""
        case .withOriginCountry: return filters.withOriginCountry ?? ""
        case .withKeywords: return filters.withKeywords ?? ""
        case .withoutKeywords: return filters.withoutKeywords ?? ""
        case .withCompanies: return filters.withCompanies ?? ""
        case .withoutCompanies: return filters.withoutCompanies ?? ""
        case .withNetworks: return filters.withNetworks ?? ""
        case .watchRegion: return filters.watchRegion ?? ""
        case .withWatchProviders: return filters.withWatchProviders ?? ""
        case .withoutWatchProviders: return filters.withoutWatchProviders ?? ""
        }
    }

    /// Writes one typed box back. A blank box clears the field rather than storing `""`, so an
    /// emptied filter leaves the payload the way the other apps write it — absent.
    func apply(_ text: String, to filters: inout TmdbCollectionFilters) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        switch self {
        case .withGenres: filters.withGenres = value
        case .withoutGenres: filters.withoutGenres = value
        case .year: filters.year = value.flatMap(Int.init)
        case .releaseDateGte: filters.releaseDateGte = value
        case .releaseDateLte: filters.releaseDateLte = value
        case .voteAverageGte: filters.voteAverageGte = value.flatMap(Double.init)
        case .voteAverageLte: filters.voteAverageLte = value.flatMap(Double.init)
        case .voteCountGte: filters.voteCountGte = value.flatMap(Int.init)
        case .withOriginalLanguage: filters.withOriginalLanguage = value
        case .withOriginCountry: filters.withOriginCountry = value
        case .withKeywords: filters.withKeywords = value
        case .withoutKeywords: filters.withoutKeywords = value
        case .withCompanies: filters.withCompanies = value
        case .withoutCompanies: filters.withoutCompanies = value
        case .withNetworks: filters.withNetworks = value
        case .watchRegion: filters.watchRegion = value
        case .withWatchProviders: filters.withWatchProviders = value
        case .withoutWatchProviders: filters.withoutWatchProviders = value
        }
    }
}
