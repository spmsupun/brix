import SwiftUI
import UniformTypeIdentifiers

/// File explorer for an SSH host: browse, open text files in Brix, download,
/// upload (button or drop files from Finder), new folder, rename, duplicate, delete.
/// Writes on a production host always ask first.
struct RemoteFilesView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.inTile) private var inTile
    @Environment(\.accent) private var accent
    let hostID: ResourceID
    @State private var path = "~"
    @State private var typedPath = ""
    @State private var entries: [RemoteEntry] = []
    @State private var selected: String?
    @State private var loading = false
    @State private var busy: String?
    @State private var error: String?
    @State private var dropTargeted = false
    @State private var history: [String] = []

    private var host: SSHHost? { store.host(hostID) }

    var body: some View {
        if let h = host {
            VStack(spacing: 0) {
                toolbar(h)
                content(h)
                footer
            }
            .modifier(TileOrIsland(fill: Theme.pane))
            .task(id: hostID) {
                path = store.remoteFilesPath[hostID] ?? "~"
                await load(h, path)
            }
        } else {
            EmptyState(symbol: "questionmark.folder", message: "This host was removed.").island()
        }
    }

    // MARK: Toolbar

    private func toolbar(_ h: SSHHost) -> some View {
        HStack(spacing: 6) {
            ServerOSIcon(host: h, size: 20)
            if !inTile {
                Text(h.name).font(Typo.ui(13, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                if h.tag.isProduction { TagPill(tag: h.tag, size: 8.5) }
            }
            IconButton(symbol: "chevron.left", label: "Back", size: 26, iconSize: 11) { back(h) }.disabled(history.isEmpty)
            IconButton(symbol: "arrow.up", label: "Enclosing folder", size: 26, iconSize: 11) { go(h, RemoteFiles.parent(path)) }.disabled(path == "/")
            IconButton(symbol: "house", label: "Home folder", size: 26, iconSize: 11) { go(h, "~") }
            TextField("Path", text: $typedPath)
                .textFieldStyle(.plain).font(Typo.mono(11.5)).foregroundStyle(Theme.text)
                .padding(.horizontal, 8).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.input))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.controlStroke))
                .onSubmit { go(h, typedPath.trimmingCharacters(in: .whitespaces)) }
                .accessibilityLabel("Remote path")
            IconButton(symbol: "arrow.clockwise", label: "Refresh", size: 26, iconSize: 11) { Task { await load(h, path) } }
            IconButton(symbol: "folder.badge.plus", label: "New Folder", size: 26, iconSize: 12) { newFolder(h) }
            IconButton(symbol: "square.and.arrow.up", label: "Upload Files…", size: 26, iconSize: 12) { chooseUpload(h) }
            IconButton(symbol: "square.and.arrow.down", label: "Download", size: 26, iconSize: 12) {
                if let e = entries.first(where: { $0.name == selected }) { download(h, e) }
            }
            .disabled(selected == nil)
            IconButton(symbol: "terminal", label: "Open a terminal here", size: 26, iconSize: 12) {
                store.openServerShell(hostID, project: store.currentProjectID, cwd: path)
            }
        }
        .padding(.horizontal, 10).frame(height: 44).hairlineBottom()
    }

    // MARK: List

    @ViewBuilder private func content(_ h: SSHHost) -> some View {
        Group {
            if loading && entries.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error, entries.isEmpty {
                EmptyState(symbol: "exclamationmark.triangle", message: error, actionTitle: "Retry") { Task { await load(h, path) } }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        HStack(spacing: 10) {
                            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                            Text("Size").frame(width: 72, alignment: .trailing)
                            Text("Modified").frame(width: 120, alignment: .leading)
                            Text("Mode").frame(width: 44, alignment: .leading)
                        }
                        .font(Typo.ui(10.5, .semibold)).foregroundStyle(Theme.text3)
                        .padding(.horizontal, 12).rowHeight(26)
                        if entries.isEmpty {
                            Text("This folder is empty. Drop files here to upload.").font(Typo.ui(12)).foregroundStyle(Theme.text3).padding(20)
                        }
                        ForEach(entries) { e in row(h, e) }
                    }
                    .padding(.horizontal, 4).padding(.bottom, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8).strokeBorder(accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .background(RoundedRectangle(cornerRadius: 8).fill(accent.opacity(0.08)))
                    .overlay(Text("Upload to \(path)").font(Typo.ui(12, .semibold)).foregroundStyle(accent)
                        .padding(.horizontal, 10).frame(height: 24).background(Capsule().fill(Theme.popover)))
                    .padding(6).allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task { await uploadDropped(h, providers) }
            return true
        }
    }

    private func row(_ h: SSHHost, _ e: RemoteEntry) -> some View {
        let on = selected == e.name
        let full = RemoteFiles.join(path, e.name)
        return HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: e.isDirectory ? "folder.fill" : (e.isLink ? "arrow.up.right.square" : "doc"))
                    .font(.system(size: 12)).foregroundStyle(e.isDirectory ? Theme.blue : Theme.text3).frame(width: 16)
                Text(e.name).font(Typo.ui(12.5)).foregroundStyle(e.name.hasPrefix(".") ? Theme.text3 : Theme.text).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(e.isDirectory ? "–" : ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file))
                .font(Typo.ui(11.5)).monospacedDigit().foregroundStyle(Theme.text3).frame(width: 72, alignment: .trailing)
            Text(e.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "–")
                .font(Typo.ui(11.5)).foregroundStyle(Theme.text3).lineLimit(1).frame(width: 120, alignment: .leading)
            Text(e.mode == "0" ? "" : e.mode).font(Typo.mono(10.5)).foregroundStyle(Theme.meta).frame(width: 44, alignment: .leading)
        }
        .padding(.horizontal, 8).rowHeight(28)
        .rowBackground(selected: on, radius: 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(h, e) }
        .simultaneousGesture(TapGesture().onEnded { selected = e.name })
        .contextMenu {
            Button(e.isDirectory ? "Open" : "Edit in Brix") { open(h, e) }
            Button("Download…") { download(h, e) }
            Button("Copy Path") { store.copyToPasteboard(full, label: "path") }
            Divider()
            Button("Rename…") { rename(h, e) }
            Button("Duplicate") { duplicate(h, e) }
            Divider()
            Button("Delete…", role: .destructive) { delete(h, e) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(e.isDirectory ? "Folder" : "File") \(e.name)")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let busy {
                ProgressView().controlSize(.small)
                Text(busy).lineLimit(1)
            } else if let error, !entries.isEmpty {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.amber)
                Text(error).lineLimit(1)
            } else {
                Text("\(entries.count) item\(entries.count == 1 ? "" : "s")")
            }
            Spacer()
            Text("Drop files here to upload").foregroundStyle(Theme.meta)
        }
        .font(Typo.ui(11)).foregroundStyle(Theme.text3)
        .padding(.horizontal, 12).frame(height: 28).hairlineTop()
    }

    // MARK: Actions

    private func load(_ h: SSHHost, _ p: String) async {
        loading = true
        do {
            let r = try await RemoteFiles.list(h, password: store.hostPassword(h), path: p)
            path = r.path
            typedPath = r.path
            entries = r.entries
            error = nil
            store.remoteFilesPath[hostID] = r.path
            if store.hostStatus[h.id] != .connected { store.hostStatus[h.id] = .connected }
            if h.os.isEmpty, let m = try? await store.svc(h).metrics.metrics(h) { store.rememberOS(h.id, m.os) }
        } catch {
            self.error = error.localizedDescription
            typedPath = path
        }
        loading = false
    }

    private func go(_ h: SSHHost, _ p: String) {
        guard !p.isEmpty, p != path else { return }
        history.append(path)
        selected = nil
        Task { await load(h, p) }
    }

    private func back(_ h: SSHHost) {
        guard let p = history.popLast() else { return }
        Task { await load(h, p) }
    }

    private func open(_ h: SSHHost, _ e: RemoteEntry) {
        let full = RemoteFiles.join(path, e.name)
        if e.isDirectory || e.isLink && !e.name.contains(".") {
            go(h, full)
        } else {
            store.sheet = .editFile(.remote(hostID, full))
        }
    }

    /// Runs a write after a production confirmation when needed, then reloads.
    private func write(_ h: SSHHost, _ title: String, _ message: String, label: String, _ op: @escaping () async throws -> Void) {
        if h.tag.isProduction {
            store.confirm(title, message + " \(h.name) is tagged Production.", confirm: "Run on Production") { perform(h, label, op) }
        } else {
            perform(h, label, op)
        }
    }

    private func perform(_ h: SSHHost, _ label: String, _ op: @escaping () async throws -> Void) {
        busy = label
        Task {
            do {
                try await op()
                error = nil
            } catch {
                store.toast(.error, "\(label) failed", detail: error.localizedDescription)
            }
            busy = nil
            await load(h, path)
        }
    }

    private func newFolder(_ h: SSHHost) {
        guard let name = prompt("New folder in \(path)", "Folder name", "") else { return }
        write(h, "Create \(name) on \(h.name)?", "Makes a folder in \(path).", label: "Creating \(name)") {
            try await RemoteFiles.mkdir(h, password: store.hostPassword(h), RemoteFiles.join(path, name))
        }
    }

    private func rename(_ h: SSHHost, _ e: RemoteEntry) {
        guard let name = prompt("Rename \(e.name)", "New name", e.name), name != e.name else { return }
        write(h, "Rename \(e.name) on \(h.name)?", "Renames it to \(name).", label: "Renaming") {
            try await RemoteFiles.rename(h, password: store.hostPassword(h), from: RemoteFiles.join(path, e.name), to: RemoteFiles.join(path, name))
        }
    }

    private func duplicate(_ h: SSHHost, _ e: RemoteEntry) {
        let ext = (e.name as NSString).pathExtension
        let base = ext.isEmpty || e.isDirectory ? e.name : (e.name as NSString).deletingPathExtension
        let copyName = base + " copy" + (ext.isEmpty || e.isDirectory ? "" : ".\(ext)")
        write(h, "Duplicate \(e.name) on \(h.name)?", "Copies it to \(copyName).", label: "Copying \(e.name)") {
            try await RemoteFiles.copy(h, password: store.hostPassword(h), from: RemoteFiles.join(path, e.name), to: RemoteFiles.join(path, copyName))
        }
    }

    private func delete(_ h: SSHHost, _ e: RemoteEntry) {
        let full = RemoteFiles.join(path, e.name)
        let run = {
            busy = "Deleting \(e.name)"
            Task {
                do { try await RemoteFiles.delete(h, password: store.hostPassword(h), full) } catch {
                    store.toast(.error, "Couldn't delete \(e.name)", detail: error.localizedDescription)
                }
                busy = nil
                selected = nil
                await load(h, path)
            }
        }
        // Deleting always asks, and names production explicitly.
        store.confirm("Delete \(e.name) on \(h.name)?",
                      "\(full) is deleted from the server\(e.isDirectory ? " with everything in it" : ""). This can't be undone.\(h.tag.isProduction ? " \(h.name) is tagged Production." : "")",
                      confirm: h.tag.isProduction ? "Delete on Production" : "Delete", action: run)
    }

    private func download(_ h: SSHHost, _ e: RemoteEntry) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = e.name
        panel.message = "Download \(e.name) from \(h.name)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = "Downloading \(e.name)"
        Task {
            do {
                try await RemoteFiles.download(h, password: store.hostPassword(h), remote: RemoteFiles.join(path, e.name), to: url, recursive: e.isDirectory)
                store.toast(.success, "Downloaded \(e.name)", detail: url.path)
            } catch {
                store.toast(.error, "Download failed", detail: error.localizedDescription)
            }
            busy = nil
        }
    }

    private func chooseUpload(_ h: SSHHost) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Upload to \(h.name):\(path)"
        guard panel.runModal() == .OK else { return }
        upload(h, panel.urls)
    }

    private func uploadDropped(_ h: SSHHost, _ providers: [NSItemProvider]) async {
        var urls: [URL] = []
        for p in providers {
            if let url = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL { urls.append(url) }
            else if let data = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                    let url = URL(dataRepresentation: data, relativeTo: nil) { urls.append(url) }
        }
        if !urls.isEmpty { upload(h, urls) }
    }

    private func upload(_ h: SSHHost, _ urls: [URL]) {
        let names = urls.map(\.lastPathComponent)
        let clash = names.filter { n in entries.contains { $0.name == n } }
        let what = names.count == 1 ? names[0] : "\(names.count) items"
        let message = "Uploads to \(path)." + (clash.isEmpty ? "" : " Replaces \(clash.joined(separator: ", ")).")
        let op = {
            for u in urls { try await RemoteFiles.upload(h, password: store.hostPassword(h), local: u, toDirectory: path) }
            store.toast(.success, "Uploaded \(what)", detail: "\(h.name):\(path)")
        }
        if clash.isEmpty && !h.tag.isProduction {
            perform(h, "Uploading \(what)", op)
        } else {
            store.confirm("Upload \(what) to \(h.name)?", message + (h.tag.isProduction ? " \(h.name) is tagged Production." : ""),
                          confirm: h.tag.isProduction ? "Upload to Production" : "Replace") { perform(h, "Uploading \(what)", op) }
        }
    }

    private func prompt(_ title: String, _ label: String, _ value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        field.placeholderString = label
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let v = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, !v.contains("/") else { return nil }
        return v
    }
}
