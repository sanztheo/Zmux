---
name: zmux
description: End-user control of zmux topology and routing (windows, workspaces, panes/surfaces, focus, moves, reorder, identify, trigger flash). Use when automation needs deterministic placement and navigation in a multi-pane zmux layout.
---

# zmux Core Control

Use this skill to control non-browser zmux topology and routing.

## Core Concepts

- Window: top-level macOS zmux window.
- Workspace: tab-like group within a window.
- Pane: split container in a workspace.
- Surface: a tab within a pane (terminal or browser panel).

## Fast Start

```bash
# identify current caller context
zmux identify --json

# list topology
zmux list-windows
zmux list-workspaces
zmux list-panes
zmux list-pane-surfaces --pane pane:1

# create/focus/move
zmux new-workspace
zmux new-split right --panel pane:1
zmux move-surface --surface surface:7 --pane pane:2 --focus true
zmux reorder-surface --surface surface:7 --before surface:3

# attention cue
zmux trigger-flash --surface surface:7
```

## Handle Model

- Default output uses short refs: `window:N`, `workspace:N`, `pane:N`, `surface:N`.
- UUIDs are still accepted as inputs.
- Request UUID output only when needed: `--id-format uuids|both`.

## Deep-Dive References

| Reference | When to Use |
|-----------|-------------|
| [references/handles-and-identify.md](references/handles-and-identify.md) | Handle syntax, self-identify, caller targeting |
| [references/windows-workspaces.md](references/windows-workspaces.md) | Window/workspace lifecycle and reorder/move |
| [references/panes-surfaces.md](references/panes-surfaces.md) | Splits, surfaces, move/reorder, focus routing |
| [references/trigger-flash-and-health.md](references/trigger-flash-and-health.md) | Flash cue and surface health checks |
| [../zmux-browser/SKILL.md](../zmux-browser/SKILL.md) | Browser automation on surface-backed webviews |
| [../zmux-markdown/SKILL.md](../zmux-markdown/SKILL.md) | Markdown viewer panel with live file watching |
