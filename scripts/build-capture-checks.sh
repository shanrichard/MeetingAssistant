#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${MEETING_SIGNING_IDENTITY:?Set an Apple Development signing identity for the cloud signing archive}"
swift build --disable-sandbox --build-system native -c release
BIN_DIRECTORY=$(swift build --disable-sandbox --build-system native -c release --show-bin-path)
APP="$PWD/.build/capture-checks/MeetingAssistant.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -parse-as-library -O -g -target arm64-apple-macosx14.2 -module-name MeetingCaptureChecks \
    -I "$BIN_DIRECTORY/Modules" -I "$BIN_DIRECTORY/AudioSafety.build" \
    Sources/MeetingAssistant/AudioCapture.swift Sources/MeetingAssistant/AudioDevices.swift Sources/MeetingAssistant/MicrophoneCapture.swift Tests/CaptureChecks/main.swift \
    "$BIN_DIRECTORY"/MeetingCore.build/*.swift.o "$BIN_DIRECTORY"/AudioSafety.build/*.m.o \
    -o "$APP/Contents/MacOS/MeetingAssistant.new"
mv -f "$APP/Contents/MacOS/MeetingAssistant.new" "$APP/Contents/MacOS/MeetingAssistant"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --options runtime --timestamp --entitlements Resources/MeetingAssistant.entitlements \
    --sign "$MEETING_SIGNING_IDENTITY" "$APP"
echo "$APP"
