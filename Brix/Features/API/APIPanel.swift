import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A project's HTTP requests in collections and folders: build one, send it, read the response.
struct APIPanel: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accent) private var accent
    let ws: WorkspaceStore

    enum Section: Hashable { case params, headers, auth, body }
    enum CollectionTab: Hashable { case variables, auth }
    @State private var section = Section.params
    @State private var collectionTab = CollectionTab.variables
    @State private var showHeaders = false
    @State private var filter = ""
    @State private var editingEnvs = false
    @State private var importing = false
    @State private var pastingCurl = false
    @State private var curlText = ""
    @State private var dropTarget: String?
    // Per request id, for this window: responses aren't saved.
    @State private var responses: [String: APIResponse] = [:]
    @State private var errors: [String: String] = [:]
    @State private var tasks: [String: Task<Void, Never>] = [:]

    var body: some View {
        PanelChrome(title: "API") {
            Spacer(minLength: 0)
            environmentMenu
            Menu {
                Button("Import File…") { importing = true }
                Button("Paste a curl Command…") { curlText = ""; pastingCurl = true }
            } label: {
                Image(systemName: "square.and.arrow.down").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text3)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Import")
            .help("Import a Postman, OpenAPI, Insomnia or HAR file, or a curl command")
            Menu {
                Button("New Request") { newRequest() }
                Button("New Folder") { newFolder() }.disabled(ws.api.selectedContainer == nil)
                Button("New Collection") { newCollection() }
            } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text3)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("New")
        } content: {
            HStack(spacing: 0) {
                sidebar.frame(width: 260)
                Rectangle().fill(Theme.divider).frame(width: 1)
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { importDropped($0) }
        }
        .popover(isPresented: $editingEnvs, arrowEdge: .bottom) { APIEnvironmentsEditor(ws: ws).frame(width: 560, height: 420) }
        .sheet(isPresented: $pastingCurl) { curlSheet }
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.importTypes, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): importFiles(urls)
            case .failure(let error): store.toast(.error, "Couldn't open the file", detail: error.localizedDescription)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        let api = ws.api
        if let s = api.selectedID, api.request(s) != nil {
            editor(s)
        } else if let s = api.selectedID, let f = api.folder(s) {
            folderEditor(f)
        } else if let s = api.selectedID, let c = api.collections.first(where: { $0.id == s }) {
            collectionEditor(c)
        } else if api.collections.isEmpty && api.requests.isEmpty {
            EmptyState(symbol: "network", message: "No requests yet. Make a collection with +, or import a Postman, OpenAPI, Insomnia or HAR file (drop it here).",
                       actionTitle: "Import File…") { importing = true }
        } else {
            EmptyState(symbol: "network", message: "Pick a request, folder or collection.")
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 6) {
            SearchField(placeholder: "Filter requests", text: $filter).padding([.horizontal, .top], 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if filter.isEmpty {
                        ForEach(ws.api.collections) { c in
                            row(id: c.id, depth: 0, container: true, title: c.name) {
                                Image(systemName: "square.stack.3d.up").font(.system(size: 11)).foregroundStyle(accent)
                            }
                            .contextMenu { containerMenu(c.id, name: c.name) }
                            if !ws.api.collapsed.contains(c.id) { children(c.id, depth: 1) }
                        }
                        let loose = ws.api.requests.filter { $0.parentID == nil }
                        if !loose.isEmpty {
                            heading("Not in a collection")
                            ForEach(loose) { requestRow($0, depth: 0) }
                        }
                    } else {
                        let q = filter.lowercased()
                        ForEach(ws.api.requests.filter { $0.name.lowercased().contains(q) || $0.url.lowercased().contains(q) }) { r in
                            requestRow(r, depth: 0, sub: ws.api.path(of: r.id))
                        }
                    }
                    history
                }
                .padding(.horizontal, 6).padding(.bottom, 8)
            }
        }
    }

    /// Folders, then requests, inside a collection or folder.
    private func children(_ parent: String, depth: Int) -> AnyView {
        AnyView(Group {
            ForEach(ws.api.folders.filter { $0.parentID == parent }) { f in
                row(id: f.id, depth: depth, container: true, title: f.name) {
                    Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(Theme.text3)
                }
                .contextMenu { containerMenu(f.id, name: f.name) }
                if !ws.api.collapsed.contains(f.id) { children(f.id, depth: depth + 1) }
            }
            ForEach(ws.api.requests.filter { $0.parentID == parent }) { requestRow($0, depth: depth) }
        })
    }

    private func requestRow(_ r: APIRequest, depth: Int, sub: String? = nil) -> some View {
        row(id: r.id, depth: depth, container: false, title: r.name, sub: sub) {
            Text(Self.short(r.method)).font(Typo.mono(9.5, .bold)).foregroundStyle(Self.color(r.method)).frame(width: 30, alignment: .leading)
        }
        .contextMenu {
            Button("Copy as curl") { copyCurl(r) }
            Button("Duplicate") { var c = r; c.id = UUID().uuidString; c.name += " copy"; add(c) }
            Divider()
            Button("Delete", role: .destructive) { remove(r.id) }
        }
    }

    @ViewBuilder private func containerMenu(_ id: String, name: String) -> some View {
        Button("New Request") { newRequest(in: id) }
        Button("New Folder") { ws.api.selectedID = id; newFolder() }
        if let c = ws.api.collections.first(where: { $0.id == id }) {
            Button("Export as Postman Collection…") { exportPostman(c) }
        }
        Divider()
        Button("Delete…", role: .destructive) {
            store.confirm("Delete “\(name)”?", "Its folders and requests are deleted too. This can't be undone.", confirm: "Delete") { remove(id) }
        }
    }

    /// One line of the tree. Drag a row onto a collection or folder to move it inside,
    /// or onto a request to put it just above.
    private func row(id: String, depth: Int, container: Bool, title: String, sub: String? = nil, @ViewBuilder icon: () -> some View) -> some View {
        let selected = ws.api.selectedID == id, open = !ws.api.collapsed.contains(id)
        return HStack(spacing: 6) {
            if container {
                Button { toggle(id) } label: {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.text3)
                        .frame(width: 12, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.hand)
                .accessibilityLabel(open ? "Close \(title)" : "Open \(title)")
            } else {
                Color.clear.frame(width: 12, height: 1)
            }
            Button { ws.api.selectedID = id } label: {
                HStack(spacing: 6) {
                    icon()
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(Typo.ui(12.5, container ? .medium : .regular)).foregroundStyle(Theme.text).lineLimit(1)
                        if let sub, !sub.isEmpty { Text(sub).font(Typo.ui(10.5)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle) }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.hand)
            .accessibilityLabel(title)
        }
        .padding(.leading, CGFloat(depth) * 14 + 2).padding(.trailing, 6).padding(.vertical, 4)
        .rowBackground(selected: selected)
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(dropTarget == id ? accent : .clear))
        .draggable(id)
        .dropDestination(for: String.self) { items, _ in
            guard let moved = items.first, moved != id else { return false }
            ws.api.move(moved, onto: id)
            return true
        } isTargeted: { on in
            if on { dropTarget = id } else if dropTarget == id { dropTarget = nil }
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(Typo.ui(10.5, .semibold)).foregroundStyle(Theme.text3)
            .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 2)
    }

    @ViewBuilder private var history: some View {
        let q = filter.lowercased()
        let items = ws.api.history.filter { q.isEmpty || $0.request.name.lowercased().contains(q) || $0.request.url.lowercased().contains(q) }
        if !items.isEmpty {
            HStack {
                heading("History")
                Spacer()
                Button("Clear") { ws.api.history = [] }.buttonStyle(.hand).font(Typo.ui(10.5)).foregroundStyle(Theme.text3).padding(.top, 10)
            }
            ForEach(items) { h in
                Button { reopen(h) } label: {
                    HStack(spacing: 8) {
                        Text(Self.short(h.request.method)).font(Typo.mono(9.5, .bold)).foregroundStyle(Self.color(h.request.method)).frame(width: 30, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(h.request.name).font(Typo.ui(12)).foregroundStyle(Theme.text).lineLimit(1)
                            Text("\(h.status.map(String.init) ?? "failed") · \(h.date.formatted(.relative(presentation: .named)))")
                                .font(Typo.ui(10.5)).foregroundStyle(Theme.text3).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4).contentShape(Rectangle())
                }
                .buttonStyle(.hand)
            }
        }
    }

    private var environmentMenu: some View {
        Menu {
            Button("No Environment") { ws.api.environmentID = nil }
            ForEach(ws.api.environments) { e in Button(e.name) { ws.api.environmentID = e.id } }
            Divider()
            Button("Edit Environments…") { editingEnvs = true }
        } label: {
            Text(ws.api.environment?.name ?? "No Environment").font(Typo.ui(11.5, .medium)).foregroundStyle(Theme.text2)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Variables used as {{name}} in requests")
    }

    // MARK: Request editor

    /// Edits the request with this id, wherever it is in the list now.
    private func field<T>(_ id: String, _ path: WritableKeyPath<APIRequest, T>, _ fallback: T) -> Binding<T> {
        Binding(get: { ws.api.requests.first { $0.id == id }?[keyPath: path] ?? fallback },
                set: { v in if let i = ws.api.requests.firstIndex(where: { $0.id == id }) { ws.api.requests[i][keyPath: path] = v } })
    }

    private func editor(_ id: String) -> some View {
        let r = ws.api.request(id) ?? APIRequest()
        let sending = tasks[id] != nil
        let path = ws.api.path(of: id)
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if !path.isEmpty { Text(path).font(Typo.ui(11)).foregroundStyle(Theme.text3).lineLimit(1) }
                TextField("Name", text: field(id, \.name, ""))
                    .textFieldStyle(.plain).font(Typo.ui(13.5, .semibold)).foregroundStyle(Theme.text)
                    .accessibilityLabel("Request name")
            }
            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    Menu {
                        ForEach(APIRequest.methods, id: \.self) { m in Button(m) { field(id, \.method, "GET").wrappedValue = m } }
                    } label: {
                        Text(r.method).font(Typo.mono(12, .bold)).foregroundStyle(Self.color(r.method))
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .padding(.horizontal, 10)
                    .accessibilityLabel("Method, \(r.method)")
                    Rectangle().fill(Theme.controlStroke).frame(width: 1, height: 18)
                    TextField("https://api.example.com/items or {{baseUrl}}/items", text: field(id, \.url, ""))
                        .textFieldStyle(.plain).font(Typo.mono(12.5)).foregroundStyle(Theme.text)
                        .padding(.horizontal, 10)
                        .onSubmit { send(id) }
                        .accessibilityLabel("URL")
                }
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.input))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.controlStroke))
                if sending {
                    SubtleButton(title: "Cancel", symbol: "stop.fill", height: 32) { tasks[id]?.cancel() }
                } else {
                    AccentButton(title: "Send", shortcut: "⌘↩", height: 32) { send(id) }
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            SegmentedControl(options: [(Section.params, "Params" + Self.count(r.params)), (.headers, "Headers" + Self.count(r.headers)),
                                       (.auth, r.auth.kind == .inherit ? "Auth" : "Auth · \(r.auth.kind.label)"),
                                       (.body, r.bodyKind == .none ? "Body" : "Body · \(r.bodyKind.label)")], selection: $section)
            Group {
                switch section {
                case .params: APIFieldsEditor(fields: field(id, \.params, []), keyLabel: "Query parameter")
                case .headers: APIFieldsEditor(fields: field(id, \.headers, []), keyLabel: "Header")
                case .auth: authEditor(field(id, \.auth, APIAuth()), allowInherit: true, inherited: ws.api.inheritedAuth(from: r.parentID))
                case .body: bodyEditor(id, r)
                }
            }
            .frame(height: 170)
            Rectangle().fill(Theme.divider).frame(height: 1)
            responseView(id, sending: sending)
        }
        .padding(12)
    }

    private func bodyEditor(_ id: String, _ r: APIRequest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SegmentedControl(options: APIBodyKind.allCases.map { ($0, $0.label) }, selection: field(id, \.bodyKind, .none))
            if r.bodyKind != .none, ["GET", "HEAD"].contains(r.method) {
                Text("\(r.method) requests are sent without a body.").font(Typo.ui(11)).foregroundStyle(Theme.amber)
            }
            switch r.bodyKind {
            case .none:
                Text("This request sends no body.").font(Typo.ui(12)).foregroundStyle(Theme.text3)
                Spacer(minLength: 0)
            case .json, .text:
                CodeView(text: r.body, language: r.bodyKind == .json ? .json : .plain, editable: true,
                         onChange: { field(id, \.body, "").wrappedValue = $0 }, onRun: { send(id) })
                    .id(id)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.controlStroke))
            case .form:
                APIFieldsEditor(fields: field(id, \.formFields, []), keyLabel: "Field")
            case .multipart:
                let fields = field(id, \.formFields, [])
                APIFieldsEditor(fields: fields, keyLabel: "Field", trailing: { f in AnyView(fileToggle(fields, f)) })
            }
        }
    }

    /// Text or file for one multipart field; picking File asks for the file.
    private func fileToggle(_ fields: Binding<[APIField]>, _ f: APIField) -> some View {
        Menu {
            Button("Text") { setField(fields, f.id) { $0.isFile = false } }
            Button("File…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true; panel.canChooseDirectories = false
                if panel.runModal() == .OK, let url = panel.url { setField(fields, f.id) { $0.isFile = true; $0.value = url.path } }
            }
        } label: {
            Text(f.isFile ? "File" : "Text").font(Typo.ui(11)).foregroundStyle(f.isFile ? accent : Theme.text3)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .accessibilityLabel("\(f.key) is \(f.isFile ? "a file" : "text")")
    }

    private func setField(_ fields: Binding<[APIField]>, _ id: String, _ change: (inout APIField) -> Void) {
        if let i = fields.wrappedValue.firstIndex(where: { $0.id == id }) { change(&fields.wrappedValue[i]) }
    }

    /// Sign-in settings. `inherited` is what Inherit would use, and where it comes from.
    private func authEditor(_ auth: Binding<APIAuth>, allowInherit: Bool, inherited: (auth: APIAuth, from: String?)?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SegmentedControl(options: APIAuth.Kind.editable.filter { allowInherit || $0 != .inherit }.map { ($0, $0.label) }, selection: auth.kind)
            switch auth.wrappedValue.kind {
            case .inherit:
                let from = inherited?.from.map { " from “\($0)”" } ?? ""
                if let i = inherited, i.auth.kind == .unsupported {
                    Text("Uses “\(i.auth.original)” sign-in\(from), which Brix can't do yet: this won't send until one of them picks another.")
                        .font(Typo.ui(12)).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(inherited.map { $0.auth.kind == .none ? "No sign-in\(from)." : "Uses \($0.auth.kind.label)\(from)." } ?? "No sign-in.")
                        .font(Typo.ui(12)).foregroundStyle(Theme.text2)
                }
            case .unsupported:
                Text("Imported “\(auth.wrappedValue.original)” sign-in, which Brix can't do yet. Requests using it won't send until you pick another sign-in above.")
                    .font(Typo.ui(12)).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
            case .none:
                Text("No sign-in is sent.").font(Typo.ui(12)).foregroundStyle(Theme.text2)
            case .bearer:
                authField("Token", auth.token)
            case .basic:
                authField("Username", auth.username)
                authField("Password", auth.password, secure: true)
            case .apiKey:
                authField("Key", auth.key, placeholder: "X-API-Key")
                authField("Value", auth.value)
                Toggle("Send as a query parameter instead of a header", isOn: auth.inQuery).toggleStyle(.checkbox).font(Typo.ui(12))
            }
            if ![.inherit, .none].contains(auth.wrappedValue.kind) {
                Text("Use a {{variable}} from a locked environment value to keep a secret out of the project's saved file.")
                    .font(Typo.ui(11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func authField(_ label: String, _ text: Binding<String>, placeholder: String = "", secure: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(label).font(Typo.ui(12)).foregroundStyle(Theme.text2).frame(width: 70, alignment: .leading)
            Group {
                if secure { SecureField(placeholder, text: text) } else { TextField(placeholder, text: text) }
            }
            .textFieldStyle(.plain).font(Typo.mono(12)).foregroundStyle(Theme.text)
            .padding(.horizontal, 8).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.input))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.controlStroke))
            .accessibilityLabel(label)
        }
    }

    // MARK: Folder and collection editors

    private func folderField<T>(_ id: String, _ path: WritableKeyPath<APIFolder, T>, _ fallback: T) -> Binding<T> {
        Binding(get: { ws.api.folders.first { $0.id == id }?[keyPath: path] ?? fallback },
                set: { v in if let i = ws.api.folders.firstIndex(where: { $0.id == id }) { ws.api.folders[i][keyPath: path] = v } })
    }

    private func collectionField<T>(_ id: String, _ path: WritableKeyPath<APICollection, T>, _ fallback: T) -> Binding<T> {
        Binding(get: { ws.api.collections.first { $0.id == id }?[keyPath: path] ?? fallback },
                set: { v in if let i = ws.api.collections.firstIndex(where: { $0.id == id }) { ws.api.collections[i][keyPath: path] = v } })
    }

    private func folderEditor(_ f: APIFolder) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ws.api.path(of: f.id)).font(Typo.ui(11)).foregroundStyle(Theme.text3)
            TextField("Folder name", text: folderField(f.id, \.name, "")).textFieldStyle(.plain).font(Typo.ui(15, .semibold))
                .accessibilityLabel("Folder name")
            countLine(f.id)
            SegmentedControl(options: [(CollectionTab.variables, "Variables" + Self.count(f.variables)),
                                       (.auth, f.auth.kind == .inherit ? "Auth" : "Auth · \(f.auth.kind.label)")], selection: $collectionTab)
            switch collectionTab {
            case .variables:
                Text("Used as {{name}} by the requests inside, over the collection's. The chosen environment's variables win over these.")
                    .font(Typo.ui(11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                APIFieldsEditor(fields: folderField(f.id, \.variables, []), keyLabel: "Variable").frame(height: 170)
            case .auth:
                authEditor(folderField(f.id, \.auth, APIAuth()), allowInherit: true, inherited: ws.api.inheritedAuth(from: f.parentID))
                    .frame(height: 170)
            }
            HStack { SubtleButton(title: "New Request", symbol: "plus") { newRequest(in: f.id) }; Spacer() }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private func collectionEditor(_ c: APICollection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Collection name", text: collectionField(c.id, \.name, "")).textFieldStyle(.plain).font(Typo.ui(15, .semibold))
                .accessibilityLabel("Collection name")
            countLine(c.id)
            SegmentedControl(options: [(CollectionTab.variables, "Variables" + Self.count(c.variables)),
                                       (.auth, c.auth.kind == .none ? "Auth" : "Auth · \(c.auth.kind.label)")], selection: $collectionTab)
            switch collectionTab {
            case .variables:
                Text("Used as {{name}} by every request in this collection. The chosen environment's variables win over these. Lock a value to keep it in the Keychain instead of the project's saved file.")
                    .font(Typo.ui(11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                APILockedFields(fields: collectionField(c.id, \.variables, []), secrets: collectionField(c.id, \.secrets, []), account: c.secretAccount)
            case .auth:
                authEditor(collectionField(c.id, \.auth, APIAuth(kind: .none)), allowInherit: false, inherited: nil)
            }
            HStack { SubtleButton(title: "New Request", symbol: "plus") { newRequest(in: c.id) }; Spacer() }
        }
        .padding(16)
    }

    private func countLine(_ id: String) -> some View {
        var inside: Set<String> = [id], grew = true
        while grew {
            let n = inside.count
            for f in ws.api.folders where inside.contains(f.parentID) { inside.insert(f.id) }
            grew = inside.count != n
        }
        let requests = ws.api.requests.filter { $0.parentID.map(inside.contains) == true }.count
        return Text("\(requests) request\(requests == 1 ? "" : "s"), \(inside.count - 1) folder\(inside.count == 2 ? "" : "s")")
            .font(Typo.ui(11.5)).foregroundStyle(Theme.text3)
    }

    // MARK: Response

    @ViewBuilder private func responseView(_ id: String, sending: Bool) -> some View {
        if sending {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Sending…").font(Typo.ui(12)).foregroundStyle(Theme.text2) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let e = errors[id] {
            VStack(alignment: .leading, spacing: 4) {
                Text("Request failed").font(Typo.ui(12.5, .semibold)).foregroundStyle(Theme.red)
                Text(e).font(Typo.ui(12)).foregroundStyle(Theme.text2).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if let res = responses[id] {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text("\(res.status) \(Self.reason(res.status))")
                        .font(Typo.ui(12.5, .semibold)).foregroundStyle(Self.statusColor(res.status))
                    Text("\(res.ms) ms").font(Typo.mono(11.5)).foregroundStyle(Theme.text2)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(res.body.count), countStyle: .file)).font(Typo.mono(11.5)).foregroundStyle(Theme.text2)
                    Spacer()
                    SegmentedControl(options: [(false, "Body"), (true, "Headers \(res.headers.count)")], selection: $showHeaders)
                    IconButton(symbol: "doc.on.doc", label: "Copy response body") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(res.text, forType: .string)
                    }
                }
                if showHeaders {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(res.headers.enumerated()), id: \.offset) { _, h in
                                HStack(alignment: .top, spacing: 10) {
                                    Text(h.0).font(Typo.mono(11.5)).foregroundStyle(Theme.synType).frame(width: 200, alignment: .leading)
                                    Text(h.1).font(Typo.mono(11.5)).foregroundStyle(Theme.body).textSelection(.enabled)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    let text = res.text
                    // Highlighting a very large body would stall typing; it's shown plain.
                    CodeView(text: text, language: text.utf8.count < 300_000 && (text.hasPrefix("{") || text.hasPrefix("[")) ? .json : .plain)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        } else {
            Text("Send the request to see the response here.").font(Typo.ui(12)).foregroundStyle(Theme.text3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Actions

    private func toggle(_ id: String) {
        if ws.api.collapsed.contains(id) { ws.api.collapsed.remove(id) } else { ws.api.collapsed.insert(id) }
    }

    /// Opens the containers above an item so it shows in the list.
    private func reveal(_ id: String) {
        for p in ws.api.ancestors(of: id) { ws.api.collapsed.remove(p) }
    }

    private func add(_ r: APIRequest) {
        ws.api.requests.append(r)
        ws.api.selectedID = r.id
        reveal(r.id)
    }

    private func newRequest(in parent: String? = nil) {
        add(APIRequest(parentID: parent ?? ws.api.selectedContainer))
        section = .params
    }

    private func newFolder() {
        guard let p = ws.api.selectedContainer else { return }
        let f = APIFolder(parentID: p)
        ws.api.folders.append(f)
        ws.api.collapsed.remove(p)
        ws.api.selectedID = f.id
        reveal(f.id)
    }

    private func newCollection() {
        let c = APICollection()
        ws.api.collections.append(c)
        ws.api.selectedID = c.id
    }

    private func remove(_ id: String) {
        if let c = ws.api.collections.first(where: { $0.id == id }) {
            // Its locked values leave the Keychain first; if one can't, nothing is deleted.
            let failed = c.variables.filter { c.secrets.contains($0.id) }.filter { f in
                do { try store.keychain.delete(c.secretAccount(f)); return false } catch { return true }
            }
            guard failed.isEmpty else {
                store.toast(.error, "Couldn't delete “\(c.name)”", detail: "\(failed.map(\.key).joined(separator: ", ")) couldn't be removed from the Keychain. Try again.")
                return
            }
        }
        for r in ws.api.delete(id) + [id] {
            tasks[r]?.cancel()
            responses[r] = nil; errors[r] = nil
        }
    }

    /// A past send: its request if it's still in the list, else a copy of what was sent.
    private func reopen(_ h: APIHistoryItem) {
        if ws.api.request(h.request.id) != nil {
            ws.api.selectedID = h.request.id
            reveal(h.request.id)
        } else {
            var r = h.request
            if let p = r.parentID, !ws.api.isCollection(p), ws.api.folder(p) == nil { r.parentID = nil }
            add(r)
        }
    }

    static let importTypes: [UTType] = [.json, .yaml, .plainText] + ["har", "yml"].compactMap { UTType(filenameExtension: $0) }

    private var curlSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste a curl command").font(Typo.ui(14, .semibold))
            Text("From a browser's Copy as cURL, or any API's docs. It's added to the selected collection or folder.")
                .font(Typo.ui(11.5)).foregroundStyle(Theme.text3)
            TextEditor(text: $curlText)
                .font(Typo.mono(12)).scrollContentBackground(.hidden).padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.input))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.controlStroke))
                .accessibilityLabel("curl command")
            HStack {
                Spacer()
                SubtleButton(title: "Cancel") { pastingCurl = false }.keyboardShortcut(.cancelAction)
                AccentButton(title: "Import") { importCurl() }.keyboardShortcut(.defaultAction)
                    .disabled(curlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16).frame(width: 560, height: 340)
        .background(Theme.sheet)
    }

    private func importCurl() {
        do {
            var result = try APIImport.curl(curlText.trimmingCharacters(in: .whitespacesAndNewlines))
            var target = ws.api.selectedContainer
            // Its sign-in values are locked in a collection; with none chosen, a new one named after the host holds it.
            if !result.lockedVariables.isEmpty, target == nil {
                let host = URLComponents(string: result.requests.first.map { $0.url.contains("://") ? $0.url : "http://" + $0.url } ?? "")?.host
                let c = APICollection(name: host ?? "Imported")
                ws.api.collections.append(c)
                target = c.id
            }
            for i in result.requests.indices { result.requests[i].parentID = target }
            if let target, let c = ws.api.collection(of: target) ?? ws.api.collections.first(where: { $0.id == target }),
               let i = ws.api.collections.firstIndex(where: { $0.id == c.id }) {
                for v in result.lockedVariables {
                    var f = v
                    do {
                        try store.keychain.set(v.value, for: c.secretAccount(v))
                        f.value = ""
                        ws.api.collections[i].secrets.insert(v.id)
                    } catch {
                        result.notes.append("\(v.key) couldn't be locked in the Keychain, so it's kept as a plain value: \(error.localizedDescription)")
                    }
                    ws.api.collections[i].variables.append(f)
                }
            }
            ws.api.add(result)
            if let r = result.requests.first { reveal(r.id) }
            pastingCurl = false
            store.toast(.info, "Imported \(result.requests.first?.name ?? "the request")", detail: result.notes.isEmpty ? nil : result.notes.joined(separator: "\n"))
        } catch {
            store.toast(.error, "Couldn't read the curl command", detail: error.localizedDescription)
        }
    }

    private func copyCurl(_ r: APIRequest) {
        do {
            let req = try APISender.build(r, vars: try variables(for: r), auth: ws.api.auth(for: r).auth)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(APIExport.curl(r, sent: req), forType: .string)
            store.toast(.info, "Copied “\(r.name)” as curl", detail: "Variables are filled in, so it may include a token.")
        } catch {
            store.toast(.error, "Couldn't copy “\(r.name)” as curl", detail: error.localizedDescription)
        }
    }

    private func exportPostman(_ c: APICollection) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = c.name + ".postman_collection.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let (data, emptied) = try APIExport.postman(c, in: ws.api)
            try data.write(to: url, options: .atomic)
            store.toast(.info, "Exported “\(c.name)” for Postman",
                        detail: emptied.isEmpty ? url.path : "Left empty so the file is safe to share: \(emptied.joined(separator: ", ")).")
        } catch {
            store.toast(.error, "Couldn't export “\(c.name)”", detail: error.localizedDescription)
        }
    }

    private func importDropped(_ providers: [NSItemProvider]) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        for p in files {
            _ = p.loadObject(ofClass: URL.self) { url, error in
                Task { @MainActor in
                    if let url { importFiles([url]) } else {
                        store.toast(.error, "Couldn't read the dropped file", detail: error?.localizedDescription)
                    }
                }
            }
        }
        return true
    }

    private func importFiles(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                var result = try APIImport.read(try Data(contentsOf: url), fileName: url.lastPathComponent)
                lockSecrets(&result)
                ws.api.add(result)
                store.toast(.info, "Imported \(result.summary) from \(url.lastPathComponent)",
                            detail: result.notes.isEmpty ? nil : result.notes.joined(separator: "\n"))
            } catch {
                store.toast(.error, "Couldn't import \(url.lastPathComponent)", detail: error.localizedDescription)
            }
        }
    }

    /// Postman's secret environment values, and sign-in secrets lifted into collection
    /// variables, go straight into the Keychain.
    private func lockSecrets(_ r: inout APIImport.Result) {
        for i in r.collections.indices {
            guard let ids = r.secrets[r.collections[i].id] else { continue }
            for j in r.collections[i].variables.indices where ids.contains(r.collections[i].variables[j].id) {
                let f = r.collections[i].variables[j]
                do {
                    try store.keychain.set(f.value, for: r.collections[i].secretAccount(f))
                    r.collections[i].variables[j].value = ""
                    r.collections[i].secrets.insert(f.id)
                } catch {
                    r.notes.append("\(f.key) couldn't be locked in the Keychain, so it's kept as a plain value: \(error.localizedDescription)")
                }
            }
        }
        for i in r.environments.indices {
            guard let ids = r.secrets[r.environments[i].id] else { continue }
            for j in r.environments[i].vars.indices where ids.contains(r.environments[i].vars[j].id) {
                let f = r.environments[i].vars[j]
                do {
                    try store.keychain.set(f.value, for: r.environments[i].secretAccount(f))
                    r.environments[i].vars[j].value = ""
                    r.environments[i].secrets.insert(f.id)
                } catch {
                    r.notes.append("\(f.key) couldn't be locked in the Keychain, so it's kept as a plain value: \(error.localizedDescription)")
                }
            }
        }
    }

    /// The collection's variables, then the chosen environment's on top; a locked value
    /// that can't be read stops the send.
    private func variables(for r: APIRequest) throws -> [String: String] {
        var out: [String: String] = [:]
        func locked(_ v: APIField, _ account: String, _ where_: String) throws -> String {
            guard let value = try store.keychain.get(account) else {
                throw APISender.BuildError(message: "\(v.key) is locked, but this Mac's Keychain has no value for it. Set it again in \(where_).")
            }
            return value
        }
        if let c = ws.api.collection(of: r.id) {
            for v in c.variables where v.on && !v.key.isEmpty {
                out[v.key] = c.secrets.contains(v.id) ? try locked(v, c.secretAccount(v), "the collection's variables") : v.value
            }
        }
        for p in ws.api.ancestors(of: r.id).reversed() {
            for v in ws.api.folder(p)?.variables ?? [] where v.on && !v.key.isEmpty { out[v.key] = v.value }
        }
        guard let env = ws.api.environment else { return out }
        for v in env.vars where v.on && !v.key.isEmpty {
            out[v.key] = env.secrets.contains(v.id) ? try locked(v, env.secretAccount(v), "Edit Environments") : v.value
        }
        return out
    }

    private func send(_ id: String) {
        guard tasks[id] == nil, let r = ws.api.request(id) else { return }
        let req: URLRequest
        do { req = try APISender.build(r, vars: try variables(for: r), auth: ws.api.auth(for: r).auth) } catch {
            errors[id] = error.localizedDescription; responses[id] = nil; return
        }
        errors[id] = nil
        let start = Date()
        tasks[id] = Task {
            defer { tasks[id] = nil }
            do {
                let res = try await APISender.send(req)
                guard ws.api.request(id) != nil else { return }
                responses[id] = res
                ws.api.record(r, status: res.status, ms: res.ms)
            } catch {
                guard ws.api.request(id) != nil else { return }
                responses[id] = nil
                let cancelled = (error as? URLError)?.code == .cancelled || error is CancellationError
                errors[id] = cancelled ? "Cancelled." : error.localizedDescription
                if !cancelled { ws.api.record(r, status: nil, ms: Int(Date().timeIntervalSince(start) * 1000)) }
            }
        }
    }

    // MARK: Look

    static func color(_ method: String) -> Color {
        switch method {
        case "GET": Theme.green
        case "POST": Theme.amber
        case "PUT": Theme.blue
        case "PATCH": Theme.violet
        case "DELETE": Theme.red
        default: Theme.text2
        }
    }

    /// The usual name for a status; macOS's own text calls 200 "no error".
    static func reason(_ s: Int) -> String {
        let names = [200: "OK", 201: "Created", 202: "Accepted", 204: "No Content", 301: "Moved Permanently", 302: "Found",
                     304: "Not Modified", 307: "Temporary Redirect", 308: "Permanent Redirect", 400: "Bad Request", 401: "Unauthorized",
                     403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 410: "Gone", 415: "Unsupported Media Type",
                     422: "Unprocessable Content", 429: "Too Many Requests", 500: "Internal Server Error", 501: "Not Implemented",
                     502: "Bad Gateway", 503: "Service Unavailable", 504: "Gateway Timeout"]
        return names[s] ?? HTTPURLResponse.localizedString(forStatusCode: s).capitalized
    }

    static func short(_ method: String) -> String { method == "DELETE" ? "DEL" : method == "OPTIONS" ? "OPT" : method }

    static func statusColor(_ s: Int) -> Color {
        switch s {
        case 200..<300: Theme.green
        case 300..<400: Theme.blue
        case 400..<500: Theme.amber
        default: Theme.red
        }
    }

    private static func count(_ fields: [APIField]) -> String {
        let n = fields.filter { $0.on && !$0.key.isEmpty }.count
        return n == 0 ? "" : " \(n)"
    }
}

