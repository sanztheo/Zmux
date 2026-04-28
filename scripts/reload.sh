#!/usr/bin/env bash
set -euo pipefail

APP_NAME="zmux DEV"
BUNDLE_ID="com.zmuxterm.app.debug"
BASE_APP_NAME="zmux DEV"
DERIVED_DATA=""
NAME_SET=0
BUNDLE_SET=0
DERIVED_SET=0
TAG=""
LAUNCH=0
ZMUX_DEBUG_LOG=""
ZMUX_DEV_PORT=""
ZMUX_DEV_PORT_END=""
ZMUX_DEV_PORT_RANGE=""
ZMUX_DEV_ORIGIN=""
CLI_PATH=""
LAST_SOCKET_PATH_DIR="$HOME/Library/Application Support/zmux"
LAST_SOCKET_PATH_FILE="${LAST_SOCKET_PATH_DIR}/last-socket-path"
AUTO_SKIP_ZIG_BUILD_REASON=""

should_skip_ghostty_cli_helper_zig_build() {
  if [[ "${ZMUX_SKIP_ZIG_BUILD:-}" == "1" ]]; then
    AUTO_SKIP_ZIG_BUILD_REASON="ZMUX_SKIP_ZIG_BUILD=1"
    return 0
  fi

  local product_version zig_version major_version
  product_version="$(sw_vers -productVersion 2>/dev/null || true)"
  zig_version="$(zig version 2>/dev/null || true)"
  major_version="${product_version%%.*}"

  if [[ "$zig_version" == "0.15.2" ]] && [[ "$major_version" =~ ^[0-9]+$ ]] && (( major_version >= 26 )); then
    AUTO_SKIP_ZIG_BUILD_REASON="macOS ${product_version} + zig ${zig_version}"
    return 0
  fi

  AUTO_SKIP_ZIG_BUILD_REASON=""
  return 1
}

write_dev_cli_shim() {
  local target="$1"
  local fallback_bin="$2"
  mkdir -p "$(dirname "$target")"
  cat > "$target" <<EOF
#!/usr/bin/env bash
# zmux dev shim (managed by scripts/reload.sh)
set -euo pipefail

CLI_PATH_FILE="/tmp/zmux-last-cli-path"
CLI_PATH_OWNER="\$(stat -f '%u' "\$CLI_PATH_FILE" 2>/dev/null || stat -c '%u' "\$CLI_PATH_FILE" 2>/dev/null || echo -1)"
if [[ -r "\$CLI_PATH_FILE" ]] && [[ ! -L "\$CLI_PATH_FILE" ]] && [[ "\$CLI_PATH_OWNER" == "\$(id -u)" ]]; then
  CLI_PATH="\$(cat "\$CLI_PATH_FILE")"
  if [[ -x "\$CLI_PATH" ]]; then
    exec "\$CLI_PATH" "\$@"
  fi
fi

if [[ -x "$fallback_bin" ]]; then
  exec "$fallback_bin" "\$@"
fi

echo "error: no reload-selected dev zmux CLI found. Run ./scripts/reload.sh --tag <name> first." >&2
exit 1
EOF
  chmod +x "$target"
}

