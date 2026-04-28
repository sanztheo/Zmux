# Notifications

zmux provides a notification panel for AI agents like Claude Code, Codex, and OpenCode. Notifications appear in a dedicated panel and trigger macOS system notifications.

> For inline permission / plan / question approvals directly from the sidebar (Vibe Island-style), see **[Feed](feed.md)**. `zmux setup-hooks` installs the Feed bridge alongside the notification hooks covered below.

## Quick Start

```bash
# Send a notification (if zmux is available)
command -v zmux &>/dev/null && zmux notify --title "Done" --body "Task complete"

# With fallback to macOS notifications
command -v zmux &>/dev/null && zmux notify --title "Done" --body "Task complete" || osascript -e 'display notification "Task complete" with title "Done"'
```

## Detection

Check if `zmux` CLI is available before using it:

```bash
# Shell
if command -v zmux &>/dev/null; then
    zmux notify --title "Hello"
fi

# One-liner with fallback
command -v zmux &>/dev/null && zmux notify --title "Hello" || osascript -e 'display notification "" with title "Hello"'
```

```python
# Python
import shutil
import subprocess

def notify(title: str, body: str = ""):
    if shutil.which("zmux"):
        subprocess.run(["zmux", "notify", "--title", title, "--body", body])
    else:
        # Fallback to macOS
        subprocess.run(["osascript", "-e", f'display notification "{body}" with title "{title}"'])
```

## CLI Usage

```bash
# Simple notification
zmux notify --title "Build Complete"

# With subtitle and body
zmux notify --title "Claude Code" --subtitle "Permission" --body "Approval needed"

# Notify specific tab/panel
zmux notify --title "Done" --tab 0 --panel 1
```

## Integration Examples

### Claude Code

See the [Claude Code documentation](https://docs.anthropic.com/en/docs/claude-code) for hook configuration.

### GitHub Copilot CLI

Copilot CLI supports [hooks](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/coding-agent/use-hooks) that run shell commands at key lifecycle events. Add to `~/.copilot/config.json`:

```json
{
  "hooks": {
    "userPromptSubmitted": [
      {
        "type": "command",
        "bash": "if command -v zmux &>/dev/null; then zmux set-status copilot_cli Running; fi",
        "timeoutSec": 3
      }
    ],
    "agentStop": [
      {
        "type": "command",
        "bash": "if command -v zmux &>/dev/null; then zmux notify --title 'Copilot CLI' --body 'Done'; zmux set-status copilot_cli Idle; else osascript -e 'display notification \"Done\" with title \"Copilot CLI\"'; fi",
        "timeoutSec": 5
      }
    ],
    "errorOccurred": [
      {
        "type": "command",
        "bash": "if command -v zmux &>/dev/null; then zmux notify --title 'Copilot CLI' --subtitle 'Error' --body \"$(cat | jq -r '.errorMessage // \"An error occurred\"' 2>/dev/null | head -c 100)\"; zmux set-status copilot_cli Error; else osascript -e 'display notification \"An error occurred\" with title \"Copilot CLI\"'; fi",
        "timeoutSec": 5
      }
    ],
    "sessionEnd": [
      {
        "type": "command",
        "bash": "if command -v zmux &>/dev/null; then zmux clear-status copilot_cli; fi",
        "timeoutSec": 3
      }
    ]
  }
}
```

Or for repo-level hooks, create `.github/hooks/notify.json`:

```json
{
  "version": 1,
  "hooks": {
    "userPromptSubmitted": [ ... ],
    "agentStop": [ ... ]
  }
}
```

### OpenAI Codex

Add to `~/.codex/config.toml`:

```toml
notify = ["bash", "-c", "command -v zmux &>/dev/null && zmux notify --title Codex --body \"$(echo $1 | jq -r '.\"last-assistant-message\" // \"Turn complete\"' 2>/dev/null | head -c 100)\" || osascript -e 'display notification \"Turn complete\" with title \"Codex\"'", "--"]
```

Or create a simple script `~/.local/bin/codex-notify.sh`:

```bash
#!/bin/bash
MSG=$(echo "$1" | jq -r '."last-assistant-message" // "Turn complete"' 2>/dev/null | head -c 100)
command -v zmux &>/dev/null && zmux notify --title "Codex" --body "$MSG" || osascript -e "display notification \"$MSG\" with title \"Codex\""
```

Then use:
```toml
notify = ["bash", "~/.local/bin/codex-notify.sh"]
```

### OpenCode Plugin

Create `.opencode/plugins/zmux-notify.js`:

```javascript
export const ZmuxNotificationPlugin = async ({ $, }) => {
  const notify = async (title, body) => {
    try {
      await $`command -v zmux && zmux notify --title ${title} --body ${body}`;
    } catch {
      await $`osascript -e ${"display notification \"" + body + "\" with title \"" + title + "\""}`;
    }
  };

  return {
    event: async ({ event }) => {
      if (event.type === "session.idle") {
        await notify("OpenCode", "Session idle");
      }
    },
  };
};
```

## Environment Variables

zmux sets these in child shells:

| Variable | Description |
|----------|-------------|
| `ZMUX_SOCKET_PATH` | Path to control socket |
| `ZMUX_TAB_ID` | UUID of the current tab |
| `ZMUX_PANEL_ID` | UUID of the current panel |

## CLI Commands

```
zmux notify --title <text> [--subtitle <text>] [--body <text>] [--tab <id|index>] [--panel <id|index>]
zmux list-notifications
zmux clear-notifications
zmux set-status <key> <value>
zmux clear-status <key>
zmux ping
```

## Best Practices

1. **Always check availability first** - Use `command -v zmux` before calling
2. **Provide fallbacks** - Use `|| osascript` for macOS fallback
3. **Keep notifications concise** - Title should be brief, use body for details
