import SwiftUI
import AppKit

/// The data grid for table and console tabs: a native NSTableView, so only the
/// rows on screen exist and switching tabs or scrolling stays light. Row-number
/// gutter, typed headers with PK / FK marks and a sort arrow, staged-edit tints,
/// inline data bars, click to select, double-click or Return to edit.
struct DWGrid: NSViewRepresentable {
    enum RowState { case normal, inserted, deleted }

    let columns: [DBColumn]
    let rowCount: Int
    let value: (Int, Int) -> String?
    var rowState: (Int) -> RowState = { _ in .normal }
    /// The columns with a staged edit in a row.
    var edited: (Int) -> Set<Int> = { _ in [] }
    var rowOffset = 0
    var selection: DWCell?
    var sort: (column: String, ascending: Bool)?
    var barColumn: Int?
    var editable = false
    var onSelect: (DWCell) -> Void = { _ in }
    var onEdit: ((DWCell, String?) -> Void)?
    var onSort: ((String) -> Void)?
    var fkCell: DWCell?
    var fkContent: ((DWCell) -> AnyView)?
    var onFKDismiss: () -> Void = {}

    @Environment(\.accent) private var accent
    @Environment(AppStore.self) private var store

    static let gutter: CGFloat = 44
    static let rowHeight: CGFloat = 26

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = GridTable()
        table.coordinator = context.coordinator
        table.style = .plain
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.gridStyleMask = []
        table.selectionHighlightStyle = .none
        table.allowsColumnReordering = false
        table.allowsColumnResizing = true
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.backgroundColor = GridInk.island
        table.headerView = GridHeader()
        table.headerView?.frame.size.height = 30
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.action = #selector(Coordinator.clicked)
        table.doubleAction = #selector(Coordinator.doubleClicked)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = true
        scroll.backgroundColor = GridInk.island
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // The accent is a plain colour (not a light/dark one), so converting it is safe.
        context.coordinator.update(self, accent: NSColor(accent).usingColorSpace(.sRGB) ?? .systemGreen, store: store)
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSPopoverDelegate, NSTextFieldDelegate {
        var grid: DWGrid?
        weak var table: GridTable?
        var accent = NSColor.systemGreen
        weak var store: AppStore?
        private var signature = ""
        private var popover: NSPopover?
        private var popoverCell: DWCell?
        private var editor: NSTextField?
        private var editing: DWCell?

        func update(_ g: DWGrid, accent: NSColor, store: AppStore) {
            let old = grid
            grid = g
            self.accent = accent
            self.store = store
            guard let table else { return }
            let sig = g.columns.map { "\($0.name)|\($0.type)|\($0.isPK)|\($0.fk ?? "")" }.joined(separator: ",")
            // An open editor is tied to a row index: drop it if the rows or columns changed under it.
            if editor != nil, sig != signature || g.rowCount != old?.rowCount || g.rowOffset != old?.rowOffset { cancelEdit() }
            if sig != signature {
                signature = sig
                rebuildColumns(table, g)
            }
            barCache = nil
            for (i, c) in g.columns.enumerated() {
                let tc = table.tableColumns[i + 1]
                (tc.headerCell as? GridHeaderCell)?.sort = g.sort?.column == c.name ? g.sort?.ascending : nil
                (tc.headerCell as? GridHeaderCell)?.accent = accent
            }
            table.headerView?.needsDisplay = true
            table.reloadData()
            // Follow keyboard moves, but leave a freshly opened tab at its top.
            if old != nil, let sel = g.selection, sel != old?.selection, sel.row < g.rowCount {
                table.scrollRowToVisible(sel.row)
            }
            syncPopover(g)
        }

        private func rebuildColumns(_ table: NSTableView, _ g: DWGrid) {
            for c in table.tableColumns { table.removeTableColumn(c) }
            let gutter = NSTableColumn(identifier: .init("#"))
            gutter.width = DWGrid.gutter
            gutter.minWidth = DWGrid.gutter
            gutter.resizingMask = []
            gutter.headerCell = GridHeaderCell(column: nil)
            table.addTableColumn(gutter)
            for (i, c) in g.columns.enumerated() {
                let tc = NSTableColumn(identifier: .init("c\(i)"))
                tc.width = DWGrid.width(c)
                tc.minWidth = 40
                tc.maxWidth = 2000
                tc.headerCell = GridHeaderCell(column: c)
                tc.headerToolTip = c.fk.map { "\(c.name) \(c.type) → \($0)" } ?? "\(c.name) \(c.type)"
                table.addTableColumn(tc)
            }
        }

        // Data

        func numberOfRows(in tableView: NSTableView) -> Int { grid?.rowCount ?? 0 }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let g = grid, let tc = tableColumn else { return nil }
            let id = tc.identifier
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? GridCell) ?? {
                let v = GridCell()
                v.identifier = id
                return v
            }()
            let state = g.rowState(row)
            let rowSelected = g.selection?.row == row
            cell.rowTint = state == .inserted ? GridInk.green.withAlphaComponent(0.07)
                : state == .deleted ? GridInk.red.withAlphaComponent(0.07)
                : rowSelected ? accent.withAlphaComponent(0.06) : nil
            if id.rawValue == "#" {
                cell.configureGutter(state == .inserted ? "+" : state == .deleted ? "−" : "\(g.rowOffset + row + 1)",
                                     color: state == .inserted ? GridInk.green : state == .deleted ? GridInk.red
                                         : rowSelected ? accent : GridInk.null,
                                     heavy: state != .normal)
                return cell
            }
            guard let col = Int(id.rawValue.dropFirst()), col < g.columns.count else { return cell }
            let c = g.columns[col]
            let v = g.value(row, col)
            let style = DWGrid.style(v, c, inserted: state == .inserted)
            let isEdited = !g.edited(row).isEmpty && g.edited(row).contains(col)
            var bar: CGFloat?
            if let b = g.barColumn, b == col, let n = DWGrid.number(v), let top = maxBar(g, b), top > 0 { bar = CGFloat(min(1, n / top)) }
            cell.configure(text: style.text, color: isEdited ? GridInk.edited : style.ns, italic: style.italic,
                           right: DWGrid.numeric(c.type) && v != nil, struck: state == .deleted,
                           underline: c.fk != nil && v != nil, edited: isEdited,
                           selected: g.selection == DWCell(row: row, col: col), accent: accent, bar: bar)
            return cell
        }

        var barCache: (col: Int, rows: Int, max: Double)?
        private func maxBar(_ g: DWGrid, _ col: Int) -> Double? {
            if let c = barCache, c.col == col, c.rows == g.rowCount { return c.max }
            let m = (0..<g.rowCount).compactMap { DWGrid.number(g.value($0, col)) }.max() ?? 0
            barCache = (col, g.rowCount, m)
            return m
        }

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            guard let g = grid, tableColumn.identifier.rawValue != "#", let col = Int(tableColumn.identifier.rawValue.dropFirst()), col < g.columns.count else { return }
            g.onSort?(g.columns[col].name)
        }

        // Clicks

        @objc func clicked() {
            guard let table, let g = grid, table.clickedRow >= 0 else { return }
            commitEdit()
            let col = max(0, table.clickedColumn - 1)
            g.onSelect(DWCell(row: table.clickedRow, col: min(col, max(0, g.columns.count - 1))))
        }

        @objc func doubleClicked() {
            guard let table, table.clickedRow >= 0, table.clickedColumn >= 1 else { return }
            beginEdit(DWCell(row: table.clickedRow, col: table.clickedColumn - 1))
        }

        func move(dRow: Int, dCol: Int) {
            guard let g = grid, g.rowCount > 0, !g.columns.isEmpty else { return }
            let s = g.selection ?? DWCell(row: 0, col: 0)
            g.onSelect(DWCell(row: min(max(0, s.row + dRow), g.rowCount - 1), col: min(max(0, s.col + dCol), g.columns.count - 1)))
        }

        func copySelection() {
            guard let g = grid, let s = g.selection else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(g.value(s.row, s.col) ?? "NULL", forType: .string)
        }

        // Editing: a text field over the cell.

        func beginEdit(_ at: DWCell?) {
            guard let table, let g = grid, let at = at ?? g.selection, g.editable, g.onEdit != nil,
                  at.row < g.rowCount, at.col < g.columns.count, g.rowState(at.row) != .deleted else { return }
            commitEdit()
            g.onSelect(at)
            let rect = table.frameOfCell(atColumn: at.col + 1, row: at.row).insetBy(dx: 1, dy: 1)
            let f = NSTextField(frame: rect)
            f.font = NSFont.code(ofSize: 12)
            f.stringValue = g.value(at.row, at.col) ?? ""
            f.isBordered = false
            f.focusRingType = .none
            f.drawsBackground = true
            f.backgroundColor = GridInk.input
            f.textColor = GridInk.text
            f.delegate = self
            table.addSubview(f)
            table.window?.makeFirstResponder(f)
            editor = f
            editing = at
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.cancelOperation(_:)) { cancelEdit(); return true }
            if sel == #selector(NSResponder.insertNewline(_:)) { commitEdit(); table?.window?.makeFirstResponder(table); return true }
            return false
        }

        func controlTextDidEndEditing(_ obj: Notification) { commitEdit() }

        private func commitEdit() {
            guard let f = editor, let at = editing else { return }
            editor = nil
            editing = nil
            f.removeFromSuperview()
            grid?.onEdit?(at, f.stringValue)
        }

        func cancelEdit() {
            // Cleared first: removing the field ends editing, which would otherwise commit it.
            let f = editor
            editor = nil
            editing = nil
            f?.removeFromSuperview()
            table?.window?.makeFirstResponder(table)
        }

        // Foreign-key popover, anchored to the clicked cell.

        private func syncPopover(_ g: DWGrid) {
            guard let table else { return }
            if let cell = g.fkCell, let content = g.fkContent, cell.row < g.rowCount {
                if popoverCell == cell, popover?.isShown == true { return }
                // Forget the old one before closing it, so its close isn't read as "dismissed".
                let old = popover
                popover = nil
                popoverCell = nil
                old?.close()
                let p = NSPopover()
                p.behavior = .transient
                p.delegate = self
                var root = AnyView(content(cell))
                if let store { root = AnyView(root.environment(store).environment(\.accent, Color(accent))) }
                p.contentViewController = NSHostingController(rootView: root)
                let rect = table.frameOfCell(atColumn: cell.col + 1, row: cell.row)
                guard table.visibleRect.intersects(rect) else { return }
                popover = p
                popoverCell = cell
                p.show(relativeTo: rect, of: table, preferredEdge: .maxY)
            } else if popover?.isShown == true {
                let old = popover
                popover = nil
                popoverCell = nil
                old?.close()
            }
        }

        func popoverDidClose(_ notification: Notification) {
            guard (notification.object as? NSPopover) === popover else { return }
            popover = nil
            if popoverCell != nil {
                popoverCell = nil
                grid?.onFKDismiss()
            }
        }
    }

    // MARK: Cell look (shared with the record inspector and chart)

    struct Style {
        enum Ink { case null, on, off, fk, json, plain }
        var text: String
        var ink: Ink
        var italic = false

        var color: Color {
            switch ink {
            case .null: Color(hex: 0x5E5E68)
            case .on: Theme.green
            case .off: Theme.meta
            case .fk: Color(hex: 0x93B4FF)
            case .json: Color(hex: 0xFDBA74)
            case .plain: Theme.body
            }
        }
        var ns: NSColor {
            switch ink {
            case .null: GridInk.null
            case .on: GridInk.green
            case .off: GridInk.meta
            case .fk: GridInk.fk
            case .json: GridInk.json
            case .plain: GridInk.body
            }
        }
    }

    static func style(_ v: String?, _ c: DBColumn, inserted: Bool) -> Style {
        guard let v else {
            if inserted && c.isPK { return Style(text: "generated", ink: .on, italic: true) }
            return Style(text: inserted ? "default" : "NULL", ink: .null, italic: true)
        }
        let t = c.type.lowercased()
        if isBool(t) {
            let on = ["t", "true", "1", "yes"].contains(v.lowercased())
            return Style(text: on ? "true" : "false", ink: on ? .on : .off)
        }
        if c.fk != nil { return Style(text: v, ink: .fk) }
        if t.contains("json") { return Style(text: v, ink: .json) }
        return Style(text: v.replacingOccurrences(of: "\n", with: " ↵ "), ink: .plain)
    }

    static func isBool(_ t: String) -> Bool { t == "bool" || t == "boolean" || t.hasPrefix("tinyint(1)") }

    static func numeric(_ type: String) -> Bool {
        let t = type.lowercased()
        return !isBool(t) && ["int", "numeric", "decimal", "float", "double", "real", "money", "serial"].contains { t.contains($0) }
    }

    static func number(_ v: String?) -> Double? {
        v.flatMap { Double($0.replacingOccurrences(of: ",", with: "")) }
    }

    static func width(_ c: DBColumn) -> CGFloat {
        let t = c.type.lowercased()
        let head = CGFloat(c.name.count + c.type.count) * 7 + 44
        let body: CGFloat
        if t.contains("timestamp") || c.name.hasSuffix("_at") { body = 200 }
        else if t.contains("uuid") { body = 150 }
        else if c.name.contains("email") || c.name == "name" || t.contains("varchar(255)") || t == "text" { body = 210 }
        else if t.contains("json") { body = 170 }
        else if numeric(t) || isBool(t) { body = 80 }
        else if c.name == "QUERY PLAN" || c.name == "detail" { body = 760 }
        else { body = 110 }
        return min(max(head, body), 900)
    }
}

