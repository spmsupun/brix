import SwiftUI
import AppKit

/// Lazy data grid: sticky header (name, type, PK/FK, sort arrow), row numbers,
/// NULL dimmed and italic, horizontal scrolling. Smooth at 10k rows.
struct DataGrid: View {
    let columns: [DBColumn]
    let rows: [[String?]]
    var hidden: Set<String> = []
    var sort: (column: String, ascending: Bool)? = nil
    var onSort: ((String) -> Void)? = nil
    var rowOffset = 0
    var selectedRow: Int? = nil
    var onSelect: ((Int) -> Void)? = nil
    @Environment(\.accent) private var accent

    private var visible: [(Int, DBColumn)] {
        columns.enumerated().filter { !hidden.contains($0.element.name) }.map { ($0.offset, $0.element) }
    }

    static func width(_ c: DBColumn) -> CGFloat {
        let t = c.type.lowercased()
        if c.name.hasSuffix("_at") || t.contains("timestamp") || t.contains("date") { return 170 }
        if t.contains("uuid") { return 120 }
        if c.name.contains("email") || t.contains("varchar(255)") { return 230 }
        if t.contains("int") || t.contains("numeric") || t.contains("bool") { return 110 }
        if c.name == "QUERY PLAN" { return 900 }
        return max(110, min(240, CGFloat(c.name.count) * 9 + 40))
    }

    static func mono(_ c: DBColumn) -> Bool {
        let t = c.type.lowercased()
        return t.contains("uuid") || t.contains("time") || t.contains("int") || t.contains("numeric") || t.contains("date") || c.isPK || c.fk != nil
    }

    var body: some View {
        let cols = visible
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                        HStack(spacing: 0) {
                            Text("\(rowOffset + i + 1)").font(Typo.mono(10.5)).foregroundStyle(Theme.lineNumber)
                                .frame(width: 44, alignment: .trailing).padding(.trailing, 8)
                            ForEach(cols, id: \.0) { idx, c in
                                cell(idx < r.count ? r[idx] : nil, c)
                            }
                        }
                        .frame(height: 30)
                        .background(selectedRow == i ? Color.white(0.05) : .clear)
                        .overlay(alignment: .leading) { if selectedRow == i { Rectangle().fill(accent).frame(width: 2) } }
                        .overlay(alignment: .bottom) { Rectangle().fill(Color.white(0.04)).frame(height: 1) }
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect?(i) }
                        .contextMenu {
                            Button("Copy Row") { copy(cols.map { idx, _ in idx < r.count ? (r[idx] ?? "NULL") : "" }.joined(separator: "\t")) }
                            Button("Copy as JSON") { copyJSON(r) }
                        }
                    }
                } header: {
                    header(cols)
                }
            }
            .textSelection(.enabled)
        }
        .defaultScrollAnchor(.topLeading)
        .background(Theme.editor)
    }

    private func header(_ cols: [(Int, DBColumn)]) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 52)
            ForEach(cols, id: \.0) { _, c in
                Button { onSort?(c.name) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(c.name).font(Typo.ui(12, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                            if c.isPK { KeyBadge(text: "PK", color: Theme.amber) }
                            if c.fk != nil { KeyBadge(text: "FK", color: Theme.blue) }
                            Spacer(minLength: 0)
                            if sort?.column == c.name {
                                Image(systemName: sort!.ascending ? "arrow.up" : "arrow.down").font(.system(size: 9, weight: .bold)).foregroundStyle(accent)
                            }
                        }
                        Text(c.type).font(Typo.mono(10)).foregroundStyle(Theme.meta).lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .frame(width: Self.width(c), height: 40, alignment: .leading)
                    .overlay(alignment: .trailing) { Rectangle().fill(Color.white(0.05)).frame(width: 1) }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(c.fk.map { "References \($0)" } ?? "Sort by \(c.name)")
                .accessibilityLabel("\(c.name), \(c.type)\(sort?.column == c.name ? (sort!.ascending ? ", sorted ascending" : ", sorted descending") : "")")
            }
        }
        .background(Theme.island)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    private func cell(_ v: String?, _ c: DBColumn) -> some View {
        Group {
            if let v {
                Text(v.count > 300 ? String(v.prefix(300)) + "…" : v)
                    .font(Self.mono(c) ? Typo.mono(11.5) : Typo.ui(12.5))
                    .foregroundStyle(c.type == "user_role" ? Theme.agentText : Theme.text)
            } else {
                Text("NULL").font(Typo.mono(11.5).italic()).foregroundStyle(Theme.disabled)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(width: Self.width(c), height: 30, alignment: .leading)
        .overlay(alignment: .trailing) { Rectangle().fill(Color.white(0.04)).frame(width: 1) }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func copyJSON(_ r: [String?]) {
        var obj: [String: Any] = [:]
        for (i, c) in columns.enumerated() where i < r.count { obj[c.name] = r[i] ?? NSNull() }
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]), let s = String(data: d, encoding: .utf8) { copy(s) }
    }

    /// RFC 4180 CSV.
    static func csv(columns: [DBColumn], rows: [[String?]]) -> String {
        func esc(_ s: String) -> String {
            s.contains(",") || s.contains("\"") || s.contains("\n") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        var out = columns.map { esc($0.name) }.joined(separator: ",") + "\n"
        for r in rows { out += r.map { esc($0 ?? "") }.joined(separator: ",") + "\n" }
        return out
    }
}
