#!/bin/bash
# 构建并打包 SuperRightClick.app
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="SuperRightClick"
CONFIG="${1:-release}"

echo "==> 构建 ($CONFIG)"
swift build -c "$CONFIG"

BIN="$(find .build -type f -name "$APP_NAME" -path "*$CONFIG/*" | head -n 1)"
if [ -z "$BIN" ]; then
    echo "错误：未找到二进制文件" >&2
    exit 1
fi
echo "==> 二进制: $BIN"

APP="dist/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Info.plist "$APP/Contents/Info.plist"

# App 图标（若已生成）
if [ -f Assets/AppIcon.icns ]; then
    cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# 规范化权限：目录 755 / 文件 644 / 可执行 755
# （防止源文件 600 权限被带进 bundle，安装后普通用户读不了 Info.plist）
find "$APP" -type d -exec chmod 755 {} \;
find "$APP" -type f -exec chmod 644 {} \;
chmod 755 "$APP/Contents/MacOS/$APP_NAME"

echo "==> 签名（稳定自签名证书）"
IDENTITY="$(./scripts/sign.sh)"
KEYCHAIN_PATH="$HOME/Library/Keychains/superrightclick-dev.keychain-db"
# codesign 只搜索钥匙串搜索列表，故先把专用钥匙串加入列表并解锁
security list-keychains -d user -s "$KEYCHAIN_PATH" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1 || true
security unlock-keychain -p superrightclick-dev "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --verbose=2 "$APP" 2>&1 | head -2

echo "==> 完成: $APP"
echo "运行: open \"$APP\""
