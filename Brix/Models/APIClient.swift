import Foundation
import UniformTypeIdentifiers

/// Decodes a list one element at a time: an element this version can't read is
/// skipped (and counted) instead of emptying the whole list.
private struct SkipElement: Decodable { init(from decoder: Decoder) throws {} }

extension KeyedDecodingContainer {
    func lossy<T: Decodable>(_ type: T.Type, _ key: Key, dropped: inout Int) -> [T] {
        guard contains(key) else { return [] }
        guard var list = try? nestedUnkeyedContainer(forKey: key) else { dropped += 1; return [] }
        var out: [T] = []
        while !list.isAtEnd {
            if let v = try? list.decode(T.self) { out.append(v) } else if (try? list.decode(SkipElement.self)) == nil { dropped += 1; break } else { dropped += 1 }
        }
        return out
    }

    func lossy<T: Decodable>(_ type: T.Type, _ key: Key) -> [T] {
        var ignored = 0
        return lossy(type, key, dropped: &ignored)
    }
}

/// A header, query parameter, form field or variable row: off rows are kept but not sent.
struct APIField: Codable, Hashable, Identifiable {
    var id = UUID().uuidString
    var key = ""
    var value = ""
    var on = true
    /// A multipart field sending the file at the path in `value`.
    var isFile = false

    init(key: String = "", value: String = "", on: Bool = true, isFile: Bool = false) {
        self.key = key; self.value = value; self.on = on; self.isFile = isFile
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = (try? c.decode(String.self, forKey: .key)) ?? ""
        // A row's id names its Keychain item: a missing one falls back to the key,
        // the same on every load, not a new random id that would lose the secret.
        id = (try? c.decode(String.self, forKey: .id)) ?? "key:" + key
        value = (try? c.decode(String.self, forKey: .value)) ?? ""
        on = (try? c.decode(Bool.self, forKey: .on)) ?? true
        isFile = (try? c.decode(Bool.self, forKey: .isFile)) ?? false
    }
}

enum APIBodyKind: String, Codable, CaseIterable, Identifiable {
    case none, json, text, form, multipart
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: "None"
        case .json: "JSON"
        case .text: "Text"
        case .form: "Form"
        case .multipart: "Multipart"
        }
    }
}

/// How a request signs in. `inherit` takes its folder's, then its collection's.
struct APIAuth: Codable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case inherit, none, bearer, basic, apiKey
        /// Imported sign-in Brix can't do (OAuth 2, Digest…): requests using it don't send.
        case unsupported
        var id: String { rawValue }
        static let editable: [Kind] = [.inherit, .none, .bearer, .basic, .apiKey]
        var label: String {
            switch self {
            case .inherit: "Inherit"
            case .none: "None"
            case .bearer: "Bearer"
            case .basic: "Basic"
            case .apiKey: "API Key"
            case .unsupported: "Unsupported"
            }
        }
    }
    var kind = Kind.inherit
    var token = ""
    var username = ""
    var password = ""
    var key = ""
    var value = ""
    /// API key sent as a query parameter instead of a header.
    var inQuery = false
    /// For `unsupported`: the other tool's name for it ("oauth2").
    var original = ""

    init(kind: Kind = .inherit) { self.kind = kind }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .inherit
        token = (try? c.decode(String.self, forKey: .token)) ?? ""
        username = (try? c.decode(String.self, forKey: .username)) ?? ""
        password = (try? c.decode(String.self, forKey: .password)) ?? ""
        key = (try? c.decode(String.self, forKey: .key)) ?? ""
        value = (try? c.decode(String.self, forKey: .value)) ?? ""
        inQuery = (try? c.decode(Bool.self, forKey: .inQuery)) ?? false
        original = (try? c.decode(String.self, forKey: .original)) ?? ""
    }
}

struct APIRequest: Codable, Hashable, Identifiable {
    static let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

    var id = UUID().uuidString
    var name = "New request"
    /// The collection or folder it's in; nil for one outside any collection.
    var parentID: String?
    var method = "GET"
    var url = ""
    var params: [APIField] = []
    var headers: [APIField] = []
    var auth = APIAuth()
    var bodyKind = APIBodyKind.none
    var body = ""
    /// Fields of a Form or Multipart body.
    var formFields: [APIField] = []