/// Rows of key and value with an on switch, plus a row to add one.
struct APIFieldsEditor: View {
    @Binding var fields: [APIField]
    var keyLabel: String
    var valueLabel = "Value"
    /// Rows whose value is shown hidden and kept elsewhere (environment secrets);
    /// a failure is shown in place of the field, so nothing is typed over a value that couldn't be read.
    var secret: ((APIField) -> Result<Binding<String>, Error>?)? = nil
    var trailing: ((APIField) -> AnyView)? = nil

    private func bind<T>(_ id: String, _ path: WritableKeyPath<APIField, T>, _ fallback: T) -> Binding<T> {
        Binding(get: { fields.first { $0.id == id }?[keyPath: path] ?? fallback },
                set: { v in if let i = fields.firstIndex(where: { $0.id == id }) { fields[i][keyPath: path] = v } })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(fields) { f in
                    HStack(spacing: 6) {
                        Toggle("", isOn: bind(f.id, \.on, true)).toggleStyle(.checkbox).labelsHidden()
                            .accessibilityLabel("Send \(f.key.isEmpty ? keyLabel : f.key)")
                        cell(TextField(keyLabel, text: bind(f.id, \.key, "")), label: keyLabel)
                        if let hidden = secret?(f) {
                            switch hidden {
                            case .success(let value): cell(SecureField(valueLabel, text: value), label: "\(f.key) value")
                            case .failure(let error):
                                Text("Keychain: \(error.localizedDescription)").font(Typo.ui(11)).foregroundStyle(Theme.red).lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading).help(error.localizedDescription)
                            }
                        } else {
                            cell(TextField(valueLabel, text: bind(f.id, \.value, "")), label: "\(f.key) value")
                        }
                        if let trailing { trailing(f) }
                        IconButton(symbol: "xmark", label: "Remove \(f.key.isEmpty ? keyLabel : f.key)", iconSize: 10) {
                            fields.removeAll { $0.id == f.id }
                        }
                    }
                }
                HStack {
                    Button { fields.append(APIField()) } label: {
                        Label("Add \(keyLabel.lowercased())", systemImage: "plus").font(Typo.ui(11.5)).foregroundStyle(Theme.text2)
                    }
                    .buttonStyle(.hand)
                    Spacer()
                }
                .padding(.top, 2)
            }
        }
    }

    private func cell(_ f: some View, label: String) -> some View {
        f.textFieldStyle(.plain).font(Typo.mono(12)).foregroundStyle(Theme.text)
            .padding(.horizontal, 8).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.input))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.controlStroke))
            .accessibilityLabel(label)
    }
}

