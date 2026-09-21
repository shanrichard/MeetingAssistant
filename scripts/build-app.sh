#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --disable-sandbox --build-system native -c release
APP="${1:-$PWD/dist/MeetingAssistant.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MeetingAssistant "$APP/Contents/MacOS/MeetingAssistant.new"
mv -f "$APP/Contents/MacOS/MeetingAssistant.new" "$APP/Contents/MacOS/MeetingAssistant"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [[ -n "${MEETING_SIGNING_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --entitlements Resources/MeetingAssistant.entitlements --sign "$MEETING_SIGNING_IDENTITY" "$APP"
else
    SIGNING_DIRECTORY="$HOME/Library/Application Support/MeetingAssistant/DevelopmentSigning"
    SIGNING_IDENTITY=$(swift -suppress-warnings scripts/prepare-signing.swift "$SIGNING_DIRECTORY")
    codesign --force --timestamp=none --keychain "$SIGNING_DIRECTORY/development.keychain-db" --sign "$SIGNING_IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "Built $APP"
