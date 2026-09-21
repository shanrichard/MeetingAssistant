#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
swift build --disable-sandbox --build-system native -c release
BIN_DIRECTORY=$(swift build --disable-sandbox --build-system native -c release --show-bin-path)
CHECK_DIRECTORY="$PWD/.build/blackhole-setup-checks"
mkdir -p "$CHECK_DIRECTORY"
core_objects=()
for source in Sources/MeetingCore/*.swift; do
    core_objects+=("$BIN_DIRECTORY/MeetingCore.build/$(basename "$source").o")
done
swiftc -parse-as-library -O -g -target arm64-apple-macosx14.2 -module-cache-path .build/ModuleCache \
    -I "$BIN_DIRECTORY/Modules" Sources/MeetingAssistant/AudioDevices.swift \
    Sources/MeetingAssistant/BlackHolePackage.swift Sources/MeetingAssistant/BlackHoleSetup.swift \
    Tests/BlackHoleSetupChecks/main.swift "${core_objects[@]}" \
    -o "$CHECK_DIRECTORY/BlackHoleSetupChecks"
"$CHECK_DIRECTORY/BlackHoleSetupChecks" "$@"
