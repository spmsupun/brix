import SwiftUI

/// Review hosts and databases found in JetBrains IDEs, VS Code and ~/.ssh/config,
/// then import the ticked ones. Nothing connects; passwords found in VS Code
/// settings go to the Keychain.
struct ImportSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var found: [ImportCandidate]?
    @State private var picked: Set<String> = []
    @State private var tags: [String: EnvTag] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import Connections").font(Typo.pageTitle).foregroundStyle(Theme.text)
                Text("From JetBrains IDEs (SSH configs, .idea data sources), VS Code and Cursor (SQLTools, Remote-SSH) and ~/.ssh/config. Read only: nothing connects.")
                    .font(Typo.ui(12)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            }
            Group {
                if let found {
                    if found.isEmpty {
                        EmptyState(symbol: "tray", message: "Nothing to import was found.")
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                section("SSH HOSTS", found.filter { if case .host = $0.item { return true }; return false })
                                section("DATABASES", found.filter { if case .database = $0.item { return true }; return false })
                            }
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 380)
            Text("Tags are guessed from names: anything mentioning prod is Production, which opens read-only and asks before connecting. Passwords saved in JetBrains stay in its own storage; enter them on first connect.")
                .font(Typo.ui(11.5)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(allPicked ? "Select None" : "Select All") { picked = allPicked ? [] : Set(importable.map(\.id)) }
                    .buttonStyle(.hand).font(Typo.ui(12)).foregroundStyle(Theme.text2)
                    .disabled(importable.isEmpty)
                Spacer()
                SubtleButton(title: "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                AccentButton(title: picked.isEmpty ? "Import" : "Import \(picked.count)") {
                    store.importConnections((found ?? []).filter { picked.contains($0.id) }, tags: tags, all: found ?? [])
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 640)
        .background(Theme.sheet)
        .task {
            let folders = store.library.projects.filter { !$0.isSample }.map(\.url)
            let result = await Task.detached { ConfigImporter.scan(projectFolders: folders) }.value
            found = result
            picked = Set(result.filter { !store.alreadyImported($0) }.map(\.id))
        }
    }

    private var importable: [ImportCandidate] { (found ?? []).filter { !store.alreadyImported($0) } }
    private var allPicked: Bool { !importable.isEmpty && importable.allSatisfy { picked.contains($0.id) } }

    @ViewBuilder private func section(_ title: String, _ items: [ImportCandidate]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typo.sectionTitle).tracking(0.6).foregroundStyle(Theme.text3).padding(.horizontal, 6).padding(.bottom, 4)
                ForEach(items) { row($0) }
            }
        }
    }

    private func row(_ c: ImportCandidate) -> some View {
        let exists = store.alreadyImported(c)
        let badge: (String, Color) = {
            switch c.item {
            case .host: return ("SSH", Theme.blue)
            case .database(let d, _, _): return (d.kind.badge, d.kind.color)
            }
        }()
        let (name, detail, tag): (String, String, EnvTag) = {
            switch c.item {
            case .host(let h):
                return (h.name, h.address + (h.auth == .password ? " · password" : ""), h.tag)
            case .database(let d, let pw, let tunnel):
                let extra = (d.user.isEmpty ? "" : " · \(d.user)") + (tunnel != nil ? " · via SSH" : "") + (pw != nil ? " · password to Keychain" : "")
                return (d.name, "\(d.kind.label) · \(d.endpoint)" + extra, d.tag)
            }
        }()
        let current = tags[c.id] ?? tag
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { picked.contains(c.id) }, set: { v in if v { picked.insert(c.id) } else { picked.remove(c.id) } }))
                .toggleStyle(.checkbox).labelsHidden().disabled(exists)
            KindBadge(text: badge.0, color: badge.1, tint: badge.1.opacity(0.12), size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(Typo.row).foregroundStyle(exists ? Theme.text3 : Theme.text).lineLimit(1)
                Text(detail).font(Typo.mono(10.5)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(exists ? "Already in Brix" : c.source).font(Typo.ui(11)).foregroundStyle(Theme.meta).lineLimit(1)
                .frame(maxWidth: 170, alignment: .trailing)
            Menu {
                ForEach(EnvTag.allCases) { t in Button(t.name) { tags[c.id] = t } }
            } label: {
                TagPill(tag: current, size: 8.5)
            }
            .menuStyle(.borderlessButton).fixedSize().disabled(exists)
        }
        .padding(.horizontal, 6).rowHeight(40)
        .rowBackground(selected: false)
    }
}

extension AppStore {
    func alreadyImported(_ c: ImportCandidate) -> Bool {
        switch c.item {
        case .host(let h): library.hosts.contains { $0.host == h.host && $0.port == h.port && $0.user == h.user }
        case .database(let d, _, _): library.databases.contains { $0.kind == d.kind && $0.endpoint == d.endpoint && $0.user == d.user }
        }
    }

    /// `all` lets a database tunnel through a host that was already in Brix.
    func importConnections(_ items: [ImportCandidate], tags: [String: EnvTag], all: [ImportCandidate] = []) {
        var hostByRef: [String: ResourceID] = [:]
        var hosts = 0, dbs = 0
        var failed: [String] = []
        for c in items {
            guard case .host(var h) = c.item else { continue }
            h.tag = tags[c.id] ?? h.tag
            library.hosts.append(h)
            hostStatus[h.id] = .disconnected
            if let ref = c.ref { hostByRef[ref] = h.id }
            hosts += 1
        }
        for c in all {
            guard let ref = c.ref, hostByRef[ref] == nil, case .host(let h) = c.item,
                  let existing = library.hosts.first(where: { $0.host == h.host && $0.port == h.port && $0.user == h.user }) else { continue }
            hostByRef[ref] = existing.id
        }
        for c in items {
            guard case .database(var d, let password, let tunnel) = c.item else { continue }
            d.tag = tags[c.id] ?? d.tag
            // Tunnel through the JetBrains SSH config it named, if that host came along.
            d.tunnelHostID = tunnel.flatMap { hostByRef[$0] }
            if let password {
                do { try keychain.set(password, for: Keychain.dbAccount(d.id)) } catch { failed.append(d.name) }
            }
            library.databases.append(d)
            dbStatus[d.id] = .disconnected
            dbs += 1
        }
        let parts = [hosts > 0 ? "\(hosts) host\(hosts == 1 ? "" : "s")" : nil, dbs > 0 ? "\(dbs) database\(dbs == 1 ? "" : "s")" : nil].compactMap { $0 }
        toast(.success, "Imported \(parts.joined(separator: " and "))", detail: "Link them to projects in Project Settings → Resources.")
        if !failed.isEmpty {
            toast(.error, "Couldn't store passwords in the Keychain", detail: failed.joined(separator: ", ") + ". Enter them when you connect.")
        }
    }
}
