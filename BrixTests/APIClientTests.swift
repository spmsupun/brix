import XCTest
@testable import Brix

final class APIClientTests: XCTestCase {
    func testVariablesFillInAndUnknownOnesStay() {
        let vars = ["baseUrl": "https://api.test", "id": "42"]
        XCTAssertEqual(APISender.substitute("{{baseUrl}}/items/{{ id }}", vars), "https://api.test/items/42")
        XCTAssertEqual(APISender.substitute("{{nope}}/x", vars), "{{nope}}/x", "a typo shows in the URL")
        XCTAssertEqual(APISender.substitute("a {{baseUrl", vars), "a {{baseUrl")
    }

    func testBuildAddsParamsHeadersAndJSONBody() throws {
        var r = APIRequest()
        r.method = "POST"
        r.url = "{{host}}/orders?x=1"
        r.params = [APIField(key: "status", value: "{{s}}"), APIField(key: "off", value: "1", on: false)]
        r.headers = [APIField(key: "Authorization", value: "Bearer {{token}}"), APIField(key: "", value: "dropped")]
        r.bodyKind = .json
        r.body = #"{"total": {{n}}}"#
        let req = try APISender.build(r, vars: ["host": "localhost:3000", "s": "open", "token": "t0k", "n": "5"])
        XCTAssertEqual(req.url?.absoluteString, "http://localhost:3000/orders?x=1&status=open", "no scheme means http; off rows aren't sent")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer t0k")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(req.httpBody.map { String(decoding: $0, as: UTF8.self) }, #"{"total": 5}"#)

        r.method = "GET"
        XCTAssertNil(try APISender.build(r, vars: ["host": "h"]).httpBody, "GET sends no body")
        r.url = "ftp://files.test"
        XCTAssertThrowsError(try APISender.build(r, vars: [:]))
        r.url = "  "
        XCTAssertThrowsError(try APISender.build(r, vars: [:]))
    }

    /// A saved workspace from before the API panel, or with fields this version
    /// doesn't know, still loads its layout and the requests it can read.
    func testOldAndPartialWorkspacesStillLoad() throws {
        let old = try JSONDecoder().decode(WorkspaceState.self, from: Data(#"{"openFiles":["a.swift"]}"#.utf8))
        XCTAssertEqual(old.openFiles, ["a.swift"])
        XCTAssertTrue(old.api.requests.isEmpty)

        let partial = #"{"api":{"requests":[{"id":"r1","url":"x.test","future":true}],"history":"bad"}}"#
        let ws = try JSONDecoder().decode(WorkspaceState.self, from: Data(partial.utf8))
        XCTAssertEqual(ws.api.requests.map(\.id), ["r1"])
        XCTAssertEqual(ws.api.requests.first?.method, "GET")
        XCTAssertTrue(ws.api.history.isEmpty)
        XCTAssertEqual(ws.api.dropped, 1, "the unreadable history is counted, so the file gets backed up")
    }

    /// One bad entry costs only itself, and a row without an id gets the same id every load
    /// (its id names its Keychain item).
    func testOneBadEntryKeepsTheRestAndIdsStayStable() throws {
        let json = #"{"history":[{"request":{"id":"a"},"ms":3,"id":"h1","date":0},{"ms":"oops"},{"request":{"id":"b"},"ms":4,"id":"h2","date":0}],"#
            + #""environments":[{"name":"Dev","vars":[{"key":"token"}],"secrets":["key:token"]}]}"#
        let api = try JSONDecoder().decode(APIWorkspace.self, from: Data(json.utf8))
        XCTAssertEqual(api.history.map(\.id), ["h1", "h2"])
        XCTAssertEqual(api.dropped, 1)
        let again = try JSONDecoder().decode(APIWorkspace.self, from: Data(json.utf8))
        XCTAssertEqual(api.environments.first?.vars.first?.id, "key:token")
        XCTAssertEqual(api.environments.first.map { $0.secretAccount($0.vars[0]) }, again.environments.first.map { $0.secretAccount($0.vars[0]) })
        XCTAssertEqual(api.environments.first?.secrets, ["key:token"])
        // `dropped` is about this load only: it isn't saved.
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(api), as: UTF8.self).contains("dropped"))
    }

