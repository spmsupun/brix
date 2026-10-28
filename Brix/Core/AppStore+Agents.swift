import SwiftUI

extension AppStore {
    var enabledAgents: [AgentConfig] { settings.agents.filter(\.enabled) }

    func agent(_ id: String?) -> AgentConfig? { id.flatMap { i in settings.agents.first { $0.id == i } } }

    func isInstalled(_ a: AgentConfig) -> Bool { agentPaths[a.id] != nil }

    func refreshAgentPaths() {
        var paths: [String: String] = [:]
        for a in settings.agents { if let p = ProcessRunner.which(a.binary) { paths[a.id] = p } }
        agentPaths = paths
    }

    /// The "start an agent" entry point. Uses the project's or the app's default
    /// agent when one is set; otherwise asks which one. With `then`, the caller
    /// places the session itself (a docked panel, say) instead of the agent grid.
    func startAgent(project id: ProjectID?, then: ((TerminalSession) -> Void)? = nil) {
        guard let id = id ?? currentProjectID ?? sortedProjects.first?.id else {
            toast(.info, "Add a project first", detail: "Agent sessions run inside a project folder.")
            return
        }
        let preferred = agent(project(id)?.agentID) ?? agent(settings.defaultAgent)
        if let a = preferred, a.enabled, isInstalled(a) || project(id)?.isSample == true {
            launchAgent(a, project: id, then: then)
        } else {
            agentCompletion = then
            sheet = .chooseAgent(id)
        }
    }

    func launchAgent(_ a: AgentConfig, project id: ProjectID, then: ((TerminalSession) -> Void)?) {
        if then == nil, route != .workspace(id) { openProject(id) }
        guard let s = newAgentSession(project: id, agent: a, attach: then == nil) else { return }
        then?(s)
    }

    /// One menu item per enabled agent, for "+" menus.
    func agentMenuItems(project id: ProjectID, then: ((TerminalSession) -> Void)? = nil) -> [MenuSpec] {
        enabledAgents.map { a in
            MenuSpec(title: isInstalled(a) || project(id)?.isSample == true ? a.name : "\(a.name) (not installed)", symbol: "sparkle") { [weak self] in
                guard let self else { return }
                if isInstalled(a) || project(id)?.isSample == true { launchAgent(a, project: id, then: then) } else { installAgent(a) }
            }
        } + [.separator, MenuSpec(title: "Manage Agents…", symbol: "gearshape") { [weak self] in self?.showAgentSettings() }]
    }

    func showAgentSettings() {
        customizeTab = "agents"
        route = .customize
    }

    func installAgent(_ a: AgentConfig) {
        let cmd = a.installCommand.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty else {
            toast(.info, "No install command for \(a.name)", detail: "Add one in Customize → Agents, or install it yourself.")
            return
        }
        confirm("Install \(a.name)?", "Runs this in a new terminal so you can watch it:\n\n\(cmd)", confirm: "Install") { [weak self] in
            guard let self else { return }
            let s = newTerminal(project: nil, title: "Install \(a.name)", command: cmd, attach: false)
            route = .terminals
            focusedSessionID = s.id
        }
    }

    func saveAgent(_ a: AgentConfig) {
        if let i = settings.agents.firstIndex(where: { $0.id == a.id }) { settings.agents[i] = a } else { settings.agents.append(a) }
        refreshAgentPaths()
    }

    func removeAgent(_ id: String) {
        settings.agents.removeAll { $0.id == id }
        if settings.defaultAgent == id { settings.defaultAgent = nil }
    }

    /// Turning an agent on offers to install it when it isn't found.
    func setAgentEnabled(_ id: String, _ on: Bool) {
        guard let i = settings.agents.firstIndex(where: { $0.id == id }) else { return }
        settings.agents[i].enabled = on
        refreshAgentPaths()
        if on, !isInstalled(settings.agents[i]) { installAgent(settings.agents[i]) }
    }

    func refreshAgentUsage() async {
        let shown = settings.agents.filter { $0.enabled && $0.showUsage }
        let result = await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: shown.map { ($0.id, AgentUsageReader.read($0)) })
        }.value
        agentUsage = result
        for (id, windows) in result { recordDailyMax("usage", id, windows.map(\.percent).max() ?? 0) }
    }

    func saveDefaultLayoutAsPreset(name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        var l = library.defaultLayout
        l.presetName = nil
        let p = CustomPreset(id: "custom-\(UUID().uuidString.prefix(6))", name: clean, layout: l)
        library.customPresets.append(p)
        library.defaultLayout.presetName = p.id
        toast(.success, "Saved layout “\(clean)”")
    }
}
