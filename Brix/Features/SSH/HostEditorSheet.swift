import SwiftUI
import AppKit

/// Add / Edit SSH connection sheet (SSH artboard).
struct HostEditorSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let existing: SSHHost?

    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var user = ""
    @State private var auth: SSHAuth = .key
    @State private var keyPath = "~/.ssh/id_ed25519"
    @State private var password = ""
    @State private var tag: EnvTag = .dev
    @State private var notes = ""
    @State private var projects: Set<ProjectID> = []
    @State private var errors: [String: String] = [:]
    @State private var testState: TestState = .idle
    @State private var loaded = false

    enum TestState: Equatable { case idle, running, ok(String), failed(String) }

    private var hasStoredPassword: Bool {
        existing.map { store.keychain.has(Keychain.hostAccount($0.id)) } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(existing == nil ? "New Connection" : "Edit Connection").font(Typo.ui(15, .semibold)).foregroundStyle(Theme.text)
                Text("Credentials stay in your Keychain. Brix stores only references.").font(Typo.ui(12)).foregroundStyle(Theme.text3)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    BXTextField(label: "Name", text: $name, placeholder: "Development Server", error: errors["name"])
                    HStack(alignment: .top, spacing: 12) {
                        BXTextField(label: "Host", text: $host, placeholder: "dev.example.com", mono: true, error: errors["host"])
                        BXTextField(label: "Port", text: $port, mono: true, error: errors["port"]).frame(width: 110)
                    }
                    BXTextField(label: "User", text: $user, placeholder: "deploy", mono: true, error: errors["user"])
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Authentication").font(Typo.ui(11.5, .medium)).foregroundStyle(Theme.text2)
                        SegmentedControl(options: SSHAuth.allCases.map { ($0, $0.label) }, selection: $auth, height: 26, fill: Theme.input, fontSize: 12)
                        authDetail
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Environment").font(Typo.ui(11.5, .medium)).foregroundStyle(Theme.text2)
                        HStack(spacing: 6) {
                            ForEach([EnvTag.dev, .stage, .prod, .personal], id: \.self) { t in envButton(t) }
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Linked projects").font(Typo.ui(11.5, .medium)).foregroundStyle(Theme.text2)
                        if store.library.projects.isEmpty {
                            Text("No projects yet.").font(Typo.ui(12)).foregroundStyle(Theme.text3)
                        }
                        FlowChips(items: store.sortedProjects.map { ($0.id, $0.name, $0.hue.color) }, selection: $projects)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Notes").font(Typo.ui(11.5, .medium)).foregroundStyle(Theme.text2)
                        TextEditor(text: $notes)
                            .font(Typo.ui(12.5)).scrollContentBackground(.hidden)
                            .padding(6).frame(height: 64)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.input))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.controlStroke))
                            .accessibilityLabel("Notes")
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 16)
            }
            footer
        }
        .frame(width: 520, height: 640)
        .background(Theme.sheet)
        .onAppear(perform: load)
    }

    @ViewBuilder private var authDetail: some View {
        switch auth {
        case .key:
            HStack(spacing: 9) {
                Image(systemName: "key").font(.system(size: 12)).foregroundStyle(Theme.text2)
                TextField("~/.ssh/id_ed25519", text: $keyPath).textFieldStyle(.plain).font(Typo.mono(12)).foregroundStyle(Theme.text)
                    .accessibilityLabel("Key path")
                Text(keyKind + " · reference only").font(Typo.ui(11)).foregroundStyle(Theme.text3)
                Button("Choose…", action: chooseKey).buttonStyle(.plain).font(Typo.ui(11.5)).foregroundStyle(Theme.body)
                    .padding(.horizontal, 9).frame(height: 24).background(RoundedRectangle(cornerRadius: 6).fill(Color.white(0.06)))
            }
            .padding(.horizontal, 10).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.input))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(errors["key"] != nil ? Theme.red : Theme.border))
            if let e = errors["key"] { Text(e).font(Typo.ui(11)).foregroundStyle(Theme.red) }
        case .agent:
            Text("Uses the keys loaded in your SSH agent (ssh-add -l).").font(Typo.ui(12)).foregroundStyle(Theme.text3).frame(height: 34)
        case .password:
            BXTextField(label: "", text: $password, placeholder: hasStoredPassword ? "Stored in Keychain · type to replace" : "Password", secure: true, error: errors["password"])
        }
    }

    private var keyKind: String {
        let n = (keyPath as NSString).lastPathComponent.lowercased()
        if n.contains("ed25519") { return "ED25519" }
        if n.contains("ecdsa") { return "ECDSA" }
        if n.contains("rsa") { return "RSA" }
        return "Key"
    }

    private func envButton(_ t: EnvTag) -> some View {
        let on = tag == t
        return Button { tag = t } label: {
            HStack(spacing: 6) {
                Circle().fill(t.color).frame(width: 6, height: 6)
                Text(t.name).font(Typo.ui(12))
            }
            .foregroundStyle(on ? Theme.text : Theme.text2)
            .padding(.horizontal, 11).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? t.color.opacity(0.12) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? t.color.opacity(0.4) : Theme.controlStroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var footer: some View {
        HStack(spacing: 8) {
            switch testState {
            case .idle: EmptyView()
            case .running: ProgressView().controlSize(.small); Text("Testing…").font(Typo.ui(12)).foregroundStyle(Theme.text3)
            case .ok(let m): Label(m, systemImage: "checkmark.circle.fill").font(Typo.ui(12)).foregroundStyle(Theme.green).lineLimit(1)
            case .failed(let m): Label(m, systemImage: "xmark.octagon.fill").font(Typo.ui(12)).foregroundStyle(Theme.red).lineLimit(2)
            }
            Spacer()
            SubtleButton(title: "Test") { test() }.disabled(testState == .running)
            Button("Cancel") { dismiss() }.buttonStyle(.plain).font(Typo.ui(12.5)).foregroundStyle(Theme.text2).padding(.horizontal, 12)
                .keyboardShortcut(.cancelAction)
            AccentButton(title: "Save") { save() }.keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Color.white(0.02))
        .hairlineTop()
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let h = existing else { return }
        name = h.name; host = h.host; port = "\(h.port)"; user = h.user; auth = h.auth
        keyPath = h.keyPath.isEmpty ? "~/.ssh/id_ed25519" : h.keyPath
        tag = h.tag; notes = h.notes
        projects = Set(store.library.links.projects(for: h.id))
    }

    private func chooseKey() {
        let p = NSOpenPanel()
        p.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
        p.showsHiddenFiles = true
        p.canChooseDirectories = false
        p.message = "Choose a private key. Brix stores only its path."
        if p.runModal() == .OK, let u = p.url {
            let home = NSHomeDirectory()
            keyPath = u.path.hasPrefix(home) ? "~" + u.path.dropFirst(home.count) : u.path
        }
    }

    /// Validates and returns the host being edited, or nil with errors set.
    private func build() -> SSHHost? {
        var e: [String: String] = [:]
        let n = name.trimmingCharacters(in: .whitespaces)
        let hst = host.trimmingCharacters(in: .whitespaces)
        let usr = user.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { e["name"] = "Enter a name" }
        if hst.isEmpty { e["host"] = "Enter a host" } else if hst.contains(" ") || hst.contains("@") { e["host"] = "Host only, without user@ or spaces" }
        if usr.isEmpty { e["user"] = "Enter a user" }
        guard let p = Int(port), (1...65535).contains(p) else {
            e["port"] = "1 to 65535"
            errors = e
            return nil
        }
        if auth == .key {
            let full = (keyPath as NSString).expandingTildeInPath
            if keyPath.isEmpty { e["key"] = "Choose a key file" }
            else if !(existing?.isSample ?? false), !FileManager.default.fileExists(atPath: full) { e["key"] = "No file at \(keyPath)" }
        }
        if auth == .password, password.isEmpty, !hasStoredPassword { e["password"] = "Enter the password" }
        errors = e
        guard e.isEmpty else { return nil }
        var h = existing ?? SSHHost(id: UUID().uuidString, name: n, host: hst, user: usr, tag: tag)
        h.name = n; h.host = hst; h.user = usr; h.port = p; h.auth = auth
        h.keyPath = auth == .key ? keyPath : ""
        h.tag = tag; h.notes = notes
        return h
    }

    private func test() {
        guard let h = build() else { return }
        testState = .running
        let pw = password.isEmpty ? store.hostPassword(h) : password
        Task {
            do {
                let ok = try await store.svc(h).ssh.test(h, password: pw)
                testState = .ok("Reachable · \(ok)")
            } catch {
                testState = .failed(error.localizedDescription)
            }
        }
    }

    private func save() {
        guard let h = build() else { return }
        store.saveHost(h, password: auth == .password && !password.isEmpty ? password : nil)
        if auth != .password, existing?.auth == .password { try? store.keychain.delete(Keychain.hostAccount(h.id)) }
        let before = Set(store.library.links.projects(for: h.id))
        for p in projects.subtracting(before) { store.setLink(p, h.id, kind: .host, linked: true) }
        for p in before.subtracting(projects) { store.setLink(p, h.id, kind: .host, linked: false) }
        store.selectedHost = h.id
        dismiss()
    }
}
