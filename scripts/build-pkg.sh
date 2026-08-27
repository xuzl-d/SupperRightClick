#!/bin/bash
# 构建 .pkg 安装包（自动安装到 /Applications）
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="SuperRightClick"
VERSION="${1:-1.0.0}"
PKG_ID="com.superrightclick.app"

echo "==> 构建 App (release + 稳定签名)"
./scripts/build-app.sh release >/dev/null

echo "==> 组装安装载荷 (Applications/$APP_NAME.app)"
PAYLOAD="$(mktemp -d)"
mkdir -p "$PAYLOAD/Applications"
cp -R "dist/$APP_NAME.app" "$PAYLOAD/Applications/"

echo "==> 生成 postinstall 脚本（关闭旧实例 + 启动新版）"
SCRIPTS="$(mktemp -d)"
cat > "$SCRIPTS/postinstall" <<'EOF'
#!/bin/bash
# 1) 关闭正在运行的旧实例
pkill -x SuperRightClick 2>/dev/null || true
# 2) 以当前登录用户会话启动新版（postinstall 以 root 运行，需切换会话）
CONSOLE_UID="$(stat -f '%u' /dev/console 2>/dev/null || echo '')"
if [ -n "$CONSOLE_UID" ] && [ "$CONSOLE_UID" != "0" ]; then
    launchctl asuser "$CONSOLE_UID" open "/Applications/SuperRightClick.app" 2>/dev/null || true
fi
exit 0
EOF
chmod +x "$SCRIPTS/postinstall"

echo "==> 打包 pkg"
pkgbuild \
    --root "$PAYLOAD" \
    --scripts "$SCRIPTS" \
    --identifier "$PKG_ID" \
    --version "$VERSION" \
    --install-location / \
    "dist/$APP_NAME-$VERSION.pkg"

rm -rf "$PAYLOAD" "$SCRIPTS"

# 防止安装时被 PackageKit「重定位」：若开发机上的 dist 副本已注册，
# 安装器会把安装重定向到 dist 而不是 /Applications。先注销再装。
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -u "$PWD/dist/$APP_NAME.app" >/dev/null 2>&1 || true

echo "==> 完成: dist/$APP_NAME-$VERSION.pkg"
echo "安装: open \"dist/$APP_NAME-$VERSION.pkg\""
echo "提示: 安装前请确保本机未从 dist/ 运行过本 App（避免被重定位）"
