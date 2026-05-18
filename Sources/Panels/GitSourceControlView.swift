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
    let selectedChangeKey: String?
    let selectedCommitKey: String?
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
    let onSelectCommit: (GitCommit) -> Void
    let onOpenFile: (GitChange) -> Void
    let onFocusInput: () -> Void
    let onClearError: () -> Void
}

private struct GitRepoPresentation: Identifiable {
    let snapshot: GitRepoSnapshot
    let actions: GitRepoActions

    var id: UUID { snapshot.id }
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
                    ForEach(repoPresentations) { presentation in
                        GitRepoSection(
                            snapshot: presentation.snapshot,
                            actions: presentation.actions
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

    private var repoPresentations: [GitRepoPresentation] {
        workspace.visibleRepositories.map { repo in
            GitRepoPresentation(
                snapshot: makeSnapshot(for: repo),
                actions: makeActions(for: repo)
            )
        }
    }

    private func makeSnapshot(for repo: GitRepository) -> GitRepoSnapshot {
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
            selectedChangeKey: panel.selectedGitChange?.diffKey,
            selectedCommitKey: panel.selectedGitCommit?.selectionKey,
            lastError: repo.lastError,
            staged: repo.indexChanges,
            unstaged: repo.workingTreeChanges,
            untracked: repo.untrackedChanges,
            conflicted: repo.mergeChanges,
            availableBranches: repo.availableBranches,
            commits: repo.commits
        )
    }

    private func makeActions(for repo: GitRepository) -> GitRepoActions {
        GitRepoActions(
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
                panel.selectedGitChange = GitDiffSelection(
                    absolutePath: change.absolutePath,
                    repoRoot: repo.root,
                    path: change.path,
                    isStaged: change.isStaged,
                    status: change.status,
                    originalPath: change.originalPath
                )
                panel.selectedGitCommit = nil
                workspace.focusedRepoID = repo.id
            },
            onSelectCommit: { commit in
                panel.selectedGitChange = nil
                panel.selectedGitCommit = GitCommitSelection(
                    repoRoot: repo.root,
                    sha: commit.id,
                    shortSha: commit.shortSha
                )
                workspace.focusedRepoID = repo.id
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
    let snapshot: GitRepoSnapshot
    let actions: GitRepoActions

    @State private var isExpanded: Bool = true
    @State private var isGraphExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(snapshot: snapshot, actions: actions)
            if isExpanded {
                commitArea(snapshot: snapshot, actions: actions)
                if let err = snapshot.lastError {
                    errorBanner(text: err, actions: actions)
                }
                changesList(snapshot: snapshot, actions: actions)
                graphSection(snapshot: snapshot, actions: actions)
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
    private func graphSection(snapshot: GitRepoSnapshot, actions: GitRepoActions) -> some View {
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
                        GitCommitRow(
                            commit: commit,
                            isSelected: "\(snapshot.repoRoot)|commit|\(commit.id)" == snapshot.selectedCommitKey,
                            onSelect: { actions.onSelectCommit(commit) }
                        )
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
                    selectedChangeKey: snapshot.selectedChangeKey,
                    actions: actions
                )
            }
            if !snapshot.staged.isEmpty {
                changeGroup(
                    title: String(localized: "git.group.staged", defaultValue: "Staged Changes"),
                    count: snapshot.staged.count,
                    changes: snapshot.staged,
                    isStaged: true,
                    selectedChangeKey: snapshot.selectedChangeKey,
                    actions: actions
                )
            }
            if !snapshot.unstaged.isEmpty {
                changeGroup(
                    title: String(localized: "git.group.changes", defaultValue: "Changes"),
                    count: snapshot.unstaged.count,
                    changes: snapshot.unstaged,
                    isStaged: false,
                    selectedChangeKey: snapshot.selectedChangeKey,
                    actions: actions
                )
            }
            if !snapshot.untracked.isEmpty {
                changeGroup(
                    title: String(localized: "git.group.untracked", defaultValue: "Untracked"),
                    count: snapshot.untracked.count,
                    changes: snapshot.untracked,
                    isStaged: false,
                    selectedChangeKey: snapshot.selectedChangeKey,
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
        selectedChangeKey: String?,
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
                    isSelected: rowDiffKey(for: change, isStaged: isStaged) == selectedChangeKey,
                    actions: actions
                )
            }
        }
    }

    private func rowDiffKey(for change: GitChange, isStaged: Bool) -> String {
        "\(change.absolutePath)|\(isStaged ? "staged" : "wt")|\(change.status.rawValue)"
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
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

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
        .contentShape(Rectangle())
        .background(rowBackground)
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onSelect)
        .help("\(commit.shortSha) — \(commit.author) — \(commit.dateRelative)\n\(commit.subject)")
    }

    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.25) }
        if isHovering { return Color.primary.opacity(0.05) }
        return Color.clear
    }
}

