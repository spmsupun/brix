import Foundation
import Security

/// JSON files in ~/Library/Application Support/Brix. Secrets never go here.
struct Persistence {
    let directory: URL

    static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["BRIX_SUPPORT_DIR"] {
            let dir = URL(fileURLWithPath: override, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Brix", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

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

    func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// Returns nil when the file does not exist; throws when it exists but is unreadable.
    func load<T: Decodable>(_ type: T.Type, from name: String) throws -> T? {
        let u = url(name)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        let data = try Data(contentsOf: u)
        return try Self.decoder.decode(T.self, from: data)
    }

    func save<T: Encodable>(_ value: T, to name: String) throws {
        let data = try Self.encoder.encode(value)
        try data.write(to: url(name), options: .atomic)
    }

    func delete(_ name: String) {
        try? FileManager.default.removeItem(at: url(name))
    }
}

/// Keychain wrapper for passwords and tokens (generic passwords).
struct Keychain {
    let service: String

    static let standard = Keychain(service: "com.brix.credentials")

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
