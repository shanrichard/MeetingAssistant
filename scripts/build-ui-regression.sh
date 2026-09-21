#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --disable-sandbox --build-system native -c release
BIN_DIRECTORY=$(swift build --disable-sandbox --build-system native -c release --show-bin-path)
APP="$PWD/.build/ui-regression/MeetingUIRegression.app"
mkdir -p "$APP/Contents/MacOS"
sources=()
for source in Sources/MeetingAssistant/*.swift; do
    if [[ "$source" != Sources/MeetingAssistant/App.swift ]]; then sources+=("$source"); fi
done
core_objects=()
for source in Sources/MeetingCore/*.swift; do
    core_objects+=("$BIN_DIRECTORY/MeetingCore.build/$(basename "$source").o")
done
swiftc -parse-as-library -O -g -target arm64-apple-macosx14.2 -module-name MeetingUIRegression \
    -I "$BIN_DIRECTORY/Modules" -I "$BIN_DIRECTORY/AudioSafety.build" \
    "${sources[@]}" Tests/UIRegression/*.swift \
    "${core_objects[@]}" "$BIN_DIRECTORY"/AudioSafety.build/*.m.o \
    -o "$APP/Contents/MacOS/MeetingUIRegression.new"
mv -f "$APP/Contents/MacOS/MeetingUIRegression.new" "$APP/Contents/MacOS/MeetingUIRegression"
python3 - "$APP" <<'PY'
import pathlib, plistlib, sys
with (pathlib.Path(sys.argv[1])/'Contents/Info.plist').open('wb') as f:
    plistlib.dump({'CFBundleIdentifier': 'com.meetingassistant.tests.UIRegression',
                  'CFBundleName': 'MeetingUIRegression', 'CFBundleExecutable': 'MeetingUIRegression',
                  'CFBundlePackageType': 'APPL', 'LSMinimumSystemVersion': '14.2'}, f)
PY
codesign --force --sign - "$APP"
echo "$APP"
