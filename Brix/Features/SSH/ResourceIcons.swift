import SwiftUI

/// The operating system an SSH host reported, read from `os-release` on first connect.
enum ServerOS: String {
    case ubuntu, debian, amazon, centos, rhel, fedora, rocky, alma, alpine, arch, suse, macos, freebsd, windows, linux, unknown

    init(_ text: String) {
        let t = text.lowercased()
        let table: [(String, ServerOS)] = [("ubuntu", .ubuntu), ("debian", .debian), ("amazon", .amazon), ("centos", .centos),
                                           ("red hat", .rhel), ("rhel", .rhel), ("fedora", .fedora), ("rocky", .rocky),
                                           ("alma", .alma), ("alpine", .alpine), ("arch", .arch), ("suse", .suse),
                                           ("darwin", .macos), ("macos", .macos), ("mac os", .macos), ("freebsd", .freebsd),
                                           ("windows", .windows), ("linux", .linux)]
        self = table.first { t.contains($0.0) }?.1 ?? (t.isEmpty ? .unknown : .linux)
    }

    var color: Color {
        switch self {
        case .ubuntu: Color(hex: 0xE95420)
        case .debian: Color(hex: 0xD70A53)
        case .amazon: Color(hex: 0xFF9900)
        case .centos: Color(hex: 0x9C3DB5)
        case .rhel: Color(hex: 0xEE0000)
        case .fedora: Color(hex: 0x51A2DA)
        case .rocky: Color(hex: 0x10B981)
        case .alma: Color(hex: 0x56A6E0)
        case .alpine: Color(hex: 0x3E8EC6)
        case .arch: Color(hex: 0x1793D1)
        case .suse: Color(hex: 0x73BA25)
        case .macos: Theme.text
        case .freebsd: Color(hex: 0xAB2B28)
        case .windows: Color(hex: 0x0078D4)
        case .linux: Theme.text2
        case .unknown: Theme.text3
        }
    }

    /// The vendor logo in the asset catalog (Simple Icons, CC0); nil draws a globe.
    var logo: String? { self == .unknown ? nil : "Logos/\(rawValue)" }

    /// Before the first connection, the login name often gives the OS away
    /// (cloud images ship with these users).
    static func guess(user: String) -> ServerOS {
        switch user.lowercased() {
        case "ubuntu": .ubuntu
        case "ec2-user": .amazon
        case "centos": .centos
        case "fedora": .fedora
        case "rocky": .rocky
        case "almalinux": .alma
        case "debian", "admin": .debian
        default: .unknown
        }
    }

    var label: String {
        switch self {
        case .rhel: "Red Hat"
        case .macos: "macOS"
        case .freebsd: "FreeBSD"
        case .suse: "SUSE"
        case .unknown: "Not connected yet"
        default: rawValue.capitalized
        }
    }
}

/// Host icon from its operating system, with its connection state as a dot.
struct ServerOSIcon: View {
    @Environment(AppStore.self) private var store
    let host: SSHHost
    var size: CGFloat = 18

    var body: some View {
        let known = ServerOS(host.os)
        let os = known == .unknown ? ServerOS.guess(user: host.user) : known
        let status = store.hostStatus[host.id] ?? .disconnected
        LogoBadge(logo: os.logo, color: os.color, size: size)
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            Circle().fill(status.color).frame(width: size * 0.36, height: size * 0.36)
                .overlay(Circle().strokeBorder(Theme.island, lineWidth: 1.5))
                .offset(x: size * 0.1, y: size * 0.1)
        }
        .help(!host.os.isEmpty ? "\(host.name): \(host.os)" : os == .unknown ? "\(host.name): operating system shows after the first connection" : "\(host.name): probably \(os.label), confirmed on first connection")
        .accessibilityHidden(true)
    }
}

/// Database product: the one chosen in the form, else read from the server version.
enum DBProduct {
    static func flavor(_ d: DatabaseConnection) -> DBFlavor {
        if let f = d.flavor { return f }
        let v = d.serverVersion.lowercased()
        if v.contains("mariadb") { return .mariadb }
        if v.contains("cockroach") { return .cockroach }
        if v.contains("redshift") { return .redshift }
        if v.contains("tidb") { return .tidb }
        switch d.kind {
        case .postgres: return .postgres
        case .mysql: return .mysql
        case .sqlite: return .sqlite
        }
    }
}

struct DatabaseIcon: View {
    @Environment(AppStore.self) private var store
    let db: DatabaseConnection
    var size: CGFloat = 18

    var body: some View {
        let p = DBProduct.flavor(db)
        let status = store.dbStatus[db.id] ?? .disconnected
        LogoBadge(logo: p.logo, color: p.color, size: size)
        .overlay(alignment: .bottomTrailing) {
            Circle().fill(status.color).frame(width: size * 0.36, height: size * 0.36)
                .overlay(Circle().strokeBorder(Theme.island, lineWidth: 1.5))
                .offset(x: size * 0.1, y: size * 0.1)
        }
        .help(db.serverVersion.isEmpty ? p.label : db.serverVersion)
        .accessibilityHidden(true)
    }
}

/// A vendor logo on a tinted rounded square; a globe when there's no logo.
struct LogoBadge: View {
    let logo: String?
    let color: Color
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(color.opacity(logo == nil ? 0.08 : 0.16))
            if let logo {
                Image(logo).renderingMode(.template).resizable().aspectRatio(contentMode: .fit)
                    .foregroundStyle(color).padding(size * 0.2)
            } else {
                Image(systemName: "globe").font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(color)
            }
        }
        .frame(width: size, height: size)
    }
}