/// The table view: arrows move the selected cell, Return edits, ⌘C copies.
final class GridTable: NSTableView {
    weak var coordinator: DWGrid.Coordinator?

    override func keyDown(with e: NSEvent) {
        guard let c = coordinator else { return super.keyDown(with: e) }
        switch e.keyCode {
        case 123: c.move(dRow: 0, dCol: -1)
        case 124: c.move(dRow: 0, dCol: 1)
        case 125: c.move(dRow: 1, dCol: 0)
        case 126: c.move(dRow: -1, dCol: 0)
        case 36, 76 where e.modifierFlags.intersection([.command, .option, .control]).isEmpty: c.beginEdit(nil)
        case 48 where e.modifierFlags.intersection([.command, .option, .control]).isEmpty:
            c.move(dRow: 0, dCol: e.modifierFlags.contains(.shift) ? -1 : 1)
        default: super.keyDown(with: e)
        }
    }

    @objc func copy(_ sender: Any?) { coordinator?.copySelection() }

    override func menu(for event: NSEvent) -> NSMenu? { nil }
}

/// One cell, drawn directly: background tints, a data bar, the edit mark,
/// truncated text and the grid lines. No subviews.
final class GridCell: NSView {
    private var text = ""
    private var color = NSColor.labelColor
    private var italic = false
    private var right = false
    private var struck = false
    private var underline = false
    private var edited = false
    private var selected = false
    private var accent = NSColor.systemGreen
    private var bar: CGFloat?
    private var gutter = false
    private var heavy = false
    var rowTint: NSColor?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    func configure(text: String, color: NSColor, italic: Bool, right: Bool, struck: Bool, underline: Bool, edited: Bool,
                   selected: Bool, accent: NSColor, bar: CGFloat?) {
        self.text = text; self.color = color; self.italic = italic; self.right = right; self.struck = struck
        self.underline = underline; self.edited = edited; self.selected = selected; self.accent = accent; self.bar = bar
        gutter = false
        needsDisplay = true
    }

