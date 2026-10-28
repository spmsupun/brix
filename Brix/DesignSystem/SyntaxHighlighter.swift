import AppKit
import SwiftUI

/// Regex highlighter for the read-only viewer and the SQL editor.
/// Comments and strings are found first and protected, then keywords,
/// types, numbers and calls are coloured in the remaining text.
enum SyntaxLanguage: String {
    case typescript, javascript, swift, go, python, php, sql, json, yaml, markdown, shell, config, plain

    static func detect(path: String) -> SyntaxLanguage {
        let name = (path as NSString).lastPathComponent.lowercased()
        switch (name as NSString).pathExtension {
        case "ts", "tsx", "mts", "cts": return .typescript
        case "js", "jsx", "mjs", "cjs": return .javascript
        case "swift": return .swift
        case "go": return .go
        case "py", "pyi": return .python
        case "php": return .php
        case "sql": return .sql
        case "json", "jsonc": return .json
        case "yml", "yaml": return .yaml
        case "md", "markdown", "mdx": return .markdown
        case "sh", "bash", "zsh", "fish": return .shell
        case "toml", "ini", "cfg", "conf", "env", "properties": return .config
        default:
            if name.hasPrefix(".env") || name == "dockerfile" || name == "makefile" || name.hasPrefix(".git") || name == "brewfile" { return name == ".zshrc" ? .shell : .config }
            if name.hasPrefix(".") && (name.hasSuffix("rc") || name.hasSuffix("profile")) { return .shell }
            return .plain
        }
    }
}

struct SyntaxTheme {
    var font = NSFont.code(ofSize: 12.5, weight: .regular)
    var text = NSColor(Theme.text)
    var keyword = NSColor(Theme.synKeyword)
    var string = NSColor(Theme.synString)
    var type = NSColor(Theme.synType)
    var function = NSColor(Theme.synFunction)
    var number = NSColor(Theme.synNumber)
    var comment = NSColor(Theme.synComment)
    var punct = NSColor(Theme.synPunct)
    var tag = NSColor(Theme.synTag)
}

enum SyntaxHighlighter {
    private struct Spec {
        var lineComment: [String] = []
        var blockComment: (String, String)? = nil
        var strings: [String] = ["\"", "'"]
        var templateString = false
        var keywords: Set<String> = []
        var types: Set<String> = []
        var caseInsensitive = false
        var jsx = false
    }

