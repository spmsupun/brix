import Foundation

/// Reads the YAML that API descriptions are written in (OpenAPI files): block maps and
/// lists, plain and quoted scalars, `|` and `>` blocks, and one-line `[…]` / `{…}`.
/// ponytail: no anchors, aliases, tags or multi-document files; those fail with a
/// message asking for the JSON version, add a full YAML library when they show up.
enum MiniYAML {
    struct Failure: LocalizedError {
        let line: Int
        let message: String
        var errorDescription: String? { "YAML line \(line): \(message)" }
    }

    private struct Line { let number: Int; let indent: Int; let text: String }

    static func parse(_ source: String) throws -> Any {
        var lines: [Line] = []
        for (i, raw) in source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").enumerated() {
            if raw.hasPrefix("---") && lines.isEmpty { continue }
            if raw.hasPrefix("---") || raw.hasPrefix("...") { throw Failure(line: i + 1, message: "more than one document; save it as JSON to import it") }
            lines.append(Line(number: i + 1, indent: raw.prefix { $0 == " " }.count, text: raw))
        }
        var p = Parser(lines: lines)
        p.skipBlank()
        guard p.i < lines.count else { return [String: Any]() }
        let value = try p.block(indent: lines[p.i].indent)
        p.skipBlank()
        if p.i < lines.count { throw Failure(line: lines[p.i].number, message: "unexpected indentation") }
        return value
    }

    private struct Parser {
        let lines: [Line]
        var i = 0

        mutating func skipBlank() {
            while i < lines.count, MiniYAML.stripComment(lines[i].text).trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }
        }

        /// A map or list whose entries start at exactly `indent`.
        mutating func block(indent: Int) throws -> Any {
            skipBlank()
            let first = MiniYAML.stripComment(lines[i].text).trimmingCharacters(in: .whitespaces)
            return first == "-" || first.hasPrefix("- ") ? try list(indent: indent) : try map(indent: indent)
        }

        mutating func list(indent: Int) throws -> [Any] {
            var out: [Any] = []
            while true {
                skipBlank()
                guard i < lines.count, lines[i].indent == indent else { break }
                let line = lines[i]
                let text = MiniYAML.stripComment(line.text).trimmingCharacters(in: .whitespaces)
                guard text == "-" || text.hasPrefix("- ") else { break }
                let rest = String(text.dropFirst(1)).trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("&") || rest.hasPrefix("*") || rest.hasPrefix("!") {
                    throw Failure(line: line.number, message: "anchors, aliases and tags aren't supported; save it as JSON to import it")
                }
                if rest == "|" || rest == ">" || (rest.count == 2 && (rest.hasPrefix("|") || rest.hasPrefix(">"))) {
                    out.append(blockScalar(folded: rest.hasPrefix(">"), keep: rest.hasSuffix("+"), strip: rest.hasSuffix("-"), parent: indent))
                    continue
                }
                if rest.isEmpty {
                    i += 1
                    skipBlank()
                    out.append(i < lines.count && lines[i].indent > indent ? try block(indent: lines[i].indent) : NSNull())
                } else if MiniYAML.keySplit(rest) != nil {
                    // "- key: value" starts a map whose keys line up after the dash.
                    let inner = line.indent + 1 + line.text.dropFirst(line.indent + 1).prefix { $0 == " " }.count
                    var shadow = lines
                    shadow[i] = Line(number: line.number, indent: inner, text: String(repeating: " ", count: inner) + rest)
                    var sub = Parser(lines: shadow, i: i)
                    out.append(try sub.map(indent: inner))
                    i = sub.i
                } else {
                    out.append(try scalarOrFlow(rest, line: line.number, indent: indent))
                }
            }
            return out
        }

        mutating func map(indent: Int) throws -> [String: Any] {
            var out: [String: Any] = [:]
            while true {
                skipBlank()
                guard i < lines.count, lines[i].indent == indent else { break }
                let line = lines[i]
                let text = MiniYAML.stripComment(line.text).trimmingCharacters(in: .whitespaces)
                if text == "-" || text.hasPrefix("- ") { break }
                guard let (key, rest) = MiniYAML.keySplit(text) else { throw Failure(line: line.number, message: "expected “key: value”") }
                if rest.hasPrefix("&") || rest.hasPrefix("*") || rest.hasPrefix("!") {
                    throw Failure(line: line.number, message: "anchors, aliases and tags aren't supported; save it as JSON to import it")
                }
                if rest.isEmpty {
                    i += 1
                    skipBlank()
                    if i < lines.count, lines[i].indent > indent,
                       let f = MiniYAML.stripComment(lines[i].text).trimmingCharacters(in: .whitespaces).first, f == "[" || f == "{" {
                        // A […] or {…} that starts on the line below its key.
                        let l = lines[i]
                        out[key] = try scalarOrFlow(MiniYAML.stripComment(l.text).trimmingCharacters(in: .whitespaces), line: l.number, indent: indent)
                    } else if i < lines.count, lines[i].indent > indent {
                        out[key] = try block(indent: lines[i].indent)
                    } else if i < lines.count, lines[i].indent == indent,
                              MiniYAML.stripComment(lines[i].text).trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
                        out[key] = try list(indent: indent)  // a list may sit at its key's indent
                    } else {
                        out[key] = NSNull()
                    }
                } else if rest == "|" || rest == ">" || rest.hasPrefix("|") || rest.hasPrefix(">") {
                    out[key] = blockScalar(folded: rest.hasPrefix(">"), keep: rest.hasSuffix("+"), strip: rest.hasSuffix("-"), parent: indent)
                } else {
                    out[key] = try scalarOrFlow(rest, line: line.number, indent: indent)
                }
            }
            return out
        }

        /// A `|` or `>` block: the more-indented lines below.
        mutating func blockScalar(folded: Bool, keep: Bool, strip: Bool, parent: Int) -> String {
            i += 1
            var body: [String] = [], indent: Int?
            while i < lines.count {
                let l = lines[i]
                if l.text.trimmingCharacters(in: .whitespaces).isEmpty { body.append(""); i += 1; continue }
                if l.indent <= parent { break }
                if indent == nil { indent = l.indent }
                body.append(String(l.text.dropFirst(min(indent!, l.indent))))
                i += 1
            }
            while !keep, body.last == "" { body.removeLast() }
            var text = body.first ?? ""
            for (n, l) in body.enumerated().dropFirst() {
                let prev = body[n - 1]
                if !folded || l.isEmpty || l.hasPrefix(" ") || prev.hasPrefix(" ") { text += "\n" + l }
                // Folding: a single break between two plain lines is a space; an empty line is the break.
                else { text += (prev.isEmpty ? "" : " ") + l }
            }
            if !strip { text += "\n" }
            return text
        }

        /// One-line values, which may continue on more-indented lines (plain or quoted).
        mutating func scalarOrFlow(_ first: String, line: Int, indent: Int) throws -> Any {
            var text = first
            i += 1
            if text.hasPrefix("[") || text.hasPrefix("{") || text.hasPrefix("\"") || text.hasPrefix("'") {
                while !MiniYAML.balanced(text), i < lines.count, lines[i].indent > indent {
                    text += " " + MiniYAML.stripComment(lines[i].text).trimmingCharacters(in: .whitespaces)
                    i += 1
                }
            } else {
                while i < lines.count, lines[i].indent > indent,
                      !MiniYAML.stripComment(lines[i].text).trimmingCharacters(in: .whitespaces).isEmpty,
                      MiniYAML.keySplit(MiniYAML.stripComment(lines[i].text).trimmingCharacters(in: .whitespaces)) == nil {
                    text += " " + MiniYAML.stripComment(lines[i].text).trimmingCharacters(in: .whitespaces)
                    i += 1
                }
            }
            // A plain scalar ("https://{env}.test") is never […] or {…}, whatever it contains.
            if let f = text.first, !"[{\"'".contains(f) { return MiniYAML.typed(text) }
            var flow = Flow(chars: Array(text), line: line)
            let v = try flow.value()
            flow.skipSpace()
            if flow.pos < flow.chars.count { throw Failure(line: line, message: "unexpected text after a value") }
            return v
        }
    }

    /// `[a, b]`, `{k: v}` and scalars on one line.
    private struct Flow {
        let chars: [Character]
        let line: Int
        var pos = 0
        /// How many […] or {…} we're inside; stop characters only end a value there.
        var depth = 0

        mutating func skipSpace() { while pos < chars.count, chars[pos] == " " { pos += 1 } }

        /// After an entry: a comma, or the closer that ends this […] or {…}. Anything
        /// else (a "]" closing a "{") is an error, not a value to keep reading.
        mutating func separator(closer: Character) throws {
            skipSpace()
            guard pos < chars.count else { return }
            if chars[pos] == "," { pos += 1 } else if chars[pos] != closer {
                throw Failure(line: line, message: "expected “,” or “\(closer)” but found “\(chars[pos])”")
            }
        }

        mutating func value() throws -> Any {
            skipSpace()
            guard pos < chars.count else { return NSNull() }
            switch chars[pos] {
            case "[":
                pos += 1
                depth += 1
                defer { depth -= 1 }
                var out: [Any] = []
                while true {
                    skipSpace()
                    guard pos < chars.count else { throw Failure(line: line, message: "unclosed [") }
                    if chars[pos] == "]" { pos += 1; return out }
                    out.append(try value())
                    try separator(closer: "]")
                }
            case "{":
                pos += 1
                depth += 1
                defer { depth -= 1 }
                var out: [String: Any] = [:]
                while true {
                    skipSpace()
                    guard pos < chars.count else { throw Failure(line: line, message: "unclosed {") }
                    if chars[pos] == "}" { pos += 1; return out }
                    let k = MiniYAML.string(try scalar(stops: [":", ",", "}"]))
                    skipSpace()
                    guard pos < chars.count, chars[pos] == ":" else { throw Failure(line: line, message: "expected : in {…}") }
                    pos += 1
                    out[k] = try value()
                    try separator(closer: "}")
                }
            default:
                return try scalar(stops: [",", "]", "}"])
            }
        }

        /// A quoted or plain scalar; inside […] or {…} it ends at a stop character.
        mutating func scalar(stops: Set<Character>) throws -> Any {
            skipSpace()
            if pos < chars.count, chars[pos] == "\"" || chars[pos] == "'" {
                let q = chars[pos]
                pos += 1
                var s = ""
                while pos < chars.count {
                    let c = chars[pos]
                    if q == "'", c == "'" {
                        if pos + 1 < chars.count, chars[pos + 1] == "'" { s.append("'"); pos += 2; continue }
                        pos += 1; return s
                    }
                    if q == "\"", c == "\"" { pos += 1; return s }
                    if q == "\"", c == "\\", pos + 1 < chars.count {
                        let n = chars[pos + 1]
                        let map: [Character: String] = ["n": "\n", "t": "\t", "\"": "\"", "\\": "\\", "/": "/", "r": "\r", "0": "\0"]
                        if let m = map[n] { s += m; pos += 2; continue }
                        if n == "u", pos + 5 < chars.count, let code = UInt32(String(chars[(pos + 2)...(pos + 5)]), radix: 16), let u = Unicode.Scalar(code) {
                            s.unicodeScalars.append(u); pos += 6; continue
                        }
                    }
                    s.append(c)
                    pos += 1
                }
                throw Failure(line: line, message: "unclosed quote")
            }
            var s = ""
            while pos < chars.count {
                let c = chars[pos]
                if stops.contains(c), depth > 0 { break }
                s.append(c)
                pos += 1
            }
            return MiniYAML.typed(s.trimmingCharacters(in: .whitespaces))
        }

    }

    // MARK: Helpers

    /// "key: rest" when the line is a mapping entry (the colon outside quotes, then a space or the end).
    static func keySplit(_ text: String) -> (String, String)? {
        var quote: Character?
        let chars = Array(text)
        for (n, c) in chars.enumerated() {
            if let q = quote { if c == q { quote = nil }; continue }
            if (c == "\"" || c == "'") && n == 0 { quote = c; continue }
            if c == "[" || c == "{", n == 0 { return nil }
            if c == ":", n + 1 == chars.count || chars[n + 1] == " " {
                var key = String(chars[..<n]).trimmingCharacters(in: .whitespaces)
                if key.count >= 2, let f = key.first, f == "\"" || f == "'", key.last == f { key = String(key.dropFirst().dropLast()) }
                return (key, String(chars[(n + 1)...]).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    /// The line without a `# comment` (a # outside quotes, at the start or after a space).
    static func stripComment(_ line: String) -> String {
        var quote: Character?, prev: Character = " "
        for (n, c) in line.enumerated() {
            if let q = quote { if c == q { quote = nil } } else if c == "\"" || c == "'" {
                if prev == " " || prev == ":" || prev == "[" || prev == "{" || prev == "," || n == 0 { quote = c }
            } else if c == "#", prev == " " || n == 0 {
                return String(line.prefix(n))
            }
            prev = c
        }
        return line
    }

    static func balanced(_ text: String) -> Bool {
        var depth = 0, quote: Character?
        for c in text {
            if let q = quote { if c == q { quote = nil }; continue }
            if c == "\"" || c == "'" { quote = c } else if c == "[" || c == "{" { depth += 1 } else if c == "]" || c == "}" { depth -= 1 }
        }
        return depth <= 0 && quote == nil
    }

    static func typed(_ s: String) -> Any {
        switch s {
        case "", "~", "null", "Null", "NULL": return NSNull()
        case "true", "True", "TRUE": return true
        case "false", "False", "FALSE": return false
        default: break
        }
        if let n = Int(s) { return n }
        if s.contains("."), let d = Double(s) { return d }
        return s
    }

    static func string(_ v: Any) -> String {
        if let s = v as? String { return s }
        if v is NSNull { return "" }
        return "\(v)"
    }
}
