#!/bin/bash
# 构建并打包 SuperRightClick.app
#
# 用法: ./scripts/build-app.sh [debug|release] [架构...]
#   架构留空      → 只构建本机架构（开发用，快）
#   "arm64 x86_64" → 通用二进制（发给别人用，Intel Mac 也能跑）
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="SuperRightClick"
CONFIG="${1:-release}"
ARCHS="${2:-}"

BUILD_ARGS=(-c "$CONFIG")
for arch in $ARCHS; do
    BUILD_ARGS+=(--arch "$arch")
done

echo "==> 构建 ($CONFIG${ARCHS:+ / $ARCHS})"
swift build "${BUILD_ARGS[@]}"

# 用 --show-bin-path 问 SwiftPM 产物在哪：通用构建的产物位于
# .build/apple/Products/Release，单架构在 .build/<target>/<config>，
# 用 find 猜路径在通用构建下会直接找不到。
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
if [ ! -f "$BIN" ]; then
    echo "错误：未找到二进制文件（${BIN}）" >&2
    exit 1
fi
# 注意：变量后面紧跟全角字符时必须用 ${VAR}，否则 bash 会把全角字节吃进变量名。
echo "==> 二进制: ${BIN}（$(lipo -archs "$BIN" 2>/dev/null || echo '架构未知')）"

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