// MARK: - Diff content view (right pane)

struct GitDiffContentView: View {
    let selection: GitDiffSelection

    @State private var diffLines: [GitRenderedDiffLine] = []
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
            } else if diffLines.isEmpty {
                placeholder(icon: "doc", title: String(localized: "git.diff.empty", defaultValue: "No diff to display"))
            } else {
                ScrollView([.vertical, .horizontal]) {
                    DiffLinesView(lines: diffLines)
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
        let outcome: (lines: [GitRenderedDiffLine], error: String?) = await Task.detached(priority: .userInitiated) { () -> ([GitRenderedDiffLine], String?) in
            switch sel.status {
            case .untracked:
                guard let content = try? String(contentsOfFile: sel.absolutePath, encoding: .utf8) else {
                    return ([], String(localized: "git.diff.cantRead", defaultValue: "Cannot read file"))
                }
                let diff = GitUnifiedDiffParser.untrackedDiff(path: sel.path, content: content)
                return (GitUnifiedDiffParser.parse(diff), nil)
            default:
                let args: [String]
                if sel.isStaged {
                    args = ["diff", "--cached", "--no-color", "--find-renames", "--", sel.path]
                } else {
                    args = ["diff", "--no-color", "--find-renames", "--", sel.path]
                }
                let out = GitRepository.runGit(in: sel.repoRoot, args: args) ?? ""
                return (GitUnifiedDiffParser.parse(out), nil)
            }
        }.value

        diffLines = outcome.lines
        error = outcome.error
        isLoading = false
    }
}

private struct DiffLinesView: View {
    let lines: [GitRenderedDiffLine]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                DiffLineRow(line: line)
            }
        }
    }
}

private struct DiffLineRow: View {
    let line: GitRenderedDiffLine

    var body: some View {
        HStack(spacing: 0) {
            Text(numberText(line.oldLineNumber))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(gutterTextColor)
                .frame(width: 46, alignment: .trailing)
                .padding(.trailing, 8)
                .background(gutterBackground)
            Text(numberText(line.newLineNumber))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(gutterTextColor)
                .frame(width: 46, alignment: .trailing)
                .padding(.trailing, 8)
                .background(gutterBackground)
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(textColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
        }
        .background(rowBackground)
        .frame(minWidth: 760, maxWidth: .infinity, alignment: .leading)
    }

    private func numberText(_ number: Int?) -> String {
        guard let number else { return "" }
        return "\(number)"
    }

    private var textColor: Color {
        switch line.kind {
        case .fileHeader: return .secondary
        case .hunk: return .blue
        case .addition: return .green
        case .deletion: return .red
        case .context: return .primary
        }
    }

    private var rowBackground: Color {
        switch line.kind {
        case .fileHeader: return Color.primary.opacity(0.035)
        case .hunk: return Color.blue.opacity(0.10)
        case .addition: return Color.green.opacity(0.13)
        case .deletion: return Color.red.opacity(0.13)
        case .context: return Color.clear
        }
    }

    private var gutterBackground: Color {
        switch line.kind {
        case .hunk: return Color.blue.opacity(0.08)
        case .addition: return Color.green.opacity(0.09)
        case .deletion: return Color.red.opacity(0.09)
        case .fileHeader: return Color.primary.opacity(0.04)
        case .context: return Color.primary.opacity(0.025)
        }
    }

    private var gutterTextColor: Color {
        switch line.kind {
        case .addition: return .green.opacity(0.9)
        case .deletion: return .red.opacity(0.9)
        case .hunk: return .blue.opacity(0.9)
        case .fileHeader: return .clear
        case .context: return .secondary
        }
    }
}

// MARK: - Commit detail content view (right pane)

struct GitCommitDetailContentView: View {
    let selection: GitCommitSelection

