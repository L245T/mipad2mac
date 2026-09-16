#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Build and sign the app first; never re-sign with a different identity while packaging.
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
3. 从应用程序文件夹启动，按照“使用指引”选择平板显示器、检查权限。
4. 只有点击“启用鼠标控制”后程序才接管笔输入；手指输入尚未解决。

本包使用本地开发证书签名，不是 Developer ID 公证发行版。
其他 Mac 可能出现系统安全提示；DMG 打包本身不代表已获 Apple 公证。
请不要直接在磁盘映像中运行应用。更换安装路径后若系统权限不生效，
请在系统设置中核对授权的应用路径。
TEXT
codesign --verify --deep --strict "$WORK/content/MiPad2Mac.app"
hdiutil create -volname "MiPad2Mac $VERSION" -srcfolder "$WORK/content" -format UDZO -ov "$WORK/package.dmg"
hdiutil verify "$WORK/package.dmg"
DEST="$PWD/dist/MiPad2Mac-$VERSION.dmg"
mv "$WORK/package.dmg" "$DEST"
shasum -a 256 "$DEST" > "$DEST.sha256"
printf '%s\n' "$DEST"
