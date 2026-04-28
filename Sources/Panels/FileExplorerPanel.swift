import Foundation
import Combine
import AppKit

@MainActor
final class FileExplorerPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .fileExplorer

    @Published var rootPath: String
    @Published private(set) var displayTitle: String = ""
    @Published private(set) var focusFlashToken: Int = 0

    var displayIcon: String? { "folder" }
    var isDirty: Bool { false }

    private(set) var workspaceId: UUID

    init(workspaceId: UUID, rootPath: String) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.rootPath = rootPath
        self.displayTitle = (rootPath as NSString).lastPathComponent
    }

    func close() {}
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
}
