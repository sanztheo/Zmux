import AppKit
import Carbon.HIToolbox
import CodeEditLanguages
import CodeEditSourceEditor
import SwiftUI

struct FileCodeEditorView: View {
    @Binding var content: String
    let isEditable: Bool
    let language: FileLanguage
    let isDarkMode: Bool
    let onSave: (() -> Void)?

    @State private var state = SourceEditorState()

    init(
        content: Binding<String>,
        isEditable: Bool,
        language: FileLanguage,
        isDarkMode: Bool,
        onSave: (() -> Void)? = nil
    ) {
        _content = content
        self.isEditable = isEditable
        self.language = language
        self.isDarkMode = isDarkMode
        self.onSave = onSave
    }

    var body: some View {
        SourceEditor(
            $content,
            language: language.codeLanguage,
            configuration: SourceEditorConfiguration(
                appearance: .init(
                    theme: isDarkMode ? .zmuxDark : .zmuxLight,
                    font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                    lineHeightMultiple: 1.3,
                    wrapLines: true,
                    tabWidth: 4
                ),
                behavior: .init(
                    isEditable: isEditable,
                    isSelectable: true,
                    indentOption: .spaces(count: 4)
                ),
                layout: .init(),
                peripherals: .init(
                    showGutter: true,
                    showMinimap: false,
                    showReformattingGuide: false,
                    showFoldingRibbon: false
                )
            ),
            state: $state
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CodeEditorKeyMonitor(onSave: onSave))
    }
}

// MARK: - Editor key monitor: Cmd+S (save)
//
// SwiftUI `.onKeyPress` does not fire when focus lives inside the underlying
// AppKit text view, so we install a local NSEvent monitor that intercepts
// Cmd+S only when the editor is the first responder. CodeEditSourceEditor
// already handles Cmd+F (find) natively, so we don't trap it here.

private struct CodeEditorKeyMonitor: NSViewRepresentable {
    let onSave: (() -> Void)?

    func makeNSView(context: Context) -> NSView {
        context.coordinator.onSave = onSave
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_: NSView, context: Context) {
        context.coordinator.onSave = onSave
    }

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var onSave: (() -> Void)?
        private var monitor: Any?

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.handle(event) ? nil : event
            }
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit { uninstall() }

        private func handle(_ event: NSEvent) -> Bool {
            guard event.modifierFlags.contains(.command),
                  !event.modifierFlags.contains(.control),
                  !event.modifierFlags.contains(.option),
                  Self.firstResponderIsCodeEditor()
            else { return false }

            // Cmd+Backspace and Cmd+ForwardDelete should delete to line bounds.
            // CodeEditTextView implements the standard NSResponder selectors but
            // some IME/host setups swallow the keyDown before
            // interpretKeyEvents resolves them, so route the action explicitly.
            switch Int(event.keyCode) {
            case kVK_Delete: // Backspace
                return performLineEditAction(#selector(NSStandardKeyBindingResponding.deleteToBeginningOfLine(_:)))
            case kVK_ForwardDelete:
                return performLineEditAction(#selector(NSStandardKeyBindingResponding.deleteToEndOfLine(_:)))
            default:
                break
            }

            if event.charactersIgnoringModifiers == "s" {
                onSave?()
                return true
            }
            return false
        }

        private func performLineEditAction(_ selector: Selector) -> Bool {
            guard let responder = NSApp.keyWindow?.firstResponder else { return false }
            return responder.tryToPerform(selector, with: nil)
        }

        private static func firstResponderIsCodeEditor() -> Bool {
            guard let responder = NSApp.keyWindow?.firstResponder else { return false }
            let className = String(describing: type(of: responder))
            return className.contains("TextView") || className.contains("CodeEdit")
        }
    }
}

private extension EditorTheme {
    static let zmuxDark = EditorTheme(
        text: .init(color: NSColor(red: 0.831, green: 0.831, blue: 0.831, alpha: 1)),
        insertionPoint: .white,
        invisibles: .init(color: NSColor(white: 0.4, alpha: 1)),
        background: NSColor(red: 0.118, green: 0.118, blue: 0.118, alpha: 1),
        lineHighlight: NSColor(red: 0.16, green: 0.16, blue: 0.18, alpha: 1),
        selection: NSColor(red: 0.24, green: 0.30, blue: 0.48, alpha: 1),
        keywords: .init(color: NSColor(red: 0.99, green: 0.37, blue: 0.53, alpha: 1)),
        commands: .init(color: NSColor(red: 0.40, green: 0.82, blue: 0.90, alpha: 1)),
        types: .init(color: NSColor(red: 0.40, green: 0.82, blue: 0.90, alpha: 1)),
        attributes: .init(color: NSColor(red: 0.82, green: 0.66, blue: 1.0, alpha: 1)),
        variables: .init(color: NSColor(red: 0.51, green: 0.79, blue: 0.87, alpha: 1)),
        values: .init(color: NSColor(red: 0.95, green: 0.65, blue: 0.25, alpha: 1)),
        numbers: .init(color: NSColor(red: 0.95, green: 0.65, blue: 0.25, alpha: 1)),
        strings: .init(color: NSColor(red: 0.40, green: 0.80, blue: 0.40, alpha: 1)),
        characters: .init(color: .systemYellow),
        comments: .init(color: NSColor(red: 0.55, green: 0.55, blue: 0.57, alpha: 1), italic: true)
    )

    static let zmuxLight = EditorTheme(
        text: .init(color: NSColor(red: 0.118, green: 0.118, blue: 0.118, alpha: 1)),
        insertionPoint: .black,
        invisibles: .init(color: NSColor(white: 0.7, alpha: 1)),
        background: .white,
        lineHighlight: NSColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1),
        selection: NSColor(red: 0.70, green: 0.82, blue: 0.98, alpha: 1),
        keywords: .init(color: NSColor(red: 0.55, green: 0.15, blue: 0.70, alpha: 1)),
        commands: .init(color: NSColor(red: 0.15, green: 0.35, blue: 0.75, alpha: 1)),
        types: .init(color: NSColor(red: 0.15, green: 0.35, blue: 0.75, alpha: 1)),
        attributes: .init(color: NSColor(red: 0.32, green: 0.16, blue: 0.54, alpha: 1)),
        variables: .init(color: NSColor(red: 0.20, green: 0.40, blue: 0.60, alpha: 1)),
        values: .init(color: NSColor(red: 0.80, green: 0.45, blue: 0.10, alpha: 1)),
        numbers: .init(color: NSColor(red: 0.80, green: 0.45, blue: 0.10, alpha: 1)),
        strings: .init(color: NSColor(red: 0.15, green: 0.50, blue: 0.15, alpha: 1)),
        characters: .init(color: .systemOrange),
        comments: .init(color: NSColor(red: 0.45, green: 0.45, blue: 0.47, alpha: 1), italic: true)
    )
}
