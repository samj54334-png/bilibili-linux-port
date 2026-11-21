#!/bin/sh
# 便携安装脚本：把哔哩哔哩客户端装进 ~/.local（或 $PREFIX），不需要 root、不需要包管理器。
# 适用于任何 glibc x86_64 发行版。
#
#   ./install.sh              安装到 ~/.local
#   PREFIX=/usr/local ./install.sh   安装到指定前缀（需要写权限）
#   ./install.sh --uninstall  卸载

set -e

SRC=$(cd "$(dirname "$0")" && pwd)
PREFIX=${PREFIX:-$HOME/.local}
DEST=$PREFIX/opt/bililinux
BIN_DIR=$PREFIX/bin
APP_DIR=$PREFIX/share/applications
ICON_DIR=$PREFIX/share/icons/hicolor/512x512/apps

say() { printf '\033[36m==> %s\033[0m\n' "$*"; }

uninstall() {
  say "移除 $DEST"
  rm -rf "$DEST"
  rm -f "$BIN_DIR/bililinux"
  rm -f "$APP_DIR/bililinux.desktop"
  rm -f "$ICON_DIR/bililinux.png"
  update-desktop-database -q "$APP_DIR" 2>/dev/null || true
  gt-update-icon-cache -q "$PREFIX/share/icons/hicolor" 2>/dev/null || \
    gtk-update-icon-cache -q "$PREFIX/share/icons/hicolor" 2>/dev/null || true
  echo "已卸载。用户数据仍保留在 ~/.config/bilibili（如需清除请手动删除）。"
}

case "${1:-}" in
  --uninstall|-u) uninstall; exit 0 ;;
  --help|-h) sed -n '2,10p' "$0"; exit 0 ;;
esac

[ -d "$SRC/runtime" ] || { echo "缺少 runtime/，请在解压后的目录里运行本脚本" >&2; exit 1; }

say "安装到 $DEST"
mkdir -p "$DEST" "$BIN_DIR" "$APP_DIR" "$ICON_DIR"
rm -rf "$DEST/app" "$DEST/runtime" "$DEST/shim" "$DEST/bin"
cp -a "$SRC/app" "$SRC/runtime" "$SRC/shim" "$SRC/bin" "$DEST"/
[ -f "$SRC/bililinux.png" ] && cp -a "$SRC/bililinux.png" "$ICON_DIR/bililinux.png"

say "创建启动命令 $BIN_DIR/bililinux"
ln -sf "$DEST/bin/bililinux" "$BIN_DIR/bililinux"

say "注册桌面项"
cat > "$APP_DIR/bililinux.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=哔哩哔哩
GenericName=Bilibili
Comment=哔哩哔哩 PC 客户端（Linux 移植版）
Exec=$DEST/bin/bililinux %U
Icon=bililinux
Terminal=false
Categories=AudioVideo;Video;Network;
Keywords=bilibili;b站;哔哩哔哩;video;
StartupNotify=true
EOF

update-desktop-database -q "$APP_DIR" 2>/dev/null || true
gtk-update-icon-cache -q "$PREFIX/share/icons/hicolor" 2>/dev/null || true

say "完成"
echo "启动：$BIN_DIR/bililinux   （或从应用菜单打开「哔哩哔哩」）"
echo "注意：用户级安装时 chrome-sandbox 不是 setuid，启动器会自动加 --no-sandbox。"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "提示：$BIN_DIR 不在 PATH 中，可加入 ~/.profile：export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac
