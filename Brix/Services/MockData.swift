import SwiftUI

/// Sample workspace data, copied from the design artboards. Loaded by
/// "Load sample workspace" on first launch and used by the tests.
enum MockData {
    static let now = Date()
    static func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
    static let minute: TimeInterval = 60, hour: TimeInterval = 3600, day: TimeInterval = 86400

    // MARK: Projects

    static let projects: [Project] = [
        Project(id: "atlas-web", name: "atlas-web", path: "~/Developer/atlas-web", language: "TypeScript", framework: "Next.js 15 · TypeScript", hue: .violet, isPinned: true, lastOpened: ago(5 * minute), envVarNames: ["STRIPE_SECRET_KEY", "NEXT_PUBLIC_STRIPE_KEY", "DATABASE_URL"], isSample: true),
        Project(id: "atlas-api", name: "atlas-api", path: "~/Developer/atlas-api", language: "Go", framework: "Go 1.23 · chi", hue: .cyan, isPinned: true, lastOpened: ago(hour), envVarNames: ["DATABASE_URL", "STRIPE_WEBHOOK_SECRET"], isSample: true),
        Project(id: "billing-service", name: "billing-service", path: "~/Developer/billing-service", language: "PHP", framework: "Laravel 11 · PHP", hue: .orange, isPinned: false, lastOpened: ago(day), envVarNames: ["APP_KEY", "DB_PASSWORD"], isSample: true),
        Project(id: "ml-pipelines", name: "ml-pipelines", path: "~/Developer/ml-pipelines", language: "Python", framework: "Python 3.12 · Prefect", hue: .pink, isPinned: false, lastOpened: ago(2 * day), envVarNames: ["PREFECT_API_KEY"], isSample: true),
        Project(id: "ios-companion", name: "ios-companion", path: "~/Developer/ios-companion", language: "Swift", framework: "SwiftUI", hue: .blue, isPinned: false, lastOpened: ago(7 * day), isSample: true),
        Project(id: "dotfiles", name: "dotfiles", path: "~/dotfiles", language: "Shell", framework: "zsh · Homebrew", hue: .green, isPinned: false, lastOpened: ago(21 * day), isSample: true, mark: "DF")
    ]

    // MARK: Hosts

    static let hosts: [SSHHost] = [
        SSHHost(id: "dev", name: "Development Server", host: "dev.atlas.internal", user: "deploy", tag: .dev, notes: "Shared dev box. Runs the API and queue worker via compose in /srv/atlas.", os: "Ubuntu 24.04", lastConnected: ago(12 * minute), isSample: true),
        SSHHost(id: "staging", name: "Staging Server", host: "staging.atlas.io", user: "ubuntu", tag: .stage, notes: "Mirrors production config.", os: "Ubuntu 22.04", lastConnected: ago(2 * hour), isSample: true),
        SSHHost(id: "prod", name: "Production Server", host: "prod-web-01.atlas.io", user: "deploy", port: 2222, tag: .prod, notes: "Production. Read-only unless on call.", os: "Debian 12", lastConnected: ago(day), isSample: true),
        SSHHost(id: "bastion", name: "Prod Bastion", host: "bastion.atlas.io", user: "ec2-user", auth: .agent, keyPath: "", tag: .prod, notes: "Jump host for the production VPC.", os: "Amazon Linux 2023", lastConnected: ago(4 * day), isSample: true),
        SSHHost(id: "runner", name: "Build Runner", host: "ci-runner-03.internal", user: "ci", tag: .dev, os: "Ubuntu 24.04", lastConnected: ago(6 * hour), isSample: true),
        SSHHost(id: "homelab", name: "Home Lab", host: "nas.local", user: "admin", auth: .password, keyPath: "", tag: .personal, notes: "Synology NAS.", os: "DSM 7.2", lastConnected: ago(40 * minute), isSample: true)
    ]

    static let hostStatus: [ResourceID: ConnectionStatus] = [
        "dev": .connected, "staging": .idle, "prod": .disconnected, "bastion": .disconnected, "runner": .idle, "homelab": .connected
    ]

    static let metrics: [ResourceID: HostMetrics] = [
        "dev": HostMetrics(cpu: 0.34, memory: 0.61, disk: 0.48, load: "0.82 0.74 0.66", uptime: "41 days", os: "Ubuntu 24.04"),
        "staging": HostMetrics(cpu: 0.12, memory: 0.44, disk: 0.37, load: "0.21 0.30 0.28", uptime: "12 days", os: "Ubuntu 22.04"),
        "prod": HostMetrics(cpu: 0.58, memory: 0.72, disk: 0.66, load: "2.10 1.96 1.88", uptime: "88 days", os: "Debian 12"),
        "bastion": HostMetrics(cpu: 0.02, memory: 0.18, disk: 0.22, load: "0.01 0.02 0.00", uptime: "140 days", os: "Amazon Linux 2023"),
        "runner": HostMetrics(cpu: 0.81, memory: 0.52, disk: 0.73, load: "3.40 2.90 2.70", uptime: "6 days", os: "Ubuntu 24.04"),
        "homelab": HostMetrics(cpu: 0.08, memory: 0.39, disk: 0.84, load: "0.30 0.25 0.22", uptime: "63 days", os: "DSM 7.2")
    ]

