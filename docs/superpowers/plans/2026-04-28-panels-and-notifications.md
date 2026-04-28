# Panels, Notifications & Terminal Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix blank terminal bug, add notification source-based blocklist, add Git Diff panel (4 modes), add File Explorer panel with inline code editor.

**Architecture:** Four workstreams executed sequentially. New panels follow the existing `Panel` protocol pattern (MarkdownPanel as reference). Notification filtering adds a `source` field to the existing struct and intercepts in `addNotification()`. Shared git cache avoids duplicate `Process` calls across panels.

**Tech Stack:** Swift, SwiftUI, AppKit (`NSTextView`, `NSRulerView`), `Process` for git CLI, `DispatchSource` for file watching, `NSAttributedString` for syntax highlighting.

**Design doc:** `docs/plans/2026-04-28-panels-and-notifications-design.md`

---

## Progress

### Completed

- [x] **Workstream 0: Rename zmux → zmux** — Full rebrand across all source files, resources, packages, scripts, docs. Bundle IDs, socket paths, env vars, CLI name all updated.
- [x] **Workstream 1: Bug terminal noir** — Fixed in one line: `GhosttyTerminalView.swift:5756` changed `visibleInUI` default from `true` to `false`. Root cause: first `setVisibleInUI(true)` never detected a hidden→visible transition, so `refreshSurfaceNow()` was skipped. Commit: `696e1123`.

### In Progress

- [ ] **Workstream 2: Notification blocklist** — Next up

---

## File Structure

### New files (7)

| File | Responsibility |
|------|---------------|
| `Sources/Panels/GitDiffPanel.swift` | Git diff panel model — runs git commands, parses diff output, manages diff cache, file list, mode switching |
| `Sources/Panels/GitDiffPanelView.swift` | SwiftUI view — mode selector header, file list sidebar, colored diff content area, summary footer |
| `Sources/Panels/FileExplorerPanel.swift` | File explorer panel model — lazy directory loading, tree state, file content loading, edit/save, FS cache |
| `Sources/Panels/FileExplorerPanelView.swift` | SwiftUI view — file tree sidebar, code content area with line numbers, edit toggle, file info footer |
| `Sources/Panels/CodeEditorView.swift` | `NSViewRepresentable` wrapping `NSTextView` — editable/read-only modes, line numbers via `NSRulerView`, Cmd+S save |
| `Sources/Panels/SyntaxHighlighter.swift` | Regex-based syntax highlighting — per-language keyword/string/comment patterns, returns `NSAttributedString` |
| `Sources/SharedGitCache.swift` | Shared git status cache — single `.git/index` watcher, TTL-based expiry, invalidation callbacks for consumers |

### Modified files (6)

| File | Lines to modify | Change |
|------|----------------|--------|
| `Sources/Panels/Panel.swift` | Lines 6-10 (`PanelType` enum) | Add `.gitDiff` and `.fileExplorer` cases |
| `Sources/Panels/PanelContentView.swift` | Lines 20-59 (switch in `body`) | Add two new cases routing to `GitDiffPanelView` and `FileExplorerPanelView` |
| `Sources/Workspace.swift` | After line 10440 (after `newMarkdownSurface`) | Add `newGitDiffSurface()` and `newFileExplorerSurface()` methods |
| `Sources/TerminalNotificationStore.swift` | Lines 658-667 (struct), 899-973 (`addNotification`) | Add `source: String?` field, add blocklist check at top of `addNotification()` |
| `Sources/TerminalController.swift` | Lines 7121-7227 (V2 notification methods) | Extract `params["source"]` and pass to `addNotification()` |
| `Sources/zmuxApp.swift` | Notification settings area | Add "Blocked Sources" and "Blocked Content Patterns" list editors |

---

## Workstream 1: Bug Terminal Noir

**Context:** Workspace with a single terminal renders completely black. The Ghostty submodule already has PR #11736 (white foreground default). Investigation shows a timing race: surface creation (`GhosttyTerminalView.swift:4639-4972`) calls `forceRefreshSurface()` at line 4971, but portal binding (`GhosttyTerminalView.swift:13010-13144`) applies visibility later. Single-pane workspaces may hit a window where the surface is alive but not yet marked visible.

### Task 1.1: Reproduce and diagnose

**Files:**
- Read: `Sources/GhosttyTerminalView.swift:4639-4972` (creation), `Sources/GhosttyTerminalView.swift:10830-10873` (setVisibleInUI), `Sources/WorkspaceContentView.swift:246-255` (panelVisibleInUI)

