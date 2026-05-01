# Zmux Roadmap: panels, docs/plans et notifications

**Date:** 2026-04-28
**Last updated:** 2026-05-01
**Produit:** Zmux — une version inspirée de Cmux, améliorée pour les agents de code avec Ghostty, panneaux natifs, notifications et contexte projet.
**Priority order:** Bug fix → Notifications → Git Diff → ~~File Explorer~~ ✅

## Statut

- ✅ **File Explorer Panel — terminé (2026-05-01)**
- ⏳ Bug terminal noir (single-pane)
- ⏳ Notification Blocklist
- ⏳ Git Diff Panel

---

## Roadmap produit

- **Explorateur de fichier** — déjà présent dans la barre latérale droite pour naviguer dans le workspace courant.
- **Viewer Git diff** — panel prévu pour inspecter les diffs du working tree, de l'index, des branches et des commits sans quitter Zmux.
- **Docs/plans** — organiser les spécifications et plans de design dans `docs/plans` pour garder la roadmap produit lisible.

---

## Design: Git Diff Panel, File Explorer Panel, Notification Blocklist & Terminal Fix

## 1. Bug: Terminal noir (surface Ghostty ne rend pas en solo)

### Symptome

Workspace avec un seul terminal, pas d'autre tab/split. Surface complètement noire, rien ne s'affiche. Fonctionne dès qu'un second tab est ajouté.

### Causes connues upstream

- **Ghostty #11704 (fix PR #11736, merged 1.4.0):** `RenderState` init met fg ET bg à noir (0,0,0). Texte invisible pour les consumers libghostty qui ne set pas les couleurs explicitement.
- **zmux #445:** Terminal blank avec curseur seul après lancement. Fresh workspace.
- **zmux #1789 (fix PR #1964):** `CVDisplayLink` stall quand workspace backgrounded. Workaround: `zmux refresh-surfaces`.

### Plan d'investigation

1. Vérifier version submodule ghostty — contient-il le fix #11736 ?
2. Si non → update submodule, tester
3. Si oui → investiguer chemin de focus initial dans `BonsplitController` pour le cas single-pane/single-tab
4. Vérifier `isVisibleInUI` dans `PanelContentView` au premier rendu
5. Vérifier que `forceRefresh()` fire quand workspace créé avec un seul terminal
6. Tester `zmux refresh-surfaces` comme workaround temporaire

### Fix probable

Garantir que le premier terminal d'un workspace reçoit focus + signal de visibilité même sans compétition de tabs. Soit dans `Workspace.createPanel()`, soit dans `onAppear` de `WorkspaceContentView`.

---

## 2. Notification Blocklist

### Probleme

Plugins (claude-mem, etc.) spamment des notifications vides ou inutiles. Aucun champ `source` n'existe dans `TerminalNotification` — impossible de filtrer par plugin.

### Design

#### Etape 1: Ajouter champ `source` au systeme

**TerminalNotification struct** — nouveau champ:
```swift
struct TerminalNotification: Identifiable, Hashable {
    let id: UUID
    let tabId: UUID
    let surfaceId: UUID?
    let title: String
    let subtitle: String
    let body: String
    let source: String?          // NEW — plugin/hook identifier, nil = unknown
    let createdAt: Date
    var isRead: Bool
}
```

**addNotification() signature** — nouveau parametre:
```swift
func addNotification(
    tabId: UUID,
    surfaceId: UUID?,
    title: String,
    subtitle: String,
    body: String,
    source: String? = nil,       // NEW
    cooldownKey: String? = nil,
    cooldownInterval: TimeInterval? = nil
)
```

**V2 API** — nouveau parametre optionnel dans `v2NotificationCreate*`:
```swift
// params["source"] as? String → passed to addNotification
```

#### Etape 2: Blocklist filtering

**Settings storage:**
```swift
struct NotificationBlocklistSettings {
    static let key = "notification.blocklist.sources"
    static var blockedSources: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    
    static let contentPatternsKey = "notification.blocklist.patterns"
    static var blockedContentPatterns: [String] {
        get { UserDefaults.standard.stringArray(forKey: contentPatternsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: contentPatternsKey) }
    }
}
```

