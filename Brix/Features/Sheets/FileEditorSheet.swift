import SwiftUI

/// A file Brix edits itself instead of handing it to another app.
enum FileRef: Hashable, Identifiable {
    case local(String)
    case remote(ResourceID, String)
    var id: String {
        switch self {
        case .local(let p): "l:\(p)"
        case .remote(let h, let p): "r:\(h):\(p)"
        }
    }
    var path: String {
        switch self {
        case .local(let p), .remote(_, let p): p
        }
    }
    var name: String { (path as NSString).lastPathComponent }
}

/// Text editor for any file: local (outside a project too) or on an SSH host.
/// ⌘S saves; production hosts ask before writing, and so does a local file
/// that changed on disk since it was opened.
struct FileEditorSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let file: FileRef
    @State private var text = ""
    @State private var original = ""
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?
    /// The file couldn't be read: no editor, and nothing to save over it.
    @State private var loadFailed = false
    /// The remote file's size and time when read; a save checks it first.
    @State private var remoteStamp = ""
    /// A local file's modification date and size when read, to notice outside changes.
    @State private var stamp: DiskStamp?
    @State private var askDiscard = false
    @State private var askOverwrite = false
    @State private var askProduction = false

    struct DiskStamp: Equatable {
        var modified: Date?
        var size: Int?
    }

    private var dirty: Bool { text != original }
    private var host: SSHHost? { if case .remote(let h, _) = file { return store.host(h) }; return nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let host { ServerOSIcon(host: host, size: 18) } else { Image(systemName: "doc.text").foregroundStyle(Theme.text2) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.name + (dirty ? " •" : "")).font(Typo.ui(13, .semibold)).foregroundStyle(Theme.text)
                    Text((host.map { "\($0.name): " } ?? "") + (file.path as NSString).abbreviatingWithTildeInPath)
                        .font(Typo.mono(11)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.head)
                }
                Spacer()
                if let error, !loadFailed { Text(error).font(Typo.ui(11.5)).foregroundStyle(Theme.red).lineLimit(2) }
                SubtleButton(title: dirty ? "Discard" : "Close") { if dirty { askDiscard = true } else { dismiss() } }.keyboardShortcut(.cancelAction)
                AccentButton(title: saving ? "Saving…" : "Save", shortcut: "⌘S", isLoading: saving) { save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!dirty || saving || loading || loadFailed)
            }
            .padding(.horizontal, 16).frame(height: 54).hairlineBottom()
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if loadFailed {
                EmptyState(symbol: "exclamationmark.triangle", message: error ?? "Couldn't open this file.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CodeView(text: text, language: SyntaxLanguage.detect(path: file.path), editable: true, onChange: { text = $0 })
            }
        }
        .frame(minWidth: 900, idealWidth: 1100, minHeight: 600, idealHeight: 760)
        .background(Theme.editor)
        .interactiveDismissDisabled(dirty)
        .task { await load() }
        .alert("Discard changes to \(file.name)?", isPresented: $askDiscard) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Your edits haven't been saved.")
        }
        .alert("\(file.name) changed on disk", isPresented: $askOverwrite) {
            Button("Overwrite", role: .destructive) { write() }
            Button("Reload") { Task { await load() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Something else changed the file since Brix opened it. Overwrite it with your version, or reload it and lose your edits?")
        }
        // Asked from the sheet itself: the window's alert may not show over a sheet.
        .alert("Save \(file.name) on \(host?.name ?? "")?", isPresented: $askProduction) {
            Button("Save to Production", role: .destructive) { write() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(host?.name ?? "") is tagged Production. This overwrites the file on the server.")
        }
    }

    private func load() async {
        loading = true
        loadFailed = false
        error = nil
        do {
            switch file {
            case .local(let p):
                let url = Self.resolved(p)
                let data = try Data(contentsOf: url)
                guard data.count <= 5_000_000, !data.contains(0), let s = String(data: data, encoding: .utf8) else {
                    throw ServiceError("Brix edits text files up to 5 MB.")
                }
                stamp = Self.stamp(url)
                text = s
            case .remote(let hid, let p):
                guard let h = store.host(hid) else { throw ServiceError("Host not found") }
                guard !h.isSample else { throw ServiceError("Sample servers have no real files to open.") }
                (text, remoteStamp) = try await RemoteFiles.readText(h, password: store.hostPassword(h), p)
            }
            original = text
        } catch {
            self.error = error.localizedDescription
            loadFailed = true
        }
        loading = false
    }

    private func save() {
        guard !loadFailed else { return }
        if case .local(let p) = file, Self.stamp(Self.resolved(p)) != stamp {
            askOverwrite = true
        } else if let host, host.tag.isProduction {
            askProduction = true
        } else {
            write()
        }
    }

    private func write() {
        // What's written is what becomes clean: keys typed during a slow save stay dirty.
        let written = text
        saving = true
        error = nil
        Task {
            do {
                var warning: String?
                switch file {
                case .local(let p):
                    let url = Self.resolved(p)
                    warning = try Self.writeKeepingMode(written, to: url)
                    stamp = Self.stamp(url)
                case .remote(let hid, let p):
                    guard let h = store.host(hid) else { throw ServiceError("Host not found") }
                    remoteStamp = try await RemoteFiles.writeText(h, password: store.hostPassword(h), p, text: written, stamp: remoteStamp)
                }
                original = written
                if let warning { store.toast(.error, "Saved \(file.name), but its permissions changed", detail: warning) }
                else { store.toast(.success, "Saved \(file.name)") }
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }

    /// The file itself, through any symlinks, so saving updates the target
    /// instead of replacing the link with a plain file.
    static func resolved(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath()
    }

    static func stamp(_ url: URL) -> DiskStamp? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return DiskStamp(modified: a[.modificationDate] as? Date, size: (a[.size] as? NSNumber)?.intValue)
    }

    /// Atomic write that keeps the file's permissions (an executable script stays executable).
    /// Throws when nothing was written; the text was written when it returns, with a
    /// note if the permissions couldn't be put back.
    @discardableResult
    static func writeKeepingMode(_ text: String, to url: URL) throws -> String? {
        let fm = FileManager.default
        // An atomic write replaces the file, so it would get past a read-only one.
        if fm.fileExists(atPath: url.path), !fm.isWritableFile(atPath: url.path) {
            throw ServiceError("\(url.lastPathComponent) is read-only.")
        }
        let mode = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions]
        try Data(text.utf8).write(to: url, options: .atomic)
        guard let mode else { return nil }
        do { try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path) } catch {
            return "Its permissions couldn't be restored: \(error.localizedDescription)"
        }
        return nil
    }
}