    // MARK: Databases

    static let databases: [DatabaseConnection] = [
        DatabaseConnection(id: "atlas_dev", name: "atlas_dev", kind: .postgres, host: "localhost", port: 5432, database: "atlas_dev", user: "atlas", tag: .dev, lastUsed: ago(10 * minute), isSample: true),
        DatabaseConnection(id: "atlas_staging", name: "atlas_staging", kind: .postgres, host: "staging-db.atlas.io", port: 5432, database: "atlas", user: "atlas_ro", sslMode: .require, tunnelHostID: "staging", tag: .stage, lastUsed: ago(3 * hour), isSample: true),
        DatabaseConnection(id: "billing", name: "billing", kind: .mysql, host: "127.0.0.1", port: 3306, database: "billing", user: "root", tag: .dev, lastUsed: ago(day), isSample: true),
        DatabaseConnection(id: "analytics", name: "analytics.sqlite", kind: .sqlite, host: "", port: 0, database: "", user: "", filePath: "~/Developer/ml-pipelines/data/analytics.sqlite", tag: .local, lastUsed: ago(2 * day), isSample: true),
        DatabaseConnection(id: "atlas_prod_replica", name: "atlas_prod_replica", kind: .postgres, host: "replica.prod.atlas.io", port: 5432, database: "atlas", user: "readonly", sslMode: .require, tunnelHostID: "bastion", tag: .prod, readOnly: true, lastUsed: ago(5 * day), isSample: true)
    ]

    static let dbStatus: [ResourceID: ConnectionStatus] = [
        "atlas_dev": .connected, "atlas_staging": .idle, "billing": .connected, "analytics": .connected, "atlas_prod_replica": .error("timeout")
    ]

    // MARK: Docker

    static let docker: [DockerTarget] = [
        DockerTarget(id: "db", name: "db", image: "postgres:16", ports: ":5432", hostID: nil, composeProject: "atlas-web", state: .running, startedAt: ago(3 * hour), isSample: true),
        DockerTarget(id: "redis", name: "redis", image: "redis:7-alpine", ports: ":6379", hostID: nil, composeProject: "atlas-web", state: .running, startedAt: ago(3 * hour), isSample: true),
        DockerTarget(id: "atlas-api-c", name: "atlas-api", image: "ghcr.io/atlas/api:main", ports: ":8080", hostID: "dev", composeProject: "atlas", state: .running, startedAt: ago(2 * hour), isSample: true),
        DockerTarget(id: "queue-worker", name: "queue-worker", image: "ghcr.io/atlas/worker:main", ports: "", hostID: "dev", composeProject: "atlas", state: .exited, startedAt: nil, exitCode: 0, isSample: true)
    ]

    // MARK: Links (matches the Projects artboard resource counts)

    static var links: ProjectLinks {
        var l = ProjectLinks()
        for h in ["dev", "staging", "prod"] { l.link("atlas-web", h, kind: .host) }
        for d in ["atlas_dev", "atlas_staging"] { l.link("atlas-web", d, kind: .database) }
        for c in ["db", "redis", "atlas-api-c", "queue-worker"] { l.link("atlas-web", c, kind: .docker) }
        for h in ["dev", "prod", "bastion"] { l.link("atlas-api", h, kind: .host) }
        for d in ["atlas_dev", "atlas_prod_replica"] { l.link("atlas-api", d, kind: .database) }
        l.link("billing-service", "staging", kind: .host)
        l.link("billing-service", "billing", kind: .database)
        l.link("ml-pipelines", "runner", kind: .host)
        l.link("ml-pipelines", "analytics", kind: .database)
        l.link("dotfiles", "homelab", kind: .host)
        return l
    }

    // MARK: Git

    static func change(_ st: GitStatus, _ path: String, _ add: Int, _ del: Int, staged: Bool) -> GitFileChange {
        GitFileChange(path: path, status: st, add: add, del: del, staged: staged)
    }

    static let atlasWebCommits: [GitCommit] = [
        GitCommit(hash: "9f1c2ab4d7e0", message: "Add payment intent endpoint", author: "Supun", date: ago(2 * hour),
                  files: [change(.A, "src/app/api/payment-intent/route.ts", 38, 0, staged: false), change(.M, "src/lib/stripe/client.ts", 6, 2, staged: false)], isPushed: false),
        GitCommit(hash: "4e0d913c1a22", message: "Refactor cart totals into hook", author: "Supun", date: ago(5 * hour),
                  files: [change(.A, "src/lib/useCartTotals.ts", 31, 0, staged: false), change(.M, "src/components/CartSummary.tsx", 8, 27, staged: false)], isPushed: false),
        GitCommit(hash: "b7a2c01e9f43", message: "Merge PR #212 from atlas/fix-tax-rounding", author: "Maya Chen", date: ago(day),
                  files: [change(.M, "src/lib/tax.ts", 12, 9, staged: false)]),
        GitCommit(hash: "e33d7f0aa812", message: "Bump next to 15.1", author: "dependabot", date: ago(2 * day),
                  files: [change(.M, "package.json", 1, 1, staged: false), change(.M, "pnpm-lock.yaml", 88, 71, staged: false)]),
        GitCommit(hash: "1a9b4c2f0d31", message: "Checkout skeleton states", author: "Supun", date: ago(3 * day),
                  files: [change(.A, "src/app/checkout/loading.tsx", 22, 0, staged: false)]),
        GitCommit(hash: "70cc8e1b5e66", message: "Add CLAUDE.md with agent conventions", author: "Supun", date: ago(4 * day),
                  files: [change(.A, "CLAUDE.md", 46, 0, staged: false)])
    ]

