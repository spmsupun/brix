import SwiftUI
import AppKit

/// Pick a folder, show what was detected, choose options, add.
struct AddProjectSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var url: URL?
    @State private var detected: AppStore.DetectedProject?
    @State private var error: String?
    @State private var name = ""
    @State private var hue: ProjectHue = .violet
    @State private var pinned = false
    @State private var preset: BuiltinPreset = .code
    @State private var hosts: Set<ResourceID> = []
    @State private var dbs: Set<ResourceID> = []
    @State private var docker: Set<ResourceID> = []
    @State private var openAfter = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Add Project").font(Typo.pageTitle).foregroundStyle(Theme.text)
                Spacer()
            }
            .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    folderRow
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").font(Typo.ui(12)).foregroundStyle(Theme.red)
                    }
                    if let d = detected { details(d) }
                }
                .padding(.horizontal, 22).padding(.bottom, 16)
            }
            HStack {
                Toggle("Open after adding", isOn: $openAfter).toggleStyle(.checkbox).font(Typo.ui(12)).foregroundStyle(Theme.text2)
                Spacer()
                SubtleButton(title: "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                AccentButton(title: "Add Project") { add() }
                    .disabled(detected == nil || error != nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
            .hairlineTop()
        }
        .frame(width: 600, height: detected == nil ? 260 : 640)
        .background(Theme.sheet)
    }

    private var folderRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder").font(.system(size: 15)).foregroundStyle(Theme.text2)
                .frame(width: 34, height: 34).background(RoundedRectangle(cornerRadius: 8).fill(Color.white(0.05)))
            VStack(alignment: .leading, spacing: 2) {
                Text(url?.lastPathComponent ?? "No folder chosen").font(Typo.ui(13, .semibold)).foregroundStyle(Theme.text)
                // A path cuts in the middle; the hint wraps instead.
                Text(url?.path ?? "Use a folder you have, or make a new one.").font(Typo.mono(11)).foregroundStyle(Theme.text3)
                    .lineLimit(url == nil ? 2 : 1).truncationMode(.middle).fixedSize(horizontal: false, vertical: url == nil)
            }
            Spacer()
            SubtleButton(title: "New Folder…") { create() }
            SubtleButton(title: url == nil ? "Choose Folder…" : "Change…") { choose() }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.input))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
    }

    private func details(_ d: AppStore.DetectedProject) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: "Detected", color: Theme.text3)
                HStack(spacing: 18) {
                    fact("Language", d.language)
                    fact("Framework", d.framework)
                    fact("Git", d.isGitRepo ? "⎇ \(d.branch)" : "Not a repository")
                }
            }
            HStack(alignment: .top, spacing: 14) {
                BXTextField(label: "Name", text: $name)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Colour").font(Typo.ui(11.5, .medium)).foregroundStyle(Theme.text2)
                    HuePicker(selection: $hue)
                }
            }
            HStack(spacing: 20) {
                Toggle("Pin to the top", isOn: $pinned).toggleStyle(.bx).font(Typo.ui(12.5)).foregroundStyle(Theme.text).frame(width: 200)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Default layout").font(Typo.ui(11.5, .medium)).foregroundStyle(Theme.text2)
                    SegmentedControl(options: BuiltinPreset.shown.map { ($0, $0.label) }, selection: $preset, fill: Theme.input)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: "Link resources now", color: Theme.text3)
                if store.library.hosts.isEmpty && store.library.databases.isEmpty && store.allDocker.isEmpty {
                    Text("No saved hosts, databases or containers yet. You can link them later in Project Settings.").font(Typo.ui(12)).foregroundStyle(Theme.text3)
                }
                FlowChips(items: store.library.hosts.map { ($0.id, "SSH  \($0.name)", $0.tag.color) }, selection: $hosts)
                FlowChips(items: store.library.databases.map { ($0.id, "\($0.kind.badge)  \($0.name)", $0.tag.color) }, selection: $dbs)
                FlowChips(items: store.allDocker.map { ($0.id, "DK  \($0.name)", Theme.text2) }, selection: $docker)
            }
        }
    }

    private func fact(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(Typo.ui(11)).foregroundStyle(Theme.text3)
            Text(v).font(Typo.ui(12.5, .medium)).foregroundStyle(Theme.text).lineLimit(1)
        }
    }

    /// A brand-new project: name a folder, Brix makes it and starts a Git repository in it.
    private func create() {
        let panel = NSSavePanel()
        panel.title = "New Project"
        panel.prompt = "Create"
        panel.message = "Name the new project folder"
        panel.nameFieldLabel = "Project:"
        panel.nameFieldStringValue = "new-project"
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/Developer")
        guard panel.runModal() == .OK, let u = panel.url else { return }
        // The panel offers "Replace" for a folder that's already there: use it as it is.
        var isDir: ObjCBool = false
        let existed = FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) && isDir.boolValue
        if !existed {
            do {
                try FileManager.default.createDirectory(at: u, withIntermediateDirectories: false)
            } catch {
                self.error = "Couldn't create \(u.lastPathComponent): \(error.localizedDescription)"
                url = nil
                detected = nil
                return
            }
        }
        Task {
            // Git first, so the project opens with a branch; a failure only means no repository yet.
            // Off the main thread: without the developer tools, /usr/bin/git waits on an install prompt.
            if !existed, let failure = await Self.gitInit(u) {
                store.toast(.info, "Created \(u.lastPathComponent) without Git", detail: failure)
            }
            use(u)
        }
    }

    /// Runs `git init`; nil when it worked, else what went wrong.
    private static func gitInit(_ u: URL) async -> String? {
        await Task.detached {
            let git = Process(), err = Pipe()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = ["init", "-q", u.path]
            git.standardError = err
            git.standardOutput = FileHandle.nullDevice
            do { try git.run() } catch { return error.localizedDescription }
            let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            git.waitUntilExit()
            guard git.terminationStatus != 0 else { return nil }
            let msg = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return msg.isEmpty ? "git init exited with \(git.terminationStatus)." : msg
        }.value
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a project folder"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/Developer")
        guard panel.runModal() == .OK, let u = panel.url else { return }
        use(u)
    }

    private func use(_ u: URL) {
        url = u
        if let e = store.validateNewProject(url: u) {
            error = e.localizedDescription
            detected = nil
            return
        }
        error = nil
        let d = AppStore.detect(url: u)
        detected = d
        name = d.name
        hue = d.hue
    }

    private func add() {
        guard var d = detected else { return }
        d.name = name.trimmingCharacters(in: .whitespaces)
        d.hue = hue
        let p = store.addProject(d, pinned: pinned, preset: preset, hosts: hosts, databases: dbs, docker: docker)
        dismiss()
        if openAfter { store.openProject(p.id) } else { store.selectedProjectInList = p.id }
    }
}

struct HuePicker: View {
    @Binding var selection: ProjectHue
    var body: some View {
        HStack(spacing: 6) {
            ForEach(ProjectHue.allCases) { h in
                Button { selection = h } label: {
                    Circle().fill(h.color).frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: selection == h ? 2 : 0).padding(-3))
                        .padding(3)
                }
                .buttonStyle(.hand)
                .accessibilityLabel(h.rawValue.capitalized)
                .accessibilityAddTraits(selection == h ? .isSelected : [])
            }
        }
        .frame(height: 32)
    }
}

/// Wrapping multi-select chips.
struct FlowChips: View {
    let items: [(String, String, Color)]
    @Binding var selection: Set<String>

    var body: some View {
        if !items.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(items, id: \.0) { id, title, dot in
                    Chip(title: title, dot: dot, isOn: selection.contains(id)) {
                        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
                    }
                }
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, width: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > maxW, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
            width = max(width, x)
        }
        return CGSize(width: min(width, maxW), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}
