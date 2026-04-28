import AppKit
import SwiftUI

struct CodeEditorView: NSViewRepresentable {
    @Binding var content: String
    let isEditable: Bool
    let language: CodeLanguage
    let isDarkMode: Bool
    let onSave: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false

        let textView = NSTextView()
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.usesFindPanel = true

        let font = NSFont(name: "SF Mono", size: 13)
            ?? NSFont(name: "Menlo", size: 13)
            ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.font = font
        textView.delegate = context.coordinator

        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        applyColors(to: textView)

        scrollView.documentView = textView
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        let rulerView = LineNumberRulerView(textView: textView, isDarkMode: isDarkMode)
        scrollView.verticalRulerView = rulerView

        context.coordinator.textView = textView
        textView.string = content
        context.coordinator.applySyntaxHighlighting()

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        if !context.coordinator.isInternalChange && textView.string != content {
            textView.string = content
            context.coordinator.applySyntaxHighlighting()
        }
        context.coordinator.isInternalChange = false

        textView.isEditable = isEditable
        applyColors(to: textView)

        if context.coordinator.lastLanguage != language || context.coordinator.lastDarkMode != isDarkMode {
            context.coordinator.lastLanguage = language
            context.coordinator.lastDarkMode = isDarkMode
            context.coordinator.applySyntaxHighlighting()
        }

        if let rulerView = scrollView.verticalRulerView as? LineNumberRulerView {
            rulerView.isDarkMode = isDarkMode
            rulerView.needsDisplay = true
        }
    }

    private func applyColors(to textView: NSTextView) {
        let bgColor = isDarkMode
            ? NSColor(red: 0.118, green: 0.118, blue: 0.118, alpha: 1) // #1E1E1E
            : NSColor.white
        let textColor = isDarkMode
            ? NSColor(red: 0.831, green: 0.831, blue: 0.831, alpha: 1) // #D4D4D4
            : NSColor(red: 0.118, green: 0.118, blue: 0.118, alpha: 1)
        textView.backgroundColor = bgColor
        textView.insertionPointColor = isDarkMode ? .white : .black
        textView.textColor = textColor
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView
        weak var textView: NSTextView?
        var isInternalChange = false
        var lastLanguage: CodeLanguage
        var lastDarkMode: Bool
        private var highlightWorkItem: DispatchWorkItem?

        init(_ parent: CodeEditorView) {
            self.parent = parent
            self.lastLanguage = parent.language
            self.lastDarkMode = parent.isDarkMode
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            isInternalChange = true
            parent.content = textView.string
            scheduleHighlighting()
            (textView.enclosingScrollView?.verticalRulerView as? LineNumberRulerView)?.needsDisplay = true
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                textView.insertText("    ", replacementRange: textView.selectedRange())
                return true
            }
            if commandSelector == #selector(NSDocument.save(_:)) {
                parent.onSave?()
                return true
            }
            return false
        }

        private func scheduleHighlighting() {
            highlightWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.applySyntaxHighlighting()
            }
            highlightWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
        }

        func applySyntaxHighlighting() {
            guard let textView = textView,
                  let textStorage = textView.textStorage else { return }
            let selectedRange = textView.selectedRange()
            let attributed = SyntaxHighlighter.highlight(
                textView.string, language: parent.language, isDarkMode: parent.isDarkMode
            )
            textStorage.beginEditing()
            textStorage.setAttributedString(attributed)
            textStorage.endEditing()
            if selectedRange.location + selectedRange.length <= textStorage.length {
                textView.setSelectedRange(selectedRange)
            }
        }
    }
}

final class LineNumberRulerView: NSRulerView {
    var isDarkMode: Bool

    init(textView: NSTextView, isDarkMode: Bool) {
        self.isDarkMode = isDarkMode
        super.init(scrollView: textView.enclosingScrollView!, orientation: .verticalRuler)
        clientView = textView
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    override var requiredThickness: CGFloat {
        guard let textView = clientView as? NSTextView else { return 40 }
        let lineCount = max(textView.string.components(separatedBy: "\n").count, 1)
        let digits = max(String(lineCount).count, 2)
        return CGFloat(digits) * 8 + 16
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        let bgColor = isDarkMode
            ? NSColor(red: 0.118, green: 0.118, blue: 0.118, alpha: 1)
            : NSColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1)
        bgColor.setFill()
        rect.fill()

        let font = NSFont(name: "SF Mono", size: 11)
            ?? NSFont(name: "Menlo", size: 11)
            ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let color = NSColor.gray
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]

        let visibleRect = scrollView!.contentView.bounds
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        let text = textView.string
        var lineNumber = 1
        var index = text.startIndex
        let charStart = characterRange.location

        for i in 0..<charStart {
            let idx = text.index(text.startIndex, offsetBy: i, limitedBy: text.endIndex) ?? text.endIndex
            if idx < text.endIndex && text[idx] == "\n" { lineNumber += 1 }
        }
        index = text.index(text.startIndex, offsetBy: charStart, limitedBy: text.endIndex) ?? text.endIndex

        var glyphIndex = glyphRange.location
        while glyphIndex < NSMaxRange(glyphRange) {
            var effectiveRange = NSRange()
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &effectiveRange)
            let yPos = lineRect.origin.y - visibleRect.origin.y

            let numStr = "\(lineNumber)" as NSString
            let strSize = numStr.size(withAttributes: attrs)
            let x = ruleThickness - strSize.width - 6
            numStr.draw(at: NSPoint(x: x, y: yPos), withAttributes: attrs)

            lineNumber += 1
            glyphIndex = NSMaxRange(effectiveRange)
        }
    }
}