    static var git: [ProjectID: GitRepoState] {
        [
            "atlas-web": GitRepoState(
                branch: "feat/checkout-v2", ahead: 2, behind: 0,
                changes: [
                    change(.A, "src/lib/stripe/intent.ts", 24, 0, staged: true),
                    change(.M, "src/components/PaymentForm.tsx", 24, 6, staged: true),
                    change(.M, "src/app/checkout/page.tsx", 9, 3, staged: false),
                    change(.D, "src/lib/legacy/cart.ts", 0, 58, staged: false),
                    change(.M, "package.json", 2, 1, staged: false),
                    change(.M, "pnpm-lock.yaml", 41, 12, staged: false),
                    change(.U, "src/app/checkout/success/page.tsx", 18, 0, staged: false)
                ],
                commits: atlasWebCommits,
                branches: [
                    GitBranch(name: "feat/checkout-v2", isCurrent: true, lastCommit: "2 h"),
                    GitBranch(name: "main", isCurrent: false, lastCommit: "2 d"),
                    GitBranch(name: "fix/tax-rounding", isCurrent: false, lastCommit: "1 d"),
                    GitBranch(name: "chore/deps", isCurrent: false, lastCommit: "6 d")
                ]),
            "atlas-api": GitRepoState(branch: "main", ahead: 0, behind: 0, changes: [],
                commits: [GitCommit(hash: "5d21e7a9c0b4", message: "Add payment_intents migration", author: "Supun", date: ago(hour)),
                          GitCommit(hash: "aa04c3b18e27", message: "chi: request id middleware", author: "Supun", date: ago(day))],
                branches: [GitBranch(name: "main", isCurrent: true, lastCommit: "1 h")]),
            "billing-service": GitRepoState(branch: "fix/invoice-rounding", ahead: 0, behind: 1,
                changes: [change(.M, "app/Services/InvoiceTotals.php", 14, 6, staged: false), change(.M, "tests/Unit/InvoiceTotalsTest.php", 22, 0, staged: false)],
                commits: [GitCommit(hash: "c19e2d4a8b10", message: "Round tax per invoice", author: "Supun", date: ago(day))],
                branches: [GitBranch(name: "fix/invoice-rounding", isCurrent: true, lastCommit: "1 d"), GitBranch(name: "main", isCurrent: false, lastCommit: "3 d")]),
            "ml-pipelines": GitRepoState(branch: "develop", ahead: 0, behind: 0,
                changes: [change(.M, "flows/daily_rollup.py", 7, 2, staged: false)],
                commits: [GitCommit(hash: "f0e1d2c3b4a5", message: "Daily rollup: skip empty partitions", author: "Supun", date: ago(2 * day))],
                branches: [GitBranch(name: "develop", isCurrent: true, lastCommit: "2 d"), GitBranch(name: "main", isCurrent: false, lastCommit: "1 wk")]),
            "ios-companion": GitRepoState(branch: "release/2.4", ahead: 0, behind: 0, changes: [],
                commits: [GitCommit(hash: "0b1c2d3e4f50", message: "Bump build to 2.4 (118)", author: "Supun", date: ago(7 * day))],
                branches: [GitBranch(name: "release/2.4", isCurrent: true, lastCommit: "1 wk"), GitBranch(name: "main", isCurrent: false, lastCommit: "2 wk")]),
            "dotfiles": GitRepoState(branch: "main", ahead: 0, behind: 0, changes: [],
                commits: [GitCommit(hash: "9a8b7c6d5e4f", message: "zsh: faster prompt", author: "Supun", date: ago(21 * day))],
                branches: [GitBranch(name: "main", isCurrent: true, lastCommit: "3 wk")])
        ]
    }

    // MARK: Diffs

