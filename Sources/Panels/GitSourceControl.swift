import Foundation
import Combine
import AppKit

// MARK: - Domain

enum GitChangeStatus: String, Hashable {
    case modified
    case added
    case deleted
    case renamed
    case copied
    case untracked
    case conflicted
}

struct GitChange: Identifiable, Hashable {
    let id: String  // absolute path (rename: post-rename path)
    let path: String  // path relative to repo root
    let absolutePath: String
    let status: GitChangeStatus
    let isStaged: Bool
    let originalPath: String?  // for renames

    var displayName: String { (path as NSString).lastPathComponent }
    var displayDirectory: String { (path as NSString).deletingLastPathComponent }
}

enum GitSortKey: String, CaseIterable {
    case name
    case path
    case status
}

enum GitViewMode: String, CaseIterable {
    case list
    case tree
}

/// Lightweight value snapshot used to drive the diff content view in the right pane.
/// Carries everything needed to rerun `git diff` and identify the file across refreshes.
struct GitDiffSelection: Equatable, Hashable {
    let absolutePath: String
    let repoRoot: String
    let path: String  // relative to repo root
    let isStaged: Bool
    let status: GitChangeStatus
    let originalPath: String?

    var diffKey: String { "\(absolutePath)|\(isStaged ? "staged" : "wt")|\(status.rawValue)" }
}

/// One row in the per-repo "Graph" (commit history) section.
struct GitCommit: Identifiable, Hashable {
    let id: String  // full sha
    let shortSha: String
    let subject: String
    let author: String
    let dateRelative: String
}

// MARK: - Per-repository model

@MainActor
final class GitRepository: ObservableObject, Identifiable {
    let id: UUID = UUID()
    let root: String
    let displayName: String
    let isSubmodule: Bool

    @Published private(set) var headBranch: String?
    @Published private(set) var headSha: String?
    @Published private(set) var upstream: String?
    @Published private(set) var ahead: Int = 0
    @Published private(set) var behind: Int = 0
    @Published private(set) var indexChanges: [GitChange] = []
    @Published private(set) var workingTreeChanges: [GitChange] = []
    @Published private(set) var untrackedChanges: [GitChange] = []
    @Published private(set) var mergeChanges: [GitChange] = []
    @Published private(set) var availableBranches: [String] = []
    @Published private(set) var commits: [GitCommit] = []
    @Published var commitMessage: String = ""
    @Published private(set) var isRefreshing: Bool = false
    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var lastError: String?

    private var watcher: DispatchSourceFileSystemObject?
    private let watchQueue = DispatchQueue(label: "com.zmux.gitRepoWatcher", qos: .utility)
    private var debounce: DispatchWorkItem?

    var totalChangeCount: Int {
        indexChanges.count + workingTreeChanges.count + untrackedChanges.count + mergeChanges.count
    }

    var isDirty: Bool { totalChangeCount > 0 }

    init(root: String, isSubmodule: Bool = false) {
        self.root = root
        self.displayName = (root as NSString).lastPathComponent
        self.isSubmodule = isSubmodule
        startWatchingIndex()
        Task { await self.refresh() }
    }

    deinit {
        watcher?.cancel()
        debounce?.cancel()
    }

    // MARK: - Refresh

    func refresh() async {
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let root = self.root
        let result = await Task.detached(priority: .userInitiated) {
            GitRepository.collectStatus(root: root)
        }.value

        self.headBranch = result.branch
        self.headSha = result.headSha
        self.upstream = result.upstream
        self.ahead = result.ahead
        self.behind = result.behind
        self.indexChanges = result.indexChanges
        self.workingTreeChanges = result.workingTreeChanges
        self.untrackedChanges = result.untrackedChanges
        self.mergeChanges = result.mergeChanges
        self.availableBranches = result.branches
        self.commits = result.commits
    }

    // MARK: - File system watcher (.git/index + .git/HEAD)

    private func startWatchingIndex() {
        let gitDir = (root as NSString).appendingPathComponent(".git")
        let fd = open(gitDir, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .link, .rename, .delete],
            queue: watchQueue
        )
        source.setEventHandler { [weak self] in
            self?.scheduleDebouncedRefresh()
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        source.resume()
        watcher = source
    }

