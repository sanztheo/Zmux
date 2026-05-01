import SwiftUI
import AppKit

// MARK: - Snapshot types passed to row subtrees (no ObservableObject below LazyVStack)

private struct GitRepoSnapshot: Identifiable, Equatable {
    let id: UUID
    let repoRoot: String
    let displayName: String
    let isSubmodule: Bool
    let head: String?
    let upstream: String?
    let isDirty: Bool
    let ahead: Int
    let behind: Int
    let isSyncing: Bool
    let totalCount: Int
    let commitMessage: String
    let isFocused: Bool
    let selectedKey: String?
    let lastError: String?

    let staged: [GitChange]
    let unstaged: [GitChange]
    let untracked: [GitChange]
    let conflicted: [GitChange]
    let availableBranches: [String]
    let commits: [GitCommit]
}

private struct GitRepoActions {
    let onCommitMessageChange: (String) -> Void
    let onCommit: () -> Void
    let onPush: () -> Void
    let onPull: () -> Void
    let onSync: () -> Void
    let onRefresh: () -> Void
    let onStageAll: () -> Void
    let onUnstageAll: () -> Void
    let onCheckout: (String) -> Void
    let onStage: (GitChange) -> Void
    let onUnstage: (GitChange) -> Void
    let onDiscard: (GitChange) -> Void
    let onSelectChange: (GitChange) -> Void
    let onOpenFile: (GitChange) -> Void
    let onFocusInput: () -> Void
    let onClearError: () -> Void
}

private enum CommitButtonMode {
    case commit(Int)
    case push(Int)
    case pull(Int)
    case sync(ahead: Int, behind: Int)
    case disabled
}

// MARK: - Top-level view

struct GitSourceControlView: View {
    @ObservedObject var panel: FileExplorerPanel
    @StateObject private var workspace: GitWorkspace

    init(panel: FileExplorerPanel) {
        self.panel = panel
        _workspace = StateObject(wrappedValue: GitWorkspace(workspaceRoot: panel.rootPath))
    }

