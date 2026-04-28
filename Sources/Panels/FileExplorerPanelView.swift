import SwiftUI

struct FileExplorerTabView: View {
    @ObservedObject var panel: FileExplorerPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let onRequestPanelFocus: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            HStack(spacing: 0) {
                sidebar
                    .frame(minWidth: 220, maxWidth: 280)
                Divider()
                contentArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footerBar
        }
        .background(backgroundColor)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Text(abbreviateHome(panel.rootPath))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
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
            Button {
                panel.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 11))
                TextField(
                    String(localized: "fileExplorer.filter", defaultValue: "Filter..."),
                    text: $panel.filterQuery
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onChange(of: panel.filterQuery) { _ in
                    panel.refresh()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(flattenedNodes, id: \.node.id) { entry in
                        FileNodeRow(
                            node: entry.node,
                            depth: entry.depth,
                            isExpanded: entry.isExpanded,
                            isSelected: entry.isSelected,
                            onTap: entry.onTap
                        )
                    }
                }
            }
        }
    }

    private var flattenedNodes: [FlatNodeEntry] {
        var result: [FlatNodeEntry] = []
        func walk(_ nodes: [FileNode], depth: Int) {
            for node in nodes {
                let isExpanded = panel.expandedDirs.contains(node.path)
                let isSelected = panel.selectedFile == node.path
                let capturedPath = node.path
                let capturedIsDir = node.isDirectory
                result.append(FlatNodeEntry(
                    node: node,
                    depth: depth,
                    isExpanded: isExpanded,
                    isSelected: isSelected,
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
                    CodeEditorView(
                        content: $panel.fileContent,
                        isEditable: panel.isEditing,
                        language: panel.fileLanguage,
                        isDarkMode: colorScheme == .dark,
                        onSave: { panel.saveFile() }
                    )
                    .onChange(of: panel.fileContent) { _ in
                        if panel.isEditing { panel.markDirty() }
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
        HStack {
            Text(path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button(panel.isEditing
                ? String(localized: "fileExplorer.viewing", defaultValue: "View")
                : String(localized: "fileExplorer.editing", defaultValue: "Edit")
            ) {
                panel.toggleEditing()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            if panel.isEditing, panel.isDirty {
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
    let onTap: () -> Void
}

private struct FileNodeRow: View {
    let node: FileNode
    let depth: Int
    let isExpanded: Bool
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                if node.isDirectory {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 12)
                } else {
                    Spacer().frame(width: 12)
                }
                Image(systemName: iconForNode)
                    .font(.system(size: 12))
                    .foregroundStyle(node.isDirectory ? .blue : .secondary)
                    .frame(width: 16)
                Text(node.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
            }
            .padding(.leading, CGFloat(depth) * 16 + 4)
            .padding(.vertical, 3)
            .padding(.trailing, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
    }

    private var iconForNode: String {
        if node.isDirectory {
            return isExpanded ? "folder.fill" : "folder"
        }
        switch node.fileExtension?.lowercased() {
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
