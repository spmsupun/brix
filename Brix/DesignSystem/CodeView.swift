import SwiftUI
import AppKit

/// Git gutter mark: lines are 1-based and inclusive.
struct GutterMark: Hashable {
    var lines: ClosedRange<Int>
    var status: GitStatus
}

/// NSTextView-based code view with line numbers, a git gutter and syntax
/// highlighting. Read-only unless `text` is a writable binding.
struct CodeView: NSViewRepresentable {
    var text: String
    var language: SyntaxLanguage
    var editable = false
    var onChange: ((String) -> Void)? = nil
    var marks: [GutterMark] = []
    /// Lines (1-based) to tint, used for "Claude is editing this block".
    var highlight: ClosedRange<Int>? = nil
    var highlightColor: Color = Theme.violet
    var fontSize: CGFloat = 12.5
    var lineHeight: CGFloat = 20
    var background: Color = Theme.editor
    var onCursor: ((Int, Int) -> Void)? = nil
    var onRun: (() -> Void)? = nil
    /// Caret position as a UTF-16 offset into `text`.
    var onCaret: ((Int) -> Void)? = nil
    /// Lines (1-based) that start a runnable statement: a green ▶ in the gutter.
    var runLines: Set<Int> = []
    var onRunLine: ((Int) -> Void)? = nil
    /// Tab key; return true when handled (e.g. accepting a suggestion).
    var onTab: (() -> Bool)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(background)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        let replacement = CodeTextView(frame: tv.frame)
        replacement.autoresizingMask = tv.autoresizingMask
        replacement.minSize = tv.minSize
        replacement.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        replacement.isVerticallyResizable = true
        replacement.isHorizontallyResizable = true
        replacement.textContainer?.widthTracksTextView = false
        replacement.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = replacement
        let textView = replacement
        textView.onRun = onRun
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = true
        textView.backgroundColor = NSColor(background)
        textView.insertionPointColor = NSColor(AccentChoice.lime.color)
        textView.selectedTextAttributes = [.backgroundColor: NSColor.white.withAlphaComponent(0.12)]
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.delegate = context.coordinator
        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = lineHeight
        para.maximumLineHeight = lineHeight
        textView.defaultParagraphStyle = para
        textView.typingAttributes = [.font: NSFont.code(ofSize: fontSize, weight: .regular),
                                     .foregroundColor: NSColor(Theme.text), .paragraphStyle: para]

        let ruler = LineNumberRuler(textView: textView)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        context.coordinator.ruler = ruler
        context.coordinator.textView = textView
        apply(to: textView, ruler: ruler, force: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = context.coordinator.textView, let ruler = context.coordinator.ruler else { return }
        context.coordinator.parent = self
        (tv as? CodeTextView)?.onRun = onRun
        (tv as? CodeTextView)?.onTab = onTab
        ruler.onRunLine = onRunLine
        scroll.backgroundColor = NSColor(background)
        tv.backgroundColor = NSColor(background)
        apply(to: tv, ruler: ruler, force: false)
    }

    private func apply(to tv: NSTextView, ruler: LineNumberRuler, force: Bool) {
        tv.isEditable = editable
        tv.isSelectable = true
        ruler.marks = marks
        ruler.runLines = runLines
        ruler.lineHeight = lineHeight
        if force || (tv.string != text && !(editable && tv.window?.firstResponder === tv && tv.string == text)) {
            if tv.string != text || force {
                let selected = tv.selectedRanges
                tv.textStorage?.setAttributedString(styled(text))
                if editable { tv.selectedRanges = selected.filter { $0.rangeValue.upperBound <= (text as NSString).length } }
            }
        }
        (tv as? CodeTextView)?.highlightLines = highlight
        (tv as? CodeTextView)?.highlightColor = NSColor(highlightColor)
        tv.needsDisplay = true
        ruler.needsDisplay = true
    }

    func styled(_ s: String) -> NSAttributedString {
        var theme = SyntaxTheme()
        theme.font = NSFont.code(ofSize: fontSize, weight: .regular)
        let a = NSMutableAttributedString(attributedString: SyntaxHighlighter.highlight(s, language: language, theme: theme))
        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = lineHeight
        para.maximumLineHeight = lineHeight
        a.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: a.length))
        return a
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeView
        weak var textView: NSTextView?
        weak var ruler: LineNumberRuler?
        private var rehighlight: DispatchWorkItem?

        init(_ p: CodeView) { parent = p }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            let s = tv.string
            parent.onChange?(s)
            ruler?.needsDisplay = true
            // Live highlighting, debounced so typing stays smooth.
            rehighlight?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let tv = self.textView, tv.string == s else { return }
                let sel = tv.selectedRanges
                tv.textStorage?.beginEditing()
                tv.textStorage?.setAttributedString(self.parent.styled(s))
                tv.textStorage?.endEditing()
                tv.selectedRanges = sel
            }
            rehighlight = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = textView else { return }
            let loc = tv.selectedRange().location
            parent.onCaret?(loc)
            guard let cb = parent.onCursor else { return }
            let prefix = (tv.string as NSString).substring(to: min(loc, (tv.string as NSString).length))
            let line = prefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            let col = loc - ((prefix as NSString).range(of: "\n", options: .backwards).location == NSNotFound ? 0 : (prefix as NSString).range(of: "\n", options: .backwards).location + 1) + 1
            cb(line, col)
        }
    }
}