**Interception point** dans `addNotification()`:
```swift
// Source-based blocking
if let source = source,
   NotificationBlocklistSettings.blockedSources.contains(source) {
    return // silently drop
}

// Fallback: content pattern blocking (for plugins that don't identify themselves)
let contentToCheck = "\(title) \(subtitle) \(body)"
for pattern in NotificationBlocklistSettings.blockedContentPatterns {
    if contentToCheck.localizedCaseInsensitiveContains(pattern) {
        return // silently drop
    }
}
```

#### Etape 3: Settings UI

Dans Settings → Notifications:
- Section "Blocked Sources" — liste editable de strings (add/remove)
- Section "Blocked Content Patterns" — liste editable de substrings (fallback)
- Defaults pre-remplis: `["claude-mem", "mcp-search"]` pour les content patterns

#### Cache

- Blocked sources set cached en `Set<String>` au lieu de re-lire `UserDefaults` par notification
- Invalidation sur `UserDefaults.didChangeNotification` pour la cle blocklist
- Content patterns pre-compiles en `[String]` lowercase pour comparaison rapide

### Fichiers modifies

- `Sources/TerminalNotificationStore.swift` — struct + addNotification + filtering
- `Sources/TerminalController.swift` — V2 commands passent `source` param
- `Sources/GhosttyTerminalView.swift` — OSC handler passe `source: "osc"`
- `Sources/zmuxApp.swift` — settings UI section

---

## 3. Git Diff Panel

### Nouveau type de panel: `.gitDiff`

#### Modele: `GitDiffPanel`

```swift
class GitDiffPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .gitDiff
    
    @Published var mode: DiffMode = .workingTree
    @Published var repoPath: String
    @Published var files: [DiffFile] = []
    @Published var selectedFile: DiffFile?
    @Published var diffContent: NSAttributedString?
    @Published var isLoading: Bool = false
    
    // Branch/commit compare mode
    @Published var fromRef: String = "HEAD"
    @Published var toRef: String = ""
    @Published var availableBranches: [String] = []
    @Published var recentCommits: [GitCommit] = []
}

enum DiffMode: String, CaseIterable {
    case workingTree    // git diff + git diff --staged
    case staged         // git diff --staged
    case commitCompare  // git diff <sha1> <sha2>
    case branchCompare  // git diff <branch1>...<branch2>
}

struct DiffFile: Identifiable, Hashable {
    let id: String          // file path
    let path: String
    let status: GitFileStatus  // .modified, .added, .deleted, .renamed
    let insertions: Int
    let deletions: Int
}

struct GitCommit: Identifiable {
    let id: String          // SHA
    let shortSha: String
    let message: String
    let date: Date
    let author: String
}
```

#### Vue: `GitDiffPanelView`

```
┌─────────────────────────────────────────────────────┐
│ [Working Tree ▾] [main ▾] [...] [⟳ Refresh]        │  ← Header: mode selector + refs
├────────────────┬────────────────────────────────────┤
│ M file1.swift  │ @@ -10,6 +10,8 @@                 │
│ A file2.swift  │   existing line                    │
│ D file3.swift  │ + added line (green)               │
│ R old→new.ts   │ - removed line (red)               │
│                │   context line (gray)              │
│                │ @@ -25,3 +27,4 @@ (blue)          │
│                │   ...                              │
├────────────────┴────────────────────────────────────┤
│ 3 files changed, +12 -5                             │  ← Footer: summary
└─────────────────────────────────────────────────────┘
```

**Layout:** `HSplitView` — fichiers a gauche (200pt fixed width), diff a droite (flexible).

#### Git commands

| Action | Command |
|--------|---------|
| Liste fichiers (working tree) | `git diff --name-status` + `git diff --staged --name-status` |
| Liste fichiers (staged) | `git diff --staged --name-status` |
| Liste fichiers (compare) | `git diff --name-status <ref1> <ref2>` |
| Diff d'un fichier | `git diff -- <file>` (ou `--staged`, ou `<ref1> <ref2> -- <file>`) |
| Stats | `git diff --stat` |
| Branches | `git branch -a --format='%(refname:short)'` |
| Commits | `git log --oneline --format='%H|%h|%s|%aI|%an' -50` |
| Repo root | `git rev-parse --show-toplevel` |

