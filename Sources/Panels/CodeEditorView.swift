import AppKit
import Carbon.HIToolbox
import CodeEditLanguages
import CodeEditSourceEditor
import SwiftUI

enum CodeEditorSettings {
    static let showMinimapKey = "codeEditor.showMinimap"
    static let showFoldingRibbonKey = "codeEditor.showFoldingRibbon"
    static let showReformattingGuideKey = "codeEditor.showReformattingGuide"
    static let showInvisibleCharactersKey = "codeEditor.showInvisibleCharacters"
    static let showWarningCharactersKey = "codeEditor.showWarningCharacters"
    static let wrapLinesKey = "codeEditor.wrapLines"
    static let tabWidthKey = "codeEditor.tabWidth"
    static let reformatColumnKey = "codeEditor.reformatColumn"

    static let defaultShowMinimap = true
    static let defaultShowFoldingRibbon = true
    static let defaultShowReformattingGuide = false
    static let defaultShowInvisibleCharacters = false
    static let defaultShowWarningCharacters = true
    static let defaultWrapLines = true
    static let defaultTabWidth = 4
    static let defaultReformatColumn = 80

    static func sanitizedTabWidth(_ value: Int) -> Int {
        min(8, max(2, value))
    }

    static func sanitizedReformatColumn(_ value: Int) -> Int {
        min(160, max(40, value))
    }

    static func invisibleConfiguration(isEnabled: Bool) -> InvisibleCharactersConfiguration {
        guard isEnabled else { return .empty }
        return InvisibleCharactersConfiguration(showSpaces: true, showTabs: true, showLineEndings: false)
    }

    static func warningCharacters(isEnabled: Bool) -> Set<UInt16> {
        guard isEnabled else { return [] }
        return [
            0x00A0, // no-break space
            0x200B, 0x200C, 0x200D, 0xFEFF, // zero-width characters
            0x2018, 0x2019, 0x201C, 0x201D, // curly quotes
        ]
    }

    static func sourceEditorConfiguration(
        isEditable: Bool,
        isDarkMode: Bool,
        performanceMode: Bool,
        showMinimap: Bool,
        showFoldingRibbon: Bool,
        showReformattingGuide: Bool,
        showInvisibleCharacters: Bool,
        showWarningCharacters: Bool,
        wrapLines: Bool,
        tabWidth: Int,
        reformatColumn: Int
    ) -> SourceEditorConfiguration {
        let resolvedTabWidth = sanitizedTabWidth(tabWidth)
        let resolvedReformatColumn = sanitizedReformatColumn(reformatColumn)

        return SourceEditorConfiguration(
            appearance: .init(
                theme: isDarkMode ? .zmuxDark : .zmuxLight,
                font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                lineHeightMultiple: 1.3,
                wrapLines: wrapLines,
                tabWidth: resolvedTabWidth
            ),
            behavior: .init(
                isEditable: isEditable,
                isSelectable: true,
                indentOption: .spaces(count: resolvedTabWidth),
                reformatAtColumn: resolvedReformatColumn
            ),
            layout: .init(),
            peripherals: .init(
                showGutter: true,
                showMinimap: !performanceMode && showMinimap,
                showReformattingGuide: !performanceMode && showReformattingGuide,
                showFoldingRibbon: !performanceMode && showFoldingRibbon,
                invisibleCharactersConfiguration: invisibleConfiguration(
                    isEnabled: !performanceMode && showInvisibleCharacters
                ),
                warningCharacters: warningCharacters(isEnabled: !performanceMode && showWarningCharacters),
                codeSuggestionTriggerCharacters: CodeEditorHub.triggerCharacters
            )
        )
    }
}

@MainActor
enum CodeEditorStateCache {
    private static var states: [String: SourceEditorState] = [:]

    static func state(for filePath: String) -> SourceEditorState {
        states[filePath] ?? SourceEditorState()
    }

    static func store(_ state: SourceEditorState, for filePath: String) {
        states[filePath] = state
    }

    static func removeState(for filePath: String) {
        states.removeValue(forKey: filePath)
    }

    static func removeAll() {
        states.removeAll()
    }
}

struct CodeEditorCursorStatus: Equatable {
    let line: Int
    let column: Int
}

struct FileCodeEditorView: View {
    @Binding var content: String
    let isEditable: Bool
    let language: FileLanguage
    let isDarkMode: Bool
    let filePath: String
    let rootPath: String
    let performanceMode: Bool
    let fileSuggestions: (String, Int) async -> [IndexedFile]
    let onOpenLocalDefinition: (String, CursorPosition?) -> Void
    let onCursorPositionChange: (CodeEditorCursorStatus?) -> Void
    let onSave: (() -> Void)?

    @State private var state = SourceEditorState()
    @State private var hub = CodeEditorHub()

