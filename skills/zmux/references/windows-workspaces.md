# Windows and Workspaces

Window/workspace lifecycle and ordering operations.

## Inspect

```bash
zmux list-windows
zmux current-window
zmux list-workspaces
zmux current-workspace
```

## Create/Focus/Close

```bash
zmux new-window
zmux focus-window --window window:2
zmux close-window --window window:2

zmux new-workspace
zmux select-workspace --workspace workspace:4
zmux close-workspace --workspace workspace:4
```

## Reorder and Move

```bash
zmux reorder-workspace --workspace workspace:4 --before workspace:2
zmux move-workspace-to-window --workspace workspace:4 --window window:1
```
