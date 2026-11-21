#!/bin/bash
# 从官方 Windows 安装包构建 Linux deb 包
#   用法: bash scripts/build-deb.sh [官方安装包路径]
#   依赖: 7zz(或7z) / dpkg-deb / asar(可选, 仅在需要重新解包时)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-/tmp/bili-deb-build}
DEBROOT=$WORK/deb
OUT=$ROOT/dist
VERSION=${VERSION:-1.20.0}

SRC_ASAR=${SRC_ASAR:-/tmp/bili-port/run/resources/app.asar}
SRC_UNPACKED=${SRC_UNPACKED:-/tmp/bili-port/run/resources/app.asar.unpacked}
ELECTRON_DIST=${ELECTRON_DIST:-$ROOT/../bililinux/node_modules/electron/dist}

say() { printf '\033[36m==> %s\033[0m\n' "$*"; }

[ -f "$SRC_ASAR" ] || { echo "找不到 app.asar: $SRC_ASAR" >&2; exit 1; }
[ -x "$ELECTRON_DIST/electron" ] || { echo "找不到 Electron 运行时: $ELECTRON_DIST" >&2; exit 1; }

say "清理构建目录"
rm -rf "$WORK"
mkdir -p "$DEBROOT/opt/bililinux" "$DEBROOT/usr/bin" \
         "$DEBROOT/usr/share/applications" \
         "$DEBROOT/usr/share/icons/hicolor/512x512/apps" \
         "$DEBROOT/DEBIAN"

say "复制 Electron 运行时"
cp -a "$ELECTRON_DIST" "$DEBROOT/opt/bililinux/runtime"
rm -rf "$DEBROOT/opt/bililinux/runtime/resources/app" 2>/dev/null || true

say "复制官方 app.asar"
mkdir -p "$DEBROOT/opt/bililinux/app"
cp -a "$SRC_ASAR" "$DEBROOT/opt/bililinux/app/app.asar"
[ -d "$SRC_UNPACKED" ] && cp -a "$SRC_UNPACKED" "$DEBROOT/opt/bililinux/app/app.asar.unpacked"
# electron-updater / 主进程启动时会读它，缺失会在日志里报 Index error
[ -f "${SRC_UPDATE_YML:-/tmp/bili-port/app/resources/app-update.yml}" ] && \
  cp -a "$SRC_UPDATE_YML" "$DEBROOT/opt/bililinux/app/app-update.yml" || true

say "安装启动器与兼容垫片"
install -Dm755 "$ROOT/scripts/bililinux" "$DEBROOT/opt/bililinux/bin/bililinux"
install -Dm755 "$ROOT/shim/sw_vers" "$DEBROOT/opt/bililinux/shim/sw_vers"
ln -sf /opt/bililinux/bin/bililinux "$DEBROOT/usr/bin/bililinux"

install -Dm644 "$ROOT/assets/bililinux.desktop" "$DEBROOT/usr/share/applications/bililinux.desktop"
install -Dm644 "$ROOT/assets/bililinux.png" "$DEBROOT/usr/share/icons/hicolor/512x512/apps/bililinux.png"

say "写入控制信息"
SIZE_KB=$(du -sk "$DEBROOT/opt" | cut -f1)
cat > "$DEBROOT/DEBIAN/control" <<EOF
Package: bililinux
Version: $VERSION
Section: video
Priority: optional
Architecture: amd64
Installed-Size: $SIZE_KB
Depends: libnss3, libgbm1, libasound2t64 | libasound2, libgtk-3-0t64 | libgtk-3-0, libatk-bridge2.0-0t64 | libatk-bridge2.0-0, libxss1, libdrm2, libxkbcommon0, libxcomposite1, libxdamage1, libxrandr2, libcups2, libpango-1.0-0, libcairo2
Maintainer: sam <sam@localhost>
Homepage: https://app.bilibili.com
Description: 哔哩哔哩 PC 客户端（Linux 移植版）
 基于哔哩哔哩官方 Windows 客户端（Electron）移植：
 将官方 app.asar 运行在 Linux 版 Electron 运行时上，
 并提供 macOS 版本探测垫片与本地服务兼容处理。
 非官方构建，仅供个人使用。
EOF

cat > "$DEBROOT/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
# 让 Chromium 使用 setuid 沙箱（否则启动器会退回 --no-sandbox）
if [ -f /opt/bililinux/runtime/chrome-sandbox ]; then
  chown root:root /opt/bililinux/runtime/chrome-sandbox
  chmod 4755 /opt/bililinux/runtime/chrome-sandbox
fi
update-desktop-database -q /usr/share/applications 2>/dev/null || true
gtk-update-icon-cache -q /usr/share/icons/hicolor 2>/dev/null || true
exit 0
EOF
chmod 755 "$DEBROOT/DEBIAN/postinst"

cat > "$DEBROOT/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
# 退出可能仍在运行的客户端，避免覆盖运行中的文件
pkill -f '/opt/bililinux/runtime/electron' 2>/dev/null || true
exit 0
EOF
chmod 755 "$DEBROOT/DEBIAN/prerm"

mkdir -p "$OUT"
PKG=$OUT/bililinux_${VERSION}_amd64.deb
say "打包 $PKG"
dpkg-deb --root-owner-group -Zxz --build "$DEBROOT" "$PKG" >/dev/null
ls -lh "$PKG"
say "完成。安装: sudo apt install ./$(basename "$PKG")"