/// Environments and their variables. Secret values go to the Keychain.
struct APIEnvironmentsEditor: View {
    @Environment(AppStore.self) private var store
    let ws: WorkspaceStore
    @State private var selected: String?

    private var current: String? { ws.api.environments.contains { $0.id == selected } ? selected : ws.api.environments.first?.id }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(ws.api.environments) { e in
                    Button { selected = e.id } label: {
                        Text(e.name).font(Typo.ui(12.5)).foregroundStyle(Theme.text).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .rowBackground(selected: e.id == current)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.hand)
                    .contextMenu { Button("Delete", role: .destructive) { remove(e) } }
                }
                Button {
                    let e = APIEnvironment(name: ws.api.environments.isEmpty ? "Local" : "Environment \(ws.api.environments.count + 1)",
                                           vars: [APIField(key: "baseUrl", value: "http://localhost:3000")])
                    ws.api.environments.append(e)
                    selected = e.id
                    if ws.api.environmentID == nil { ws.api.environmentID = e.id }
                } label: {
                    Label("New environment", systemImage: "plus").font(Typo.ui(11.5)).foregroundStyle(Theme.text2)
                }
                .buttonStyle(.hand).padding(.top, 4)
                Spacer()
            }
            .padding(10).frame(width: 170)
            Rectangle().fill(Theme.divider).frame(width: 1)
            if let id = current, let i = ws.api.environments.firstIndex(where: { $0.id == id }) {
                let env = ws.api.environments[i]
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Name", text: Binding(get: { env.name }, set: { v in rename(id, v) }))
                        .textFieldStyle(.plain).font(Typo.ui(13.5, .semibold)).accessibilityLabel("Environment name")
                    Text("Use a variable as {{name}} in a URL, parameter, header or body. Lock a value to keep it in the Keychain instead of the project's saved layout.")
                        .font(Typo.ui(11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                    APILockedFields(fields: Binding(get: { ws.api.environments.first { $0.id == id }?.vars ?? [] },
                                                    set: { v in if let i = ws.api.environments.firstIndex(where: { $0.id == id }) { ws.api.environments[i].vars = v } }),
                                    secrets: Binding(get: { ws.api.environments.first { $0.id == id }?.secrets ?? [] },
                                                     set: { v in if let i = ws.api.environments.firstIndex(where: { $0.id == id }) { ws.api.environments[i].secrets = v } }),
                                    account: env.secretAccount)
                }
                .padding(12)
            } else {
                EmptyState(symbol: "list.bullet.rectangle", message: "No environments yet.")
            }
        }
        .background(Theme.popover)
    }

    private func rename(_ id: String, _ name: String) {
        if let i = ws.api.environments.firstIndex(where: { $0.id == id }) { ws.api.environments[i].name = name }
    }

    private func remove(_ e: APIEnvironment) {
        let failed = e.vars.filter { e.secrets.contains($0.id) && !forget(e, $0) }
        guard failed.isEmpty else { return }
        ws.api.environments.removeAll { $0.id == e.id }
        if ws.api.environmentID == e.id { ws.api.environmentID = nil }
    }

    @discardableResult
    private func forget(_ env: APIEnvironment, _ f: APIField) -> Bool {
        do { try store.keychain.delete(env.secretAccount(f)); return true } catch {
            store.toast(.error, "Couldn't remove \(f.key) from the Keychain", detail: "It's kept so you can try again. \(error.localizedDescription)")
            return false
        }
    }
}

