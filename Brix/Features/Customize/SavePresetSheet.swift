import SwiftUI

struct SavePresetSheet: View {
    @Environment(AppStore.self) private var store
    let projectID: ProjectID?
    var body: some View {
        NameSheet(title: "Save Layout as Preset", message: "Stores the current arrangement of panels, dock sizes and centre mode.",
                  label: "Preset name", confirm: "Save", value: "",
                  validate: { v in
                      let t = v.trimmingCharacters(in: .whitespaces)
                      if t.isEmpty { return "Enter a name" }
                      if BuiltinPreset.allCases.contains(where: { $0.label.lowercased() == t.lowercased() }) || store.library.customPresets.contains(where: { $0.name.lowercased() == t.lowercased() }) {
                          return "A preset with that name exists"
                      }
                      return nil
                  }) { name in
            if let projectID {
                store.workspace(for: projectID).saveAsPreset(name: name)
            } else {
                store.saveDefaultLayoutAsPreset(name: name)
            }
        }
    }
}