- [ ] **Step 1: Add diagnostic logging**
  In `GhosttyTerminalView.swift`, add `#if DEBUG` log calls at these points:
  - After `ghostty_surface_new` (line 4847): log surface pointer + timestamp
  - After `forceRefreshSurface()` (line 4971): log "initial refresh" + `visibleInUI` value
  - In `setVisibleInUI` (line 10832): log old → new visibility transition + surface pointer
  - In `refreshSurfaceNow` (line 10869): log "visibility-triggered refresh"
  Use `zmuxDebugLog()` (the existing debug log free function).

- [ ] **Step 2: Build tagged debug app and reproduce**
  Run: `./scripts/reload.sh --tag fix-blank-terminal --launch`
  Create a new workspace with a single terminal. Check `/tmp/zmux-debug-fix-blank-terminal.log` for the sequence of events.
  Expected: logs show `forceRefreshSurface` fires BEFORE `setVisibleInUI(true)`, confirming the race.

- [ ] **Step 3: Verify workaround**
  In the running debug app, add a second tab then close it. Check if terminal renders.
  Also test: `zmux refresh-surfaces` from another terminal.
  This confirms the surface data is intact — only rendering is stalled.

### Task 1.2: Fix the visibility race

**Files:**
- Modify: `Sources/GhosttyTerminalView.swift`

- [ ] **Step 1: Identify the fix point**
  The fix belongs in `setVisibleInUI` (line 10830). When transitioning from hidden → visible (lines 10865-10871), it already calls `refreshSurfaceNow`. The issue is that for the FIRST render, visibility may not transition because it was never explicitly set to false first.
  Check: is `visibleInUI` initialized to `false` or `true`? If `true`, the hidden→visible transition never fires.

- [ ] **Step 2: Implement the fix**
  Two possible approaches depending on Step 1 findings:
  
  **If `visibleInUI` defaults to `true`:** Change default to `false`. This ensures the first `setVisibleInUI(true)` call triggers the hidden→visible path with `refreshSurfaceNow`.
  
  **If `visibleInUI` defaults to `false` but the transition is missed:** Add a `refreshSurfaceNow` call at the end of `createSurface` (after line 4972), gated on `visibleInUI == true` at that point. This ensures the initial draw happens regardless of ordering.
  
  **If it's a portal binding timing issue:** Move the `forceRefreshSurface()` call from `createSurface` (line 4971) into the portal binding path (around line 13027), after visibility is applied.

- [ ] **Step 3: Rebuild and verify**
  Run: `./scripts/reload.sh --tag fix-blank-terminal --launch`
  Test: Create 5 new workspaces, each with a single terminal. All must render immediately.
  Test: Switch between workspaces rapidly. No blank frames.
  Test: Close all but one workspace. Terminal still renders.

- [ ] **Step 4: Remove diagnostic logging (keep only useful ones)**
  Remove verbose creation-path logs. Keep the `setVisibleInUI` transition log if it adds value to future debugging.

- [ ] **Step 5: Commit**
  `git add Sources/GhosttyTerminalView.swift && git commit -m "fix: terminal renders blank in single-pane workspace"`

---

## Workstream 2: Notification Blocklist

### Task 2.1: Add `source` field to notification struct

**Files:**
- Modify: `Sources/TerminalNotificationStore.swift:658-667`

- [ ] **Step 1: Add field to struct**
  Add `let source: String?` to `TerminalNotification` struct (after `body`, before `createdAt`).
  Update `Hashable` conformance if it's manually implemented (check if it is).

- [ ] **Step 2: Update `addNotification()` signature**
  At line 899, add `source: String? = nil` parameter (after `body`, before `cooldownKey`).
  Pass it through to the `TerminalNotification` initializer at line 949.

- [ ] **Step 3: Verify build**
  Run: `xcodebuild -project GhosttyTabs.xcodeproj -scheme zmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/zmux-blocklist build 2>&1 | tail -5`
  Expected: BUILD SUCCEEDED (all existing callers use default `nil`).

- [ ] **Step 4: Commit**
  `git add Sources/TerminalNotificationStore.swift && git commit -m "feat(notifications): add source field to TerminalNotification"`

### Task 2.2: Pass `source` from V2 API

**Files:**
- Modify: `Sources/TerminalController.swift:7121-7227`

- [ ] **Step 1: Update v2NotificationCreate (line 7121)**
  After line 7129 (`let body = ...`), add: extract `params["source"] as? String`.
  Pass it to `addNotification()` call at line 7145.

- [ ] **Step 2: Update v2NotificationCreateForSurface (line 7158)**
  Same pattern — extract `source` param, pass to `addNotification()`.

