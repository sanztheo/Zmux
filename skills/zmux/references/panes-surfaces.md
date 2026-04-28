# Panes and Surfaces

Split layout, surface creation, focus, move, and reorder.

## Inspect

```bash
zmux list-panes
zmux list-pane-surfaces --pane pane:1
```

## Create Splits/Surfaces

```bash
zmux new-split right --panel pane:1
zmux new-surface --type terminal --pane pane:1
zmux new-surface --type browser --pane pane:1 --url https://example.com
```

## Focus and Close

```bash
zmux focus-pane --pane pane:2
zmux focus-panel --panel surface:7
zmux close-surface --surface surface:7
```

## Move/Reorder Surfaces

```bash
zmux move-surface --surface surface:7 --pane pane:2 --focus true
zmux move-surface --surface surface:7 --workspace workspace:2 --window window:1 --after surface:4
zmux reorder-surface --surface surface:7 --before surface:3
```

Surface identity is stable across move/reorder operations.
