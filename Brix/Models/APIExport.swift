import Foundation

/// Writes requests out for other tools: a collection as Postman v2.1, a request as curl.
enum APIExport {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The collection, its folders and requests as a Postman v2.1 file. The file is
    /// meant to be shared, so locked values, sign-in secrets and sign-in-like headers
    /// and variables are written empty; `emptied` names them.
    static func postman(_ c: APICollection, in api: APIWorkspace) throws -> (data: Data, emptied: [String]) {
        var emptied: [String] = []
        /// A secret written as a {{variable}} is safe to share; a literal one isn't.
        func scrub(_ value: String, _ what: String) -> String {
            let v = value.trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty, !(v.hasPrefix("{{") && v.hasSuffix("}}")) else { return value }
            emptied.append(what)
            return ""
        }
        func vars(_ list: [APIField], locked: Set<String> = [], owner: String) -> [[String: Any]] {
            list.map { f in
                var value = f.value
                if locked.contains(f.id) { emptied.append("\(owner): \(f.key)"); value = "" }
                else if APIImport.looksSecret(f.key) { value = scrub(f.value, "\(owner): \(f.key)") }
                var v: [String: Any] = ["key": f.key, "value": value]
                if !f.on { v["disabled"] = true }
                return v
            }
        }
        func safeAuth(_ a: APIAuth, owner: String) -> [String: Any]? {
            var a = a
            a.token = scrub(a.token, "\(owner): token")
            a.password = scrub(a.password, "\(owner): password")
            if a.kind == .apiKey { a.value = scrub(a.value, "\(owner): API key") }
            return auth(a)
        }
        func items(in parent: String) -> [[String: Any]] {
            api.folders.filter { $0.parentID == parent }.map { f in
                var d: [String: Any] = ["name": f.name, "item": items(in: f.id)]
                if let a = safeAuth(f.auth, owner: f.name) { d["auth"] = a }
                if !f.variables.isEmpty { d["variable"] = vars(f.variables, owner: f.name) }
                return d
            } + api.requests.filter { $0.parentID == parent }.map { r in
                var r = r
                r.auth.token = scrub(r.auth.token, "\(r.name): token")
                r.auth.password = scrub(r.auth.password, "\(r.name): password")
                if r.auth.kind == .apiKey { r.auth.value = scrub(r.auth.value, "\(r.name): API key") }
                for i in r.headers.indices where APIImport.looksSecret(r.headers[i].key) {
                    r.headers[i].value = scrub(r.headers[i].value, "\(r.name): \(r.headers[i].key)")
                }
                for i in r.params.indices where APIImport.looksSecret(r.params[i].key) {
                    r.params[i].value = scrub(r.params[i].value, "\(r.name): \(r.params[i].key)")
                }
                return ["name": r.name, "request": request(r)]
            }
        }
        var out: [String: Any] = [
            "info": ["name": c.name, "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"],
            "item": items(in: c.id),
        ]
        if !c.variables.isEmpty { out["variable"] = vars(c.variables, locked: c.secrets, owner: c.name) }
        if let a = safeAuth(c.auth, owner: c.name) { out["auth"] = a }
        do {
            return (try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), emptied)
        } catch {
            throw Failure(message: "The collection couldn't be written as JSON: \(error.localizedDescription)")
        }
    }

    static func request(_ r: APIRequest) -> [String: Any] {
        func rows(_ list: [APIField]) -> [[String: Any]] {
            list.map { f in
                var d: [String: Any] = ["key": f.key, "value": f.value]
                if !f.on { d["disabled"] = true }
                return d
            }
        }
        let query = r.params.filter { !$0.key.isEmpty }
        let active = query.filter(\.on).map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        var url: [String: Any] = ["raw": r.url + (active.isEmpty ? "" : "?" + active)]
        if !query.isEmpty { url["query"] = rows(query) }
        var d: [String: Any] = ["method": r.method, "header": rows(r.headers), "url": url]
        if let a = auth(r.auth) { d["auth"] = a }
        switch r.bodyKind {
        case .none: break
        case .json: d["body"] = ["mode": "raw", "raw": r.body, "options": ["raw": ["language": "json"]]]
        case .text: d["body"] = ["mode": "raw", "raw": r.body]
        case .form: d["body"] = ["mode": "urlencoded", "urlencoded": rows(r.formFields)]
        case .multipart:
            d["body"] = ["mode": "formdata", "formdata": r.formFields.map { f -> [String: Any] in
                var x: [String: Any] = ["key": f.key, "type": f.isFile ? "file" : "text"]
                x[f.isFile ? "src" : "value"] = f.value
                if !f.on { x["disabled"] = true }
                return x
            }]
        }
        return d
    }

    /// Postman's auth block; nil for Inherit (Postman's default too).
    static func auth(_ a: APIAuth) -> [String: Any]? {
        func kv(_ pairs: [(String, String)]) -> [[String: Any]] { pairs.map { ["key": $0.0, "value": $0.1, "type": "string"] } }
        switch a.kind {
        case .inherit: return nil
        case .none: return ["type": "noauth"]
        case .bearer: return ["type": "bearer", "bearer": kv([("token", a.token)])]
        case .basic: return ["type": "basic", "basic": kv([("username", a.username), ("password", a.password)])]
        case .apiKey: return ["type": "apikey", "apikey": kv([("key", a.key), ("value", a.value), ("in", a.inQuery ? "query" : "header")])]
        // Kept as its type so Postman still shows it; its settings were never brought over.
        case .unsupported: return ["type": a.original.isEmpty ? "noauth" : a.original.components(separatedBy: " ").first!]
        }
    }

    /// The request as Brix would send it, as one curl command.
    static func curl(_ r: APIRequest, sent req: URLRequest) -> String {
        var parts = ["curl"]
        if r.method == "HEAD" { parts.append("-I") }  // -X HEAD makes curl wait for a body that never comes
        else if r.method != "GET" || (req.httpBody != nil && r.bodyKind != .none) { parts += ["-X", r.method] }
        parts.append(quote(req.url?.absoluteString ?? r.url))
        for (k, v) in (req.allHTTPHeaderFields ?? [:]).sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            if r.bodyKind == .multipart, k.lowercased() == "content-type" { continue }  // curl writes its own boundary
            parts += ["-H", quote("\(k): \(v)")]
        }
        if r.bodyKind == .multipart {
            for f in r.formFields where f.on && !f.key.isEmpty {
                // --form-string sends text as it is: with -F a value starting with @ or < reads a file.
                parts += f.isFile ? ["-F", quote("\(f.key)=@\(f.value)")] : ["--form-string", quote("\(f.key)=\(f.value)")]
            }
        } else if let body = req.httpBody, !body.isEmpty {
            parts += ["--data-raw", quote(String(decoding: body, as: UTF8.self))]
        }
        return parts.joined(separator: " ")
    }

    /// Single-quoted for a POSIX shell.
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
