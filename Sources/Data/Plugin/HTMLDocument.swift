import Foundation

/// Minimal HTML parser and CSS selector engine.
///
/// Nuvio's plugin runtime exposes a jsoup-backed `cheerio` shim to scraper JS. Apple platforms
/// have no jsoup, so the same surface — `load`, `select`, `find`, `text`, `html`, `attr`, `next`,
/// `prev` — is served from here. This is deliberately a subset: enough for the selectors real
/// scrapers use, not a spec-complete parser.
final class HTMLNode {
    enum Kind {
        case element(String)
        case text(String)
        case comment
    }

    let kind: Kind
    var attributes: [String: String] = [:]
    private(set) var children: [HTMLNode] = []
    weak var parent: HTMLNode?

    init(kind: Kind) { self.kind = kind }

    var tagName: String? {
        if case .element(let name) = kind { return name }
        return nil
    }

    func append(_ node: HTMLNode) {
        node.parent = self
        children.append(node)
    }

    var elementChildren: [HTMLNode] {
        children.filter { $0.tagName != nil }
    }

    /// Element siblings, used by `next` / `prev`.
    private var siblings: [HTMLNode] { parent?.elementChildren ?? [] }

    var nextElement: HTMLNode? {
        let group = siblings
        guard let index = group.firstIndex(where: { $0 === self }),
              group.indices.contains(index + 1) else { return nil }
        return group[index + 1]
    }

    var previousElement: HTMLNode? {
        let group = siblings
        guard let index = group.firstIndex(where: { $0 === self }), index > 0 else { return nil }
        return group[index - 1]
    }