- [ ] **Step 3: Update v2NotificationCreateForTarget (line 7192)**
  Same pattern.

- [ ] **Step 4: Update OSC handler**
  In `GhosttyTerminalView.swift` (lines 3253-3283 and 3535-3559), pass `source: "osc"` to `addNotification()` calls.

- [ ] **Step 5: Verify build**
  Run: `xcodebuild -project GhosttyTabs.xcodeproj -scheme zmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/zmux-blocklist build 2>&1 | tail -5`

- [ ] **Step 6: Commit**
  `git add Sources/TerminalController.swift Sources/GhosttyTerminalView.swift && git commit -m "feat(notifications): pass source from V2 API and OSC handler"`

### Task 2.3: Implement blocklist filtering

**Files:**
- Modify: `Sources/TerminalNotificationStore.swift`

- [ ] **Step 1: Add blocklist settings**
  Add a new enum `NotificationBlocklistSettings` (near line 564, next to `NotificationPaneRingSettings`):
  - `static let sourcesKey = "notification.blocklist.sources"` → `[String]` from UserDefaults
  - `static let patternsKey = "notification.blocklist.patterns"` → `[String]` from UserDefaults
  - Cached `Set<String>` for sources, `[String]` lowercased for patterns
  - Invalidation on `UserDefaults.didChangeNotification` for these keys
  - `static func isBlocked(source: String?, title: String, subtitle: String, body: String) -> Bool`

- [ ] **Step 2: Add interception in addNotification()**
  At the top of `addNotification()` (line 900, before cooldown check), call `NotificationBlocklistSettings.isBlocked(source:title:subtitle:body:)`. Return early if blocked.

- [ ] **Step 3: Verify build**
  Run: `xcodebuild -project GhosttyTabs.xcodeproj -scheme zmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/zmux-blocklist build 2>&1 | tail -5`

- [ ] **Step 4: Commit**
  `git add Sources/TerminalNotificationStore.swift && git commit -m "feat(notifications): blocklist filtering by source and content patterns"`

### Task 2.4: Settings UI

**Files:**
- Modify: `Sources/zmuxApp.swift` (notification settings area)

- [ ] **Step 1: Find the notification settings section**
  Locate where `NotificationSoundSettings` and `NotificationPaneRingSettings` are rendered in the settings UI. The section may be in a separate view file — search for "notificationSound" or "notificationPaneRing" in SwiftUI views.

- [ ] **Step 2: Add "Blocked Sources" section**
  After the existing notification settings, add a new section:
  - Label: `String(localized: "settings.notifications.blockedSources", defaultValue: "Blocked Sources")`
  - `List` of current blocked sources with swipe-to-delete
  - `TextField` + "Add" button to add new source
  - Help text explaining the feature

- [ ] **Step 3: Add "Blocked Content Patterns" section**
  Same pattern as blocked sources but for content substring patterns.

- [ ] **Step 4: Build and manually verify**
  Run: `./scripts/reload.sh --tag fix-blank-terminal --launch`
  Open Settings → Notifications. Verify both sections appear, add/remove works, persists across restart.

- [ ] **Step 5: Commit**
  `git add Sources/zmuxApp.swift && git commit -m "feat(notifications): blocklist settings UI"`

---

## Workstream 3: Git Diff Panel

### Task 3.1: Register panel type

**Files:**
- Modify: `Sources/Panels/Panel.swift:6-10`
- Modify: `Sources/Panels/PanelContentView.swift:20-59`

- [ ] **Step 1: Add enum case**
  In `PanelType` enum (line 9), add `case gitDiff` after `case markdown`.

- [ ] **Step 2: Add placeholder view route**
  In `PanelContentView` body switch (line 20), add `case .gitDiff:` with a placeholder `Text("Git Diff — coming soon")`. This unblocks the build while we implement the real panel.

- [ ] **Step 3: Verify build**
  Run: `xcodebuild -project GhosttyTabs.xcodeproj -scheme zmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/zmux-gitdiff build 2>&1 | tail -5`

- [ ] **Step 4: Commit**
  `git add Sources/Panels/Panel.swift Sources/Panels/PanelContentView.swift && git commit -m "feat(panels): register gitDiff panel type"`

### Task 3.2: SharedGitCache

**Files:**
- Create: `Sources/SharedGitCache.swift`

