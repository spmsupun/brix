import Foundation
import Security
import CryptoKit

/// JSON files in ~/Library/Application Support/Brix. Secrets never go here.
struct Persistence {
    let directory: URL

    static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["BRIX_SUPPORT_DIR"] {
            let dir = URL(fileURLWithPath: override, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let dir = applicationSupport.appendingPathComponent(dataFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var applicationSupport: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }

    /// "Brix" for the installed app, "Brix Dev" for development builds (from Info.plist).
    static var dataFolderName: String { infoValue("BrixDataFolder", release: "Brix", dev: "Brix Dev") }

    /// A Debug/Release value from Info.plist. When it's missing or wasn't filled in,
    /// a build with the .dev bundle id still gets the development value, so it
    /// never falls back to the installed app's data or passwords.
    static func infoValue(_ key: String, release: String, dev: String) -> String {
        let v = (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty || $0.contains("$(") ? nil : $0 }
        return v ?? (Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true ? dev : release)
    }

    /// True for a Brix Dev build.
    static var isDevBuild: Bool { dataFolderName != "Brix" }

    static let standard = Persistence(directory: supportDirectory)

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory.appendingPathComponent("workspaces"), withIntermediateDirectories: true)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func url(_ name: String) -> URL { directory.appendingPathComponent(Self.safeName(name)) }

    /// "workspaces/<project id>.json" names one file in that folder whatever the
    /// id holds: a "/" is escaped and a leading "." too, so "../x" can't climb out.
    static func safeName(_ name: String) -> String {
        let folder = "workspaces/", ext = ".json"
        guard name.hasPrefix(folder), name.hasSuffix(ext), name.count > folder.count + ext.count else { return name }
        var id = String(name.dropFirst(folder.count).dropLast(ext.count)).replacingOccurrences(of: "/", with: "%2F")
        if id.hasPrefix(".") { id = "%2E" + id.dropFirst() }
        return folder + id + ext
    }

    /// Digest of what this run last wrote to each file, so a save that changes
    /// nothing skips the disk. Shared by copies of this Persistence.
    private final class Written: @unchecked Sendable {
        private let lock = NSLock()
        private var digests: [String: SHA256.Digest] = [:]
        func same(_ path: String, _ d: SHA256.Digest) -> Bool { lock.lock(); defer { lock.unlock() }; return digests[path] == d }
        func put(_ path: String, _ d: SHA256.Digest) { lock.lock(); digests[path] = d; lock.unlock() }
    }
    private let written = Written()

    /// Returns nil when the file does not exist; throws when it exists but is unreadable.
    func load<T: Decodable>(_ type: T.Type, from name: String) throws -> T? {
        let u = url(name)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        let data = try Data(contentsOf: u)
        return try Self.decoder.decode(T.self, from: data)
    }

    func save<T: Encodable>(_ value: T, to name: String) throws {
        let data = try Self.encoder.encode(value)
        let u = url(name), digest = SHA256.hash(data: data)
        if written.same(u.path, digest), FileManager.default.fileExists(atPath: u.path) { return }
        try data.write(to: u, options: .atomic)
        written.put(u.path, digest)
    }

    func delete(_ name: String) {
        try? FileManager.default.removeItem(at: url(name))
    }
}

/// Keychain wrapper for passwords and tokens (generic passwords).
struct Keychain {
    let service: String

    /// Development builds use their own entries (from Info.plist), so they never
    /// read or change the installed app's passwords.
    static let standard = Keychain(service: Persistence.infoValue("BrixKeychainService", release: "com.brix.credentials", dev: "com.brix.credentials.dev"))

    /// Secrets already read this run. A Keychain read is a system call (and on
    /// a freshly signed debug build it can prompt), so each one is read once.
    /// Holds `nil` for "no item" too, so missing passwords aren't re-asked for.
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String?] = [:]
        func get(_ k: String) -> String?? { lock.lock(); defer { lock.unlock() }; return values[k] }
        func put(_ k: String, _ v: String?) { lock.lock(); values[k] = .some(v); lock.unlock() }
        func drop(_ k: String) { lock.lock(); values[k] = nil; lock.unlock() }
    }
    private static let cache = Cache()
    private func key(_ account: String) -> String { service + "\u{1F}" + account }

    enum KeychainError: LocalizedError {
        case status(OSStatus)
        var errorDescription: String? {
            switch self {
            case .status(let s): (SecCopyErrorMessageString(s, nil) as String?) ?? "Keychain error \(s)"
            }
        }
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func set(_ secret: String, for account: String) throws {
        let data = Data(secret.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(account)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let s = SecItemAdd(add as CFDictionary, nil)
            guard s == errSecSuccess else { throw KeychainError.status(s) }
        } else if status != errSecSuccess {
            throw KeychainError.status(status)
        }
        Self.cache.put(key(account), secret)
    }

    func get(_ account: String) throws -> String? {
        if let hit = Self.cache.get(key(account)) { return hit }
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { Self.cache.put(key(account), nil); return nil }
        // Errors (a denied prompt) aren't cached, so the next read asks again.
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainError.status(status) }
        let v = String(data: data, encoding: .utf8)
        Self.cache.put(key(account), v)
        return v
    }

    /// Forgets the remembered copy; the next `get` reads the Keychain again.
    func forget(_ account: String) { Self.cache.drop(key(account)) }

    func has(_ account: String) -> Bool { ((try? get(account)) ?? nil) != nil }

    func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        Self.cache.drop(key(account))
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }

    static func hostAccount(_ id: ResourceID) -> String { "ssh:\(id)" }
    static func dbAccount(_ id: ResourceID) -> String { "db:\(id)" }
}
