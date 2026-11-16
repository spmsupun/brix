import XCTest
@testable import Brix

final class APIFormatsTests: XCTestCase {
    // MARK: curl

    func testCurlFromABrowser() throws {
        let cmd = #"""
        curl 'https://api.shop.test/v1/orders?status=open&limit=20' \
          -H 'accept: application/json' \
          -H "Authorization: Bearer abc" \
          -H $'x-note: it\'s' \
          --data-raw '{"total":5}' \
          --compressed -o out.txt
        """#
        let r = try APIImport.curl(cmd)
        let q = try XCTUnwrap(r.requests.first)
        XCTAssertEqual(q.method, "POST", "data means POST")
        XCTAssertEqual(q.url, "https://api.shop.test/v1/orders")
        XCTAssertEqual(q.params.map(\.key), ["status", "limit"])
        XCTAssertEqual(q.headers.map(\.key), ["accept", "Authorization", "x-note"])
        XCTAssertEqual(q.headers[2].value, "it's")
        XCTAssertEqual(q.bodyKind, .json)
        XCTAssertEqual(q.body, #"{"total":5}"#)
        XCTAssertEqual(q.name, "POST /v1/orders")
        XCTAssertTrue(r.notes.contains { $0.contains("-o") })
        XCTAssertEqual(q.headers[1].value, "{{authorization}}", "the token moves to a variable")
        XCTAssertEqual(r.lockedVariables.map(\.value), ["Bearer abc"], "to be locked in the collection it goes into")
    }

    func testCurlFormsUserAndGet() throws {
        var q = try XCTUnwrap(APIImport.curl("curl -u ada:pw -d 'a=1&b=two+words' https://h.test/x").requests.first)
        XCTAssertEqual(q.auth.kind, .basic)
        XCTAssertEqual(q.auth.password, "{{password}}", "locked, like every sign-in value from curl")
        XCTAssertEqual(q.bodyKind, .form)
        XCTAssertEqual(q.formFields.map(\.value), ["1", "two words"])
        q = try XCTUnwrap(APIImport.curl("curl -G https://h.test/s -d q=swift -XGET").requests.first)
        XCTAssertEqual(q.method, "GET")
        XCTAssertEqual(q.params.map(\.value), ["swift"])
        XCTAssertEqual(q.bodyKind, .none)
        q = try XCTUnwrap(APIImport.curl("curl -F note=hi -F 'doc=@/tmp/a.pdf;type=application/pdf' https://h.test/up").requests.first)
        XCTAssertEqual(q.bodyKind, .multipart)
        XCTAssertEqual(q.formFields.map(\.isFile), [false, true])
        XCTAssertEqual(q.formFields[1].value, "/tmp/a.pdf")
        XCTAssertThrowsError(try APIImport.curl("wget https://x"))
        XCTAssertThrowsError(try APIImport.curl("curl -H 'a: b'"))
        XCTAssertThrowsError(try APIImport.curl("curl 'https://x"))
    }

    // MARK: OpenAPI

    static let openapiYAML = """
    openapi: 3.0.3
    info:
      title: Pet Store   # the name
      version: "1.0"
    servers:
      - url: https://{env}.pets.test/v1
        variables:
          env:
            default: api
    security:
      - bearerAuth: []
    paths:
      /pets/{petId}:
        parameters:
          - name: petId
            in: path
            required: true
            schema: { type: integer, example: 7 }
        get:
          summary: Get a pet
          tags: [pets]
          parameters:
            - $ref: '#/components/parameters/Verbose'
        delete:
          operationId: deletePet
          tags: [pets]
          security: []
      /pets:
        post:
          summary: Add a pet
          tags:
            - pets
          requestBody:
            content:
              application/json:
                schema:
                  $ref: '#/components/schemas/Pet'
      /upload:
        post:
          requestBody:
            content:
              multipart/form-data:
                schema:
                  type: object
                  required: [file]
                  properties:
                    file: { type: string, format: binary }
                    note:
                      type: string
                      description: |
                        A note.
                        Two lines.
    components:
      parameters:
        Verbose:
          name: verbose
          in: query
          schema:
            type: boolean
            default: false
      schemas:
        Pet:
          type: object
          properties:
            name: { type: string, example: "Rex" }
            tags:
              type: array
              items: { type: string }
            born: { type: string, format: date }
      securitySchemes:
        bearerAuth:
          type: http
          scheme: bearer
    """

    func testOpenAPIFromYAML() throws {
        let r = try APIImport.read(Data(Self.openapiYAML.utf8), fileName: "pets.yaml")
        let c = try XCTUnwrap(r.collections.first)
        XCTAssertEqual(c.name, "Pet Store")
        XCTAssertEqual(c.variables.first { $0.key == "baseUrl" }?.value, "https://api.pets.test/v1")
        XCTAssertEqual(c.variables.first { $0.key == "petId" }?.value, "7")
        XCTAssertEqual(c.auth.kind, .bearer)
        XCTAssertEqual(c.auth.token, "{{bearerToken}}")
        XCTAssertEqual(r.folders.map(\.name), ["pets"])
        let byName = Dictionary(uniqueKeysWithValues: r.requests.map { ($0.name, $0) })
        let get = try XCTUnwrap(byName["Get a pet"])
        XCTAssertEqual(get.url, "{{baseUrl}}/pets/{{petId}}")
        XCTAssertEqual(get.params.map(\.key), ["verbose"])
        XCTAssertEqual(get.params.first?.value, "false")
        XCTAssertEqual(get.parentID, r.folders[0].id)
        XCTAssertEqual(byName["deletePet"]?.auth.kind, APIAuth.Kind.none, "security: [] means no sign-in")
        let add = try XCTUnwrap(byName["Add a pet"])
        XCTAssertEqual(add.bodyKind, .json)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(add.body.utf8)) as? [String: Any])
        XCTAssertEqual(body["name"] as? String, "Rex")
        XCTAssertEqual(body["born"] as? String, "2026-01-01")
        let upload = try XCTUnwrap(byName["POST /upload"])
        XCTAssertEqual(upload.bodyKind, .multipart)
        XCTAssertEqual(upload.formFields.map(\.key), ["file", "note"])
        XCTAssertEqual(upload.formFields.map(\.isFile), [true, false])
        XCTAssertEqual(upload.formFields.map(\.on), [true, false], "only required fields start switched on")
        XCTAssertEqual(upload.parentID, c.id, "untagged operations sit in the collection")
    }

    func testOpenAPIJSONAndSwagger() throws {
        let json = #"{"openapi":"3.1.0","info":{"title":"T"},"paths":{"/a":{"get":{}}},"components":{"securitySchemes":{"k":{"type":"apiKey","in":"query","name":"key"}}},"security":[{"k":[]}]}"#
        let r = try APIImport.read(Data(json.utf8))
        XCTAssertEqual(r.collections[0].auth.kind, .apiKey)
        XCTAssertTrue(r.collections[0].auth.inQuery)
        XCTAssertEqual(r.requests.map(\.name), ["GET /a"])
        XCTAssertTrue(r.notes.contains { $0.contains("names no server") })
        XCTAssertThrowsError(try APIImport.read(Data(#"{"openapi":"3.0.0","info":{"title":"Models"},"components":{}}"#.utf8))) { e in
            XCTAssertTrue(e.localizedDescription.contains("no paths"))
        }
        XCTAssertThrowsError(try APIImport.read(Data(#"{"swagger":"2.0","paths":{}}"#.utf8))) { e in
            XCTAssertTrue(e.localizedDescription.contains("OpenAPI 2"))
        }
    }

    func testMiniYAML() throws {
        let v = try XCTUnwrap(MiniYAML.parse("""
        a: 1
        b: "x: y # not a comment"
        c: 'it''s'
        d: [1, "two", {e: 3}]
        f:
        - g: 1
          h: [x]
        - plain words
        i: >
          folded
          line
        j: ~
        url: http://h.test:8080/x
        """) as? [String: Any])
        XCTAssertEqual(v["a"] as? Int, 1)
        XCTAssertEqual(v["b"] as? String, "x: y # not a comment")
        XCTAssertEqual(v["c"] as? String, "it's")
        let d = try XCTUnwrap(v["d"] as? [Any])
        XCTAssertEqual(d.count, 3)
        XCTAssertEqual((d[2] as? [String: Any])?["e"] as? Int, 3)
        let f = try XCTUnwrap(v["f"] as? [Any])
        XCTAssertEqual((f[0] as? [String: Any])?["h"] as? [String], ["x"])
        XCTAssertEqual(f[1] as? String, "plain words")
        XCTAssertEqual(v["i"] as? String, "folded line\n")
        XCTAssertTrue(v["j"] is NSNull)
        XCTAssertEqual(v["url"] as? String, "http://h.test:8080/x")
        XCTAssertThrowsError(try MiniYAML.parse("a: &x 1\nb: *x"))
    }

    // MARK: Insomnia and HAR

    func testInsomniaExport() throws {
        let json = #"""
        {"_type":"export","__export_format":4,"resources":[
          {"_id":"wrk_1","_type":"workspace","name":"Shop"},
          {"_id":"env_base","_type":"environment","parentId":"wrk_1","name":"Base","data":{"host":"https://s.test"}},
          {"_id":"env_dev","_type":"environment","parentId":"env_base","name":"Dev","data":{"token":"t"}},
          {"_id":"fld_1","_type":"request_group","parentId":"wrk_1","name":"Orders"},
          {"_id":"fld_2","_type":"request_group","parentId":"fld_1","name":"Admin"},
          {"_id":"req_1","_type":"request","parentId":"fld_2","name":"List","method":"get","url":"{{ _.host }}/orders",
           "parameters":[{"name":"page","value":"1","disabled":true}],"headers":[{"name":"Accept","value":"application/json"}],
           "authentication":{"type":"bearer","token":"{{ _.token }}"},"body":{}},
          {"_id":"req_2","_type":"request","parentId":"wrk_1","name":"Login","method":"POST","url":"{{_.host}}/login",
           "body":{"mimeType":"application/x-www-form-urlencoded","params":[{"name":"u","value":"a"}]},"authentication":{"type":"oauth2"}}
        ]}
        """#
        let r = try APIImport.read(Data(json.utf8))
        XCTAssertEqual(r.collections.map(\.name), ["Shop"])
        XCTAssertEqual(r.collections[0].variables.map(\.key), ["host"])
        XCTAssertEqual(r.environments.map(\.name), ["Dev"])
        XCTAssertEqual(r.folders.map(\.name), ["Orders", "Admin"])
        XCTAssertEqual(r.folders[1].parentID, r.folders[0].id)
        let list = r.requests[0]
        XCTAssertEqual(list.url, "{{host}}/orders")
        XCTAssertEqual(list.method, "GET")
        XCTAssertEqual(list.params.first?.on, false)
        XCTAssertEqual(list.auth.token, "{{token}}")
        XCTAssertEqual(list.parentID, r.folders[1].id)
        XCTAssertEqual(r.requests[1].bodyKind, .form)
        XCTAssertEqual(r.requests[1].auth.kind, .unsupported)
        XCTAssertTrue(r.notes.contains { $0.contains("oauth2") })
    }

    func testHARGroupsByHostAndLocksSignIn() throws {
        let json = #"""
        {"log":{"entries":[
          {"request":{"method":"GET","url":"https://a.test/x?q=1","headers":[{"name":":authority","value":"a.test"},{"name":"Authorization","value":"Bearer s3cret"},{"name":"Cookie","value":"sid=1"},{"name":"Accept","value":"*/*"}]}},
          {"request":{"method":"GET","url":"https://a.test/x?q=1","headers":[{"name":":authority","value":"a.test"},{"name":"Authorization","value":"Bearer s3cret"},{"name":"Cookie","value":"sid=2"},{"name":"Accept","value":"*/*"}]}},
          {"request":{"method":"POST","url":"https://b.test/y","headers":[],"postData":{"mimeType":"application/json","text":"{\"a\":1}"}}},
          {"nope":true}
        ]}}
        """#
        let r = try APIImport.read(Data(json.utf8), fileName: "session.har")
        XCTAssertEqual(r.collections[0].name, "session")
        XCTAssertEqual(r.folders.map(\.name), ["a.test", "b.test"])
        XCTAssertEqual(r.requests.count, 2, "the repeated call merged")
        let first = r.requests[0]
        XCTAssertEqual(first.params.map(\.key), ["q"])
        XCTAssertEqual(first.headers.map(\.key), ["Authorization", "Accept"], "pseudo headers and cookies left out")
        XCTAssertEqual(first.headers[0].value, "{{authorization}}")
        let secret = try XCTUnwrap(r.collections[0].variables.first)
        XCTAssertEqual(secret.value, "Bearer s3cret")
        XCTAssertEqual(r.secrets[r.collections[0].id], [secret.id], "marked to go into the Keychain")
        XCTAssertEqual(r.requests[1].bodyKind, .json)
        let notes = r.notes.joined(separator: "\n")
        XCTAssertTrue(notes.contains("Cookie headers were left out of 2"), notes)
        XCTAssertTrue(notes.contains("1 entry couldn't be read"), notes)
        XCTAssertTrue(notes.contains("1 repeated call was merged"), notes)
    }

    // MARK: Export

    func testPostmanExportRoundTrips() throws {
        var api = APIWorkspace()
        api.add(try APIImport.read(Data(APIClientTests.postman.utf8)))
        var c = api.collections[0]
        c.secrets = [c.variables.first { $0.key == "orders_password" }!.id]
        api.collections[0] = c
        let (data, emptied) = try APIExport.postman(c, in: api)
        XCTAssertEqual(emptied, ["Shop API: orders_password"])
        let back = try APIImport.read(data)
        XCTAssertEqual(back.collections[0].name, "Shop API")
        XCTAssertEqual(back.folders.map(\.name), ["Orders"])
        XCTAssertEqual(back.requests.map(\.name), api.requests.map(\.name))
        XCTAssertEqual(back.requests.map(\.method), api.requests.map(\.method))
        XCTAssertEqual(back.requests.map(\.bodyKind), api.requests.map(\.bodyKind))
        XCTAssertEqual(back.requests[0].params.map(\.key), ["status"])
        XCTAssertEqual(back.requests[0].url, api.requests[0].url)
        XCTAssertEqual(back.folders[0].auth.kind, .basic)
        XCTAssertEqual(back.collections[0].auth.kind, .bearer)
        XCTAssertEqual(back.collections[0].variables.first { $0.key == "orders_password" }?.value, "", "locked values aren't written")
    }

    func testCurlExportReadsBack() throws {
        var r = APIRequest(); r.method = "POST"; r.url = "https://h.test/o"
        r.headers = [APIField(key: "X-It", value: "it's")]
        r.bodyKind = .json; r.body = #"{"a":"b c"}"#
        let req = try APISender.build(r, vars: [:])
        let text = APIExport.curl(r, sent: req)
        let back = try XCTUnwrap(APIImport.curl(text).requests.first)
        XCTAssertEqual(back.method, "POST")
        XCTAssertEqual(back.url, "https://h.test/o")
        XCTAssertEqual(back.headers.first { $0.key == "X-It" }?.value, "it's")
        XCTAssertEqual(back.body, r.body)
    }

    // MARK: Review fixes

    func testYAMLErrorsInsteadOfHangingOrGuessing() throws {
        let start = Date()
        XCTAssertThrowsError(try MiniYAML.parse("a: [1}\n"))
        XCTAssertThrowsError(try MiniYAML.parse("a: {b: 1]\n"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "a mismatched bracket fails at once")
        XCTAssertThrowsError(try MiniYAML.parse("a:\n  - *ref\n"))
        XCTAssertThrowsError(try MiniYAML.parse("a:\n  - &x k: v\n"))
        let v = try XCTUnwrap(MiniYAML.parse("a:\n  - |\n    two\n    lines\n  - b\n") as? [String: Any])
        XCTAssertEqual(v["a"] as? [String], ["two\nlines\n", "b"])
        XCTAssertThrowsError(try APIImport.read(Data("{\"a\": ".utf8), fileName: "x.json")) { e in
            XCTAssertTrue(e.localizedDescription.contains("couldn't be read as JSON"), e.localizedDescription)
        }
    }

    func testCurlKeepsTheRealURLAndLocksSignIn() throws {
        XCTAssertEqual(try APIImport.curl("curl --max-redirs 3 https://real.test/x").requests[0].url, "https://real.test/x")
        XCTAssertEqual(try APIImport.curl("curl --made-up-opt value https://real.test/y").requests[0].url, "https://real.test/y")
        XCTAssertEqual(try APIImport.curl("curl --made-up-flag https://real.test/z").requests[0].url, "https://real.test/z")
        let r = try APIImport.curl("curl -u ada:pw -H 'X-Auth-Token: t1' 'https://h.test/a?api_key=k3'")
        let q = r.requests[0]
        XCTAssertEqual(q.auth.password, "{{password}}")
        XCTAssertEqual(q.headers[0].value, "{{x_auth_token}}")
        XCTAssertEqual(q.params[0].value, "{{api_key}}")
        XCTAssertEqual(Set(r.lockedVariables.map(\.value)), ["pw", "t1", "k3"])
        let b = try APIImport.curl("curl --oauth2-bearer b2 https://h.test/b")
        XCTAssertEqual(b.requests[0].auth.token, "{{token}}")
        XCTAssertEqual(b.lockedVariables.map(\.value), ["b2"])
        let f = try APIImport.curl("curl -F justname -F 'note=hi;type=text/plain' -d @body.json https://h.test/f")
        XCTAssertEqual(f.requests[0].formFields.map(\.value), ["hi"])
        let notes = f.notes.joined(separator: "\n")
        XCTAssertTrue(notes.contains("“justname”"), notes)
        XCTAssertTrue(notes.contains("own content type"), notes)
        XCTAssertTrue(notes.contains("the file body.json"), notes)
    }

    func testShellQuotingEscapes() throws {
        XCTAssertEqual(try APIImport.shellWords(#"curl $'\x41\xc3\xa9 \u00e9 \uD83D\uDE00'"#), ["curl", "Aé é 😀"])
        XCTAssertThrowsError(try APIImport.shellWords("curl $'open"))
        XCTAssertThrowsError(try APIImport.shellWords(#"curl $'\u12'"#))
    }

    func testHARKeepsDifferentCallsAndLocksMore() throws {
        let json = #"""
        {"log":{"entries":[
          {"request":{"method":"POST","url":"https://a.test/login?access_token=q1","headers":[{"name":"X-Auth-Token","value":"h1"}],
            "postData":{"mimeType":"application/x-www-form-urlencoded","params":[{"name":"user","value":"ada"},{"name":"password","value":"p1"}]}}},
          {"request":{"method":"POST","url":"https://a.test/login?access_token=q1","headers":[{"name":"X-Auth-Token","value":"h1"}],
            "postData":{"mimeType":"application/x-www-form-urlencoded","params":[{"name":"user","value":"bob"},{"name":"password","value":"p1"}]}}},
          {"request":{"method":"POST","url":"https://a.test/up","headers":[],
            "postData":{"mimeType":"multipart/form-data","params":[{"name":"doc","fileName":"a.pdf"}]}}}
        ]}}
        """#
        let r = try APIImport.read(Data(json.utf8), fileName: "s.har")
        XCTAssertEqual(r.requests.count, 3, "different form fields aren't merged")
        XCTAssertEqual(r.requests[0].params[0].value, "{{access_token}}")
        XCTAssertEqual(r.requests[0].headers[0].value, "{{x_auth_token}}")
        XCTAssertEqual(r.requests[0].formFields[1].value, "{{password}}")
        XCTAssertEqual(r.requests[0].formFields[0].value, "ada")
        XCTAssertEqual(Set(r.collections[0].variables.map(\.value)), ["q1", "h1", "p1"], "the same value is locked once")
        XCTAssertTrue(r.requests[2].formFields[0].isFile)
        XCTAssertTrue(r.notes.contains { $0.contains("uploaded file") })
    }

    func testOpenAPISignInEdgeCases() throws {
        let json = #"""
        {"openapi":"3.0.0","info":{"title":"S"},"servers":[{"url":"https://s.test"}],
         "components":{"securitySchemes":{"k":{"type":"apiKey","in":"header","name":"X-K"},"b":{"type":"http","scheme":"bearer"}}},
         "security":[{"missing":[]}],
         "paths":{"/a":{"get":{"security":[{"k":[],"b":[]}],"parameters":[{"name":"sid","in":"cookie"}]}},
                  "/b":{"get":{"security":[{"b":[]},{"k":[]}]}},
                  "/c":{"$ref":"other.yaml#/paths/c"}}}
        """#
        let r = try APIImport.read(Data(json.utf8))
        XCTAssertEqual(r.collections[0].auth.kind, .unsupported, "an undefined scheme doesn't quietly send nothing")
        XCTAssertTrue(r.collections[0].auth.original.contains("missing"))
        let notes = r.notes.joined(separator: "\n")
        XCTAssertTrue(notes.contains("needs b and k together"), notes)
        XCTAssertTrue(notes.contains("offers 2 ways"), notes)
        XCTAssertTrue(notes.contains("Cookie parameters (sid)"), notes)
        XCTAssertTrue(notes.contains("pointing to other files"), notes)
    }

    func testInsomniaLocksSecretsAndCopiesFolderHeaders() throws {
        let json = #"""
        {"_type":"export","__export_format":4,"resources":[
          {"_id":"w","_type":"workspace","name":"W"},
          {"_id":"e","_type":"environment","parentId":"w","data":{"host":"h.test","api_token":"zzz"}},
          {"_id":"g","_type":"request_group","parentId":"w","name":"G","headers":[{"name":"X-Team","value":"core"}],
           "authentication":{"type":"bearer","token":"literal"}},
          {"_id":"r","_type":"request","parentId":"g","name":"R","method":"GET","url":"{{ _.host }}/{% uuid 'v4' %}"}
        ]}
        """#
        let r = try APIImport.read(Data(json.utf8))
        let c = r.collections[0]
        XCTAssertEqual(r.folders[0].auth.token, "{{g_token}}")
        XCTAssertTrue(c.variables.contains { $0.key == "g_token" && $0.value == "literal" })
        let locked = r.secrets[c.id] ?? []
        XCTAssertTrue(c.variables.filter { locked.contains($0.id) }.map(\.key).sorted() == ["api_token", "g_token"])
        XCTAssertEqual(r.requests[0].headers.map(\.key), ["X-Team"], "the folder's header is copied in")
        XCTAssertTrue(r.notes.contains { $0.contains("template tags") })
    }

    func testExportsLeaveSecretsOutAndCurlIsSafe() throws {
        var api = APIWorkspace()
        var c = APICollection(name: "C"); c.auth = APIAuth(kind: .bearer); c.auth.token = "literal-token"
        var r = APIRequest(parentID: c.id); r.name = "R"; r.headers = [APIField(key: "X-Api-Key", value: "k"), APIField(key: "Accept", value: "a")]
        api.collections = [c]; api.requests = [r]
        let (data, emptied) = try APIExport.postman(c, in: api)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("literal-token"))
        XCTAssertFalse(text.contains("\"k\""))
        XCTAssertEqual(Set(emptied), ["C: token", "R: X-Api-Key"])

        var head = APIRequest(); head.method = "HEAD"; head.url = "https://h.test"
        XCTAssertTrue(APIExport.curl(head, sent: try APISender.build(head, vars: [:])).hasPrefix("curl -I "))
        var up = APIRequest(); up.method = "POST"; up.url = "https://h.test"; up.bodyKind = .multipart
        up.formFields = [APIField(key: "note", value: "@/etc/passwd")]
        let cmd = APIExport.curl(up, sent: try APISender.build(up, vars: [:]))
        XCTAssertTrue(cmd.contains("--form-string 'note=@/etc/passwd'"), cmd)
        XCTAssertFalse(cmd.contains("-F 'note"), cmd)
    }
}