/// Variable rows whose values can be locked into the Keychain (an environment's or a collection's).
struct APILockedFields: View {
    @Environment(AppStore.self) private var store
    @Binding var fields: [APIField]
    @Binding var secrets: Set<String>
    let account: (APIField) -> String

    var body: some View {
        APIFieldsEditor(fields: rows, keyLabel: "Variable",
                        secret: { f in secrets.contains(f.id) ? value(f) : nil },
                        trailing: { f in AnyView(lockButton(f)) })
    }

    /// Removed rows also drop their Keychain item; one that can't be removed comes back to try again.
    private var rows: Binding<[APIField]> {
        Binding(get: { fields }, set: { v in
            var kept = v
            for f in fields where !v.contains(where: { $0.id == f.id }) && secrets.contains(f.id) && !forget(f) { kept.append(f) }
            fields = kept
            secrets.formIntersection(Set(kept.map(\.id)))
        })
    }

    private func value(_ f: APIField) -> Result<Binding<String>, Error> {
        let account = account(f)
        let current: String
        do { current = try store.keychain.get(account) ?? "" } catch { return .failure(error) }
        return .success(Binding(get: { current }, set: { v in
            do { try store.keychain.set(v, for: account) } catch {
                store.toast(.error, "Couldn't save \(f.key) to the Keychain", detail: error.localizedDescription)
            }
        }))
    }

