import Foundation
import AppKit
import CoreServices

/// Real file system access with FSEvents watching.
final class LiveFileService: FileService {
    /// Folders that are listed but never descended into (too large to walk).
    static let heavyDirs: Set<String> = ["node_modules", ".git", ".next", "build", "dist", "DerivedData", ".build", "vendor", "__pycache__", ".venv", "Pods", "target"]
    static let maxNodes = 20_000

    /// `*.noindex` too: build output kept out of Spotlight is just as large.
    static func isHeavy(_ name: String) -> Bool { heavyDirs.contains(name) || isGenerated(name) }
    /// Never tracked by Git, so changes inside them don't even refresh Git.
    static func isGenerated(_ name: String) -> Bool {
        ["node_modules", "DerivedData", ".build", "__pycache__", ".venv", ".next"].contains(name) || name.hasSuffix(".noindex")
    }

    var gitStatusProvider: (@MainActor (Project) -> [String: GitStatus])?

    func tree(_ project: Project) async throws -> [FileNode] {
        let root = project.url
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw ServiceError("Folder not found: \(project.path)")
        }
        let provider = gitStatusProvider
        let status = await MainActor.run { provider?(project) } ?? [:]
        return await Task.detached(priority: .userInitiated) {
            var count = 0
            return Self.walk(root, rel: "", status: status, count: &count)
        }.value
    }

    private static func walk(_ url: URL, rel: String, status: [String: GitStatus], count: inout Int) -> [FileNode] {
        guard count < maxNodes,
              let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        else { return [] }
        var nodes: [FileNode] = []
        for item in items {
            let name = item.lastPathComponent
            if name == ".DS_Store" || name == ".git" { continue }
            count += 1
            let path = rel.isEmpty ? name : rel + "/" + name
            let dir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if dir {
                let kids = isHeavy(name) ? [] : walk(item, rel: path, status: status, count: &count)
                let inner = status.filter { $0.key.hasPrefix(path + "/") }.map(\.value)
                let st: GitStatus? = inner.isEmpty ? nil : (Set(inner).count == 1 ? inner[0] : .M)
                nodes.append(FileNode(name: name, path: path, isDirectory: true, children: kids, gitStatus: st))
            } else {
                nodes.append(FileNode(name: name, path: path, isDirectory: false, gitStatus: status[path]))
            }
        }
        return nodes.sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
    }

    func read(_ project: Project, path: String) async -> FileContent {
        let url = project.url.appendingPathComponent(path)
        return await Task.detached {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return .missing }
            let size = (attrs[.size] as? Int) ?? 0
            if FileKinds.isImage(path), let img = NSImage(contentsOf: url) {
                let rep = img.representations.first
                let px = CGSize(width: rep?.pixelsWide ?? Int(img.size.width), height: rep?.pixelsHigh ?? Int(img.size.height))
                return .image(img, size: px)
            }
            // ponytail: 8 MB cap for the read-only viewer; stream or page larger files if needed.
            guard size <= 8_000_000, let data = try? Data(contentsOf: url) else { return .binary(size: size) }
            if data.prefix(8000).contains(0) { return .binary(size: size) }
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return .binary(size: size) }
            return .text(text)
        }.value
    }

    func info(_ project: Project, path: String) async -> FileInfo {
        let url = project.url.appendingPathComponent(path)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? 0
        let modified = attrs?[.modificationDate] as? Date
        var lines = 0
        var encoding = "binary"
        if case .text(let t) = await read(project, path: path) {
            lines = t.reduce(into: 0) { if $1 == "\n" { $0 += 1 } } + (t.hasSuffix("\n") || t.isEmpty ? 0 : 1)
            encoding = "UTF-8"
        }
        return FileInfo(kind: FileKinds.kind(for: path), size: size, lines: lines, encoding: encoding, modified: modified)
    }

    func create(_ project: Project, path: String, isDirectory: Bool) async throws {
        let clean = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !clean.isEmpty, !clean.contains("..") else { throw ServiceError("Enter a valid name") }
        let url = project.url.appendingPathComponent(clean)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw ServiceError("\(clean) already exists") }
        do {
            if isDirectory {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard FileManager.default.createFile(atPath: url.path, contents: Data()) else { throw ServiceError("Could not create \(clean)") }
            }
        } catch let e as ServiceError {
            throw e
        } catch {
            throw ServiceError(error.localizedDescription)
        }
    }

    func rename(_ project: Project, from: String, to: String) async throws {
        let target = to.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty, !target.contains(".."), !target.contains("/") else { throw ServiceError("Enter a valid name") }
        let src = project.url.appendingPathComponent(from)
        let dst = src.deletingLastPathComponent().appendingPathComponent(target)
        do {
            try FileManager.default.moveItem(at: src, to: dst)
        } catch {
            throw ServiceError(error.localizedDescription)
        }
    }

    func watch(_ project: Project, onChange: @escaping (_ files: Bool) -> Void) -> AnyObject? {
        FolderWatcher(path: project.expandedPath, onChange: onChange)
    }
}

/// FSEvents stream for one folder. Coalesces bursts into one callback.
/// Changes inside build output and dependency folders are ignored: a build or
/// `npm install` writes thousands of files there, and each burst re-walked the
/// tree (a full CPU core while a build ran). Inside `.git` only Git is refreshed,
/// so `git status` touching its own index can't loop into a tree walk.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let root: String
    private let onChange: (_ files: Bool) -> Void
    private var pending: Bool?

    init?(path: String, onChange: @escaping (_ files: Bool) -> Void) {
        root = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        self.onChange = onChange
        var ctx = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        ctx.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            me.fire(list.prefix(count))
        }
        guard let s = FSEventStreamCreate(nil, callback, &ctx, [root] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes))
        else { return nil }
        stream = s
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
    }

    /// nil: ignore; false: refresh Git only; true: project files.
    /// Inside build, dist or vendor folders (sometimes tracked) Git is still
    /// refreshed, but the file tree isn't re-walked.
    static func kind(_ path: String, root: String) -> Bool? {
        // FSEvents reports /private/tmp for a project opened as /tmp.
        let rel = path.hasPrefix(root) ? path.dropFirst(root.count)
            : path.hasPrefix("/private" + root) ? path.dropFirst(root.count + 8) : nil
        guard let rel else { return true }
        let dirs = rel.split(separator: "/").map(String.init).dropLast()
        if dirs.contains(where: LiveFileService.isGenerated) { return nil }
        return dirs.contains { $0 == ".git" || LiveFileService.heavyDirs.contains($0) } ? false : true
    }

    private func fire(_ paths: ArraySlice<String>) {
        let kinds = paths.compactMap { Self.kind($0, root: root) }
        guard !kinds.isEmpty else { return }
        let files = kinds.contains(true)
        if let p = pending { pending = p || files; return }
        pending = files
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, let files = self.pending else { return }
            self.pending = nil
            self.onChange(files)
        }
    }

    deinit {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }
}
