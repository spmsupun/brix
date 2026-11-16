import Foundation

// cURL, OpenAPI 3, Insomnia and HAR import.
extension APIImport {

    // MARK: Secrets

    /// Names that usually hold a sign-in: header, query or form field names.
    static func looksSecret(_ name: String) -> Bool {
        let n = name.lowercased().replacingOccurrences(of: "-", with: "_")
        if ["authorization", "proxy_authorization", "cookie", "x_api_key", "api_key", "apikey", "key", "secret", "password", "passwd", "pwd"].contains(n) { return true }
        return ["token", "secret", "password", "api_key", "apikey", "credential", "session"].contains { n.contains($0) }
    }

    /// Moves `value` into a variable to be locked in the Keychain and returns {{name}}.
    /// A value that's already a {{variable}} is left alone.
    static func lock(_ value: String, as base: String, into vars: inout [APIField], taken: inout Set<String>) -> String {
        let v = value.trimmingCharacters(in: .whitespaces)
        if v.isEmpty || (v.hasPrefix("{{") && v.hasSuffix("}}") && !v.dropFirst(2).dropLast(2).contains("{")) { return value }
        if let same = vars.first(where: { $0.value == value }) { return "{{\(same.key)}}" }
        let slug = base.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined().split(separator: "_").joined(separator: "_")
        var key = slug.isEmpty ? "secret" : slug, n = 2
        while taken.contains(key) { key = (slug.isEmpty ? "secret" : slug) + "_\(n)"; n += 1 }
        taken.insert(key)
        vars.append(APIField(key: key, value: value))
        return "{{\(key)}}"
    }

    // MARK: cURL

    /// Options known to take a value that Brix doesn't use: skipped with their value.
    private static let curlValueOptions: Set<String> = [
        "-o", "--output", "-m", "--max-time", "--connect-timeout", "-w", "--write-out", "-x", "--proxy", "--retry", "--retry-delay",
        "--retry-max-time", "--max-redirs", "--cert", "-E", "--key", "--cacert", "--capath", "--cert-type", "--key-type", "--pass",
        "--resolve", "--connect-to", "--interface", "--limit-rate", "-r", "--range", "-T", "--upload-file", "-c", "--cookie-jar",
        "-K", "--config", "--proxy-user", "-U", "--dns-servers", "--local-port", "--max-filesize", "-y", "--speed-time", "-Y", "--speed-limit",
        "-z", "--time-cond", "--trace", "--trace-ascii", "--stderr", "-D", "--dump-header", "--unix-socket", "--abstract-unix-socket",
        "--aws-sigv4", "--ciphers", "--tls-max", "--hostpubmd5", "--hostpubsha256", "--pinnedpubkey", "--noproxy", "--happy-eyeballs-timeout-ms",
        "--expect100-timeout", "--keepalive-time", "--sasl-authzid", "--service-name", "--socks5", "--socks5-hostname", "--preproxy",
        "--variable", "--expand-url", "--url-query", "--parallel-max", "--rate", "--create-file-mode", "--output-dir", "--etag-save", "--etag-compare",
    ]

    /// Options without a value that change nothing Brix sends.
    private static let curlFlags: Set<String> = [
        "--compressed", "-k", "--insecure", "-L", "--location", "-s", "--silent", "-S", "--show-error", "-v", "--verbose", "-i", "--include",
        "-g", "--globoff", "-f", "--fail", "--fail-with-body", "-N", "--no-buffer", "-#", "--progress-bar", "-O", "--remote-name",
        "--http1.1", "--http2", "--http2-prior-knowledge", "--http3", "-0", "--http1.0", "--tlsv1.2", "--tlsv1.3", "-4", "-6", "--ipv4", "--ipv6",
        "--location-trusted", "--raw", "--tr-encoding", "--no-keepalive", "--path-as-is", "-Z", "--parallel", "--digest", "--basic", "--anyauth",
    ]

