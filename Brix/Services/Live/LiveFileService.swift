import Foundation
import AppKit
import CoreServices

/// Real file system access with FSEvents watching.
final class LiveFileService: FileService {
    /// Folders that are listed but never descended into (too large to walk).
    static let heavyDirs: Set<String> = ["node_modules", ".git", ".next", "build", "dist", "DerivedData", ".build", "vendor", "__pycache__", ".venv", "Pods", "target"]
    static let maxNodes = 20_000

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
                let kids = heavyDirs.contains(name) ? [] : walk(item, rel: path, status: status, count: &count)
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

    func watch(_ project: Project, onChange: @escaping () -> Void) -> AnyObject? {
        FolderWatcher(path: project.expandedPath, onChange: onChange)
    }
}

/// FSEvents stream for one folder. Coalesces bursts into one callback.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void
    private var pending = false

    init?(path: String, onChange: @escaping () -> Void) {
        self.onChange = onChange
        var ctx = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        ctx.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let me = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            me.fire()
        }
        guard let s = FSEventStreamCreate(nil, callback, &ctx, [path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        else { return nil }
        stream = s
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
    }

    private func fire() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.pending = false
            self?.onChange()
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
