# Command Reference (zmux Browser)

This maps common `agent-browser` usage to `zmux browser` usage.

## Direct Equivalents

- `agent-browser open <url>` -> `zmux browser open <url>`
- `agent-browser goto|navigate <url>` -> `zmux browser <surface> goto|navigate <url>`
- `agent-browser snapshot -i` -> `zmux browser <surface> snapshot --interactive`
- `agent-browser click <ref>` -> `zmux browser <surface> click <ref>`
- `agent-browser fill <ref> <text>` -> `zmux browser <surface> fill <ref> <text>`
- `agent-browser type <ref> <text>` -> `zmux browser <surface> type <ref> <text>`
- `agent-browser select <ref> <value>` -> `zmux browser <surface> select <ref> <value>`
- `agent-browser get text <ref>` -> `zmux browser <surface> get text <ref-or-selector>`
- `agent-browser get url` -> `zmux browser <surface> get url`
- `agent-browser get title` -> `zmux browser <surface> get title`

## Core Command Groups

### Navigation

```bash
zmux browser open <url>                        # opens in caller's workspace (uses ZMUX_WORKSPACE_ID)
zmux browser open <url> --workspace <id|ref>   # opens in a specific workspace
zmux browser <surface> goto <url>
zmux browser <surface> back|forward|reload
zmux browser <surface> get url|title
```

> **Workspace context:** `browser open` targets the workspace of the terminal where the command is run (via `ZMUX_WORKSPACE_ID`), even if a different workspace is currently focused. Use `--workspace` to override.

### Snapshot and Inspection

```bash
zmux browser <surface> snapshot --interactive
zmux browser <surface> snapshot --interactive --compact --max-depth 3
zmux browser <surface> get text body
zmux browser <surface> get html body
zmux browser <surface> get value "#email"
zmux browser <surface> get attr "#email" --attr placeholder
zmux browser <surface> get count ".row"
zmux browser <surface> get box "#submit"
zmux browser <surface> get styles "#submit" --property color
zmux browser <surface> eval '<js>'
```

### Interaction

```bash
zmux browser <surface> click|dblclick|hover|focus <selector-or-ref>
zmux browser <surface> fill <selector-or-ref> [text]   # empty text clears
zmux browser <surface> type <selector-or-ref> <text>
zmux browser <surface> press|keydown|keyup <key>
zmux browser <surface> select <selector-or-ref> <value>
zmux browser <surface> check|uncheck <selector-or-ref>
zmux browser <surface> scroll [--selector <css>] [--dx <n>] [--dy <n>]
```

### Wait

```bash
zmux browser <surface> wait --selector "#ready" --timeout-ms 10000
zmux browser <surface> wait --text "Done" --timeout-ms 10000
zmux browser <surface> wait --url-contains "/dashboard" --timeout-ms 10000
zmux browser <surface> wait --load-state complete --timeout-ms 15000
zmux browser <surface> wait --function "document.readyState === 'complete'" --timeout-ms 10000
```

### Session/State

```bash
zmux browser <surface> cookies get|set|clear ...
zmux browser <surface> storage local|session get|set|clear ...
zmux browser <surface> tab list|new|switch|close ...
zmux browser <surface> state save|load <path>
```

### Diagnostics

```bash
zmux browser <surface> console list|clear
zmux browser <surface> errors list|clear
zmux browser <surface> highlight <selector>
zmux browser <surface> screenshot
zmux browser <surface> download wait --timeout-ms 10000
```

## Agent Reliability Tips

- Use `--snapshot-after` on mutating actions to return a fresh post-action snapshot.
- Re-snapshot after navigation, modal open/close, or major DOM changes.
- Prefer short handles in outputs by default (`surface:N`, `pane:N`, `workspace:N`, `window:N`).
- Use `--id-format both` only when a UUID must be logged/exported.

## Known WKWebView Gaps (`not_supported`)

- `browser.viewport.set`
- `browser.geolocation.set`
- `browser.offline.set`
- `browser.trace.start|stop`
- `browser.network.route|unroute|requests`
- `browser.screencast.start|stop`
- `browser.input_mouse|input_keyboard|input_touch`

See also:
- [snapshot-refs.md](snapshot-refs.md)
- [authentication.md](authentication.md)
- [session-management.md](session-management.md)