    @State private var detail: GitCommitDetail?
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if isLoading {
                placeholder(icon: "ellipsis.circle", title: String(localized: "git.commitDetail.loading", defaultValue: "Loading commit…"))
            } else if let error {
                placeholder(icon: "exclamationmark.triangle", title: error)
            } else if let detail {
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 12) {
                        commitSummary(detail)
                        fileList(detail.files)
                        if detail.diffLines.isEmpty {
                            Text(String(localized: "git.commitDetail.noPatch", defaultValue: "No patch to display"))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                        } else {
                            DiffLinesView(lines: detail.diffLines)
                        }
                    }
                    .padding(.vertical, 10)
                }
            } else {
                placeholder(icon: "doc", title: String(localized: "git.commitDetail.empty", defaultValue: "No commit to display"))
            }
        }
        .id(selection.selectionKey)
        .task(id: selection.selectionKey) {
            await loadCommit()
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(selection.shortSha)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(String(localized: "git.commitDetail.title", defaultValue: "Commit"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func commitSummary(_ detail: GitCommitDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(detail.subject)
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(detail.shortSha)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(detail.authorLine)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Text(detail.sha)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            if !detail.bodyText.isEmpty {
                Text(detail.bodyText)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .frame(minWidth: 760, maxWidth: .infinity, alignment: .leading)
    }

    private func fileList(_ files: [GitCommitFileChange]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "git.commitDetail.filesChanged", defaultValue: "Files changed").uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            if files.isEmpty {
                Text(String(localized: "git.commitDetail.noFiles", defaultValue: "No changed files reported"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(files) { file in
                    HStack(spacing: 8) {
                        Text(file.displayStatus)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(statusColor(file.displayStatus))
                            .frame(width: 20, alignment: .leading)
                        Text(fileLabel(file))
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(minWidth: 760, maxWidth: .infinity, alignment: .leading)
    }

    private func fileLabel(_ file: GitCommitFileChange) -> String {
        if let oldPath = file.oldPath, oldPath != file.path {
            return "\(oldPath) → \(file.path)"
        }
        return file.path
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "A": return .green
        case "D": return .red
        case "R": return .purple
        case "C": return .teal
        default: return .orange
        }
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

    private func loadCommit() async {
        isLoading = true
        error = nil
        detail = nil

        let selection = self.selection
        let outcome: (detail: GitCommitDetail?, error: String?) = await Task.detached(priority: .userInitiated) {
            let metadataFormat = "%H%x1f%h%x1f%an%x1f%ae%x1f%ad%x1f%B"
            guard let metadata = GitRepository.runGit(
                in: selection.repoRoot,
                args: ["show", "-s", "--date=local", "--format=\(metadataFormat)", selection.sha]
            ) else {
                return (nil, String(localized: "git.commitDetail.cantLoad", defaultValue: "Cannot load commit"))
            }

            let parts = metadata.components(separatedBy: "\u{001f}")
            guard parts.count >= 6 else {
                return (nil, String(localized: "git.commitDetail.cantParse", defaultValue: "Cannot parse commit"))
            }

            let message = parts.dropFirst(5).joined(separator: "\u{001f}")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let subject = message.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? selection.shortSha

            let nameStatus = GitRepository.runGit(
                in: selection.repoRoot,
                args: ["show", "--format=", "--name-status", "--find-renames", "--find-copies", "--root", selection.sha]
            ) ?? ""
            let files = GitCommitNameStatusParser.parse(nameStatus)

            let patch = GitRepository.runGit(
                in: selection.repoRoot,
                args: ["show", "--format=", "--patch", "--no-color", "--find-renames", "--find-copies", "--root", selection.sha]
            ) ?? ""

            let detail = GitCommitDetail(
                sha: parts[0].trimmingCharacters(in: .whitespacesAndNewlines),
                shortSha: parts[1],
                subject: subject,
                author: parts[2],
                authorEmail: parts[3],
                date: parts[4],
                message: message,
                files: files,
                diffLines: GitUnifiedDiffParser.parse(patch)
            )
            return (detail, nil)
        }.value

        detail = outcome.detail
        error = outcome.error
        isLoading = false
    }

}

private extension GitCommitDetail {
    var authorLine: String {
        if authorEmail.isEmpty {
            return "\(author) · \(date)"
        }
        return "\(author) <\(authorEmail)> · \(date)"
    }

    var bodyText: String {
        let lines = message.components(separatedBy: .newlines)
        guard lines.count > 1 else { return "" }
        return lines.dropFirst()
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