    private func scheduleDebouncedRefresh() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                await self?.refresh()
            }
        }
        debounce = work
        watchQueue.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: - Mutations (run off-main, refresh on completion)

    func stage(_ change: GitChange) async {
        await runMutating(["add", "--", change.path])
    }

    func unstage(_ change: GitChange) async {
        await runMutating(["reset", "HEAD", "--", change.path])
    }

    func discard(_ change: GitChange) async {
        if change.status == .untracked {
            await runMutating(["clean", "-f", "--", change.path])
        } else {
            await runMutating(["checkout", "--", change.path])
        }
    }

    func stageAll() async {
        await runMutating(["add", "-A"])
    }

    func unstageAll() async {
        await runMutating(["reset", "HEAD"])
    }

    func commit() async {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        let root = self.root
        await Task.detached(priority: .userInitiated) {
            _ = GitRepository.runGit(in: root, args: ["commit", "-m", message])
        }.value
        commitMessage = ""
        await refresh()
    }

    func checkout(branch: String) async {
        await runMutating(["checkout", branch])
    }

    func push() async {
        if isSyncing { return }
        isSyncing = true
        defer { isSyncing = false }
        let root = self.root
        let upstream = self.upstream
        let head = self.headBranch
        let err = await Task.detached(priority: .userInitiated) { () -> String? in
            if upstream == nil, let head, !head.isEmpty {
                return GitRepository.runGitWithError(in: root, args: ["push", "-u", "origin", head])
            }
            return GitRepository.runGitWithError(in: root, args: ["push"])
        }.value
        lastError = err
        await refresh()
    }

    func pull() async {
        if isSyncing { return }
        isSyncing = true
        defer { isSyncing = false }
        let root = self.root
        let err = await Task.detached(priority: .userInitiated) { () -> String? in
            GitRepository.runGitWithError(in: root, args: ["pull", "--ff-only"])
        }.value
        lastError = err
        await refresh()
    }

    func sync() async {
        if isSyncing { return }
        isSyncing = true
        defer { isSyncing = false }
        let root = self.root
        let upstream = self.upstream
        let head = self.headBranch
        let err = await Task.detached(priority: .userInitiated) { () -> String? in
            if let pullErr = GitRepository.runGitWithError(in: root, args: ["pull", "--ff-only"]) {
                return pullErr
            }
            if upstream == nil, let head, !head.isEmpty {
                return GitRepository.runGitWithError(in: root, args: ["push", "-u", "origin", head])
            }
            return GitRepository.runGitWithError(in: root, args: ["push"])
        }.value
        lastError = err
        await refresh()
    }

    func clearError() {
        lastError = nil
    }

    private func runMutating(_ args: [String]) async {
        let root = self.root
        await Task.detached(priority: .userInitiated) {
            _ = GitRepository.runGit(in: root, args: args)
        }.value
        await refresh()
    }

    // MARK: - Static collectors

    private struct StatusResult {
        var branch: String?
        var headSha: String?
        var upstream: String?
        var ahead: Int
        var behind: Int
        var indexChanges: [GitChange]
        var workingTreeChanges: [GitChange]
        var untrackedChanges: [GitChange]
        var mergeChanges: [GitChange]
        var branches: [String]
        var commits: [GitCommit]
    }

    nonisolated private static func collectStatus(root: String) -> StatusResult {
        let branch = runGit(in: root, args: ["symbolic-ref", "--short", "HEAD"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let headSha = runGit(in: root, args: ["rev-parse", "HEAD"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let upstreamRef = runGit(in: root, args: ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var ahead = 0
        var behind = 0
        if let upstreamRef, !upstreamRef.isEmpty, !upstreamRef.contains("@{u}") {
            if let counts = runGit(in: root, args: ["rev-list", "--left-right", "--count", "HEAD...\(upstreamRef)"])?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespaces)
                .compactMap(Int.init), counts.count == 2 {
                ahead = counts[0]
                behind = counts[1]
            }
        }

        let porcelain = runGit(in: root, args: ["status", "-z", "-uall", "--ignore-submodules"]) ?? ""
        let parsed = parsePorcelainZ(porcelain, repoRoot: root)

        let branches = (runGit(in: root, args: ["for-each-ref", "--format=%(refname:short)", "refs/heads"]) ?? "")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let logFormat = "%H%x1f%h%x1f%an%x1f%ar%x1f%s"
        let commits = (runGit(in: root, args: ["log", "-n", "30", "--format=\(logFormat)"]) ?? "")
            .components(separatedBy: "\n")
            .compactMap { line -> GitCommit? in
                let parts = line.components(separatedBy: "\u{001f}")
                guard parts.count >= 5, !parts[0].isEmpty else { return nil }
                return GitCommit(
                    id: parts[0],
                    shortSha: parts[1],
                    subject: parts[4],
                    author: parts[2],
                    dateRelative: parts[3]
                )
            }

        return StatusResult(
            branch: branch?.isEmpty == false ? branch : nil,
            headSha: headSha?.isEmpty == false ? headSha : nil,
            upstream: upstreamRef?.isEmpty == false ? upstreamRef : nil,
            ahead: ahead,
            behind: behind,
            indexChanges: parsed.index,
            workingTreeChanges: parsed.working,
            untrackedChanges: parsed.untracked,
            mergeChanges: parsed.merge,
            branches: branches,
            commits: commits
        )
    }

    nonisolated private static func parsePorcelainZ(_ output: String, repoRoot: String) -> (
        index: [GitChange], working: [GitChange], untracked: [GitChange], merge: [GitChange]
    ) {
        var index: [GitChange] = []
        var working: [GitChange] = []
        var untracked: [GitChange] = []
        var merge: [GitChange] = []

        let entries = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < entries.count {
            let entry = entries[i]
            if entry.count < 3 { i += 1; continue }
            let xy = entry.prefix(2)
            let xyChars = Array(xy)
            let x = xyChars[0]
            let y = xyChars[1]
            let path = String(entry.dropFirst(3))
            var originalPath: String? = nil
            var endIndex = i + 1

            // Renames/copies have a second path slot in -z output
            if x == "R" || x == "C" || y == "R" || y == "C" {
                if i + 1 < entries.count {
                    originalPath = entries[i + 1]
                    endIndex = i + 2
                }
            }

            let absolutePath = (repoRoot as NSString).appendingPathComponent(path)

            // Conflicts: any UU/AA/DD/AU/UA/DU/UD pattern → merge group
            if isConflictPair(x: x, y: y) {
                merge.append(GitChange(
                    id: absolutePath,
                    path: path,
                    absolutePath: absolutePath,
                    status: .conflicted,
                    isStaged: false,
                    originalPath: originalPath
                ))
                i = endIndex
                continue
            }

            // Untracked
            if x == "?" && y == "?" {
                untracked.append(GitChange(
                    id: absolutePath,
                    path: path,
                    absolutePath: absolutePath,
                    status: .untracked,
                    isStaged: false,
                    originalPath: nil
                ))
                i = endIndex
                continue
            }

            // Index (staged) — X column
            if x != " " && x != "?" {
                if let status = mapStatusChar(x) {
                    index.append(GitChange(
                        id: absolutePath,
                        path: path,
                        absolutePath: absolutePath,
                        status: status,
                        isStaged: true,
                        originalPath: originalPath
                    ))
                }
            }

            // Working tree (unstaged) — Y column
            if y != " " && y != "?" {
                if let status = mapStatusChar(y) {
                    working.append(GitChange(
                        id: absolutePath,
                        path: path,
                        absolutePath: absolutePath,
                        status: status,
                        isStaged: false,
                        originalPath: originalPath
                    ))
                }
            }

            i = endIndex
        }

        return (index, working, untracked, merge)
    }

    nonisolated private static func mapStatusChar(_ c: Character) -> GitChangeStatus? {
        switch c {
        case "M", "T": return .modified
        case "A": return .added
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .copied
        default: return nil
        }
    }

    nonisolated private static func isConflictPair(x: Character, y: Character) -> Bool {
        let conflictChars: Set<Character> = ["U"]
        if conflictChars.contains(x) || conflictChars.contains(y) { return true }
        if x == "A" && y == "A" { return true }
        if x == "D" && y == "D" { return true }
        return false
    }

    nonisolated static func runGit(in directory: String, args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    /// Runs git capturing stderr — returns nil on success, error message on failure.
    /// Used by push/pull/sync where surfacing the failure to the user matters.
    nonisolated static func runGitWithError(in directory: String, args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
            _ = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0 { return nil }
            let raw = String(data: errData, encoding: .utf8) ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "git \(args.joined(separator: " ")) failed" : trimmed
        } catch {
            return error.localizedDescription
        }
    }
}

// MARK: - Workspace (multi-repo)

@MainActor
final class GitWorkspace: ObservableObject {
    @Published private(set) var repositories: [GitRepository] = []
    @Published var focusedRepoID: UUID?
    @Published var sortKey: GitSortKey = .path
    @Published var viewMode: GitViewMode = .list
    @Published var hiddenRepoIDs: Set<UUID> = []

    let workspaceRoot: String

    init(workspaceRoot: String) {
        self.workspaceRoot = workspaceRoot
        Task { await self.discover() }
    }

    var visibleRepositories: [GitRepository] {
        let visible = repositories.filter { !hiddenRepoIDs.contains($0.id) }
        switch sortKey {
        case .name:
            return visible.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .path:
            return visible.sorted { $0.root.localizedCaseInsensitiveCompare($1.root) == .orderedAscending }
        case .status:
            return visible.sorted { $0.totalChangeCount > $1.totalChangeCount }
        }
    }

    func discover() async {
        let root = self.workspaceRoot
        let roots = await Task.detached(priority: .userInitiated) {
            GitWorkspace.discoverRepoRoots(workspaceRoot: root)
        }.value

        let existing = Set(repositories.map(\.root))
        let newRoots = roots.filter { !existing.contains($0.path) }
        for repoInfo in newRoots {
            repositories.append(GitRepository(root: repoInfo.path, isSubmodule: repoInfo.isSubmodule))
        }

        // Remove repos no longer present (e.g. submodule deinit)
        let stillPresent = Set(roots.map(\.path))
        repositories.removeAll { !stillPresent.contains($0.root) }

        if focusedRepoID == nil, let first = visibleRepositories.first {
            focusedRepoID = first.id
        }
    }

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for repo in repositories {
                group.addTask { @MainActor in
                    await repo.refresh()
                }
            }
        }
    }

    func setRepoVisible(_ repoID: UUID, visible: Bool) {
        if visible {
            hiddenRepoIDs.remove(repoID)
        } else {
            hiddenRepoIDs.insert(repoID)
        }
    }

    // MARK: - Discovery

    private struct DiscoveredRepo {
        let path: String
        let isSubmodule: Bool
    }

    nonisolated private static func discoverRepoRoots(workspaceRoot: String) -> [DiscoveredRepo] {
        var seen = Set<String>()
        var result: [DiscoveredRepo] = []

        // 1. Resolve top-level repo from workspace root
        if let topLevel = GitRepository.runGit(in: workspaceRoot, args: ["rev-parse", "--show-toplevel"])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !topLevel.isEmpty {
            if seen.insert(topLevel).inserted {
                result.append(DiscoveredRepo(path: topLevel, isSubmodule: false))
            }
            // Submodules from .gitmodules
            for sub in submodulePaths(repoRoot: topLevel) {
                let absolute = (topLevel as NSString).appendingPathComponent(sub)
                if FileManager.default.fileExists(atPath: (absolute as NSString).appendingPathComponent(".git")) {
                    if seen.insert(absolute).inserted {
                        result.append(DiscoveredRepo(path: absolute, isSubmodule: true))
                    }
                }
            }
        }

        // 2. Bounded scan: depth 2 from workspaceRoot, looking for `.git` directories
        //    that aren't already covered. Catches sibling "vendor/foo" embedded repos.
        let fm = FileManager.default
        let maxDepth = 2
        var queue: [(String, Int)] = [(workspaceRoot, 0)]
        let ignored: Set<String> = ["node_modules", ".build", "DerivedData", "Pods", ".venv", "venv", "target"]

        while let (dir, depth) = queue.first {
            queue.removeFirst()
            if depth > maxDepth { continue }
            guard let contents = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in contents {
                if ignored.contains(entry) { continue }
                let full = (dir as NSString).appendingPathComponent(entry)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { continue }

                if entry == ".git" {
                    let parent = (full as NSString).deletingLastPathComponent
                    if seen.insert(parent).inserted {
                        let isSub = result.contains { $0.path == parent && $0.isSubmodule }
                        result.append(DiscoveredRepo(path: parent, isSubmodule: isSub))
                    }
                    continue
                }

                if depth + 1 <= maxDepth {
                    queue.append((full, depth + 1))
                }
            }
        }

        return result
    }

    nonisolated private static func submodulePaths(repoRoot: String) -> [String] {
        let modulesPath = (repoRoot as NSString).appendingPathComponent(".gitmodules")
        guard let content = try? String(contentsOfFile: modulesPath, encoding: .utf8) else { return [] }
        var paths: [String] = []
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("path") {
                if let eq = trimmed.firstIndex(of: "=") {
                    let value = String(trimmed[trimmed.index(after: eq)...])
                        .trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty { paths.append(value) }
                }
            }
        }
        return paths
    }
}
