import SwiftUI

struct NewFileSheet: View {
    @Environment(AppStore.self) private var store
    let projectID: ProjectID
    let isDirectory: Bool
    let parent: String

    var body: some View {
        NameSheet(title: isDirectory ? "New Folder" : "New File", message: parent.isEmpty ? "In the project root" : "In \(parent)/",
                  label: "Name", confirm: "Create", value: "",
                  validate: { v in
                      let t = v.trimmingCharacters(in: .whitespaces)
                      if t.isEmpty { return "Enter a name" }
                      if t.contains("..") { return "Names can't contain .." }
                      return nil
                  }) { name in
            guard let p = store.project(projectID) else { return }
            let path = parent.isEmpty ? name : parent + "/" + name
            Task {
                do {
                    try await store.svc(p).files.create(p, path: path, isDirectory: isDirectory)
                    let ws = store.workspace(for: projectID)
                    ws.loadTree()
                    if !isDirectory { ws.open(path) } else { ws.state.expanded.insert(path) }
                    store.toast(.success, "Created \(name)")
                } catch {
                    store.toast(.error, "Couldn't create \(name)", detail: error.localizedDescription)
                }
            }
        }
    }
}

struct RenameFileSheet: View {
    @Environment(AppStore.self) private var store
    let projectID: ProjectID
    let path: String

    var body: some View {
        NameSheet(title: "Rename", message: path, label: "New name", confirm: "Rename", value: (path as NSString).lastPathComponent,
                  validate: { v in
                      let t = v.trimmingCharacters(in: .whitespaces)
                      if t.isEmpty { return "Enter a name" }
                      if t.contains("/") { return "Use a name, not a path" }
                      return nil
                  }) { name in
            guard let p = store.project(projectID) else { return }
            Task {
                do {
                    try await store.svc(p).files.rename(p, from: path, to: name)
                    let ws = store.workspace(for: projectID)
                    let dir = (path as NSString).deletingLastPathComponent
                    let newPath = dir.isEmpty ? name : dir + "/" + name
                    ws.renamed(from: path, to: newPath)
                    ws.loadTree()
                    store.refreshGit(projectID)
                    store.toast(.success, "Renamed to \(name)")
                } catch {
                    store.toast(.error, "Couldn't rename", detail: error.localizedDescription)
                }
            }
        }
    }
}

struct RenameSessionSheet: View {
    @Environment(AppStore.self) private var store
    let sessionID: String
    var body: some View {
        NameSheet(title: "Rename Session", message: "", label: "Name", confirm: "Rename", value: store.session(sessionID)?.title ?? "") { name in
            store.renameSession(sessionID, to: name)
        }
    }
}

struct RenamePanelSheet: View {
    @Environment(AppStore.self) private var store
    let projectID: ProjectID
    let panelID: String
    var body: some View {
        let ws = store.workspace(for: projectID)
        NameSheet(title: "Rename Panel", message: "", label: "Name", confirm: "Rename",
                  value: ws.layout.allPanels.first { $0.id == panelID }?.displayTitle ?? "") { ws.layout.rename(panelID, to: $0) }
    }
}
