#!/bin/bash
# Exercise the real credential implementation across two Developer ID cloud-signed builds.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 2 ]]; then
    echo 'Usage: bash scripts/check-cloud-credentials.sh APPLE_DEVELOPMENT_IDENTITY TEAM_ID' >&2
    exit 2
fi
DEVELOPMENT_IDENTITY="$1"
TEAM_ID="$2"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p .build
CHECK_DIRECTORY=$(mktemp -d "$PWD/.build/cloud-credential-checks.XXXXXX")
TEST_SERVICE="com.meetingassistant.tests.credentials.$(uuidgen)"
cleanup() {
    result=$?
    if [[ -d "$CHECK_DIRECTORY/export-original/MeetingAssistant.app" ]]; then
        rm -rf "$CHECK_DIRECTORY/installed.app"
        ditto "$CHECK_DIRECTORY/export-original/MeetingAssistant.app" "$CHECK_DIRECTORY/installed.app"
        "$CHECK_DIRECTORY/installed.app/Contents/MacOS/CredentialChecks" delete "$TEST_SERVICE" >/dev/null 2>&1 || true
    fi
    rm -rf "$CHECK_DIRECTORY"
    exit "$result"
}
trap cleanup EXIT
python3 - "$CHECK_DIRECTORY" "$TEAM_ID" <<'PY'
import pathlib, plistlib, sys
folder = pathlib.Path(sys.argv[1])
with (folder / 'ExportOptions.plist').open('wb') as f:
    plistlib.dump({'method': 'developer-id', 'destination': 'export',
                  'signingStyle': 'automatic', 'teamID': sys.argv[2]}, f)
for build, name in enumerate(('original', 'upgraded'), 1):
    contents = folder / name / 'MeetingAssistant.app' / 'Contents'
    (contents / 'MacOS').mkdir(parents=True)
    with (contents / 'Info.plist').open('wb') as f:
        plistlib.dump({'CFBundleIdentifier': 'com.meetingassistant.CredentialChecks',
                      'CFBundleName': 'CredentialChecks', 'CFBundleExecutable': 'CredentialChecks',
                      'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '1.0',
                      'CFBundleVersion': str(build), 'LSMinimumSystemVersion': '14.2'}, f)
PY
for version in original upgraded; do
    application="$CHECK_DIRECTORY/$version/MeetingAssistant.app"
    compiler_options=(-suppress-warnings -parse-as-library)
    if [[ "$version" == upgraded ]]; then compiler_options+=(-D KEYCHAIN_CHECK_UPGRADE); fi
    swiftc "${compiler_options[@]}" \
        Sources/MeetingCore/Credentials.swift Tests/KeychainIntegration/main.swift \
        -o "$application/Contents/MacOS/CredentialChecks"
    codesign --force --options runtime --timestamp --entitlements Resources/MeetingAssistant.entitlements \
        --sign "$DEVELOPMENT_IDENTITY" "$application"
    swift scripts/create-archive.swift --for-cloud-signing "$application" "$CHECK_DIRECTORY/$version.xcarchive"
    xcodebuild -exportArchive -archivePath "$CHECK_DIRECTORY/$version.xcarchive" \
        -exportPath "$CHECK_DIRECTORY/export-$version" \
        -exportOptionsPlist "$CHECK_DIRECTORY/ExportOptions.plist" -allowProvisioningUpdates
    signed_application="$CHECK_DIRECTORY/export-$version/MeetingAssistant.app"
    codesign --verify --deep --strict "$signed_application"
    signature=$(codesign --display --verbose=4 "$signed_application" 2>&1)
    if [[ "$signature" != *"Authority=Developer ID Application:"* || "$signature" != *"TeamIdentifier=$TEAM_ID"* ]]; then
        echo 'FAIL: cloud export did not produce the expected Developer ID signature.' >&2
        exit 1
    fi
    codesign --display -r- "$signed_application"
done
install_version() {
    rm -rf "$CHECK_DIRECTORY/installed.app"
    ditto "$CHECK_DIRECTORY/export-$1/MeetingAssistant.app" "$CHECK_DIRECTORY/installed.app"
}
CHECK_EXECUTABLE="$CHECK_DIRECTORY/installed.app/Contents/MacOS/CredentialChecks"
install_version original
"$CHECK_EXECUTABLE" write "$TEST_SERVICE"
"$CHECK_EXECUTABLE" read "$TEST_SERVICE"
"$CHECK_EXECUTABLE" replace "$TEST_SERVICE"
"$CHECK_EXECUTABLE" read-replaced "$TEST_SERVICE"
install_version upgraded
"$CHECK_EXECUTABLE" read-replaced "$TEST_SERVICE"
install_version original
"$CHECK_EXECUTABLE" read-replaced "$TEST_SERVICE"
"$CHECK_EXECUTABLE" delete "$TEST_SERVICE"
"$CHECK_EXECUTABLE" missing "$TEST_SERVICE"
echo 'PASS Developer ID cloud-signed cross-version credential lifecycle'