    init(parentID: String? = nil) { self.parentID = parentID }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        name = (try? c.decode(String.self, forKey: .name)) ?? "Request"
        parentID = try? c.decode(String.self, forKey: .parentID)
        method = (try? c.decode(String.self, forKey: .method)) ?? "GET"
        url = (try? c.decode(String.self, forKey: .url)) ?? ""
        params = c.lossy(APIField.self, .params)
        headers = c.lossy(APIField.self, .headers)
        auth = (try? c.decode(APIAuth.self, forKey: .auth)) ?? APIAuth()
        bodyKind = (try? c.decode(APIBodyKind.self, forKey: .bodyKind)) ?? .none
        body = (try? c.decode(String.self, forKey: .body)) ?? ""
        formFields = c.lossy(APIField.self, .formFields)
    }
}

struct APIFolder: Codable, Hashable, Identifiable {
    var id = UUID().uuidString
    var name = "New folder"
    /// The collection or folder it's in.
    var parentID: String
    var auth = APIAuth()
    /// Used as {{name}} by the requests inside; win over the collection's.
    var variables: [APIField] = []

    init(name: String = "New folder", parentID: String) { self.name = name; self.parentID = parentID }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        name = (try? c.decode(String.self, forKey: .name)) ?? "Folder"
        parentID = try c.decode(String.self, forKey: .parentID)
        auth = (try? c.decode(APIAuth.self, forKey: .auth)) ?? APIAuth()
        variables = c.lossy(APIField.self, .variables)
    }
}

/// A set of requests and folders with its own variables and sign-in, like a Postman collection.
struct APICollection: Codable, Hashable, Identifiable {
    var id = UUID().uuidString
    var name = "New collection"
    var variables: [APIField] = []
    /// Ids of the variables whose value is kept in the Keychain.
    var secrets: Set<String> = []
    var auth = APIAuth(kind: .none)

    init(name: String = "New collection") { self.name = name }

    func secretAccount(_ field: APIField) -> String { "api-colvar-\(id)-\(field.id)" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        name = (try? c.decode(String.self, forKey: .name)) ?? "Collection"
        variables = c.lossy(APIField.self, .variables)
        secrets = Set(c.lossy(String.self, .secrets))
        auth = (try? c.decode(APIAuth.self, forKey: .auth)) ?? APIAuth(kind: .none)
    }
}

/// A named set of variables used as {{name}} in a request. Secret values live in
/// the Keychain, never in the saved workspace file: `value` is empty for them.
struct APIEnvironment: Codable, Hashable, Identifiable {
    var id = UUID().uuidString
    var name = "Local"
    var vars: [APIField] = []
    /// Ids of the rows whose value is kept in the Keychain.
    var secrets: Set<String> = []

    init(name: String = "Local", vars: [APIField] = []) { self.name = name; self.vars = vars }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? "Environment"
        id = (try? c.decode(String.self, forKey: .id)) ?? "name:" + name
        vars = c.lossy(APIField.self, .vars)
        secrets = Set(c.lossy(String.self, .secrets))
    }

    /// Keychain account for one secret variable (by row id, so renaming the key keeps it).
    func secretAccount(_ field: APIField) -> String { "api-var-\(id)-\(field.id)" }
}

/// One sent request, for the History list.
struct APIHistoryItem: Codable, Hashable, Identifiable {
    var id = UUID().uuidString
    var date = Date()
    var request: APIRequest
    var status: Int?
    var ms: Int
}

/// A project's collections, requests, environments and history, saved with its workspace.
struct APIWorkspace: Codable, Hashable {
    var collections: [APICollection] = []
    var folders: [APIFolder] = []
    var requests: [APIRequest] = []
    var environments: [APIEnvironment] = []
    var environmentID: String?
    /// A request, folder or collection.
    var selectedID: String?
    /// Collections and folders shown closed in the list.
    var collapsed: Set<String> = []
    var history: [APIHistoryItem] = []
    /// Saved entries that couldn't be read at load; not saved. The workspace keeps a copy of the file when this isn't 0.
    var dropped = 0
    static let historyLimit = 50