    /// One `curl …` command (as browsers' "Copy as cURL" make it) as a request. Sign-in
    /// values come back in `lockedVariables`, to be locked in the collection it goes into.
    static func curl(_ command: String) throws -> Result {
        var args = try shellWords(command)
        guard let first = args.first, (first as NSString).lastPathComponent == "curl" || first == "curl.exe" else {
            throw Failure(message: "That isn't a curl command.")
        }
        args.removeFirst()
        var r = APIRequest()
        var method: String?, data: [String] = [], form: [APIField] = [], getMode = false, urls: [String] = []
        var ignored: Set<String> = [], notes: [String] = []
        var i = 0
        func looksLikeURL(_ s: String) -> Bool { s.contains("://") || s.hasPrefix("localhost") || (s.contains(".") && !s.contains(" ") && !s.hasPrefix("@")) }
        while i < args.count {
            var a = args[i]
            var inline: String?
            // -XPOST, --request=POST
            if a.hasPrefix("--"), let eq = a.firstIndex(of: "=") { inline = String(a[a.index(after: eq)...]); a = String(a[..<eq]) }
            else if a.count > 2, a.hasPrefix("-"), !a.hasPrefix("--"), "XHdFuAebom".contains(a[a.index(after: a.startIndex)]) {
                inline = String(a.dropFirst(2)); a = String(a.prefix(2))
            }
            func value() throws -> String {
                if let inline { return inline }
                i += 1
                guard i < args.count else { throw Failure(message: "\(a) needs a value.") }
                return args[i]
            }
            func dataValue(_ raw: String) {
                // curl reads "@file" (and "@-" for stdin) for these; Brix can't see that file.
                if a != "--data-raw", raw.hasPrefix("@") {
                    notes.append("The body comes from \(raw == "@-" ? "standard input" : "the file \(raw.dropFirst())"), which Brix can't read here; add it in Body.")
                } else { data.append(raw) }
            }
            switch a {
            case "-X", "--request": method = try value().uppercased()
            case "-H", "--header":
                let h = try value()
                if let c = h.firstIndex(of: ":") {
                    r.headers.append(APIField(key: h[..<c].trimmingCharacters(in: .whitespaces), value: h[h.index(after: c)...].trimmingCharacters(in: .whitespaces)))
                }
            case "-d", "--data", "--data-raw", "--data-binary", "--data-ascii": dataValue(try value())
            case "--data-urlencode":
                let v = try value()
                if let eq = v.firstIndex(of: "=") { data.append(String(v[..<eq]) + "=" + APISender.formEncode(String(v[v.index(after: eq)...]))) } else { data.append(APISender.formEncode(v)) }
            case "--json":
                dataValue(try value())
                if !r.headers.contains(where: { $0.key.lowercased() == "content-type" }) { r.headers.append(APIField(key: "Content-Type", value: "application/json")) }
            case "-F", "--form", "--form-string":
                let v = try value()
                guard let eq = v.firstIndex(of: "=") else { notes.append("Left out the form field “\(v)”: it has no name=value."); break }
                let key = String(v[..<eq])
                var val = String(v[v.index(after: eq)...])
                let isFile = a != "--form-string" && (val.hasPrefix("@") || val.hasPrefix("<"))
                if a != "--form-string", let semi = val.range(of: ";type=") ?? val.range(of: ";filename=") {
                    notes.append("The form field “\(key)” set its own content type or file name; Brix sends it with the usual one.")
                    val = String(val[..<semi.lowerBound])
                }
                form.append(APIField(key: key, value: isFile ? String(val.dropFirst()) : val, isFile: isFile))
            case "-u", "--user":
                let v = try value()
                r.auth = APIAuth(kind: .basic)
                if let c = v.firstIndex(of: ":") { r.auth.username = String(v[..<c]); r.auth.password = String(v[v.index(after: c)...]) } else { r.auth.username = v }
            case "--oauth2-bearer": r.auth = APIAuth(kind: .bearer); r.auth.token = try value()
            case "-A", "--user-agent": r.headers.append(APIField(key: "User-Agent", value: try value()))
            case "-e", "--referer": r.headers.append(APIField(key: "Referer", value: try value()))
            case "-b", "--cookie":
                let v = try value()
                if v.contains("=") { r.headers.append(APIField(key: "Cookie", value: v)) } else { notes.append("Cookies are read from the file \(v), which Brix can't see.") }
            case "--url": urls.insert(try value(), at: 0)
            case "-G", "--get": getMode = true
            case "-I", "--head": method = "HEAD"
            default:
                if curlFlags.contains(a) { break }
                if curlValueOptions.contains(a) { _ = try value(); ignored.insert(a); break }
                if a.hasPrefix("-"), a.count > 1 {
                    ignored.insert(a)
                    // An option Brix doesn't know: its value, if it has one, is never the URL.
                    if inline == nil, i + 1 < args.count, !args[i + 1].hasPrefix("-"), !looksLikeURL(args[i + 1]) { i += 1 }
                } else {
                    urls.append(a)
                }
            }
            i += 1
        }
        guard var urlText = urls.first(where: looksLikeURL) ?? urls.first else { throw Failure(message: "The curl command has no URL.") }
        if urls.count > 1 { notes.append("The command names more than one address; Brix used \(urlText).") }
        // The query becomes rows you can switch off.
        if let q = urlText.firstIndex(of: "?") {
            r.params = String(urlText[urlText.index(after: q)...]).split(separator: "&").map(formPair)
            urlText = String(urlText[..<q])
        }
        r.url = urlText
        if getMode {
            r.params += data.flatMap { $0.split(separator: "&").map(formPair) }
            data = []
        }
        let contentType = r.headers.first { $0.key.lowercased() == "content-type" }?.value.lowercased() ?? ""
        if !form.isEmpty {
            r.bodyKind = .multipart
            r.formFields = form
            r.headers.removeAll { $0.key.lowercased() == "content-type" }
        } else if !data.isEmpty {
            let body = data.joined(separator: "&")
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if contentType.contains("json") || (contentType.isEmpty && (trimmed.hasPrefix("{") || trimmed.hasPrefix("["))) {
                r.bodyKind = .json; r.body = body
            } else if contentType.contains("x-www-form-urlencoded") || (contentType.isEmpty && body.contains("=") && !body.contains("\n")) {
                r.bodyKind = .form
                r.formFields = body.split(separator: "&").map(formPair)
            } else {
                r.bodyKind = .text; r.body = body
            }
        }
        r.method = method ?? (getMode ? "GET" : (data.isEmpty && form.isEmpty ? "GET" : "POST"))
        let path = URLComponents(string: urlText.contains("://") ? urlText : "http://" + urlText)?.path ?? ""
        r.name = "\(r.method) \(path.isEmpty ? "/" : path)"
        var out = Result()
        // Sign-in values go to locked variables.
        var vars: [APIField] = [], taken: Set<String> = []
        r.auth.password = lock(r.auth.password, as: "password", into: &vars, taken: &taken)
        r.auth.token = lock(r.auth.token, as: "token", into: &vars, taken: &taken)
        for j in r.headers.indices where looksSecret(r.headers[j].key) {
            r.headers[j].value = lock(r.headers[j].value, as: r.headers[j].key, into: &vars, taken: &taken)
        }
        for j in r.params.indices where looksSecret(r.params[j].key) {
            r.params[j].value = lock(r.params[j].value, as: r.params[j].key, into: &vars, taken: &taken)
        }
        for j in r.formFields.indices where !r.formFields[j].isFile && looksSecret(r.formFields[j].key) {
            r.formFields[j].value = lock(r.formFields[j].value, as: r.formFields[j].key, into: &vars, taken: &taken)
        }
        out.requests = [r]
        out.lockedVariables = vars
        if !vars.isEmpty { out.notes.append("Sign-in values were moved into locked collection variables (\(vars.map(\.key).joined(separator: ", "))), kept in the Keychain.") }
        if !ignored.isEmpty { out.notes.append("Left out curl options Brix doesn't use: \(ignored.sorted().joined(separator: ", ")).") }
        out.notes += notes
        return out
    }