    var body: some View {
        VStack(spacing: 0) {
            sectionHeader
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(workspace.visibleRepositories) { repo in
                        GitRepoSection(
                            repo: repo,
                            workspace: workspace,
                            selectedKey: panel.selectedGitChange?.diffKey,
                            onSelect: { change in
                                panel.selectedGitChange = GitDiffSelection(
                                    absolutePath: change.absolutePath,
                                    repoRoot: repo.root,
                                    path: change.path,
                                    isStaged: change.isStaged,
                                    status: change.status,
                                    originalPath: change.originalPath
                                )
                                workspace.focusedRepoID = repo.id
                            }
                        )
                    }
                    if workspace.visibleRepositories.isEmpty {
                        emptyState
                    }
                }
            }
        }
        .onAppear {
            Task { await workspace.discover() }
        }
    }

    private var sectionHeader: some View {
        HStack(spacing: 6) {
            Text(String(localized: "git.section.changes", defaultValue: "CHANGES").uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button {
                Task { await workspace.refreshAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .help(String(localized: "git.refresh", defaultValue: "Refresh"))
            viewSortMenu
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var viewSortMenu: some View {
        Menu {
            Section(String(localized: "git.menu.repositories", defaultValue: "Repositories")) {
                ForEach(workspace.repositories) { repo in
                    Button {
                        let nowVisible = workspace.hiddenRepoIDs.contains(repo.id)
                        workspace.setRepoVisible(repo.id, visible: nowVisible)
                    } label: {
                        if !workspace.hiddenRepoIDs.contains(repo.id) {
                            Label(repo.displayName, systemImage: "checkmark")
                        } else {
                            Text(repo.displayName)
                        }
                    }
                }
            }
            Divider()
            Picker(String(localized: "git.menu.viewMode", defaultValue: "View"), selection: $workspace.viewMode) {
                Text(String(localized: "git.menu.viewAsList", defaultValue: "View as List")).tag(GitViewMode.list)
                Text(String(localized: "git.menu.viewAsTree", defaultValue: "View as Tree")).tag(GitViewMode.tree)
            }
            Divider()
            Picker(String(localized: "git.menu.sort", defaultValue: "Sort"), selection: $workspace.sortKey) {
                Text(String(localized: "git.menu.sortName", defaultValue: "Sort Changes by Name")).tag(GitSortKey.name)
                Text(String(localized: "git.menu.sortPath", defaultValue: "Sort Changes by Path")).tag(GitSortKey.path)
                Text(String(localized: "git.menu.sortStatus", defaultValue: "Sort Changes by Status")).tag(GitSortKey.status)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 18)
        .help(String(localized: "git.menu.viewSort", defaultValue: "View & Sort"))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(String(localized: "git.empty.noRepos", defaultValue: "No git repositories found"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - Per-repo section

private struct GitRepoSection: View {
    @ObservedObject var repo: GitRepository
    @ObservedObject var workspace: GitWorkspace
    let selectedKey: String?
    let onSelect: (GitChange) -> Void

    @State private var isExpanded: Bool = true
    @State private var isGraphExpanded: Bool = false

    var body: some View {
        let snapshot = makeSnapshot()
        let actions = makeActions()

        VStack(alignment: .leading, spacing: 0) {
            header(snapshot: snapshot, actions: actions)
            if isExpanded {
                commitArea(snapshot: snapshot, actions: actions)
                if let err = snapshot.lastError {
                    errorBanner(text: err, actions: actions)
                }
                changesList(snapshot: snapshot, actions: actions)
                graphSection(snapshot: snapshot)
            }
        }
        .padding(.vertical, 4)
    }

    private func errorBanner(text: String, actions: GitRepoActions) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.red)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                actions.onClearError()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.red.opacity(0.12))
    }

    private func header(snapshot: GitRepoSnapshot, actions: GitRepoActions) -> some View {
        HStack(spacing: 6) {
            Button {
                isExpanded.toggle()
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 10)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Text(snapshot.displayName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            Text(snapshot.isSubmodule ? "Submodule" : "Git")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            Spacer()

            branchPicker(snapshot: snapshot, actions: actions)

            Button {
                actions.onRefresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help(String(localized: "git.refresh", defaultValue: "Refresh"))

            if !snapshot.staged.isEmpty {
                Button {
                    actions.onUnstageAll()
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help(String(localized: "git.unstageAll", defaultValue: "Unstage all"))
            }

            if !snapshot.unstaged.isEmpty || !snapshot.untracked.isEmpty {
                Button {
                    actions.onStageAll()
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help(String(localized: "git.stageAll", defaultValue: "Stage all"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func branchPicker(snapshot: GitRepoSnapshot, actions: GitRepoActions) -> some View {
        Menu {
            ForEach(snapshot.availableBranches, id: \.self) { branch in
                Button {
                    actions.onCheckout(branch)
                } label: {
                    if branch == snapshot.head {
                        Label(branch, systemImage: "checkmark")
                    } else {
                        Text(branch)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9))
                Text(snapshot.head ?? "—")
                    .font(.system(size: 11))
                    .lineLimit(1)
                if snapshot.isDirty {
                    Text("*")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.orange)
                }
                if snapshot.ahead > 0 || snapshot.behind > 0 {
                    Text("↑\(snapshot.ahead) ↓\(snapshot.behind)")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func commitArea(snapshot: GitRepoSnapshot, actions: GitRepoActions) -> some View {
        let mode = commitButtonMode(snapshot)
        let messageEmpty = snapshot.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let canActivate = canActivateButton(mode: mode, messageEmpty: messageEmpty, snapshot: snapshot)

        return VStack(alignment: .leading, spacing: 4) {
            TextField(
                commitPlaceholder(branch: snapshot.head),
                text: Binding(
                    get: { snapshot.commitMessage },
                    set: { actions.onCommitMessageChange($0) }
                ),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .lineLimit(1...4)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(snapshot.isFocused ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
            )
            .onTapGesture {
                actions.onFocusInput()
            }
            .onSubmit {
                if canActivate { triggerCommitAction(mode: mode, actions: actions) }
            }

            Button {
                triggerCommitAction(mode: mode, actions: actions)
            } label: {
                HStack(spacing: 4) {
                    if snapshot.isSyncing {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.5)
                            .frame(width: 10, height: 10)
                    } else {
                        Image(systemName: commitButtonIcon(mode: mode))
                            .font(.system(size: 10, weight: .bold))
                    }
                    Text(commitButtonTitle(mode: mode))
                        .font(.system(size: 12, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(canActivate ? Color.accentColor.opacity(0.55) : Color.gray.opacity(0.2))
                )
                .foregroundStyle(canActivate ? Color.white : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canActivate)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func triggerCommitAction(mode: CommitButtonMode, actions: GitRepoActions) {
        switch mode {
        case .commit: actions.onCommit()
        case .push: actions.onPush()
        case .pull: actions.onPull()
        case .sync: actions.onSync()
        case .disabled: break
        }
    }

    @ViewBuilder
    private func graphSection(snapshot: GitRepoSnapshot) -> some View {
        if !snapshot.commits.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    isGraphExpanded.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isGraphExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 10)
                        Text(String(localized: "git.graph.title", defaultValue: "Graph").uppercased())
                            .font(.system(size: 10, weight: .semibold))
                        Spacer()
                        Text("\(snapshot.commits.count)")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isGraphExpanded {
                    ForEach(snapshot.commits) { commit in
                        GitCommitRow(commit: commit)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func changesList(snapshot: GitRepoSnapshot, actions: GitRepoActions) -> some View {
        if snapshot.totalCount == 0 {
            Text(String(localized: "git.empty.cleanTree", defaultValue: "No changes"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
        } else {
            if !snapshot.conflicted.isEmpty {
                changeGroup(
                    title: String(localized: "git.group.conflicts", defaultValue: "Merge Changes"),
                    count: snapshot.conflicted.count,
                    changes: snapshot.conflicted,
                    isStaged: false,
                    actions: actions
                )
            }
            if !snapshot.staged.isEmpty {
                changeGroup(
                    title: String(localized: "git.group.staged", defaultValue: "Staged Changes"),
                    count: snapshot.staged.count,
                    changes: snapshot.staged,
                    isStaged: true,
                    actions: actions
                )
            }
            if !snapshot.unstaged.isEmpty {
                changeGroup(
                    title: String(localized: "git.group.changes", defaultValue: "Changes"),
                    count: snapshot.unstaged.count,
                    changes: snapshot.unstaged,
                    isStaged: false,
                    actions: actions
                )
            }
            if !snapshot.untracked.isEmpty {
                changeGroup(
                    title: String(localized: "git.group.untracked", defaultValue: "Untracked"),
                    count: snapshot.untracked.count,
                    changes: snapshot.untracked,
                    isStaged: false,
                    actions: actions
                )
            }
        }
    }

    private func changeGroup(
        title: String,
        count: Int,
        changes: [GitChange],
        isStaged: Bool,
        actions: GitRepoActions
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 9))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 2)

            ForEach(changes) { change in
                GitChangeRow(
                    change: change,
                    isStaged: isStaged,
                    isSelected: rowDiffKey(for: change, isStaged: isStaged) == selectedKey,
                    actions: actions
                )
            }
        }
    }

    private func rowDiffKey(for change: GitChange, isStaged: Bool) -> String {
        "\(change.absolutePath)|\(isStaged ? "staged" : "wt")|\(change.status.rawValue)"
    }

    // MARK: - Snapshot building

    private func makeSnapshot() -> GitRepoSnapshot {
        GitRepoSnapshot(
            id: repo.id,
            repoRoot: repo.root,
            displayName: repo.displayName,
            isSubmodule: repo.isSubmodule,
            head: repo.headBranch,
            upstream: repo.upstream,
            isDirty: repo.isDirty,
            ahead: repo.ahead,
            behind: repo.behind,
            isSyncing: repo.isSyncing,
            totalCount: repo.totalChangeCount,
            commitMessage: repo.commitMessage,
            isFocused: workspace.focusedRepoID == repo.id,
            selectedKey: selectedKey,
            lastError: repo.lastError,
            staged: repo.indexChanges,
            unstaged: repo.workingTreeChanges,
            untracked: repo.untrackedChanges,
            conflicted: repo.mergeChanges,
            availableBranches: repo.availableBranches,
            commits: repo.commits
        )
    }

    private func makeActions() -> GitRepoActions {
        let repo = self.repo
        let workspace = self.workspace
        let select = self.onSelect
        return GitRepoActions(
            onCommitMessageChange: { message in
                repo.commitMessage = message
            },
            onCommit: {
                Task { await repo.commit() }
            },
            onPush: {
                Task { await repo.push() }
            },
            onPull: {
                Task { await repo.pull() }
            },
            onSync: {
                Task { await repo.sync() }
            },
            onRefresh: {
                Task { await repo.refresh() }
            },
            onStageAll: {
                Task { await repo.stageAll() }
            },
            onUnstageAll: {
                Task { await repo.unstageAll() }
            },
            onCheckout: { branch in
                Task { await repo.checkout(branch: branch) }
            },
            onStage: { change in
                Task { await repo.stage(change) }
            },
            onUnstage: { change in
                Task { await repo.unstage(change) }
            },
            onDiscard: { change in
                Task { await repo.discard(change) }
            },
            onSelectChange: { change in
                select(change)
            },
            onOpenFile: { change in
                NSWorkspace.shared.open(URL(fileURLWithPath: change.absolutePath))
            },
            onFocusInput: {
                workspace.focusedRepoID = repo.id
            },
            onClearError: {
                repo.clearError()
            }
        )
    }

    private func commitButtonMode(_ snapshot: GitRepoSnapshot) -> CommitButtonMode {
        if !snapshot.staged.isEmpty { return .commit(snapshot.staged.count) }
        if snapshot.ahead > 0 && snapshot.behind > 0 { return .sync(ahead: snapshot.ahead, behind: snapshot.behind) }
        if snapshot.ahead > 0 { return .push(snapshot.ahead) }
        if snapshot.behind > 0 { return .pull(snapshot.behind) }
        return .disabled
    }

    private func canActivateButton(mode: CommitButtonMode, messageEmpty: Bool, snapshot: GitRepoSnapshot) -> Bool {
        if snapshot.isSyncing { return false }
        switch mode {
        case .commit: return !messageEmpty
        case .push, .pull, .sync: return true
        case .disabled: return false
        }
    }

    private func commitPlaceholder(branch: String?) -> String {
        let template = String(
            localized: "git.commit.placeholder",
            defaultValue: "Message (⌘↵ to commit on \"%@\")"
        )
        return String(format: template, branch ?? "—")
    }

    private func commitButtonIcon(mode: CommitButtonMode) -> String {
        switch mode {
        case .commit: return "checkmark"
        case .push: return "arrow.up"
        case .pull: return "arrow.down"
        case .sync: return "arrow.triangle.2.circlepath"
        case .disabled: return "checkmark"
        }
    }

    private func commitButtonTitle(mode: CommitButtonMode) -> String {
        switch mode {
        case .commit(let n):
            let template = String(localized: "git.commit.buttonCount", defaultValue: "Commit %d")
            return String(format: template, n)
        case .push(let n):
            let template = String(localized: "git.push.buttonCount", defaultValue: "Push %d")
            return String(format: template, n)
        case .pull(let n):
            let template = String(localized: "git.pull.buttonCount", defaultValue: "Pull %d")
            return String(format: template, n)
        case .sync(let ahead, let behind):
            let template = String(localized: "git.sync.button", defaultValue: "Sync Changes (↑%d ↓%d)")
            return String(format: template, ahead, behind)
        case .disabled:
            return String(localized: "git.commit.button", defaultValue: "Commit")
        }
    }
}

// MARK: - Change row

private struct GitChangeRow: View {
    let change: GitChange
    let isStaged: Bool
    let isSelected: Bool
    let actions: GitRepoActions

    @State private var isHovering: Bool = false

    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.25) }
        if isHovering { return Color.primary.opacity(0.05) }
        return Color.clear
    }

    var body: some View {
        HStack(spacing: 6) {
            statusBadge
                .frame(width: 14)
            Text(change.displayName)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            if !change.displayDirectory.isEmpty {
                Text(change.displayDirectory)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            if isHovering {
                rowActions
            }
            statusLetter
                .frame(width: 14, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .background(rowBackground)
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) { actions.onOpenFile(change) }
        .onTapGesture { actions.onSelectChange(change) }
        .contextMenu {
            Button(String(localized: "git.menu.openFile", defaultValue: "Open File")) {
                actions.onOpenFile(change)
            }
            Divider()
            if isStaged {
                Button(String(localized: "git.menu.unstage", defaultValue: "Unstage Changes")) {
                    actions.onUnstage(change)
                }
            } else {
                Button(String(localized: "git.menu.stage", defaultValue: "Stage Changes")) {
                    actions.onStage(change)
                }
            }
            if !isStaged {
                Button(String(localized: "git.menu.discard", defaultValue: "Discard Changes"), role: .destructive) {
                    actions.onDiscard(change)
                }
            }
        }
    }

    @ViewBuilder
    private var rowActions: some View {
        if isStaged {
            Button {
                actions.onUnstage(change)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .help(String(localized: "git.menu.unstage", defaultValue: "Unstage Changes"))
        } else {
            if change.status != .untracked {
                Button {
                    actions.onDiscard(change)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .help(String(localized: "git.menu.discard", defaultValue: "Discard Changes"))
            }
            Button {
                actions.onStage(change)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .help(String(localized: "git.menu.stage", defaultValue: "Stage Changes"))
        }
    }

    private var statusBadge: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 6, height: 6)
    }

    private var statusLetter: some View {
        Text(statusInitial)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(statusColor)
    }

    private var statusInitial: String {
        switch change.status {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .untracked: return "U"
        case .conflicted: return "!"
        }
    }

    private var statusColor: Color {
        switch change.status {
        case .modified: return .orange
        case .added: return .green
        case .deleted: return .red
        case .renamed: return .purple
        case .copied: return .teal
        case .untracked: return .gray
        case .conflicted: return .red
        }
    }
}

// MARK: - Commit row (graph)

private struct GitCommitRow: View {
    let commit: GitCommit

    var body: some View {
        HStack(spacing: 8) {
            Text(commit.shortSha)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 56, alignment: .leading)
            Text(commit.subject)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(commit.dateRelative)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 2)
        .help("\(commit.shortSha) — \(commit.author) — \(commit.dateRelative)\n\(commit.subject)")
    }
}

// MARK: - Diff content view (right pane)

struct GitDiffContentView: View {
    let selection: GitDiffSelection

    @State private var diffText: String = ""
    @State private var isLoading: Bool = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if isLoading {
                placeholder(icon: "ellipsis.circle", title: String(localized: "git.diff.loading", defaultValue: "Loading diff…"))
            } else if let err = error {
                placeholder(icon: "exclamationmark.triangle", title: err)
            } else if diffText.isEmpty {
                placeholder(icon: "doc", title: String(localized: "git.diff.empty", defaultValue: "No diff to display"))
            } else {
                ScrollView([.vertical, .horizontal]) {
                    DiffLinesView(text: diffText)
                        .padding(.vertical, 4)
                }
            }
        }
        .id(selection.diffKey)
        .task(id: selection.diffKey) {
            await loadDiff()
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(selection.path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(selection.isStaged
                ? String(localized: "git.diff.staged", defaultValue: "Staged")
                : String(localized: "git.diff.workingTree", defaultValue: "Working tree"))
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func placeholder(icon: String, title: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    private func loadDiff() async {
        isLoading = true
        error = nil
        let sel = selection
        let outcome: (text: String, error: String?) = await Task.detached(priority: .userInitiated) { () -> (String, String?) in
            switch sel.status {
            case .untracked:
                guard let content = try? String(contentsOfFile: sel.absolutePath, encoding: .utf8) else {
                    return ("", String(localized: "git.diff.cantRead", defaultValue: "Cannot read file"))
                }
                let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
                let prefixed = lines.map { "+" + $0 }.joined(separator: "\n")
                let header = "+++ \(sel.path)\n@@ untracked file @@\n"
                return (header + prefixed, nil)
            default:
                let args: [String]
                if sel.isStaged {
                    args = ["diff", "--cached", "--no-color", "--", sel.path]
                } else {
                    args = ["diff", "--no-color", "--", sel.path]
                }
                let out = GitRepository.runGit(in: sel.repoRoot, args: args) ?? ""
                return (out, nil)
            }
        }.value

        diffText = outcome.text
        error = outcome.error
        isLoading = false
    }
}

private struct DiffLinesView: View {
    let text: String

    var body: some View {
        let lines = text.components(separatedBy: "\n")
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                DiffLineRow(line: line)
            }
        }
    }
}

private struct DiffLineRow: View {
    let line: String

    var body: some View {
        HStack(spacing: 0) {
            Text(line.isEmpty ? " " : line)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(textColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
        }
        .background(rowBackground)
    }

    private var textColor: Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") {
            return .secondary
        }
        if line.hasPrefix("@@") { return .blue }
        if line.hasPrefix("+") { return .green }
        if line.hasPrefix("-") { return .red }
        return .primary
    }

    private var rowBackground: Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") {
            return Color.clear
        }
        if line.hasPrefix("@@") { return Color.blue.opacity(0.08) }
        if line.hasPrefix("+") { return Color.green.opacity(0.12) }
        if line.hasPrefix("-") { return Color.red.opacity(0.12) }
        return Color.clear
    }
}