    private enum CodingKeys: String, CodingKey { case collections, folders, requests, environments, environmentID, selectedID, collapsed, history }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        collections = c.lossy(APICollection.self, .collections, dropped: &dropped)
        folders = c.lossy(APIFolder.self, .folders, dropped: &dropped)
        requests = c.lossy(APIRequest.self, .requests, dropped: &dropped)
        environments = c.lossy(APIEnvironment.self, .environments, dropped: &dropped)
        environmentID = try? c.decode(String.self, forKey: .environmentID)
        selectedID = try? c.decode(String.self, forKey: .selectedID)
        collapsed = Set(c.lossy(String.self, .collapsed))
        history = c.lossy(APIHistoryItem.self, .history, dropped: &dropped)
        repair()
    }

    /// Requests and folders whose container is gone (a folder that couldn't be read)
    /// or that loop back on themselves would be hidden for good: requests become
    /// loose, folders go into a "Recovered" collection.
    mutating func repair() {
        let containers = Set(collections.map(\.id) + folders.map(\.id))
        for i in requests.indices where requests[i].parentID.map(containers.contains) == false { requests[i].parentID = nil }
        var rescue: String?
        // Moving the top of a broken chain brings the folders under it along.
        while let i = folders.indices.first(where: { !ancestorsReachCollection(folders[$0].id) && folder(folders[$0].parentID) == nil })
                ?? folders.indices.first(where: { !ancestorsReachCollection(folders[$0].id) }) {
            if rescue == nil {
                if let c = collections.first(where: { $0.name == "Recovered" }) { rescue = c.id } else {
                    let c = APICollection(name: "Recovered")
                    collections.append(c)
                    rescue = c.id
                }
            }
            folders[i].parentID = rescue!
        }
    }

    private func ancestorsReachCollection(_ id: String) -> Bool {
        var next = folder(id)?.parentID, seen: Set<String> = [id]
        while let p = next {
            if collections.contains(where: { $0.id == p }) { return true }
            guard seen.insert(p).inserted else { return false }
            next = folder(p)?.parentID
        }
        return false
    }

    /// Every value locked in the Keychain, with a name to show if it can't be removed.
    var lockedAccounts: [(name: String, account: String)] {
        environments.flatMap { e in e.vars.filter { e.secrets.contains($0.id) }.map { ("\(e.name): \($0.key)", e.secretAccount($0)) } }
            + collections.flatMap { c in c.variables.filter { c.secrets.contains($0.id) }.map { ("\(c.name): \($0.key)", c.secretAccount($0)) } }
    }

    var environment: APIEnvironment? { environments.first { $0.id == environmentID } }

    mutating func record(_ r: APIRequest, status: Int?, ms: Int) {
        history.insert(APIHistoryItem(request: r, status: status, ms: ms), at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
    }

    // MARK: Tree

    func isCollection(_ id: String) -> Bool { collections.contains { $0.id == id } }
    func folder(_ id: String) -> APIFolder? { folders.first { $0.id == id } }
    func request(_ id: String) -> APIRequest? { requests.first { $0.id == id } }

    /// The collection or folder holding this item.
    func parent(of id: String) -> String? { request(id)?.parentID ?? folder(id)?.parentID }

    /// Its containers, nearest first, up to the collection.
    func ancestors(of id: String) -> [String] {
        var out: [String] = [], next = parent(of: id)
        while let p = next, !out.contains(p) { out.append(p); next = folder(p)?.parentID }
        return out
    }

    func collection(of id: String) -> APICollection? {
        ancestors(of: id).last.flatMap { last in collections.first { $0.id == last } } ?? collections.first { $0.id == id }
    }

    /// Names from the collection down to the item's folder: "Shop / Orders".
    func path(of id: String) -> String {
        ancestors(of: id).reversed().compactMap { p in folder(p)?.name ?? collections.first { $0.id == p }?.name }.joined(separator: " / ")
    }

    /// The sign-in a request uses: its own, else its nearest folder's or collection's.
    func auth(for r: APIRequest) -> (auth: APIAuth, from: String?) {
        r.auth.kind != .inherit ? (r.auth, nil) : inheritedAuth(from: r.parentID)
    }

    /// What Inherit means inside this container: the first folder up that sets a
    /// sign-in, else the collection's.
    func inheritedAuth(from container: String?) -> (auth: APIAuth, from: String?) {
        var next = container, seen: Set<String> = []
        while let p = next, seen.insert(p).inserted {
            if let f = folder(p) {
                if f.auth.kind != .inherit { return (f.auth, f.name) }
                next = f.parentID
            } else if let c = collections.first(where: { $0.id == p }) {
                return (c.auth.kind == .inherit ? APIAuth(kind: .none) : c.auth, c.name)
            } else { break }
        }
        return (APIAuth(kind: .none), nil)
    }

    /// A container for something new next to the selection: the selected collection or
    /// folder, or the one holding the selected request.
    var selectedContainer: String? {
        guard let s = selectedID else { return nil }
        if isCollection(s) || folder(s) != nil { return s }
        return request(s)?.parentID
    }

    /// Removes an item and everything inside it; returns the removed requests' ids.
    @discardableResult
    mutating func delete(_ id: String) -> [String] {
        var gone: Set<String> = [id], grew = true
        while grew {
            let before = gone.count
            for f in folders where gone.contains(f.parentID) { gone.insert(f.id) }
            grew = gone.count != before
        }
        let removedRequests = requests.filter { gone.contains($0.id) || $0.parentID.map(gone.contains) == true }.map(\.id)
        requests.removeAll { gone.contains($0.id) || $0.parentID.map(gone.contains) == true }
        folders.removeAll { gone.contains($0.id) }
        collections.removeAll { $0.id == id }
        collapsed.subtract(gone)
        if let s = selectedID, gone.contains(s) || removedRequests.contains(s) { selectedID = nil }
        return removedRequests
    }

    /// Drag and drop: onto a collection or folder puts the item inside it, onto a
    /// request puts it just above that request. A folder never goes inside itself.
    mutating func move(_ id: String, onto target: String) {
        guard id != target else { return }
        if isCollection(id) {
            guard isCollection(target), let from = collections.firstIndex(where: { $0.id == id }) else { return }
            let c = collections.remove(at: from)
            collections.insert(c, at: collections.firstIndex { $0.id == target } ?? collections.endIndex)
            return
        }
        let into: String?, before: String?
        if isCollection(target) || folder(target) != nil { into = target; before = nil } else if let r = request(target) { into = r.parentID; before = target } else { return }
        if let i = folders.firstIndex(where: { $0.id == id }) {
            guard let into, into != id, !ancestorsOfContainer(into).contains(id) else { return }
            var f = folders.remove(at: i)
            f.parentID = into
            folders.append(f)
        } else if let i = requests.firstIndex(where: { $0.id == id }) {
            var r = requests.remove(at: i)
            r.parentID = into
            requests.insert(r, at: before.flatMap { b in requests.firstIndex { $0.id == b } } ?? requests.endIndex)
        }
    }

    /// A container and the folders above it.
    private func ancestorsOfContainer(_ id: String) -> [String] {
        var out = [id], next = folder(id)?.parentID
        while let p = next, !out.contains(p) { out.append(p); next = folder(p)?.parentID }
        return out
    }

    /// Adds an import's collections, folders, requests and environments.
    mutating func add(_ result: APIImport.Result) {
        collections += result.collections
        folders += result.folders
        requests += result.requests
        environments += result.environments
        if let c = result.collections.first { selectedID = c.id } else if let r = result.requests.first { selectedID = r.id }
        if environmentID == nil, let e = result.environments.first { environmentID = e.id }
    }
}