    @AppStorage(CodeEditorSettings.showMinimapKey)
    private var showMinimap = CodeEditorSettings.defaultShowMinimap
    @AppStorage(CodeEditorSettings.showFoldingRibbonKey)
    private var showFoldingRibbon = CodeEditorSettings.defaultShowFoldingRibbon
    @AppStorage(CodeEditorSettings.showReformattingGuideKey)
    private var showReformattingGuide = CodeEditorSettings.defaultShowReformattingGuide
    @AppStorage(CodeEditorSettings.showInvisibleCharactersKey)
    private var showInvisibleCharacters = CodeEditorSettings.defaultShowInvisibleCharacters
    @AppStorage(CodeEditorSettings.showWarningCharactersKey)
    private var showWarningCharacters = CodeEditorSettings.defaultShowWarningCharacters
    @AppStorage(CodeEditorSettings.wrapLinesKey)
    private var wrapLines = CodeEditorSettings.defaultWrapLines
    @AppStorage(CodeEditorSettings.tabWidthKey)
    private var tabWidth = CodeEditorSettings.defaultTabWidth
    @AppStorage(CodeEditorSettings.reformatColumnKey)
    private var reformatColumn = CodeEditorSettings.defaultReformatColumn

    init(
        content: Binding<String>,
        isEditable: Bool,
        language: FileLanguage,
        isDarkMode: Bool,
        filePath: String,
        rootPath: String,
        performanceMode: Bool,
        fileSuggestions: @escaping (String, Int) async -> [IndexedFile] = { _, _ in [] },
        onOpenLocalDefinition: @escaping (String, CursorPosition?) -> Void = { _, _ in },
        onCursorPositionChange: @escaping (CodeEditorCursorStatus?) -> Void = { _ in },
        onSave: (() -> Void)? = nil
    ) {
        _content = content
        self.isEditable = isEditable
        self.language = language
        self.isDarkMode = isDarkMode
        self.filePath = filePath
        self.rootPath = rootPath
        self.performanceMode = performanceMode
        self.fileSuggestions = fileSuggestions
        self.onOpenLocalDefinition = onOpenLocalDefinition
        self.onCursorPositionChange = onCursorPositionChange
        self.onSave = onSave
    }

    var body: some View {
        SourceEditor(
            $content,
            language: language.codeLanguage,
            configuration: CodeEditorSettings.sourceEditorConfiguration(
                isEditable: isEditable,
                isDarkMode: isDarkMode,
                performanceMode: performanceMode,
                showMinimap: showMinimap,
                showFoldingRibbon: showFoldingRibbon,
                showReformattingGuide: showReformattingGuide,
                showInvisibleCharacters: showInvisibleCharacters,
                showWarningCharacters: showWarningCharacters,
                wrapLines: wrapLines,
                tabWidth: tabWidth,
                reformatColumn: reformatColumn
            ),
            state: $state,
            coordinators: [hub],
            completionDelegate: hub,
            jumpToDefinitionDelegate: hub
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CodeEditorKeyMonitor(onSave: onSave))
        .onAppear {
            configureHub()
            let cachedState = CodeEditorStateCache.state(for: filePath)
            if cachedState != state {
                state = cachedState
            }
        }
        .onChange(of: state) { newValue in
            CodeEditorStateCache.store(newValue, for: filePath)
        }
        .onDisappear {
            CodeEditorStateCache.store(state, for: filePath)
            onCursorPositionChange(nil)
        }
    }

    private func configureHub() {
        hub.configure(
            filePath: filePath,
            rootPath: rootPath,
            currentText: { content },
            fileSuggestions: fileSuggestions,
            onOpenLocalDefinition: onOpenLocalDefinition,
            onCursorPositionChange: onCursorPositionChange
        )
    }
}

// MARK: - CodeEdit public coordinators

