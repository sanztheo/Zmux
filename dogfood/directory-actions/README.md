# Directory Actions Dogfood

This tree is for dogfooding per-directory `zmux.json` resolution.

Use a terminal pane in zmux and `cd` into these directories:

- `dogfood/directory-actions/alpha`
- `dogfood/directory-actions/alpha/nested`
- `dogfood/directory-actions/legacy`
- `dogfood/directory-actions/legacy/prefer-dot-zmux`

What each one demonstrates:

- `alpha`
  - Inherits the ancestor `./.zmux/zmux.json`
  - Shows ancestor lookup from the active pane cwd
- `alpha/nested`
  - Has its own `./.zmux/zmux.json`
  - Overrides `zmux.newTerminal`
  - Replaces the surface tab bar button list
  - Still inherits parent actions into Command Palette
- `legacy`
  - Uses fallback `./zmux.json`
  - Demonstrates backward-compatible local config loading
- `legacy/prefer-dot-zmux`
  - Contains both `./zmux.json` and `./.zmux/zmux.json`
  - The `./.zmux/zmux.json` file should win

General expectations:

- Image-backed project-local icons start as a lock until that exact action is trusted.
- Emoji-backed project-local actions show their emoji immediately, but still prompt on first run.
- Running a trusted action opens a new terminal tab in the current pane and sends the configured shell input.
- Command Palette should update as the active pane cwd changes.
