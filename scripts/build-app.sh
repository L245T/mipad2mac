#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build -c release --disable-sandbox --cache-path .build/cache
mkdir -p "$PWD/dist"
STAGING="$(mktemp -d "$PWD/dist/.app-build.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/MiPad2Mac.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
bash scripts/build-icon.sh "$APP/Contents/Resources/MiPad2Mac.icns"
cp .build/release/MiPad2Mac "$APP/Contents/MacOS/MiPad2Mac"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.mipad2mac.app</string>
<key>CFBundleName</key><string>MiPad2Mac</string>
<key>CFBundleExecutable</key><string>MiPad2Mac</string>
<key>CFBundleIconFile</key><string>MiPad2Mac.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.16</string>
<key>CFBundleVersion</key><string>17</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Replace the app only after the build and resource packaging succeed.
DEST="$PWD/dist/MiPad2Mac.app"
if [[ -d "$DEST" ]]; then
    mkdir -p "$PWD/dist/archive"
    ditto -c -k --keepParent "$DEST" "$PWD/dist/archive/MiPad2Mac-before-$(date +%Y%m%d-%H%M%S).zip"
fi
ditto "$APP" "$DEST"
# Refresh only this app's registration after replacing resources at the same path.
touch "$DEST"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$DEST" || printf '%s\n' "Warning: app registration refresh failed; reopen Finder to refresh its icon." >&2
fi
printf '%s\n' "$DEST"
