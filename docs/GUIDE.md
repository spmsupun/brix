# Brix guide

Everything Brix does, in detail. For the short tour see the [README](../README.md).

A native macOS workspace for developers who build with AI agents. Projects, agent sessions (Claude Code, Codex and others), terminals, SSH hosts, databases, Docker and Git live in one window, and every project keeps its own dockable layout.

SwiftUI first, AppKit where it is clearly better (code editor, terminal, cursors, menus). macOS 14 or later.

![Workspace](screenshots/workspace.png)

## Build and run

Requirements: Xcode 16 or later (built and tested with Xcode 26.5), [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
./build.sh          # generates Brix.xcodeproj from project.yml, then builds Debug
./build.sh test     # runs the unit tests
open "build/dd/Build/Products/Debug/Brix Dev.app"
```

Or run `xcodegen generate` and open `Brix.xcodeproj` in Xcode. If `xcode-select` points at the Command Line Tools, `build.sh` uses `/Applications/Xcode.app` automatically.

Builds from source (Debug) are **Brix Dev**: a separate app with an orange DEV badge, its own data folder (`~/Library/Application Support/Brix Dev`) and its own Keychain entries, so it can run beside an installed Brix without touching it. On its first run it offers to copy the installed Brix's projects, servers and databases (never passwords).

On first launch Brix shows a short welcome: add a project folder, an SSH host or a database, or choose **Load sample workspace** to explore with demo data (Help menu has the same option, plus **Remove Sample Workspace**).

## Why App Sandbox is off

Brix is distributed outside the Mac App Store (GitHub Releases). It needs things the sandbox does not allow:

- **PTYs and child processes** for terminals and the `claude` CLI.
- **Your `~/.ssh` config, keys and agent socket**, so SSH works exactly like it does in Terminal.
- **The Docker socket** (`/var/run/docker.sock`) and the `docker` CLI.
- **Local databases** and arbitrary project folders anywhere on disk.

Hardened Runtime stays on. Brix asks for nothing beyond what those tools already have when you run them yourself.

## Where data and secrets live

| What | Where |
|---|---|
| Projects, hosts, database connections, Docker targets, links, presets, query history | `~/Library/Application Support/Brix/library.json` |
| Per-project layout, open files, terminal tabs, selection | `~/Library/Application Support/Brix/workspaces/<project>.json` |
| Appearance and layout settings | `~/Library/Application Support/Brix/settings.json` |
| SSH and database passwords | macOS Keychain, service `com.brix.credentials` |
| SSH keys | Never copied. Brix stores the key **path** only. |
| Per-project settings that travel with the repo: layout, default agent, notes, env var names, linked SSH hosts, databases and Docker targets (by address, never passwords), compose files found | `<project>/brix.json`, kept up to date automatically (turn off in Project Settings → General) |

Secrets are never shown in the UI ("Stored in Keychain" or "•••"), never written to JSON, and never passed to agents. Agent sessions receive linked resource **names** only. When a password is needed for SSH, Brix passes it to `ssh` through a one-line `SSH_ASKPASS` helper and an environment variable of that child process.

If `library.json` ever fails to load, Brix keeps a copy as `library.unreadable-<time>.json` before writing anything. A `brix.json` that doesn't parse (a bad edit, a merge conflict) is never overwritten; Brix shows the error in Project Settings instead.

Adding a folder that already has `brix.json` brings its layout, agent and connections along. Hosts and databases already in Brix with the same address are reused, so nothing is duplicated. Passwords are entered on first connect.

## Agents

Customize → Agents lists the coding agents Brix can start: Claude Code, Codex, Gemini CLI and OpenCode are built in, and any other CLI can be added with its launch and install commands. Starting an agent asks which one unless an app or project default is set. Turning on an agent that isn't installed offers to run its install command in a visible terminal.

Below the list, the selected agent's own setup is split into tabs: its global instructions, skills, subagents, commands, MCP servers and hooks. Double-click an item to edit it in Brix; create a new skill, subagent or command from a template; move one to the Trash; or remove an MCP server (through the agent's own CLI, since Claude Code rewrites `~/.claude.json` while it runs). MCP settings such as tokens are never shown.

Agent state comes from what's on the agent's screen: a running turn ("esc to interrupt", or a spinner word like "Cogitating…") shows as working and animates the agent's logo; a question or permission prompt shows as **Input**; anything else is idle. Closing an agent always asks first. The message box under agent sessions can be turned off in Appearance → Agents.

The toolbar can show plan usage for agents you choose. It reads files the CLIs already write on this Mac and sends nothing anywhere:

- **Codex:** the newest `rate_limits` entry in `~/.codex/sessions`.
- **Claude Code:** `~/.claude/state/rate-limits.json`, which a Claude Code status line script can write from the `rate_limits` it receives. Without that file, no Claude usage is shown.

## Tiled centre

In the Agent layout the centre is a tiled area: split any pane right or down, at any size, with Chrome-style tabs in every pane. Any tab kind can go in any pane: terminals, agents, open files, Explorer, Source Control, Plan, Agent Files, Inspector, Docker, database panels, notes and logs.

- Each pane's strip has Split Right, Split Down and a ⋯ menu (Split into 2 × 2, Move Tab to New Pane, Equalize Sizes, Maximize Pane, Swap with Pane, Close Pane). "+" after the tabs opens the Add Panel menu for that pane.
- Drag a tab along its strip to reorder, onto another strip to move it, or over a pane to split it: half-pane drop zones and a centred 3 × 3 picker show where it lands (left, right, top, bottom, or into the pane).
- Drag the 6pt gap between panes to resize (panes stay at least 160 × 120); double-click it to equalise.
- The tree is saved per project and restored on relaunch; "Save as preset…" keeps the tiled layout too (terminals are recreated, agents reuse the project's open sessions).

| Shortcut | Action |
|---|---|
| ⌘D / ⇧⌘D | Split right / down (new terminal) |
| ⌥⌘ arrows | Focus the neighbouring pane |
| ⌃⇧ arrows | Move the tab to the neighbouring pane |
| ⌃⌥⌘→ | Move tab to a new pane |
| ⌃⌘= | Equalize sizes |
| ⇧⌘↩ | Maximize or restore the pane |
| ⌘W / ⌥⌘W | Close tab / close pane |
| ⇧⌘T | Reopen the last closed tab |
| ⌥⌘T | New agent session (moved from ⇧⌘T) |

## Sessions, windows and restarts

- Closing the window (red button) hides it; terminals and agents keep running. Click the Dock icon to bring it back. ⌘Q quits.
- Every open project's terminals and agents, and the Terminals screen's tabs, are saved continuously (within half a second of a change). After a quit or a crash they're started again in their last folder. Claude Code sessions start with `--session-id`, so they come back with `claude --resume`; Codex resumes by id when known. Production SSH shells are not reopened automatically.

## Project overview

Clicking a project in the sidebar opens its overview; double-click opens the workspace. The overview shows:

- **Agent sessions** for the folder from Claude Code (`~/.claude/projects`) and Codex (`~/.codex/sessions`), including ones started outside Brix. Resume one in Brix, copy its id or resume command, reveal the transcript, or move it to the Trash.
- **AI instructions**: CLAUDE.md, AGENTS.md, GEMINI.md, Cursor and Copilot rules, `.mcp.json`, and `.claude` skills, subagents and commands, also inside sub-projects.
- **Connections** attached to the project, with Attach and Detach.
- **Structure**: top-level files and folders, nested projects (by package.json, go.mod, compose files and so on) and nested git repositories.

## Home, project overview and status bar

- **Home (Overview)** is a build site. Every brick is a commit and every crane is an agent at work. Each project gets a tower (up to four, most active first). Today's commits are bright bricks and older history is compressed into dimmer floors. Uncommitted changes show as dashed scaffolding. Each working agent raises a crane, a waiting agent lights an amber beacon, and a new commit drops a brick. The Brix buddy's mood follows the real state: waiting beats shipped (a build or push in the last minute), which beats working, which beats idle. Under it: **Since your last visit** (agents waiting, failed builds with a "Fix with agent" button, unreachable servers, unpushed commits, finished agents), **Usage & limits** per agent provider with a pace warning for the 7-day window, **This Mac** (CPU, memory, storage, battery, the biggest caches, and clearing Xcode's build cache to the Trash), and **Servers & Docker** with problems first.
- **Project overview** has these parts:
  - An ask box that starts any configured agent with your prompt and @-references.
  - Five stat tiles with seven-day sparklines.
  - Every agent session for the folder (live or from transcripts), with a tool-call ribbon, files and lines changed, and Open, Resume, Fork and more.
  - An activity timeline.
  - Run (tasks detected from build.sh, package.json, Makefile, Cargo, Go, Swift, Xcode and Compose; running one records a build or test result).
  - Connections, AI instructions (with "Generate from repo") and Codebase.
- **Status bar:** on the left, a chip for each active agent: working, waiting for you, or done and ready to review. On the right: the last build, the branch, plan usage per provider (mini bar per window, reset time), servers online and containers running.
- Animations follow Reduce Motion (static poses) and pause while no Brix window is visible. Agent time, builds and daily totals are stored in `library.json`; nothing is sent anywhere.

## Sidebar

- A short nav at the top (Overview, All Terminals, Git, Recent Files), the project tree in the middle, and the library (Servers, Docker, Databases) pinned at the bottom.
- Each project row shows its mark, branch and uncommitted changes. Collapsed, it also shows what an agent is doing (or that one needs input) and counts of agents, terminals and linked resources.
- Expanded, a project shows its sessions on a coloured spine, dashed Agent and Terminal buttons, then collapsible Servers, Docker and Databases groups (a group with nothing linked is hidden). Clicking a server opens its files as a tab in the project.
- The + on a project row opens "New in project": an agent session, a terminal, a shell on any linked server or container, or Link server, container or DB.
- Drag projects to reorder them (pinned projects stay on top). Drag servers or databases inside a project group to reorder them everywhere.
- A folder holding several git repositories (a monorepo's frontend, backend…) shows them nested under it as projects of their own, each with its branch, changes and agents; the parent's overview lists them and merges their commits. Nested repositories don't get a `brix.json` unless you turn it on.
- Hosts show their operating system's logo (read from `/etc/os-release` the first time Brix connects; before that, guessed from cloud login names such as `ubuntu` or `ec2-user`) and databases their product's logo (from the server version on first connect). Logos are from [Simple Icons](https://simpleicons.org) (CC0) and are used everywhere a host or database appears.
- Clicking a project selects only the project; a session row is highlighted only while its workspace shows it.

## SSH file explorer

Browse Files on a host (sidebar, SSH screen, or a project's linked host) lists the server's files over `ssh`, using your `~/.ssh/config` and keys. Double-click a folder to open it or a text file to edit it in Brix; save writes it back. Upload with the button or by dropping files from Finder; download, new folder, rename, duplicate and delete from the toolbar or the context menu. Every change on a Production host asks first, and delete always asks. The listing works with GNU tools and with busybox or BSD systems.

## Editing files

Text files open in Brix. A project file opens as a tab in the tiled centre, alongside agents and terminals, with the same tabs; the Code and Focus layouts use the tiled centre too. Project files are editable in place (⌘S saves, ⌥⌘S saves all, an unsaved file shows a dot on its tab), and files outside projects (agent instructions, compose files, server files) open in Brix's own editor window.

## Databases and Docker

- Database: dump and restore (pg_dump/pg_restore/psql, mysqldump/mysql, sqlite3; through the SSH tunnel when set), open the CLI in a terminal, copy the connection URL without the password, and a read-only switch. Restore is refused while read-only is on and asks twice for Production. Client tools come from Homebrew (`brew install libpq` or `mysql-client`).
- Docker: containers, compose stacks, networks, volumes and images, for local Docker and connected hosts. Click any of them for details from `docker inspect` (ports, networks, mounts, environment with secrets masked, labels, live CPU and memory for containers; services and compose files for stacks; what uses a volume or image) and its actions: start, stop, restart, pause, kill, remove, logs, shell, pull, up and down. Removing always asks. Docker is hidden from the sidebar when the `docker` CLI isn't installed and nothing Docker is saved.

## Database connections

The connection form lists PostgreSQL, MySQL, MariaDB, SQLite, CockroachDB, TimescaleDB, Supabase, Neon, Redshift, TiDB and PlanetScale. Each speaks the PostgreSQL, MySQL or SQLite protocol Brix connects with, and brings its default port and SSL setting. Paste a connection URL to fill the form (its password goes to the Keychain on save). Advanced holds SSL, an SSH tunnel, a connect timeout and notes.

## GitHub

Settings → Accounts shows whether the GitHub CLI (`gh`) is installed and signed in, with buttons to install, sign in or out (in a terminal). Brix reads pull requests and workflow runs through that sign-in and stores no token. GitHub data refreshes in the background every minute (every 15 seconds while a pipeline runs, and only while a Brix window is visible). A running pipeline shows on the project's sidebar row, its overview header, its Home tower and in "Since your last visit"; failed pipelines show there too. A folder of repositories shows its repositories' pull requests and pipelines together, and projects without a GitHub remote show no GitHub card. With several GitHub accounts signed in to gh (`gh auth login` again adds one), each project uses the account that can see its repository: Brix tries them in turn and remembers the one that worked, or you pick one in Project Settings → General. The chosen account's token is fetched from gh for each call and never saved by Brix.

## Importing connections

Add (+) → Import from JetBrains / VS Code, the import button on the SSH and Database screens, or ⌘K "Import connections" finds SSH hosts and databases in:

- JetBrains IDEs: `options/sshConfigs.xml` (newest version of each IDE) and each project's `.idea/sshConfigs.xml`, `.idea/dataSources.xml` and `dataSources.local.xml`, including SSH tunnels.
- VS Code, Cursor, VSCodium, Windsurf: SQLTools connections in user and project settings, and the Remote-SSH config file.
- `~/.ssh/config` (wildcards and GitHub/GitLab key aliases are skipped).

You review everything before it's added. Tags are guessed from names (anything mentioning prod becomes Production, which is read-only and asks before connecting). Passwords found in VS Code settings go to the Keychain; JetBrains keeps its own passwords, so those are entered on first connect. Importing reads files only and never connects.

## Live services and the sample workspace

Everything you add yourself runs against the real system. The sample workspace runs on mock services so it can be explored safely.

| Area | Live implementation | Sample workspace |
|---|---|---|
| Terminals | PTY via [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) running your login `zsh` | Simulated shell (`ls`, `pwd`, `git status/log`, `pnpm dev/test`, `go test`, `docker ps`, `htop`, `claude`, `help`) |
| Agents | The agent CLI (claude, codex, …) in a PTY; plan and touched files parsed from Claude Code output | Scripted session that moves to "needs input" |
| SSH | `/usr/bin/ssh` in a PTY, so `~/.ssh/config` and the agent apply; metrics over SSH | 1 s simulated connect; Prod Bastion times out |
| Git | `git` CLI, porcelain v2 | In-memory repository |
| PostgreSQL / MySQL / SQLite | PostgresNIO / MySQLNIO / GRDB, optional SSH tunnel | Generated rows; `atlas_prod_replica` times out |
| Docker | `docker` CLI locally, or over SSH on a linked host | `db`, `redis`, `atlas-api`, `queue-worker` |
| Files | Real file system with FSEvents watching | Tree and sources from the design |

Production-tagged hosts and databases ask before connecting or writing. Production databases are read-only by default (the session is opened read-only); writes need an explicit confirmation.

## Architecture

```
Brix/
  App/            BrixApp, AppDelegate, menu commands and shortcuts, notifications, debug snapshot tool
  Core/           AppStore (navigation, library, runtime state), WorkspaceStore (per project), persistence, Keychain, settings
  Layout/         DockModel (pure value type), dock host views, drag and drop, resize handles
  DesignSystem/   Tokens, components, CodeView (NSTextView), DataGrid, syntax highlighter, native menus
  Models/         Project, SSHHost, DatabaseConnection, DockerTarget, links, sessions, Git, files
  Services/       Protocols, mock implementations, sample data, Live/ implementations
  Features/       One folder per screen or panel
BrixTests/        Dock model, links, fuzzy matching, Keychain, parsers, mock Git, persistence safety
design/           The design source of truth (tokens and artboards)
```

- `@Observable` stores; views read the store from the environment.
- Services sit behind protocols (`GitService`, `FileService`, `TerminalService`, `AgentService`, `SSHService`, `MetricsService`, `DatabaseService`, `DockerService`). `Services` picks the mock set for sample resources and the live set for everything else.
- The dock layout is a plain `Codable` value (`DockLayout`) with move, stack, hide, float, resize clamps and presets, so it is fully unit tested.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘K | Command palette (⇥ scopes to the project, ⌘↩ opens in a split) |
| ⌘1 to ⌘7 | Overview, Projects, Terminals, Git, Databases, Docker, SSH |
| ⌘O | Open project |
| ⌘T / ⌥⌘T | New terminal / new agent session |
| ⌘D / ⇧⌘D | Split right / down |
| ⌘P | Go to file |
| ⌘W, middle click | Close tab |
| ⌃Tab | Next tab |
| ⌃⌘S | Toggle sidebar |
| ⌥⌘0 | Toggle inspector |
| ⌥⌘E / G / J / I / L | Explorer, Source Control, Terminal, Inspector, Connections |
| ⌃⌥← / → / ↓, ⌃⌥F | Move the selected panel left, right, bottom, float |
| ⌃⌘1 to ⌃⌘4 | Code, Agent, Review, Focus layouts |
| ⇧⌘[ / ⇧⌘] | Previous / next open project |
| ⌘↩ | Commit / run query |
| ⌘, | Customize (theme, density, layouts, agents) |

## Development aids

- `BRIX_SUPPORT_DIR=/tmp/x` points Brix at a different data folder, so your real data is never touched.
- `BRIX_SNAPSHOT_DIR=/tmp/shots` loads the sample workspace, renders each main screen to PNG and quits (`BRIX_SNAPSHOT_ONLY=Main,SSH` limits the set). Uses the app's own drawing, so no screen-recording permission is needed. Known limit: the live SwiftTerm terminal paints its background on a layer, which this capture can't see, so live terminals appear on white in these images.
- `BRIX_LAUNCH_MARK=/tmp/mark` writes the time the first window appeared, then quits.
