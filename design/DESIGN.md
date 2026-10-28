# Brix design spec

This folder is the design source of truth for Brix. It was exported from the Claude Design canvas:
https://claude.ai/code/artifact/f703f664-ef24-46f2-8cb0-86710126fa31

The canvas uses the working name **"Conduit"**. The product name is **Brix**.

## How to read the artboards

`artboards/*.dc.html` are HTML files with **inline styles**. Read them as code; they don't render on their own, because they rely on a canvas runtime.

| Markup | What it means |
|---|---|
| `<x-dc>…</x-dc>` | The screen markup. Every size, colour, radius and gap is in the `style` attributes. |
| `{{name}}` | A value computed in the `renderVals()` script at the bottom of the file. That script also holds all the mock data and per-row styles. |
| `<sc-for list="{{items}}" as="item">` | A loop. |
| `<sc-if value="{{cond}}">` | A conditional. |
| `<dc-import name="Toolbar" …>` | Embeds `Toolbar.dc.html` (or `Sidebar.dc.html`). Its attributes are props, e.g. `variant="rail"`, `active="atlas-web"`, `preset="code"`, `dock-l="{{ false }}"`. |
| `canvas.json` | Lists every artboard and its title. Every frame is 1440×900. |

Each screen is laid out the same way, top to bottom:
- toolbar, 52pt;
- main row, 822pt: a sidebar or rail plus islands, with a 6pt gap and 6pt outer padding;
- status bar, 26pt.

## Artboards

| File | Screen |
|---|---|
| Main | Overview / home |
| CommandPalette | ⌘K palette over a dimmed workspace |
| Projects | Projects list with an inspector |
| ProjectWorkspace | Project workspace, **Code** layout. The dock menu is open on Source Control. |
| WorkspaceAgent | Workspace, **Agent** layout. Explorer and Connections are docked right; the sidebar is a rail. |
| Git | Workspace, **Review** layout. Diff in the centre, Source Control left, Inspector right. |
| WorkspaceCustom | A user-built layout with the **+ Add panel** menu open. Docker and Database panels are docked; the sidebar is on the right. |
| ProjectResources | Project settings → Resources: links SSH, databases and Docker to a project (many-to-many). Interactive. |
| Customize | Layout and appearance settings with a live dock preview. Interactive. |
| Terminals | Global terminal sessions, grouped by project and server. |
| SSH | SSH connections list, host detail, and the Edit Connection sheet. |
| Database | Database browser: object tree and data grid. |
| SQL | SQL editor, results, history. |
| Toolbar, Sidebar | Shared components. Sidebar has `full` and `rail` variants. |

## Tokens

### Surfaces
| Token | Value | Usage |
|---|---|---|
| base | `#09090B` | Window background, between islands |
| island | `#121214` | Panel surface |
| editor | `#0E0E10` | Editor and well |
| terminal | `#0B0B0D` | Terminal body; header `#111113` |
| input | `#0C0C0E` | Text fields, segmented control track |
| sheet | `#161618` | Sheets, palette, popovers (`#18181B`) |
| hover | white 4.5% | |
| selected | white 7% + 1px inner stroke white 6% | |
| segmented on | white 10% | |

### Lines
- Island border: white 7%.
- Divider: white 6%.
- Island top highlight: `inset 0 1px 0` white 4%.
- Popover/sheet border: white 10–11%; shadow `0 24–40px 60–100px` black 60–75%.

### Text
| Role | Value |
|---|---|
| Primary | `#F4F4F5` |
| Secondary | `#A1A1AA` |
| Body in lists | `#D4D4D8` |
| Tertiary | `#8A8A93` |
| Meta | `#74747E` |
| Line numbers | `#3F3F46` |
| NULL / disabled | `#52525B` |

### Accent (user-selectable)
| Name | Value |
|---|---|
| Lime (default) | `#C8F560` |
| Violet | `#A78BFA` |
| Cyan | `#22D3EE` |
| Amber | `#FBBF24` |
| Pink | `#F472B6` |
| Blue | `#60A5FA` |

Text on an accent fill is `#09090B`. Use the accent only for the primary action, focus, active preset/radio and the caret.

### Status
| Status | Value |
|---|---|
| Green (running, connected, added) | `#4ADE80` |
| Amber (idle, modified, needs input) | `#FBBF24` |
| Red (error, deleted, production) | `#F87171` |
| Blue (development, info) | `#60A5FA` |
| Cyan (untracked, local) | `#22D3EE` |
| Violet (personal, agent) | `#A78BFA` |

### Environment tags
Uppercase, 8.5–9.5pt bold, text in the tag colour on a 12% tint, radius 4:
- PROD red
- STAGE amber
- DEV blue
- PERSONAL violet
- LOCAL cyan

