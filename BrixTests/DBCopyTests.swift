import XCTest
@testable import Brix

final class DBCopyTests: XCTestCase {
    private func sqlite(_ name: String) -> (DatabaseConnection, String) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("brix-copy-\(name)-\(UUID().uuidString).sqlite").path
        FileManager.default.createFile(atPath: path, contents: nil)
        return (DatabaseConnection(id: "c-\(name)", name: name, kind: .sqlite, filePath: path, tag: .local), path)
    }

    /// A real SQLite → SQLite copy: every value arrives the same, binary and NULL included,
    /// keys and indexes come along, and the three clash choices behave.
    func testSQLiteCopyIsExact() async throws {
        let svc = LiveDatabaseService()
        let (src, a) = sqlite("from"), (dst, b) = sqlite("to")
        defer { try? FileManager.default.removeItem(atPath: a); try? FileManager.default.removeItem(atPath: b) }
        _ = try await svc.execute(src, sql: "create table items (id integer primary key, name text not null default 'x', price real, data blob, flag boolean)", password: nil)
        _ = try await svc.execute(src, sql: "create index items_name on items (name)", password: nil)
        _ = try await svc.execute(src, sql: #"insert into items (name, price, data, flag) values ('café ☕', 1.5, x'00ff10', 1), ('it''s \back', null, null, 0), ('', -2e10, x'', null)"#, password: nil)
        // More than one read page, so keyset paging is exercised.
        _ = try await svc.execute(src, sql: "with recursive n(i) as (select 1 union all select i + 1 from n where i < 2500) insert into items (name, price) select 'row ' || i, i from n", password: nil)
        let objects = try await svc.schema(src, password: nil).schemas["main"] ?? []

        let plan = try await DBCopy.plan(source: src, sourcePassword: nil, objects: objects, target: dst, targetPassword: nil, targetSchema: "main", mode: .all, service: svc)
        XCTAssertEqual(plan.tables.count, 1)
        XCTAssertFalse(plan.tables[0].exists)
        XCTAssertEqual(plan.tables[0].indexes.map(\.columns), [["name"]])
        let out = await DBCopy.run(plan, sourcePassword: nil, targetPassword: nil, service: svc) { _, _ in }
        XCTAssertEqual(out.first?.state, "Done")
        XCTAssertEqual(out.first?.rows, 2503)

        let check = "select count(*), sum(length(name)), total(price), group_concat(hex(data), ','), group_concat(coalesce(flag, 'n'), ',') from items"
        let want = try await svc.execute(src, sql: check, password: nil).rows
        let got = try await svc.execute(dst, sql: check, password: nil).rows
        XCTAssertEqual(got, want)
        let exact = "select id, name, price, quote(data), flag from items where id <= 3 order by id"
        let a1 = try await svc.execute(dst, sql: exact, password: nil).rows, a2 = try await svc.execute(src, sql: exact, password: nil).rows
        XCTAssertEqual(a1, a2)
        let idx = try await svc.execute(dst, sql: "select name from sqlite_master where type = 'index' and tbl_name = 'items'", password: nil).rows
        XCTAssertTrue(idx.contains { $0.first == "items_name" })

        // Already there now: skip leaves it, add rows doubles it, drop and recreate restores it.
        var again = try await DBCopy.plan(source: src, sourcePassword: nil, objects: objects, target: dst, targetPassword: nil, targetSchema: "main", mode: .data, service: svc)
        XCTAssertTrue(again.tables[0].exists)
        let skipped = await DBCopy.run(again, sourcePassword: nil, targetPassword: nil, service: svc) { _, _ in }
        XCTAssertEqual(skipped.first?.rows, 0)
        _ = try await svc.execute(dst, sql: "delete from items", password: nil)
        again.tables[0].clash = .append
        let appended = await DBCopy.run(again, sourcePassword: nil, targetPassword: nil, service: svc) { _, _ in }
        XCTAssertEqual(appended.first?.rows, 2503)
        again.mode = .all
        again.tables[0].clash = .replace
        _ = await DBCopy.run(again, sourcePassword: nil, targetPassword: nil, service: svc) { _, _ in }
        let replaced = try await svc.execute(dst, sql: check, password: nil).rows
        XCTAssertEqual(replaced, want)
    }

    func testSafetyChecks() {
        let a = DatabaseConnection(id: "a", name: "a", kind: .postgres, host: "localhost", port: 5432, database: "shop", user: "u", tag: .local)
        var b = a; b.id = "b"; b.host = "127.0.0.1"
        XCTAssertTrue(DBCopy.sameDatabase(a, b), "two saved connections to one database")
        b.database = "other"
        XCTAssertFalse(DBCopy.sameDatabase(a, b))
        let plan = DBCopy.Plan(source: a, target: a, targetSchema: "public", mode: .all, tables: [], createSchema: false)
        XCTAssertNotNil(DBCopy.refusal(plan, sourceSchema: "public"), "copying a schema onto itself is refused")
        XCTAssertNil(DBCopy.refusal(plan, sourceSchema: "staging"), "another schema in the same database is fine")
        var ro = plan; ro.target.readOnly = true
        XCTAssertNotNil(DBCopy.refusal(ro, sourceSchema: "staging"))
        // Production: only once the type-to-confirm step unlocked it.
        var prod = plan; prod.target.tag = .prod
        XCTAssertNotNil(DBCopy.refusal(prod, sourceSchema: "staging"))
        prod.target.writeUnlocked = true
        XCTAssertNil(DBCopy.refusal(prod, sourceSchema: "staging"))
    }

    func testTypeMapAcrossEngines() {
        func m(_ t: String, _ f: DBKind, _ to: DBKind) -> String { DBTypeMap.map(t, from: f, to: to).type }
        XCTAssertEqual(m("character varying(80)", .postgres, .mysql), "varchar(80)")
        XCTAssertEqual(m("text", .postgres, .mysql), "longtext")
        XCTAssertEqual(m("numeric(12,2)", .postgres, .mysql), "decimal(12,2)")
        XCTAssertEqual(m("timestamp with time zone", .postgres, .mysql), "datetime(6)")
        XCTAssertNotNil(DBTypeMap.map("timestamp with time zone", from: .postgres, to: .mysql).note)
        XCTAssertEqual(m("bytea", .postgres, .sqlite), "BLOB")
        XCTAssertEqual(m("tinyint(1)", .mysql, .postgres), "boolean")
        XCTAssertEqual(m("int(10) unsigned", .mysql, .postgres), "bigint")
        XCTAssertEqual(m("bigint unsigned", .mysql, .postgres), "numeric(20)")
        XCTAssertEqual(m("interval", .postgres, .mysql), "longtext", "interval isn't an integer")
        XCTAssertEqual(m("enum('print','binary')", .mysql, .postgres), "text", "enum values don't decide the type")
        XCTAssertEqual(DBTypeMap.map("tinyint(1)", from: .mysql, to: .mysql).kind, .smallint, "tinyint(1) stays a number within MySQL")
        XCTAssertEqual(m("enum('a','b')", .mysql, .postgres), "text")
        XCTAssertEqual(m("datetime", .mysql, .postgres), "timestamp")
        XCTAssertEqual(m("json", .mysql, .postgres), "jsonb")
        XCTAssertEqual(m("varbinary(16)", .mysql, .postgres), "bytea")
        XCTAssertEqual(m("REAL", .sqlite, .postgres), "double precision")
        XCTAssertEqual(m("", .sqlite, .mysql), "longtext")
        XCTAssertEqual(m("integer[]", .postgres, .mysql), "longtext")
        XCTAssertEqual(m("uuid", .postgres, .mysql), "char(36)")
        XCTAssertEqual(m("enum('a','b')", .mysql, .mysql), "enum('a','b')", "same engine keeps the type as it is")
    }

    func testLiteralsAndDefaults() {
        let bin = DBCopy.Column(name: "d", sourceType: "bytea", targetType: "bytea", kind: .binary, nullable: true, isPK: false, auto: false, defaultSQL: nil)
        XCTAssertEqual(DBCopy.literal("00ff", bin, target: .postgres), "decode('00ff', 'hex')")
        XCTAssertEqual(DBCopy.literal("00ff", bin, target: .mysql), "X'00ff'")
        XCTAssertEqual(DBCopy.literal(nil, bin, target: .mysql), "NULL")
        let flag = DBCopy.Column(name: "f", sourceType: "boolean", targetType: "boolean", kind: .bool, nullable: true, isPK: false, auto: false, defaultSQL: nil)
        XCTAssertEqual(DBCopy.literal("1", flag, target: .postgres), "true")
        XCTAssertEqual(DBCopy.literal("f", flag, target: .mysql), "0")
        let num = DBCopy.Column(name: "n", sourceType: "numeric", targetType: "numeric", kind: .decimal, nullable: true, isPK: false, auto: false, defaultSQL: nil)
        XCTAssertEqual(DBCopy.literal("-12.50", num, target: .mysql), "-12.50")
        XCTAssertEqual(DBCopy.literal("NaN", num, target: .postgres), "'NaN'")
        let txt = DBCopy.Column(name: "t", sourceType: "text", targetType: "text", kind: .text, nullable: true, isPK: false, auto: false, defaultSQL: nil)
        XCTAssertEqual(DBCopy.literal(#"it's \x"#, txt, target: .mysql), #"'it''s \\x'"#)
        XCTAssertEqual(DBCopy.literal(#"it's \x"#, txt, target: .postgres), #"'it''s \x'"#)
        let ts = DBCopy.Column(name: "c", sourceType: "datetime(6)", targetType: "TEXT", kind: .timestamp, nullable: true, isPK: false, auto: false, defaultSQL: nil)
        XCTAssertEqual(DBCopy.literal("2024-05-06 07:08:09.000000", ts, target: .sqlite), "'2024-05-06 07:08:09'")
        XCTAssertEqual(DBCopy.literal("2024-05-06 07:08:09.120000", ts, target: .sqlite), "'2024-05-06 07:08:09.120000'")

        XCTAssertEqual(DBTypeMap.defaultSQL("'draft'::character varying", kind: .varchar, from: .postgres, to: .mysql), "'draft'")
        XCTAssertEqual(DBTypeMap.defaultSQL("now()", kind: .timestamptz, from: .postgres, to: .sqlite), "CURRENT_TIMESTAMP")
        XCTAssertEqual(DBTypeMap.defaultSQL("draft", kind: .varchar, from: .mysql, to: .postgres), "'draft'")
        XCTAssertEqual(DBTypeMap.defaultSQL("1", kind: .bool, from: .mysql, to: .postgres), "true")
        XCTAssertNil(DBTypeMap.defaultSQL("gen_random_uuid()", kind: .uuid, from: .postgres, to: .mysql), "a function default isn't guessed at")
        XCTAssertEqual(DBCopy.splitFK("public.users.id")?.table, "users")
    }
}

/// Copies across real Postgres and MySQL servers. Runs only with
/// TEST_RUNNER_BRIX_COPY_SERVERS=1 and throwaway servers on 55432 (postgres/brixtest)
/// and 53306 (root/brixtest, database brixcopy).
final class DBCopyServerTests: XCTestCase {
    private let svc = LiveDatabaseService()
    private let pg = DatabaseConnection(id: "copy-pg", name: "pg", kind: .postgres, host: "127.0.0.1", port: 55432, database: "postgres", user: "postgres", sslMode: .disable, tag: .local)
    private let my = DatabaseConnection(id: "copy-my", name: "my", kind: .mysql, host: "127.0.0.1", port: 53306, database: "brixcopy", user: "root", sslMode: .disable, tag: .local)
    private let pw = "brixtest"

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BRIX_COPY_SERVERS"] == "1", "needs the throwaway Postgres and MySQL servers")
    }

    private func copy(_ from: DatabaseConnection, _ fromPW: String?, schema: String, to: DatabaseConnection, _ toPW: String?, into: String, table: String) async throws -> [DBCopy.Outcome] {
        let objs = (try await svc.schema(from, password: fromPW).schemas[schema] ?? []).filter { $0.kind == .table && $0.name == table }
        var plan = try await DBCopy.plan(source: from, sourcePassword: fromPW, objects: objs, target: to, targetPassword: toPW, targetSchema: into, mode: .all, service: svc)
        for i in plan.tables.indices { plan.tables[i].clash = .replace }
        return await DBCopy.run(plan, sourcePassword: fromPW, targetPassword: toPW, service: svc) { _, _ in }
    }

    /// SQLite → Postgres → MySQL → SQLite: every value comes back the same.
    func testRoundTrip() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("rt-\(UUID().uuidString).sqlite").path
        let back = path + ".back"
        FileManager.default.createFile(atPath: path, contents: nil); FileManager.default.createFile(atPath: back, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: path); try? FileManager.default.removeItem(atPath: back) }
        let a = DatabaseConnection(id: "rt-a", name: "a", kind: .sqlite, filePath: path, tag: .local)
        let z = DatabaseConnection(id: "rt-z", name: "z", kind: .sqlite, filePath: back, tag: .local)
        _ = try await svc.execute(a, sql: "create table ct_items (id integer primary key, name varchar(80) not null default 'x', price numeric(10,2), weight real, data blob, flag boolean, created datetime)", password: nil)
        _ = try await svc.execute(a, sql: #"insert into ct_items (name, price, weight, data, flag, created) values ('café ☕', 12.50, 1.25, x'00ff10', 1, '2024-05-06 07:08:09'), ('it''s \back', null, null, null, 0, null), ('', -3.00, 0.5, x'', null, '1999-12-31 23:59:59')"#, password: nil)
        _ = try await svc.execute(a, sql: "with recursive n(i) as (select 1 union all select i + 1 from n where i < 1500) insert into ct_items (name, price) select 'row ' || i, i from n", password: nil)
        _ = try await svc.execute(pg, sql: "create schema if not exists copytest", password: pw)

        let o1 = try await copy(a, nil, schema: "main", to: pg, pw, into: "copytest", table: "ct_items")
        XCTAssertEqual(o1.map(\.state), ["Done"], "\(o1)")
        let o2 = try await copy(pg, pw, schema: "copytest", to: my, pw, into: "brixcopy", table: "ct_items")
        XCTAssertEqual(o2.map(\.state), ["Done"], "\(o2)")
        let o3 = try await copy(my, pw, schema: "brixcopy", to: z, nil, into: "main", table: "ct_items")
        XCTAssertEqual(o3.map(\.state), ["Done"], "\(o3)")

        let check = "select id, name, printf('%.2f', price), weight, hex(data), flag, created from ct_items order by id"
        let want = try await svc.execute(a, sql: check, password: nil).rows
        let got = try await svc.execute(z, sql: check, password: nil).rows
        XCTAssertEqual(got.count, 1503)
        XCTAssertEqual(Array(got.prefix(3)), Array(want.prefix(3)))
        XCTAssertEqual(got, want)
        // The copied id keeps numbering: a new row gets the next one.
        _ = try await svc.execute(pg, sql: "insert into copytest.ct_items (name) values ('next')", password: pw)
        let next = try await svc.execute(pg, sql: "select max(id) from copytest.ct_items", password: pw).rows
        XCTAssertEqual(next.first?.first ?? nil, "1504")
    }

    /// What the drivers hand back: exact values, the columns of an empty result, changed-row counts,
    /// and an agent's call on its own read-only, time-limited, capped session.
    func testDriverResults() async throws {
        let v = try await svc.execute(pg, sql: """
            select 1.50::numeric(10,2) a, 'NaN'::numeric b, 123456789012345678901234567890.123456789::numeric c, -0.0001::numeric d,
              '1 year 2 mons 3 days 04:05:06.5'::interval e, '13:14:15.25'::time f, '2024-01-02 03:04:05.123456+05'::timestamptz g,
              '2024-01-02 03:04:05.5'::timestamp h, 16384::oid i, '{1,2}'::int[] j, '{a,"b c"}'::text[] k, '10.0.0.1/8'::inet l, '{"x": 1}'::jsonb m
            """, password: pw).rows.first ?? []
        XCTAssertEqual(Array(v.prefix(11)), ["1.50", "NaN", "123456789012345678901234567890.123456789", "-0.0001", "1 year 2 mons 3 days 04:05:06.5", "13:14:15.25",
                                             "2024-01-01 22:04:05.123456+00", "2024-01-02 03:04:05.5", "16384", "{1,2}", #"{a,"b c"}"#])
        XCTAssertEqual(v[safe: 11]??.hasPrefix("<"), true, "a type Brix can't read shows as a stand-in, not bytes")
        XCTAssertEqual(v[safe: 12], #"{"x": 1}"#)

        for (c, p) in [(pg, "postgres"), (my, "mysql")] {
            let empty = try await svc.execute(c, sql: "select 1 as a, 'x' as b from (select 1 as z) q where 1 = 0", password: pw)
            XCTAssertEqual(empty.columns.map(\.name), ["a", "b"], p)
            _ = try await svc.execute(c, sql: "drop table if exists drv_t", password: pw)
            _ = try await svc.execute(c, sql: "create table drv_t (id int primary key)", password: pw)
            let ins = try await svc.execute(c, sql: "insert into drv_t values (1), (2)", password: pw)
            XCTAssertEqual(ins.message, "2 rows affected", p)
            let none = try await svc.page(c, object: DBObject(schema: c.kind == .postgres ? "public" : "brixcopy", name: "drv_t", kind: .table, rowEstimate: nil),
                                          where: "id > 5", orderBy: "", page: 0, pageSize: 10, columns: nil, password: pw)
            XCTAssertEqual(none.columns.map(\.name), ["id"], "an empty page still has its columns")
            // A console's schema is switched under the same hold of the session.
            let here = try await LiveDatabaseService.$schema.withValue(c.kind == .postgres ? "pg_catalog" : "mysql") {
                try await svc.execute(c, sql: c.kind == .postgres ? "select current_schema()" : "select database()", password: pw).rows.first?.first ?? nil
            }
            XCTAssertEqual(here, c.kind == .postgres ? "pg_catalog" : "mysql")
            // Agents: their own session, reads in a read-only transaction, at most rowCap rows.
            var a = AgentDBGateway.agentConnection(c)
            a.readOnly = true
            let r = try await LiveDatabaseService.$agent.withValue(true) {
                try await svc.execute(a, sql: c.kind == .postgres ? "select g from generate_series(1, 5000) g" : "select 1 from information_schema.columns a, information_schema.columns b limit 5000", password: pw)
            }
            XCTAssertEqual(r.rows.count, AgentDBPolicy.rowCap, p)
            do {
                _ = try await LiveDatabaseService.$agent.withValue(true) { try await svc.execute(a, sql: "insert into drv_t values (3)", password: pw) }
                XCTFail("an agent's read can't write: \(p)")
            } catch {}
        }
        let t = try await LiveDatabaseService.$agent.withValue(true) {
            try await svc.execute(AgentDBGateway.agentConnection(pg), sql: "select current_setting('statement_timeout')", password: pw).rows.first?.first ?? nil
        }
        XCTAssertEqual(t, "30s")
    }

    /// Postgres-only types arrive in MySQL and SQLite without loss.
    func testPostgresTypes() async throws {
        _ = try await svc.execute(pg, sql: "drop schema if exists pgtypes cascade", password: pw)
        _ = try await svc.execute(pg, sql: "create schema pgtypes", password: pw)
        _ = try await svc.execute(pg, sql: "create table pgtypes.ct_kinds (id bigserial primary key, b bytea, ts timestamptz, t timestamp, n numeric(20,6), j jsonb, u uuid, arr text[], ok boolean default true, note text default 'hi')", password: pw)
        _ = try await svc.execute(pg, sql: """
            insert into pgtypes.ct_kinds (b, ts, t, n, j, u, arr, ok) values
              ('\\x00ff7f'::bytea, '2024-01-02 03:04:05.123456+05', '2024-01-02 03:04:05.654321', 12345678901234.123456, '{"a": [1, 2]}', '6f1c0e2a-1111-4222-8333-944455556666', '{x,"y z"}', false),
              (null, null, null, null, null, null, null, null)
            """, password: pw)
        let o = try await copy(pg, pw, schema: "pgtypes", to: my, pw, into: "brixcopy", table: "ct_kinds")
        XCTAssertEqual(o.map(\.state), ["Done"], "\(o)")
        let r = try await svc.execute(my, sql: "select hex(b), cast(ts as char), cast(t as char), cast(n as char), cast(j as char), u, arr, ok, note from brixcopy.ct_kinds order by id", password: pw).rows
        XCTAssertEqual(r.first?[0], "00FF7F")
        XCTAssertEqual(r.first?[1], "2024-01-01 22:04:05.123456", "timestamptz in UTC, microseconds kept")
        XCTAssertEqual(r.first?[2], "2024-01-02 03:04:05.654321")
        XCTAssertEqual(r.first?[3], "12345678901234.123456")
        XCTAssertEqual(r.first?[5], "6f1c0e2a-1111-4222-8333-944455556666")
        XCTAssertEqual(r.first?[6], #"{x,"y z"}"#)
        XCTAssertEqual(r.first?[7], "0")
        XCTAssertEqual(r.last?[0] ?? "nil", "nil")
        XCTAssertEqual(r.last?[8], "hi", "the default came along")
    }
}

/// MySQL over TLS. The live part runs only with TEST_RUNNER_BRIX_TLS_SERVER=1 and a
/// throwaway MySQL 8 on 127.0.0.1:53307 with TLS on (user brix/brixtest, database brixtls).
final class MySQLTLSTests: XCTestCase {
    func testTLSNameIsNeverAnIP() {
        XCTAssertNil(LiveDatabaseService.tlsName("127.0.0.1"))
        XCTAssertNil(LiveDatabaseService.tlsName("::1"))
        XCTAssertEqual(LiveDatabaseService.tlsName("db.eu-west-2.rds.amazonaws.com"), "db.eu-west-2.rds.amazonaws.com")
    }

    /// TLS refused an IP as the server name, so every MySQL reached through a
    /// tunnel (or at an IP) with SSL on "prefer" failed before signing in.
    func testConnectsOverTLSAtAnIP() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BRIX_TLS_SERVER"] == "1", "needs the throwaway MySQL with TLS")
        let c = DatabaseConnection(id: "tls-my", name: "my", kind: .mysql, host: "127.0.0.1", port: 53307, database: "brixtls", user: "brix", sslMode: .prefer, tag: .local)
        let r = try await LiveDatabaseService().execute(c, sql: "show session status like 'Ssl_version'", password: "brixtest")
        XCTAssertEqual(r.rows.first?.first ?? nil, "Ssl_version")
        XCTAssertTrue((r.rows.first?.last ?? nil)?.hasPrefix("TLS") == true, "\(r.rows)")
    }
}
