import SwiftUI

/// Copies tables from one connection to another, any engine to any engine:
/// pick the tables and the target, review what happens to each, confirm, copy.
struct CopyDatabaseSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent
    let sourceID: ResourceID
    var initialSchema: String?
    var initialTables: [String]?

    private enum Step { case choose, review, copying, done }
    @State private var step = Step.choose
    @State private var tree: DBSchemaTree?
    @State private var loadError: String?
    @State private var schema = ""
    @State private var picked: Set<String> = []
    @State private var targetID: ResourceID = ""
    @State private var targetSchema = ""
    @State private var mode = DBCopy.Mode.all
    @State private var plan: DBCopy.Plan?
    @State private var planning = false
    @State private var typed = ""
    @State private var copied: [Int: Int] = [:]
    @State private var outcomes: [DBCopy.Outcome] = []
    @State private var job: Task<Void, Never>?

    private var source: DatabaseConnection? { store.database(sourceID) }
    private var target: DatabaseConnection? { store.database(targetID) }
    /// Sample connections run on made-up data: not copied to or from.
    private var targets: [DatabaseConnection] { store.library.databases.filter { !$0.isSample } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Copy Tables").font(Typo.pageTitle).foregroundStyle(Theme.text)
                Text("From \(source?.name ?? "?") to another connection, between PostgreSQL, MySQL and SQLite. The source is only read.")
                    .font(Typo.ui(12)).foregroundStyle(Theme.text3)
            }
            Group {
                switch step {
                case .choose: choose
                case .review: review
                case .copying, .done: running
                }
            }
            .frame(height: 400)
            footer
        }
        .padding(22)
        .frame(width: 680)
        .background(Theme.sheet)
        .task { await load() }
        .onDisappear { job?.cancel() }
    }

    // MARK: Choose

    private var objects: [DBObject] { (tree?.schemas[schema] ?? []).filter { $0.kind == .table }.sorted { $0.name < $1.name } }

    @ViewBuilder private var choose: some View {
        if let loadError {
            Text(loadError).font(Typo.ui(12)).foregroundStyle(Theme.red)
        } else if tree == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    if source?.kind != .sqlite {
                        Picker("From", selection: $schema) {
                            ForEach((tree?.schemas.keys.sorted() ?? []), id: \.self) { Text($0).tag($0) }
                        }
                        .frame(width: 240)
                        .onChange(of: schema) { _, _ in picked = Set(objects.map(\.name)) }
                    }
                    Spacer()
                    Button(picked.count == objects.count ? "Select None" : "Select All") {
                        picked = picked.count == objects.count ? [] : Set(objects.map(\.name))
                    }
                    .buttonStyle(.hand).font(Typo.ui(12)).foregroundStyle(Theme.text2)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if objects.isEmpty { Text("No tables here.").font(Typo.ui(12)).foregroundStyle(Theme.text3).padding(8) }
                        ForEach(objects) { o in
                            Toggle(isOn: Binding(get: { picked.contains(o.name) }, set: { on in if on { picked.insert(o.name) } else { picked.remove(o.name) } })) {
                                HStack {
                                    Text(o.name).font(Typo.ui(12.5)).foregroundStyle(Theme.body)
                                    Spacer()
                                    if let n = o.rowEstimate, n > 0 { Text("~\(Compact.number(n)) rows").font(Typo.ui(11)).foregroundStyle(Theme.text3).monospacedDigit() }
                                }
                            }
                            .toggleStyle(.checkbox)
                            .padding(.vertical, 4).padding(.horizontal, 8)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.well))
                HStack(spacing: 10) {
                    Picker("To", selection: $targetID) {
                        Text("Choose a connection").tag("")
                        ForEach(targets) { d in Text("\(d.name) · \(d.kind.label)" + (d.tag.isProduction ? " · PROD" : "")).tag(d.id) }
                    }
                    .frame(width: 330)
                    .onChange(of: targetID) { _, _ in targetSchema = defaultTargetSchema }
                    if let t = target, t.kind != .sqlite {
                        TextField(t.kind == .postgres ? "Schema" : "Database", text: $targetSchema)
                            .textFieldStyle(.roundedBorder).frame(width: 160)
                            .help(t.kind == .postgres ? "Schema in the target; created if it isn't there" : "Database on the target server; created if it isn't there")
                    }
                }
                Picker("Copy", selection: $mode) {
                    ForEach(DBCopy.Mode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 420)
                if let why = targetProblem {
                    Text(why).font(Typo.ui(11.5)).foregroundStyle(Theme.amber)
                }
            }
        }
    }

    /// Why the chosen target can't take the copy, if it can't.
    private var targetProblem: String? {
        guard let s = source, let t = target else { return nil }
        if t.readOnly { return "\(t.name) is read-only, so nothing can be copied into it. Turn read-only off for it first." }
        let into = targetSchema.trimmingCharacters(in: .whitespaces)
        if DBCopy.sameDatabase(s, t), t.kind == .sqlite || into == schema {
            return "That's where the tables come from. Pick another connection" + (t.kind == .sqlite ? "." : ", or another \(t.kind == .postgres ? "schema" : "database").")
        }
        let system = t.kind == .mysql ? ["mysql", "sys", "information_schema", "performance_schema"] : ["pg_catalog", "information_schema", "pg_toast"]
        if t.kind != .sqlite, system.contains(into.lowercased()) { return "\(into) is a system \(t.kind == .postgres ? "schema" : "database")." }
        return nil
    }

    /// The choices that mean something in this mode: structure only can't add rows.
    private var clashChoices: [DBCopy.Clash] { mode == .structure ? [.skip, .replace] : DBCopy.Clash.allCases }

    private var defaultTargetSchema: String {
        guard let t = target else { return "" }
        switch t.kind {
        case .postgres: return source?.kind == .postgres ? schema : "public"
        case .mysql: return t.database.isEmpty ? schema : t.database
        case .sqlite: return "main"
        }
    }

    // MARK: Review

    @ViewBuilder private var review: some View {
        if let plan {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(plan.mode.label) into \(plan.target.name)" + (plan.target.kind == .sqlite ? "" : " · \(plan.targetSchema)") + (plan.createSchema ? " (created)" : ""))
                    .font(Typo.ui(12.5, .semibold)).foregroundStyle(Theme.text)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(plan.tables.enumerated()), id: \.offset) { i, t in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(t.source.name).font(Typo.ui(12.5, .medium)).foregroundStyle(Theme.body)
                                    Text("~\(Compact.number(t.rowEstimate)) rows").font(Typo.ui(11)).foregroundStyle(Theme.text3).monospacedDigit()
                                    Spacer()
                                    if t.exists {
                                        Text("Already there:").font(Typo.ui(11)).foregroundStyle(Theme.amber)
                                        Picker("", selection: Binding(get: { self.plan?.tables[i].clash ?? .skip }, set: { self.plan?.tables[i].clash = $0; typed = "" })) {
                                            ForEach(clashChoices) { Text($0.label).tag($0) }
                                        }
                                        .labelsHidden().frame(width: 160)
                                    } else {
                                        Text("New").font(Typo.ui(11)).foregroundStyle(Theme.green)
                                    }
                                }
                                ForEach(t.warnings, id: \.self) { w in
                                    Text("• " + w).font(Typo.ui(11)).foregroundStyle(Theme.text3)
                                }
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.well))
                        }
                    }
                }
                if let ask = confirmText {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(ask).font(Typo.ui(11.5)).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
                        TextField("Type \(confirmWord)", text: $typed).textFieldStyle(.roundedBorder).frame(width: 260)
                    }
                }
            }
        }
    }

    private var drops: [String] { plan?.tables.filter { $0.exists && $0.clash == .replace }.map(\.source.name) ?? [] }
    /// The target's name, typed to confirm dropping tables or writing to Production.
    private var confirmWord: String { plan.map { $0.target.kind == .sqlite ? $0.target.name : $0.targetSchema } ?? "" }

    private var confirmText: String? {
        guard let plan else { return nil }
        var parts: [String] = []
        if plan.target.tag.isProduction { parts.append("\(plan.target.name) is Production.") }
        if !drops.isEmpty { parts.append("These tables in the target are dropped and their rows lost: " + drops.joined(separator: ", ") + ".") }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ") + " Type \(confirmWord) to go ahead."
    }

    // MARK: Running

    private var running: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array((plan?.tables ?? []).enumerated()), id: \.offset) { i, t in
                        let o = outcomes.first { $0.table == t.source.name }
                        HStack(spacing: 8) {
                            if let o {
                                let ok = o.state == "Done" && o.error == nil
                                Image(systemName: ok ? "checkmark.circle.fill" : (o.state.hasPrefix("Skipped") ? "minus.circle" : "exclamationmark.triangle.fill"))
                                    .foregroundStyle(ok ? Theme.green : (o.state.hasPrefix("Skipped") ? Theme.text3 : Theme.amber))
                            } else if copied[i] != nil {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "circle").foregroundStyle(Theme.text3)
                            }
                            Text(t.source.name).font(Typo.ui(12.5)).foregroundStyle(Theme.body)
                            Spacer()
                            Text(o.map { "\($0.state) · \(Compact.number($0.rows)) rows" } ?? copied[i].map { "\(Compact.number($0)) of ~\(Compact.number(t.rowEstimate))" } ?? "")
                                .font(Typo.ui(11)).foregroundStyle(Theme.text3).monospacedDigit()
                        }
                        if let e = o?.error { Text(e).font(Typo.ui(11)).foregroundStyle(Theme.amber).textSelection(.enabled).padding(.leading, 24) }
                    }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if step == .review { SubtleButton(title: "Back") { step = .choose; plan = nil; typed = "" } }
            Spacer()
            switch step {
            case .choose:
                SubtleButton(title: "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                AccentButton(title: "Review", isLoading: planning) { makePlan() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(picked.isEmpty || target == nil || targetProblem != nil || (target?.kind != .sqlite && targetSchema.trimmingCharacters(in: .whitespaces).isEmpty))
            case .review:
                SubtleButton(title: "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                AccentButton(title: "Copy") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(confirmText != nil && typed != confirmWord)
            case .copying:
                SubtleButton(title: "Stop") { job?.cancel() }
            case .done:
                SubtleButton(title: "Show Target") {
                    if let t = target { store.selectedDatabase = t.id; store.go(.databases) }
                    dismiss()
                }
                AccentButton(title: "Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Actions

    private func load() async {
        guard let s = source else { loadError = "That connection is gone."; return }
        do {
            let t = try await store.svc(s).db.schema(s, password: store.dbPassword(s))
            tree = t
            schema = initialSchema ?? (s.kind == .sqlite ? "main" : (t.schemas.keys.contains("public") ? "public" : (t.schemas.keys.contains(s.database) ? s.database : t.schemas.keys.sorted().first ?? "")))
            let names = Set(objects.map(\.name))
            picked = initialTables.map { Set($0).intersection(names) } ?? names
        } catch {
            loadError = "Couldn't read \(s.name): " + LiveDatabaseService.describe(error)
        }
    }

    private func makePlan() {
        guard let s = source, let t = target else { return }
        planning = true
        let objs = objects.filter { picked.contains($0.name) }
        Task {
            defer { planning = false }
            do {
                plan = try await DBCopy.plan(source: s, sourcePassword: store.dbPassword(s), objects: objs, target: t, targetPassword: store.dbPassword(t),
                                             targetSchema: targetSchema.trimmingCharacters(in: .whitespaces), mode: mode, service: store.svc(t).db)
                step = .review
            } catch {
                store.toast(.error, "Couldn't prepare the copy", detail: LiveDatabaseService.describe(error))
            }
        }
    }

    private func start() {
        guard let plan, let s = source, let t = target else { return }
        step = .copying
        copied = [:]
        outcomes = []
        let svc = store.svc(t).db
        let sp = store.dbPassword(s), tp = store.dbPassword(t)
        job = Task {
            let out = await DBCopy.run(plan, sourcePassword: sp, targetPassword: tp, service: svc) { i, n in copied[i] = n }
            outcomes = out
            step = .done
            store.schemaCache[t.id] = nil
            store.loadTree(t, force: true)
            let rows = out.reduce(0) { $0 + $1.rows }
            let clean = out.allSatisfy { ($0.state == "Done" || $0.state.hasPrefix("Skipped")) && $0.error == nil }
            let stopped = out.contains { $0.state == "Stopped" || $0.state == "Not started" }
            store.toast(clean ? .success : .error, clean ? "Copied to \(t.name)" : (stopped ? "Copy stopped" : "Copy finished with problems"),
                        detail: "\(Compact.number(rows)) rows; \(out.filter { $0.state == "Done" }.count) of \(out.count) tables done")
        }
    }
}
