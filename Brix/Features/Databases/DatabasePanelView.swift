import SwiftUI

/// Dockable query panel bound to one of the project's linked databases.
struct DatabasePanelView: View {
    @Environment(AppStore.self) private var store
    let ws: WorkspaceStore
    let panel: PanelInstance
    @State private var sql = ""
    @State private var result: QueryResult?
    @State private var error: String?
    @State private var running = false

    private var db: DatabaseConnection? {
        panel.resourceID.flatMap(store.database) ?? store.linkedDatabases(ws.projectID).first
    }

    var body: some View {
        PanelChrome(title: "Database") {
            picker
            Spacer(minLength: 0)
            AccentButton(title: "Run", shortcut: "⌘↩", height: 24, isLoading: running) { run() }
                .disabled(db == nil || sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || running)
        } content: {
            if let db {
                VStack(spacing: 0) {
                    CodeView(text: sql, language: .sql, editable: true, onChange: { sql = $0 }, fontSize: 12, lineHeight: 18, background: Theme.island, onRun: { run() })
                        .frame(height: 64)
                        .hairlineBottom(Color.white(0.05))
                    if let error {
                        ScrollView { Text(error).font(Typo.mono(11.5)).foregroundStyle(Theme.diffDelText).padding(12).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    } else if let r = result {
                        if r.columns.isEmpty {
                            EmptyState(symbol: "checkmark.circle", message: r.message ?? "Done.")
                        } else {
                            DataGrid(columns: r.columns, rows: r.rows)
                        }
                        HStack {
                            Text("\(r.totalRows) rows · \(Int(r.elapsedMs)) ms").font(Typo.ui(11)).foregroundStyle(Theme.text3)
                            Spacer()
                            Button("Open in SQL editor") { store.pendingQuery = (db.id, sql); store.selectedDatabase = db.id; store.route = .databases }
                                .buttonStyle(.plain).font(Typo.ui(11)).foregroundStyle(store.settings.accent.color)
                        }
                        .padding(.horizontal, 12).frame(height: 24).hairlineTop()
                    } else {
                        EmptyState(symbol: "play.circle", message: "Write a query and press ⌘↩.")
                    }
                }
                .onAppear { if sql.isEmpty { sql = Self.starter(for: db) } }
            } else {
                EmptyState(symbol: "cylinder.split.1x2", message: "No databases linked to this project.", actionTitle: "Link a database") { store.route = .projectSettings(ws.projectID) }
            }
        }
    }

    static func starter(for d: DatabaseConnection) -> String {
        if d.isSample, d.id == "atlas_dev" { return "select id, provider, status, amount_cents from payments order by created_at desc limit 5;" }
        switch d.kind {
        case .sqlite: return "select name from sqlite_master where type = 'table';"
        case .mysql: return "show tables;"
        case .postgres: return "select table_name from information_schema.tables where table_schema = 'public' limit 20;"
        }
    }

    private var picker: some View {
        MenuButton(items: {
            store.linkedDatabases(ws.projectID).map { d in
                MenuSpec(title: d.name, checked: d.id == db?.id) {
                    ws.layout.bind(panel.id, resource: d.id)
                    sql = Self.starter(for: d)
                    result = nil; error = nil
                }
            } + [.separator, MenuSpec(title: "Link a database…") { store.route = .projectSettings(ws.projectID) }]
        }) {
            HStack(spacing: 6) {
                Text(db?.kind.badge ?? "DB").font(.system(size: 8, weight: .heavy)).foregroundStyle(db?.kind.color ?? Theme.text3)
                Text(db?.name ?? "Choose").font(Typo.ui(11.5)).foregroundStyle(Theme.text).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold)).foregroundStyle(Theme.text3)
            }
            .padding(.horizontal, 8).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.input))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Database \(db?.name ?? "none")")
    }

    private func run() {
        guard let db else { return }
        running = true
        store.runQuery(sql, on: db) { r in
            running = false
            switch r {
            case .success(let res): result = res; error = nil
            case .failure(let e): error = e.message; result = nil
            }
        }
    }
}