- [ ] **Step 1: Design the cache interface**
  Singleton `SharedGitCache` with:
  - `func getStatus(repoRoot: String) -> [String: GitFileStatus]?` — returns cached status or nil
  - `func refreshStatus(repoRoot: String) -> [String: GitFileStatus]` — runs `git status --porcelain`, caches, returns
  - `func watchIndex(repoRoot: String, onChange: @escaping () -> Void) -> UUID` — registers DispatchSource on `.git/index`, returns registration ID
  - `func unwatchIndex(registrationId: UUID)` — removes callback
  - `func getBranches(repoRoot: String) -> [String]` — cached branch list (30s TTL)
  - `func getRecentCommits(repoRoot: String, limit: Int) -> [GitCommit]` — cached commit list (30s TTL)
  - `func invalidateAll(repoRoot: String)` — manual flush

  Internal storage:
  - `statusCache: [String: (statuses: [String: GitFileStatus], timestamp: Date)]` — 3s TTL
  - `branchCache: [String: (branches: [String], timestamp: Date)]` — 30s TTL
  - `commitCache: [String: (commits: [GitCommit], timestamp: Date)]` — 30s TTL
  - `indexWatchers: [String: DispatchSourceFileSystemObject]` — one per repo root
  - `callbacks: [String: [(id: UUID, callback: () -> Void)]]` — per repo root

  Reuse `GitStatusProvider.runGit()` pattern from `FileExplorerStore.swift:946-963` for Process execution.

- [ ] **Step 2: Implement**
  Follow `DispatchSource` pattern from `MarkdownPanel.swift:106-149`. Watch `.git/index` file with event mask `[.write, .delete, .rename, .extend]`. On change: invalidate status + diff caches, fire all registered callbacks.

- [ ] **Step 3: Verify build**
  Run: `xcodebuild ... build 2>&1 | tail -5`

- [ ] **Step 4: Commit**
  `git add Sources/SharedGitCache.swift && git commit -m "feat: shared git cache with index watcher"`

### Task 3.3: GitDiffPanel model

**Files:**
- Create: `Sources/Panels/GitDiffPanel.swift`

- [ ] **Step 1: Define the model**
  `@MainActor final class GitDiffPanel: Panel, ObservableObject` following MarkdownPanel pattern (reference: `Sources/Panels/MarkdownPanel.swift:7-39`).

  Properties:
  - `let id: UUID`
  - `let panelType: PanelType = .gitDiff`
  - `@Published var mode: DiffMode` (enum: `.workingTree`, `.staged`, `.commitCompare`, `.branchCompare`)
  - `@Published var repoPath: String`
  - `@Published var files: [DiffFile]` (struct: `path, status: GitFileStatus, insertions: Int, deletions: Int`)
  - `@Published var selectedFile: DiffFile?`
  - `@Published var diffContent: NSAttributedString?`
  - `@Published var isLoading: Bool`
  - `@Published var fromRef: String`
  - `@Published var toRef: String`
  - `@Published var displayTitle: String`
  - `var displayIcon: String? { "arrow.triangle.branch" }`
  - `var isDirty: Bool { false }` (read-only panel)
  - Private: `workspaceId: UUID`, cache registration ID

  Methods:
  - `func loadFileList()` — runs appropriate `git diff --name-status` command based on mode, parses output into `[DiffFile]`
  - `func loadDiff(for file: DiffFile)` — runs `git diff -- <path>` with mode-appropriate refs, parses into colored `NSAttributedString`
  - `func setMode(_ mode: DiffMode)` — switches mode, reloads file list
  - `func refresh()` — forces cache invalidation + reload
  - Panel protocol: `close()` unregisters from SharedGitCache, `focus()`/`unfocus()` are no-ops (like MarkdownPanel)

  Diff parsing: split output by lines, colorize `+`/`-`/`@@`/context lines with `NSAttributedString` attributes (foreground color + optional background tint).

- [ ] **Step 2: Implement diff content cache**
  Internal `diffCache: [String: (content: NSAttributedString, timestamp: Date)]` with 5s TTL, keyed by `"\(mode):\(fromRef):\(toRef):\(filePath)"`. Invalidated by SharedGitCache index watcher callback.

- [ ] **Step 3: Wire to SharedGitCache**
  On init, register with `SharedGitCache.shared.watchIndex(repoRoot:)`. On callback: reload file list if mode is `.workingTree` or `.staged` (compare modes use stable refs). On `close()`: unregister.

- [ ] **Step 4: Verify build**

- [ ] **Step 5: Commit**
  `git add Sources/Panels/GitDiffPanel.swift && git commit -m "feat: GitDiffPanel model with 4 diff modes"`

### Task 3.4: GitDiffPanelView

**Files:**
- Create: `Sources/Panels/GitDiffPanelView.swift`
- Modify: `Sources/Panels/PanelContentView.swift` (replace placeholder)

