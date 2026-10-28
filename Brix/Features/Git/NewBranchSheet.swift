import SwiftUI

/// Small single-field sheet used for names (branch, preset, file, session).
struct NameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let message: String
    let label: String
    let confirm: String
    @State var value: String
    var validate: (String) -> String? = { $0.trimmingCharacters(in: .whitespaces).isEmpty ? "Enter a name" : nil }
    let onSave: (String) -> Void
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(Typo.pageTitle).foregroundStyle(Theme.text)
            if !message.isEmpty { Text(message).font(Typo.ui(12)).foregroundStyle(Theme.text3) }
            BXTextField(label: label, text: $value, mono: true, error: error)
                .onSubmit(save)
            HStack {
                Spacer()
                SubtleButton(title: "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                AccentButton(title: confirm) { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 420)
        .background(Theme.sheet)
    }

    private func save() {
        if let e = validate(value) { error = e; return }
        onSave(value.trimmingCharacters(in: .whitespaces))
        dismiss()
    }
}

struct NewBranchSheet: View {
    @Environment(AppStore.self) private var store
    let projectID: ProjectID
    var body: some View {
        NameSheet(title: "New Branch", message: "Creates the branch from \(store.git[projectID]?.branch ?? "HEAD") and switches to it.",
                  label: "Branch name", confirm: "Create", value: "feat/",
                  validate: { v in
                      let t = v.trimmingCharacters(in: .whitespaces)
                      if t.isEmpty || t.hasSuffix("/") { return "Enter a branch name" }
                      if t.contains(" ") { return "Branch names can't contain spaces" }
                      if store.git[projectID]?.branches.contains(where: { $0.name == t }) == true { return "That branch already exists" }
                      return nil
                  }) { store.createBranch(projectID, name: $0) }
    }
}
