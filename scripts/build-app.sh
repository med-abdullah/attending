#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
source scripts/sdk.sh
# Local overrides (bundle ID, signing identity) live in an uncommitted file.
BUNDLE_ID="${BUNDLE_ID:-app.attending.Attending}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Attending Local Signing}"
# Public release builds (scripts/release.sh) ignore local overrides.
[[ -f scripts/local.env && -z "${ATTENDING_RELEASE:-}" ]] && source scripts/local.env
VERSION=$(<VERSION)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
configuration=${1:-debug}
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$PWD/.build/cache"
swift build --disable-sandbox --cache-path "$PWD/.build/cache" -c "$configuration"
bin_dir=$(swift build --disable-sandbox --cache-path "$PWD/.build/cache" -c "$configuration" --show-bin-path)
app="$PWD/build/Attending.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/Attending" "$app/Contents/MacOS/Attending.new"
mv "$app/Contents/MacOS/Attending.new" "$app/Contents/MacOS/Attending"
cp "$bin_dir/attending-bridge" "$app/Contents/MacOS/attending-bridge.new"
mv "$app/Contents/MacOS/attending-bridge.new" "$app/Contents/MacOS/attending-bridge"
cp "$bin_dir/libAttendingMedia.dylib" "$app/Contents/Resources/libAttendingMedia.dylib"
cp "$PWD/Assets/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
# Release notes, for What's New after an update.
cp "$PWD/CHANGELOG.md" "$app/Contents/Resources/CHANGELOG.md"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>Attending</string>
<key>CFBundleDisplayName</key><string>Attending</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleExecutable</key><string>Attending</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>LSMinimumSystemVersion</key><string>14.2</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSCalendarsFullAccessUsageDescription</key><string>Attending shows your next event in the notch. Events never leave this Mac.</string>
<key>NSRemindersFullAccessUsageDescription</key><string>Attending shows your Apple Reminders in the notch and checks them off when you do. Reminders never leave this Mac.</string>
<key>NSRemindersUsageDescription</key><string>Attending shows your Apple Reminders in the notch and checks them off when you do. Reminders never leave this Mac.</string>
<key>NSCameraUsageDescription</key><string>Attending shows a camera mirror in the notch only while you have it open.</string>
<key>NSLocationUsageDescription</key><string>Attending uses your approximate location for the weather and prayer times.</string>
<key>NSLocationWhenInUseUsageDescription</key><string>Attending uses your approximate location for the weather and prayer times.</string>
<key>NSAudioCaptureUsageDescription</key><string>Attending listens to system audio only to animate its visualizer while music plays. Nothing is recorded or saved.</string>
<key>NSAppleEventsUsageDescription</key><string>Attending uses this for Spotify and Apple Music controls in the notch.</string>
</dict></plist>
PLIST
# A stable local identity keeps macOS privacy grants across updates (see
# scripts/create-signing-identity.sh); fall back to ad-hoc signing without it.
identity="$SIGN_IDENTITY"
security find-certificate -c "$identity" >/dev/null 2>&1 || identity="-"
# Every build runs with the hardened runtime that notarization requires, so anything it
# would break shows up here first. Developer ID builds also get a secure timestamp.
runtime=(--options runtime)
[[ "$identity" == "Developer ID Application"* ]] && runtime+=(--timestamp)
codesign --force "${runtime[@]}" --sign "$identity" "$app/Contents/MacOS/attending-bridge"
codesign --force "${runtime[@]}" --sign "$identity" "$app/Contents/Resources/libAttendingMedia.dylib"
codesign --force "${runtime[@]}" --entitlements scripts/Attending.entitlements --sign "$identity" "$app"
printf '%s\n' "$app"