#### Diff rendering

`NSTextView` read-only avec `NSAttributedString`:
- `+` lignes → fond vert pale, texte vert fonce
- `-` lignes → fond rouge pale, texte rouge fonce
- `@@` headers → texte bleu, font bold
- Contexte → texte default
- Numeros de ligne → colonne gutter gauche via `NSRulerView`

#### Cache

```swift
class GitDiffCache {
    // File list cache — invalidated when .git/index changes
    private var fileListCache: [DiffMode: (files: [DiffFile], timestamp: Date)] = [:]
    private let fileListTTL: TimeInterval = 2.0  // 2s for working tree
    
    // Diff content cache — keyed by (mode, file, fromRef, toRef)
    private var diffCache: [String: (content: NSAttributedString, timestamp: Date)] = [:]
    private let diffTTL: TimeInterval = 5.0  // 5s per file diff
    
    // Branch/commit list cache — changes less frequently
    private var branchCache: (branches: [String], timestamp: Date)?
    private let branchTTL: TimeInterval = 30.0
    
    private var commitCache: (commits: [GitCommit], timestamp: Date)?
    private let commitTTL: TimeInterval = 30.0
    
    // DispatchSource on .git/index — invalidates file list + diff caches
    private var gitIndexWatcher: DispatchSourceFileSystemObject?
    
    func invalidateAll() { /* clear all caches */ }
    func invalidateFileDiffs() { /* clear diff content only, keep file list */ }
}
```

**Invalidation strategy:**
- `DispatchSource` file watcher on `.git/index` → invalidate file list + diff caches
- TTL-based expiry as safety net
- Branch/commit lists cached longer (30s) — less volatile
- Manual refresh button clears everything

#### Auto-refresh

- `DispatchSource` watch `.git/index` pour detecter `git add`, `git commit`, etc.
- Debounce 500ms pour eviter refresh cascade
- Working tree mode: re-scan fichiers, re-diff fichier selectionne
- Compare modes: pas d'auto-refresh (refs sont stables)

#### Ouverture

- Bouton toolbar dans pane tab bar (icone `arrow.triangle.branch`)
- Raccourci clavier configurable via `KeyboardShortcutSettings`
- Commande socket: `panel.git-diff [--mode working-tree|staged|commit|branch] [--repo /path]`
- Detecte auto le git root depuis le cwd du terminal actif

#### Fichiers a creer

- `Sources/Panels/GitDiffPanel.swift` — modele + cache + git commands
- `Sources/Panels/GitDiffPanelView.swift` — vue SwiftUI

#### Fichiers a modifier

- `Sources/Panels/Panel.swift` — ajouter `.gitDiff` a `PanelType`
- `Sources/Panels/PanelContentView.swift` — route vers `GitDiffPanelView`
- `Sources/Workspace.swift` — `newGitDiffSurface()` creation method

---

## 4. File Explorer Panel ✅ TERMINÉ (2026-05-01)

> **État final:** panel implémenté, intégré au workspace, avec arbre de fichiers VSCode-style, éditeur de code (CodeEditSourceEditor), recherche, drag-and-drop AppKit (NSDraggingDestination + DragDropOverlayView), rename inline, opérations CRUD, raccourci "Open in Integrated Terminal", icônes Material, sélection right-click, et hidden files visibles par défaut. Voir `Sources/Panels/FileExplorer*.swift` + `CodeEditorView.swift` + `SyntaxHighlighter.swift` + `FileIndex.swift`.
>
> **Écarts vs design initial:**
> - Éditeur: `CodeEditSourceEditor` (SPM) au lieu d'un wrapper `NSTextView` custom — meilleur highlighting + features.
> - Drag-drop: `DragDropOverlayView` AppKit single-overlay (SwiftUI `.onDrop` cassé sur LazyVStack macOS, `.dropDestination` API peu fiable) — voir notes Apr 30.
> - Right-click selection: `RightClickCatcher` NSViewRepresentable + `isContextMenuTarget` flag (FileNodeRow ne peut pas se self-select depuis parent flattenedNodes).
> - Sidebar mode: enum `FileExplorerSidebarMode` ajouté pour toggle VSCode-style tab bar + section header + collapseAll + drag-drop moveItems.
> - RenameField: auto-focus async + outside-click via `NSEvent.addLocalMonitorForEvents` (régressions focus-stealing résolues).

