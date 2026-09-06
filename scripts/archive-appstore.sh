#!/bin/bash
# Archive SwiftMind for the Mac App Store and export an uploadable .pkg.
#
# Prerequisites (one-time, in Xcode / App Store Connect):
#   1. Xcode > Settings > Accounts: add the Apple ID for team 5MFYYSM9G3.
#   2. App Store Connect > Apps > New App: platform macOS, bundle ID
#      app.swiftmind.mac, name SwiftMind (registers the app record).
#   Then: scripts/archive-appstore.sh and upload the resulting .pkg with
#   Transporter (or Xcode Organizer > Distribute App > App Store Connect).
set -euo pipefail
cd "$(dirname "$0")/../Apps/SwiftMindMac"

TEAM_ID="5MFYYSM9G3"
ARCHIVE_PATH="/tmp/SwiftMindAppStore.xcarchive"
EXPORT_DIR="/tmp/SwiftMindAppStoreExport"

xcodegen generate
../../scripts/patch-xcode-scheme.sh

rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR"

echo "==> Archiving (Release, App Store entitlements, team $TEAM_ID)…"
xcodebuild archive \
  -project SwiftMindMac.xcodeproj \
  -scheme SwiftMindMac \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination 'generic/platform=macOS' \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_ENTITLEMENTS="SwiftMindMac/SwiftMindMac-AppStore.entitlements"

EXPORT_OPTIONS=/tmp/swiftmind-export-options.plist
cat > "$EXPORT_OPTIONS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PLIST 1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>export</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>5MFYYSM9G3</string>
</dict>
</plist>
PLIST

echo "==> Exporting .pkg…"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -allowProvisioningUpdates

echo "==> Done. Upload $EXPORT_DIR/SwiftMind.pkg with Transporter,"
echo "    then finish metadata/pricing/screenshots in App Store Connect and submit for review."