struct APIResponse {
    var status: Int
    var headers: [(String, String)]
    var body: Data
    var ms: Int
    var url: String

    var contentType: String { headers.first { $0.0.lowercased() == "content-type" }?.1 ?? "" }

    /// The body as text: JSON indented, anything else decoded as UTF-8.
    /// ponytail: shows the first 2 MB; a bigger body needs a "Save to file" button.
    var text: String {
        let cap = 2_000_000
        if body.count <= cap, contentType.contains("json") || body.first == UInt8(ascii: "{") || body.first == UInt8(ascii: "["),
           let obj = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            return String(decoding: pretty, as: UTF8.self)
        }
        guard let shown = String(data: body.prefix(cap), encoding: .utf8) ?? (body.count > cap ? String(decoding: body.prefix(cap), as: UTF8.self) : nil) else {
            return "Binary content (\(contentType.isEmpty ? "no Content-Type" : contentType)), \(body.count) bytes: not shown as text."
        }
        return body.count > cap ? shown + "\n\n… \(body.count - cap) more bytes not shown" : shown
    }
}

enum APISender {
    struct BuildError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Postman's built-in values, made fresh for each use.
    static func dynamic(_ name: String) -> String? {
        switch name {
        case "$guid", "$randomUUID": UUID().uuidString.lowercased()
        case "$timestamp": String(Int(Date().timeIntervalSince1970))
        case "$isoTimestamp": ISO8601DateFormatter().string(from: Date())
        case "$randomInt": String(Int.random(in: 0...1000))
        case "$randomBoolean": Bool.random() ? "true" : "false"
        case "$randomAlphaNumeric": String("abcdefghijklmnopqrstuvwxyz0123456789".randomElement()!)
        case "$randomFirstName": ["Ada", "Alan", "Grace", "Linus", "Margaret", "Ken"].randomElement()!
        case "$randomLastName": ["Lovelace", "Turing", "Hopper", "Torvalds", "Hamilton", "Thompson"].randomElement()!
        case "$randomFullName": "\(dynamic("$randomFirstName")!) \(dynamic("$randomLastName")!)"
        case "$randomUserName": "user\(Int.random(in: 1000...9999))"
        case "$randomEmail": "user\(Int.random(in: 1000...9999))@example.com"
        case "$randomPhoneNumber": "555-\(Int.random(in: 100...999))-\(Int.random(in: 1000...9999))"
        case "$randomIP": (0..<4).map { _ in String(Int.random(in: 1...254)) }.joined(separator: ".")
        case "$randomWord": ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"].randomElement()!
        case "$randomUrl": "https://example.com/\(UUID().uuidString.prefix(8).lowercased())"
        default: nil
        }
    }