- [ ] **Step 1: Build the view**
  `struct GitDiffPanelView: View` with parameters matching the pattern from `PanelContentView` (reference: `MarkdownPanelView` receives `panel, isFocused, isVisibleInUI, portalPriority, onRequestPanelFocus`).

  Layout (top to bottom):
  - **Header:** `HStack` with mode `Picker` (segmented, 4 options). For commit/branch modes: two `Picker`s for ref selection (populated from `SharedGitCache.getBranches/getRecentCommits`). Refresh button (SF Symbol `arrow.clockwise`).
  - **Body:** `HSplitView` with:
    - Left (200pt min): `List` of `DiffFile` items. Each row shows status icon (M/A/D/R with color), filename, +/- counts. Selection binding to `panel.selectedFile`.
    - Right (flexible): `ScrollView` containing the diff `NSAttributedString` rendered in a read-only `NSTextView` via `NSViewRepresentable`. Show "Select a file" placeholder when no file selected.
  - **Footer:** `HStack` with summary: "N files changed, +X -Y" computed from file list.

- [ ] **Step 2: Replace placeholder in PanelContentView**
  In `PanelContentView.swift`, replace the placeholder `Text("Git Diff — coming soon")` with the real `GitDiffPanelView` instantiation, following the MarkdownPanel pattern (cast `panel as? GitDiffPanel`, pass required params).

- [ ] **Step 3: Build and visually verify**
  Run: `./scripts/reload.sh --tag fix-blank-terminal --launch`
  Test: Need to wire up opening mechanism first (Task 3.5).

- [ ] **Step 4: Commit**
  `git add Sources/Panels/GitDiffPanelView.swift Sources/Panels/PanelContentView.swift && git commit -m "feat: GitDiffPanelView with file list and colored diff"`

### Task 3.5: Wire panel creation in Workspace

**Files:**
- Modify: `Sources/Workspace.swift` (after line 10440)

- [ ] **Step 1: Add `newGitDiffSurface()` method**
  Follow `newMarkdownSurface()` pattern (lines 10408-10440):
  - Signature: `func newGitDiffSurface(inPane paneId: PaneID, repoPath: String? = nil, focus: Bool? = nil) -> GitDiffPanel?`
  - If `repoPath` is nil, detect from focused terminal's working directory or fall back to `SharedGitCache` repo root detection
  - Create `GitDiffPanel` instance
  - Register in `panels[panel.id]`
  - Create bonsplit tab (need to add `SurfaceKind.gitDiff` — check where `SurfaceKind` is defined)
  - Register `surfaceIdToPanelId` mapping
  - Handle focus

- [ ] **Step 2: Add to `createPanel(from:)` for session restoration**
  In the switch statement (lines 694-773), add `case .gitDiff:` that calls `newGitDiffSurface()`. Define `SessionGitDiffSnapshot` struct for persistence if needed, or skip persistence for v1 (panel recreated fresh on restore).

- [ ] **Step 3: Add keyboard shortcut**
  In `Sources/KeyboardShortcutSettings.swift`, add `case openGitDiff` to the Action enum (after existing navigation actions). Default shortcut: `Cmd+Shift+G`. Add label localization. Wire the action to call `workspace.newGitDiffSurface()` wherever keyboard shortcuts are dispatched.

- [ ] **Step 4: Add socket command**
  In `Sources/TerminalController.swift`, add handler for `panel.git-diff` command. Parse optional `--mode` and `--repo` arguments. Call `workspace.newGitDiffSurface()`.

- [ ] **Step 5: Build, launch, and test all 4 modes**
  Run: `./scripts/reload.sh --tag fix-blank-terminal --launch`
  Test working tree: modify a file, open git diff panel, verify file appears with colored diff.
  Test staged: `git add` a file, switch to staged mode, verify it shows.
  Test commit compare: select two commits, verify diff between them.
  Test branch compare: select two branches, verify diff.
  Test auto-refresh: modify a file while panel is open, verify file list updates.

- [ ] **Step 6: Commit**
  `git add Sources/Workspace.swift Sources/KeyboardShortcutSettings.swift Sources/TerminalController.swift && git commit -m "feat: wire GitDiffPanel creation, shortcut Cmd+Shift+G, socket command"`

---

## Workstream 4: File Explorer Panel

### Task 4.1: Register panel type

**Files:**
- Modify: `Sources/Panels/Panel.swift:6-10`
- Modify: `Sources/Panels/PanelContentView.swift`

- [ ] **Step 1: Add enum case**
  In `PanelType` enum, add `case fileExplorer` after `case gitDiff`.

