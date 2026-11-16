import Foundation

/// Reads API collections and environments made in other tools.
enum APIImport {
    struct Result {
        var collections: [APICollection] = []
        var folders: [APIFolder] = []
        var requests: [APIRequest] = []
        var environments: [APIEnvironment] = []
        /// Environment rows to move into the Keychain once added: environment id to row ids.
        var secrets: [String: Set<String>] = [:]
        /// What couldn't be brought over, in words.
        var notes: [String] = []
        /// Variables for the collection a loose request (a curl import) goes into, to be locked there.
        var lockedVariables: [APIField] = []

        var summary: String {
            var parts: [String] = []
            if !collections.isEmpty { parts.append("\(collections.count) collection\(collections.count == 1 ? "" : "s")") }
            if !requests.isEmpty { parts.append("\(requests.count) request\(requests.count == 1 ? "" : "s")") }
            if !folders.isEmpty { parts.append("\(folders.count) folder\(folders.count == 1 ? "" : "s")") }
            if !environments.isEmpty { parts.append("\(environments.count) environment\(environments.count == 1 ? "" : "s")") }
            return parts.joined(separator: ", ")
        }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Postman collections and environments, OpenAPI 3 (JSON or YAML), Insomnia
    /// exports, HAR recordings, or a curl command, told apart by their contents.
    static func read(_ data: Data, fileName: String = "") throws -> Result {
        let label = fileName.isEmpty ? "This" : fileName
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("curl ") || text.hasPrefix("curl.exe ") { return try curl(text) }
        let obj: [String: Any]
        let looksJSON = text.hasPrefix("{") || text.hasPrefix("[")
        do {
            if looksJSON {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure(message: "it's a JSON list, not an object") }
                obj = json
            } else {
                guard let yaml = try MiniYAML.parse(text) as? [String: Any], !yaml.isEmpty else { throw Failure(message: "it has no fields") }
                obj = yaml
            }
        } catch {
            let what = looksJSON ? "JSON" : "YAML"
            throw Failure(message: "\(label) couldn't be read as \(what): \(error.localizedDescription). Brix imports Postman, OpenAPI 3, Insomnia and HAR files, and curl commands.")
        }
        if obj["openapi"] != nil || obj["swagger"] != nil { return try openAPI(obj) }
        if string(obj["type"]).contains("insomnia") {
            throw Failure(message: "\(label) is an Insomnia 5 (YAML) export. Export from Insomnia as “Insomnia v4 (JSON)” and import that.")
        }
        if string(obj["_type"]) == "export", obj["resources"] is [Any] { return try insomnia(obj) }
        if (obj["log"] as? [String: Any])?["entries"] != nil { return try har(obj, name: ((fileName as NSString).deletingPathExtension)) }
        if let info = obj["info"] as? [String: Any], obj["item"] is [Any] { return postmanCollection(obj, info: info) }
        if obj["values"] is [Any], obj["name"] is String { return postmanEnvironment(obj) }
        throw Failure(message: "\(label) isn't a Postman, OpenAPI 3, Insomnia or HAR file Brix recognises.")
    }

    // MARK: Postman collection (v2.0 and v2.1)

    /// What a collection import gathers on the way down.
    private struct Walk {
        var out = Result()
        var scripts = 0
        var skipped = 0
        var getBodies: [String] = []
        var unsupported: [String: [String]] = [:]
        var partTypes = 0
        /// Sign-in secrets lifted into locked collection variables.
        var lifted: [APIField] = []
        var takenKeys: Set<String> = []
    }

    static func postmanCollection(_ obj: [String: Any], info: [String: Any]) -> Result {
        var w = Walk()
        var c = APICollection(name: string(info["name"]).isEmpty ? "Imported collection" : string(info["name"]))
        c.variables = fields(obj["variable"])
        w.takenKeys = Set(c.variables.map(\.key))
        w.scripts = (obj["event"] as? [Any])?.count ?? 0
        if var a = auth(obj["auth"], item: c.name, w: &w) {
            lift(&a, owner: c.name, w: &w)
            c.auth = a.kind == .inherit ? APIAuth(kind: .none) : a
        }
        walk(obj["item"], parent: c.id, w: &w)
        c.variables += w.lifted
        var out = w.out
        if !w.lifted.isEmpty {
            out.secrets[c.id] = Set(w.lifted.map(\.id))
            out.notes.append("Sign-in secrets were moved into locked collection variables (\(w.lifted.map(\.key).joined(separator: ", "))), kept in the Keychain instead of the project file.")
        }
        out.collections.insert(c, at: 0)
        for (type, items) in w.unsupported.sorted(by: { $0.key < $1.key }) {
            out.notes.append("“\(type)” sign-in on \(items.joined(separator: ", ")) isn't supported yet: the requests using it won't send until you pick another sign-in.")
        }
        if w.scripts > 0 { out.notes.append("\(w.scripts) pre-request or test script\(w.scripts == 1 ? "" : "s") not brought over: Brix doesn't run Postman scripts yet.") }
        if w.skipped > 0 { out.notes.append("\(w.skipped) item\(w.skipped == 1 ? "" : "s") couldn't be read and were left out.") }
        if !w.getBodies.isEmpty { out.notes.append("\(w.getBodies.joined(separator: ", ")) send a body with GET or HEAD in Postman; Brix sends those without one.") }
        if w.partTypes > 0 { out.notes.append("\(w.partTypes) multipart field content type\(w.partTypes == 1 ? " was" : "s were") not kept; Brix sends files with their usual type.") }
        return out
    }

