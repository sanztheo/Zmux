#!/bin/bash
# Rebuild and restart zmux app

set -e

cd "$(dirname "$0")/.."

# Kill existing app if running
pkill -9 -f "zmux" 2>/dev/null || true

# Build
swift build

# Copy to app bundle
cp .build/debug/zmux .build/debug/zmux.app/Contents/MacOS/

# Open the app
open .build/debug/zmux.app