    func configureGutter(_ text: String, color: NSColor, heavy: Bool) {
        self.text = text; self.color = color; self.heavy = heavy
        gutter = true; selected = false; edited = false; bar = nil; struck = false; underline = false; italic = false; right = true
        needsDisplay = true
    }

    private static let mono = NSFont.code(ofSize: 12)
    private static let small = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    private static let heavyFont = NSFont.systemFont(ofSize: 13, weight: .heavy)
    private static let line = NSColor.white.withAlphaComponent(0.04)
    private static let rowLine = NSColor.white.withAlphaComponent(0.035)

    override func draw(_ dirty: NSRect) {
        let b = bounds
        if let rowTint { rowTint.setFill(); b.fill() }
        if edited {
            GridInk.amber.withAlphaComponent(0.14).setFill(); b.fill()
            GridInk.amber.setFill(); NSRect(x: 0, y: 0, width: 2, height: b.height).fill()
        } else if selected {
            accent.withAlphaComponent(0.12).setFill(); b.fill()
        }
        if let bar {
            accent.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: NSRect(x: 10, y: (b.height - 16) / 2, width: max(0, (b.width - 20) * bar), height: 16), xRadius: 2, yRadius: 2).fill()
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        para.alignment = right ? .right : .left
        var attrs: [NSAttributedString.Key: Any] = [
            .font: gutter ? (heavy ? Self.heavyFont : Self.small) : Self.mono,
            .foregroundColor: color, .paragraphStyle: para
        ]
        if italic { attrs[.obliqueness] = 0.18 }
        if struck { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue; attrs[.strikethroughColor] = GridInk.red.withAlphaComponent(0.6) }
        if underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue; attrs[.underlineColor] = GridInk.blue.withAlphaComponent(0.6) }
        let font = attrs[.font] as! NSFont
        let h = ceil(font.ascender - font.descender + font.leading)
        let inset: CGFloat = gutter ? 10 : 10
        let r = NSRect(x: inset, y: (b.height - h) / 2, width: b.width - inset * 2, height: h)
        (text as NSString).draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        (gutter ? NSColor.white.withAlphaComponent(0.05) : Self.line).setFill()
        NSRect(x: b.width - 1, y: 0, width: 1, height: b.height).fill()
        Self.rowLine.setFill()
        NSRect(x: 0, y: b.height - 1, width: b.width, height: 1).fill()
        if selected {
            accent.setStroke()
            let p = NSBezierPath(rect: b.insetBy(dx: 0.75, dy: 0.75))
            p.lineWidth = 1.5
            p.stroke()
        }
    }
}