    func testBinaryBodiesAreNotShownAsText() {
        let png = APIResponse(status: 200, headers: [("Content-Type", "image/png")], body: Data([0x89, 0x50, 0x4E, 0x47, 0xFF, 0xFE]), ms: 1, url: "")
        XCTAssertTrue(png.text.hasPrefix("Binary content (image/png), 6 bytes"))
        let plain = APIResponse(status: 200, headers: [], body: Data("héllo".utf8), ms: 1, url: "")
        XCTAssertEqual(plain.text, "héllo")
    }

    func testHistoryKeepsTheNewestFifty() {
        var api = APIWorkspace()
        for i in 0..<60 { var r = APIRequest(); r.name = "\(i)"; api.record(r, status: 200, ms: 1) }
        XCTAssertEqual(api.history.count, APIWorkspace.historyLimit)
        XCTAssertEqual(api.history.first?.request.name, "59")
    }

    // MARK: Collections and Postman import

    static let postman = #"""
    {"info":{"name":"Shop API","schema":"https://schema.getpostman.com/json/collection/v2.1.0/collection.json"},
     "auth":{"type":"bearer","bearer":[{"key":"token","value":"{{token}}","type":"string"}]},
     "variable":[{"key":"baseUrl","value":"https://shop.test"},{"key":"old","value":"x","disabled":true}],
     "event":[{"listen":"prerequest","script":{"exec":["1"]}}],
     "item":[
      {"name":"Orders","auth":{"type":"basic","basic":{"username":"u","password":"p"}},"item":[
        {"name":"List orders","request":{"method":"GET","header":[{"key":"Accept","value":"application/json"},{"key":"X-Off","value":"1","disabled":true}],
          "url":{"raw":"{{baseUrl}}/orders/:shop?status=open","host":["{{baseUrl}}"],"path":["orders",":shop"],
                 "query":[{"key":"status","value":"open"}],"variable":[{"key":"shop","value":"42"}]}}},
        {"name":"Create order","request":{"method":"POST","url":"{{baseUrl}}/orders",
          "body":{"mode":"raw","raw":"{\"total\": 5}","options":{"raw":{"language":"json"}}}}}
      ]},
      {"name":"Login","event":[{"listen":"test"}],"request":{"method":"POST","auth":{"type":"noauth"},"url":{"raw":"{{baseUrl}}/login"},
        "body":{"mode":"urlencoded","urlencoded":[{"key":"user","value":"a b"},{"key":"x","value":"1","disabled":true}]}}},
      {"name":"Upload","request":{"method":"POST","url":"{{baseUrl}}/files",
        "body":{"mode":"formdata","formdata":[{"key":"note","value":"hi","type":"text"},{"key":"file","src":"/tmp/a.png","type":"file"}]}}},
      {"name":"Query","request":{"method":"POST","url":"{{baseUrl}}/graphql",
        "body":{"mode":"graphql","graphql":{"query":"{ me { id } }","variables":"{\"a\":1}"}}}}
     ]}
    """#

    func testPostmanCollectionImport() throws {
        let r = try APIImport.read(Data(Self.postman.utf8))
        XCTAssertEqual(r.collections.map(\.name), ["Shop API"])
        let c = r.collections[0]
        XCTAssertEqual(c.auth.kind, .bearer)
        XCTAssertEqual(c.auth.token, "{{token}}")
        XCTAssertEqual(c.variables.map(\.key), ["baseUrl", "old", "orders_password"], "the folder's literal password became a collection variable")
        XCTAssertEqual(c.variables.map(\.on), [true, false, true])
        XCTAssertEqual(r.secrets[c.id], [c.variables[2].id], "and is marked to go into the Keychain")
        XCTAssertEqual(r.folders[0].auth.password, "{{orders_password}}")
        XCTAssertEqual(r.folders.map(\.name), ["Orders"])
        XCTAssertEqual(r.folders[0].parentID, c.id)
        XCTAssertEqual(r.folders[0].auth.kind, .basic, "v2.0 object-form auth reads too")
        XCTAssertEqual(r.requests.map(\.name), ["List orders", "Create order", "Login", "Upload", "Query"])

        let list = r.requests[0]
        XCTAssertEqual(list.parentID, r.folders[0].id)
        XCTAssertEqual(list.url, "{{baseUrl}}/orders/42", "query moves to rows, path variable takes its value")
        XCTAssertEqual(list.params.map(\.key), ["status"])
        XCTAssertEqual(list.headers.map(\.on), [true, false])
        XCTAssertEqual(list.auth.kind, .inherit)

        XCTAssertEqual(r.requests[1].bodyKind, .json)
        XCTAssertEqual(r.requests[2].auth.kind, .none)
        XCTAssertEqual(r.requests[2].bodyKind, .form)
        XCTAssertEqual(r.requests[2].formFields.map(\.on), [true, false])
        XCTAssertEqual(r.requests[3].bodyKind, .multipart)
        XCTAssertEqual(r.requests[3].formFields.map(\.isFile), [false, true])
        XCTAssertEqual(r.requests[3].formFields[1].value, "/tmp/a.png")
        XCTAssertEqual(r.requests[4].bodyKind, .json)
        XCTAssertTrue(r.requests[4].body.contains("\"variables\""))
        XCTAssertTrue(r.notes.contains { $0.contains("2 pre-request or test scripts") }, "\(r.notes)")
        XCTAssertEqual(r.summary, "1 collection, 5 requests, 1 folder")
    }

    func testImportedRequestsSendWithInheritedSignIn() throws {
        var api = APIWorkspace()
        api.add(try APIImport.read(Data(Self.postman.utf8)))
        let list = api.requests[0], create = api.requests[1], login = api.requests[2]
        XCTAssertEqual(api.auth(for: list).auth.kind, .basic, "the folder's sign-in wins over the collection's")
        XCTAssertEqual(api.auth(for: list).from, "Orders")
        XCTAssertEqual(api.auth(for: login).auth.kind, .none)
        XCTAssertEqual(api.auth(for: api.requests[3]).auth.kind, .bearer)
        XCTAssertEqual(api.path(of: create.id), "Shop API / Orders")

        var vars = ["baseUrl": "https://shop.test", "token": "t"]
        vars["orders_password"] = api.collections[0].variables.first { $0.key == "orders_password" }?.value
        let req = try APISender.build(list, vars: vars, auth: api.auth(for: list).auth)
        XCTAssertEqual(req.url?.absoluteString, "https://shop.test/orders/42?status=open")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("u:p".utf8).base64EncodedString())
        XCTAssertNil(req.value(forHTTPHeaderField: "X-Off"))

        let form = try APISender.build(login, vars: vars, auth: api.auth(for: login).auth)
        XCTAssertEqual(form.httpBody.map { String(decoding: $0, as: UTF8.self) }, "user=a%20b")
        XCTAssertEqual(form.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertNil(form.value(forHTTPHeaderField: "Authorization"))

        var key = APIAuth(kind: .apiKey); key.key = "api_key"; key.value = "{{token}}"; key.inQuery = true
        XCTAssertEqual(try APISender.build(login, vars: vars, auth: key).url?.query, "api_key=t")
    }

    func testMultipartSendsTextAndFileFields() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("brix-\(UUID().uuidString).txt")
        try "file body".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        var r = APIRequest(); r.method = "POST"; r.url = "h.test"; r.bodyKind = .multipart
        r.formFields = [APIField(key: "note", value: "{{v}}"), APIField(key: "doc", value: file.path, isFile: true)]
        let req = try APISender.build(r, vars: ["v": "hi"])
        let type = try XCTUnwrap(req.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(type.hasPrefix("multipart/form-data; boundary="))
        let body = String(decoding: try XCTUnwrap(req.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"note\"\r\n\r\nhi\r\n"))
        XCTAssertTrue(body.contains("filename=\"\(file.lastPathComponent)\"\r\nContent-Type: text/plain\r\n\r\nfile body\r\n"))
        r.formFields[1].value = "/nope/missing.png"
        XCTAssertThrowsError(try APISender.build(r, vars: [:]), "a missing file stops the send")
    }

    func testPostmanEnvironmentImportMarksSecrets() throws {
        let json = #"{"name":"Staging","values":[{"key":"baseUrl","value":"https://s.test","enabled":true},{"key":"token","value":"abc","type":"secret","enabled":true}]}"#
        let r = try APIImport.read(Data(json.utf8))
        XCTAssertEqual(r.environments.map(\.name), ["Staging"])
        let env = r.environments[0]
        XCTAssertEqual(r.secrets[env.id], [env.vars[1].id])
        XCTAssertThrowsError(try APIImport.read(Data("not json".utf8)))
        XCTAssertThrowsError(try APIImport.read(Data(#"{"something":"else"}"#.utf8)))
    }

    func testMovingAndDeletingInTheTree() {
        var api = APIWorkspace()
        let c = APICollection(name: "C"), d = APICollection(name: "D")
        let outer = APIFolder(name: "Outer", parentID: c.id)
        let inner = APIFolder(name: "Inner", parentID: outer.id)
        var a = APIRequest(parentID: inner.id); a.name = "a"
        var b = APIRequest(parentID: c.id); b.name = "b"
        api.collections = [c, d]; api.folders = [outer, inner]; api.requests = [a, b]

        api.move(outer.id, onto: inner.id)
        XCTAssertEqual(api.folder(outer.id)?.parentID, c.id, "a folder never goes inside itself")
        api.move(b.id, onto: a.id)
        XCTAssertEqual(api.request(b.id)?.parentID, inner.id)
        XCTAssertEqual(api.requests.map(\.name), ["b", "a"], "dropped onto a request lands just above it")
        api.move(d.id, onto: c.id)
        XCTAssertEqual(api.collections.map(\.name), ["D", "C"])

        api.selectedID = a.id
        XCTAssertEqual(Set(api.delete(outer.id)), [a.id, b.id])
        XCTAssertTrue(api.folders.isEmpty)
        XCTAssertTrue(api.requests.isEmpty)
        XCTAssertNil(api.selectedID)
    }

    func testPostmanDynamicValues() {
        let s = APISender.substitute("{{$guid}} {{$timestamp}}", [:])
        XCTAssertFalse(s.contains("{{"))
        XCTAssertEqual(s.split(separator: " ").first?.count, 36)
    }

    // MARK: Import and send safety

    func testUnsupportedSignInIsKeptAndRefusesToSend() throws {
        let json = #"{"info":{"name":"O"},"auth":{"type":"oauth2","oauth2":[]},"item":[{"name":"F","item":[{"name":"r","request":{"url":"h.test"}}]},{"name":"s","request":{"url":"h.test","auth":{"type":"digest"}}}]}"#
        let r = try APIImport.read(Data(json.utf8))
        XCTAssertEqual(r.collections[0].auth.kind, .unsupported)
        XCTAssertEqual(r.collections[0].auth.original, "oauth2")
        XCTAssertTrue(r.notes.contains { $0.contains("“oauth2” sign-in on “O”") }, "\(r.notes)")
        var api = APIWorkspace()
        api.add(r)
        let inherited = api.auth(for: api.requests[0]).auth
        XCTAssertEqual(inherited.kind, .unsupported, "inheriting requests don't quietly go out unsigned")
        XCTAssertThrowsError(try APISender.build(api.requests[0], vars: [:], auth: inherited))
        XCTAssertEqual(api.auth(for: api.requests[1]).auth.original, "digest")
    }

    func testImportNotesWhatItLeavesOutAndKeepsValuesExact() throws {
        let json = #"""
        {"info":{"name":"N"},"variable":[{"key":"flag","value":true},{"key":"n","value":3}],"item":[
          "junk",
          {"name":"F","variable":[{"key":"v","value":"folder"}],"item":[]},
          {"name":"g","request":{"method":"GET","url":{"raw":"h.test/a/:id/:idx","variable":[{"key":"id","value":"1"},{"key":"idx","value":"2"}]},
            "body":{"mode":"raw","raw":"x"}}},
          {"name":"q","request":{"method":"POST","url":"h.test","body":{"mode":"graphql","graphql":{"query":"{a}","variables":"{bad"}}}},
          {"name":"m","request":{"method":"POST","url":"h.test","body":{"mode":"formdata","formdata":[{"key":"f","type":"file","src":"/a","contentType":"image/png"}]}}}
        ]}
        """#
        let r = try APIImport.read(Data(json.utf8))
        XCTAssertEqual(r.collections[0].variables.map(\.value), ["true", "3"], "JSON booleans stay true/false")
        XCTAssertEqual(r.folders[0].variables.map(\.value), ["folder"])
        XCTAssertEqual(r.requests[0].url, "h.test/a/1/2", ":id doesn't touch :idx")
        let notes = r.notes.joined(separator: "\n")
        XCTAssertTrue(notes.contains("1 item couldn't be read"), notes)
        XCTAssertTrue(notes.contains("“g” send a body with GET"), notes)
        XCTAssertTrue(notes.contains("GraphQL variables aren't valid JSON"), notes)
        XCTAssertTrue(notes.contains("multipart field content type"), notes)
    }

    func testUnknownPostmanBuiltInStopsTheSend() {
        var r = APIRequest(); r.url = "h.test/{{$randomEmail}}/{{$randomCreditCard}}"
        XCTAssertThrowsError(try APISender.build(r, vars: [:])) { e in
            XCTAssertTrue(e.localizedDescription.contains("{{$randomCreditCard}}"))
            XCTAssertFalse(e.localizedDescription.contains("randomEmail"), "known ones are made")
        }
    }

    func testOrphanedItemsAreRecoveredAtLoad() throws {
        // Folder "lost" points at a folder that couldn't be read; "a" and "b" loop; request "r" is in a missing folder.
        let json = #"""
        {"collections":[{"id":"c","name":"C"}],
         "folders":[{"id":"lost","name":"Lost","parentID":"gone"},{"id":"kid","name":"Kid","parentID":"lost"},
                    {"id":"a","name":"A","parentID":"b"},{"id":"b","name":"B","parentID":"a"},{"name":"no parent"}],
         "requests":[{"id":"r","parentID":"nowhere"},{"id":"k","parentID":"kid"}]}
        """#
        let api = try JSONDecoder().decode(APIWorkspace.self, from: Data(json.utf8))
        XCTAssertEqual(api.dropped, 1, "the folder with no parent couldn't be read")
        let rescue = try XCTUnwrap(api.collections.first { $0.name == "Recovered" })
        XCTAssertEqual(api.folder("lost")?.parentID, rescue.id)
        XCTAssertEqual(api.folder("kid")?.parentID, "lost", "folders under a rescued one stay under it")
        XCTAssertTrue([api.folder("a")?.parentID, api.folder("b")?.parentID].contains(rescue.id), "a loop is broken")
        XCTAssertNil(api.request("r")?.parentID, "a request in a missing folder becomes loose, still visible")
        XCTAssertEqual(api.path(of: "k"), "Recovered / Lost / Kid")
    }

    func testLockedAccountsCoverEnvironmentsAndCollections() {
        var api = APIWorkspace()
        var env = APIEnvironment(name: "E", vars: [APIField(key: "t")]); env.secrets = [env.vars[0].id]
        var c = APICollection(name: "C"); c.variables = [APIField(key: "p"), APIField(key: "plain")]; c.secrets = [c.variables[0].id]
        api.environments = [env]; api.collections = [c]
        XCTAssertEqual(api.lockedAccounts.map(\.account), [env.secretAccount(env.vars[0]), c.secretAccount(c.variables[0])])
    }
}
