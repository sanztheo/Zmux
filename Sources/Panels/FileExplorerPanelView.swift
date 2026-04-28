import SwiftUI

struct FileExplorerTabView: View {
    @ObservedObject var panel: FileExplorerPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let onRequestPanelFocus: () -> Void

    var body: some View {
        VStack {
            Text(String(localized: "fileExplorer.placeholder", defaultValue: "File Explorer"))
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(panel.rootPath)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