    private static let jsKeywords: Set<String> = ["import", "from", "export", "default", "const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "switch", "case", "break", "continue", "new", "class", "extends", "super", "this", "typeof", "instanceof", "in", "of", "async", "await", "try", "catch", "finally", "throw", "yield", "null", "undefined", "true", "false", "type", "interface", "enum", "implements", "as", "satisfies", "readonly", "public", "private", "protected", "static", "void", "keyof", "declare", "namespace"]
    private static let jsTypes: Set<String> = ["string", "number", "boolean", "any", "unknown", "never", "object", "Record", "Promise", "Array", "Map", "Set", "Date", "Error"]

    private static func spec(_ l: SyntaxLanguage) -> Spec {
        switch l {
        case .typescript, .javascript:
            return Spec(lineComment: ["//"], blockComment: ("/*", "*/"), strings: ["\"", "'", "`"], templateString: true, keywords: jsKeywords, types: jsTypes, jsx: true)
        case .swift:
            return Spec(lineComment: ["//"], blockComment: ("/*", "*/"), strings: ["\""],
                        keywords: ["import", "struct", "class", "enum", "protocol", "extension", "func", "var", "let", "if", "else", "guard", "return", "for", "in", "while", "switch", "case", "default", "break", "continue", "throw", "throws", "try", "catch", "do", "async", "await", "some", "any", "self", "Self", "super", "init", "deinit", "static", "private", "fileprivate", "internal", "public", "open", "final", "override", "mutating", "nil", "true", "false", "where", "typealias", "associatedtype", "inout", "defer", "lazy", "weak", "unowned", "actor", "nonisolated", "@MainActor", "@State", "@Binding", "@Observable", "@Environment"],
                        types: ["String", "Int", "Double", "Float", "Bool", "Array", "Dictionary", "Set", "Optional", "View", "Text", "Date", "URL", "Data", "Void", "Error", "Result", "Task"])
        case .go:
            return Spec(lineComment: ["//"], blockComment: ("/*", "*/"), strings: ["\"", "`", "'"],
                        keywords: ["package", "import", "func", "return", "if", "else", "for", "range", "switch", "case", "default", "break", "continue", "go", "defer", "select", "chan", "map", "struct", "interface", "type", "var", "const", "nil", "true", "false", "fallthrough", "goto"],
                        types: ["string", "int", "int64", "int32", "uint", "float64", "bool", "byte", "rune", "error", "any", "Context", "ResponseWriter", "Request"])
        case .python:
            return Spec(lineComment: ["#"], strings: ["\"\"\"", "'''", "\"", "'"],
                        keywords: ["def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is", "import", "from", "as", "with", "try", "except", "finally", "raise", "pass", "break", "continue", "lambda", "yield", "async", "await", "None", "True", "False", "global", "nonlocal", "assert", "del", "self"],
                        types: ["int", "str", "float", "bool", "list", "dict", "set", "tuple", "bytes", "object"])
        case .php:
            return Spec(lineComment: ["//", "#"], blockComment: ("/*", "*/"), strings: ["\"", "'"],
                        keywords: ["<?php", "namespace", "use", "class", "interface", "trait", "extends", "implements", "function", "public", "private", "protected", "static", "return", "if", "else", "elseif", "foreach", "as", "for", "while", "new", "echo", "null", "true", "false", "array", "fn", "match", "throw", "try", "catch", "readonly", "const"],
                        types: ["int", "string", "float", "bool", "array", "void", "mixed", "self"])
        case .sql:
            return Spec(lineComment: ["--"], blockComment: ("/*", "*/"), strings: ["'"],
                        keywords: ["select", "from", "where", "and", "or", "not", "in", "is", "null", "join", "left", "right", "inner", "outer", "full", "cross", "on", "as", "group", "by", "order", "having", "limit", "offset", "insert", "into", "values", "update", "set", "delete", "create", "table", "index", "view", "drop", "alter", "add", "column", "primary", "key", "references", "foreign", "unique", "default", "distinct", "union", "all", "case", "when", "then", "else", "end", "with", "returning", "explain", "analyze", "asc", "desc", "interval", "exists", "between", "like", "ilike", "true", "false", "begin", "commit", "rollback", "constraint", "cascade", "if"],
                        types: ["int", "integer", "bigint", "smallint", "text", "varchar", "char", "boolean", "bool", "uuid", "timestamp", "timestamptz", "date", "numeric", "decimal", "real", "jsonb", "json", "serial", "bigserial"], caseInsensitive: true)
        case .json:
            return Spec(strings: ["\""], keywords: ["true", "false", "null"])
        case .yaml:
            return Spec(lineComment: ["#"], strings: ["\"", "'"], keywords: ["true", "false", "null", "yes", "no", "on", "off"])
        case .shell:
            return Spec(lineComment: ["#"], strings: ["\"", "'"],
                        keywords: ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "case", "esac", "function", "return", "export", "local", "set", "echo", "source", "alias", "cd", "exit"])
        case .config:
            return Spec(lineComment: ["#", ";"], strings: ["\"", "'"], keywords: ["true", "false"])
        case .markdown, .plain:
            return Spec(strings: [])
        }
    }

    static func highlight(_ text: String, language: SyntaxLanguage, theme: SyntaxTheme = SyntaxTheme()) -> NSAttributedString {
        let out = NSMutableAttributedString(string: text, attributes: [.font: theme.font, .foregroundColor: theme.text])
        let ns = text as NSString
        let len = ns.length
        guard len > 0, len < 3_000_000 else { return out }
        if language == .markdown { return markdown(out, theme: theme) }
        let sp = spec(language)
        var protected = IndexSet()

        func color(_ r: NSRange, _ c: NSColor, italic: Bool = false, bold: Bool = false) {
            out.addAttribute(.foregroundColor, value: c, range: r)
            if italic { out.addAttribute(.font, value: NSFontManager.shared.convert(theme.font, toHaveTrait: .italicFontMask), range: r) }
            if bold { out.addAttribute(.font, value: NSFont.code(ofSize: theme.font.pointSize, weight: .medium), range: r) }
        }

        // Pass 1: comments and strings, scanning left to right.
        var i = 0
        let chars = Array(text.utf16)
        func starts(_ s: String, at idx: Int) -> Bool {
            let u = Array(s.utf16)
            guard idx + u.count <= chars.count else { return false }
            for k in 0..<u.count where chars[idx + k] != u[k] { return false }
            return true
        }
        while i < chars.count {
            if let lc = sp.lineComment.first(where: { starts($0, at: i) }), !(language == .php && lc == "#" && starts("#[", at: i)) {
                _ = lc
                var j = i
                while j < chars.count, chars[j] != 10 { j += 1 }
                let r = NSRange(location: i, length: j - i)
                color(r, theme.comment, italic: true)
                protected.insert(integersIn: i..<j)
                i = j
                continue
            }
            if let (open, close) = sp.blockComment, starts(open, at: i) {
                let found = ns.range(of: close, range: NSRange(location: i + open.utf16.count, length: len - i - open.utf16.count))
                let end = found.location == NSNotFound ? len : found.location + found.length
                color(NSRange(location: i, length: end - i), theme.comment, italic: true)
                protected.insert(integersIn: i..<end)
                i = end
                continue
            }
            if let q = sp.strings.first(where: { starts($0, at: i) }) {
                let qu = Array(q.utf16)
                var j = i + qu.count
                let multiline = qu.count == 3 || (q == "`")
                while j < chars.count {
                    if chars[j] == 92 { j += 2; continue } // backslash
                    if !multiline, chars[j] == 10 { break }
                    if starts(q, at: j) { j += qu.count; break }
                    j += 1
                }
                j = min(j, chars.count)
                color(NSRange(location: i, length: j - i), theme.string)
                protected.insert(integersIn: i..<j)
                i = j
                continue
            }
            i += 1
        }

        func apply(_ pattern: String, options: NSRegularExpression.Options = [], group: Int = 0, _ body: (NSRange, String) -> Void) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            re.enumerateMatches(in: text, range: NSRange(location: 0, length: len)) { m, _, _ in
                guard let m else { return }
                let r = m.range(at: group)
                guard r.location != NSNotFound, !protected.contains(r.location) else { return }
                body(r, ns.substring(with: r))
            }
        }