select_zmux_shim_target() {
  local app_cli_dir="/Applications/zmux.app/Contents/Resources/bin"
  local marker="zmux dev shim (managed by scripts/reload.sh)"
  local target=""
  local path_entry=""
  local candidate=""

  IFS=':' read -r -a path_entries <<< "${PATH:-}"
  for path_entry in "${path_entries[@]}"; do
    [[ -z "$path_entry" ]] && continue
    if [[ "$path_entry" == "~/"* ]]; then
      path_entry="$HOME/${path_entry#~/}"
    fi
    if [[ "$path_entry" == "$app_cli_dir" ]]; then
      break
    fi
    [[ -d "$path_entry" && -w "$path_entry" ]] || continue
    candidate="$path_entry/zmux"
    if [[ ! -e "$candidate" ]]; then
      target="$candidate"
      break
    fi
    if [[ -f "$candidate" ]] && grep -q "$marker" "$candidate" 2>/dev/null; then
      target="$candidate"
      break
    fi
  done

  if [[ -n "$target" ]]; then
    echo "$target"
    return 0
  fi

  # Fallback for PATH layouts where app CLI isn't listed or no earlier entries were writable.
  for path_entry in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/bin"; do
    [[ -d "$path_entry" && -w "$path_entry" ]] || continue
    candidate="$path_entry/zmux"
    if [[ ! -e "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
    if [[ -f "$candidate" ]] && grep -q "$marker" "$candidate" 2>/dev/null; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}

write_last_socket_path() {
  local socket_path="$1"
  mkdir -p "$LAST_SOCKET_PATH_DIR"
  echo "$socket_path" > "$LAST_SOCKET_PATH_FILE" || true
  echo "$socket_path" > /tmp/zmux-last-socket-path || true
}

usage() {
  cat <<'EOF'
Usage: ./scripts/reload.sh --tag <name> [options]

Options:
  --tag <name>           Required. Short tag for parallel builds (e.g., feature-xyz-lol).
                         Sets app name, bundle id, and derived data path unless overridden.
                         After a successful build, terminates any running app with this tag
                         so macOS launches the freshly-built binary on cmd-click or --launch.
  --launch               Launch the app after building. Without this flag, the script
                         builds and prints the app path but does not open it.
  --name <app name>      Override app display/bundle name.
  --bundle-id <id>       Override bundle identifier.
  --derived-data <path>  Override derived data path.
  -h, --help             Show this help.
EOF
}

sanitize_bundle() {
  local raw="$1"
  local cleaned
  cleaned="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/./g; s/^\\.+//; s/\\.+$//; s/\\.+/./g')"
  if [[ -z "$cleaned" ]]; then
    cleaned="agent"
  fi
  echo "$cleaned"
}

sanitize_path() {
  local raw="$1"
  local cleaned
  cleaned="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  if [[ -z "$cleaned" ]]; then
    cleaned="agent"
  fi
  echo "$cleaned"
}

is_valid_port() {
  local port="${1:-}"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  local numeric=$((10#$port))
  (( numeric >= 1 && numeric <= 65535 ))
}

is_positive_integer() {
  local value="${1:-}"
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  local numeric=$((10#$value))
  (( numeric > 0 ))
}

choose_zmux_dev_port() {
  if is_valid_port "${ZMUX_PORT:-}"; then
    echo "$ZMUX_PORT"
    return 0
  fi
  if is_valid_port "${PORT:-}"; then
    echo "$PORT"
    return 0
  fi
  echo "3777"
}

choose_zmux_dev_port_range() {
  if is_positive_integer "${ZMUX_PORT_RANGE:-}"; then
    echo "$ZMUX_PORT_RANGE"
    return 0
  fi
  echo "1"
}

choose_zmux_dev_port_end() {
  local start="$1"
  local range="$2"
  if is_valid_port "${ZMUX_PORT_END:-}"; then
    echo "$ZMUX_PORT_END"
    return 0
  fi
  local start_num=$((10#$start))
  local range_num=$((10#$range))
  local end=$((start_num + range_num - 1))
  if (( end > 65535 )); then
    end="$start_num"
  fi
  echo "$end"
}

set_plist_env() {
  local plist="$1"
  local key="$2"
  local value="$3"
  /usr/libexec/PlistBuddy -c "Set :LSEnvironment:${key} \"${value}\"" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :LSEnvironment:${key} string \"${value}\"" "$plist"
}

tagged_derived_data_path() {
  local slug="$1"
  echo "$HOME/Library/Developer/Xcode/DerivedData/zmux-${slug}"
}

print_tag_cleanup_reminder() {
  local current_slug="$1"
  local path=""
  local tag=""
  local seen=" "
  local -a stale_tags=()

  while IFS= read -r -d '' path; do
    if [[ "$path" == /tmp/zmux-* ]]; then
      tag="${path#/tmp/zmux-}"
    elif [[ "$path" == "$HOME/Library/Developer/Xcode/DerivedData/zmux-"* ]]; then
      tag="${path#$HOME/Library/Developer/Xcode/DerivedData/zmux-}"
    else
      continue
    fi
    if [[ "$tag" == "$current_slug" ]]; then
      continue
    fi
    # Only surface stale debug tag builds.
    if [[ ! -d "$path/Build/Products/Debug" ]]; then
      continue
    fi
    if [[ "$seen" == *" $tag "* ]]; then
      continue
    fi
    seen="${seen}${tag} "
    stale_tags+=("$tag")
  done < <(
    find /tmp -maxdepth 1 -name 'zmux-*' -print0 2>/dev/null
    find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 1 -type d -name 'zmux-*' -print0 2>/dev/null
  )

  echo
  echo "Tag cleanup status:"
  echo "  current tag: ${current_slug} (keep this running until you verify)"
  if [[ "${#stale_tags[@]}" -eq 0 ]]; then
    echo "  stale tags: none"
    echo "  stale cleanup: not needed"
  else
    echo "  stale tags:"
    for tag in "${stale_tags[@]}"; do
      echo "    - ${tag}"
    done
    echo "Cleanup stale tags only:"
    for tag in "${stale_tags[@]}"; do
      echo "  pkill -f \"zmux DEV ${tag}.app/Contents/MacOS/zmux DEV\""
      echo "  rm -rf \"$(tagged_derived_data_path "$tag")\" \"/tmp/zmux-${tag}\" \"/tmp/zmux-debug-${tag}.sock\""
      echo "  rm -f \"/tmp/zmux-debug-${tag}.log\""
      echo "  rm -f \"$HOME/Library/Application Support/zmux/zmuxd-dev-${tag}.sock\""
    done
  fi
  echo "After you verify current tag, cleanup command:"
  echo "  pkill -f \"zmux DEV ${current_slug}.app/Contents/MacOS/zmux DEV\""
  echo "  rm -rf \"$(tagged_derived_data_path "$current_slug")\" \"/tmp/zmux-${current_slug}\" \"/tmp/zmux-debug-${current_slug}.sock\""
  echo "  rm -f \"/tmp/zmux-debug-${current_slug}.log\""
  echo "  rm -f \"$HOME/Library/Application Support/zmux/zmuxd-dev-${current_slug}.sock\""
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      TAG="${2:-}"
      if [[ -z "$TAG" ]]; then
        echo "error: --tag requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    --name)
      APP_NAME="${2:-}"
      if [[ -z "$APP_NAME" ]]; then
        echo "error: --name requires a value" >&2
        exit 1
      fi
      NAME_SET=1
      shift 2
      ;;
    --bundle-id)
      BUNDLE_ID="${2:-}"
      if [[ -z "$BUNDLE_ID" ]]; then
        echo "error: --bundle-id requires a value" >&2
        exit 1
      fi
      BUNDLE_SET=1
      shift 2
      ;;
    --launch)
      LAUNCH=1
      shift
      ;;
    --derived-data)
      DERIVED_DATA="${2:-}"
      if [[ -z "$DERIVED_DATA" ]]; then
        echo "error: --derived-data requires a value" >&2
        exit 1
      fi
      DERIVED_SET=1
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$TAG" ]]; then
  echo "error: --tag is required (example: ./scripts/reload.sh --tag fix-sidebar-theme)" >&2
  usage
  exit 1
fi

if [[ -n "$TAG" ]]; then
  TAG_ID="$(sanitize_bundle "$TAG")"
  TAG_SLUG="$(sanitize_path "$TAG")"
  if [[ "$NAME_SET" -eq 0 ]]; then
    APP_NAME="zmux DEV ${TAG}"
  fi
  if [[ "$BUNDLE_SET" -eq 0 ]]; then
    BUNDLE_ID="com.zmuxterm.app.debug.${TAG_ID}"
  fi
  if [[ "$DERIVED_SET" -eq 0 ]]; then
    DERIVED_DATA="$(tagged_derived_data_path "$TAG_SLUG")"
  fi
fi

ZMUX_DEV_PORT="$(choose_zmux_dev_port)"
ZMUX_DEV_PORT_RANGE="$(choose_zmux_dev_port_range)"
ZMUX_DEV_PORT_END="$(choose_zmux_dev_port_end "$ZMUX_DEV_PORT" "$ZMUX_DEV_PORT_RANGE")"
ZMUX_DEV_ORIGIN="http://localhost:${ZMUX_DEV_PORT}"

# Quiet logging: capture all noisy build output (xcodebuild, zig, codesign,
# plistbuddy, etc.) to a single log file. On success we print only a one-line
# summary plus the App/CLI paths. On failure we dump the log.
RELOAD_LOG="/tmp/zmux-reload-${TAG_SLUG}.log"
RELOAD_START_TIME="$(date +%s)"
: > "$RELOAD_LOG"

# Save the original stdout/stderr so the EXIT trap can write the user-facing
# summary after the body redirect, then redirect bulk output into the log.
exec 3>&1 4>&2
exec >>"$RELOAD_LOG" 2>&1

reload_finalize() {
  local rc=$?
  trap - EXIT
  exec 1>&3 2>&4
  local elapsed=$(( $(date +%s) - RELOAD_START_TIME ))
  if [[ "$rc" -ne 0 ]]; then
    if [[ -s "$RELOAD_LOG" ]]; then
      cat "$RELOAD_LOG" >&2
    fi
    echo "" >&2
    echo "==> reload FAILED (exit $rc) after ${elapsed}s" >&2
    echo "==> log: $RELOAD_LOG" >&2
    exit "$rc"
  fi
  echo "==> reload succeeded in ${elapsed}s"
  echo "==> log: $RELOAD_LOG"
  if [[ -n "${APP_PATH:-}" ]]; then
    echo
    echo "App path:"
    echo "  $APP_PATH"
  fi
  if [[ -n "${ZMUX_DEV_ORIGIN:-}" ]]; then
    echo
    echo "Dev web origin:"
    echo "  $ZMUX_DEV_ORIGIN"
  fi
  if [[ -x "${CLI_PATH:-}" ]]; then
    echo
    echo "CLI path:"
    echo "  $CLI_PATH"
    echo "CLI helpers:"
    echo "  /tmp/zmux-cli ..."
    echo "  $HOME/.local/bin/zmux-dev ..."
    if [[ -n "${ZMUX_SHIM_TARGET:-}" ]]; then
      echo "  $ZMUX_SHIM_TARGET ..."
    fi
    echo "If your shell still resolves the old zmux, run: rehash"
  fi
  if [[ "$LAUNCH" -eq 0 ]]; then
    echo
    echo "Build complete. Pass --launch to open the app, or cmd-click the path above."
  fi
}
trap reload_finalize EXIT

# Tell the user we're starting (visible even though body output is redirected).
echo "==> reload starting (tag: ${TAG}, log: ${RELOAD_LOG})" >&3

"$PWD/scripts/ensure-ghosttykit.sh"

if should_skip_ghostty_cli_helper_zig_build; then
  if [[ "${ZMUX_SKIP_ZIG_BUILD:-}" != "1" ]]; then
    echo "Auto-enabling ZMUX_SKIP_ZIG_BUILD=1 for Ghostty CLI helper (${AUTO_SKIP_ZIG_BUILD_REASON})"
  fi
  export ZMUX_SKIP_ZIG_BUILD=1
fi

XCODEBUILD_ARGS=(
  -project GhosttyTabs.xcodeproj
  -scheme zmux
  -configuration Debug
  -destination 'platform=macOS'
)
if [[ -n "$DERIVED_DATA" ]]; then
  XCODEBUILD_ARGS+=(-derivedDataPath "$DERIVED_DATA")
fi
if [[ -z "$TAG" ]]; then
  XCODEBUILD_ARGS+=(
    INFOPLIST_KEY_CFBundleName="$APP_NAME"
    INFOPLIST_KEY_CFBundleDisplayName="$APP_NAME"
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID"
  )
fi
# Forward ZMUX_SKIP_ZIG_BUILD to xcodebuild run script phases (e.g. macOS
# Tahoe where zig 0.15.2 can't link the ghostty CLI helper).
if [[ "${ZMUX_SKIP_ZIG_BUILD:-}" == "1" ]]; then
  XCODEBUILD_ARGS+=(ZMUX_SKIP_ZIG_BUILD=1)
fi
XCODEBUILD_ARGS+=(build)

XCODEBUILD_LOCK="${TMPDIR:-/tmp}/zmux-xcodebuild-$(id -u).lock"
# Xcode 26's SWBBuildService is a per-user singleton. Concurrent xcodebuild
# invocations (even with separate -derivedDataPath) share that daemon and can
# crash it, SIGTERMing in-flight builds. Serialize via a per-user lock so
# parallel reload.sh runs queue instead of trampling each other.
python3 -c '
import fcntl
import os
import sys

lock_path = sys.argv[1]
command = sys.argv[2:]

try:
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
except OSError as exc:
    raise SystemExit(f"error: open lock: {exc}")

try:
    flags = fcntl.fcntl(fd, fcntl.F_GETFD)
    fcntl.fcntl(fd, fcntl.F_SETFD, flags & ~fcntl.FD_CLOEXEC)
except OSError as exc:
    raise SystemExit(f"error: fcntl lock fd: {exc}")

try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    msg = f"==> Another xcodebuild is running; waiting for {lock_path}...\n"
    # reload.sh saves the original stderr on fd 4 before redirecting to the
    # log file. Surface the wait notice to the terminal so the user knows
    # they are queued, not hung. Fall back to stderr (the log) if fd 4 is
    # unavailable (e.g. when this script is run standalone).
    try:
        os.write(4, msg.encode())
    except OSError:
        sys.stderr.write(msg)
        sys.stderr.flush()
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
    except OSError as exc:
        raise SystemExit(f"error: flock: {exc}")
except OSError as exc:
    raise SystemExit(f"error: flock: {exc}")

try:
    os.execvp(command[0], command)
except OSError as exc:
    raise SystemExit(f"error: exec: {exc}")
' "$XCODEBUILD_LOCK" xcodebuild "${XCODEBUILD_ARGS[@]}"
sleep 0.2

FALLBACK_APP_NAME="$BASE_APP_NAME"
SEARCH_APP_NAME="$APP_NAME"
if [[ -n "$TAG" ]]; then
  SEARCH_APP_NAME="$BASE_APP_NAME"
fi
if [[ -n "$DERIVED_DATA" ]]; then
  APP_PATH="${DERIVED_DATA}/Build/Products/Debug/${SEARCH_APP_NAME}.app"
  if [[ ! -d "${APP_PATH}" && "$SEARCH_APP_NAME" != "$FALLBACK_APP_NAME" ]]; then
    APP_PATH="${DERIVED_DATA}/Build/Products/Debug/${FALLBACK_APP_NAME}.app"
  fi
else
  APP_BINARY="$(
    find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Debug/${SEARCH_APP_NAME}.app/Contents/MacOS/${SEARCH_APP_NAME}" -print0 \
    | xargs -0 /usr/bin/stat -f "%m %N" 2>/dev/null \
    | sort -nr \
    | head -n 1 \
    | cut -d' ' -f2-
  )"
  if [[ -n "${APP_BINARY}" ]]; then
    APP_PATH="$(dirname "$(dirname "$(dirname "$APP_BINARY")")")"
  fi
  if [[ -z "${APP_PATH}" && "$SEARCH_APP_NAME" != "$FALLBACK_APP_NAME" ]]; then
    APP_BINARY="$(
      find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Debug/${FALLBACK_APP_NAME}.app/Contents/MacOS/${FALLBACK_APP_NAME}" -print0 \
      | xargs -0 /usr/bin/stat -f "%m %N" 2>/dev/null \
      | sort -nr \
      | head -n 1 \
      | cut -d' ' -f2-
    )"
    if [[ -n "${APP_BINARY}" ]]; then
      APP_PATH="$(dirname "$(dirname "$(dirname "$APP_BINARY")")")"
    fi
  fi
fi
if [[ -z "${APP_PATH}" || ! -d "${APP_PATH}" ]]; then
  echo "${APP_NAME}.app not found in DerivedData" >&2
  exit 1
fi

if [[ -n "${TAG_SLUG:-}" ]]; then
  TMP_COMPAT_DERIVED_LINK="/tmp/zmux-${TAG_SLUG}"
  if [[ "$DERIVED_DATA" != "$TMP_COMPAT_DERIVED_LINK" ]]; then
    ABS_DERIVED_DATA="$(cd "$DERIVED_DATA" && pwd)"
    rm -rf "$TMP_COMPAT_DERIVED_LINK"
    ln -s "$ABS_DERIVED_DATA" "$TMP_COMPAT_DERIVED_LINK"
  fi
fi

if [[ -n "$TAG" && "$APP_NAME" != "$SEARCH_APP_NAME" ]]; then
  TAG_APP_PATH="$(dirname "$APP_PATH")/${APP_NAME}.app"
  rm -rf "$TAG_APP_PATH"
  cp -R "$APP_PATH" "$TAG_APP_PATH"
  INFO_PLIST="$TAG_APP_PATH/Contents/Info.plist"
  if [[ -f "$INFO_PLIST" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$INFO_PLIST" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Add :CFBundleName string $APP_NAME" "$INFO_PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$INFO_PLIST" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $APP_NAME" "$INFO_PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$INFO_PLIST" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $BUNDLE_ID" "$INFO_PLIST"
    if [[ -n "${TAG_SLUG:-}" ]]; then
      APP_SUPPORT_DIR="$HOME/Library/Application Support/zmux"
      ZMUXD_SOCKET="${APP_SUPPORT_DIR}/zmuxd-dev-${TAG_SLUG}.sock"
      ZMUX_SOCKET="/tmp/zmux-debug-${TAG_SLUG}.sock"
      ZMUX_DEBUG_LOG="/tmp/zmux-debug-${TAG_SLUG}.log"
      write_last_socket_path "$ZMUX_SOCKET"
      echo "$ZMUX_DEBUG_LOG" > /tmp/zmux-last-debug-log-path || true
      /usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$INFO_PLIST" 2>/dev/null || true
      set_plist_env "$INFO_PLIST" ZMUXD_UNIX_PATH "$ZMUXD_SOCKET"
      set_plist_env "$INFO_PLIST" ZMUX_SOCKET_PATH "$ZMUX_SOCKET"
      set_plist_env "$INFO_PLIST" ZMUX_DEBUG_LOG "$ZMUX_DEBUG_LOG"
      set_plist_env "$INFO_PLIST" ZMUX_SOCKET_ENABLE "1"
      set_plist_env "$INFO_PLIST" ZMUX_SOCKET_MODE "allowAll"
      set_plist_env "$INFO_PLIST" ZMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD "1"
      set_plist_env "$INFO_PLIST" ZMUXTERM_REPO_ROOT "$PWD"
      set_plist_env "$INFO_PLIST" ZMUX_PORT "$ZMUX_DEV_PORT"
      set_plist_env "$INFO_PLIST" ZMUX_PORT_END "$ZMUX_DEV_PORT_END"
      set_plist_env "$INFO_PLIST" ZMUX_PORT_RANGE "$ZMUX_DEV_PORT_RANGE"
      set_plist_env "$INFO_PLIST" PORT "$ZMUX_DEV_PORT"
      set_plist_env "$INFO_PLIST" ZMUX_AUTH_WWW_ORIGIN "$ZMUX_DEV_ORIGIN"
      set_plist_env "$INFO_PLIST" ZMUX_API_BASE_URL "$ZMUX_DEV_ORIGIN"
      set_plist_env "$INFO_PLIST" ZMUX_VM_API_BASE_URL "$ZMUX_DEV_ORIGIN"
      if [[ -S "$ZMUXD_SOCKET" ]]; then
        for PID in $(lsof -t "$ZMUXD_SOCKET" 2>/dev/null); do
          kill "$PID" 2>/dev/null || true
        done
        rm -f "$ZMUXD_SOCKET"
      fi
      if [[ -S "$ZMUX_SOCKET" ]]; then
        rm -f "$ZMUX_SOCKET"
      fi
    fi
  fi
  APP_PATH="$TAG_APP_PATH"
fi

CLI_PATH="$(dirname "$APP_PATH")/zmux"
if [[ -x "$CLI_PATH" ]]; then
  (umask 077; printf '%s\n' "$CLI_PATH" > /tmp/zmux-last-cli-path) || true
  ln -sfn "$CLI_PATH" /tmp/zmux-cli || true

  # Stable shim that always follows the last reload-selected dev CLI.
  DEV_CLI_SHIM="$HOME/.local/bin/zmux-dev"
  write_dev_cli_shim "$DEV_CLI_SHIM" "/Applications/zmux.app/Contents/Resources/bin/zmux"

  ZMUX_SHIM_TARGET="$(select_zmux_shim_target || true)"
  if [[ -n "${ZMUX_SHIM_TARGET:-}" ]]; then
    write_dev_cli_shim "$ZMUX_SHIM_TARGET" "/Applications/zmux.app/Contents/Resources/bin/zmux"
  fi
fi

# Build zmuxd and ghostty helper binaries (needed for both launch and no-launch).
ZMUXD_SRC="$PWD/zmuxd/zig-out/bin/zmuxd"
GHOSTTY_HELPER_SRC="$PWD/ghostty/zig-out/bin/ghostty"
if [[ -d "$PWD/zmuxd" ]]; then
  (cd "$PWD/zmuxd" && zig build -Doptimize=ReleaseFast)
fi
if [[ -d "$PWD/ghostty" ]]; then
  if [[ "${ZMUX_SKIP_ZIG_BUILD:-}" == "1" ]]; then
    echo "Skipping direct ghostty CLI helper zig build (ZMUX_SKIP_ZIG_BUILD=1)"
  else
    (cd "$PWD/ghostty" && zig build cli-helper -Dapp-runtime=none -Demit-macos-app=false -Demit-xcframework=false -Doptimize=ReleaseFast)
  fi
fi
if [[ -x "$ZMUXD_SRC" ]]; then
  BIN_DIR="$APP_PATH/Contents/Resources/bin"
  mkdir -p "$BIN_DIR"
  cp "$ZMUXD_SRC" "$BIN_DIR/zmuxd"
  chmod +x "$BIN_DIR/zmuxd"
fi
if [[ -x "$GHOSTTY_HELPER_SRC" ]]; then
  BIN_DIR="$APP_PATH/Contents/Resources/bin"
  mkdir -p "$BIN_DIR"
  cp "$GHOSTTY_HELPER_SRC" "$BIN_DIR/ghostty"
  chmod +x "$BIN_DIR/ghostty"
fi
if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$APP_PATH" || true
fi
if ! /usr/bin/codesign --force --sign - --timestamp=none --generate-entitlement-der "$APP_PATH" >/dev/null 2>&1; then
  if [[ "${ZMUX_ALLOW_UNSIGNED_DEV_APP:-}" == "1" ]]; then
    echo "warning: codesign failed for $APP_PATH; continuing because ZMUX_ALLOW_UNSIGNED_DEV_APP=1" >&2
  else
    echo "error: codesign failed for $APP_PATH" >&2
    exit 1
  fi
fi
CLI_PATH="$APP_PATH/Contents/Resources/bin/zmux"
if [[ -x "$CLI_PATH" ]]; then
  echo "$CLI_PATH" > /tmp/zmux-last-cli-path || true
fi

# Tag mode: always terminate the existing same-tag instance after a successful build,
# even without --launch. A stale tagged app pinned to this bundle id would otherwise
# keep running against freshly-overwritten resources, and macOS would foreground it
# instead of launching the newly built binary when the user cmd-clicks the .app.
if [[ -n "$TAG" ]]; then
  /usr/bin/osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
  sleep 0.3
  pkill -f "${APP_NAME}.app/Contents/MacOS/${BASE_APP_NAME}" || true
  sleep 0.3
fi

if [[ "$LAUNCH" -eq 1 ]]; then
  if [[ -z "$TAG" ]]; then
    # Non-tag mode: kill any running instance (across any DerivedData path) to avoid socket conflicts.
    /usr/bin/osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
    sleep 0.3
    pkill -f "/${BASE_APP_NAME}.app/Contents/MacOS/${BASE_APP_NAME}" || true
    sleep 0.3
  fi

  # Avoid inheriting zmux/ghostty environment variables from the terminal that
  # runs this script (often inside another zmux instance), which can cause
  # socket and resource-path conflicts.
  OPEN_CLEAN_ENV=(
    env
    -u ZMUX_SOCKET_PATH
    -u ZMUX_WORKSPACE_ID
    -u ZMUX_SURFACE_ID
    -u ZMUX_TAB_ID
    -u ZMUX_PANEL_ID
    -u ZMUXD_UNIX_PATH
    -u ZMUX_TAG
    -u ZMUX_DEBUG_LOG
    -u ZMUX_BUNDLE_ID
    -u ZMUX_SHELL_INTEGRATION
    -u GHOSTTY_BIN_DIR
    -u GHOSTTY_RESOURCES_DIR
    -u GHOSTTY_SHELL_FEATURES
    # Dev shells (including CI/Codex) often force-disable paging by exporting these.
    # Don't leak that into zmux, otherwise `git diff` won't page even with PAGER=less.
    -u GIT_PAGER
    -u GH_PAGER
    -u TERMINFO
    -u XDG_DATA_DIRS
  )

  TAG_LAUNCH_ENV=(
    ZMUX_TAG="${TAG_SLUG:-}"
    ZMUX_SOCKET_ENABLE=1
    ZMUX_SOCKET_MODE=allowAll
    ZMUX_DEBUG_LOG="$ZMUX_DEBUG_LOG"
    ZMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD=1
    ZMUXTERM_REPO_ROOT="$PWD"
    ZMUX_PORT="$ZMUX_DEV_PORT"
    ZMUX_PORT_END="$ZMUX_DEV_PORT_END"
    ZMUX_PORT_RANGE="$ZMUX_DEV_PORT_RANGE"
    PORT="$ZMUX_DEV_PORT"
    ZMUX_AUTH_WWW_ORIGIN="$ZMUX_DEV_ORIGIN"
    ZMUX_API_BASE_URL="$ZMUX_DEV_ORIGIN"
    ZMUX_VM_API_BASE_URL="$ZMUX_DEV_ORIGIN"
  )

  if [[ -n "${TAG_SLUG:-}" && -n "${ZMUX_SOCKET:-}" ]]; then
    # Ensure tag-specific socket paths win even if the caller has ZMUX_* overrides.
    "${OPEN_CLEAN_ENV[@]}" "${TAG_LAUNCH_ENV[@]}" ZMUX_SOCKET_PATH="$ZMUX_SOCKET" ZMUXD_UNIX_PATH="$ZMUXD_SOCKET" open -g "$APP_PATH"
  elif [[ -n "${TAG_SLUG:-}" ]]; then
    "${OPEN_CLEAN_ENV[@]}" "${TAG_LAUNCH_ENV[@]}" open -g "$APP_PATH"
  else
    echo "/tmp/zmux-debug.sock" > /tmp/zmux-last-socket-path || true
    echo "/tmp/zmux-debug.log" > /tmp/zmux-last-debug-log-path || true
    "${OPEN_CLEAN_ENV[@]}" open -g "$APP_PATH"
  fi

  # Safety: ensure only one instance is running.
  sleep 0.2
  PIDS=($(pgrep -f "${APP_PATH}/Contents/MacOS/" || true))
  if [[ "${#PIDS[@]}" -gt 1 ]]; then
    NEWEST_PID=""
    NEWEST_AGE=999999
    for PID in "${PIDS[@]}"; do
      AGE="$(ps -o etimes= -p "$PID" | tr -d ' ')"
      if [[ -n "$AGE" && "$AGE" -lt "$NEWEST_AGE" ]]; then
        NEWEST_AGE="$AGE"
        NEWEST_PID="$PID"
      fi
    done
    for PID in "${PIDS[@]}"; do
      if [[ "$PID" != "$NEWEST_PID" ]]; then
        kill "$PID" 2>/dev/null || true
      fi
    done
  fi
fi

# The user-facing summary (success line, App path, CLI path/helpers, rehash
# hint, "pass --launch") is printed by the reload_finalize EXIT trap. The
# tag-cleanup reminder still runs here, but its output goes to $RELOAD_LOG
# (visible by tail -f or by inspecting the log path printed in the summary).
if [[ -n "${TAG_SLUG:-}" ]]; then
  print_tag_cleanup_reminder "$TAG_SLUG"
fi