    static let paymentFormDiff: FileDiff = {
        typealias R = (DiffLineKind, Int?, Int?, String)
        let raw: [R] = [
            (.hunk, nil, nil, "@@ -1,22 +1,40 @@ \"use client\";"),
            (.context, 1, 1, "\"use client\";"),
            (.context, 2, 2, ""),
            (.del, 3, nil, "import { Elements, PaymentElement } from \"@stripe/react-stripe-js\";"),
            (.add, nil, 3, "import { useEffect, useState } from \"react\";"),
            (.add, nil, 4, "import {"),
            (.add, nil, 5, "  Elements,"),
            (.add, nil, 6, "  PaymentElement,"),
            (.add, nil, 7, "  PaymentRequestButtonElement,"),
            (.add, nil, 8, "  useStripe,"),
            (.add, nil, 9, "} from \"@stripe/react-stripe-js\";"),
            (.context, 4, 10, "import { stripePromise } from \"@/lib/stripe/client\";"),
            (.context, 5, 11, ""),
            (.del, 6, nil, "type Props = { clientSecret: string };"),
            (.add, nil, 12, "type Props = { clientSecret: string; amount: number };"),
            (.context, 7, 13, ""),
            (.del, 8, nil, "export function PaymentForm({ clientSecret }: Props) {"),
            (.add, nil, 14, "export function PaymentForm({ clientSecret, amount }: Props) {"),
            (.context, 9, 15, "  return ("),
            (.context, 10, 16, "    <Elements stripe={stripePromise} options={{ clientSecret }}>"),
            (.add, nil, 17, "      <WalletButtons amount={amount} />"),
            (.context, 11, 18, "      <PaymentElement options={{ layout: \"accordion\" }} />"),
            (.context, 12, 19, "    </Elements>"),
            (.hunk, nil, nil, "@@ -24,0 +42,18 @@ export function PaymentForm"),
            (.add, nil, 42, "function WalletButtons({ amount }: { amount: number }) {"),
            (.add, nil, 43, "  const stripe = useStripe();"),
            (.add, nil, 44, "  const [request, setRequest] = useState<PaymentRequest | null>(null);"),
            (.add, nil, 45, "  useEffect(() => {"),
            (.add, nil, 46, "    if (!stripe) return;"),
            (.add, nil, 47, "    const pr = stripe.paymentRequest({ country: \"GB\", currency: \"gbp\","),
            (.add, nil, 48, "      total: { label: \"Atlas booking\", amount } });"),
            (.add, nil, 49, "    pr.canMakePayment().then((r) => r?.applePay && setRequest(pr));"),
            (.add, nil, 50, "  }, [stripe, amount]);")
        ]
        return FileDiff(path: "src/components/PaymentForm.tsx", add: 24, del: 6,
                        lines: raw.map { DiffLine(kind: $0.0, old: $0.1, new: $0.2, text: $0.3) })
    }()

    /// A believable diff for any other changed file.
    static func syntheticDiff(for change: GitFileChange) -> FileDiff {
        if change.path.hasSuffix("PaymentForm.tsx") { return paymentFormDiff }
        var lines: [DiffLine] = [DiffLine(kind: .hunk, old: nil, new: nil, text: "@@ -1,\(max(change.del, 1)) +1,\(max(change.add, 1)) @@")]
        let name = change.name
        var n = 1
        for i in 0..<min(change.del, 12) {
            lines.append(DiffLine(kind: .del, old: i + 1, new: nil, text: "// \(name): previous line \(i + 1)"))
        }
        for i in 0..<min(change.add, 16) {
            lines.append(DiffLine(kind: .add, old: nil, new: n, text: "// \(name): new line \(i + 1)"))
            n += 1
        }
        if change.add > 16 || change.del > 12 {
            lines.append(DiffLine(kind: .hunk, old: nil, new: nil, text: "… \(change.add + change.del - min(change.add, 16) - min(change.del, 12)) more lines"))
        }
        return FileDiff(path: change.path, add: change.add, del: change.del, lines: lines)
    }

    // MARK: Files (atlas-web)

    static func tree(for project: ProjectID) -> [FileNode] {
        let paths: [String]
        switch project {
        case "atlas-web":
            paths = ["src/app/checkout/success/page.tsx", "src/app/checkout/page.tsx", "src/app/checkout/loading.tsx", "src/app/layout.tsx",
                     "src/app/api/payment-intent/route.ts",
                     "src/components/CartSummary.tsx", "src/components/PaymentForm.tsx",
                     "src/lib/legacy/cart.ts", "src/lib/stripe/intent.ts", "src/lib/stripe/client.ts", "src/lib/useCartTotals.ts", "src/lib/tax.ts",
                     "public/logo.png", "public/favicon.ico", "docs/checkout.md",
                     ".env.local", "CLAUDE.md", "docker-compose.yml", "package.json", "pnpm-lock.yaml", "tsconfig.json"]
        case "atlas-api":
            paths = ["cmd/api/main.go", "internal/payments/handler.go", "internal/payments/handler_test.go", "internal/payments/store.go",
                     "migrations/0012_payment_intents.sql", "go.mod", "go.sum", "Dockerfile", "README.md", "CLAUDE.md"]
        case "billing-service":
            paths = ["app/Services/InvoiceTotals.php", "app/Http/Controllers/InvoiceController.php", "tests/Unit/InvoiceTotalsTest.php",
                     "routes/web.php", "composer.json", ".env.example", "README.md"]
        case "ml-pipelines":
            paths = ["flows/daily_rollup.py", "flows/__init__.py", "data/analytics.sqlite", "pyproject.toml", "README.md"]
        case "ios-companion":
            paths = ["Companion/App.swift", "Companion/BookingView.swift", "Companion/Assets.xcassets/Contents.json", "Package.swift", "README.md"]
        default:
            paths = [".zshrc", ".gitconfig", "Brewfile", "install.sh", "README.md"]
        }
        let status = Dictionary(git[project]?.changes.map { ($0.path, $0.status) } ?? [], uniquingKeysWith: { a, _ in a })
        return buildTree(paths: paths, status: status)
    }

