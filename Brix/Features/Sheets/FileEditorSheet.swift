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
/// ⌘S saves; production hosts ask before writing.
struct FileEditorSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let file: FileRef
    @State private var text = ""
    @State private var original = ""
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?

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
                if let error { Text(error).font(Typo.ui(11.5)).foregroundStyle(Theme.red).lineLimit(2) }
                SubtleButton(title: dirty ? "Discard" : "Close") { dismiss() }.keyboardShortcut(.cancelAction)
                AccentButton(title: saving ? "Saving…" : "Save", shortcut: "⌘S", isLoading: saving) { save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!dirty || saving || loading)
            }
            .padding(.horizontal, 16).frame(height: 54).hairlineBottom()
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CodeView(text: text, language: SyntaxLanguage.detect(path: file.path), editable: true, onChange: { text = $0 })
            }
        }
        .frame(minWidth: 900, idealWidth: 1100, minHeight: 600, idealHeight: 760)
        .background(Theme.editor)
        .task { await load() }
    }

    private func load() async {
        loading = true
        do {
            switch file {
            case .local(let p):
                let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
                let data = try Data(contentsOf: url)
                guard data.count <= 5_000_000, !data.contains(0), let s = String(data: data, encoding: .utf8) else {
                    throw ServiceError("Brix edits text files up to 5 MB.")
                }
                text = s
            case .remote(let hid, let p):
                guard let h = store.host(hid) else { throw ServiceError("Host not found") }
                text = try await RemoteFiles.readText(h, password: store.hostPassword(h), p)
            }
            original = text
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func save() {
        let write = {
            saving = true
            error = nil
            Task {
                do {
                    switch file {
                    case .local(let p):
                        try text.write(to: URL(fileURLWithPath: (p as NSString).expandingTildeInPath), atomically: true, encoding: .utf8)
                    case .remote(let hid, let p):
                        guard let h = store.host(hid) else { throw ServiceError("Host not found") }
                        try await RemoteFiles.writeText(h, password: store.hostPassword(h), p, text: text)
                    }
                    original = text
                    store.toast(.success, "Saved \(file.name)")
                } catch {
                    self.error = error.localizedDescription
                }
                saving = false
            }
        }
        if let host, host.tag.isProduction {
            store.confirm("Save \(file.name) on \(host.name)?", "\(host.name) is tagged Production. This overwrites the file on the server.", confirm: "Save to Production", action: write)
        } else {
            write()
        }
    }
}
