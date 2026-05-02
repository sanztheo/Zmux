import XCTest

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
}
