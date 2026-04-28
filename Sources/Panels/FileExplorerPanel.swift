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
    @Published var isEditing: Bool = false
    @Published private(set) var isDirtyFlag: Bool = false
    @Published var showHiddenFiles: Bool = false
    @Published var filterQuery: String = ""
    @Published var fileLanguage: CodeLanguage = .unknown
    @Published var isFileBinary: Bool = false
    @Published var isFileTooLarge: Bool = false

    var displayIcon: String? { "folder" }
    var isDirty: Bool { isDirtyFlag }

    private(set) var workspaceId: UUID

    private static let maxFileSize = 1_048_576
    private static let binaryCheckSize = 8192
    private static let cacheTTL: TimeInterval = 5

    private var dirCache: [String: (nodes: [FileNode], date: Date)] = [:]
    private nonisolated(unsafe) var fileWatchSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var isClosed: Bool = false
    private let watchQueue = DispatchQueue(label: "com.zmux.file-explorer-watch", qos: .utility)

    init(workspaceId: UUID, rootPath: String) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.rootPath = rootPath
        self.displayTitle = (rootPath as NSString).lastPathComponent
        loadRootDirectory()
    }

    // MARK: - Panel protocol

    func close() {
        isClosed = true
        stopFileWatcher()
        dirCache.removeAll()
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
    }

    func collapseDirectory(_ path: String) {
        expandedDirs.remove(path)
        dirCache.removeValue(forKey: path)
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
            if !filterQuery.isEmpty,
               !name.localizedCaseInsensitiveContains(filterQuery) { return nil }
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

    // MARK: - File operations

    func openFile(_ path: String) {
        isFileBinary = false
        isFileTooLarge = false

        let url = URL(fileURLWithPath: path)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int else { return }

        if size > Self.maxFileSize {
            isFileTooLarge = true
            selectedFile = path
            fileContent = ""
            return
        }

        guard let data = try? Data(contentsOf: url) else { return }

        let checkSlice = data.prefix(Self.binaryCheckSize)
        if checkSlice.contains(0) {
            isFileBinary = true
            selectedFile = path
            fileContent = ""
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

        fileContent = decoded
        selectedFile = path
        isEditing = false
        isDirtyFlag = false
        fileLanguage = CodeLanguage.detect(from: url.pathExtension)

        stopFileWatcher()
        startFileWatcher(for: path)
    }

    func saveFile() {
        guard let path = selectedFile else { return }
        let url = URL(fileURLWithPath: path)
        try? fileContent.data(using: .utf8)?.write(to: url, options: .atomic)
        isDirtyFlag = false
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
        if let path = selectedFile {
            openFile(path)
        }
    }

    func markDirty() {
        isDirtyFlag = true
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

    deinit {
        fileWatchSource?.cancel()
    }
}