    static func buildTree(paths: [String], status: [String: GitStatus]) -> [FileNode] {
        final class Box { var name: String; var path: String; var dir: Bool; var kids: [String: Box] = [:]
            init(_ n: String, _ p: String, _ d: Bool) { name = n; path = p; dir = d } }
        let root = Box("", "", true)
        for p in paths {
            var cur = root
            let comps = p.split(separator: "/").map(String.init)
            for (i, c) in comps.enumerated() {
                let sub = comps[0...i].joined(separator: "/")
                if cur.kids[c] == nil { cur.kids[c] = Box(c, sub, i < comps.count - 1) }
                cur = cur.kids[c]!
            }
        }
        func convert(_ b: Box) -> FileNode {
            let kids = b.kids.values.sorted { ($0.dir ? 0 : 1, $0.name.lowercased()) < ($1.dir ? 0 : 1, $1.name.lowercased()) }.map(convert)
            var st = status[b.path]
            if b.dir {
                // Folder shows a status when everything inside shares it (matches the artboard).
                let inner = status.filter { $0.key.hasPrefix(b.path + "/") }.map(\.value)
                if !inner.isEmpty { st = Set(inner).count == 1 ? inner[0] : .M }
            }
            return FileNode(name: b.name, path: b.path, isDirectory: b.dir, children: b.dir ? kids : nil, gitStatus: st)
        }
        return convert(root).children ?? []
    }

    static func content(project: ProjectID, path: String) -> FileContent {
        if path.hasSuffix(".png") || path.hasSuffix(".ico") {
            let img = NSImage(systemSymbolName: "photo", accessibilityDescription: nil) ?? NSImage()
            return .image(img, size: CGSize(width: 512, height: 512))
        }
        if path.hasSuffix(".sqlite") { return .binary(size: 4_718_592) }
        if let text = files[path] { return .text(text) }
        let name = (path as NSString).lastPathComponent
        return .text(placeholderSource(name: name))
    }

    static func placeholderSource(name: String) -> String {
        switch (name as NSString).pathExtension {
        case "go": return "package payments\n\nimport (\n\t\"context\"\n\t\"net/http\"\n)\n\n// Handler serves payment intent routes.\ntype Handler struct {\n\tstore Store\n}\n\nfunc (h *Handler) Create(w http.ResponseWriter, r *http.Request) {\n\tctx := context.Background()\n\tintent, err := h.store.CreateIntent(ctx, 1200)\n\tif err != nil {\n\t\thttp.Error(w, err.Error(), 500)\n\t\treturn\n\t}\n\twriteJSON(w, intent)\n}\n"
        case "py": return "from prefect import flow, task\n\n\n@task(retries=2)\ndef load_partition(day: str) -> int:\n    \"\"\"Load one day of events.\"\"\"\n    return 0\n\n\n@flow(name=\"daily-rollup\")\ndef daily_rollup(days: int = 7):\n    for d in range(days):\n        if load_partition(str(d)) == 0:\n            continue\n"
        case "php": return "<?php\n\nnamespace App\\Services;\n\nclass InvoiceTotals\n{\n    public function tax(int $cents, float $rate): int\n    {\n        // Round per invoice, not per line.\n        return (int) round($cents * $rate);\n    }\n}\n"
        case "swift": return "import SwiftUI\n\nstruct BookingView: View {\n    @State private var count = 0\n\n    var body: some View {\n        Text(\"Bookings: \\(count)\")\n            .padding()\n    }\n}\n"
        case "sql": return "-- 0012 payment intents\nCREATE TABLE payment_intents (\n  id BIGSERIAL PRIMARY KEY,\n  booking_id BIGINT NOT NULL REFERENCES bookings(id),\n  amount_cents INTEGER NOT NULL,\n  status TEXT NOT NULL DEFAULT 'pending',\n  created_at TIMESTAMPTZ NOT NULL DEFAULT now()\n);\n"
        case "md": return "# \(name)\n\nNotes for this project.\n\n- Run `pnpm dev`\n- Tests: `pnpm test`\n"
        case "json": return "{\n  \"name\": \"example\",\n  \"version\": \"1.0.0\"\n}\n"
        case "yml", "yaml": return "version: 1\nitems:\n  - one\n  - two\n"
        case "sh": return "#!/usr/bin/env bash\nset -euo pipefail\n\necho \"Linking dotfiles\"\nln -sf \"$PWD/.zshrc\" ~/.zshrc\n"
        default: return "# \(name)\n"
        }
    }