### Project identity hues
| Project | Hue |
|---|---|
| atlas-web | violet `#A78BFA` |
| atlas-api | cyan `#22D3EE` |
| billing-service | orange `#FB923C` |
| ml-pipelines | pink `#F472B6` |
| ios-companion | blue `#60A5FA` |
| dotfiles | green `#4ADE80` |

How a project's hue is used:
- **Project mark:** rounded square with a 16% tint fill, a 38% hue border and initials in the hue.
- **Active editor tab:** a 2pt top bar in the hue.
- **Selected explorer row:** 12% hue fill with a 22% hue inner stroke.
- **Active agent pane:** a hue border at 35% plus a 3pt hue glow at 7%.

### Syntax
| Token | Value |
|---|---|
| Keyword | `#B4A1FF` |
| String | `#C3E88D` |
| Type | `#7DD3FC` |
| Function | `#F4F4F5`, medium weight |
| Number | `#F5A97F` |
| Comment | `#5C5C66`, italic |
| Punctuation | `#8A8A93` |
| JSX tag | `#F9A8D4` |
| Diff added | row tint green 8%, 2pt green left bar, text `#D9F99D` |
| Diff removed | row tint red 8%, 2pt red left bar, text `#FECACA` |
| Diff hunk | white 3% |

### Type
**UI: SF Pro**

| Element | Size | Weight / notes |
|---|---|---|
| Body | 13 | |
| Rows | 12.5 | |
| Secondary | 11.5–12 | |
| Meta | 10.5–11 | |
| Panel header title | 11 | semibold, tracking 0.04em |
| Page title | 17 | semibold |
| Greeting | 20 | semibold |
| Large stats | 18 | semibold, tabular numbers |

**Mono: SF Mono**

| Element | Size / line height |
|---|---|
| Editor | 12.5 / 20 |
| Terminal | 11.5–12 / 18–19 (user setting 10–16) |
| Paths and hashes | 11–11.5 |

### Shape and metrics
- **Radii:**
  - island 10; control 6–8; segmented track 8 with 6 inside;
  - sheet and palette 14; popover 10–12;
  - project mark 28–30% of its size.
- **Island gap:** Seamless 1, Islands 6 (default), Airy 10.
- **Fixed sizes:**
  - toolbar 52; status bar 26; panel header 36; editor tab bar 38 (tabs 32–33);
  - sidebar full 232, rail 56;
  - dock widths: left about 252, right about 280–300; bottom dock about 262–300.
- **Row heights:**
  - Compact: tree 24, list 26–28, grid 30, project/host rows 44–56.
  - Comfortable: add 4 to each.

## Components
- **Island**
- **PanelHeader:** grip (2×3 dots), title, count pill, actions, then the DockButton.
- **DockButton:** a window icon with the docked side filled. It opens the dock menu (Left, Right, Bottom, Float, Hide), each with ⌃⌥ shortcuts.
- **Add panel menu:** search, then groups Shells / Project / Linked resources. Each row has a 24pt badge, a title, a subtitle and a key hint.
- **Toolbar:**
  - traffic lights and sidebar toggle;
  - project switcher pill: mark, name, "/", ⎇ branch, chevron;
  - centre search pill "Search projects, files, hosts, actions… ⌘K";
  - layout preset segmented control (Code / Agent / Review / Focus), shown only in projects;
  - left, bottom and right dock toggles;
  - accent "+" button.
- **Sidebar:**
  - Groups: WORKSPACE (Overview, Projects, Recent Files), DEVELOPMENT (Terminals, Git, Databases, Docker), INFRASTRUCTURE (SSH Connections, Servers, Database Connections), then PROJECTS (+), HOSTS (+) and DATABASES (+).
  - The artboard Sidebar shows PROJECTS and HOSTS only; Docker and the DATABASES group were added later and use the same row styles.
  - Rows show count badges, coloured where meaningful.
  - Footer: accent "Add" button and a Customize icon.
  - Rail variant: icons, then project marks with a hue ring on the active one, then Customize.
- **Others:** TagPill, StatusDot (pulse for live), KeyCap, SearchField, SegmentedControl, Chip, Switch (accent track, dark knob), CodeView with line numbers and git gutter bars, DiffView, DataGrid (sticky header with name and type, PK/FK badges, sort arrow in accent), Toast, Sheet, CommandPalette.

## Mock data
Use the data from the artboards' `renderVals()` blocks:
- **Projects:** atlas-web, atlas-api, billing-service, ml-pipelines, ios-companion, dotfiles.
- **Hosts:** Development Server, Staging Server, Production Server, Prod Bastion, Build Runner, Home Lab.
- **Databases:** atlas_dev, atlas_staging, billing (MySQL), analytics.sqlite, atlas_prod_replica (error: timeout).
- **Docker:** db, redis, atlas-api, queue-worker.
- **Also:** the Claude Code and dev-server transcripts, the users and payments rows, the PaymentForm.tsx diff, commits and branches.

Never show real credentials. Use "Stored in Keychain", "•••" or a key *path* instead.