- [ ] **Step 2: Add placeholder view route**
  In `PanelContentView` body switch, add `case .fileExplorer:` with placeholder `Text("File Explorer — coming soon")`.

- [ ] **Step 3: Verify build**

- [ ] **Step 4: Commit**
  `git add Sources/Panels/Panel.swift Sources/Panels/PanelContentView.swift && git commit -m "feat(panels): register fileExplorer panel type"`

### Task 4.2: SyntaxHighlighter

**Files:**
- Create: `Sources/Panels/SyntaxHighlighter.swift`

- [ ] **Step 1: Define language detection**
  `enum CodeLanguage` with cases: `swift, typescript, javascript, python, rust, zig, json, yaml, markdown, shell, c, cpp, go, html, css, toml, sql, unknown`.
  `static func detect(from extension: String) -> CodeLanguage` — maps file extensions to languages.

- [ ] **Step 2: Define highlighting rules**
  Per-language struct `HighlightRules` containing arrays of `(pattern: String, category: TokenCategory)` where `TokenCategory` is an enum: `.keyword, .string, .comment, .number, .type, .operator`.
  
  Each language provides its keyword list and comment/string delimiters. Keep it simple:
  - Keywords: exact word match (`\b(let|var|func|class|...)\b`)
  - Strings: `"[^"]*"`, `'[^']*'`
  - Comments: `//.*$`, `/\*[\s\S]*?\*/`, `#.*$`
  - Numbers: `\b\d+\.?\d*\b`
  - Types: `\b[A-Z][a-zA-Z0-9]+\b` (PascalCase heuristic)

- [ ] **Step 3: Implement highlighting function**
  `static func highlight(_ text: String, language: CodeLanguage, theme: SyntaxTheme) -> NSAttributedString`
  - Base: monospaced font (SF Mono or Menlo), default foreground
  - Apply regex matches in order: comments last (override strings inside comments)
  - `SyntaxTheme` struct with colors for each `TokenCategory`, with dark/light variants
  - Debounce-friendly: caller is responsible for debouncing, this function is pure

- [ ] **Step 4: Verify build**

- [ ] **Step 5: Commit**
  `git add Sources/Panels/SyntaxHighlighter.swift && git commit -m "feat: regex-based syntax highlighter for 17 languages"`

### Task 4.3: CodeEditorView

**Files:**
- Create: `Sources/Panels/CodeEditorView.swift`

- [ ] **Step 1: Build NSViewRepresentable wrapper**
  `struct CodeEditorView: NSViewRepresentable` with:
  - `@Binding var content: String`
  - `let isEditing: Bool`
  - `let language: CodeLanguage`
  - `let onSave: (() -> Void)?`
  
  `makeNSView`: create `NSScrollView` containing `NSTextView`. Configure:
  - Monospaced font (SF Mono 13pt or Menlo fallback)
  - `isEditable` bound to `isEditing`
  - `NSRulerView` for line numbers (set `hasVerticalRuler = true`, `rulersVisible = true`)
  - Background color matching zmux theme

- [ ] **Step 2: Implement Coordinator**
  `NSTextViewDelegate` coordinator handles:
  - `textDidChange`: update binding, schedule re-highlight (debounce 150ms via `DispatchWorkItem`)
  - Cmd+S interception: override `performKeyEquivalent` or use `NSEvent.addLocalMonitorForEvents` — call `onSave` closure
  - Undo/redo: `NSTextView` provides this natively via `NSUndoManager`

- [ ] **Step 3: Implement line number ruler**
  Subclass `NSRulerView` to draw line numbers. Override `drawHashMarksAndLabels(in:)`. Calculate line positions from `NSLayoutManager.lineFragmentRect(forGlyphAt:effectiveRange:)`. Right-align numbers, draw with dimmed color.

- [ ] **Step 4: Implement syntax re-highlighting**
  On text change (debounced 150ms): call `SyntaxHighlighter.highlight()`, apply resulting attributes to `NSTextStorage` without resetting cursor position. Use `textStorage.beginEditing()`/`endEditing()` for performance.

- [ ] **Step 5: Verify build**

- [ ] **Step 6: Commit**
  `git add Sources/Panels/CodeEditorView.swift && git commit -m "feat: CodeEditorView NSTextView wrapper with line numbers and syntax highlighting"`

### Task 4.4: FileExplorerPanel model

**Files:**
- Create: `Sources/Panels/FileExplorerPanel.swift`

