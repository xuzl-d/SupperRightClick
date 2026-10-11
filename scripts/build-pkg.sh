#!/bin/bash
# 构建 .pkg 安装包（自动安装到 /Applications）
#
# 用法: ./scripts/build-pkg.sh [版本号] [架构...]
#   ./scripts/build-pkg.sh 1.1.0                     → 只含本机架构（默认，推荐）
#   ./scripts/build-pkg.sh 1.1.0 "arm64 x86_64"      → 通用二进制，产物名带 -universal
#
# 关于架构选择（重要）：
#   macOS 26 起 Apple 会主动提示“Intel 架构 App 支持终止”。系统里的 ecosystemagent 会
#   逐个遍历 Mach-O 切片并与首选架构（Apple 芯片为 arm64）比对，因此**通用二进制里的
#   x86_64 切片会让 App 每次启动都弹一次**「此版本包含一个与 macOS 后续版本不兼容的组件」。
#   给 Apple 芯片用户就用默认（单 arm64）——干净无提示；只有确实要发给 Intel Mac 时才出通用包。
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="SuperRightClick"
VERSION="${1:-1.0.0}"
ARCHS="${2:-}"                  # 留空 = 只构建本机架构
PKG_ID="com.superrightclick.app"

# 产物名带架构后缀：通用包加 -universal，其它非默认架构直接带上架构名
ARCH_TAG=""
case "$ARCHS" in
    "arm64 x86_64"|"x86_64 arm64") ARCH_TAG="-universal" ;;
    ""|"arm64"|"$(uname -m)")      ARCH_TAG="" ;;
    *)                             ARCH_TAG="-$(echo "$ARCHS" | tr ' ' '-')" ;;
esac

echo "==> 构建 App (release + 稳定签名, 架构: ${ARCHS:-本机})"
./scripts/build-app.sh release "$ARCHS" >/dev/null
echo "==> 二进制架构: $(lipo -archs "dist/$APP_NAME.app/Contents/MacOS/$APP_NAME")"

# 部署目标闸门：必须是 13.0。
# 为什么必须卡：用 `swiftc` 直接编译（绕过 SwiftPM）时，最低系统版本会默认成**主机系统版本**
# （实测在 macOS 27 上编出 minos=28.0），于是 App 在较低系统上连启动都起不来 ——
# 表现就是「安装完啥也没有」。这里一旦不对就直接失败，不让这种包发出去。
BIN="dist/$APP_NAME.app/Contents/MacOS/$APP_NAME"
MINOS="$(otool -l "$BIN" | grep -A4 LC_BUILD_VERSION | awk '/minos/{print $2; exit}')"
if [ "$MINOS" != "13.0" ]; then
    echo "❌ 部署目标异常：minos=$MINOS（应为 13.0）。"
    echo "   这会让 App 在较低 macOS 上无法启动。SwiftPM 构建应在 Package.swift 里声明"
    echo "   platforms: [.macOS(.v13)]；手工 swiftc 构建必须显式加 -target arm64-apple-macos13.0。"
    exit 1
fi
echo "==> 部署目标: minos $MINOS ✅"

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
# 2) 清除隔离属性（quarantine）：带着它运行会被 Gatekeeper「随机路径化」(App Translocation)，
#    而那种情况下辅助功能授权无法生效 —— 客户会一直看到「未授权」。postinstall 是 root，可写。
xattr -dr com.apple.quarantine "/Applications/SuperRightClick.app" 2>/dev/null || true
# 3) 以当前登录用户会话启动新版（postinstall 以 root 运行，需切换会话）
CONSOLE_UID="$(stat -f '%u' /dev/console 2>/dev/null || echo '')"
if [ -n "$CONSOLE_UID" ] && [ "$CONSOLE_UID" != "0" ]; then
    launchctl asuser "$CONSOLE_UID" open "/Applications/SuperRightClick.app" 2>/dev/null || true
fi
exit 0
EOF
chmod +x "$SCRIPTS/postinstall"

echo "==> 打包 pkg"
PKG_PATH="dist/$APP_NAME-$VERSION$ARCH_TAG.pkg"
pkgbuild \
    --root "$PAYLOAD" \
    --scripts "$SCRIPTS" \
    --identifier "$PKG_ID" \
    --version "$VERSION" \
    --install-location / \
    "$PKG_PATH"

rm -rf "$PAYLOAD" "$SCRIPTS"

# 防止安装时被 PackageKit「重定位」：若开发机上的 dist 副本已注册，
# 安装器会把安装重定向到 dist 而不是 /Applications。先注销再装。
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -u "$PWD/dist/$APP_NAME.app" >/dev/null 2>&1 || true

echo "==> 完成: $PKG_PATH"
echo "安装: open \"$PKG_PATH\""
echo "提示: 安装前请确保本机未从 dist/ 运行过本 App（避免被重定位）"