/// Text view that tints a block of lines and runs on ⌘↩.
final class CodeTextView: NSTextView {
    var highlightLines: ClosedRange<Int>?
    var highlightColor = NSColor.systemPurple
    var onRun: (() -> Void)?
    var onTab: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48, event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty, onTab?() == true { return }
        if event.modifierFlags.contains(.command), event.keyCode == 36, let onRun {
            onRun()
            return
        }
        super.keyDown(with: event)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let lines = highlightLines, let lm = layoutManager, let tc = textContainer else { return }
        let ns = string as NSString
        var lineStart = 0, line = 1
        var startLoc: Int?, endLoc = ns.length
        while lineStart <= ns.length {
            let r = ns.lineRange(for: NSRange(location: min(lineStart, ns.length), length: 0))
            if line == lines.lowerBound { startLoc = r.location }
            if line == lines.upperBound { endLoc = NSMaxRange(r); break }
            if NSMaxRange(r) >= ns.length { break }
            lineStart = NSMaxRange(r)
            line += 1
        }
        guard let s = startLoc else { return }
        let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: s, length: max(0, endLoc - s)), actualCharacterRange: nil)
        var box = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        box.origin.x = 0
        box.size.width = bounds.width
        box.origin.y += textContainerInset.height
        highlightColor.withAlphaComponent(0.07).setFill()
        box.fill()
        highlightColor.setFill()
        NSRect(x: 0, y: box.minY, width: 2, height: box.height).fill()
    }
}

/// Line numbers plus git gutter bars.
final class LineNumberRuler: NSRulerView {
    weak var textView: NSTextView?
    var marks: [GutterMark] = []
    var runLines: Set<Int> = []
    var onRunLine: ((Int) -> Void)?
    var lineHeight: CGFloat = 20
    /// Where each drawn line sat, for clicks on a ▶.
    private var drawn: [(line: Int, minY: CGFloat, maxY: CGFloat)] = []

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        ruleThickness = 54
        // No separator line, and nothing drawn outside the gutter (it showed through
        // the breadcrumb above the scroll view).
        clipsToBounds = true
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification, object: textView.enclosingScrollView?.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSText.didChangeNotification, object: textView)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func redraw() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func mouseDown(with event: NSEvent) {
        let y = convert(event.locationInWindow, from: nil).y
        if let hit = drawn.first(where: { y >= $0.minY && y < $0.maxY }), runLines.contains(hit.line), let onRunLine {
            onRunLine(hit.line)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        drawn.removeAll()
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        (tv.backgroundColor).setFill()
        bounds.fill()
        let ns = tv.string as NSString
        let visible = tv.visibleRect
        let glyphRange = lm.glyphRange(forBoundingRect: visible, in: tc)
        let charRange = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        // Line number of the first visible character.
        var line = 1
        ns.enumerateSubstrings(in: NSRange(location: 0, length: charRange.location), options: [.byLines, .substringNotRequired]) { _, _, _, _ in line += 1 }
        if charRange.location == 0 { line = 1 }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor(Theme.lineNumber)]
        let inset = tv.textContainerInset.height
        let relativeY = convert(NSPoint.zero, from: tv).y
        var idx = charRange.location
        let end = NSMaxRange(charRange)
        func drawLine(_ n: Int, _ rect: NSRect) {
            let y = rect.minY + inset + relativeY
            let label = "\(n)" as NSString
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: ruleThickness - 14 - size.width, y: y + (rect.height - size.height) / 2), withAttributes: attrs)
            drawn.append((n, y, y + rect.height))
            if runLines.contains(n) {
                let mid = y + rect.height / 2
                let tri = NSBezierPath()
                tri.move(to: NSPoint(x: 7, y: mid - 4.5)); tri.line(to: NSPoint(x: 15, y: mid)); tri.line(to: NSPoint(x: 7, y: mid + 4.5)); tri.close()
                NSColor(Theme.green).setFill()
                tri.fill()
            }
            if let m = marks.first(where: { $0.lines.contains(n) }) {
                NSColor(m.status.color).withAlphaComponent(0.8).setFill()
                NSBezierPath(roundedRect: NSRect(x: ruleThickness - 6, y: y, width: 3, height: rect.height), xRadius: 1.5, yRadius: 1.5).fill()
            }
        }
        if ns.length == 0 {
            drawLine(1, NSRect(x: 0, y: 0, width: 0, height: lineHeight))
            return
        }
        while idx <= end, idx < ns.length {
            let lr = ns.lineRange(for: NSRange(location: idx, length: 0))
            let g = lm.glyphRange(forCharacterRange: NSRange(location: lr.location, length: 0), actualCharacterRange: nil)
            let rect = lm.lineFragmentRect(forGlyphAt: g.location, effectiveRange: nil)
            drawLine(line, rect)
            line += 1
            idx = NSMaxRange(lr)
            if lr.length == 0 { break }
        }
        // Trailing empty line after a final newline.
        if ns.length > 0, ns.character(at: ns.length - 1) == 10, end >= ns.length {
            let rect = lm.extraLineFragmentRect
            if rect.height > 0 { drawLine(line, rect) }
        }
    }
}
