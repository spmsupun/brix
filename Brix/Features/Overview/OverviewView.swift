import SwiftUI

struct OverviewView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.islandGap) private var gap

    private var isEmpty: Bool {
        store.library.projects.isEmpty && store.library.hosts.isEmpty && store.library.databases.isEmpty
    }

    var body: some View {
        if isEmpty {
            WelcomeView()
        } else {
            HomeOverview()
        }
    }
}

// MARK: - First launch

struct WelcomeView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accent) private var accent

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            BrixMark(size: 56)
            VStack(spacing: 6) {
                Text("Welcome to Brix").font(Typo.ui(20, .semibold)).foregroundStyle(Theme.text)
                Text("Projects, agents, terminals, servers and databases in one workspace.").font(Typo.ui(13)).foregroundStyle(Theme.text3)
            }
            VStack(spacing: 8) {
                step(1, "Add a project folder", "Brix detects the language, framework and Git branch.", "folder.badge.plus") { store.sheet = .addProject }
                step(2, "Add an SSH host", "Uses your ~/.ssh config and agent. Passwords go to the Keychain.", "globe") { store.sheet = .editHost(nil) }
                step(3, "Add a database", "PostgreSQL, MySQL or SQLite, optionally through an SSH tunnel.", "cylinder.split.1x2") { store.sheet = .editDatabase(nil) }
            }
            .frame(width: 520)
            Button("Load sample workspace") { store.loadSampleWorkspace() }
                .buttonStyle(.plain).font(Typo.ui(12)).foregroundStyle(accent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .island()
    }

    private func step(_ n: Int, _ title: String, _ sub: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text("\(n)").font(Typo.ui(12, .semibold)).foregroundStyle(Theme.text2)
                    .frame(width: 26, height: 26).background(Circle().fill(Color.white(0.06)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Typo.ui(13, .semibold)).foregroundStyle(Theme.text)
                    Text(sub).font(Typo.ui(11.5)).foregroundStyle(Theme.text3)
                }
                Spacer()
                Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(Theme.text2)
            }
            .padding(.horizontal, 14).frame(height: 58)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.editor))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The Brix mark: a single lime brick with a notch, on obsidian.
struct BrixMark: View {
    var size: CGFloat
    @Environment(\.accent) private var accent
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(Color(hex: 0x111114))
                .overlay(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).strokeBorder(Color.white(0.08)))
            VStack(spacing: size * 0.06) {
                HStack(spacing: size * 0.06) {
                    RoundedRectangle(cornerRadius: size * 0.06).fill(accent).frame(width: size * 0.36, height: size * 0.2)
                    RoundedRectangle(cornerRadius: size * 0.06).fill(accent.opacity(0.35)).frame(width: size * 0.18, height: size * 0.2)
                }
                RoundedRectangle(cornerRadius: size * 0.06).fill(accent).frame(width: size * 0.6, height: size * 0.2)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
