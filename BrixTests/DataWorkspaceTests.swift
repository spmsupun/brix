import XCTest
@testable import Brix

final class DataWorkspaceTests: XCTestCase {
    func testStatementsSplitOutsideQuotesAndComments() {
        let sql = "-- revenue; by day\nSELECT 'a;b' AS x;\n\nSELECT count(*) FROM users WHERE name = \"x;y\";\n"
        let parts = SQLText.statements(sql).map { SQLText.strip((sql as NSString).substring(with: $0)) }
        XCTAssertEqual(parts, ["SELECT 'a;b' AS x", "SELECT count(*) FROM users WHERE name = \"x;y\""])
    }

    func testStatementUnderCaret() {
        let sql = "SELECT 1;\nSELECT 2;\nSELECT 3"
        let pick = { (c: Int) in SQLText.strip((sql as NSString).substring(with: SQLText.statement(at: c, in: sql)!)) }
        XCTAssertEqual(pick(3), "SELECT 1")
        XCTAssertEqual(pick(12), "SELECT 2")
        XCTAssertEqual(pick((sql as NSString).length), "SELECT 3")
        XCTAssertEqual(SQLText.firstCodeLine(SQLText.statements("-- c\nSELECT 1")[0], in: "-- c\nSELECT 1"), 2)
        let two = "SELECT 1\nFROM t;\n\nSELECT 2;"
        XCTAssertEqual(SQLText.statements(two).map { SQLText.firstCodeLine($0, in: two) }, [1, 4])
    }

    func testLimitOnlyAddedToUnlimitedSelects() {
        XCTAssertEqual(SQLText.limited("select * from t;", limit: 500), "select * from t\nLIMIT 500")
        XCTAssertEqual(SQLText.limited("select * from t limit 5", limit: 500), "select * from t limit 5")
        XCTAssertEqual(SQLText.limited("update t set a = 1", limit: 500), "update t set a = 1")
    }

    func testStagedEditsBecomeSQL() {
        let o = DBObject(schema: "public", name: "airports", kind: .table, rowEstimate: nil)
        let edit = DWRowEdit(key: ["id": "3"], original: ["id": "3", "name": "Colombo Ratmalana"], changes: ["name": "Ratmalana", "city": String?.none])
        let sql = DataEdits.sql(object: o, kind: .postgres, edits: ["3": edit], inserted: [["iata": "KCT", "name": "Koggala"]],
                                deleted: ["21": ["id": "21"]])
        XCTAssertEqual(sql, [
            #"UPDATE "public"."airports" SET "city" = NULL, "name" = 'Ratmalana' WHERE "id" = '3';"#,
            #"INSERT INTO "public"."airports" ("iata", "name") VALUES ('KCT', 'Koggala');"#,
            #"DELETE FROM "public"."airports" WHERE "id" = '21';"#
        ])
        // A deleted row's edits are dropped, and quotes in values are escaped.
        let both = DataEdits.sql(object: o, kind: .mysql, edits: ["21": DWRowEdit(key: ["id": "21"], original: [:], changes: ["name": "O'Hare"])],
                                 inserted: [], deleted: ["21": ["id": "21"]])
        XCTAssertEqual(both, ["DELETE FROM `public`.`airports` WHERE `id` = '21';"])
        XCTAssertEqual(DataEdits.value("O'Hare", .postgres), "'O''Hare'")
        // MySQL: a trailing backslash can't swallow the closing quote.
        XCTAssertEqual(DataEdits.value("C:\\", .mysql), "'C:\\\\'")
        XCTAssertEqual(DataEdits.value("C:\\", .postgres), "'C:\\'")
    }

    func testSubmitPlanChecksEachRow() {
        let o = DBObject(schema: "s", name: "t", kind: .table, rowEstimate: nil)
        let edits = ["3": DWRowEdit(key: ["id": "3"], original: ["a": "0"], changes: ["a": "1"])]
        let pg = DataEdits.plan(object: o, kind: .postgres, edits: edits, inserted: [["a": "x"]], deleted: ["4": ["id": "4"]])
        XCTAssertEqual(pg.map(\.sql), [#"UPDATE "s"."t" SET "a" = '1' WHERE "id" = '3' RETURNING 1;"#,
                                        #"INSERT INTO "s"."t" ("a") VALUES ('x');"#,
                                        #"DELETE FROM "s"."t" WHERE "id" = '4' RETURNING 1;"#])
        XCTAssertEqual(pg.map(\.expect), [1, nil, 1])
        let my = DataEdits.plan(object: o, kind: .mysql, edits: edits, inserted: [], deleted: ["4": ["id": "4"]])
        XCTAssertEqual(my.map(\.sql), ["SELECT COUNT(*) AS brix_affected FROM `s`.`t` WHERE `id` = '3' FOR UPDATE", "UPDATE `s`.`t` SET `a` = '1' WHERE `id` = '3';",
                                        "SELECT COUNT(*) AS brix_affected FROM `s`.`t` WHERE `id` = '4' FOR UPDATE", "DELETE FROM `s`.`t` WHERE `id` = '4';"])
        XCTAssertEqual(my.map(\.expect), [1, nil, 1, nil])
        XCTAssertFalse(DataEdits.plainKey(DBColumn(name: "at", type: "timestamptz", isPK: true)))
        XCTAssertTrue(DataEdits.plainKey(DBColumn(name: "id", type: "uuid", isPK: true)))
    }

    func testRowKeyNeedsAPrimaryKey() {
        let cols = [DBColumn(name: "id", type: "int", isPK: true), DBColumn(name: "name", type: "text")]
        XCTAssertEqual(DataEdits.rowKey(["7", "x"], columns: cols)?.key, ["id": "7"])
        XCTAssertNil(DataEdits.rowKey(["7", "x"], columns: cols.map { var c = $0; c.isPK = false; return c }))
    }
}

final class MySQLScopeTests: XCTestCase {
    func testAgentsSeeOnlyTheConnectionsDatabase() {
        var d = DatabaseConnection(id: "m", name: "m", kind: .mysql, tag: .dev)
        let all = ["shop": [DBObject(schema: "shop", name: "users", kind: .table, rowEstimate: nil)],
                   "crm": [DBObject(schema: "crm", name: "users", kind: .table, rowEstimate: nil)]]
        XCTAssertEqual(Set(d.agentSchemas(all).keys), ["shop", "crm"], "no default database: everything")
        d.database = "shop"
        XCTAssertEqual(Array(d.agentSchemas(all).keys), ["shop"])
    }
}

final class ShortVersionTests: XCTestCase {
    func testServerVersionsReadShort() {
        XCTAssertEqual(DatabaseEditorSheet.shortVersion("MySQL 10.11.7-MariaDB-1:10.11.7+maria~ubu2204"), "MariaDB 10.11.7")
        XCTAssertEqual(DatabaseEditorSheet.shortVersion("PostgreSQL 17.6 (Debian 17.6-1.pgdg120+1) on x86_64-pc-linux-gnu"), "PostgreSQL 17.6")
        XCTAssertEqual(DatabaseEditorSheet.shortVersion("MySQL 8.0.36"), "MySQL 8.0.36")
    }
}
