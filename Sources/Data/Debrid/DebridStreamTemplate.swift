import Foundation

/// A value a template can name. Modelled rather than left as `Any` because the DSL's operators
/// behave differently per shape — `exists` on a list means "not empty", on a string means "not
/// blank", and `bytes` only means anything on a number.
enum DebridTemplateValue: Equatable, Sendable {
    case text(String)
    case number(Double)
    /// A byte count, which the `bytes` transform renders and which counts as a number elsewhere.
    case bytes(Int64)
    case flag(Bool)
    case list([String])
    case absent

    init(_ text: String?) { self = text.map { .text($0) } ?? .absent }
    init(_ number: Int?) { self = number.map { .number(Double($0)) } ?? .absent }
    init(_ list: [String]) { self = list.isEmpty ? .absent : .list(list) }
}

/// The stream name and description templates, ported from `DebridStreamTemplateEngine.kt`.
///
/// A small expression language, and the only reason to have one is that it is Android's: a
/// viewer who wrote a format on the phone or the TV app should be able to paste it here and get
/// the same rows out. So the grammar is reproduced rather than improved on.
///
/// ```
/// {stream.resolution::=2160p["4K "||""]}{stream.size::>0["{stream.size::bytes} "||""]}
/// ```
///
/// A placeholder is either a **condition with two branches** — `condition[ "yes" || "no" ]`,
/// where each branch is itself a template — or a **field followed by transforms**, separated by
/// `::`. Everything is quote-aware, so a separator inside `join(' | ')` does not split anything.
enum DebridStreamTemplate {
    // MARK: Rendering

    static func render(_ template: String, values: [String: DebridTemplateValue]) -> String {
        guard !template.isEmpty else { return "" }
        var out = ""
        var index = template.startIndex

        while index < template.endIndex {
            guard let start = template[index...].firstIndex(of: "{") else {
                out += template[index...]
                break
            }
            out += template[index..<start]
            guard let end = placeholderEnd(template, from: template.index(after: start)) else {
                // An unbalanced brace is the viewer mid-edit, not a failure: show it as typed.
                out += template[start...]
                break
            }
            out += renderExpression(String(template[template.index(after: start)..<end]), values: values)
            index = template.index(after: end)
        }
        return out
    }

    private static func renderExpression(_ expression: String, values: [String: DebridTemplateValue]) -> String {
        if let bracket = topLevelIndex(of: "[", in: expression), expression.hasSuffix("]") {
            let condition = String(expression[expression.startIndex..<bracket])
            let body = String(expression[expression.index(after: bracket)..<expression.index(before: expression.endIndex)])
            let branches = parseBranches(body)
            // Each branch is a template in its own right, so a placeholder can nest inside one.
            return render(evaluate(condition, values) ? branches.taken : branches.otherwise, values: values)
        }

        let tokens = splitOperators(expression)
        guard let field = tokens.first else { return "" }
        var value = values[field] ?? .absent
        for op in tokens.dropFirst() { value = transform(value, op) }
        return text(of: value)
    }

    // MARK: Conditions

    /// `and` binds tighter than `or`: the tokens are cut into `or` groups, and a group passes
    /// only if every test in it does.
    private static func evaluate(_ expression: String, _ values: [String: DebridTemplateValue]) -> Bool {
        let tokens = splitOperators(expression).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return false }

        var groups: [[Bool]] = []
        var current: [Bool] = []
        var index = 0