### Nouveau type de panel: `.fileExplorer`

#### Modele: `FileExplorerPanel`

```swift
class FileExplorerPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .fileExplorer
    
    @Published var rootPath: String
    @Published var selectedFile: String?
    @Published var isEditing: Bool = false
    @Published var isDirty: Bool = false
    @Published var expandedDirs: Set<String> = []
    @Published var fileTree: [FileNode] = []
    @Published var fileContent: String = ""
    @Published var showHiddenFiles: Bool = false
}

struct FileNode: Identifiable, Hashable {
    let id: String              // absolute path
    let name: String
    let path: String
    let isDirectory: Bool
    let fileExtension: String?
    let gitStatus: GitFileStatus?
    var children: [FileNode]?   // nil = not loaded, [] = empty dir
}
```

#### Vue: `FileExplorerPanelView`

```
┌─────────────────────────────────────────────────────┐
│ ~/Desktop/Zmux                        [👁 ⚙]        │  ← Header: root path + toggles
├────────────────┬────────────────────────────────────┤
│ 🔍 Filter...   │ Sources/Panels/Panel.swift    [✏️]  │  ← Search + file header + edit btn
├────────────────┤────────────────────────────────────┤
│ ▼ Sources/     │  1 │ import Foundation           │
│   ▼ Panels/    │  2 │ import SwiftUI              │
│     Panel.swi… │  3 │                             │
│     GitDiff…   │  4 │ protocol Panel {            │
│     Browser…   │  5 │     var id: UUID { get }    │
│   ▶ App/       │  6 │     var panelType: ...      │
│ ▶ Packages/    │  7 │ }                           │
│ ▶ vendor/      │  ...                              │
│   .gitignore   │                                    │
├────────────────┴────────────────────────────────────┤
│ Swift │ UTF-8 │ LF │ 311 lines │ ● Modified        │  ← Footer: file info
└─────────────────────────────────────────────────────┘
```

**Layout:** `HSplitView` — arbre a gauche (220pt, resizable), editeur a droite.

#### Arbre de fichiers

- **Chargement lazy** — `FileManager.contentsOfDirectory()` seulement quand dossier expand
- **Tri:** dossiers first, puis fichiers, alphabetique case-insensitive
- **Icones:** SF Symbols par extension (`.swift` → `swift`, `.ts` → `t.square`, `.py` → `p.square`, defaut `doc`)
- **Git status:** couleurs via `GitStatusProvider` existant (reuse `FileExplorerStore`)
- **`.gitignore` aware:** parse `.gitignore` basique, fichiers ignores en gris ou masques
- **Fichiers caches:** toggle dans header, off par defaut
- **Filtre rapide:** text field en haut, filtre par nom de fichier dans l'arbre visible

#### Editeur: `CodeEditorView`

`NSViewRepresentable` wrapping `NSTextView`:

```swift
struct CodeEditorView: NSViewRepresentable {
    @Binding var content: String
    @Binding var isEditing: Bool
    let language: CodeLanguage       // detected from extension
    let showLineNumbers: Bool
    let onSave: () -> Void
}
```

**Syntax highlighting:**
- Detection du langage par extension du fichier
- Patterns regex par langage dans `NSAttributedString`:
  - Keywords: `let`, `var`, `func`, `class`, `import`, `return`, etc.
  - Strings: `"..."`, `'...'`, `` `...` ``
  - Commentaires: `//`, `/* */`, `#`
  - Numbers: `\b\d+\.?\d*\b`
  - Types: `\b[A-Z][a-zA-Z0-9]+\b` (PascalCase heuristic)
- Couleurs adaptees au theme zmux (dark/light)
- Re-highlight apres chaque edit (debounce 100ms pour performance)