    static let files: [String: String] = [
        "src/components/PaymentForm.tsx": """
        "use client";

        import { useEffect, useState } from "react";
        import {
          Elements,
          PaymentElement,
          PaymentRequestButtonElement,
          useStripe,
        } from "@stripe/react-stripe-js";
        import type { PaymentRequest } from "@stripe/stripe-js";
        import { stripePromise } from "@/lib/stripe/client";

        type Props = { clientSecret: string; amount: number };

        export function PaymentForm({ clientSecret, amount }: Props) {
          return (
            <Elements stripe={stripePromise} options={{ clientSecret }}>
              <WalletButtons amount={amount} />
              <PaymentElement options={{ layout: "accordion" }} />
            </Elements>
          );
        }

        function WalletButtons({ amount }: { amount: number }) {
          const stripe = useStripe();
          const [request, setRequest] = useState<PaymentRequest | null>(null);

          useEffect(() => {
            if (!stripe) return;
            const pr = stripe.paymentRequest({
              country: "GB",
              currency: "gbp",
              total: { label: "Atlas booking", amount },
            });
            pr.canMakePayment().then((r) => r?.applePay && setRequest(pr));
          }, [stripe, amount]);

          if (!request) return null;
          return <PaymentRequestButtonElement options={{ paymentRequest: request }} />;
        }

        """,
        "src/lib/stripe/intent.ts": """
        import Stripe from "stripe";

        const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
          apiVersion: "2024-12-18.acacia",
        });

        export type IntentInput = {
          amount: number;
          currency: string;
          metadata?: Record<string, string>;
        };

        export async function createPaymentIntent({ amount, currency, metadata }: IntentInput) {
          const intent = await stripe.paymentIntents.create({
            amount, currency, metadata,
            automatic_payment_methods: { enabled: true },
          });
          return { id: intent.id, clientSecret: intent.client_secret! };
        }

        """,
        "src/app/checkout/page.tsx": """
        import { PaymentForm } from "@/components/PaymentForm";
        import { CartSummary } from "@/components/CartSummary";
        import { createPaymentIntent } from "@/lib/stripe/intent";

        export default async function CheckoutPage() {
          const amount = 12400;
          // Server-side intent only: the secret never reaches the client bundle.
          const { clientSecret } = await createPaymentIntent({ amount, currency: "gbp" });
          return (
            <main className="checkout">
              <CartSummary />
              <PaymentForm clientSecret={clientSecret} amount={amount} />
            </main>
          );
        }

        """,
        "CLAUDE.md": """
        # atlas-web agent conventions

        - Use **pnpm**, never npm.
        - Server-side Stripe calls only; never expose secret keys.
        - Run `pnpm test` before proposing a commit.

        ## Layout

        | Folder | Purpose |
        |---|---|
        | `src/app` | Next.js routes |
        | `src/lib` | Shared helpers |

        """,
        "docker-compose.yml": """
        services:
          db:
            image: postgres:16
            ports:
              - "5432:5432"
            environment:
              POSTGRES_DB: atlas_dev
          redis:
            image: redis:7-alpine
            ports:
              - "6379:6379"

        """,
        "package.json": """
        {
          "name": "atlas-web",
          "private": true,
          "scripts": {
            "dev": "next dev --turbopack",
            "build": "next build",
            "test": "vitest run"
          },
          "dependencies": {
            "next": "15.1.2",
            "react": "19.0.0",
            "@stripe/react-stripe-js": "^3.1.0",
            "stripe": "^17.5.0"
          }
        }

        """,
        "tsconfig.json": """
        {
          "compilerOptions": {
            "strict": true,
            "paths": { "@/*": ["./src/*"] }
          }
        }

        """,
        ".env.local": "STRIPE_SECRET_KEY=•••\nNEXT_PUBLIC_STRIPE_KEY=•••\nDATABASE_URL=•••\n"
    ]

    // MARK: Sessions

    static func span(_ t: String, _ c: Color = Theme.body, bold: Bool = false) -> TermSpan { TermSpan(text: t, color: c, bold: bold) }

