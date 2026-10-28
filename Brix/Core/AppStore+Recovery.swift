import Foundation

/// Libraries Brix couldn't read earlier (kept as library.unreadable-*.json) that
/// load now: merged and offered back to the user.
extension AppStore {
    /// The kept copies that decode, newest first, merged into one library: each
    /// project, server, database and link once (the newest copy wins).
    func recoverableLibrary() -> (library: Library, files: [URL])? {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: persistence.directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("library.unreadable-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        var readable: [(URL, Library)] = []
        for f in files {
            if let lib = try? persistence.load(Library.self, from: f.lastPathComponent) { readable.append((f, lib)) }
        }
        guard !readable.isEmpty else { return nil }
        return (Self.merge(readable.map(\.1)), readable.map(\.0))
    }

    /// Union by id, earlier entries in `libs` winning.
    nonisolated static func merge(_ libs: [Library]) -> Library {
        var out = libs[0]
        func union<T: Identifiable>(_ a: [T], _ b: [T]) -> [T] where T.ID: Hashable {
            let ids = Set(a.map(\.id))
            return a + b.filter { !ids.contains($0.id) }
        }
        for lib in libs.dropFirst() {
            out.projects = union(out.projects, lib.projects)
            out.hosts = union(out.hosts, lib.hosts)
            out.databases = union(out.databases, lib.databases)
            out.docker = union(out.docker, lib.docker)
            out.stacks = union(out.stacks, lib.stacks)
            out.customPresets = union(out.customPresets, lib.customPresets)
            out.activity = union(out.activity, lib.activity).sorted { $0.date > $1.date }
            out.links.pairs.formUnion(lib.links.pairs)
            out.openProjects += lib.openProjects.filter { !out.openProjects.contains($0) }
        }
        return out
    }

    /// After launch: offer back what an earlier unreadable library held.
    func offerRecovery() {
        guard let (found, files) = recoverableLibrary() else { return }
        let have = Set(library.projects.map(\.id)), haveHosts = Set(library.hosts.map(\.id)), haveDBs = Set(library.databases.map(\.id))
        let p = found.projects.filter { !have.contains($0.id) && !$0.isSample }.count
        let h = found.hosts.filter { !haveHosts.contains($0.id) && !$0.isSample }.count
        let d = found.databases.filter { !haveDBs.contains($0.id) && !$0.isSample }.count
        guard p + h + d > 0 else { Self.retire(files, as: "library.restored-"); return }
        let what = [p > 0 ? "\(p) project\(p == 1 ? "" : "s")" : nil, h > 0 ? "\(h) server\(h == 1 ? "" : "s")" : nil, d > 0 ? "\(d) database\(d == 1 ? "" : "s")" : nil]
            .compactMap { $0 }.joined(separator: ", ")
        confirm("Restore your earlier library?",
                "Brix couldn't read your saved library \(files.count == 1 ? "once" : "\(files.count) times") and kept the copies. They load now and hold \(what) that aren't in Brix. Restore them? Nothing in Brix now is removed.",
                confirm: "Restore", destructive: false,
                onCancel: { [weak self] in self?.toast(.info, "Kept the copies", detail: "They stay in Brix's folder as library.unreadable-*.json.") }) { [weak self] in
            guard let self else { return }
            library = Self.merge([library, found])
            Self.retire(files, as: "library.restored-")
            for p in library.projects { refreshGit(p.id) }
            toast(.success, "Restored \(what)")
        }
    }

    /// Renames the copies so they aren't offered again (the files are kept).
    static func retire(_ files: [URL], as prefix: String) {
        for f in files {
            let to = f.deletingLastPathComponent().appendingPathComponent(f.lastPathComponent.replacingOccurrences(of: "library.unreadable-", with: prefix))
            try? FileManager.default.moveItem(at: f, to: to)
        }
    }
}
