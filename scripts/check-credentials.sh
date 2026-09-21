#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SIGNING_DIRECTORY="$HOME/Library/Application Support/MeetingAssistant/DevelopmentSigning"
SIGNING_IDENTITY="${MEETING_SIGNING_IDENTITY:-}"
UPGRADE_OPERATION="read-replaced"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY=$(swift -suppress-warnings scripts/prepare-signing.swift "$SIGNING_DIRECTORY")
    UPGRADE_OPERATION="upgrade"
fi
CHECK_DIRECTORY=$(mktemp -d "$PWD/.build/credential-checks.XXXXXX")
TEST_SERVICE="com.meetingassistant.tests.credentials.$(uuidgen)"
cleanup() {
    if [[ -x "$CHECK_DIRECTORY/original" ]]; then
        cp "$CHECK_DIRECTORY/original" "$CHECK_DIRECTORY/installed.new"
        mv -f "$CHECK_DIRECTORY/installed.new" "$CHECK_DIRECTORY/installed"
        "$CHECK_DIRECTORY/installed" delete "$TEST_SERVICE" >/dev/null 2>&1 || true
    fi
    rm -rf "$CHECK_DIRECTORY"
}
trap cleanup EXIT
swiftc -suppress-warnings -parse-as-library Sources/MeetingCore/Credentials.swift Tests/KeychainIntegration/main.swift -o "$CHECK_DIRECTORY/original"
swiftc -suppress-warnings -parse-as-library -D KEYCHAIN_CHECK_UPGRADE Sources/MeetingCore/Credentials.swift Tests/KeychainIntegration/main.swift -o "$CHECK_DIRECTORY/upgraded"
for binary in original upgraded; do
    if [[ -n "${MEETING_SIGNING_IDENTITY:-}" ]]; then
        codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
            --identifier com.meetingassistant.CredentialChecks "$CHECK_DIRECTORY/$binary"
    else
        codesign --force --timestamp=none --keychain "$SIGNING_DIRECTORY/development.keychain-db" --sign "$SIGNING_IDENTITY" \
            --identifier com.meetingassistant.CredentialChecks "$CHECK_DIRECTORY/$binary"
    fi
done
codesign --display -r- "$CHECK_DIRECTORY/original"
codesign --display -r- "$CHECK_DIRECTORY/upgraded"
cp "$CHECK_DIRECTORY/original" "$CHECK_DIRECTORY/installed"
"$CHECK_DIRECTORY/installed" write "$TEST_SERVICE"
"$CHECK_DIRECTORY/installed" read "$TEST_SERVICE"
"$CHECK_DIRECTORY/installed" replace "$TEST_SERVICE"
"$CHECK_DIRECTORY/installed" read-replaced "$TEST_SERVICE"
cp "$CHECK_DIRECTORY/upgraded" "$CHECK_DIRECTORY/installed.new"
mv -f "$CHECK_DIRECTORY/installed.new" "$CHECK_DIRECTORY/installed"
"$CHECK_DIRECTORY/installed" "$UPGRADE_OPERATION" "$TEST_SERVICE"
cp "$CHECK_DIRECTORY/original" "$CHECK_DIRECTORY/installed.new"
mv -f "$CHECK_DIRECTORY/installed.new" "$CHECK_DIRECTORY/installed"
"$CHECK_DIRECTORY/installed" read-replaced "$TEST_SERVICE"
"$CHECK_DIRECTORY/installed" delete "$TEST_SERVICE"
"$CHECK_DIRECTORY/installed" missing "$TEST_SERVICE"