    static var sessions: [TerminalSession] {
        [
            TerminalSession(id: "s-claude-aw", projectID: "atlas-web", title: "Claude Code", kind: .agent, cwd: "~/Developer/atlas-web", state: .running, process: "claude", startedAt: ago(26 * minute),
                            lines: claudeAtlasWebTranscript,
                            plan: [PlanItem(title: "Server-side PaymentIntent helper", done: true),
                                   PlanItem(title: "Pass client secret from checkout page", done: true),
                                   PlanItem(title: "Render wallet button when Apple Pay is available", done: false),
                                   PlanItem(title: "Success route and tests", done: false)],
                            touched: [FileTouch(path: "src/lib/stripe/intent.ts", add: 24, del: 0),
                                      FileTouch(path: "src/components/PaymentForm.tsx", add: 24, del: 6),
                                      FileTouch(path: "src/app/checkout/page.tsx", add: 9, del: 3)],
                            lastOutput: "⏺ Update(src/components/PaymentForm.tsx)\n  ⎿ +24 −6   ✶ Wiring wallet buttons… 48s",
                            progress: 0.5, task: "add Apple Pay to the checkout flow, server-side intent only"),
            TerminalSession(id: "s-dev-aw", projectID: "atlas-web", title: "dev server", kind: .shell, cwd: "~/Developer/atlas-web", state: .running, process: "pnpm dev", startedAt: ago(48 * minute),
                            lines: devServerTranscript, lastOutput: "✓ Ready in 1182ms\nGET /checkout 200 in 41ms", progress: 1),
            TerminalSession(id: "s-zsh-aw", projectID: "atlas-web", title: "zsh", kind: .shell, cwd: "~/Developer/atlas-web", state: .idle, process: "zsh", startedAt: ago(30 * minute),
                            lines: [promptLine(project: "atlas-web", branch: "feat/checkout-v2")]),
            TerminalSession(id: "s-claude-aa", projectID: "atlas-api", title: "Claude Code", kind: .agent, cwd: "~/Developer/atlas-api", state: .needsInput, process: "claude", startedAt: ago(hour),
                            lines: claudeAtlasApiTranscript,
                            plan: [PlanItem(title: "Add payment_intents migration", done: true), PlanItem(title: "Booking foreign key", done: true), PlanItem(title: "Wire HTTP handler", done: false)],
                            touched: [FileTouch(path: "migrations/0012_payment_intents.sql", add: 9, del: 0)],
                            lastOutput: "Done. Migration adds payment_intents.\nWant me to wire the handler next?", progress: 1,
                            task: "add a payment_intents table linked to bookings"),
            TerminalSession(id: "s-tests-aa", projectID: "atlas-api", title: "tests", kind: .shell, cwd: "~/Developer/atlas-api", state: .idle, process: "zsh", startedAt: ago(2 * hour),
                            lines: [TermLine([span("❯ ", Theme.text3), span("go test ./...")]), TermLine("ok  \tatlas-api/internal/payments\t0.412s", Theme.green), TermLine("ok  \tatlas-api/internal/bookings\t0.207s", Theme.green)]),
            TerminalSession(id: "s-logs-dev", hostID: "dev", title: "api logs", kind: .logs, cwd: "/srv/atlas", state: .running, process: "tail -f /var/log/atlas/api.log", startedAt: ago(12 * minute),
                            lines: apiLogTranscript, lastOutput: "08:41:07 WARN slow query table=audit_log\n08:41:12 ERROR stripe webhook signature", progress: 0.7),
            TerminalSession(id: "s-htop-dev", hostID: "dev", title: "htop", kind: .server, cwd: "/srv/atlas", state: .running, process: "htop", startedAt: ago(9 * minute),
                            lines: htopTranscript),
            TerminalSession(id: "s-nas", hostID: "homelab", title: "nas", kind: .server, cwd: "/volume1", state: .idle, process: "bash", startedAt: ago(40 * minute),
                            lines: [TermLine([span("admin@nas", Theme.green), span(":", Theme.text3), span("/volume1", Theme.cyan), span(" $ ", Theme.text3)])])
        ]
    }

    static func promptLine(project: String, branch: String) -> TermLine {
        TermLine([span(project, Theme.cyan), span(" on ", Theme.text3), span("⎇ \(branch)", Theme.violet), span(" ❯ ", Color(hex: 0xC8F560))])
    }

    static var claudeAtlasWebTranscript: [TermLine] {
        [
            TermLine([span("✻ ", Theme.violet), span("Claude Code", Theme.text, bold: true), span("  ~/Developer/atlas-web", Theme.meta)]),
            TermLine(""),
            TermLine([span("> ", Theme.violet), span("add Apple Pay to the checkout flow, server-side intent only", Theme.text)]),
            TermLine(""),
            TermLine([span("⏺ ", Theme.green), span("I'll start by reading the checkout page and payment form.")]),
            TermLine([span("⏺ ", Theme.green), span("Read", Theme.text, bold: true), span("(src/app/checkout/page.tsx)", Theme.text3)]),
            TermLine([span("  ⎿ Read 41 lines", Theme.text3)]),
            TermLine([span("⏺ ", Theme.green), span("Write", Theme.text, bold: true), span("(src/lib/stripe/intent.ts)", Theme.text3), span("  +24", Theme.green)]),
            TermLine([span("  ⎿ Wrote 24 lines", Theme.text3)]),
            TermLine([span("⏺ ", Theme.amber), span("Update", Theme.text, bold: true), span("(src/components/PaymentForm.tsx)", Theme.text3), span("  +24", Theme.green), span(" −6", Theme.red)]),
            TermLine([span("  18 ", Theme.lineNumber), span("+ const [request, setRequest] = useState<PaymentRequest | null>(null);", Theme.diffAddText)]),
            TermLine([span("  19 ", Theme.lineNumber), span("+ useEffect(() => {", Theme.diffAddText)]),
            TermLine([span("  20 ", Theme.lineNumber), span("+   if (!stripe) return;", Theme.diffAddText)]),
            TermLine([span("⏺ ", Theme.green), span("Bash", Theme.text, bold: true), span("(pnpm test src/lib/stripe)", Theme.text3)]),
            TermLine([span("  ⎿ ", Theme.text3), span("✓ 3 tests passed", Theme.green), span(" (22ms)", Theme.text3)]),
            TermLine(""),
            TermLine([span("☒ ", Theme.green), span("Server-side PaymentIntent helper", Theme.text3)]),
            TermLine([span("☒ ", Theme.green), span("Pass client secret from checkout page", Theme.text3)]),
            TermLine([span("☐ ", Theme.amber), span("Render PaymentRequestButton when Apple Pay is available")]),
            TermLine([span("☐ ", Theme.lineNumber), span("Add success route tests")]),
            TermLine(""),
            TermLine([span("✶ Wiring wallet buttons…", Theme.violet), span("  48s · ↓ 2.1k tokens · esc to interrupt", Theme.meta)])
        ]
    }