- [ ] **Step 1: Define the model**
  `@MainActor final class FileExplorerPanel: Panel, ObservableObject` with:
  - `let id: UUID`, `let panelType: PanelType = .fileExplorer`
  - `@Published var rootPath: String`
  - `@Published var fileTree: [FileNode]` (struct: `name, path, isDirectory, extension, gitStatus, children: [FileNode]?`)
  - `@Published var expandedDirs: Set<String>`
  - `@Published var selectedFile: String?`
  - `@Published var fileContent: String`
  - `@Published var isEditing: Bool`
  - `@Published var isDirty: Bool`
  - `@Published var showHiddenFiles: Bool`
  - `@Published var filterQuery: String`
  - `var displayTitle: String` (root dir name)
  - `var displayIcon: String? { "folder" }`
  - Private: `workspaceId: UUID`, cache, watchers

- [ ] **Step 2: Implement lazy directory loading**
  `func loadDirectory(_ path: String) -> [FileNode]`:
  - `FileManager.default.contentsOfDirectory(at:includingPropertiesForKeys:options:)`
  - Sort: directories first, then files, case-insensitive alphabetical
  - Filter `.gitignore` entries (basic parsing: read `.gitignore` from repo root, match patterns)
  - Filter hidden files based on `showHiddenFiles` toggle
  - Set `children = nil` for directories (lazy — loaded on expand)
  - Apply git status from `SharedGitCache`

- [ ] **Step 3: Implement file content loading and saving**
  `func openFile(_ path: String)`:
  - Guard: file size < 1MB (warn via published property if larger)
  - Guard: not binary (check first 8KB for null bytes)
  - Read with `String(contentsOfFile:encoding:)`, try UTF-8 then ISO-Latin1
  - Set `fileContent`, `selectedFile`, `isEditing = false`, `isDirty = false`
  - Start DispatchSource watcher on file (pattern from MarkdownPanel:106-149)

  `func saveFile()`:
  - `fileContent.data(using: .utf8)?.write(to: url, options: .atomic)`
  - Set `isDirty = false`

- [ ] **Step 4: Implement directory cache**
  Internal `dirCache: [String: (nodes: [FileNode], modDate: Date)]` with 5s TTL.
  One `DispatchSourceFileSystemObject` per expanded directory. On FS change: invalidate cache entry, reload, publish update.
  Max watchers: limit to expanded dirs only. On collapse: remove watcher.
  File content cache: LRU, max 20 entries, max 500KB each.

- [ ] **Step 5: Wire to SharedGitCache**
  Register for git index changes. On callback: refresh `gitStatus` on all visible `FileNode`s without reloading directory structure.

- [ ] **Step 6: Verify build**

- [ ] **Step 7: Commit**
  `git add Sources/Panels/FileExplorerPanel.swift && git commit -m "feat: FileExplorerPanel model with lazy loading, edit/save, caching"`

### Task 4.5: FileExplorerPanelView

**Files:**
- Create: `Sources/Panels/FileExplorerPanelView.swift`
- Modify: `Sources/Panels/PanelContentView.swift` (replace placeholder)

- [ ] **Step 1: Build the tree sidebar**
  Recursive `FileNodeRow` view:
  - Disclosure triangle for directories (bound to `expandedDirs`)
  - On expand: call `panel.loadDirectory(node.path)`, add to `expandedDirs`
  - SF Symbol per file type: detect from extension (`.swift` → `swift`, `.ts` → `t.square`, default `doc`)
  - Git status color on filename (modified=orange, added=green, untracked=gray, deleted=red)
  - Selection highlight on tap → calls `panel.openFile(node.path)`
  - Filter text field at top: filters visible nodes by name substring

  **IMPORTANT:** Follow snapshot boundary rule from CLAUDE.md pitfalls. `FileNodeRow` must receive immutable value snapshots only — no `@ObservedObject`, `@EnvironmentObject`, or store references. Pass `FileNode` value + closure bundle for actions.

- [ ] **Step 2: Build the content area**
  Right side of `HSplitView`:
  - Header: file path breadcrumb + Edit/Save toggle button
  - When `isEditing == false`: `CodeEditorView(content: .constant(panel.fileContent), isEditing: false, language: detected)`
  - When `isEditing == true`: `CodeEditorView(content: $panel.fileContent, isEditing: true, language: detected, onSave: panel.saveFile)`
  - Empty state: "Select a file" centered text when no file selected
  - Binary file state: "Binary file — no preview" message
  - Large file state: "File > 1MB" with "Open anyway" button

- [ ] **Step 3: Build the footer**
  `HStack`: language label, encoding (UTF-8), line ending (LF/CRLF), line count, dirty indicator (orange dot if `isDirty`).

- [ ] **Step 4: Replace placeholder in PanelContentView**
  Cast `panel as? FileExplorerPanel`, instantiate `FileExplorerPanelView` with required params.