    private static func formPair(_ s: Substring) -> APIField {
        let parts = s.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let dec = { (x: Substring) in String(x).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(x) }
        return APIField(key: dec(parts[0]), value: parts.count > 1 ? dec(parts[1]) : "")
    }

    /// Splits a command line the way a POSIX shell would: quotes, backslashes, and
    /// line continuations; `$'…'` as ANSI-C quoting.
    static func shellWords(_ s: String) throws -> [String] {
        var out: [String] = [], cur = "", inWord = false
        let chars = Array(s.replacingOccurrences(of: "\\\r\n", with: " ").replacingOccurrences(of: "\\\n", with: " "))
            .map { $0 == "\n" || $0 == "\r" || $0 == "\t" ? " " : $0 }
        var i = 0
        let unclosed = Failure(message: "A quote in the curl command isn't closed.")
        func hex(_ from: Int, _ count: Int) -> UInt32? {
            guard from + count <= chars.count else { return nil }
            return UInt32(String(chars[from..<(from + count)]), radix: 16)
        }
        while i < chars.count {
            let c = chars[i]
            switch c {
            case " ":
                if inWord { out.append(cur); cur = ""; inWord = false }
            case "'":
                inWord = true; i += 1
                while i < chars.count, chars[i] != "'" { cur.append(chars[i]); i += 1 }
                if i >= chars.count { throw unclosed }
            case "\"":
                inWord = true; i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count, "\"\\$`".contains(chars[i + 1]) { i += 1 }
                    cur.append(chars[i]); i += 1
                }
                if i >= chars.count { throw unclosed }
            case "$" where i + 1 < chars.count && chars[i + 1] == "'":
                inWord = true; i += 2
                var bytes: [UInt8] = []  // \x escapes are bytes, joined as UTF-8
                func flush() { if !bytes.isEmpty { cur += String(decoding: bytes, as: UTF8.self); bytes = [] } }
                while i < chars.count, chars[i] != "'" {
                    guard chars[i] == "\\", i + 1 < chars.count else { flush(); cur.append(chars[i]); i += 1; continue }
                    i += 1
                    let e = chars[i]
                    if e == "x", let b = hex(i + 1, 2) { bytes.append(UInt8(b)); i += 3; continue }
                    flush()
                    switch e {
                    case "n": cur.append("\n")
                    case "t": cur.append("\t")
                    case "r": cur.append("\r")
                    case "u", "U":
                        let len = e == "u" ? 4 : 8
                        guard var code = hex(i + 1, len) else { throw Failure(message: "A \\\(e) escape in the curl command is incomplete.") }
                        i += len
                        // A surrogate pair written as two \u escapes.
                        if (0xD800...0xDBFF).contains(code), i + 2 < chars.count, chars[i + 1] == "\\", chars[i + 2] == "u", let low = hex(i + 3, 4), (0xDC00...0xDFFF).contains(low) {
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                            i += 6
                        }
                        guard let u = Unicode.Scalar(code) else { throw Failure(message: "The curl command has an invalid \\\(e) escape.") }
                        cur.unicodeScalars.append(u)
                    default: cur.append(e)
                    }
                    i += 1
                }
                flush()
                if i >= chars.count { throw unclosed }
            case "\\":
                inWord = true
                if i + 1 < chars.count { i += 1; cur.append(chars[i]) }
            default:
                inWord = true; cur.append(c)
            }
            i += 1
        }
        if inWord { out.append(cur) }
        return out
    }

    // MARK: OpenAPI 3

    static func openAPI(_ doc: [String: Any]) throws -> Result {
        if doc["swagger"] != nil {
            throw Failure(message: "This is an OpenAPI 2 (Swagger) file. Brix reads OpenAPI 3; convert it first (for example with swagger2openapi) and import that.")
        }
        var out = Result()
        let info = doc["info"] as? [String: Any] ?? [:]
        var c = APICollection(name: string(info["title"]).isEmpty ? "Imported API" : string(info["title"]))
        // The first server, with its variables' defaults, becomes {{baseUrl}}.
        if let server = (doc["servers"] as? [[String: Any]])?.first {
            var url = string(server["url"])
            for (k, v) in server["variables"] as? [String: Any] ?? [:] {
                url = url.replacingOccurrences(of: "{\(k)}", with: string((v as? [String: Any])?["default"]))
            }
            c.variables.append(APIField(key: "baseUrl", value: url))
        } else {
            c.variables.append(APIField(key: "baseUrl", value: "http://localhost"))
            out.notes.append("The file names no server, so {{baseUrl}} is set to http://localhost; change it in the collection's variables.")
        }
        let schemes = ((doc["components"] as? [String: Any])?["securitySchemes"] as? [String: Any]) ?? [:]
        var addedVars: Set<String> = ["baseUrl"]
        func addVar(_ key: String, _ value: String = "") {
            if addedVars.insert(key).inserted { c.variables.append(APIField(key: key, value: value)) }
        }
        var authNotes: Set<String> = []
        func authFor(_ security: Any?, _ where_: String) -> APIAuth? {
            guard let list = security as? [[String: Any]] else { return nil }
            // An empty requirement ({}) means signing in is optional.
            guard let first = list.first, !first.isEmpty, let name = first.keys.sorted().first else { return APIAuth(kind: .none) }
            if first.count > 1 { authNotes.insert("\(where_) needs \(first.keys.sorted().joined(separator: " and ")) together; Brix can only send \(name).") }
            if list.count > 1 { authNotes.insert("\(where_) offers \(list.count) ways to sign in; Brix uses \(name).") }
            guard let s = resolve(schemes[name], in: doc) as? [String: Any] else {
                var a = APIAuth(kind: .unsupported)
                a.original = name + " (not defined in the file)"
                return a
            }
            var a = APIAuth()
            switch (string(s["type"]), string(s["scheme"]).lowercased()) {
            case ("http", "bearer"): a.kind = .bearer; a.token = "{{bearerToken}}"; addVar("bearerToken")
            case ("http", "basic"): a.kind = .basic; a.username = "{{username}}"; a.password = "{{password}}"; addVar("username"); addVar("password")
            case ("apiKey", _) where string(s["in"]) != "cookie":
                a.kind = .apiKey; a.key = string(s["name"]); a.value = "{{apiKey}}"; a.inQuery = string(s["in"]) == "query"; addVar("apiKey")
            default:
                a.kind = .unsupported; a.original = string(s["type"]) + (string(s["scheme"]).isEmpty ? "" : " " + string(s["scheme"]))
            }
            return a
        }
        c.auth = authFor(doc["security"], "The API") ?? APIAuth(kind: .none)
        var external = 0, cookies: Set<String> = [], emptyBodies: [String] = []
        var folders: [String: APIFolder] = [:]
        var unsupported: Set<String> = []
        if c.auth.kind == .unsupported { unsupported.insert(c.auth.original) }
        let methods = ["get", "put", "post", "delete", "options", "head", "patch", "trace"]
        for (path, item) in (doc["paths"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let item = resolve(item, in: doc) as? [String: Any] else { external += 1; continue }
            let shared = item["parameters"] as? [Any] ?? []
            for m in methods {
                guard let op = item[m] as? [String: Any] else { continue }
                var r = APIRequest()
                r.method = m.uppercased()
                r.name = [string(op["summary"]), string(op["operationId"])].first { !$0.isEmpty } ?? "\(r.method) \(path)"
                r.url = "{{baseUrl}}" + path.replacingOccurrences(of: "{", with: "{{").replacingOccurrences(of: "}", with: "}}")
                var seen: Set<String> = []
                for raw in (op["parameters"] as? [Any] ?? []) + shared {
                    guard let p = resolve(raw, in: doc) as? [String: Any] else { external += 1; continue }
                    let name = string(p["name"]), place = string(p["in"])
                    guard seen.insert(place + ":" + name).inserted else { continue }
                    let example = exampleText(p, in: doc)
                    switch place {
                    case "query": r.params.append(APIField(key: name, value: example, on: p["required"] as? Bool ?? false))
                    case "header": r.headers.append(APIField(key: name, value: example, on: p["required"] as? Bool ?? false))
                    case "path": addVar(name, example)
                    case "cookie": cookies.insert(name)
                    default: break
                    }
                }
                if let body = resolve(op["requestBody"], in: doc) as? [String: Any], let content = body["content"] as? [String: Any] {
                    applyContent(content, to: &r, in: doc)
                    if r.bodyKind == .json, r.body.isEmpty { emptyBodies.append("“\(r.name)”") }
                } else if op["requestBody"] != nil {
                    external += 1
                }
                if let a = authFor(op["security"], "“\(r.name)”") {
                    r.auth = a
                    if a.kind == .unsupported { unsupported.insert(a.original) }
                }
                let tag = (op["tags"] as? [Any])?.first.map(string) ?? ""
                if !tag.isEmpty {
                    if folders[tag] == nil { folders[tag] = APIFolder(name: tag, parentID: c.id) }
                    r.parentID = folders[tag]!.id
                } else {
                    r.parentID = c.id
                }
                out.requests.append(r)
            }
        }
        guard !out.requests.isEmpty else {
            throw Failure(message: external > 0
                ? "“\(c.name)”'s API calls point to other files, which Brix can't follow. Bundle it into one file (for example with redocly bundle) and import that."
                : "“\(c.name)” describes no API calls (it has no paths, only data models), so there's nothing to import.")
        }
        out.notes += authNotes.sorted()
        if external > 0 { out.notes.append("\(external) part\(external == 1 ? "" : "s") pointing to other files couldn't be followed and \(external == 1 ? "was" : "were") left out; bundle the API into one file to include them.") }
        if !cookies.isEmpty { out.notes.append("Cookie parameters (\(cookies.sorted().joined(separator: ", "))) weren't brought over; add a Cookie header if you need them.") }
        if !emptyBodies.isEmpty { out.notes.append("\(emptyBodies.joined(separator: ", ")) have no example or schema Brix could turn into a body, so it starts empty.") }
        out.collections = [c]
        out.folders = folders.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        for u in unsupported.sorted() { out.notes.append("“\(u)” sign-in isn't supported yet: requests using it won't send until you pick another sign-in.") }
        if addedVars.count > 1 { out.notes.append("Fill in the collection's variables (\(addedVars.subtracting(["baseUrl"]).sorted().joined(separator: ", "))) before sending; lock any secret.") }
        return out
    }

    /// Follows a local `$ref` ("#/components/…"); other values come back as they are.
    static func resolve(_ v: Any?, in doc: [String: Any], depth: Int = 0) -> Any? {
        guard let d = v as? [String: Any], let ref = d["$ref"] as? String else { return v }
        guard depth < 20, ref.hasPrefix("#/") else { return nil }
        var node: Any? = doc
        for part in ref.dropFirst(2).split(separator: "/") {
            let key = part.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            node = (node as? [String: Any])?[key]
        }
        return resolve(node, in: doc, depth: depth + 1)
    }

    private static func exampleText(_ p: [String: Any], in doc: [String: Any]) -> String {
        if let e = p["example"] { return string(e) }
        if let ex = (p["examples"] as? [String: Any])?.values.first.flatMap({ resolve($0, in: doc) as? [String: Any] }), let v = ex["value"] { return string(v) }
        let schema = resolve(p["schema"], in: doc) as? [String: Any] ?? [:]
        if let d = schema["default"] ?? schema["example"] { return string(d) }
        if let e = (schema["enum"] as? [Any])?.first { return string(e) }
        return ""
    }

    private static func applyContent(_ content: [String: Any], to r: inout APIRequest, in doc: [String: Any]) {
        let types = content.keys.sorted()
        if let t = types.first(where: { $0.contains("json") }), let media = content[t] as? [String: Any] {
            r.bodyKind = .json
            let value = media["example"]
                ?? ((media["examples"] as? [String: Any])?.values.first.flatMap { (resolve($0, in: doc) as? [String: Any])?["value"] })
                ?? sample(media["schema"], in: doc, depth: 0)
            if let v = value, let data = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]) {
                r.body = String(decoding: data, as: UTF8.self)
            }
            if t != "application/json" { r.headers.append(APIField(key: "Content-Type", value: t)) }
        } else if let t = types.first(where: { $0 == "application/x-www-form-urlencoded" || $0 == "multipart/form-data" }),
                  let schema = resolve((content[t] as? [String: Any])?["schema"], in: doc) as? [String: Any] {
            r.bodyKind = t == "multipart/form-data" ? .multipart : .form
            let required = Set((schema["required"] as? [Any] ?? []).map(string))
            for (k, v) in (schema["properties"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
                let prop = resolve(v, in: doc) as? [String: Any] ?? [:]
                let isFile = r.bodyKind == .multipart && (string(prop["format"]) == "binary" || string(prop["format"]) == "base64")
                r.formFields.append(APIField(key: k, value: isFile ? "" : string(prop["example"] ?? prop["default"]), on: required.contains(k) || required.isEmpty, isFile: isFile))
            }
        } else if let t = types.first {
            r.bodyKind = .text
            r.headers.append(APIField(key: "Content-Type", value: t))
        }
    }

    /// A made-up value shaped like a schema, for a body to start from.
    static func sample(_ s: Any?, in doc: [String: Any], depth: Int) -> Any? {
        guard depth < 8, let schema = resolve(s, in: doc) as? [String: Any] else { return nil }
        if let e = schema["example"] { return e }
        if let d = schema["default"] { return d }
        if let e = (schema["enum"] as? [Any])?.first { return e }
        if let all = schema["allOf"] as? [Any] {
            var merged: [String: Any] = [:]
            for part in all { (sample(part, in: doc, depth: depth + 1) as? [String: Any])?.forEach { merged[$0.key] = $0.value } }
            return merged
        }
        if let one = (schema["oneOf"] as? [Any] ?? schema["anyOf"] as? [Any])?.first { return sample(one, in: doc, depth: depth + 1) }
        switch string(schema["type"]) {
        case "object", "":
            guard let props = schema["properties"] as? [String: Any] else { return string(schema["type"]).isEmpty ? nil : [String: Any]() }
            var out: [String: Any] = [:]
            for (k, v) in props { out[k] = sample(v, in: doc, depth: depth + 1) ?? NSNull() }
            return out
        case "array": return [sample(schema["items"], in: doc, depth: depth + 1)].compactMap { $0 }
        case "integer": return 0
        case "number": return 0.0
        case "boolean": return false
        default:
            switch string(schema["format"]) {
            case "date-time": return "2026-01-01T00:00:00Z"
            case "date": return "2026-01-01"
            case "email": return "user@example.com"
            case "uuid": return "00000000-0000-0000-0000-000000000000"
            default: return "string"
            }
        }
    }

    // MARK: Insomnia (export format 4)

    static func insomnia(_ obj: [String: Any]) throws -> Result {
        let resources = (obj["resources"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        var out = Result()
        var collectionOf: [String: String] = [:]   // workspace id to collection id
        var folderOf: [String: String] = [:]       // request group id to folder id
        var groupHeaders: [String: [APIField]] = [:], groupParent: [String: String] = [:]
        var templated: [String] = [], fileBodies: [String] = [], unsupported: [String: [String]] = [:]
        var lifted: [String: [APIField]] = [:], taken: [String: Set<String>] = [:]  // per collection id
        let fix = { (s: String) -> String in
            // Insomnia writes {{ _.name }}; Brix and Postman write {{name}}.
            s.replacingOccurrences(of: #"\{\{\s*_\.([A-Za-z0-9_\-\.]+)\s*\}\}"#, with: "{{$1}}", options: .regularExpression)
        }
        func rows(_ list: Any?) -> [APIField] {
            (list as? [[String: Any]] ?? []).map { APIField(key: fix(string($0["name"])), value: fix(string($0["value"])), on: !($0["disabled"] as? Bool ?? false)) }
        }
        /// Insomnia sign-in; literal secrets move to locked variables of the collection.
        func auth(_ raw: Any?, item: String, collection: String?) -> APIAuth? {
            guard let a = raw as? [String: Any], !a.isEmpty else { return nil }
            var auth = APIAuth()
            switch string(a["type"]) {
            case "bearer": auth.kind = .bearer; auth.token = fix(string(a["token"]))
            case "basic": auth.kind = .basic; auth.username = fix(string(a["username"])); auth.password = fix(string(a["password"]))
            case "apikey": auth.kind = .apiKey; auth.key = fix(string(a["key"])); auth.value = fix(string(a["value"])); auth.inQuery = string(a["addTo"]) == "queryParams"
            case "none", "": auth.kind = .inherit
            default: auth.kind = .unsupported; auth.original = string(a["type"]); unsupported[auth.original, default: []].append("“\(item)”")
            }
            if a["disabled"] as? Bool == true { auth.kind = .none }
            if let c = collection {
                auth.token = lock(auth.token, as: item + " token", into: &lifted[c, default: []], taken: &taken[c, default: []])
                auth.password = lock(auth.password, as: item + " password", into: &lifted[c, default: []], taken: &taken[c, default: []])
                if auth.kind == .apiKey { auth.value = lock(auth.value, as: item + " api key", into: &lifted[c, default: []], taken: &taken[c, default: []]) }
            }
            return auth
        }
        func collection(of parent: String) -> String? {
            var p: String? = parent, seen: Set<String> = []
            while let x = p, seen.insert(x).inserted {
                if let c = collectionOf[x] { return c }
                p = groupParent[x]
            }
            return nil
        }
        for w in resources where string(w["_type"]) == "workspace" {
            let c = APICollection(name: string(w["name"]).isEmpty ? "Insomnia" : string(w["name"]))
            collectionOf[string(w["_id"])] = c.id
            out.collections.append(c)
        }
        for g in resources where string(g["_type"]) == "request_group" { groupParent[string(g["_id"])] = string(g["parentId"]) }
        // Groups can nest: place each once its parent is known.
        var groups = resources.filter { string($0["_type"]) == "request_group" }
        while !groups.isEmpty {
            let before = groups.count
            groups.removeAll { g in
                let parent = string(g["parentId"])
                guard let p = collectionOf[parent] ?? folderOf[parent] else { return false }
                var f = APIFolder(name: string(g["name"]).isEmpty ? "Folder" : string(g["name"]), parentID: p)
                f.variables = (g["environment"] as? [String: Any] ?? [:]).sorted { $0.key < $1.key }.map { APIField(key: $0.key, value: fix(string($0.value))) }
                if let a = auth(g["authentication"], item: f.name, collection: collection(of: parent)) { f.auth = a }
                groupHeaders[string(g["_id"])] = rows(g["headers"])
                folderOf[string(g["_id"])] = f.id
                out.folders.append(f)
                return true
            }
            if groups.count == before { out.notes.append("\(groups.count) folder\(groups.count == 1 ? "" : "s") pointed at a missing parent and \(groups.count == 1 ? "was" : "were") left out."); break }
        }
        var loose = 0
        for q in resources where string(q["_type"]) == "request" {
            let parent = string(q["parentId"])
            var r = APIRequest(parentID: folderOf[parent] ?? collectionOf[parent])
            r.name = string(q["name"]).isEmpty ? "Request" : string(q["name"])
            r.method = string(q["method"]).uppercased().isEmpty ? "GET" : string(q["method"]).uppercased()
            r.url = fix(string(q["url"]))
            r.params = rows(q["parameters"])
            r.headers = rows(q["headers"])
            // A folder's headers apply to the requests inside it; Brix folders have none, so each request gets a copy.
            var g: String? = parent, seen: Set<String> = []
            while let x = g, seen.insert(x).inserted {
                for h in groupHeaders[x] ?? [] where !r.headers.contains(where: { $0.key.lowercased() == h.key.lowercased() }) { r.headers.append(h) }
                g = groupParent[x]
            }
            if let body = q["body"] as? [String: Any] {
                let mime = string(body["mimeType"])
                if let params = body["params"] as? [[String: Any]] {
                    r.bodyKind = mime.contains("multipart") ? .multipart : .form
                    r.formFields = params.map {
                        let isFile = string($0["type"]) == "file"
                        return APIField(key: fix(string($0["name"])), value: isFile ? string($0["fileName"]) : fix(string($0["value"])), on: !($0["disabled"] as? Bool ?? false), isFile: isFile)
                    }
                } else if let text = body["text"] as? String {
                    r.body = fix(text)
                    r.bodyKind = mime.contains("json") || mime.contains("graphql") ? .json : .text
                    if mime.contains("graphql") { out.notes.append("“\(r.name)” is a GraphQL request; its body was kept as Insomnia stored it.") }
                    if !mime.isEmpty, !mime.contains("json"), !mime.contains("graphql"), !r.headers.contains(where: { $0.key.lowercased() == "content-type" }) {
                        r.headers.append(APIField(key: "Content-Type", value: mime))
                    }
                } else if !string(body["fileName"]).isEmpty {
                    fileBodies.append("“\(r.name)”")
                }
            }
            if let a = auth(q["authentication"], item: r.name, collection: collection(of: parent)) { r.auth = a }
            let all = [r.url, r.body] + r.headers.map(\.value) + r.params.map(\.value) + r.formFields.map(\.value) + [r.auth.token, r.auth.password, r.auth.value]
            if all.contains(where: { $0.contains("{%") }) { templated.append("“\(r.name)”") }
            if r.parentID == nil { loose += 1 }
            out.requests.append(r)
        }
        // The base environment is the collection's variables; the ones under it are environments.
        // Values with sign-in-like names are locked.
        for e in resources where string(e["_type"]) == "environment" {
            let vars = (e["data"] as? [String: Any] ?? [:]).sorted { $0.key < $1.key }.map { APIField(key: $0.key, value: fix(string($0.value))) }
            let secret = Set(vars.filter { looksSecret($0.key) && !$0.value.isEmpty }.map(\.id))
            if let c = collectionOf[string(e["parentId"])], let i = out.collections.firstIndex(where: { $0.id == c }) {
                out.collections[i].variables += vars
                if !secret.isEmpty { out.secrets[c, default: []].formUnion(secret) }
            } else {
                let env = APIEnvironment(name: string(e["name"]).isEmpty ? "Insomnia environment" : string(e["name"]), vars: vars)
                out.environments.append(env)
                if !secret.isEmpty { out.secrets[env.id] = secret }
            }
        }
        for (c, vars) in lifted where !vars.isEmpty {
            guard let i = out.collections.firstIndex(where: { $0.id == c }) else { continue }
            out.collections[i].variables += vars
            out.secrets[c, default: []].formUnion(vars.map(\.id))
        }
        let lockedCount = out.secrets.values.reduce(0) { $0 + $1.count }
        if lockedCount > 0 { out.notes.append("\(lockedCount) sign-in value\(lockedCount == 1 ? " was" : "s were") locked in the Keychain instead of the project file.") }
        for (type, items) in unsupported.sorted(by: { $0.key < $1.key }) {
            out.notes.append("“\(type)” sign-in on \(items.joined(separator: ", ")) isn't supported yet: those requests won't send until you pick another.")
        }
        if !templated.isEmpty { out.notes.append("\(templated.joined(separator: ", ")) use Insomnia template tags ({% … %}), which Brix sends as written; replace them with values or variables.") }
        if !fileBodies.isEmpty { out.notes.append("\(fileBodies.joined(separator: ", ")) send a file as the whole body; Brix can't do that yet, so the body is empty.") }
        if loose > 0 { out.notes.append("\(loose) request\(loose == 1 ? " wasn't" : "s weren't") in a workspace and \(loose == 1 ? "was" : "were") put outside any collection.") }
        let other = Set(resources.map { string($0["_type"]) }).subtracting(["workspace", "request_group", "request", "environment", "cookie_jar", "api_spec"])
        if !other.isEmpty { out.notes.append("Left out Insomnia items Brix doesn't have: \(other.sorted().joined(separator: ", ")).") }
        guard !out.collections.isEmpty || !out.requests.isEmpty else { throw Failure(message: "This Insomnia export has no requests.") }
        return out
    }

    // MARK: HAR

    /// A browser's recorded traffic: one request per call, in a folder per host.
    /// Sign-in headers, query values and form fields move into locked collection
    /// variables; cookies are left out.
    static func har(_ obj: [String: Any], name: String) throws -> Result {
        guard let entries = (obj["log"] as? [String: Any])?["entries"] as? [Any] else { throw Failure(message: "This HAR file has no entries.") }
        var out = Result()
        var c = APICollection(name: name.isEmpty ? "Recorded traffic" : name)
        var folders: [String: APIFolder] = [:]
        var seen: Set<String> = [], dropped = 0, cookies = 0, files = 0, jsonSecrets = 0
        var vars: [APIField] = [], taken: Set<String> = []
        let skip: Set<String> = ["host", "content-length", "connection", "accept-encoding", "cookie"]
        for case let e as [String: Any] in entries {
            guard let q = e["request"] as? [String: Any], var comps = URLComponents(string: string(q["url"])) else { dropped += 1; continue }
            let method = string(q["method"]).uppercased()
            let host = comps.host ?? "other"
            var r = APIRequest()
            r.method = method.isEmpty ? "GET" : method
            r.params = (comps.queryItems ?? []).map { item in
                APIField(key: item.name, value: looksSecret(item.name) ? lock(item.value ?? "", as: item.name, into: &vars, taken: &taken) : item.value ?? "")
            }
            comps.query = nil
            r.url = comps.string ?? string(q["url"])
            r.name = "\(r.method) \(comps.path.isEmpty ? "/" : comps.path)"
            for h in q["headers"] as? [[String: Any]] ?? [] {
                let k = string(h["name"]), lk = k.lowercased()
                if lk.hasPrefix(":") { continue }
                if lk == "cookie" { cookies += 1 }
                if skip.contains(lk) { continue }
                let v = string(h["value"])
                r.headers.append(APIField(key: k, value: looksSecret(k) ? lock(v, as: k, into: &vars, taken: &taken) : v))
            }
            if let post = q["postData"] as? [String: Any] {
                let mime = string(post["mimeType"]).lowercased()
                if let params = post["params"] as? [[String: Any]], !params.isEmpty {
                    r.bodyKind = mime.contains("multipart") ? .multipart : .form
                    r.formFields = params.map { p in
                        let k = string(p["name"])
                        if !string(p["fileName"]).isEmpty { files += 1; return APIField(key: k, value: string(p["fileName"]), isFile: true) }
                        return APIField(key: k, value: looksSecret(k) ? lock(string(p["value"]), as: k, into: &vars, taken: &taken) : string(p["value"]))
                    }
                    if r.bodyKind == .multipart { r.headers.removeAll { $0.key.lowercased() == "content-type" } }
                } else if let text = post["text"] as? String {
                    r.body = text
                    r.bodyKind = mime.contains("json") ? .json : .text
                    if r.bodyKind == .json, text.range(of: #""(password|passwd|secret|token|client_secret)"\s*:"#, options: [.regularExpression, .caseInsensitive]) != nil { jsonSecrets += 1 }
                }
            }
            // The same call recorded many times becomes one request; any difference keeps both.
            let sig = [r.method, r.url, r.params.map { $0.key + "=" + $0.value }.joined(separator: "&"),
                       r.headers.map { $0.key.lowercased() + ":" + $0.value }.sorted().joined(separator: "\n"),
                       r.formFields.map { $0.key + "=" + $0.value }.joined(separator: "&"), r.body].joined(separator: "\u{1F}")
            guard seen.insert(sig).inserted else { continue }
            if folders[host] == nil { folders[host] = APIFolder(name: host, parentID: c.id) }
            r.parentID = folders[host]!.id
            out.requests.append(r)
        }
        c.variables = vars
        if !vars.isEmpty { out.secrets[c.id] = Set(vars.map(\.id)) }
        out.collections = [c]
        out.folders = folders.values.sorted { $0.name < $1.name }
        if !vars.isEmpty { out.notes.append("Sign-in values were moved into locked collection variables (\(vars.map(\.key).joined(separator: ", "))), kept in the Keychain.") }
        if jsonSecrets > 0 { out.notes.append("\(jsonSecrets) recorded JSON bod\(jsonSecrets == 1 ? "y holds" : "ies hold") a password, secret or token, kept as written; replace it with a locked variable.") }
        if cookies > 0 { out.notes.append("Cookie headers were left out of \(cookies) recorded call\(cookies == 1 ? "" : "s"); add one back if a request needs it.") }
        if files > 0 { out.notes.append("\(files) uploaded file\(files == 1 ? " wasn't" : "s weren't") recorded; pick the file again in the request's Body.") }
        if dropped > 0 { out.notes.append("\(dropped) entr\(dropped == 1 ? "y" : "ies") couldn't be read.") }
        let calls = entries.count - dropped
        if calls > out.requests.count { out.notes.append("\(calls - out.requests.count) repeated call\(calls - out.requests.count == 1 ? " was" : "s were") merged.") }
        guard !out.requests.isEmpty else { throw Failure(message: "This HAR file has no requests Brix can read.") }
        return out
    }
}