    private static func walk(_ items: Any?, parent: String, w: inout Walk) {
        for entry in (items as? [Any]) ?? [] {
            guard let item = entry as? [String: Any] else { w.skipped += 1; continue }
            w.scripts += (item["event"] as? [Any])?.count ?? 0
            let name = string(item["name"])
            if item["item"] != nil {
                var f = APIFolder(name: name.isEmpty ? "Folder" : name, parentID: parent)
                f.variables = fields(item["variable"])
                if var a = auth(item["auth"], item: f.name, w: &w) { lift(&a, owner: f.name, w: &w); f.auth = a }
                w.out.folders.append(f)
                walk(item["item"], parent: f.id, w: &w)
            } else if let r = request(item["request"], name: name, parent: parent, w: &w) {
                w.out.requests.append(r)
            } else {
                w.skipped += 1
            }
        }
    }

    private static func request(_ raw: Any?, name: String, parent: String, w: inout Walk) -> APIRequest? {
        var r = APIRequest(parentID: parent)
        r.name = name.isEmpty ? "Request" : name
        if let s = raw as? String { r.url = s; return r }
        guard let d = raw as? [String: Any] else { return nil }
        r.method = string(d["method"]).uppercased().isEmpty ? "GET" : string(d["method"]).uppercased()
        (r.url, r.params) = url(d["url"])
        r.headers = fields(d["header"])
        if var a = auth(d["auth"], item: r.name, w: &w) { lift(&a, owner: r.name, w: &w); r.auth = a }
        if let body = d["body"] as? [String: Any] { applyBody(body, to: &r, w: &w) }
        if ["GET", "HEAD"].contains(r.method), r.bodyKind != .none { w.getBodies.append("“\(r.name)”") }
        return r
    }

