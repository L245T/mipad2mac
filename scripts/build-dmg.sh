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
bash scripts/build-app.sh
APP="$PWD/dist/MiPad2Mac.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
WORK="$(mktemp -d "$PWD/dist/.dmg.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/content"
ditto "$APP" "$WORK/content/MiPad2Mac.app"
ln -s /Applications "$WORK/content/Applications"
cat > "$WORK/content/安装说明.txt" <<'TEXT'
MiPad2Mac 安装说明

1. 如旧版本正在运行，先从 MiPad2Mac 菜单正常退出。
2. 将 MiPad2Mac.app 拖入 Applications（应用程序），然后推出此磁盘映像。
3. 从应用程序文件夹启动，在“权限检查”页完成授权。
4. 默认选择已识别的平板屏幕，权限齐全时自动启用鼠标控制。当前仅支持触控笔输入。

请不要直接在磁盘映像中运行应用。更换安装路径后若系统权限不生效，
请在系统设置中核对授权的应用路径。
TEXT
hdiutil create -volname "MiPad2Mac $VERSION" -srcfolder "$WORK/content" -format UDZO -ov "$WORK/package.dmg"
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
DEST="$PWD/dist/MiPad2Mac-$PACKAGE_VERSION.dmg"
mv "$WORK/package.dmg" "$DEST"
(cd "$PWD/dist" && shasum -a 256 "MiPad2Mac-$PACKAGE_VERSION.dmg") > "$DEST.sha256"
printf '%s\n' "$DEST"