    /// Replaces {{name}} with the variable's value; unknown names stay as written,
    /// so a typo shows in the sent URL instead of silently vanishing.
    static func substitute(_ s: String, _ vars: [String: String]) -> String {
        guard s.contains("{{") else { return s }
        var out = "", rest = Substring(s)
        while let open = rest.range(of: "{{") {
            out += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "}}") else { out += rest[open.lowerBound...]; return out }
            let name = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            out += vars[name] ?? dynamic(name) ?? String(rest[open.lowerBound..<close.upperBound])
            rest = rest[close.upperBound...]
        }
        return out + rest
    }

    static func build(_ r: APIRequest, vars: [String: String], auth: APIAuth = APIAuth(kind: .none)) throws -> URLRequest {
        if auth.kind == .unsupported {
            throw BuildError(message: "This request signs in with \(auth.original.isEmpty ? "a method" : "“\(auth.original)”") from Postman, which Brix can't do yet. Pick another sign-in in Auth (here or on its folder or collection).")
        }
        var unknown: Set<String> = []
        let sub = { (s: String) -> String in
            let out = substitute(s, vars)
            // A Postman built-in Brix doesn't make would go out as "{{$name}}".
            var rest = Substring(out)
            while let r = rest.range(of: "{{$") {
                let tail = rest[r.upperBound...]
                if let end = tail.range(of: "}}") { unknown.insert("$" + tail[..<end.lowerBound]) }
                rest = tail
            }
            return out
        }
        let req = try buildRequest(r, sub: sub, auth: auth)
        if !unknown.isEmpty {
            throw BuildError(message: "Brix doesn't make \(unknown.sorted().map { "{{\($0)}}" }.joined(separator: ", ")) yet. Use a variable instead.")
        }
        return req
    }

    private static func buildRequest(_ r: APIRequest, sub: (String) -> String, auth: APIAuth) throws -> URLRequest {
        var raw = sub(r.url).trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { throw BuildError(message: "Enter a URL") }
        if !raw.contains("://") { raw = "http://" + raw }
        guard var comps = URLComponents(string: raw), let scheme = comps.scheme?.lowercased(), ["http", "https"].contains(scheme), comps.host?.isEmpty == false else {
            throw BuildError(message: "Not a web address: \(raw)")
        }
        var query = r.params.filter { $0.on && !$0.key.isEmpty }.map { URLQueryItem(name: sub($0.key), value: sub($0.value)) }
        if auth.kind == .apiKey, auth.inQuery, !auth.key.isEmpty { query.append(URLQueryItem(name: sub(auth.key), value: sub(auth.value))) }
        if !query.isEmpty { comps.queryItems = (comps.queryItems ?? []) + query }
        guard let url = comps.url else { throw BuildError(message: "Not a web address: \(raw)") }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = r.method
        for h in r.headers where h.on && !h.key.isEmpty {
            req.addValue(sub(h.value), forHTTPHeaderField: sub(h.key))
        }
        // A header you set yourself wins over the sign-in.
        switch auth.kind {
        case .bearer where req.value(forHTTPHeaderField: "Authorization") == nil:
            req.setValue("Bearer " + sub(auth.token), forHTTPHeaderField: "Authorization")
        case .basic where req.value(forHTTPHeaderField: "Authorization") == nil:
            req.setValue("Basic " + Data("\(sub(auth.username)):\(sub(auth.password))".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        case .apiKey where !auth.inQuery && !auth.key.isEmpty && req.value(forHTTPHeaderField: sub(auth.key)) == nil:
            req.setValue(sub(auth.value), forHTTPHeaderField: sub(auth.key))
        default: break
        }
        guard r.bodyKind != .none, !["GET", "HEAD"].contains(r.method) else { return req }
        let type: String
        switch r.bodyKind {
        case .none: return req
        case .json, .text:
            req.httpBody = Data(sub(r.body).utf8)
            type = r.bodyKind == .json ? "application/json" : "text/plain; charset=utf-8"
        case .form:
            req.httpBody = Data(r.formFields.filter { $0.on && !$0.key.isEmpty }
                .map { formEncode(sub($0.key)) + "=" + formEncode(sub($0.value)) }.joined(separator: "&").utf8)
            type = "application/x-www-form-urlencoded"
        case .multipart:
            let boundary = "BrixBoundary" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            req.httpBody = try multipart(r.formFields.filter { $0.on && !$0.key.isEmpty }, boundary: boundary, sub: sub)
            type = "multipart/form-data; boundary=\(boundary)"
        }
        if req.value(forHTTPHeaderField: "Content-Type") == nil || r.bodyKind == .multipart {
            req.setValue(type, forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private static let formSafe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    static func formEncode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: formSafe) ?? s }

    static func multipart(_ fields: [APIField], boundary: String, sub: (String) -> String) throws -> Data {
        var out = Data()
        func line(_ s: String) { out.append(Data((s + "\r\n").utf8)) }
        for f in fields {
            let name = sub(f.key).replacingOccurrences(of: "\"", with: "%22")
            line("--" + boundary)
            if f.isFile {
                let path = (sub(f.value) as NSString).expandingTildeInPath
                let data: Data
                do { data = try Data(contentsOf: URL(fileURLWithPath: path)) } catch {
                    throw BuildError(message: "Couldn't read the file for \(f.key): \(path). \(error.localizedDescription)")
                }
                let file = (path as NSString).lastPathComponent.replacingOccurrences(of: "\"", with: "%22")
                line("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(file)\"")
                line("Content-Type: " + (UTType(filenameExtension: (path as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"))
                line("")
                out.append(data)
                line("")
            } else {
                line("Content-Disposition: form-data; name=\"\(name)\"")
                line("")
                line(sub(f.value))
            }
        }
        line("--" + boundary + "--")
        return out
    }

    /// No cookies or cache kept between requests: each send is what you see in the editor.
    static let session = URLSession(configuration: .ephemeral)

    static func send(_ req: URLRequest) async throws -> APIResponse {
        let start = Date()
        let (data, response) = try await session.data(for: req)
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        guard let http = response as? HTTPURLResponse else { throw BuildError(message: "Not an HTTP response") }
        let headers = http.allHeaderFields.map { ("\($0.key)", "\($0.value)") }.sorted { $0.0.lowercased() < $1.0.lowercased() }
        return APIResponse(status: http.statusCode, headers: headers, body: data, ms: ms, url: http.url?.absoluteString ?? req.url?.absoluteString ?? "")
    }
}
