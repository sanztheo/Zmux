---
name: zmux-browser
description: End-user browser automation with zmux. Use when you need to open sites, interact with pages, wait for state changes, and extract data from zmux browser surfaces.
---

# Browser Automation with zmux

Use this skill for browser tasks inside zmux webviews.

## Core Workflow

1. Open or target a browser surface.
2. Verify navigation with `get url` before waiting or snapshotting.
3. Snapshot (`--interactive`) to get fresh element refs.
4. Act with refs (`click`, `fill`, `type`, `select`, `press`).
5. Wait for state changes.
6. Re-snapshot after DOM/navigation changes.

```bash
zmux --json browser open https://example.com
# use returned surface ref, for example: surface:7

zmux browser surface:7 get url
zmux browser surface:7 wait --load-state complete --timeout-ms 15000
zmux browser surface:7 snapshot --interactive
zmux browser surface:7 fill e1 "hello"
zmux --json browser surface:7 click e2 --snapshot-after
zmux browser surface:7 snapshot --interactive
```

## Surface Targeting

```bash
# identify current context
zmux identify --json

# open routed to a specific topology target
zmux browser open https://example.com --workspace workspace:2 --window window:1 --json
```

Notes:
- CLI output defaults to short refs (`surface:N`, `pane:N`, `workspace:N`, `window:N`).
- UUIDs are still accepted on input; only request UUID output when needed (`--id-format uuids|both`).
- Keep using one `surface:N` per task unless you intentionally switch.

## Wait Support

zmux supports wait patterns similar to agent-browser:

```bash
zmux browser <surface> wait --selector "#ready" --timeout-ms 10000
zmux browser <surface> wait --text "Success" --timeout-ms 10000
zmux browser <surface> wait --url-contains "/dashboard" --timeout-ms 10000
zmux browser <surface> wait --load-state complete --timeout-ms 15000
zmux browser <surface> wait --function "document.readyState === 'complete'" --timeout-ms 10000
```

## Common Flows

### Form Submit

```bash
zmux --json browser open https://example.com/signup
zmux browser surface:7 get url
zmux browser surface:7 wait --load-state complete --timeout-ms 15000
zmux browser surface:7 snapshot --interactive
zmux browser surface:7 fill e1 "Jane Doe"
zmux browser surface:7 fill e2 "jane@example.com"
zmux --json browser surface:7 click e3 --snapshot-after
zmux browser surface:7 wait --url-contains "/welcome" --timeout-ms 15000
zmux browser surface:7 snapshot --interactive
```

### Clear an Input

```bash
zmux browser surface:7 fill e11 "" --snapshot-after --json
zmux browser surface:7 get value e11 --json
```

### Stable Agent Loop (Recommended)

```bash
# navigate -> verify -> wait -> snapshot -> action -> snapshot
zmux browser surface:7 get url
zmux browser surface:7 wait --load-state complete --timeout-ms 15000
zmux browser surface:7 snapshot --interactive
zmux --json browser surface:7 click e5 --snapshot-after
zmux browser surface:7 snapshot --interactive
```

If `get url` is empty or `about:blank`, navigate first instead of waiting on load state.

## Deep-Dive References

| Reference | When to Use |
|-----------|-------------|
| [references/commands.md](references/commands.md) | Full browser command mapping and quick syntax |
| [references/snapshot-refs.md](references/snapshot-refs.md) | Ref lifecycle and stale-ref troubleshooting |
| [references/authentication.md](references/authentication.md) | Login/OAuth/2FA patterns and state save/load |
| [references/authentication.md#saving-authentication-state](references/authentication.md#saving-authentication-state) | Save authenticated state right after login |
| [references/session-management.md](references/session-management.md) | Multi-surface isolation and state persistence patterns |
| [references/video-recording.md](references/video-recording.md) | Current recording status and practical alternatives |
| [references/proxy-support.md](references/proxy-support.md) | Proxy behavior in WKWebView and workarounds |

## Ready-to-Use Templates

| Template | Description |
|----------|-------------|
| [templates/form-automation.sh](templates/form-automation.sh) | Snapshot/ref form fill loop |
| [templates/authenticated-session.sh](templates/authenticated-session.sh) | Login once, save/load state |
| [templates/capture-workflow.sh](templates/capture-workflow.sh) | Navigate + capture snapshots/screenshots |

## Limits (WKWebView)

These commands currently return `not_supported` because they rely on Chrome/CDP-only APIs not exposed by WKWebView:
- viewport emulation
- offline emulation
- trace/screencast recording
- network route interception/mocking
- low-level raw input injection

Use supported high-level commands (`click`, `fill`, `press`, `scroll`, `wait`, `snapshot`) instead.

## Troubleshooting

### `js_error` on `snapshot --interactive` or `eval`

Some complex pages can reject or break the JavaScript used for rich snapshots and ad-hoc evaluation.

Recovery steps:

```bash
zmux browser surface:7 get url
zmux browser surface:7 get text body
zmux browser surface:7 get html body
```

- Use `get url` first so you know whether the page actually navigated.
- Fall back to `get text body` or `get html body` when `snapshot --interactive` or `eval` returns `js_error`.
- If the page is still failing, navigate to a simpler intermediate page, then retry the task from there.
