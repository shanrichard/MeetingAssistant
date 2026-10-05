#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --disable-sandbox --build-system native -c release
APP="${1:-$PWD/dist/MeetingAssistant.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MeetingAssistant "$APP/Contents/MacOS/MeetingAssistant.new"
mv -f "$APP/Contents/MacOS/MeetingAssistant.new" "$APP/Contents/MacOS/MeetingAssistant"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# The organization's Google OAuth client stays out of the repository; inject it before signing when present.
GOOGLE_CLIENT="${MEETING_GOOGLE_OAUTH_CLIENT:-$PWD/Config/google-oauth-client.json}"
if [[ -f "$GOOGLE_CLIENT" ]]; then
    python3 - "$GOOGLE_CLIENT" "$APP/Contents/Info.plist" <<'PY'
import json, plistlib, sys
with open(sys.argv[1]) as f:
    client = json.load(f)
client = client.get("installed", client)  # Also accepts the JSON downloaded from Google Cloud.
client_id, secret = client.get("client_id", "").strip(), client.get("client_secret", "").strip()
if not client_id.endswith(".apps.googleusercontent.com") or not secret:
    sys.exit("Google OAuth client file needs a desktop client_id and client_secret.")
with open(sys.argv[2], "rb") as f:
    info = plistlib.load(f)
info["GoogleOAuthClientID"], info["GoogleOAuthClientSecret"] = client_id, secret
with open(sys.argv[2], "wb") as f:
    plistlib.dump(info, f)
PY
    echo "Google OAuth client configured from $GOOGLE_CLIENT"
else
    echo "No Google OAuth client at $GOOGLE_CLIENT; calendar features are off in this build."
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
python3 scripts/check-voice-previews.py
mkdir -p "$APP/Contents/Resources/VoicePreviews"
cp Resources/VoicePreviews/*.wav "$APP/Contents/Resources/VoicePreviews/"
if [[ -n "${MEETING_SIGNING_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --entitlements Resources/MeetingAssistant.entitlements --sign "$MEETING_SIGNING_IDENTITY" "$APP"
else
    SIGNING_DIRECTORY="$HOME/Library/Application Support/MeetingAssistant/DevelopmentSigning"
    SIGNING_IDENTITY=$(swift -suppress-warnings scripts/prepare-signing.swift "$SIGNING_DIRECTORY")
    codesign --force --timestamp=none --keychain "$SIGNING_DIRECTORY/development.keychain-db" --sign "$SIGNING_IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "Built $APP"
