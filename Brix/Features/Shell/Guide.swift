import SwiftUI

/// The first-launch tour: a few tips, each pointing at the control it explains.
/// Shown once (Help > Show Guide brings it back). A step whose control isn't on
/// screen, such as the project list before any project is added, is skipped.
enum GuideStep: String, CaseIterable {
    case add, projects, search, new, customize

    var title: String {
        switch self {
        case .add: "Add what you work with"
        case .projects: "Your projects"
        case .search: "Find anything"
        case .new: "Start an agent or terminal"
        case .customize: "Make it yours"
        }
    }

    var body: String {
        switch self {
        case .add: "Add a project folder, an SSH server, a database or a Docker container."
        case .projects: "Click a project for its overview, double-click to fold it. Its agents, terminals, servers and databases sit underneath."
        case .search: "Press ⌘K to jump to any project, file, server, table or action."
        case .new: "Start a Claude agent, a terminal or a server shell in the current project."
        case .customize: "Layout, theme, fonts, notifications and sounds."
        }
    }
}

struct GuideAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { a, _ in a }
    }
}

extension View {
    /// Marks the control a guide step points at.
    func guideAnchor(_ step: GuideStep) -> some View {
        anchorPreference(key: GuideAnchorKey.self, value: .bounds) { [step.rawValue: $0] }
    }
}

/// Dims the window, rings the control and shows the tip beside it.
struct GuideOverlay: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accent) private var accent
    let anchors: [String: Anchor<CGRect>]

    var body: some View {
        GeometryReader { geo in
            let steps = GuideStep.allCases.filter { anchors[$0.rawValue] != nil }
            if let i = store.guideStep, !steps.indices.contains(i) {
                // Nothing to point at (or a stale step): end the tour instead of
                // leaving it running with nothing on screen.
                Color.clear.onAppear { store.guideStep = nil }
            } else if let i = store.guideStep, let anchor = anchors[steps[i].rawValue] {
                let step = steps[i]
                let r = geo[anchor].insetBy(dx: -6, dy: -6)
                ZStack(alignment: .topLeading) {
                    // A hole in the dimming over the control.
                    Color.black.opacity(0.35)
                        .mask {
                            Rectangle().overlay {
                                RoundedRectangle(cornerRadius: 10).frame(width: r.width, height: r.height)
                                    .position(x: r.midX, y: r.midY).blendMode(.destinationOut)
                            }
                            .compositingGroup()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {}
                    RoundedRectangle(cornerRadius: 10).strokeBorder(accent, lineWidth: 2)
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                        .allowsHitTesting(false)
                    card(step, index: i, count: steps.count)
                        .frame(width: 300)
                        .fixedSize(horizontal: false, vertical: true)
                        .position(cardCenter(near: r, in: geo.size))
                }
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
    }

    /// Below the control when there's room, else above; kept inside the window.
    private func cardCenter(near r: CGRect, in size: CGSize) -> CGPoint {
        let w: CGFloat = 300, h: CGFloat = 150, gap: CGFloat = 12
        let below = r.maxY + gap + h < size.height
        let y = below ? r.maxY + gap + h / 2 : r.minY - gap - h / 2
        let x = min(max(r.midX, w / 2 + 12), size.width - w / 2 - 12)
        return CGPoint(x: x, y: min(max(y, h / 2 + 12), size.height - h / 2 - 12))
    }

    private func card(_ step: GuideStep, index: Int, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(step.title).font(Typo.ui(13.5, .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Text("\(index + 1) of \(count)").font(Typo.ui(11)).monospacedDigit().foregroundStyle(Theme.text3)
            }
            Text(step.body).font(Typo.ui(12.5)).foregroundStyle(Theme.body).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Skip tour") { finish() }.buttonStyle(.hand).font(Typo.ui(12)).foregroundStyle(Theme.text3)
                Spacer()
                if index > 0 { SubtleButton(title: "Back", height: 28) { store.guideStep = index - 1 } }
                AccentButton(title: index + 1 == count ? "Done" : "Next", height: 28) {
                    if index + 1 == count { finish() } else { store.guideStep = index + 1 }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.sheet))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
        .onExitCommand { finish() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Guide, step \(index + 1) of \(count): \(step.title)")
    }

    private func finish() {
        store.guideStep = nil
        store.library.guideSeen = true
    }
}