        while index < tokens.count {
            switch tokens[index] {
            case "or":
                groups.append(current)
                current = []
                index += 1
            case "and":
                index += 1
            default:
                let field = tokens[index]
                index += 1
                var ops: [String] = []
                while index < tokens.count, tokens[index] != "and", tokens[index] != "or",
                      !isFieldPath(tokens[index]) {
                    ops.append(tokens[index])
                    index += 1
                }
                current.append(test(values[field] ?? .absent, ops))
            }
        }
        groups.append(current)
        return groups.contains { !$0.isEmpty && $0.allSatisfy { $0 } }
    }

    private static func test(_ value: DebridTemplateValue, _ ops: [String]) -> Bool {
        guard !ops.isEmpty else { return isTruthy(value) }
        var result = false
        var decided = false

        for op in ops {
            if op == "exists" {
                result = exists(value)
            } else if op == "istrue" {
                result = decided ? result : (asFlag(value) == true)
            } else if op == "isfalse" {
                result = decided ? !result : (asFlag(value) == false)
            } else if op.hasPrefix("~=") {
                result = contains(value, String(op.dropFirst(2)))
            } else if op.hasPrefix("~") {
                result = contains(value, String(op.dropFirst(1)))
            } else if op.hasPrefix(">=") {
                result = compare(value, op.dropFirst(2)) { $0 >= $1 }
            } else if op.hasPrefix("<=") {
                result = compare(value, op.dropFirst(2)) { $0 <= $1 }
            } else if op.hasPrefix(">") {
                result = compare(value, op.dropFirst(1)) { $0 > $1 }
            } else if op.hasPrefix("<") {
                result = compare(value, op.dropFirst(1)) { $0 < $1 }
            } else if op.hasPrefix("=") {
                result = matches(value, String(op.dropFirst(1)))
            } else {
                continue
            }
            decided = true
        }
        return result
    }

    // MARK: Transforms

    private static func transform(_ value: DebridTemplateValue, _ op: String) -> DebridTemplateValue {
        switch true {
        case op == "title": return .text(titleCased(text(of: value)))
        case op == "lower": return .text(text(of: value).lowercased())
        case op == "upper": return .text(text(of: value).uppercased())
        case op == "bytes":
            guard let number = asNumber(value) else { return .text("") }
            return .text(formatBytes(number))
        case op == "time":
            guard let number = asNumber(value) else { return .text("") }
            return .text(formatDuration(number))
        case op.hasPrefix("join("):
            let separator = arguments(op).first ?? ", "
            guard case .list(let items) = value else { return .text(text(of: value)) }
            return .text(items.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .joined(separator: separator))
        case op.hasPrefix("replace("):
            let args = arguments(op)
            guard args.count >= 2 else { return .text(text(of: value)) }
            return .text(text(of: value).replacingOccurrences(of: args[0], with: args[1]))
        default: return value
        }
    }

    // MARK: Scanning
    //
    // Every scan below is quote-aware for the same reason: `join(' | ')` contains a separator
    // character, and a naive split would cut the template in half inside the viewer's own text.

    private static func placeholderEnd(_ text: String, from start: String.Index) -> String.Index? {
        var quote: Character?
        var index = start
        var previous: Character?

        while index < text.endIndex {
            let character = text[index]
            if let open = quote {
                if character == open, previous != "\\" { quote = nil }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == "}" {
                return index
            }
            previous = character
            index = text.index(after: index)
        }
        return nil
    }

    private static func topLevelIndex(of target: Character, in text: String) -> String.Index? {
        var quote: Character?
        var depth = 0
        var previous: Character?

        for index in text.indices {
            let character = text[index]
            if let open = quote {
                if character == open, previous != "\\" { quote = nil }
                previous = character
                continue
            }
            switch character {
            case "'", "\"": quote = character
            case "(": depth += 1
            case ")": depth = max(0, depth - 1)
            case target where depth == 0: return index
            default: break
            }
            previous = character
        }
        return nil
    }

    /// Splits on `::` outside quotes and parentheses.
    private static func splitOperators(_ text: String) -> [String] {
        var tokens: [String] = []
        var quote: Character?
        var depth = 0
        var start = text.startIndex
        var index = text.startIndex
        var previous: Character?

        while index < text.endIndex {
            let character = text[index]
            if let open = quote {
                if character == open, previous != "\\" { quote = nil }
                previous = character
                index = text.index(after: index)
                continue
            }
            switch character {
            case "'", "\"": quote = character
            case "(": depth += 1
            case ")": depth = max(0, depth - 1)
            case ":":
                let next = text.index(after: index)
                if depth == 0, next < text.endIndex, text[next] == ":" {
                    tokens.append(String(text[start..<index]).trimmingCharacters(in: .whitespaces))
                    index = text.index(after: next)
                    start = index
                    previous = nil
                    continue
                }
            default: break
            }
            previous = character
            index = text.index(after: index)
        }
        tokens.append(String(text[start...]).trimmingCharacters(in: .whitespaces))
        return tokens.filter { !$0.isEmpty }
    }

    private static func parseBranches(_ text: String) -> (taken: String, otherwise: String) {
        guard let separator = branchSeparator(text) else { return (unquoted(text), "") }
        let after = text.index(separator, offsetBy: 2)
        return (unquoted(String(text[text.startIndex..<separator])), unquoted(String(text[after...])))
    }

    private static func branchSeparator(_ text: String) -> String.Index? {
        var quote: Character?
        var previous: Character?

        for index in text.indices {
            let character = text[index]
            if let open = quote {
                if character == open, previous != "\\" { quote = nil }
                previous = character
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
            } else if character == "|" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "|" { return index }
            }
            previous = character
        }
        return nil
    }

    private static func arguments(_ op: String) -> [String] {
        guard let open = op.firstIndex(of: "("), let close = op.lastIndex(of: ")"), open < close else {
            return []
        }
        let body = String(op[op.index(after: open)..<close])
        var args: [String] = []
        var quote: Character?
        var start = body.startIndex
        var previous: Character?

        for index in body.indices {
            let character = body[index]
            if let openQuote = quote {
                if character == openQuote, previous != "\\" { quote = nil }
                previous = character
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
            } else if character == "," {
                args.append(unquoted(String(body[start..<index])))
                start = body.index(after: index)
            }
            previous = character
        }
        args.append(unquoted(String(body[start...])))
        return args
    }

    private static func unquoted(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2, let first = trimmed.first, let last = trimmed.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        return trimmed
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\'", with: "'")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func isFieldPath(_ token: String) -> Bool {
        token.hasPrefix("stream.") || token.hasPrefix("service.") || token.hasPrefix("addon.")
    }

    // MARK: Value semantics

    private static func exists(_ value: DebridTemplateValue) -> Bool {
        switch value {
        case .absent: return false
        case .text(let text): return !text.trimmingCharacters(in: .whitespaces).isEmpty
        case .list(let items): return !items.isEmpty
        case .number, .bytes, .flag: return true
        }
    }

    private static func isTruthy(_ value: DebridTemplateValue) -> Bool {
        switch value {
        case .flag(let flag): return flag
        case .number(let number): return number != 0
        case .bytes(let bytes): return bytes != 0
        default: return exists(value)
        }
    }

    private static func asFlag(_ value: DebridTemplateValue) -> Bool? {
        switch value {
        case .flag(let flag): return flag
        case .text(let text): return Bool(text.lowercased())
        default: return nil
        }
    }

    private static func asNumber(_ value: DebridTemplateValue) -> Double? {
        switch value {
        case .number(let number): return number
        case .bytes(let bytes): return Double(bytes)
        case .text(let text): return Double(text.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    private static func compare(
        _ value: DebridTemplateValue,
        _ rawTarget: Substring,
        _ isOrdered: (Double, Double) -> Bool
    ) -> Bool {
        guard let left = asNumber(value),
              let right = Double(rawTarget.trimmingCharacters(in: .whitespaces))
        else { return false }
        return isOrdered(left, right)
    }

    private static func matches(_ value: DebridTemplateValue, _ target: String) -> Bool {
        let wanted = target.trimmingCharacters(in: .whitespaces)
        if case .list(let items) = value {
            return items.contains { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(wanted) == .orderedSame }
        }
        return text(of: value).trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(wanted) == .orderedSame
    }

    private static func contains(_ value: DebridTemplateValue, _ target: String) -> Bool {
        let wanted = target.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return false }
        if case .list(let items) = value {
            return items.contains { $0.localizedCaseInsensitiveContains(wanted) }
        }
        return text(of: value).localizedCaseInsensitiveContains(wanted)
    }

    static func text(of value: DebridTemplateValue) -> String {
        switch value {
        case .absent: return ""
        case .text(let text): return text
        case .flag(let flag): return flag ? "true" : "false"
        case .bytes(let bytes): return formatBytes(Double(bytes))
        case .list(let items):
            return items.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: ", ")
        case .number(let number):
            return number.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int64(number))
                : String(number)
        }
    }

    // MARK: Formatting

    private static func titleCased(_ text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            guard let first = word.first else { return String(word) }
            return first.uppercased() + word.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    /// Binary units, matching Android — a 1.5 GB row on the phone must not read 1.6 GB here.
    static func formatBytes(_ value: Double) -> String {
        let magnitude = abs(value)
        guard magnitude >= 1024 else { return "\(Int64(value)) B" }

        let units = ["KB", "MB", "GB", "TB"]
        var current = magnitude
        var unit = -1
        while current >= 1024, unit < units.count - 1 {
            current /= 1024
            unit += 1
        }
        let signed = value < 0 ? -current : current
        return signed.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int64(signed)) \(units[unit])"
            : String(format: "%.1f %@", signed, units[unit])
    }

    static func formatDuration(_ value: Double) -> String {
        let seconds = Int(value)
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds % 60)s" }
        return "\(seconds % 60)s"
    }

    // MARK: Defaults

    /// Android's shipped templates, byte for byte, so a viewer who has never opened the editor
    /// sees the rows the other app draws.
    static let defaultName = #"{stream.resolution::=2160p["4K "||""]}{stream.resolution::=1440p["QHD "||""]}{stream.resolution::=1080p["FHD "||""]}{stream.resolution::=720p["HD "||""]}{stream.resolution::exists[""||"Direct "]}{service.shortName::exists["{service.shortName} "||"Debrid "]}Instant"#

    static let defaultDescription = #"{stream.title::exists["{stream.title::title} "||""]}{stream.year::exists["({stream.year})"||""]}\#n{stream.quality::exists["{stream.quality} "||""]}{stream.visualTags::exists["{stream.visualTags::join(' | ')} "||""]}{stream.encode::exists["{stream.encode} "||""]}\#n{stream.audioTags::exists["{stream.audioTags::join(' | ')}"||""]}{stream.audioTags::exists::and::stream.audioChannels::exists[" | "||""]}{stream.audioChannels::exists["{stream.audioChannels::join(' | ')}"||""]}\#n{stream.size::>0["{stream.size::bytes} "||""]}{stream.releaseGroup::exists["{stream.releaseGroup} "||""]}{stream.indexer::exists["{stream.indexer}"||""]}\#n{service.cached::istrue["Ready"||"Not Ready"]}{service.shortName::exists[" ({service.shortName})"||""]}{stream.filename::exists["\#n{stream.filename}"||""]}"#
}
