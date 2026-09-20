#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Build the app before packaging.
# Beta filenames require matching inputs and the current public master on GitHub.
BETA_REVISION=""
if [[ "${MIPAD_BETA:-0}" == "1" ]]; then
    export MIPAD_REQUIRE_GIT_REVISION=1
    BETA_REVISION="$(python3 scripts/build-revision.py)"
    REMOTE_REVISION="$(git ls-remote https://github.com/L245T/mipad2mac.git refs/heads/master | cut -f1)"
    [[ "$BETA_REVISION" == "$REMOTE_REVISION" ]] || { echo "Public master does not match; refusing Beta filename." >&2; exit 1; }
fi
DMGBUILD="${MIPAD_DMGBUILD:-dmgbuild}"
command -v "$DMGBUILD" >/dev/null 2>&1 || { echo "Install dmgbuild 1.6.7 and set MIPAD_DMGBUILD to its executable; see docs/PUBLISHING.md." >&2; exit 1; }
OUTPUT_DIR="${MIPAD_OUTPUT_DIR:-$PWD/dist}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
if [[ -n "${MIPAD_APP_PATH:-}" ]]; then
    [[ "${MIPAD_BETA:-0}" != "1" ]] || { echo "Prebuilt app packaging cannot prove Beta input matching." >&2; exit 1; }
    APP="$MIPAD_APP_PATH"
    [[ -d "$APP" && ! -L "$APP" ]] || { echo "Invalid prebuilt app." >&2; exit 1; }
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" == "org.mipad2mac.app" ]] || { echo "Unexpected bundle identifier." >&2; exit 1; }
else
    MIPAD_OUTPUT_DIR="$OUTPUT_DIR" bash scripts/build-app.sh
    APP="$OUTPUT_DIR/MiPad2Mac.app"
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
WORK="$(mktemp -d "$OUTPUT_DIR/.dmg.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/content"
ditto "$APP" "$WORK/content/MiPad2Mac.app"
swift -module-cache-path "$PWD/.build/module-cache" scripts/dmg-background.swift "$WORK/background@2x.png"
sips -z 440 660 -s dpiWidth 72 -s dpiHeight 72 "$WORK/background@2x.png" --out "$WORK/background.png" >/dev/null
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$WORK/content/background.tiff"
cat > "$WORK/content/安装说明.txt" <<'TEXT'
MiPad2Mac 安装说明

1. 如旧版本正在运行，先从 MiPad2Mac 菜单正常退出。
2. 将 MiPad2Mac.app 拖入 Applications（应用程序），然后推出此磁盘映像。
3. 从应用程序文件夹启动，在“权限检查”页完成授权。
4. 默认选择已识别的平板屏幕，权限齐全时自动启用鼠标控制。当前仅支持触控笔输入。

请不要直接在磁盘映像中运行应用。更换安装路径后若系统权限不生效，
请在系统设置中核对授权的应用路径。
TEXT
if [[ -n "${MIPAD_INSTALL_NOTES_FILE:-}" ]]; then
    [[ -f "$MIPAD_INSTALL_NOTES_FILE" ]] || { echo "Missing installation notes." >&2; exit 1; }
    cp "$MIPAD_INSTALL_NOTES_FILE" "$WORK/content/安装说明.txt"
fi
"$DMGBUILD" -s scripts/dmg-settings.py -D "content=$WORK/content" "MiPad2Mac $VERSION" "$WORK/package.dmg"
hdiutil verify "$WORK/package.dmg"
PACKAGE_VERSION="$VERSION"
if [[ "${MIPAD_BETA:-0}" == "1" ]]; then
    [[ "$BETA_REVISION" == "$(python3 scripts/build-revision.py)" ]] || { echo "Inputs changed during packaging." >&2; exit 1; }
    SHORT_REVISION="$(git -C "${MIPAD_REVISION_REPO:-$PWD}" rev-parse --short=7 "$BETA_REVISION")"
    if [[ "$VERSION" == *-beta* ]]; then
        PACKAGE_VERSION="$VERSION.$SHORT_REVISION"
    else
        PACKAGE_VERSION="$VERSION-beta.$SHORT_REVISION"
    fi
fi
DEST="$OUTPUT_DIR/MiPad2Mac-$PACKAGE_VERSION.dmg"
[[ ! -e "$DEST" || "${MIPAD_APP_PATH:-}" == "" ]] || { echo "Refusing to overwrite a prebuilt-package output." >&2; exit 1; }
mv "$WORK/package.dmg" "$DEST"
if [[ "${MIPAD_DEFER_CHECKSUM:-0}" != "1" ]]; then
    (cd "$OUTPUT_DIR" && shasum -a 256 "MiPad2Mac-$PACKAGE_VERSION.dmg") > "$DEST.sha256"
fi
printf '%s\n' "$DEST"