    /// The URL without its query (the query becomes rows), path variables (`:id`) as {{id}}
    /// or their saved value.
    static func url(_ u: Any?) -> (String, [APIField]) {
        if let s = u as? String { return (s, []) }
        guard let d = u as? [String: Any] else { return ("", []) }
        let query = fields(d["query"])
        var base: String
        if let raw = d["raw"] as? String {
            base = query.isEmpty ? raw : String(raw.prefix { $0 != "?" })
        } else {
            let host = (d["host"] as? [Any])?.map(string).joined(separator: ".") ?? string(d["host"])
            let path = (d["path"] as? [Any])?.map(string).joined(separator: "/") ?? string(d["path"])
            let proto = string(d["protocol"])
            base = (proto.isEmpty ? "" : proto + "://") + host + (string(d["port"]).isEmpty ? "" : ":" + string(d["port"])) + (path.isEmpty ? "" : "/" + path)
        }
        for v in fields(d["variable"]) where !v.key.isEmpty {
            // Only the whole name: ":id" doesn't touch ":idx".
            let pattern = ":" + NSRegularExpression.escapedPattern(for: v.key) + "(?=$|[/?#.;,])"
            let value = v.value.isEmpty ? "{{\(v.key)}}" : v.value
            base = base.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: value), options: .regularExpression)
        }
        return (base, query)
    }

    private static func applyBody(_ b: [String: Any], to r: inout APIRequest, w: inout Walk) {
        switch string(b["mode"]) {
        case "raw":
            r.body = string(b["raw"])
            let lang = string(((b["options"] as? [String: Any])?["raw"] as? [String: Any])?["language"]).lowercased()
            let trimmed = r.body.trimmingCharacters(in: .whitespacesAndNewlines)
            r.bodyKind = lang == "json" || (lang.isEmpty && (trimmed.hasPrefix("{") || trimmed.hasPrefix("["))) ? .json : .text
            let types = ["xml": "application/xml", "html": "text/html", "javascript": "application/javascript"]
            if let type = types[lang], !r.headers.contains(where: { $0.key.lowercased() == "content-type" }) {
                r.headers.append(APIField(key: "Content-Type", value: type))
            }
        case "urlencoded":
            r.bodyKind = .form
            r.formFields = fields(b["urlencoded"])
        case "formdata":
            r.bodyKind = .multipart
            r.formFields = ((b["formdata"] as? [Any]) ?? []).compactMap { e in
                guard let d = e as? [String: Any] else { w.skipped += 1; return nil }
                let isFile = string(d["type"]) == "file"
                if !string(d["contentType"]).isEmpty { w.partTypes += 1 }
                let src = (d["src"] as? [Any])?.first.map(string) ?? string(d["src"])
                return APIField(key: string(d["key"]), value: isFile ? src : string(d["value"]), on: !(d["disabled"] as? Bool ?? false), isFile: isFile)
            }
        case "graphql":
            let g = b["graphql"] as? [String: Any] ?? [:]
            var payload: [String: Any] = ["query": string(g["query"])]
            let vars = string(g["variables"]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !vars.isEmpty {
                if let v = try? JSONSerialization.jsonObject(with: Data(vars.utf8)) { payload["variables"] = v } else {
                    w.out.notes.append("“\(r.name)”: its GraphQL variables aren't valid JSON, so they were left out of the body.")
                }
            }
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .withoutEscapingSlashes]) {
                r.body = String(decoding: data, as: UTF8.self)
                r.bodyKind = .json
            } else {
                w.out.notes.append("“\(r.name)”: its GraphQL body couldn't be converted, so it was left empty.")
            }
        case "file":
            w.out.notes.append("“\(r.name)” sends a file as its whole body; Brix can't do that yet, so its body was left empty.")
        default:
            break
        }
    }

    /// Postman auth, in v2.1's list form ([{key, value}]) or v2.0's object form.
    /// A type Brix can't do is kept as `unsupported`, so requests using it refuse
    /// to send instead of going out unsigned or with a parent's credentials.
    private static func auth(_ a: Any?, item: String, w: inout Walk) -> APIAuth? {
        guard let a = a as? [String: Any] else { return nil }
        let type = string(a["type"])
        var out = APIAuth()
        switch type {
        case "": return nil
        case "noauth": out.kind = .none
        case "bearer": out.kind = .bearer; out.token = authValue(a, type, "token")
        case "basic": out.kind = .basic; out.username = authValue(a, type, "username"); out.password = authValue(a, type, "password")
        case "apikey": out.kind = .apiKey; out.key = authValue(a, type, "key"); out.value = authValue(a, type, "value"); out.inQuery = authValue(a, type, "in") == "query"
        default:
            out.kind = .unsupported
            out.original = type
            w.unsupported[type, default: []].append("“\(item)”")
        }
        return out
    }

    static func authValue(_ a: [String: Any], _ type: String, _ k: String) -> String {
        if let list = a[type] as? [[String: Any]] { return list.first { string($0["key"]) == k }.map { string($0["value"]) } ?? "" }
        if let d = a[type] as? [String: Any] { return string(d[k]) }
        return ""
    }

    /// A literal token, password or key value moves into a locked collection variable
    /// and the sign-in refers to it; one that's already a {{variable}} stays.
    private static func lift(_ a: inout APIAuth, owner: String, w: inout Walk) {
        func move(_ value: inout String, _ what: String) {
            let v = value.trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty, !(v.hasPrefix("{{") && v.hasSuffix("}}") && v.dropFirst(2).dropLast(2).allSatisfy { $0 != "{" && $0 != "}" }) else { return }
            let slug = owner.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
                .split(separator: "_").joined(separator: "_")
            var key = (slug.isEmpty ? "" : slug + "_") + what, n = 2
            while w.takenKeys.contains(key) { key = (slug.isEmpty ? "" : slug + "_") + what + "_\(n)"; n += 1 }
            w.takenKeys.insert(key)
            w.lifted.append(APIField(key: key, value: value))
            value = "{{\(key)}}"
        }
        switch a.kind {
        case .bearer: move(&a.token, "token")
        case .basic: move(&a.password, "password")
        case .apiKey: move(&a.value, "api_key")
        default: break
        }
    }

    // MARK: Postman environment

    static func postmanEnvironment(_ obj: [String: Any]) -> Result {
        var out = Result()
        var env = APIEnvironment(name: string(obj["name"]).isEmpty ? "Imported environment" : string(obj["name"]))
        var secret: Set<String> = []
        for case let v as [String: Any] in (obj["values"] as? [Any]) ?? [] {
            let f = APIField(key: string(v["key"]), value: string(v["value"]), on: v["enabled"] as? Bool ?? true)
            env.vars.append(f)
            if string(v["type"]) == "secret" { secret.insert(f.id) }
        }
        out.environments.append(env)
        if !secret.isEmpty { out.secrets[env.id] = secret }
        return out
    }

    // MARK: Helpers

    /// Postman's [{key, value, disabled}] rows.
    static func fields(_ list: Any?) -> [APIField] {
        ((list as? [Any]) ?? []).compactMap { e in
            guard let d = e as? [String: Any] else { return nil }
            return APIField(key: string(d["key"]), value: string(d["value"]), on: !(d["disabled"] as? Bool ?? false))
        }
    }

    static func string(_ v: Any?) -> String {
        switch v {
        case let s as String: s
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): n.boolValue ? "true" : "false"
        case let n as NSNumber: n.stringValue
        case nil, is NSNull: ""
        default: "\(v!)"
        }
    }
}
