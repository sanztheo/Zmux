import SwiftUI
import UniformTypeIdentifiers

struct FileExplorerTabView: View {
    @ObservedObject var panel: FileExplorerPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let onRequestPanelFocus: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    /// Single `NSEvent` local monitor that commits any in-flight rename when the user clicks
    /// outside the inline `TextField`. Lifetime is tied to `panel.renamingPath`: installed
    /// only while a rename is active, removed the instant it ends or the view goes away.
    /// Per-row monitors leak under `LazyVStack` recycling, so we own it here at the panel
    /// level — exactly one monitor exists at a time.
    @State private var renameOutsideClickMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            GeometryReader { geo in
                HStack(spacing: 0) {
                    sidebar
                        .frame(width: min(280, max(220, geo.size.width * 0.25)))
                    Divider()
                    contentArea
                        .frame(width: geo.size.width - min(280, max(220, geo.size.width * 0.25)) - 1)
                }
            }
            Divider()
            footerBar
        }
        .background(backgroundColor)
        .simultaneousGesture(
            TapGesture()
                .onEnded { onRequestPanelFocus() }
        )
        .onChange(of: panel.renamingPath) { newPath in
            if newPath != nil {
                installRenameOutsideClickMonitor()
            } else {
                removeRenameOutsideClickMonitor()
            }
        }
        .onDisappear { removeRenameOutsideClickMonitor() }
    }

    /// Install the global click monitor. Every leftMouseDown/rightMouseDown is hit-tested
    /// against the window's view tree — clicks landing inside an `NSTextField`/`NSTextView`
    /// ancestor pass through untouched (so the user can still click around inside the rename
    /// TextField); anything else commits the rename.
    private func installRenameOutsideClickMonitor() {
        guard renameOutsideClickMonitor == nil else { return }
        let panelRef = panel
        renameOutsideClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { event in
            guard let contentView = event.window?.contentView else { return event }
            let hit = contentView.hitTest(event.locationInWindow)
            if !FileExplorerTabView.isInsideTextField(hit) {
                // Defer commit so the click finishes propagating first. Committing
                // synchronously inside the monitor sometimes drops the click that was
                // about to land on a folder row.
                DispatchQueue.main.async {
                    guard panelRef.renamingPath != nil else { return }
                    _ = panelRef.commitRename()
                }
            }
            return event
        }
    }

    private func removeRenameOutsideClickMonitor() {
        if let monitor = renameOutsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            renameOutsideClickMonitor = nil
        }
    }

    /// Walks the view tree from `view` upward looking for an `NSTextField`/`NSTextView`
    /// ancestor. SwiftUI wraps `TextField` in an `NSTextField` whose editor is an
    /// `NSTextView`; either type counts as "inside the rename field" for outside-click
    /// detection.
    private static func isInsideTextField(_ view: NSView?) -> Bool {
        var current = view
        while let v = current {
            if v is NSTextView || v is NSTextField { return true }
            current = v.superview
        }
        return false
    }

    // MARK: - Header (path + hidden toggle only — toolbar lives in section header below)

    private var headerBar: some View {
        HStack(spacing: 8) {
            Text(abbreviateHome(panel.rootPath))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                panel.showHiddenFiles.toggle()
                panel.refresh()
            } label: {
                Image(systemName: panel.showHiddenFiles ? "eye" : "eye.slash")
                    .font(.system(size: 11))
                Text(String(localized: "fileExplorer.hidden", defaultValue: "Hidden"))
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// Default parent for "new file/folder" toolbar actions. Prefers the user's last-clicked
    /// folder (VSCode "focused" state), falls back to the open file's parent, then root.
    private var parentDirectoryForCreate: String? {
        panel.activeFolder ?? panel.selectedFile
    }

    // MARK: - Sidebar (tab bar + content based on mode)

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarTabBar
            Divider()
            if panel.sidebarMode == .files {
                filesView
            } else {
                searchModeView
            }
        }
        // Background-attached AppKit key monitor: when the sidebar is the focused
        // panel, cmd+C / cmd+X / cmd+V / cmd+Backspace operate on the active row
        // (selected file or active folder). Without this, those shortcuts only fire
        // when the row's context menu is open, since SwiftUI's `Button.keyboardShortcut`
        // inside `.contextMenu` is scoped to that menu.
        .background(
            FileExplorerKeyHandler(panel: panel, isActive: isFocused)
        )
    }

    private var sidebarTabBar: some View {
        HStack(spacing: 4) {
            sidebarTabButton(
                mode: .files,
                systemImage: "doc.on.doc",
                label: String(localized: "fileExplorer.tab.files", defaultValue: "Files")
            )
            sidebarTabButton(
                mode: .search,
                systemImage: "magnifyingglass",
                label: String(localized: "fileExplorer.tab.search", defaultValue: "Search")
            )
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func sidebarTabButton(
        mode: FileExplorerSidebarMode,
        systemImage: String,
        label: String
    ) -> some View {
        let isActive = panel.sidebarMode == mode
        Button {
            panel.sidebarMode = mode
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .frame(width: 28, height: 24)
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isActive ? Color.primary.opacity(0.10) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(label)
    }

    // MARK: - Files mode

    private var filesView: some View {
        VStack(spacing: 0) {
            sectionHeaderBar
            Divider()
            treeListView
        }
    }

    private var sectionHeaderBar: some View {
        HStack(spacing: 6) {
            Text(sectionHeaderTitle.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(sectionHeaderHelp)
            Spacer()
            sectionHeaderButton(systemImage: "doc.badge.plus", help: "fileExplorer.newFile") {
                panel.createNewFile(in: parentDirectoryForCreate)
            }
            sectionHeaderButton(systemImage: "folder.badge.plus", help: "fileExplorer.newFolder") {
                panel.createNewFolder(in: parentDirectoryForCreate)
            }
            sectionHeaderButton(systemImage: "arrow.clockwise", help: "fileExplorer.refresh") {
                panel.refresh()
            }
            sectionHeaderButton(
                systemImage: "rectangle.compress.vertical",
                help: "fileExplorer.collapseAll"
            ) {
                panel.collapseAll()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func sectionHeaderButton(
        systemImage: String,
        help helpKey: String.LocalizationValue,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .help(String(localized: helpKey))
    }

    private var rootDisplayName: String {
        (panel.rootPath as NSString).lastPathComponent
    }

    /// Display title for the section header — root name normally, but when an active folder
    /// is selected we show "ROOT / SUBDIR" so the user can see where New File/Folder will land.
    private var sectionHeaderTitle: String {
        guard let active = panel.activeFolder, active != panel.rootPath else {
            return rootDisplayName
        }
        let activeName = (active as NSString).lastPathComponent
        return "\(rootDisplayName) / \(activeName)"
    }

    /// Tooltip showing the absolute destination path for create actions.
    private var sectionHeaderHelp: String {
        panel.activeFolder ?? panel.rootPath
    }

    // MARK: - Search mode (VSCode-style search panel)

    private var searchModeView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 11))
                TextField(
                    String(localized: "fileExplorer.filter", defaultValue: "Filter..."),
                    text: $panel.filterQuery
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onChange(of: panel.filterQuery) { newValue in
                    panel.scheduleSearch(query: newValue)
                }
                if !panel.filterQuery.isEmpty {
                    Button {
                        panel.filterQuery = ""
                        panel.scheduleSearch(query: "")
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            if panel.filterQuery.isEmpty {
                emptySearchPlaceholder
            } else {
                searchListView
            }
        }
    }

    private var emptySearchPlaceholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text(String(
                localized: "fileExplorer.search.placeholder",
                defaultValue: "Type to search files"
            ))
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var treeListView: some View {
        // SwiftUI `LazyVStack` of rows. Drag-and-drop within the explorer is
        // intentionally unimplemented (macOS SwiftUI bug FB12980427: `.onDrag` /
        // `.onDrop` don't fire on `LazyVStack`, and every AppKit workaround we tried
        // either consumed clicks or never received drag events). Users move files via
        // the row context menu's `Cut` → folder context menu's `Paste`, which is
        // wired to `cmd+X` / `cmd+V` keyboard shortcuts on the sidebar.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(flattenedNodes, id: \.node.id) { entry in
                    FileNodeRow(
                        node: entry.node,
                        depth: entry.depth,
                        isExpanded: entry.isExpanded,
                        isSelected: entry.isSelected,
                        isActiveFolder: entry.isActiveFolder,
                        isCut: entry.isCut,
                        isRenaming: entry.isRenaming,
                        isContextMenuTarget: entry.isContextMenuTarget,
                        renameDraft: entry.renameDraft,
                        onTap: entry.onTap,
                        onRevealInFinder: entry.onRevealInFinder,
                        onOpenInTerminal: entry.onOpenInTerminal,
                        onCut: entry.onCut,
                        onCopy: entry.onCopy,
                        onCopyPath: entry.onCopyPath,
                        onCopyRelativePath: entry.onCopyRelativePath,
                        onPaste: entry.onPaste,
                        onRename: entry.onRename,
                        onDelete: entry.onDelete,
                        onNewFileHere: entry.onNewFileHere,
                        onNewFolderHere: entry.onNewFolderHere,
                        onRenameDraftChange: entry.onRenameDraftChange,
                        onRenameCommit: entry.onRenameCommit,
                        onRenameCancel: entry.onRenameCancel,
                        onContextMenuOpen: entry.onContextMenuOpen,
                        onContextMenuClose: entry.onContextMenuClose
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear
                .frame(maxWidth: .infinity, minHeight: 80, alignment: .top)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    panel.createNewFile(in: nil)
                }
                .contextMenu {
                    emptyAreaContextMenu
                }
        }
    }

    @ViewBuilder
    private var emptyAreaContextMenu: some View {
        Button(String(localized: "fileExplorer.menu.newFile", defaultValue: "New File")) {
            panel.createNewFile(in: nil)
        }
        Button(String(localized: "fileExplorer.menu.newFolder", defaultValue: "New Folder")) {
            panel.createNewFolder(in: nil)
        }
        Divider()
        Button(String(localized: "fileExplorer.menu.paste", defaultValue: "Paste")) {
            panel.pasteClipboard(into: nil)
        }
        .disabled(!panel.canPaste())
        Divider()
        Button(String(localized: "fileExplorer.menu.revealInFinder", defaultValue: "Reveal in Finder")) {
            panel.revealInFinder(panel.rootPath)
        }
        Button(String(localized: "fileExplorer.menu.openInTerminal", defaultValue: "Open in Integrated Terminal")) {
            panel.openInIntegratedTerminal(panel.rootPath)
        }
    }

    private var searchListView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(flattenedSearchResults, id: \.id) { entry in
                    FileSearchRow(
                        name: entry.name,
                        relativeParent: entry.relativeParent,
                        isSelected: entry.isSelected,
                        onTap: entry.onTap
                    )
                }
                if flattenedSearchResults.isEmpty, !panel.isIndexing {
                    Text(String(
                        localized: "fileExplorer.noMatches",
                        defaultValue: "No files match"
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                }
            }
        }
    }

    private var flattenedSearchResults: [FlatSearchEntry] {
        let root = panel.rootPath
        let selected = panel.selectedFile
        return panel.searchResults.map { entry in
            let relative = relativeDirectory(parent: entry.parentPath, root: root)
            let capturedPath = entry.path
            return FlatSearchEntry(
                id: entry.path,
                name: entry.name,
                relativeParent: relative,
                isSelected: selected == entry.path,
                onTap: { [weak panel] in
                    panel?.openFile(capturedPath)
                }
            )
        }
    }

    private func relativeDirectory(parent: String, root: String) -> String {
        if parent == root { return "" }
        if parent.hasPrefix(root + "/") {
            return String(parent.dropFirst(root.count + 1))
        }
        return (parent as NSString).lastPathComponent
    }

    private var flattenedNodes: [FlatNodeEntry] {
        var result: [FlatNodeEntry] = []
        func walk(_ nodes: [FileNode], depth: Int) {
            for node in nodes {
                let isExpanded = panel.expandedDirs.contains(node.path)
                let isSelected = panel.selectedFile == node.path
                let isActiveFolder = node.isDirectory && panel.activeFolder == node.path
                let isCut = panel.cutPaths.contains(node.path)
                let isRenaming = panel.renamingPath == node.path
                let isContextMenuTarget = panel.contextMenuPath == node.path
                let renameDraft = isRenaming ? panel.renameDraft : ""
                let capturedPath = node.path
                let capturedIsDir = node.isDirectory
                result.append(FlatNodeEntry(
                    node: node,
                    depth: depth,
                    isExpanded: isExpanded,
                    isSelected: isSelected,
                    isActiveFolder: isActiveFolder,
                    isCut: isCut,
                    isRenaming: isRenaming,
                    isContextMenuTarget: isContextMenuTarget,
                    renameDraft: renameDraft,
                    onTap: { [weak panel] in
                        guard let panel else { return }
                        if capturedIsDir {
                            if isExpanded {
                                panel.collapseDirectory(capturedPath)
                            } else {
                                panel.expandDirectory(capturedPath)
                            }
                        } else {
                            panel.openFile(capturedPath)
                        }
                    },
                    onRevealInFinder: { [weak panel] in
                        panel?.revealInFinder(capturedPath)
                    },
                    onOpenInTerminal: { [weak panel] in
                        panel?.openInIntegratedTerminal(capturedPath)
                    },
                    onCut: { [weak panel] in
                        panel?.cutToClipboard([capturedPath])
                    },
                    onCopy: { [weak panel] in
                        panel?.copyToClipboard([capturedPath])
                    },
                    onCopyPath: { [weak panel] in
                        panel?.copyPath(capturedPath)
                    },
                    onCopyRelativePath: { [weak panel] in
                        panel?.copyRelativePath(capturedPath)
                    },
                    onPaste: { [weak panel] in
                        panel?.pasteClipboard(into: capturedPath)
                    },
                    onRename: { [weak panel] in
                        panel?.beginRename(path: capturedPath)
                    },
                    onDelete: { [weak panel] in
                        panel?.deleteItem(at: capturedPath)
                    },
                    onNewFileHere: { [weak panel] in
                        panel?.createNewFile(in: capturedPath)
                    },
                    onNewFolderHere: { [weak panel] in
                        panel?.createNewFolder(in: capturedPath)
                    },
                    onRenameDraftChange: { [weak panel] newValue in
                        panel?.renameDraft = newValue
                    },
                    onRenameCommit: { [weak panel] in
                        _ = panel?.commitRename()
                    },
                    onRenameCancel: { [weak panel] in
                        panel?.cancelRename()
                    },
                    onContextMenuOpen: { [weak panel] in
                        panel?.contextMenuPath = capturedPath
                    },
                    onContextMenuClose: { [weak panel] in
                        // Only clear if we're still the highlighted row — guards against the
                        // observer firing late after another row already grabbed the menu.
                        if panel?.contextMenuPath == capturedPath {
                            panel?.contextMenuPath = nil
                        }
                    }
                ))
                if node.isDirectory, isExpanded, let children = node.children {
                    walk(children, depth: depth + 1)
                }
            }
        }
        walk(panel.fileTree, depth: 0)
        return result
    }

    // MARK: - Content

    private var contentArea: some View {
        VStack(spacing: 0) {
            if let path = panel.selectedFile {
                fileHeaderBar(path: path)
                Divider()
                if panel.isFileBinary {
                    placeholderView(
                        icon: "doc.fill",
                        title: String(localized: "fileExplorer.binary", defaultValue: "Binary file")
                    )
                } else if panel.isFileTooLarge {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text(String(localized: "fileExplorer.tooLarge", defaultValue: "File too large (>1 MB)"))
                            .foregroundStyle(.secondary)
                        Button(String(localized: "fileExplorer.openAnyway", defaultValue: "Open anyway")) {
                            panel.isFileTooLarge = false
                            panel.openFile(path)
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    FileCodeEditorView(
                        content: $panel.fileContent,
                        isEditable: true,
                        language: panel.fileLanguage,
                        isDarkMode: colorScheme == .dark,
                        onSave: { panel.saveFile() }
                    )
                    .id(path)
                    .onChange(of: panel.fileContent) { _ in
                        panel.markDirty()
                    }
                }
            } else {
                placeholderView(
                    icon: "doc",
                    title: String(localized: "fileExplorer.selectFile", defaultValue: "Select a file")
                )
            }
        }
    }

    private func fileHeaderBar(path: String) -> some View {
        HStack(spacing: 8) {
            Button {
                panel.deselectFile()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            Text(path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if panel.isDirty {
                Button(String(localized: "fileExplorer.save", defaultValue: "Save")) {
                    panel.saveFile()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func placeholderView(icon: String, title: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(title)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 12) {
            if panel.selectedFile != nil {
                Text(panel.fileLanguage.rawValue.capitalized)
                Text("UTF-8")
                Text("\(lineCount) " + String(localized: "fileExplorer.linesUnit", defaultValue: "lines"))
                if panel.isDirty {
                    Circle()
                        .fill(.orange)
                        .frame(width: 8, height: 8)
                    Text(String(localized: "fileExplorer.modified", defaultValue: "Modified"))
                }
            }
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private var lineCount: Int {
        panel.fileContent.isEmpty ? 0 : panel.fileContent.components(separatedBy: "\n").count
    }

    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(white: 0.12, alpha: 1.0))
            : Color(nsColor: NSColor(white: 0.98, alpha: 1.0))
    }

    private func abbreviateHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - Flattened tree entry (snapshot boundary — no store references)

private struct FlatNodeEntry {
    let node: FileNode
    let depth: Int
    let isExpanded: Bool
    let isSelected: Bool
    let isActiveFolder: Bool
    let isCut: Bool
    let isRenaming: Bool
    let isContextMenuTarget: Bool
    let renameDraft: String
    let onTap: () -> Void
    let onRevealInFinder: () -> Void
    let onOpenInTerminal: () -> Void
    let onCut: () -> Void
    let onCopy: () -> Void
    let onCopyPath: () -> Void
    let onCopyRelativePath: () -> Void
    let onPaste: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onNewFileHere: () -> Void
    let onNewFolderHere: () -> Void
    let onRenameDraftChange: (String) -> Void
    let onRenameCommit: () -> Void
    let onRenameCancel: () -> Void
    let onContextMenuOpen: () -> Void
    let onContextMenuClose: () -> Void
}

private struct FileNodeRow: View {
    let node: FileNode
    let depth: Int
    let isExpanded: Bool
    let isSelected: Bool
    let isActiveFolder: Bool
    let isCut: Bool
    let isRenaming: Bool
    let isContextMenuTarget: Bool
    let renameDraft: String
    let onTap: () -> Void
    let onRevealInFinder: () -> Void
    let onOpenInTerminal: () -> Void
    let onCut: () -> Void
    let onCopy: () -> Void
    let onCopyPath: () -> Void
    let onCopyRelativePath: () -> Void
    let onPaste: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onNewFileHere: () -> Void
    let onNewFolderHere: () -> Void
    let onRenameDraftChange: (String) -> Void
    let onRenameCommit: () -> Void
    let onRenameCancel: () -> Void
    let onContextMenuOpen: () -> Void
    let onContextMenuClose: () -> Void

    var body: some View {
        rowContent
            .background(rowBackground)
            .overlay(
                RightClickCatcher(
                    onRightClick: onContextMenuOpen,
                    onDismiss: onContextMenuClose
                )
            )
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
            .contextMenu { rowContextMenu }
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected || isContextMenuTarget {
            Color.accentColor.opacity(0.15)
        } else if isActiveFolder {
            // VSCode "focused folder" — neutral subtle highlight, distinct from the
            // accent-tinted selection so the user can see which folder will receive
            // toolbar New File / New Folder actions.
            Color.primary.opacity(0.07)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var rowContent: some View {
        HStack(spacing: 4) {
            if node.isDirectory {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
            } else {
                Spacer().frame(width: 12)
            }
            MaterialIconView(
                iconID: materialIconID,
                fallbackSystemName: fallbackSystemName,
                size: 16
            )
            if isRenaming {
                RenameField(
                    draft: renameDraft,
                    onChange: onRenameDraftChange,
                    onCommit: onRenameCommit,
                    onCancel: onRenameCancel
                )
            } else {
                Text(node.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
        }
        .padding(.leading, CGFloat(depth) * 16 + 4)
        .padding(.vertical, 3)
        .padding(.trailing, 4)
        .opacity(isCut ? 0.45 : 1.0)
    }

    @ViewBuilder
    private var rowContextMenu: some View {
        if !node.isDirectory {
            Button(String(
                localized: "fileExplorer.menu.openPreview",
                defaultValue: "Open Preview"
            )) { onTap() }
            Divider()
        }
        Button(String(
            localized: "fileExplorer.menu.revealInFinder",
            defaultValue: "Reveal in Finder"
        )) { onRevealInFinder() }
        .keyboardShortcut("r", modifiers: [.option, .command])
        Button(String(
            localized: "fileExplorer.menu.openInTerminal",
            defaultValue: "Open in Integrated Terminal"
        )) { onOpenInTerminal() }
        if node.isDirectory {
            Divider()
            Button(String(
                localized: "fileExplorer.menu.newFile",
                defaultValue: "New File"
            )) { onNewFileHere() }
            Button(String(
                localized: "fileExplorer.menu.newFolder",
                defaultValue: "New Folder"
            )) { onNewFolderHere() }
        }
        Divider()
        Button(String(localized: "fileExplorer.menu.cut", defaultValue: "Cut")) { onCut() }
            .keyboardShortcut("x", modifiers: .command)
        Button(String(localized: "fileExplorer.menu.copy", defaultValue: "Copy")) { onCopy() }
            .keyboardShortcut("c", modifiers: .command)
        if node.isDirectory {
            Button(String(localized: "fileExplorer.menu.paste", defaultValue: "Paste")) {
                onPaste()
            }
        }
        Button(String(
            localized: "fileExplorer.menu.copyPath",
            defaultValue: "Copy Path"
        )) { onCopyPath() }
        .keyboardShortcut("c", modifiers: [.option, .command])
        Button(String(
            localized: "fileExplorer.menu.copyRelativePath",
            defaultValue: "Copy Relative Path"
        )) { onCopyRelativePath() }
        .keyboardShortcut("c", modifiers: [.option, .shift, .command])
        Divider()
        Button(String(localized: "fileExplorer.menu.rename", defaultValue: "Rename...")) {
            onRename()
        }
        .keyboardShortcut(.return, modifiers: [])
        Button(role: .destructive) {
            onDelete()
        } label: {
            Text(String(localized: "fileExplorer.menu.delete", defaultValue: "Delete"))
        }
        .keyboardShortcut(.delete, modifiers: .command)
    }

    /// Name to feed icon resolution. While renaming, follow the draft so the icon previews the
    /// new extension live as the user types (.ts → TypeScript, .md → Markdown, etc.).
    private var iconName: String {
        if isRenaming {
            let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return node.name
    }

    private var materialIconID: String {
        if node.isDirectory {
            return MaterialIconResolver.shared.iconID(forFolder: iconName, expanded: isExpanded)
        }
        return MaterialIconResolver.shared.iconID(forFile: iconName)
    }

    private var fallbackSystemName: String {
        if node.isDirectory {
            return isExpanded ? "folder.fill" : "folder"
        }
        let ext = (iconName as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "ts", "tsx": return "t.square"
        case "js", "jsx", "mjs", "cjs": return "j.square"
        case "py": return "p.square"
        case "json": return "curlybraces"
        case "md", "markdown": return "doc.richtext"
        default: return "doc"
        }
    }
}

// MARK: - Flat search result entry (snapshot boundary)

private struct FlatSearchEntry {
    let id: String
    let name: String
    let relativeParent: String
    let isSelected: Bool
    let onTap: () -> Void
}

private struct FileSearchRow: View {
    let name: String
    let relativeParent: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                MaterialIconView(
                    iconID: MaterialIconResolver.shared.iconID(forFile: name),
                    fallbackSystemName: fallbackSystemName,
                    size: 16
                )
                VStack(alignment: .leading, spacing: 0) {
                    Text(name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !relativeParent.isEmpty {
                        Text(relativeParent)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer()
            }
            .padding(.leading, 8)
            .padding(.vertical, 3)
            .padding(.trailing, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
    }

    private var fallbackSystemName: String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "ts", "tsx": return "t.square"
        case "js", "jsx", "mjs", "cjs": return "j.square"
        case "py": return "p.square"
        case "json": return "curlybraces"
        case "md", "markdown": return "doc.richtext"
        default: return "doc"
        }
    }
}


// MARK: - Right-click catcher

/// NSView overlay that catches `rightMouseDown` so the row can highlight while a SwiftUI
/// `.contextMenu` is open. SwiftUI's native `.contextMenu` provides no trigger callback,
/// so we intercept the AppKit event directly. Hit-testing is gated to right-mouse events
/// only, so left clicks fall through to the underlying SwiftUI gestures.
private struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: () -> Void
    let onDismiss: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = RightClickView()
        view.onRightClick = onRightClick
        view.onDismiss = onDismiss
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? RightClickView else { return }
        view.onRightClick = onRightClick
        view.onDismiss = onDismiss
    }

    private final class RightClickView: NSView {
        var onRightClick: (() -> Void)?
        var onDismiss: (() -> Void)?
        private var menuObserver: NSObjectProtocol?

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Only claim right-mouse events; pass through everything else.
            guard let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
                return self
            default:
                return nil
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            onRightClick?()
            // The SwiftUI context menu posts `NSMenu.didEndTrackingNotification` when it
            // closes — listen once so we can drop the row highlight.
            if menuObserver == nil {
                menuObserver = NotificationCenter.default.addObserver(
                    forName: NSMenu.didEndTrackingNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.onDismiss?()
                    if let observer = self?.menuObserver {
                        NotificationCenter.default.removeObserver(observer)
                        self?.menuObserver = nil
                    }
                }
            }
            super.rightMouseDown(with: event)
        }

        deinit {
            if let observer = menuObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}

// MARK: - Inline rename field

/// TextField that auto-focuses on appear, commits on Return, cancels on Escape, and pre-selects
/// the basename so typing replaces the file's stem (matches VSCode behavior). Snapshot-safe:
/// holds no store reference, only the current draft + closures.
///
/// Outside-click commit is handled at the parent (`FileExplorerTabView`) via a single
/// `NSEvent` local monitor whose lifecycle is tied to `panel.renamingPath`. Doing it here
/// per-row would leak monitors on `LazyVStack` recycling — every recycle would create a new
/// monitor without removing the old one, and orphaned monitors fire on every click for the
/// rest of the session.
private struct RenameField: View {
    let draft: String
    let onChange: (String) -> Void
    let onCommit: () -> Void
    let onCancel: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        TextField(
            "",
            text: Binding(
                get: { draft },
                set: { onChange($0) }
            )
        )
        .textFieldStyle(.plain)
        .font(.system(size: 12))
        .focused($focused)
        .onAppear {
            // Dispatch async so the underlying NSTextField is fully attached to the
            // responder chain before we try to make it first responder. Without this, the
            // focus request races against panel-level focus calls and the user has to
            // click the field manually before typing.
            DispatchQueue.main.async { focused = true }
        }
        .onSubmit { onCommit() }
        .onExitCommand { onCancel() }
        .padding(.vertical, 0)
        .padding(.horizontal, 2)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(Color.accentColor, lineWidth: 1)
        )
    }
}

// MARK: - Sidebar key shortcut handler

/// Background-attached `NSEvent` local monitor that wires `cmd+C` / `cmd+X` / `cmd+V`
/// / `cmd+Backspace` to the file explorer's clipboard + delete actions when the panel
/// is focused. Without this, those shortcuts only fire while a row's `.contextMenu` is
/// open — SwiftUI scopes `Button.keyboardShortcut` inside `.contextMenu` to the open
/// menu only.
///
/// The monitor is owned by a Coordinator (one instance per representable lifetime) and
/// removed on deinit, so opening multiple file explorer panels doesn't stack monitors.
private struct FileExplorerKeyHandler: NSViewRepresentable {
    let panel: FileExplorerPanel
    let isActive: Bool

    func makeNSView(context: Context) -> NSView {
        // Empty zero-frame host; the actual work happens in the coordinator's monitor.
        let view = NSView(frame: .zero)
        view.wantsLayer = false
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.panel = panel
        context.coordinator.isActive = isActive
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(panel: panel, isActive: isActive)
    }

    final class Coordinator {
        var panel: FileExplorerPanel
        var isActive: Bool
        private var monitor: Any?

        init(panel: FileExplorerPanel, isActive: Bool) {
            self.panel = panel
            self.isActive = isActive
            install()
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        private func install() {
            // The local monitor closure runs on the main thread (AppKit dispatches event
            // handling there), so reading `panel`/`isActive` and calling `panel`'s
            // MainActor-isolated methods is safe without explicit isolation.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard isActive else { return event }
            // Don't intercept while the user is typing in any text field — covers the
            // search field, the inline rename field, and the code editor.
            if let firstResponder = event.window?.firstResponder {
                if firstResponder is NSText
                    || firstResponder is NSTextField
                    || firstResponder is NSTextView {
                    return event
                }
            }
            // Only operate while the file tree tab is showing — search mode hands its
            // own keys to the search field and shouldn't react to clipboard shortcuts.
            guard panel.sidebarMode == .files else { return event }

            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods == .command else { return event }
            let chars = (event.charactersIgnoringModifiers ?? "").lowercased()

            // The "active" row for clipboard/delete is the open file when there is one,
            // otherwise the last-clicked folder. Mirrors VSCode's "selected explorer
            // item" semantics.
            let activeTarget: String? = panel.selectedFile ?? panel.activeFolder

            switch chars {
            case "c":
                guard let target = activeTarget else { return event }
                panel.copyToClipboard([target])
                return nil
            case "x":
                guard let target = activeTarget else { return event }
                panel.cutToClipboard([target])
                return nil
            case "v":
                let dest = panel.activeFolder
                    ?? panel.selectedFile.map { ($0 as NSString).deletingLastPathComponent }
                _ = panel.pasteClipboard(into: dest)
                return nil
            default:
                break
            }

            // cmd+Delete (Backspace) → move to Trash, matches Finder.
            if chars == "\u{7F}" || chars == "\u{8}" || event.keyCode == 51 {
                guard let target = activeTarget else { return event }
                _ = panel.deleteItem(at: target)
                return nil
            }

            return event
        }
    }
}
