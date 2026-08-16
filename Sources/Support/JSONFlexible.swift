import Foundation

// Stremio addons are famously loose with their JSON: `director` may be a string or an
// array, `imdbRating` a string or a number, `extra` an array of objects or of bare
// strings. These wrappers mirror the tolerance the Android app gets from its Moshi
// adapters so a single sloppy addon cannot blank out a whole catalog.

/// Decodes a value that may be a single string or an array of strings, dropping blanks.
@propertyWrapper
struct FlexibleStringArray: Codable, Hashable, Sendable {
    var wrappedValue: [String]

    init(wrappedValue: [String] = []) { self.wrappedValue = wrappedValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            wrappedValue = []
        } else if let single = try? container.decode(String.self) {
            wrappedValue = single.splitCommaSeparated()
        } else if let list = try? container.decode([String].self) {
            wrappedValue = list.flatMap { $0.splitCommaSeparated() }
        } else if let mixed = try? container.decode([FlexibleScalar].self) {
            wrappedValue = mixed.compactMap(\.stringValue).flatMap { $0.splitCommaSeparated() }
        } else {
            wrappedValue = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

// Swift's synthesised `init(from:)` decodes a property-wrapped field with `decode(_:forKey:)`,
// which throws `keyNotFound` when the key is absent — only `Optional` fields get the
// `decodeIfPresent` treatment. Most catalog entries omit `director`/`writer`/`cast` entirely,
// so without this overload one missing key would fail the whole meta.
extension KeyedDecodingContainer {
    func decode(_ type: FlexibleStringArray.Type, forKey key: Key) throws -> FlexibleStringArray {
        guard let value = try? decodeIfPresent(type, forKey: key) else {
            return FlexibleStringArray(wrappedValue: [])
        }
        return value
    }
}

/// Element wrapper that swallows per-item decode failures so one malformed entry cannot
/// wipe out an entire catalog, stream list or subtitle list. Decoding never throws, which
/// also keeps the unkeyed container's index advancing correctly.
struct Failable<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

extension Array {
    /// Unwraps a `[Failable<T>]` into the entries that actually decoded.
    func compacted<T>() -> [T] where Element == Failable<T> {
        compactMap(\.value)
    }
}

/// Decodes a numeric-ish value that may arrive as a string, an int or a double.
struct FlexibleScalar: Codable, Hashable, Sendable {
    let stringValue: String?
    let doubleValue: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            stringValue = s
            doubleValue = Double(s.filter { $0.isNumber || $0 == "." || $0 == "-" })
        } else if let d = try? container.decode(Double.self) {
            doubleValue = d
            stringValue = String(d)
        } else if let i = try? container.decode(Int.self) {
            doubleValue = Double(i)
            stringValue = String(i)
        } else if let b = try? container.decode(Bool.self) {
            doubleValue = b ? 1 : 0
            stringValue = String(b)
        } else {
            stringValue = nil
            doubleValue = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let stringValue { try container.encode(stringValue) } else { try container.encodeNil() }
    }
}

/// A `Bool` that tolerates `"true"` / `1` encodings.
struct FlexibleBool: Codable, Hashable, Sendable {
    let value: Bool?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let b = try? container.decode(Bool.self) {
            value = b
        } else if let s = try? container.decode(String.self) {
            value = ["true", "1", "yes"].contains(s.lowercased())
        } else if let i = try? container.decode(Int.self) {
            value = i != 0
        } else {
            value = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// An `Int` that tolerates string encodings.
struct FlexibleInt: Codable, Hashable, Sendable {
    let value: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let i = try? container.decode(Int.self) {
            value = i
        } else if let d = try? container.decode(Double.self) {
            value = Int(d)
        } else if let s = try? container.decode(String.self) {
            value = Int(s.trimmingCharacters(in: .whitespaces))
        } else {
            value = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// An `Int64` that tolerates string encodings (stream `videoSize`, manifest timestamps).
struct FlexibleInt64: Codable, Hashable, Sendable {
    let value: Int64?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let i = try? container.decode(Int64.self) {
            value = i
        } else if let d = try? container.decode(Double.self) {
            value = Int64(d)
        } else if let s = try? container.decode(String.self) {
            value = Int64(s.trimmingCharacters(in: .whitespaces))
        } else {
            value = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// Tolerant free-form JSON, used where an addon may nest arbitrary structures.
enum AnyJSON: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: AnyJSON])
    case array([AnyJSON])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let v = try? container.decode(Bool.self) { self = .bool(v) }
        else if let v = try? container.decode(Double.self) { self = .number(v) }
        else if let v = try? container.decode(String.self) { self = .string(v) }
        else if let v = try? container.decode([AnyJSON].self) { self = .array(v) }
        else if let v = try? container.decode([String: AnyJSON].self) { self = .object(v) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .number(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let v): return v
        case .number(let v): return v == v.rounded() ? String(Int(v)) : String(v)
        case .bool(let v): return String(v)
        default: return nil
        }
    }

    var objectValue: [String: AnyJSON]? {
        if case .object(let v) = self { return v }
        return nil
    }

    var arrayValue: [AnyJSON]? {
        if case .array(let v) = self { return v }
        return nil
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let v): return v
        case .number(let v): return v != 0
        case .string(let v): return ["true", "1", "yes"].contains(v.lowercased())
        default: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .number(let v): return Int(v)
        case .string(let v): return Int(v.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }
}

extension String {
    /// Splits the comma-joined lists some addons use for `cast` / `director`.
    func splitCommaSeparated() -> [String] {
        split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
