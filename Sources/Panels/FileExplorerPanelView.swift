import CodeEditSourceEditor
import SwiftUI
import UniformTypeIdentifiers

struct FileExplorerTabView: View {
    @ObservedObject var panel: FileExplorerPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let onRequestPanelFocus: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    /// Persisted user choice: render `.md` files as rendered preview or as raw source.
    /// Default is `false` (raw markdown source) to preserve current behavior.
    @AppStorage("fileExplorer.markdownPreviewEnabled") private var markdownPreviewEnabled: Bool = false
    @AppStorage(CodeEditorSettings.showMinimapKey)
    private var editorShowMinimap = CodeEditorSettings.defaultShowMinimap
    @AppStorage(CodeEditorSettings.showFoldingRibbonKey)
    private var editorShowFoldingRibbon = CodeEditorSettings.defaultShowFoldingRibbon
    @AppStorage(CodeEditorSettings.showReformattingGuideKey)
    private var editorShowReformattingGuide = CodeEditorSettings.defaultShowReformattingGuide
    @AppStorage(CodeEditorSettings.showInvisibleCharactersKey)
    private var editorShowInvisibleCharacters = CodeEditorSettings.defaultShowInvisibleCharacters
    @AppStorage("fileExplorer.internalSidebarWidth")
    private var persistedSidebarWidth: Double = 240

    /// Single `NSEvent` local monitor that commits any in-flight rename when the user clicks
    /// outside the inline `TextField`. Lifetime is tied to `panel.renamingPath`: installed
    /// only while a rename is active, removed the instant it ends or the view goes away.
    /// Per-row monitors leak under `LazyVStack` recycling, so we own it here at the panel
    /// level — exactly one monitor exists at a time.
    @State private var renameOutsideClickMonitor: Any?
    @State private var pendingWorktreeSwitch: GitWorktreeSnapshot?
    @State private var showingDirtyWorktreeAlert = false
    @State private var sidebarDragStartWidth: Double?

    private static let minSidebarWidth: CGFloat = 180
    private static let maxSidebarWidth: CGFloat = 420
    private static let minEditorWidth: CGFloat = 360
    private static let resizeHandleWidth: CGFloat = 6

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                headerBar
                Divider()
                GeometryReader { geo in
                    let sidebarWidth = constrainedSidebarWidth(totalWidth: geo.size.width)
                    HStack(spacing: 0) {
                        sidebar
                            .frame(width: sidebarWidth)
                        FileExplorerSidebarResizeHandle(
                            onDragChanged: { translation in
                                resizeSidebar(translation: translation, totalWidth: geo.size.width)
                            },
                            onDragEnded: {
                                sidebarDragStartWidth = nil
                                persistedSidebarWidth = Double(constrainedSidebarWidth(totalWidth: geo.size.width))
                            }
                        )
                        .frame(width: Self.resizeHandleWidth)
                        contentArea
                            .frame(width: max(0, geo.size.width - sidebarWidth - Self.resizeHandleWidth))
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

            if panel.isQuickOpenPresented {
                quickOpenOverlay
            }
        }
        .onChange(of: panel.renamingPath) { newPath in
            if newPath != nil {
                installRenameOutsideClickMonitor()
            } else {
                removeRenameOutsideClickMonitor()
            }
        }
        .onAppear { panel.refreshWorktrees() }
        .onDisappear { removeRenameOutsideClickMonitor() }
        .alert(
            String(localized: "fileExplorer.worktree.dirtyAlert.title", defaultValue: "Switch worktree?"),
            isPresented: $showingDirtyWorktreeAlert
        ) {
            Button(String(localized: "fileExplorer.worktree.dirtyAlert.save", defaultValue: "Save")) {
                guard let pending = pendingWorktreeSwitch else { return }
                if panel.saveFile() {
                    panel.switchRoot(to: pending.path)
                }
                pendingWorktreeSwitch = nil
            }
            Button(String(localized: "fileExplorer.worktree.dirtyAlert.discard", defaultValue: "Discard"), role: .destructive) {
                guard let pending = pendingWorktreeSwitch else { return }
                panel.switchRoot(to: pending.path)
                pendingWorktreeSwitch = nil
            }
            Button(String(localized: "fileExplorer.worktree.dirtyAlert.cancel", defaultValue: "Cancel"), role: .cancel) {
                pendingWorktreeSwitch = nil
            }
        } message: {
            Text(String(
                localized: "fileExplorer.worktree.dirtyAlert.message",
                defaultValue: "The current file has unsaved changes. Save or discard them before switching worktrees."
            ))
        }
    }