**Langages supportes au lancement:** Swift, TypeScript/JavaScript, Python, Rust, Zig, JSON, YAML, Markdown, Shell/Bash, C/C++, Go, HTML/CSS, TOML, SQL

**Features editeur:**
- `Cmd+S` → `data.write(to:url, options: .atomic)` + clear dirty flag
- `Cmd+Z` / `Cmd+Shift+Z` → undo/redo natif `NSUndoManager`
- `Cmd+F` → search dans le fichier (NSTextView find bar)
- Tab → insere 4 espaces (ou tab selon detection du fichier)
- Numeros de ligne via `NSRulerView`
- Indicateur dirty: point orange dans tab title (reuse `isDirty` protocol)

**Gardes:**
- Fichiers > 1 MB → dialog de confirmation avant ouverture
- Fichiers binaires (detection heuristique: null bytes dans les premiers 8KB) → message "Binary file"
- Fichiers read-only (permissions FS) → mode lecture force, badge 🔒

#### Cache

```swift
class FileExplorerCache {
    // Directory listing cache — keyed by path
    private var dirCache: [String: (nodes: [FileNode], modDate: Date)] = [:]
    private let dirTTL: TimeInterval = 5.0
    
    // File content cache — keyed by path, invalidated on file modification
    private var contentCache: [String: (content: String, modDate: Date)] = [:]
    private let contentMaxSize: Int = 512_000  // 500KB max cached per file
    private let contentMaxEntries: Int = 20    // LRU eviction
    
    // Git status cache — shared with GitDiffPanel
    private var gitStatusCache: (statuses: [String: GitFileStatus], timestamp: Date)?
    private let gitStatusTTL: TimeInterval = 3.0
    
    // DispatchSource watchers — one per expanded directory
    private var dirWatchers: [String: DispatchSourceFileSystemObject] = [:]
    
    // File content watcher — for currently open file
    private var fileWatcher: DispatchSourceFileSystemObject?
    
    func cacheDirectory(_ path: String, nodes: [FileNode]) { /* ... */ }
    func getCachedDirectory(_ path: String) -> [FileNode]? { /* check TTL + modDate */ }
    func invalidateDirectory(_ path: String) { /* remove + cascade children */ }
    func evictLRU() { /* remove oldest content entries when > maxEntries */ }
}
```

**Invalidation strategy:**
- `DispatchSource` per expanded directory → invalidate on file system changes
- `DispatchSource` on open file → reload content if changed externally
- LRU eviction on content cache (max 20 files, 500KB each)
- Git status: shared TTL with GitDiffPanel, invalidated by `.git/index` watcher
- Directory collapse → remove watcher + cache for that dir

#### Interaction avec Git Diff panel

- Clic sur un fichier dans Git Diff → ouvre File Explorer panel sur ce fichier
- Commande socket: `panel.file-explorer [--path /path/to/file] [--edit]`
- Git status partagé entre les deux panels via cache commun

#### Ouverture

- Bouton toolbar dans pane tab bar (icone `folder`)
- Raccourci clavier configurable via `KeyboardShortcutSettings`
- Commande socket: `panel.file-explorer [--root /path] [--file /path/to/file]`
- Detecte auto le git root depuis le cwd du terminal actif
- Depuis Git Diff panel: clic sur fichier → ouvre en File Explorer

#### Fichiers créés ✅

- ✅ `Sources/Panels/FileExplorerPanel.swift` — modèle + cache + sidebarMode + contextMenuPath + drag-drop moveItems
- ✅ `Sources/Panels/FileExplorerPanelView.swift` — vue SwiftUI (arbre + header + footer + tab bar VSCode-style)
- ✅ `Sources/Panels/CodeEditorView.swift` — wrapper `CodeEditSourceEditor` (pivot depuis NSTextView custom)
- ✅ `Sources/Panels/SyntaxHighlighter.swift` — patterns par langage (utilisé en complément CodeEdit)
- ✅ `Sources/Panels/FileIndex.swift` — recherche fichiers (FileSearchRow component)

#### Fichiers modifiés ✅