    private func lockButton(_ f: APIField) -> some View {
        let locked = secrets.contains(f.id)
        return IconButton(symbol: locked ? "lock.fill" : "lock.open", label: locked ? "Keep \(f.key) in the saved file" : "Keep \(f.key) in the Keychain",
                          iconSize: 10, active: locked) { setLocked(f, !locked) }
    }

    /// Moves the value between the saved file and the Keychain; on a Keychain error nothing moves.
    private func setLocked(_ f: APIField, _ lock: Bool) {
        guard let j = fields.firstIndex(where: { $0.id == f.id }) else { return }
        let account = account(f)
        do {
            if lock {
                try store.keychain.set(fields[j].value, for: account)
                fields[j].value = ""
                secrets.insert(f.id)
            } else {
                let value = try store.keychain.get(account) ?? ""
                try store.keychain.delete(account)
                fields[j].value = value
                secrets.remove(f.id)
            }
        } catch {
            store.toast(.error, "Couldn't change where \(f.key) is kept", detail: error.localizedDescription)
        }
    }

    private func forget(_ f: APIField) -> Bool {
        do { try store.keychain.delete(account(f)); return true } catch {
            store.toast(.error, "Couldn't remove \(f.key) from the Keychain", detail: "It's kept so you can try again. \(error.localizedDescription)")
            return false
        }
    }
}

extension AppStore {
    /// A removed project's locked API values: nothing else would ever delete them.
    func forgetAPISecrets(_ id: ProjectID) {
        let api: APIWorkspace
        if let ws = workspaces[id] {
            api = ws.api
        } else {
            do {
                guard let saved = try persistence.load(WorkspaceState.self, from: "workspaces/\(id).json") else { return }
                api = saved.api
            } catch {
                toast(.error, "Couldn't check \(id) for locked API values", detail: "They may stay in the Keychain. \(error.localizedDescription)")
                return
            }
        }
        var failed: [String] = []
        for (name, account) in api.lockedAccounts {
            do { try keychain.delete(account) } catch { failed.append(name) }
        }
        if !failed.isEmpty { toast(.error, "Couldn't remove locked API values from the Keychain", detail: failed.joined(separator: ", ")) }
    }
}