    var classes: Set<String> {
        Set((attributes["class"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
    }

    /// Concatenated text of the subtree, whitespace-collapsed the way jsoup's `text()` is.
    var text: String {
        var out = ""
        collectText(into: &out)
        return out
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func collectText(into out: inout String) {
        switch kind {
        case .text(let value):
            out += value
        case .comment:
            break
        case .element(let name):
            // Script and style contents are not document text.
            guard name != "script", name != "style" else { return }
            for child in children { child.collectText(into: &out) }
        }
    }

    /// Raw contents of the node, script/style included — scrapers read JSON out of `<script>`.
    var innerHTML: String {
        children.map(\.outerHTML).joined()
    }

    var outerHTML: String {
        switch kind {
        case .text(let value):
            return value
        case .comment:
            return ""
        case .element(let name):
            let attrs = attributes
                .sorted { $0.key < $1.key }
                .map { " \($0.key)=\"\($0.value)\"" }
                .joined()
            if HTMLParser.voidElements.contains(name) {
                return "<\(name)\(attrs)>"
            }
            return "<\(name)\(attrs)>\(innerHTML)</\(name)>"
        }
    }

    /// Depth-first descendants, in document order.
    func descendants() -> [HTMLNode] {
        var out: [HTMLNode] = []
        for child in children where child.tagName != nil {
            out.append(child)
            out.append(contentsOf: child.descendants())
        }
        return out
    }

    func select(_ selector: String) -> [HTMLNode] {
        CSSSelector.parse(selector).flatMap { compound in
            compound.match(in: self)
        }.uniqued()
    }
}

private extension Array where Element == HTMLNode {
    /// Selector groups can overlap; keep document order and drop repeats by identity.
    func uniqued() -> [HTMLNode] {
        var seen = Set<ObjectIdentifier>()
        return filter { seen.insert(ObjectIdentifier($0)).inserted }
    }
}

// MARK: - Parser

enum HTMLParser {
    static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr"
    ]

    /// Elements that close an open instance of themselves, so malformed markup does not nest
    /// forever — the common real-world case is `<p>` and table/list rows.
    private static let selfClosingSiblings: [String: Set<String>] = [
        "p": ["p", "div", "section", "article", "ul", "ol", "table", "h1", "h2", "h3", "h4"],
        "li": ["li"],
        "tr": ["tr"],
        "td": ["td", "th", "tr"],
        "th": ["td", "th", "tr"],
        "option": ["option"]
    ]

    static func parse(_ html: String) -> HTMLNode {
        let root = HTMLNode(kind: .element("#root"))
        var stack: [HTMLNode] = [root]
        let scalars = Array(html)
        var index = 0

        func current() -> HTMLNode { stack[stack.count - 1] }

        while index < scalars.count {
            if scalars[index] == "<" {
                if let (token, next) = readTag(scalars, from: index) {
                    index = next
                    switch token {
                    case .comment:
                        break
                    case .doctype:
                        break
                    case .close(let name):
                        // Unwind to the matching open tag; ignore a stray close.
                        if let position = stack.lastIndex(where: { $0.tagName == name }), position > 0 {
                            stack.removeSubrange(position...)
                        }
                    case .open(let name, let attributes, let isSelfClosing):
                        if let closes = selfClosingSiblings[current().tagName ?? ""],
                           closes.contains(name) {
                            stack.removeLast()
                        }
                        let node = HTMLNode(kind: .element(name))
                        node.attributes = attributes
                        current().append(node)

                        if !isSelfClosing && !voidElements.contains(name) {
                            stack.append(node)
                            // Raw-text elements swallow everything up to their close tag.
                            if name == "script" || name == "style" {
                                let (raw, after) = readRawText(scalars, from: index, tag: name)
                                if !raw.isEmpty { node.append(HTMLNode(kind: .text(raw))) }
                                index = after
                                stack.removeLast()
                            }
                        }
                    }
                    continue
                }
            }

            // Text run up to the next tag.
            var text = ""
            while index < scalars.count, scalars[index] != "<" {
                text.append(scalars[index])
                index += 1
            }
            if index < scalars.count, scalars[index] == "<", readTag(scalars, from: index) == nil {
                // A bare `<` that does not begin a tag is literal text.
                text.append("<")
                index += 1
            }
            if !text.isEmpty {
                current().append(HTMLNode(kind: .text(decodeEntities(text))))
            }
        }
        return root
    }

    private enum Token {
        case open(String, [String: String], Bool)
        case close(String)
        case comment
        case doctype
    }

    private static func readTag(_ scalars: [Character], from start: Int) -> (Token, Int)? {
        guard start < scalars.count, scalars[start] == "<", start + 1 < scalars.count else { return nil }
        var index = start + 1

        if scalars[index] == "!" {
            // Comment or doctype: skip to the matching terminator.
            if matches(scalars, at: index, "!--") {
                var cursor = index + 3
                while cursor + 2 < scalars.count, !matches(scalars, at: cursor, "-->") { cursor += 1 }
                return (.comment, min(cursor + 3, scalars.count))
            }
            var cursor = index
            while cursor < scalars.count, scalars[cursor] != ">" { cursor += 1 }
            return (.doctype, min(cursor + 1, scalars.count))
        }

        let isClose = scalars[index] == "/"
        if isClose { index += 1 }

        guard index < scalars.count, scalars[index].isLetter else { return nil }
        var name = ""
        while index < scalars.count, scalars[index].isLetter || scalars[index].isNumber
            || scalars[index] == "-" || scalars[index] == "_" || scalars[index] == ":" {
            name.append(scalars[index])
            index += 1
        }
        name = name.lowercased()

        if isClose {
            while index < scalars.count, scalars[index] != ">" { index += 1 }
            return (.close(name), min(index + 1, scalars.count))
        }

        var attributes: [String: String] = [:]
        var isSelfClosing = false

        while index < scalars.count {
            while index < scalars.count, scalars[index].isWhitespace { index += 1 }
            guard index < scalars.count else { break }
            if scalars[index] == ">" { index += 1; break }
            if scalars[index] == "/" {
                isSelfClosing = true
                index += 1
                continue
            }

            var key = ""
            while index < scalars.count, !scalars[index].isWhitespace,
                  scalars[index] != "=", scalars[index] != ">", scalars[index] != "/" {
                key.append(scalars[index])
                index += 1
            }
            guard !key.isEmpty else { index += 1; continue }

            while index < scalars.count, scalars[index].isWhitespace { index += 1 }
            var value = ""
            if index < scalars.count, scalars[index] == "=" {
                index += 1
                while index < scalars.count, scalars[index].isWhitespace { index += 1 }
                if index < scalars.count, scalars[index] == "\"" || scalars[index] == "'" {
                    let quote = scalars[index]
                    index += 1
                    while index < scalars.count, scalars[index] != quote {
                        value.append(scalars[index])
                        index += 1
                    }
                    index += 1
                } else {
                    while index < scalars.count, !scalars[index].isWhitespace, scalars[index] != ">" {
                        value.append(scalars[index])
                        index += 1
                    }
                }
            }
            attributes[key.lowercased()] = decodeEntities(value)
        }
        return (.open(name, attributes, isSelfClosing), index)
    }

    private static func readRawText(_ scalars: [Character], from start: Int, tag: String) -> (String, Int) {
        let closing = "</\(tag)"
        var index = start
        var text = ""
        while index < scalars.count {
            if scalars[index] == "<", matchesCaseInsensitive(scalars, at: index, closing) {
                var cursor = index
                while cursor < scalars.count, scalars[cursor] != ">" { cursor += 1 }
                return (text, min(cursor + 1, scalars.count))
            }
            text.append(scalars[index])
            index += 1
        }
        return (text, index)
    }

    private static func matches(_ scalars: [Character], at index: Int, _ needle: String) -> Bool {
        let chars = Array(needle)
        guard index + chars.count <= scalars.count else { return false }
        return Array(scalars[index..<(index + chars.count)]) == chars
    }

    private static func matchesCaseInsensitive(_ scalars: [Character], at index: Int, _ needle: String) -> Bool {
        let chars = Array(needle.lowercased())
        guard index + chars.count <= scalars.count else { return false }
        return Array(scalars[index..<(index + chars.count)]).map { Character($0.lowercased()) } == chars
    }

    /// The handful of entities that actually appear in scraped pages, plus numeric escapes.
    static func decodeEntities(_ input: String) -> String {
        guard input.contains("&") else { return input }
        var out = input
        let named = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&apos;": "'", "&#39;": "'", "&nbsp;": "\u{00A0}", "&#x27;": "'"
        ]
        for (entity, replacement) in named {
            out = out.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        // Numeric forms: &#123; and &#x1F;
        for pattern in [#"&#(\d+);"#, #"&#[xX]([0-9a-fA-F]+);"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let isHex = pattern.contains("x")
            // Rebuild forwards, appending the gap before each match, so ranges stay valid.
            var result = ""
            var last = out.startIndex
            for match in regex.matches(in: out, range: NSRange(out.startIndex..., in: out)) {
                guard let full = Range(match.range, in: out),
                      let digits = Range(match.range(at: 1), in: out),
                      let code = UInt32(out[digits], radix: isHex ? 16 : 10),
                      let scalar = Unicode.Scalar(code) else { continue }
                result += out[last..<full.lowerBound]
                result.append(Character(scalar))
                last = full.upperBound
            }
            result += out[last...]
            out = result
        }
        return out
    }
}

// MARK: - Selectors

/// One selector in a comma-separated group, as a chain of steps.
struct CSSSelector {
    enum Combinator { case descendant, child }

    struct Step {
        var tag: String?
        var id: String?
        var classes: [String] = []
        /// `(name, op, value)`; `op` is empty for a bare presence test.
        var attributes: [(name: String, op: String, value: String)] = []
        var containsText: String?
        var combinator: Combinator = .descendant
    }

    var steps: [Step]

    static func parse(_ selector: String) -> [CSSSelector] {
        splitGroups(selector).compactMap { group in
            let steps = parseSteps(group)
            return steps.isEmpty ? nil : CSSSelector(steps: steps)
        }
    }

    /// Splits on commas that are not inside brackets or a `:contains()` argument.
    private static func splitGroups(_ selector: String) -> [String] {
        var groups: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        for character in selector {
            if let active = quote {
                current.append(character)
                if character == active { quote = nil }
                continue
            }
            switch character {
            case "\"", "'":
                quote = character
                current.append(character)
            case "[", "(":
                depth += 1
                current.append(character)
            case "]", ")":
                depth = max(0, depth - 1)
                current.append(character)
            case "," where depth == 0:
                groups.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        groups.append(current)
        return groups.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func parseSteps(_ group: String) -> [Step] {
        var steps: [Step] = []
        var pendingCombinator: Combinator = .descendant
        var token = ""
        var depth = 0

        func flush() {
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            token = ""
            guard !trimmed.isEmpty else { return }
            var step = parseStep(trimmed)
            step.combinator = pendingCombinator
            pendingCombinator = .descendant
            steps.append(step)
        }

        for character in group {
            switch character {
            case "[", "(":
                depth += 1
                token.append(character)
            case "]", ")":
                depth = max(0, depth - 1)
                token.append(character)
            case ">" where depth == 0:
                flush()
                pendingCombinator = .child
            case _ where character.isWhitespace && depth == 0:
                flush()
            default:
                token.append(character)
            }
        }
        flush()
        return steps
    }

    private static func parseStep(_ raw: String) -> Step {
        var step = Step()
        var buffer = ""
        var mode: Character = "t"
        var index = raw.startIndex

        func commit() {
            guard !buffer.isEmpty else { return }
            switch mode {
            case "t": step.tag = buffer.lowercased()
            case "#": step.id = buffer
            case ".": step.classes.append(buffer)
            default: break
            }
            buffer = ""
        }

        while index < raw.endIndex {
            let character = raw[index]
            switch character {
            case "#", ".":
                commit()
                mode = character
                index = raw.index(after: index)
            case "[":
                commit()
                guard let close = raw[index...].firstIndex(of: "]") else {
                    index = raw.endIndex
                    continue
                }
                let body = String(raw[raw.index(after: index)..<close])
                step.attributes.append(parseAttribute(body))
                mode = "x"
                index = raw.index(after: close)
            case ":":
                commit()
                // `:contains(text)` is the only pseudo-class the Android shim supports.
                let rest = raw[index...]
                if let open = rest.firstIndex(of: "("), let close = rest.lastIndex(of: ")") {
                    let name = String(rest[rest.index(after: rest.startIndex)..<open]).lowercased()
                    var argument = String(rest[rest.index(after: open)..<close])
                    argument = argument.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                    if name == "contains" { step.containsText = argument }
                    index = rest.index(after: close)
                } else {
                    index = raw.endIndex
                }
                mode = "x"
            default:
                buffer.append(character)
                index = raw.index(after: index)
            }
        }
        commit()
        return step
    }

    private static func parseAttribute(_ body: String) -> (name: String, op: String, value: String) {
        for op in ["*=", "^=", "$=", "~=", "|=", "="] {
            if let range = body.range(of: op) {
                let name = String(body[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                var value = String(body[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return (name.lowercased(), op, value)
            }
        }
        return (body.trimmingCharacters(in: .whitespaces).lowercased(), "", "")
    }

    // MARK: Matching

    func match(in root: HTMLNode) -> [HTMLNode] {
        guard let first = steps.first else { return [] }

        // Start from every descendant matching the leftmost step, then walk right.
        var candidates = root.descendants().filter { first.matches($0) }
        for step in steps.dropFirst() {
            var next: [HTMLNode] = []
            for candidate in candidates {
                switch step.combinator {
                case .child:
                    next.append(contentsOf: candidate.elementChildren.filter { step.matches($0) })
                case .descendant:
                    next.append(contentsOf: candidate.descendants().filter { step.matches($0) })
                }
            }
            candidates = next
        }
        return candidates
    }
}

private extension CSSSelector.Step {
    func matches(_ node: HTMLNode) -> Bool {
        guard let tagName = node.tagName else { return false }
        if let tag, tag != "*", tag != tagName { return false }
        if let id, node.attributes["id"] != id { return false }
        if !classes.isEmpty {
            let nodeClasses = node.classes
            guard classes.allSatisfy({ nodeClasses.contains($0) }) else { return false }
        }
        for attribute in attributes {
            guard let value = node.attributes[attribute.name] else { return false }
            switch attribute.op {
            case "": continue
            case "=": if value != attribute.value { return false }
            case "*=": if !value.contains(attribute.value) { return false }
            case "^=": if !value.hasPrefix(attribute.value) { return false }
            case "$=": if !value.hasSuffix(attribute.value) { return false }
            case "~=":
                let words = value.split(whereSeparator: \.isWhitespace).map(String.init)
                if !words.contains(attribute.value) { return false }
            case "|=":
                if value != attribute.value && !value.hasPrefix(attribute.value + "-") { return false }
            default: return false
            }
        }
        if let containsText, !node.text.localizedCaseInsensitiveContains(containsText) {
            return false
        }
        return true
    }
}