/// Header strip in the grid's own colours.
final class GridHeader: NSTableHeaderView {
    override func draw(_ dirtyRect: NSRect) {
        GridInk.header.setFill()
        bounds.fill()
        super.draw(dirtyRect)
        NSColor.white.withAlphaComponent(0.07).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

/// A column header: PK key (amber) or FK link (blue), name, type, sort arrow.
final class GridHeaderCell: NSTableHeaderCell {
    let column: DBColumn?
    var sort: Bool?
    var accent = NSColor.systemGreen

    init(column: DBColumn?) {
        self.column = column
        super.init(textCell: column?.name ?? "")
    }
    required init(coder: NSCoder) { column = nil; super.init(coder: coder) }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        GridInk.header.setFill()
        cellFrame.fill()
        // The header fills the space after the last column with a cell too: leave it blank.
        if let tv = (controlView as? NSTableHeaderView)?.tableView, tv.numberOfColumns > 0,
           cellFrame.minX >= tv.rect(ofColumn: tv.numberOfColumns - 1).maxX - 1 { return }
        NSColor.white.withAlphaComponent(0.05).setFill()
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY, width: 1, height: cellFrame.height).fill()
        guard let c = column else { return }
        var x = cellFrame.minX + 10
        let midY = cellFrame.midY
        if c.isPK || c.fk != nil, let img = NSImage(systemSymbolName: c.isPK ? "key.fill" : "link", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold)) {
            let tinted = img.tinted(c.isPK ? GridInk.amber : GridInk.blue)
            tinted.draw(in: NSRect(x: x, y: midY - 5, width: 10, height: 10))
            x += 15
        }
        let s = NSMutableAttributedString(string: c.name, attributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
                                                                      .foregroundColor: GridInk.heading])
        s.append(NSAttributedString(string: "  " + c.type, attributes: [.font: NSFont.code(ofSize: 10), .foregroundColor: GridInk.meta]))
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
        s.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: s.length))
        let arrow: CGFloat = sort == nil ? 0 : 14
        let h = s.size().height
        s.draw(with: NSRect(x: x, y: midY - h / 2, width: max(0, cellFrame.maxX - x - 8 - arrow), height: h),
               options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if let up = sort, let img = NSImage(systemSymbolName: up ? "arrow.up" : "arrow.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold)) {
            img.tinted(accent).draw(in: NSRect(x: cellFrame.maxX - 20, y: midY - 5, width: 10, height: 10))
        }
    }
}