    static var claudeAtlasApiTranscript: [TermLine] {
        [
            TermLine([span("✻ ", Theme.violet), span("Claude Code", Theme.text, bold: true), span("  ~/Developer/atlas-api", Theme.meta)]),
            TermLine(""),
            TermLine([span("> ", Theme.violet), span("add a payment_intents table linked to bookings", Theme.text)]),
            TermLine([span("⏺ ", Theme.green), span("Write", Theme.text, bold: true), span("(migrations/0012_payment_intents.sql)", Theme.text3), span("  +9", Theme.green)]),
            TermLine([span("⏺ ", Theme.green), span("Bash", Theme.text, bold: true), span("(go test ./internal/payments/...)", Theme.text3)]),
            TermLine([span("  ⎿ ", Theme.text3), span("ok  internal/payments  0.412s", Theme.green)]),
            TermLine(""),
            TermLine([span("⏺ ", Theme.text), span("Done. Migration adds payment_intents with a booking FK.")]),
            TermLine([span("  Want me to wire the HTTP handler next?")]),
            TermLine([span("▍", Theme.amber)])
        ]
    }

    static var devServerTranscript: [TermLine] {
        [
            promptLine(project: "atlas-web", branch: "feat/checkout-v2").appending(span("pnpm dev", Theme.text)),
            TermLine([span("  ▲ Next.js 15.1.2", Theme.text, bold: true), span(" (Turbopack)", Theme.text3)]),
            TermLine([span("  - Local:        http://localhost:3000")]),
            TermLine([span(" ✓ ", Theme.green), span("Starting…")]),
            TermLine([span(" ✓ ", Theme.green), span("Ready in 1182ms")]),
            TermLine([span(" ○ Compiling /checkout …", Theme.text3)]),
            TermLine([span(" GET", Theme.blue), span(" /checkout "), span("200", Theme.green), span(" in 312ms", Theme.text3)]),
            TermLine([span(" POST", Theme.violet), span(" /api/payment-intent "), span("200", Theme.green), span(" in 488ms", Theme.text3)]),
            TermLine([span(" ⚠ ", Theme.amber), span("Fast Refresh had to perform a full reload", Theme.amber)]),
            TermLine([span(" ✓ ", Theme.green), span("Compiled in 164ms", Theme.text3)])
        ]
    }

    static var apiLogTranscript: [TermLine] {
        let rows: [(String, String, Color, String)] = [
            ("08:41:02", "INFO ", Theme.text3, "request  GET  /v1/bookings          200   18ms"),
            ("08:41:03", "INFO ", Theme.text3, "request  POST /v1/payment-intents   201  412ms"),
            ("08:41:07", "WARN ", Theme.amber, "slow query  table=audit_log  842ms  rows=9"),
            ("08:41:09", "INFO ", Theme.text3, "request  GET  /healthz              200    1ms"),
            ("08:41:12", "ERROR", Theme.red, "stripe webhook  signature mismatch  evt_1Q…"),
            ("08:41:15", "INFO ", Theme.text3, "request  GET  /v1/users/me          200    9ms"),
            ("08:41:18", "INFO ", Theme.text3, "request  GET  /v1/bookings?page=2   200   22ms"),
            ("08:41:21", "INFO ", Theme.text3, "cache    warm  keys=1,204  41ms"),
            ("08:41:24", "INFO ", Theme.text3, "request  POST /v1/bookings          201   64ms")
        ]
        return [TermLine([span("deploy@dev", Theme.green), span(":", Theme.text3), span("/srv/atlas", Theme.cyan), span(" ❯ ", Color(hex: 0xC8F560)), span("tail -f /var/log/atlas/api.log")])]
            + rows.map { TermLine([span($0.0 + " ", Theme.meta), span($0.1 + " ", $0.2, bold: $0.1 != "INFO "), span($0.3, $0.1 == "ERROR" ? Theme.diffDelText : Theme.body)]) }
    }

    static var htopTranscript: [TermLine] {
        [
            TermLine("  CPU[||||||||||          34.0%]   Mem[||||||||||||||   2.4G/3.9G]", Theme.green),
            TermLine("  Load average: 0.82 0.74 0.66   Uptime: 41 days, 03:12:44", Theme.text3),
            TermLine(""),
            TermLine("  PID USER     CPU%  MEM%  Command", Theme.text, bold: true),
            TermLine(" 1824 deploy   12.4   7.8  atlas-api"),
            TermLine(" 1931 postgres  4.1   4.7  postgres: atlas"),
            TermLine("  902 root      0.7   0.9  dockerd")
        ]
    }
}

extension TermLine {
    func appending(_ s: TermSpan) -> TermLine {
        var c = self
        c.spans.append(s)
        return c
    }
}