final class CodeEditorHub: TextViewCoordinator, CodeSuggestionDelegate, JumpToDefinitionDelegate {
    static let triggerCharacters = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./".map { String($0) }
    )

    private weak var controller: TextViewController?
    private var filePath = ""
    private var rootPath = ""
    private var currentText: () -> String = { "" }
    private var fileSuggestions: (String, Int) async -> [IndexedFile] = { _, _ in [] }
    private var onOpenLocalDefinition: (String, CursorPosition?) -> Void = { _, _ in }
    private var onCursorPositionChange: (CodeEditorCursorStatus?) -> Void = { _ in }
    private var lastSuggestions: [CodeEditorSuggestionEntry] = []

    func configure(
        filePath: String,
        rootPath: String,
        currentText: @escaping () -> String,
        fileSuggestions: @escaping (String, Int) async -> [IndexedFile],
        onOpenLocalDefinition: @escaping (String, CursorPosition?) -> Void,
        onCursorPositionChange: @escaping (CodeEditorCursorStatus?) -> Void
    ) {
        self.filePath = filePath
        self.rootPath = rootPath
        self.currentText = currentText
        self.fileSuggestions = fileSuggestions
        self.onOpenLocalDefinition = onOpenLocalDefinition
        self.onCursorPositionChange = onCursorPositionChange
    }

    func prepareCoordinator(controller: TextViewController) {
        self.controller = controller
        publishCursor(controller.cursorPositions.first)
    }

    func textViewDidChangeText(controller: TextViewController) {
        publishCursor(controller.cursorPositions.first)
    }

    func textViewDidChangeSelection(controller: TextViewController, newPositions: [CursorPosition]) {
        publishCursor(newPositions.first)
    }

    func controllerDidDisappear(controller: TextViewController) {
        if self.controller === controller {
            self.controller = nil
        }
    }

    func destroy() {
        controller = nil
        lastSuggestions = []
        onCursorPositionChange(nil)
    }

    func completionTriggerCharacters() -> Set<String> {
        Self.triggerCharacters
    }

    func completionSuggestionsRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) async -> (windowPosition: CursorPosition, items: [CodeSuggestionEntry])? {
        guard let request = Self.completionRequest(in: textView.text, cursorPosition: cursorPosition),
              request.prefix.count >= 2
        else {
            lastSuggestions = []
            return nil
        }

        let words = Self.localWordCandidates(in: textView.text, prefix: request.prefix, limit: 16)
            .map {
                CodeEditorSuggestionEntry(
                    label: $0,
                    detail: String(localized: "codeEditor.suggestions.documentWord", defaultValue: "Document word"),
                    documentation: nil,
                    pathComponents: nil,
                    targetPosition: nil,
                    sourcePreview: nil,
                    image: Image(systemName: "textformat"),
                    imageColor: .secondary,
                    replacementRange: request.replacementRange,
                    replacementText: $0
                )
            }

        let files = await fileSuggestions(request.prefix, 8)
        let fileEntries = files.map { entry in
            CodeEditorSuggestionEntry(
                label: entry.name,
                detail: relativePath(for: entry.path),
                documentation: nil,
                pathComponents: pathComponents(for: entry.path),
                targetPosition: CursorPosition(line: 1, column: 1),
                sourcePreview: relativePath(for: entry.path),
                image: Image(systemName: "doc"),
                imageColor: .blue,
                replacementRange: request.replacementRange,
                replacementText: entry.name
            )
        }

        lastSuggestions = Array((words + fileEntries).prefix(24))
        guard !lastSuggestions.isEmpty else { return nil }
        return (CursorPosition(range: request.replacementRange), lastSuggestions)
    }

    func completionOnCursorMove(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) -> [CodeSuggestionEntry]? {
        guard let request = Self.completionRequest(in: textView.text, cursorPosition: cursorPosition),
              request.prefix.count >= 2
        else { return nil }

        let lowerPrefix = request.prefix.lowercased()
        let filtered = lastSuggestions.filter { $0.label.lowercased().hasPrefix(lowerPrefix) }
        return filtered.isEmpty ? nil : filtered
    }

    func completionWindowApplyCompletion(
        item: CodeSuggestionEntry,
        textView: TextViewController,
        cursorPosition: CursorPosition?
    ) {
        if let entry = item as? CodeEditorSuggestionEntry {
            textView.textView.insertText(entry.replacementText, replacementRange: entry.replacementRange)
        } else {
            textView.textView.insertText(item.label)
        }
    }

    func queryLinks(forRange range: NSRange, textView: TextViewController) async -> [JumpToDefinitionLink]? {
        guard let token = Self.localReferenceToken(in: textView.text, range: range) else { return nil }
        let paths = await localDefinitionPaths(for: token)
        guard !paths.isEmpty else { return nil }
        return paths.map { path in
            JumpToDefinitionLink(
                url: URL(fileURLWithPath: path),
                targetRange: CursorPosition(line: 1, column: 1),
                typeName: (path as NSString).lastPathComponent,
                sourcePreview: relativePath(for: path),
                documentation: nil,
                image: Image(systemName: "doc.text.magnifyingglass"),
                imageColor: .blue
            )
        }
    }

    func openLink(link: JumpToDefinitionLink) {
        guard let url = link.url, url.isFileURL else { return }
        let path = url.path
        guard isPathInsideRoot(path) else { return }
        onOpenLocalDefinition(path, link.targetRange)
    }

    static func localWordCandidates(in text: String, prefix: String, limit: Int) -> [String] {
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPrefix.count >= 2 else { return [] }

        let pattern = #"[A-Za-z_][A-Za-z0-9_]{2,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let lowerPrefix = trimmedPrefix.lowercased()
        var seen = Set<String>()
        var candidates: [String] = []

        regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let range = match?.range else { return }
            let word = nsText.substring(with: range)
            let lowerWord = word.lowercased()
            guard lowerWord != lowerPrefix,
                  lowerWord.hasPrefix(lowerPrefix),
                  seen.insert(lowerWord).inserted
            else { return }
            candidates.append(word)
        }

        candidates.sort { lhs, rhs in
            let lowerLHS = lhs.lowercased()
            let lowerRHS = rhs.lowercased()
            if lowerLHS != lowerRHS { return lowerLHS < lowerRHS }
            if lhs.count != rhs.count { return lhs.count < rhs.count }
            return lhs < rhs
        }
        return Array(candidates.prefix(limit))
    }

    private func publishCursor(_ cursor: CursorPosition?) {
        guard let cursor, cursor.start.line > 0, cursor.start.column > 0 else {
            onCursorPositionChange(nil)
            return
        }
        onCursorPositionChange(CodeEditorCursorStatus(line: cursor.start.line, column: cursor.start.column))
    }

    private func localDefinitionPaths(for token: String) async -> [String] {
        var paths: [String] = []
        let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`()[]{}<>"))
        if let direct = directLocalPath(for: cleaned) {
            paths.append(direct)
        }

        let hits = await fileSuggestions(cleaned, 12)
        for hit in hits where hit.name == cleaned || hit.path.hasSuffix("/" + cleaned) {
            if isPathInsideRoot(hit.path), !paths.contains(hit.path) {
                paths.append(hit.path)
            }
        }
        return paths
    }

    private func directLocalPath(for token: String) -> String? {
        guard !token.isEmpty else { return nil }
        let fm = FileManager.default
        let candidates: [String]
        if token.hasPrefix("/") {
            candidates = [token]
        } else {
            let fileDirectory = (filePath as NSString).deletingLastPathComponent
            candidates = [
                (fileDirectory as NSString).appendingPathComponent(token),
                (rootPath as NSString).appendingPathComponent(token),
            ]
        }
        return candidates
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            .first { path in
                var isDirectory: ObjCBool = false
                return fm.fileExists(atPath: path, isDirectory: &isDirectory)
                    && !isDirectory.boolValue
                    && isPathInsideRoot(path)
            }
    }

    private func isPathInsideRoot(_ path: String) -> Bool {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let standardizedRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        return standardizedPath == standardizedRoot || standardizedPath.hasPrefix(standardizedRoot + "/")
    }

    private func relativePath(for path: String) -> String {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let standardizedRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        if standardizedPath.hasPrefix(standardizedRoot + "/") {
            return String(standardizedPath.dropFirst(standardizedRoot.count + 1))
        }
        return path
    }

    private func pathComponents(for path: String) -> [String] {
        relativePath(for: path).split(separator: "/").map(String.init)
    }

    private static func completionRequest(
        in text: String,
        cursorPosition: CursorPosition
    ) -> (prefix: String, replacementRange: NSRange)? {
        let nsText = text as NSString
        guard nsText.length > 0 else { return nil }
        let location = min(max(0, cursorPosition.range.location), nsText.length)
        var start = location
        while start > 0, isIdentifierCharacter(nsText.character(at: start - 1)) {
            start -= 1
        }
        let range = NSRange(location: start, length: location - start)
        return (nsText.substring(with: range), range)
    }

    private static func localReferenceToken(in text: String, range: NSRange) -> String? {
        let nsText = text as NSString
        guard nsText.length > 0 else { return nil }
        let anchor = min(max(0, range.location), max(nsText.length - 1, 0))
        var start = anchor
        while start > 0, isPathCharacter(nsText.character(at: start - 1)) {
            start -= 1
        }
        var end = anchor
        while end < nsText.length, isPathCharacter(nsText.character(at: end)) {
            end += 1
        }
        guard end > start else { return nil }
        let token = nsText.substring(with: NSRange(location: start, length: end - start))
        return token.isEmpty ? nil : token
    }

    private static func isIdentifierCharacter(_ character: unichar) -> Bool {
        (character >= 65 && character <= 90)
            || (character >= 97 && character <= 122)
            || (character >= 48 && character <= 57)
            || character == 95
            || character == 46
            || character == 47
    }

    private static func isPathCharacter(_ character: unichar) -> Bool {
        isIdentifierCharacter(character)
            || character == 45
            || character == 64
            || character == 126
    }
}

private struct CodeEditorSuggestionEntry: CodeSuggestionEntry {
    let label: String
    let detail: String?
    let documentation: String?
    let pathComponents: [String]?
    let targetPosition: CursorPosition?
    let sourcePreview: String?
    let image: Image
    let imageColor: Color
    let replacementRange: NSRange
    let replacementText: String
    let deprecated = false
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