private extension NSImage {
    func tinted(_ c: NSColor) -> NSImage {
        let img = copy() as! NSImage
        img.lockFocus()
        c.set()
        NSRect(origin: .zero, size: img.size).fill(using: .sourceAtop)
        img.unlockFocus()
        img.isTemplate = false
        return img
    }
}

/// The amber primary-key mark.
struct KeyGlyph: View {
    var color: Color
    var body: some View {
        Image(systemName: "key.fill").font(.system(size: 8.5, weight: .bold)).foregroundStyle(color).rotationEffect(.degrees(-45))
    }
}

/// The grid's colours, made in AppKit. Converting the app's light/dark SwiftUI
/// colours to NSColor over-releases them (it crashed), and the grid would do
/// that thousands of times, so it keeps its own.
enum GridInk {
    private static func dyn(_ dark: UInt32, _ light: UInt32) -> NSColor {
        NSColor(name: nil) { ap in NSColor(hex: ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light) }
    }
    static let island = dyn(0x121214, 0xF8F8F9)
    static let input = dyn(0x0C0C0E, 0xFFFFFF)
    static let header = dyn(0x161618, 0xF1F1F3)
    static let text = dyn(0xF4F4F5, 0x18181B)
    static let body = dyn(0xD4D4D8, 0x27272A)
    static let heading = dyn(0xE4E4E7, 0x27272A)
    static let meta = dyn(0x74747E, 0x84848D)
    static let null = dyn(0x5E5E68, 0xA1A1AA)
    static let green = dyn(0x4ADE80, 0x16A34A)
    static let amber = dyn(0xFBBF24, 0xD97706)
    static let red = dyn(0xF87171, 0xDC2626)
    static let blue = dyn(0x60A5FA, 0x2563EB)
    static let fk = dyn(0x93B4FF, 0x2563EB)
    static let json = dyn(0xFDBA74, 0xC2410C)
    static let edited = dyn(0xFDE68A, 0xA16207)
}