        // JSX tags
        if sp.jsx {
            apply(#"</?[A-Za-z][\w.]*|/?>"#) { r, _ in color(r, theme.tag) }
        }
        // YAML keys / JSON keys
        if language == .yaml || language == .config {
            apply(#"^\s*-?\s*([\w.\-]+)\s*[:=]"#, options: .anchorsMatchLines, group: 1) { r, _ in color(r, theme.type) }
            apply(#"^\s*\[[^\]]+\]"#, options: .anchorsMatchLines) { r, _ in color(r, theme.keyword) }
        }
        if language == .json {
            // Strings followed by ":" are keys.
            if let re = try? NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*"\s*:"#) {
                re.enumerateMatches(in: text, range: NSRange(location: 0, length: len)) { m, _, _ in
                    guard let m else { return }
                    var r = m.range
                    r.length = (ns.substring(with: r) as NSString).range(of: "\"", options: .backwards).location + 1
                    color(r, theme.type)
                }
            }
        }
        // Numbers
        apply(#"\b(0x[0-9a-fA-F]+|\d+(\.\d+)?)\b"#) { r, _ in color(r, theme.number) }
        // Function calls and declarations
        if ![.json, .yaml, .config, .sql].contains(language) {
            apply(#"\b([A-Za-z_][\w]*)\s*(?=\()"#, group: 1) { r, w in
                if !sp.keywords.contains(w) { color(r, theme.function, bold: true) }
            }
        }
        // Types: capitalised identifiers and known names
        if ![.json, .yaml, .config, .shell, .sql].contains(language) {
            apply(#"\b[A-Z][A-Za-z0-9_]*\b"#) { r, w in
                if !sp.keywords.contains(w) { color(r, theme.type) }
            }
        }
        // Keywords and builtin types
        apply(#"(?<![\w$])[@<?]?[A-Za-z_][\w]*"#, options: sp.caseInsensitive ? .caseInsensitive : []) { r, w in
            let key = sp.caseInsensitive ? w.lowercased() : w
            if sp.keywords.contains(key) {
                color(r, theme.keyword, bold: language == .sql)
            } else if sp.types.contains(key) {
                color(r, theme.type)
            }
        }
        // Shell variables
        if language == .shell || language == .config {
            apply(#"\$\{?[A-Za-z_][\w]*\}?"#) { r, _ in color(r, theme.type) }
        }
        // Punctuation
        apply(#"[{}()\[\];,.:=<>+\-*/|&!?]"#) { r, _ in
            if out.attribute(.foregroundColor, at: r.location, effectiveRange: nil) as? NSColor == theme.text { color(r, theme.punct) }
        }
        return out
    }

    private static func markdown(_ out: NSMutableAttributedString, theme: SyntaxTheme) -> NSAttributedString {
        let text = out.string
        let len = (text as NSString).length
        func apply(_ p: String, _ attrs: [NSAttributedString.Key: Any]) {
            let opts: NSRegularExpression.Options = .anchorsMatchLines
            guard let re = try? NSRegularExpression(pattern: p, options: opts) else { return }
            for m in re.matches(in: text, range: NSRange(location: 0, length: len)) { out.addAttributes(attrs, range: m.range) }
        }
        apply(#"^#{1,6} .*$"#, [.foregroundColor: theme.keyword, .font: NSFont.code(ofSize: theme.font.pointSize, weight: .semibold)])
        apply(#"`[^`\n]+`"#, [.foregroundColor: theme.string])
        apply(#"\*\*[^*\n]+\*\*"#, [.foregroundColor: theme.function, .font: NSFont.code(ofSize: theme.font.pointSize, weight: .bold)])
        apply(#"^\s*[-*+] "#, [.foregroundColor: theme.tag])
        apply(#"\[[^\]]+\]\([^)]+\)"#, [.foregroundColor: theme.type])
        apply(#"^\|.*\|$"#, [.foregroundColor: theme.punct])
        apply(#"^```.*$"#, [.foregroundColor: theme.comment])
        return out
    }
}
