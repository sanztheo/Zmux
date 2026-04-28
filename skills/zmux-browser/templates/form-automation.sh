#!/usr/bin/env bash
set -euo pipefail

URL="${1:-https://example.com/form}"
SURFACE="${2:-surface:1}"

zmux browser "$SURFACE" goto "$URL"
zmux browser "$SURFACE" get url
zmux browser "$SURFACE" wait --load-state complete --timeout-ms 15000
zmux browser "$SURFACE" snapshot --interactive

echo "Now run fill/click commands using refs from the snapshot above."
