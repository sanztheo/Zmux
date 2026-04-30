import Foundation
import Combine
import AppKit

struct FileNode: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    let isDirectory: Bool
    let fileExtension: String?
    var children: [FileNode]?

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: FileNode, rhs: FileNode) -> Bool { lhs.id == rhs.id }
}

/// Top-level mode for the file explorer sidebar — VSCode activity-bar style toggle between
/// the file tree and the search panel.
enum FileExplorerSidebarMode: String, Hashable {
    case files
    case search
}

@MainActor
final class FileExplorerPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .fileExplorer

    @Published var rootPath: String
    @Published private(set) var displayTitle: String = ""
    @Published private(set) var focusFlashToken: Int = 0
    @Published var fileTree: [FileNode] = []
    @Published var expandedDirs: Set<String> = []
    @Published var selectedFile: String?
    @Published var fileContent: String = ""
    @Published var isEditing: Bool = true
    @Published private(set) var isDirtyFlag: Bool = false
    @Published var showHiddenFiles: Bool = true
    @Published var filterQuery: String = ""
    @Published private(set) var searchResults: [IndexedFile] = []
    @Published private(set) var isIndexing: Bool = false
    @Published var fileLanguage: FileLanguage = .unknown
    @Published var isFileBinary: Bool = false
    @Published var isFileTooLarge: Bool = false

    /// Path currently being renamed inline (nil when no rename in progress).
    @Published var renamingPath: String?
    /// Working draft for the inline rename TextField.
    @Published var renameDraft: String = ""
    /// Paths previously copied/cut to clipboard. Cut paths are visually dimmed.
    @Published private(set) var cutPaths: Set<String> = []

    /// Workspace hook called when the user picks "Open in Integrated Terminal".
    /// Receives an absolute directory path. Set by Workspace.swift on panel creation.
    var onOpenInIntegratedTerminal: ((String) -> Void)?

    /// Activity-bar tab: file tree vs full-text search.
    @Published var sidebarMode: FileExplorerSidebarMode = .files

    /// Path currently targeted by an open context menu — drives the row highlight while
    /// a right-click menu is open (matches Finder/VSCode behavior).
    @Published var contextMenuPath: String?

    /// Folder currently "active" in the tree — last clicked directory, or the parent of the
    /// last-opened file. Drives the subtle row highlight (VSCode "focused" state) and pilots
    /// the destination for toolbar New File / New Folder buttons. `nil` ⇒ root.
    @Published var activeFolder: String?

    var displayIcon: String? { "folder" }
    var isDirty: Bool { isDirtyFlag }

    private(set) var workspaceId: UUID

    private static let maxFileSize = 1_048_576
    private static let binaryCheckSize = 8192
    private static let cacheTTL: TimeInterval = 5

    // Files above these thresholds skip syntax highlighting. CodeEditorView's
    // tokeniser is regex-based and re-runs on every edit, so disabling it on
    // large files keeps typing snappy. Tuned conservatively: well below the
    // 1MB hard cap, but high enough to keep colours on most real source files.
    private static let highlightMaxBytes = 100_000
    private static let highlightMaxLines = 3000

    private static let searchDebounceNanos: UInt64 = 60_000_000
    private static let searchLimit = 200

    private var dirCache: [String: (nodes: [FileNode], date: Date)] = [:]
    private nonisolated(unsafe) var fileWatchSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var isClosed: Bool = false
    private var cleanFileContent: String = ""
    private let watchQueue = DispatchQueue(label: "com.zmux.file-explorer-watch", qos: .utility)

    private var index: FileIndex?
    private var indexTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    init(workspaceId: UUID, rootPath: String) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.rootPath = rootPath
        self.displayTitle = (rootPath as NSString).lastPathComponent
        loadRootDirectory()
        rebuildIndex()
    }

    // MARK: - Panel protocol

    func close() {
        isClosed = true
        stopFileWatcher()
        dirCache.removeAll()
        indexTask?.cancel()
        searchTask?.cancel()
    }

    func focus() {}
    func unfocus() {}

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        focusFlashToken += 1
    }

    func captureFocusIntent(in window: NSWindow?) -> PanelFocusIntent { .panel }
    func preferredFocusIntentForActivation() -> PanelFocusIntent { .panel }
    func prepareFocusIntentForActivation(_ intent: PanelFocusIntent) {}

    @discardableResult
    func restoreFocusIntent(_ intent: PanelFocusIntent) -> Bool { false }

    func ownedFocusIntent(for responder: NSResponder, in window: NSWindow) -> PanelFocusIntent? { nil }

    @discardableResult
    func yieldFocusIntent(_ intent: PanelFocusIntent, in window: NSWindow) -> Bool { false }

    // MARK: - Directory loading

    func loadRootDirectory() {
        fileTree = loadDirectory(rootPath)
    }

    func expandDirectory(_ path: String) {
        expandedDirs.insert(path)
        let children = loadDirectory(path)
        updateChildren(at: path, with: children, in: &fileTree)
        activeFolder = path
    }

    func collapseDirectory(_ path: String) {
        expandedDirs.remove(path)
        dirCache.removeValue(forKey: path)
        activeFolder = path
    }

    private func loadDirectory(_ path: String) -> [FileNode] {
        if let cached = dirCache[path],
           Date().timeIntervalSince(cached.date) < Self.cacheTTL {
            return cached.nodes
        }

        let url = URL(fileURLWithPath: path)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: showHiddenFiles ? [] : [.skipsHiddenFiles]
        ) else { return [] }

        var nodes = contents.compactMap { itemURL -> FileNode? in
            let name = itemURL.lastPathComponent
            let isDir = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return FileNode(
                id: itemURL.path,
                name: name,
                path: itemURL.path,
                isDirectory: isDir,
                fileExtension: isDir ? nil : itemURL.pathExtension,
                children: isDir ? nil : nil
            )
        }

        nodes.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        dirCache[path] = (nodes: nodes, date: Date())
        return nodes
    }

    private func updateChildren(at path: String, with children: [FileNode], in nodes: inout [FileNode]) {
        for i in nodes.indices {
            if nodes[i].path == path {
                nodes[i].children = children
                return
            }
            if var sub = nodes[i].children {
                updateChildren(at: path, with: children, in: &sub)
                nodes[i].children = sub
            }
        }
    }

    // MARK: - Index + search

    func rebuildIndex() {
        indexTask?.cancel()
        searchTask?.cancel()

        let path = rootPath
        let hidden = showHiddenFiles
        let newIndex = FileIndex(rootPath: path, includeHidden: hidden)
        index = newIndex
        isIndexing = true

        let pendingQuery = filterQuery

        indexTask = Task { [weak self] in
            await newIndex.rebuild()
            await MainActor.run {
                guard let self else { return }
                guard self.index === newIndex else { return }
                self.isIndexing = false
                if !pendingQuery.isEmpty, self.filterQuery == pendingQuery {
                    self.scheduleSearch(query: pendingQuery)
                }
            }
        }
    }

    func scheduleSearch(query: String) {
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            searchResults = []
            return
        }

        guard let activeIndex = index else { return }
        let limit = Self.searchLimit

        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.searchDebounceNanos)
            if Task.isCancelled { return }

            let hits = await activeIndex.search(query: trimmed, limit: limit)
            if Task.isCancelled { return }

            await MainActor.run {
                guard let self else { return }
                guard self.index === activeIndex else { return }
                guard self.filterQuery == query else { return }
                self.searchResults = hits.map(\.entry)
            }
        }
    }

    // MARK: - File operations

    func openFile(_ path: String) {
        isFileBinary = false
        isFileTooLarge = false

        let url = URL(fileURLWithPath: path)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int else { return }

        if size > Self.maxFileSize {
            stopFileWatcher()
            isFileTooLarge = true
            fileLanguage = FileLanguage.detect(from: url.pathExtension)
            isDirtyFlag = false
            selectedFile = path
            activeFolder = (path as NSString).deletingLastPathComponent
            replaceFileContentFromDisk("")
            return
        }

        guard let data = try? Data(contentsOf: url) else { return }

        let checkSlice = data.prefix(Self.binaryCheckSize)
        if checkSlice.contains(0) {
            stopFileWatcher()
            isFileBinary = true
            fileLanguage = FileLanguage.detect(from: url.pathExtension)
            isDirtyFlag = false
            selectedFile = path
            activeFolder = (path as NSString).deletingLastPathComponent
            replaceFileContentFromDisk("")
            return
        }

        let decoded: String
        if let utf8 = String(data: data, encoding: .utf8) {
            decoded = utf8
        } else if let latin1 = String(data: data, encoding: .isoLatin1) {
            decoded = latin1
        } else {
            return
        }

        stopFileWatcher()
        let detected = FileLanguage.detect(from: url.pathExtension)
        let lineCount = decoded.utf8.lazy.filter { $0 == 0x0A }.count
        let tooBigForHighlight = data.count > Self.highlightMaxBytes
            || lineCount > Self.highlightMaxLines
        fileLanguage = tooBigForHighlight ? .unknown : detected
        isDirtyFlag = false
        selectedFile = path
        activeFolder = (path as NSString).deletingLastPathComponent
        replaceFileContentFromDisk(decoded)
        startFileWatcher(for: path)
    }

    func saveFile() {
        guard let path = selectedFile else { return }
        let url = URL(fileURLWithPath: path)
        try? fileContent.data(using: .utf8)?.write(to: url, options: .atomic)
        cleanFileContent = fileContent
        isDirtyFlag = false
    }

    func deselectFile() {
        stopFileWatcher()
        selectedFile = nil
        fileContent = ""
        cleanFileContent = ""
        isDirtyFlag = false
        isFileBinary = false
        isFileTooLarge = false
    }

    func toggleEditing() {
        isEditing.toggle()
    }

    func refresh() {
        dirCache.removeAll()
        loadRootDirectory()
        for dir in expandedDirs {
            let children = loadDirectory(dir)
            updateChildren(at: dir, with: children, in: &fileTree)
        }
        rebuildIndex()
        if let path = selectedFile {
            openFile(path)
        }
    }

    func markDirty() {
        isDirtyFlag = fileContent != cleanFileContent
    }

    private func replaceFileContentFromDisk(_ content: String) {
        cleanFileContent = content
        guard fileContent != content else { return }
        fileContent = content
    }

    // MARK: - File watcher

    private func startFileWatcher(for path: String) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                guard !self.isClosed, !self.isDirtyFlag, let current = self.selectedFile else { return }
                self.stopFileWatcher()
                self.openFile(current)
            }
        }

        source.setCancelHandler {
            Darwin.close(fd)
        }

        source.resume()
        fileWatchSource = source
    }

    private func stopFileWatcher() {
        if let source = fileWatchSource {
            source.cancel()
            fileWatchSource = nil
        }
        fileDescriptor = -1
    }

    // MARK: - Filesystem mutations (VSCode-style menu actions)

    /// Parent directory used for "new file at root" actions when no item is selected.
    private func parentDirectory(for path: String?) -> String {
        guard let path else { return rootPath }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            return path
        }
        return (path as NSString).deletingLastPathComponent
    }

    /// Create a new file in `parent`, generating a unique name. Returns the created path.
    @discardableResult
    func createNewFile(in parent: String? = nil) -> String? {
        let dir = parent.map { parentDirectory(for: $0) } ?? rootPath
        let path = uniquePath(in: dir, baseName: "untitled", isDirectory: false)
        guard FileManager.default.createFile(atPath: path, contents: nil, attributes: nil) else {
            return nil
        }
        ensureExpanded(dir)
        refresh()
        beginRename(path: path)
        return path
    }

    /// Create a new folder in `parent`, generating a unique name. Returns the created path.
    @discardableResult
    func createNewFolder(in parent: String? = nil) -> String? {
        let dir = parent.map { parentDirectory(for: $0) } ?? rootPath
        let path = uniquePath(in: dir, baseName: "new-folder", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                atPath: path,
                withIntermediateDirectories: false,
                attributes: nil
            )
        } catch {
            return nil
        }
        ensureExpanded(dir)
        refresh()
        beginRename(path: path)
        return path
    }

    /// Move an item to the macOS Trash. Returns true on success.
    @discardableResult
    func deleteItem(at path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        var trashed: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        } catch {
            return false
        }
        if selectedFile == path {
            deselectFile()
        }
        if activeFolder == path || activeFolder?.hasPrefix(path + "/") == true {
            activeFolder = nil
        }
        cutPaths.remove(path)
        refresh()
        return true
    }

    /// Begin inline rename for `path`. The view swaps the row's label for a TextField.
    func beginRename(path: String) {
        renamingPath = path
        renameDraft = (path as NSString).lastPathComponent
    }

    /// Cancel an in-progress inline rename without writing changes.
    func cancelRename() {
        renamingPath = nil
        renameDraft = ""
    }

    /// Commit the current inline rename. Empty / unchanged drafts are treated as cancel.
    @discardableResult
    func commitRename() -> Bool {
        guard let path = renamingPath else { return false }
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            renamingPath = nil
            renameDraft = ""
        }
        guard !trimmed.isEmpty else { return false }
        let oldName = (path as NSString).lastPathComponent
        guard trimmed != oldName else { return false }
        return renameItem(at: path, to: trimmed)
    }

    @discardableResult
    func renameItem(at path: String, to newName: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        let destination = (parent as NSString).appendingPathComponent(newName)
        if FileManager.default.fileExists(atPath: destination) { return false }
        do {
            try FileManager.default.moveItem(atPath: path, toPath: destination)
        } catch {
            return false
        }
        if selectedFile == path { selectedFile = destination }
        if cutPaths.contains(path) {
            cutPaths.remove(path)
            cutPaths.insert(destination)
        }
        refresh()
        return true
    }

    /// Collapse every expanded directory in the tree (VSCode "Collapse Folders in Explorer").
    func collapseAll() {
        expandedDirs.removeAll()
        activeFolder = nil
        // Rebuild the tree so the cached `children` arrays don't keep stale subtrees.
        loadRootDirectory()
    }

    /// Move external file URLs into `destination` (absolute path of a directory or a file —
    /// in the file case, the parent directory is used). Returns the count of successful moves.
    @discardableResult
    func moveItems(_ sourceURLs: [URL], into destination: String) -> Int {
        let dir = parentDirectory(for: destination)
        var moved = 0
        for url in sourceURLs {
            let source = url.path
            // Skip drops onto self / into own subtree.
            if source == dir { continue }
            if dir.hasPrefix(source + "/") { continue }
            let target = uniquePath(
                in: dir,
                baseName: (url.lastPathComponent as NSString).deletingPathExtension,
                fileExtension: url.pathExtension.isEmpty ? nil : url.pathExtension,
                isDirectory: (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            )
            // No-op if drop target equals source's existing parent.
            if (source as NSString).deletingLastPathComponent == dir { continue }
            do {
                try FileManager.default.moveItem(atPath: source, toPath: target)
                moved += 1
                if selectedFile == source { selectedFile = target }
            } catch {
                continue
            }
        }
        if moved > 0 {
            ensureExpanded(dir)
            refresh()
        }
        return moved
    }

    /// Reveal `path` in Finder.
    func revealInFinder(_ path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Open a new integrated terminal pane in this workspace at `path` (or its parent).
    func openInIntegratedTerminal(_ path: String) {
        let dir = parentDirectory(for: path)
        onOpenInIntegratedTerminal?(dir)
    }

    func copyPath(_ path: String) {
        writeStringToPasteboard(path)
    }

    func copyRelativePath(_ path: String) {
        let relative: String
        if path.hasPrefix(rootPath + "/") {
            relative = String(path.dropFirst(rootPath.count + 1))
        } else if path == rootPath {
            relative = (path as NSString).lastPathComponent
        } else {
            relative = path
        }
        writeStringToPasteboard(relative)
    }

    /// VSCode-style copy: writes file URLs to the pasteboard for paste-into-folder.
    func copyToClipboard(_ paths: [String]) {
        cutPaths = []
        writeFileURLsToPasteboard(paths)
    }

    /// VSCode-style cut: writes URLs and remembers the source paths for visual dimming.
    func cutToClipboard(_ paths: [String]) {
        cutPaths = Set(paths)
        writeFileURLsToPasteboard(paths)
    }

    /// Paste pasteboard file URLs into `destination`. Cut paths are moved; copy paths are duplicated.
    @discardableResult
    func pasteClipboard(into destination: String? = nil) -> Bool {
        let pasteboard = NSPasteboard.general
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else {
            return false
        }
        let dir = parentDirectory(for: destination)
        var moved = false
        for url in urls {
            let source = url.path
            let target = uniquePath(
                in: dir,
                baseName: (url.lastPathComponent as NSString).deletingPathExtension,
                fileExtension: url.pathExtension.isEmpty ? nil : url.pathExtension,
                isDirectory: (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            )
            do {
                if cutPaths.contains(source) {
                    try FileManager.default.moveItem(atPath: source, toPath: target)
                } else {
                    try FileManager.default.copyItem(atPath: source, toPath: target)
                }
                moved = true
            } catch {
                continue
            }
        }
        if moved {
            cutPaths = []
            ensureExpanded(dir)
            refresh()
        }
        return moved
    }

    /// True if the general pasteboard currently contains file URLs we can paste.
    func canPaste() -> Bool {
        let pasteboard = NSPasteboard.general
        return pasteboard.canReadObject(forClasses: [NSURL.self], options: nil)
    }

    private func writeStringToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    private func writeFileURLsToPasteboard(_ paths: [String]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let urls = paths.map { URL(fileURLWithPath: $0) as NSURL }
        pasteboard.writeObjects(urls)
    }

    private func ensureExpanded(_ path: String) {
        guard path != rootPath else { return }
        if !expandedDirs.contains(path) {
            expandedDirs.insert(path)
        }
    }

    private func uniquePath(
        in directory: String,
        baseName: String,
        fileExtension: String? = nil,
        isDirectory: Bool
    ) -> String {
        let ext = fileExtension.map { ".\($0)" } ?? ""
        var candidate = (directory as NSString).appendingPathComponent("\(baseName)\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate) {
            candidate = (directory as NSString).appendingPathComponent("\(baseName) \(counter)\(ext)")
            counter += 1
        }
        _ = isDirectory
        return candidate
    }

    deinit {
        fileWatchSource?.cancel()
        indexTask?.cancel()
        searchTask?.cancel()
    }
}