- [ ] **Step 5: Build and visually verify**
  Run: `./scripts/reload.sh --tag fix-blank-terminal --launch`
  (Needs Task 4.6 for opening mechanism)

- [ ] **Step 6: Commit**
  `git add Sources/Panels/FileExplorerPanelView.swift Sources/Panels/PanelContentView.swift && git commit -m "feat: FileExplorerPanelView with tree sidebar, code preview, inline editing"`

### Task 4.6: Wire panel creation in Workspace

**Files:**
- Modify: `Sources/Workspace.swift`
- Modify: `Sources/KeyboardShortcutSettings.swift`
- Modify: `Sources/TerminalController.swift`

- [ ] **Step 1: Add `newFileExplorerSurface()` method**
  Follow `newMarkdownSurface()` pattern:
  - Signature: `func newFileExplorerSurface(inPane paneId: PaneID, rootPath: String? = nil, filePath: String? = nil, focus: Bool? = nil) -> FileExplorerPanel?`
  - If `rootPath` is nil, detect from focused terminal's working directory
  - Create panel, register, create tab, map IDs
  - If `filePath` provided, call `panel.openFile(filePath)` after creation

- [ ] **Step 2: Add session restoration case**
  In `createPanel(from:)` switch, add `case .fileExplorer:` with `SessionFileExplorerSnapshot` (stores `rootPath`). Optionally skip for v1.

- [ ] **Step 3: Add keyboard shortcut**
  In `KeyboardShortcutSettings.swift`, add `case openFileExplorer`. Default: `Cmd+Shift+E`. Wire to `workspace.newFileExplorerSurface()`.

- [ ] **Step 4: Add socket command**
  Add `panel.file-explorer` command handler. Parse `--root` and `--file` and `--edit` flags.

- [ ] **Step 5: Wire cross-panel navigation**
  In `GitDiffPanelView`, when user clicks a filename in the file list: check if a FileExplorerPanel exists in the same workspace. If yes, navigate to that file. If no, create one via `newFileExplorerSurface(filePath:)`.

- [ ] **Step 6: Full integration test**
  Run: `./scripts/reload.sh --tag fix-blank-terminal --launch`
  Test: Open file explorer, navigate tree, open a .swift file, verify syntax highlighting.
  Test: Toggle edit mode, modify text, Cmd+S, verify file saved.
  Test: Modify file externally, verify auto-reload.
  Test: Open git diff panel, click a file, verify it opens in file explorer.
  Test: Large file warning (find a >1MB file or create one).
  Test: Binary file detection.

- [ ] **Step 7: Commit**
  `git add Sources/Workspace.swift Sources/KeyboardShortcutSettings.swift Sources/TerminalController.swift Sources/Panels/GitDiffPanelView.swift && git commit -m "feat: wire FileExplorerPanel creation, shortcut Cmd+Shift+E, cross-panel navigation"`

---

## Localization

All new user-facing strings must use `String(localized:defaultValue:)`. Key areas:
- Panel display titles and icons
- Settings UI labels for blocklist
- Mode labels in GitDiffPanelView (Working Tree, Staged, Commit Compare, Branch Compare)
- File explorer status labels (Binary file, Large file, etc.)
- Keyboard shortcut labels

Add entries to `Resources/Localizable.xcstrings` for English and Japanese.

---

## Verification Checklist (end-to-end)

- [ ] Single-pane workspace terminal renders immediately on creation
- [ ] Notification blocklist: adding "test-source" blocks notifications with that source
- [ ] Notification blocklist: content pattern "claude-mem" blocks matching notifications
- [ ] Git diff working tree mode shows modified files with colored diff
- [ ] Git diff staged mode shows only staged changes
- [ ] Git diff commit compare shows diff between two selected commits
- [ ] Git diff branch compare shows diff between two selected branches
- [ ] Git diff auto-refreshes when files change
- [ ] File explorer shows directory tree with git status colors
- [ ] File explorer opens files with syntax highlighting
- [ ] File explorer edit mode + Cmd+S saves correctly
- [ ] File explorer detects binary files and large files
- [ ] Cross-panel: clicking file in git diff opens in file explorer
- [ ] Keyboard shortcuts work: Cmd+Shift+G (git diff), Cmd+Shift+E (file explorer)
- [ ] Socket commands work: `panel.git-diff`, `panel.file-explorer`
- [ ] All strings localized (English + Japanese)
- [ ] No typing latency regression (avoid work in hot paths per CLAUDE.md pitfalls)
- [ ] Snapshot boundary rule respected in all LazyVStack/ForEach rows