- ✅ `Sources/Panels/Panel.swift` — case `.fileExplorer` ajouté
- ✅ `Sources/Panels/PanelContentView.swift` — routing vers `FileExplorerPanelView`
- ✅ `Sources/Workspace.swift` — `newFileExplorerSurface()` + spawn terminal avec `workingDirectory` (Open in Integrated Terminal)
- ✅ `Resources/Localizable.xcstrings` — strings UI traduites

#### Bugs résolus pendant l'implémentation

- `EditorTheme.Attribute` type mismatch après upgrade CodeEditSourceEditor (NSColor incompatible) — fix Apr 30 6:11p
- `Cmd+Delete` / `Cmd+ForwardDelete` non interceptés par `CodeEditTextView.performKeyEquivalent` (NSView, pas NSTextView) — routé via `CodeEditorKeyMonitor`
- Right-click ne déclenchait pas le highlight bleu — `isContextMenuTarget` + `RightClickCatcher` overlay
- `RenameField` auto-focus async + commit-on-blur bugs — fix Apr 30 10:58p
- Drag-drop macOS LazyVStack cassé — pivot vers `DragDropOverlayView` AppKit single-overlay (3 itérations: per-row → single-overlay → hitTest conditional gating)

---

## 5. Cache partagé

Les deux panels partagent un cache git:

```swift
class SharedGitCache {
    static let shared = SharedGitCache()
    
    // Git status — used by both panels + existing FileExplorerStore
    private var statusCache: [String: (statuses: [String: GitFileStatus], timestamp: Date)] = [:]
    private let statusTTL: TimeInterval = 3.0
    
    // .git/index watcher — single watcher shared across consumers
    private var indexWatchers: [String: DispatchSourceFileSystemObject] = [:]  // keyed by repo root
    private var invalidationCallbacks: [String: [() -> Void]] = []
    
    func getStatus(for repoRoot: String) -> [String: GitFileStatus]?
    func refreshStatus(for repoRoot: String) async -> [String: GitFileStatus]
    func watchIndex(repoRoot: String, onChange: @escaping () -> Void) -> UUID  // returns registration ID
    func unwatchIndex(registrationId: UUID)
}
```

**Consumers:**
- `GitDiffPanel` — file list + diff highlighting
- `FileExplorerPanel` — tree node coloring
- `FileExplorerStore` (existant) — sidebar file search

---

## Resume des fichiers

### A creer (7 fichiers)
| Fichier | Responsabilite | Statut |
|---------|---------------|--------|
| `Sources/Panels/GitDiffPanel.swift` | Modele, cache diff, git commands | ⏳ |
| `Sources/Panels/GitDiffPanelView.swift` | Vue diff: header + file list + diff content | ⏳ |
| `Sources/Panels/FileExplorerPanel.swift` | Modele, cache FS, tree loading | ✅ |
| `Sources/Panels/FileExplorerPanelView.swift` | Vue: tree sidebar + file content area | ✅ |
| `Sources/Panels/CodeEditorView.swift` | Wrapper `CodeEditSourceEditor` | ✅ |
| `Sources/Panels/SyntaxHighlighter.swift` | Regex patterns par langage | ✅ |
| `Sources/Panels/FileIndex.swift` | Recherche fichiers (bonus) | ✅ |
| `Sources/SharedGitCache.swift` | Cache git status partage | ⏳ |

### A modifier (5 fichiers)
| Fichier | Modification | Statut |
|---------|-------------|--------|
| `Sources/Panels/Panel.swift` | +2 cases dans `PanelType` enum | ✅ `.fileExplorer` / ⏳ `.gitDiff` |
| `Sources/Panels/PanelContentView.swift` | +2 cases dans switch routing | ✅ `.fileExplorer` / ⏳ `.gitDiff` |
| `Sources/Workspace.swift` | +2 methodes creation panel | ✅ `newFileExplorerSurface` / ⏳ `newGitDiffSurface` |
| `Sources/TerminalNotificationStore.swift` | +champ source, +blocklist filtering | ⏳ |
| `Sources/TerminalController.swift` | +param source dans V2 commands | ⏳ |
| `Sources/zmuxApp.swift` | +section blocklist dans Settings UI | ⏳ |
