import SwiftUI

/// Save a container or compose service as a Docker target and link it.
struct AddDockerSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<ResourceID> = []
    @State private var manualName = ""
    @State private var manualImage = ""
    @State private var hostID: ResourceID?
    @State private var project: ProjectID?
    @State private var loading = false
    @State private var error: String?

    private var discovered: [DockerTarget] {
        store.allDocker.filter { c in !store.library.docker.contains { $0.id == c.id } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Docker Target").font(Typo.pageTitle).foregroundStyle(Theme.text)
            Text("Pick containers Brix found, or add one by name. Remote containers run on a saved SSH host.").font(Typo.ui(12)).foregroundStyle(Theme.text3)
            HStack {
                SectionTitle(text: "Found", color: Theme.text3)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button("Scan again") { scan() }.buttonStyle(.plain).font(Typo.ui(11.5)).foregroundStyle(Theme.text2)
            }
            if discovered.isEmpty {
                Text(store.dockerError ?? "Nothing new found.").font(Typo.ui(12)).foregroundStyle(Theme.text3).lineLimit(3)
            } else {
                FlowChips(items: discovered.map { ($0.id, "\($0.name)  \($0.hostID.flatMap(store.host)?.name ?? "local")", $0.state.color) }, selection: $picked)
            }
            Divider()
            SectionTitle(text: "Or add by name", color: Theme.text3)
            HStack(alignment: .top, spacing: 10) {
                BXTextField(label: "Container name", text: $manualName, placeholder: "atlas-api-1", mono: true, error: error)
                BXTextField(label: "Image (optional)", text: $manualImage, placeholder: "ghcr.io/acme/api:main", mono: true)
            }
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Runs on").font(Typo.ui(11.5, .medium)).foregroundStyle(Theme.text2)
                    Picker("", selection: $hostID) {
                        Text("This Mac").tag(ResourceID?.none)
                        ForEach(store.library.hosts) { h in Text(h.name).tag(ResourceID?.some(h.id)) }
                    }
                    .labelsHidden().frame(width: 200)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Link to project").font(Typo.ui(11.5, .medium)).foregroundStyle(Theme.text2)
                    Picker("", selection: $project) {
                        Text("None").tag(ProjectID?.none)
                        ForEach(store.sortedProjects) { p in Text(p.name).tag(ProjectID?.some(p.id)) }
                    }
                    .labelsHidden().frame(width: 200)
                }
            }
            HStack {
                Spacer()
                SubtleButton(title: "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                AccentButton(title: "Add") { add() }.keyboardShortcut(.defaultAction)
                    .disabled(picked.isEmpty && manualName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 560)
        .background(Theme.sheet)
        .task { scan() }
    }

    private func scan() {
        loading = true
        Task { await store.refreshDocker(); loading = false }
    }

    private func add() {
        let name = manualName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty {
            guard name.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil else {
                error = "Letters, digits, dot, dash and underscore only"
                return
            }
            let t = DockerTarget(id: "\(hostID ?? "local")/\(name)", name: name, image: manualImage.ifEmpty("unknown"), ports: "", hostID: hostID, state: .exited, startedAt: nil)
            store.addDockerTarget(t, project: project)
        }
        for id in picked {
            if let t = store.discoveredDocker.first(where: { $0.id == id }) { store.addDockerTarget(t, project: project) }
        }
        dismiss()
    }
}