    private var quickOpenOverlay: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.18)
                .onTapGesture { panel.dismissQuickOpen() }
            FileExplorerQuickOpenPalette(
                query: $panel.quickOpenQuery,
                results: quickOpenEntries,
                isIndexing: panel.isIndexing,
                onQueryChange: { panel.scheduleQuickOpenSearch(query: $0) },
                onDismiss: { panel.dismissQuickOpen() }
            )
            .frame(width: 560)
            .frame(maxWidth: .infinity)
            .padding(.top, 34)
            .padding(.horizontal, 24)
        }
    }

    private func constrainedSidebarWidth(totalWidth: CGFloat) -> CGFloat {
        let availableMax = max(Self.minSidebarWidth, totalWidth - Self.minEditorWidth - Self.resizeHandleWidth)
        let maxWidth = min(Self.maxSidebarWidth, availableMax)
        return min(max(CGFloat(persistedSidebarWidth), Self.minSidebarWidth), maxWidth)
    }

    private func resizeSidebar(translation: CGFloat, totalWidth: CGFloat) {
        if sidebarDragStartWidth == nil {
            sidebarDragStartWidth = persistedSidebarWidth
        }
        let startWidth = CGFloat(sidebarDragStartWidth ?? persistedSidebarWidth)
        let nextWidth = startWidth + translation
        let availableMax = max(Self.minSidebarWidth, totalWidth - Self.minEditorWidth - Self.resizeHandleWidth)
        let maxWidth = min(Self.maxSidebarWidth, availableMax)
        persistedSidebarWidth = Double(min(max(nextWidth, Self.minSidebarWidth), maxWidth))
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
            worktreeSelector
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

    @ViewBuilder
    private var worktreeSelector: some View {
        if !panel.availableWorktrees.isEmpty {
            Menu {
                ForEach(panel.availableWorktrees) { worktree in
                    Button {
                        requestWorktreeSwitch(worktree)
                    } label: {
                        HStack {
                            Text(worktree.displayName)
                            Text(worktreeSubtitle(for: worktree))
                        }
                    }
                    .disabled(worktree.path == panel.selectedWorktreePath)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 11))
                    Text(selectedWorktreeTitle)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: true, vertical: false)
            .help(String(localized: "fileExplorer.worktree.selector.help", defaultValue: "Switch worktree"))
        }
    }

    private var selectedWorktreeTitle: String {
        if let selected = panel.availableWorktrees.first(where: { $0.path == panel.selectedWorktreePath }) {
            return selected.displayName
        }
        return (panel.rootPath as NSString).lastPathComponent
    }

    private func worktreeSubtitle(for worktree: GitWorktreeSnapshot) -> String {
        if worktree.isBare {
            return String(localized: "fileExplorer.worktree.bare", defaultValue: "bare")
        }
        if worktree.isDetached {
            return String(
                format: String(localized: "fileExplorer.worktree.detachedFormat", defaultValue: "detached %@"),
                worktree.head.map { String($0.prefix(8)) } ?? ""
            )
        }
        if let branch = worktree.branch, !branch.isEmpty {
            if branch.hasPrefix("refs/heads/") {
                return String(branch.dropFirst("refs/heads/".count))
            }
            return branch
        }
        return String(localized: "fileExplorer.worktree.item", defaultValue: "worktree")
    }

    private func requestWorktreeSwitch(_ worktree: GitWorktreeSnapshot) {
        guard worktree.path != panel.selectedWorktreePath else { return }
        if panel.isDirty {
            pendingWorktreeSwitch = worktree
            showingDirtyWorktreeAlert = true
        } else {
            panel.switchRoot(to: worktree.path)
        }
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
            switch panel.sidebarMode {
            case .files:
                filesView
            case .search:
                searchModeView
            case .gitDiff:
                GitSourceControlView(panel: panel)
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
            sidebarTabButton(
                mode: .gitDiff,
                systemImage: "arrow.triangle.branch",
                label: String(localized: "fileExplorer.tab.git", defaultValue: "Source Control")
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
                .onTapGesture(count: 1) {
                    panel.clearSelection()
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

    private var quickOpenEntries: [QuickOpenEntry] {
        panel.quickOpenResults.enumerated().map { index, entry in
            let capturedPath = entry.path
            return QuickOpenEntry(
                id: entry.path,
                name: entry.name,
                relativePath: entry.relativePath,
                isSelected: index == panel.quickOpenSelectionIndex,
                onOpen: { [weak panel] in
                    panel?.openQuickOpenFile(capturedPath)
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
                let isSelected = panel.selectedPath == node.path
                let isActiveFolder = node.isDirectory
                    && panel.activeFolder == node.path
                    && panel.selectedPath != node.path
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
            if panel.sidebarMode == .gitDiff, let selection = panel.selectedGitCommit {
                GitCommitDetailContentView(selection: selection)
            } else if panel.sidebarMode == .gitDiff, let selection = panel.selectedGitChange {
                GitDiffContentView(selection: selection)
            } else if let path = panel.selectedFile {
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
                } else if panel.fileLanguage == .markdown && markdownPreviewEnabled {
                    MarkdownInlinePreviewView(
                        content: panel.fileContent,
                        filePath: path,
                        showFilePathHeader: false
                    )
                    .id(path)
                } else {
                    FileCodeEditorView(
                        content: $panel.fileContent,
                        isEditable: true,
                        language: panel.fileLanguage,
                        isDarkMode: colorScheme == .dark,
                        filePath: path,
                        rootPath: panel.rootPath,
                        performanceMode: panel.isFilePerformanceMode,
                        fileSuggestions: { query, limit in
                            await panel.fileSuggestions(matching: query, limit: limit)
                        },
                        onOpenLocalDefinition: { destinationPath, cursorPosition in
                            if let cursorPosition {
                                CodeEditorStateCache.store(
                                    SourceEditorState(cursorPositions: [cursorPosition]),
                                    for: destinationPath
                                )
                            }
                            panel.openFile(destinationPath)
                        },
                        onCursorPositionChange: { status in
                            panel.editorCursorStatus = status
                        },
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
            if panel.fileLanguage == .markdown {
                markdownModeToggle
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// Segmented toggle to switch between rendered Preview and raw Markdown source
    /// for `.md` files. Choice is persisted via `@AppStorage`.
    private var markdownModeToggle: some View {
        Picker(
            String(localized: "fileExplorer.markdownMode.label", defaultValue: "Markdown view"),
            selection: $markdownPreviewEnabled
        ) {
            Text(String(localized: "fileExplorer.markdownMode.preview", defaultValue: "Preview"))
                .tag(true)
            Text(String(localized: "fileExplorer.markdownMode.markdown", defaultValue: "Markdown"))
                .tag(false)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
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
                if let cursorStatus = panel.editorCursorStatus {
                    Text(cursorStatusText(cursorStatus))
                }
                if panel.isDirty {
                    Circle()
                        .fill(.orange)
                        .frame(width: 8, height: 8)
                    Text(String(localized: "fileExplorer.modified", defaultValue: "Modified"))
                }
                if panel.isFilePerformanceMode {
                    Text(String(localized: "fileExplorer.editor.performanceMode", defaultValue: "Performance mode"))
                }
                editorFooterToggles
            }
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var editorFooterToggles: some View {
        HStack(spacing: 4) {
            editorToggleButton(
                systemImage: "map",
                isOn: editorShowMinimap && !panel.isFilePerformanceMode,
                help: String(localized: "fileExplorer.editor.toggleMinimap", defaultValue: "Toggle minimap")
            ) {
                editorShowMinimap.toggle()
            }
            editorToggleButton(
                systemImage: "sidebar.leading",
                isOn: editorShowFoldingRibbon && !panel.isFilePerformanceMode,
                help: String(localized: "fileExplorer.editor.toggleFolding", defaultValue: "Toggle folding controls")
            ) {
                editorShowFoldingRibbon.toggle()
            }
            editorToggleButton(
                systemImage: "ruler",
                isOn: editorShowReformattingGuide && !panel.isFilePerformanceMode,
                help: String(localized: "fileExplorer.editor.toggleGuide", defaultValue: "Toggle reformatting guide")
            ) {
                editorShowReformattingGuide.toggle()
            }
            editorToggleButton(
                systemImage: "paragraphsign",
                isOn: editorShowInvisibleCharacters && !panel.isFilePerformanceMode,
                help: String(localized: "fileExplorer.editor.toggleInvisibles", defaultValue: "Toggle invisible characters")
            ) {
                editorShowInvisibleCharacters.toggle()
            }
        }
        .disabled(panel.isFilePerformanceMode)
    }

    private func editorToggleButton(
        systemImage: String,
        isOn: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 18, height: 18)
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isOn ? Color.accentColor.opacity(0.16) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: - Helpers

    private var lineCount: Int {
        panel.fileContent.isEmpty ? 0 : panel.fileContent.components(separatedBy: "\n").count
    }

    private func cursorStatusText(_ status: CodeEditorCursorStatus) -> String {
        String(
            format: String(localized: "fileExplorer.editor.cursorPositionFormat", defaultValue: "Ln %d, Col %d"),
            status.line,
            status.column
        )
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

// MARK: - Quick Open

private struct QuickOpenEntry {
    let id: String
    let name: String
    let relativePath: String
    let isSelected: Bool
    let onOpen: () -> Void
}

private struct FileExplorerQuickOpenPalette: View {
    @Binding var query: String
    let results: [QuickOpenEntry]
    let isIndexing: Bool
    let onQueryChange: (String) -> Void
    let onDismiss: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField(
                    String(localized: "fileExplorer.quickOpen.placeholder", defaultValue: "Search files by name or path"),
                    text: $query
                )
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($focused)
                .onChange(of: query) { newValue in
                    onQueryChange(newValue)
                }
                if !query.isEmpty {
                    Button {
                        query = ""
                        onQueryChange("")
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "fileExplorer.quickOpen.clear", defaultValue: "Clear search"))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        quickOpenMessage(
                            String(localized: "fileExplorer.quickOpen.empty", defaultValue: "Type a file name, path, glob, extension, or /regex/")
                        )
                    } else if results.isEmpty {
                        quickOpenMessage(isIndexing
                            ? String(localized: "fileExplorer.quickOpen.indexing", defaultValue: "Indexing files...")
                            : String(localized: "fileExplorer.quickOpen.noMatches", defaultValue: "No matching files")
                        )
                    } else {
                        ForEach(results, id: \.id) { entry in
                            QuickOpenResultRow(entry: entry)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.28), radius: 24, x: 0, y: 12)
        .onAppear {
            DispatchQueue.main.async { focused = true }
        }
        .onExitCommand {
            onDismiss()
        }
    }

    private func quickOpenMessage(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct QuickOpenResultRow: View {
    let entry: QuickOpenEntry

    var body: some View {
        Button(action: entry.onOpen) {
            HStack(spacing: 8) {
                MaterialIconView(
                    iconID: MaterialIconResolver.shared.iconID(forFile: entry.name),
                    fallbackSystemName: fallbackSystemName,
                    size: 17
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(entry.relativePath)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(entry.isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
    }

    private var fallbackSystemName: String {
        let ext = (entry.name as NSString).pathExtension.lowercased()
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

// MARK: - Sidebar resize

private struct FileExplorerSidebarResizeHandle: View {
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void

    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(isHovering ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.10))
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .background(FileExplorerResizeCursorArea())
            .onHover { hovering in
                isHovering = hovering
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onDragChanged(value.translation.width)
                    }
                    .onEnded { _ in
                        onDragEnded()
                    }
            )
            .accessibilityLabel(String(localized: "fileExplorer.sidebarResizeHandle", defaultValue: "Resize file explorer sidebar"))
    }
}

private struct FileExplorerResizeCursorArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        CursorView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class CursorView: NSView {
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
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
        .background(RenameFieldFocusForcer())
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

/// AppKit-level backup focus driver. SwiftUI's `@FocusState` is unreliable inside
/// `LazyVStack` rows on macOS — when a new file is created and the row is mounted in
/// the same runloop tick, `@FocusState = true` sometimes lands before the underlying
/// `NSTextField` is in the responder chain and gets dropped silently. This view walks
/// up to the row's hosting view, finds the editable `NSTextField`, and explicitly
/// `makeFirstResponder`s it with a few retries while the row finishes mounting.
private struct RenameFieldFocusForcer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setAccessibilityHidden(true)
        DispatchQueue.main.async {
            Self.requestFocus(from: view, retries: 6)
        }
        return view
    }

    func updateNSView(_: NSView, context: Context) {}

    private static func requestFocus(from view: NSView, retries: Int) {
        guard let window = view.window else {
            scheduleRetry(view: view, retries: retries)
            return
        }
        guard let textField = findEditableTextField(near: view) else {
            scheduleRetry(view: view, retries: retries)
            return
        }
        if window.firstResponder === textField || window.firstResponder === textField.currentEditor() {
            return
        }
        if !window.makeFirstResponder(textField) {
            scheduleRetry(view: view, retries: retries)
        }
    }

    private static func scheduleRetry(view: NSView, retries: Int) {
        guard retries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            requestFocus(from: view, retries: retries - 1)
        }
    }

    /// Walk up to the row container, then find the unique editable NSTextField inside.
    /// Non-editable Text views in sibling rows render as NSTextField with isEditable=false,
    /// so the editable filter uniquely identifies the inline rename field.
    private static func findEditableTextField(near view: NSView) -> NSTextField? {
        var ancestor: NSView? = view.superview
        while let v = ancestor {
            if let tf = firstEditableTextField(in: v) { return tf }
            ancestor = v.superview
        }
        return nil
    }

    private static func firstEditableTextField(in view: NSView) -> NSTextField? {
        if let tf = view as? NSTextField, tf.isEditable {
            return tf
        }
        for sub in view.subviews {
            if let found = firstEditableTextField(in: sub) { return found }
        }
        return nil
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

    @MainActor
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
            // `monitor` is a stored property on a MainActor-isolated class; copy it into
            // a local first (nonisolated `deinit` runs on whichever thread released the
            // last reference). `NSEvent.removeMonitor` itself is thread-safe.
            let local = monitor
            if let local {
                NSEvent.removeMonitor(local)
            }
        }

        private func install() {
            // AppKit dispatches event monitor closures on the main thread, so calling
            // MainActor-isolated `handle` via `assumeIsolated` is safe. We can't simply
            // mark the closure `@MainActor` because `addLocalMonitorForEvents` takes a
            // nonisolated closure type.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                MainActor.assumeIsolated {
                    self?.handle(event) ?? event
                }
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard isActive else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
            let isQuickOpenShortcut = KeyboardShortcutSettings.shortcut(for: .quickOpenFileExplorer).matches(event: event)

            if panel.isQuickOpenPresented {
                if isQuickOpenShortcut {
                    return nil
                }
                if mods.isEmpty || mods == [.numericPad, .function] || mods == [.function] {
                    switch event.keyCode {
                    case 126: // Up arrow
                        panel.moveQuickOpenSelection(by: -1)
                        return nil
                    case 125: // Down arrow
                        panel.moveQuickOpenSelection(by: 1)
                        return nil
                    case 36, 76: // Return / Enter
                        panel.openSelectedQuickOpenFile()
                        return nil
                    case 53: // Escape
                        panel.dismissQuickOpen()
                        return nil
                    default:
                        break
                    }
                }
                return event
            }

            if isQuickOpenShortcut {
                panel.showQuickOpen()
                return nil
            }

            // Don't intercept while the user is typing in any text field — covers the
            // search field, the inline rename field, and the code editor.
            // CodeEditTextView is an NSView subclass (not NSText/NSTextView), so the
            // standard isa check misses it; without the className walk below, Cmd+Delete
            // inside the source editor falls through to `panel.deleteItem` and trashes
            // the open file.
            if let firstResponder = event.window?.firstResponder {
                if firstResponder is NSText
                    || firstResponder is NSTextField
                    || firstResponder is NSTextView {
                    return event
                }
                var current: NSResponder? = firstResponder
                while let resp = current {
                    let name = String(describing: type(of: resp))
                    if name == "TextView"
                        || name.hasSuffix(".TextView")
                        || name.contains("CodeEdit") {
                        return event
                    }
                    current = resp.nextResponder
                }
            }
            // Only operate while the file tree tab is showing — search mode hands its
            // own keys to the search field and shouldn't react to clipboard shortcuts.
            guard panel.sidebarMode == .files else { return event }

            // The "active" row is the row visually selected (file or folder) — falls back
            // to the open file or the active folder when no row was clicked.
            let activeTarget: String? = panel.selectedPath
                ?? panel.selectedFile
                ?? panel.activeFolder
            // Destructive shortcuts (Cmd+Delete, fn+Backspace) must NOT use the
            // activeFolder fallback — that path is set whenever the user merely
            // navigates the tree, so an empty-selection delete would otherwise
            // trash the project root or the last folder the user clicked.
            // Match Finder / VSCode: only fire on an explicit row selection
            // or the currently open file.
            let deleteTarget: String? = panel.selectedPath ?? panel.selectedFile

            // Modifier-less navigation + activation keys (arrow keys, Enter, F2).
            if mods.isEmpty || mods == [.numericPad, .function] || mods == [.function] {
                switch event.keyCode {
                case 126: // Up arrow
                    panel.moveSelection(by: -1)
                    return nil
                case 125: // Down arrow
                    panel.moveSelection(by: 1)
                    return nil
                case 123: // Left arrow
                    panel.arrowLeft()
                    return nil
                case 124: // Right arrow
                    panel.arrowRight()
                    return nil
                case 36, 76: // Return / Enter — Finder convention: rename selection.
                    if let target = activeTarget {
                        panel.beginRename(path: target)
                    }
                    return nil
                case 49: // Space → activate (open file / toggle folder), matches Finder.
                    panel.activateSelection()
                    return nil
                case 120: // F2 → rename selected
                    if let target = activeTarget {
                        panel.beginRename(path: target)
                    }
                    return nil
                case 117: // Forward Delete (fn+Backspace) → trash
                    if let target = deleteTarget {
                        _ = panel.deleteItem(at: target)
                        return nil
                    }
                    return event
                default:
                    break
                }
            }

            // Command-modified shortcuts.
            if mods == .command {
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
                case "z":
                    if panel.canUndo {
                        _ = panel.undoLastOperation()
                        return nil
                    }
                    return event
                default:
                    break
                }

                // cmd+Delete (Backspace) → move to Trash, matches Finder.
                if chars == "\u{7F}" || chars == "\u{8}" || event.keyCode == 51 {
                    guard let target = deleteTarget else { return event }
                    _ = panel.deleteItem(at: target)
                    return nil
                }
            }

            return event
        }
    }
}
