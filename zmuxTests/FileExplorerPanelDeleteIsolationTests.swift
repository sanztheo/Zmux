import XCTest
import CodeEditSourceEditor

#if canImport(zmux_DEV)
@testable import zmux_DEV
#elseif canImport(zmux)
@testable import zmux
#endif

/// Regression coverage for https://github.com/manaflow-ai/zmux issue:
/// Cmd+Delete in the IDE panel was trashing the workspace root because
/// `FileExplorerPanel.deleteItem(at:)` had no root-path guard, and the key
/// handler's destructive target chain fell back to `panel.activeFolder`
/// (which is set to the root as soon as the user navigates the tree).
///
/// These tests pin the model-level invariant: deleting the root path must
/// never trash the workspace, and child file deletion must continue to work.
@MainActor
final class FileExplorerPanelDeleteIsolationTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileExplorerPanelDeleteIsolationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot, FileManager.default.fileExists(atPath: tempRoot.path) {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        try super.tearDownWithError()
    }

    func testDeleteItemRefusesToTrashWorkspaceRoot() throws {
        let panel = FileExplorerPanel(workspaceId: UUID(), rootPath: tempRoot.path)

        // Simulate the user state that triggered the original bug: nothing is
        // visually selected and no editor file is open, but `activeFolder`
        // resolves to the workspace root after a fresh project open.
        panel.selectedPath = nil
        panel.selectedFile = nil
        panel.activeFolder = panel.rootPath

        let trashed = panel.deleteItem(at: panel.rootPath)

        XCTAssertFalse(trashed, "deleteItem must refuse to trash the workspace root")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: tempRoot.path),
            "Workspace root directory must still exist after a refused delete"
        )
    }

    func testDeleteItemStillTrashesChildFiles() throws {
        let child = tempRoot.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: child)

        let panel = FileExplorerPanel(workspaceId: UUID(), rootPath: tempRoot.path)
        panel.selectedPath = child.path

        let trashed = panel.deleteItem(at: child.path)

        XCTAssertTrue(trashed, "deleteItem must still trash regular child files")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: child.path),
            "Child file must be gone from its original location after a successful delete"
        )
    }

    func testWorktreeParserHandlesBranchesDetachedAndPathsWithSpaces() throws {
        let output = """
        worktree /Users/me/project
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree /Users/me/project feature branch
        HEAD 2222222222222222222222222222222222222222
        branch refs/heads/feature/editor

        worktree /Users/me/project detached
        HEAD 3333333333333333333333333333333333333333
        detached

        """

        let snapshots = GitWorktreeListParser.parse(output)

        XCTAssertEqual(snapshots.count, 3)
        XCTAssertEqual(snapshots[0].path, "/Users/me/project")
        XCTAssertEqual(snapshots[0].branch, "refs/heads/main")
        XCTAssertEqual(snapshots[1].path, "/Users/me/project feature branch")
        XCTAssertEqual(snapshots[1].branchDisplayName, "feature/editor")
        XCTAssertEqual(snapshots[2].path, "/Users/me/project detached")
        XCTAssertTrue(snapshots[2].isDetached)
        XCTAssertEqual(snapshots[2].head, "3333333333333333333333333333333333333333")
    }

    func testWorktreeParserReturnsEmptyForEmptyOutput() throws {
        XCTAssertTrue(GitWorktreeListParser.parse("").isEmpty)
    }

    func testSwitchRootReloadsTreeAndClearsDirtyEditorState() throws {
        let firstFile = tempRoot.appendingPathComponent("first.swift")
        try Data("let first = true\n".utf8).write(to: firstFile)

        let secondRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileExplorerPanelSecondRoot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: secondRoot) }
        let secondFile = secondRoot.appendingPathComponent("second.swift")
        try Data("let second = true\n".utf8).write(to: secondFile)

        let panel = FileExplorerPanel(workspaceId: UUID(), rootPath: tempRoot.path)
        panel.openFile(firstFile.path)
        panel.fileContent = "let first = false\n"
        panel.markDirty()

        XCTAssertTrue(panel.isDirty)
        XCTAssertTrue(panel.switchRoot(to: secondRoot.path))

        XCTAssertEqual(panel.rootPath, secondRoot.standardizedFileURL.path)
        XCTAssertNil(panel.selectedFile)
        XCTAssertFalse(panel.isDirty)
        XCTAssertEqual(panel.fileContent, "")
        XCTAssertTrue(panel.fileTree.contains { $0.path == secondFile.path })
    }

    func testSwitchRootRejectsNonDirectory() throws {
        let panel = FileExplorerPanel(workspaceId: UUID(), rootPath: tempRoot.path)
        let missing = tempRoot.appendingPathComponent("missing")

        XCTAssertFalse(panel.switchRoot(to: missing.path))
        XCTAssertEqual(panel.rootPath, tempRoot.path)
    }

    func testOpenFileKeepsDetectedLanguageForLargeSourceAndEnablesPerformanceMode() throws {
        let largeSwiftFile = tempRoot.appendingPathComponent("LargeFile.swift")
        let body = (0..<4_500)
            .map { "let value\($0) = \"\(String(repeating: "x", count: 24))\"" }
            .joined(separator: "\n")
        try Data(body.utf8).write(to: largeSwiftFile)

        let panel = FileExplorerPanel(workspaceId: UUID(), rootPath: tempRoot.path)
        panel.openFile(largeSwiftFile.path)

        XCTAssertEqual(panel.fileLanguage, .swift)
        XCTAssertTrue(panel.isFilePerformanceMode)
        XCTAssertFalse(panel.isFileTooLarge)
    }

    func testCodeEditorStateCacheRestoresStateForFilePath() throws {
        CodeEditorStateCache.removeAll()
        let filePath = tempRoot.appendingPathComponent("state.swift").path
        let state = SourceEditorState(cursorPositions: [CursorPosition(line: 7, column: 3)])

        CodeEditorStateCache.store(state, for: filePath)

        XCTAssertEqual(CodeEditorStateCache.state(for: filePath), state)
    }

    func testCodeEditorLocalWordSuggestionsAreDeterministic() throws {
        let text = "rename render renderLine unrelated render"

        let suggestions = CodeEditorHub.localWordCandidates(in: text, prefix: "ren", limit: 10)

        XCTAssertEqual(suggestions, ["rename", "render", "renderLine"])
    }
}
