#!/bin/bash
set -e

cd "$(dirname "$0")/.."

DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/GhosttyTabs-ezmehgztbryftedkhvvljsnyvyqf"
APP_PATH="$DERIVED_DATA/Build/Products/Debug/zmux DEV.app"

echo "Building..."
xcodebuild \
    -project GhosttyTabs.xcodeproj \
    -scheme zmux \
    -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    ZMUX_SKIP_ZIG_BUILD=1 \
    -skipPackagePluginValidation \
    -skipPackageUpdates \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    build

echo "Launching..."
ZMUX_TAG=file-explorer open "$APP_PATH"
