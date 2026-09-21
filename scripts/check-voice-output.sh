#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --disable-sandbox --build-system native -c release
BIN_DIRECTORY=$(swift build --disable-sandbox --build-system native -c release --show-bin-path)
CHECK_DIRECTORY="$PWD/.build/voice-output-checks"
mkdir -p "$CHECK_DIRECTORY"
core_objects=()
for source in Sources/MeetingCore/*.swift; do
    core_objects+=("$BIN_DIRECTORY/MeetingCore.build/$(basename "$source").o")
done
swiftc -parse-as-library -O -g -target arm64-apple-macosx14.2 -module-cache-path .build/ModuleCache \
    -I "$BIN_DIRECTORY/Modules" -I "$BIN_DIRECTORY/AudioSafety.build" \
    Sources/MeetingAssistant/AudioDevices.swift Sources/MeetingAssistant/VoiceOutput.swift \
    Sources/MeetingAssistant/VoicePlayback.swift Sources/MeetingAssistant/MicrophoneRoute.swift Tests/VoiceOutputChecks/*.swift \
    "${core_objects[@]}" "$BIN_DIRECTORY"/AudioSafety.build/*.m.o \
    -o "$CHECK_DIRECTORY/VoiceOutputChecks"
"$CHECK_DIRECTORY/VoiceOutputChecks" "$@"
