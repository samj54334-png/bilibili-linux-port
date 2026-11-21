#!/usr/bin/env bash
# bilibili-linux-port 一键构建脚本
#
# 官方客户端安装包由你自己从官方源下载，本脚本只负责在**你的机器上**
# 把它转换成适合你系统的格式。脚本本身不含任何哔哩哔哩代码。
#
# 用法：
#   一键：  curl -fsSL https://raw.githubusercontent.com/samj54334-png/bilibili-linux-port/main/build.sh | bash
#   克隆后：./build.sh [选项]
#
# 选项：
#   --format appimage|deb|portable|auto   目标格式（默认 auto）
#   --arch   auto|x64|arm64               目标架构（默认 auto = 本机）
#   --install                             构建后立即安装
#   --out DIR                             产物输出目录（默认当前目录）
#   --keep                                保留中间文件
#   --help

set -euo pipefail

# ------------------------------------------------------------------ 常量
APP_VERSION="1.20.0"
# 官方安装包（来自 microsoft/winget-pkgs 的 manifest，可自行核对）
INSTALLER_URL="https://dl.hdslb.com/mobile/pack/bili_win/30389763/public/bilibili-setup-v${APP_VERSION}.exe"
INSTALLER_SHA256="1dfdea7d7ebb11405b80084fcce94d9fc06c002b9c527a4f57397753dd753372"

ELECTRON_VERSION="33.4.11"
ELECTRON_MIRROR="https://cdn.npmmirror.com/binaries/electron/${ELECTRON_VERSION}"
ELECTRON_GITHUB="https://github.com/electron/electron/releases/download/v${ELECTRON_VERSION}"

APPIMAGE_RUNTIME_BASE="https://github.com/AppImage/type2-runtime/releases/download/continuous"
SEVENZIP_URL_X64="https://www.7-zip.org/a/7z2301-linux-x64.tar.xz"
SEVENZIP_URL_ARM64="https://www.7-zip.org/a/7z2301-linux-arm64.tar.xz"

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/bililinux-build"
WORK_DIR=""
OUT_DIR="$(pwd)"
FORMAT="auto"
ARCH="auto"
DO_INSTALL=0
KEEP=0

# ------------------------------------------------------------------ 输出
c_info() { printf '\033[36m==> %s\033[0m\n' "$*" >&2; }
c_warn() { printf '\033[33m!!  %s\033[0m\n' "$*" >&2; }
c_err()  { printf '\033[31mxx  %s\033[0m\n' "$*" >&2; }
die()    { c_err "$*"; exit 1; }

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# ------------------------------------------------------------------ 参数
while [ $# -gt 0 ]; do
  case "$1" in
    --format)  FORMAT="${2:?}"; shift 2 ;;
    --arch)    ARCH="${2:?}";   shift 2 ;;
    --out)     OUT_DIR="${2:?}"; shift 2 ;;
    --install) DO_INSTALL=1; shift ;;
    --keep)    KEEP=1; shift ;;
    --help|-h) usage ;;
    *) die "未知参数：$1（--help 查看用法）" ;;
  esac
done

# ------------------------------------------------------------------ 环境探测
detect_arch() {
  [ "$ARCH" = auto ] || return 0
  case "$(uname -m)" in
    x86_64|amd64)  ARCH=x64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) die "不支持的架构：$(uname -m)" ;;
  esac
}

detect_format() {
  [ "$FORMAT" = auto ] || return 0
  if command -v dpkg-deb >/dev/null 2>&1 && [ -f /etc/debian_version ]; then
    FORMAT=deb
  elif command -v mksquashfs >/dev/null 2>&1; then
    FORMAT=appimage
  else
    FORMAT=portable
  fi
}

fetch() { # fetch URL DEST —— 先直连，失败再退回 IPv4（部分网络到 GitHub 的 IPv6 路由不通）
  local url=$1 dest=$2
  [ -s "$dest" ] && return 0
  mkdir -p "$(dirname "$dest")"

  _fetch_once() { # $1 = 额外参数（可为空）
    if command -v curl >/dev/null 2>&1; then
      curl -fL --retry 2 --connect-timeout 15 ${1:-} -o "$dest.part" "$url"
    elif command -v wget >/dev/null 2>&1; then
      wget -q --tries=2 --timeout=25 ${1:-} -O "$dest.part" "$url"
    else
      die "需要 curl 或 wget"
    fi
  }

  if _fetch_once "" && [ -s "$dest.part" ]; then mv "$dest.part" "$dest"; return 0; fi
  rm -f "$dest.part"
  c_warn "直连失败，改用 IPv4 重试：$(basename "$dest")"
  if _fetch_once "-4" && [ -s "$dest.part" ]; then mv "$dest.part" "$dest"; return 0; fi
  rm -f "$dest.part"
  return 1
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else echo unknown; fi
}

need_tools() {
  command -v unzip >/dev/null 2>&1 || die "缺少 unzip，请先安装（apt install unzip / dnf install unzip）"
  case "$FORMAT" in
    deb)      command -v dpkg-deb >/dev/null 2>&1 || die "deb 格式需要 dpkg-deb（仅 Debian/Ubuntu 系）" ;;
    appimage) command -v mksquashfs >/dev/null 2>&1 || die "AppImage 格式需要 mksquashfs（apt install squashfs-tools）" ;;
  esac
}

# ------------------------------------------------------------------ 工具：7-Zip
# 系统自带的 7z 往往是 p7zip 16.x，解不了新版 NSIS 安装包
# （报 "Unsupported archive type"），所以这里固定下载官方 7zz。
get_7zz() {
  local dest="$CACHE_DIR/7zz"
  if [ -x "$dest" ]; then echo "$dest"; return; fi
  local url
  case "$(uname -m)" in
    aarch64|arm64) url="$SEVENZIP_URL_ARM64" ;;
    *)             url="$SEVENZIP_URL_X64" ;;
  esac
  c_info "下载 7-Zip（用于解 NSIS 安装包）"
  fetch "$url" "$CACHE_DIR/7z.tar.xz" || die "7-Zip 下载失败"
  tar -xf "$CACHE_DIR/7z.tar.xz" -C "$CACHE_DIR" || die "7-Zip 解压失败"
  [ -x "$CACHE_DIR/7zz" ] || die "7-Zip 可执行文件缺失"
  echo "$CACHE_DIR/7zz"
}

# ------------------------------------------------------------------ 步骤
get_installer() {
  local dest="$CACHE_DIR/bilibili-setup-v${APP_VERSION}.exe"
  if [ -s "$dest" ]; then
    local got; got=$(sha256_of "$dest")
    [ "$got" = "$INSTALLER_SHA256" ] && { echo "$dest"; return; }
    c_warn "缓存校验失败，重新下载"; rm -f "$dest"
  fi
  c_info "下载官方安装包 v${APP_VERSION}（约 200 MB，之后会复用缓存）"
  fetch "$INSTALLER_URL" "$dest" || die "安装包下载失败：$INSTALLER_URL"
  local got; got=$(sha256_of "$dest")
  if [ "$got" != "$INSTALLER_SHA256" ]; then
    die "安装包校验失败（实际 ${got:-unknown}），已删除。可能是官方已更新版本，请核对 URL 与 sha256"
  fi
  echo "$dest"
}

extract_asar() { # extract_asar INSTALLER DEST_DIR
  local exe=$1 dest=$2 z7
  z7=$(get_7zz)
  c_info "解 NSIS 安装包"
  rm -rf "$WORK_DIR/nsis" && mkdir -p "$WORK_DIR/nsis"
  "$z7" x -y -o"$WORK_DIR/nsis" "$exe" >/dev/null 2>&1 || die "NSIS 解包失败"

  local payload
  if [ "$ARCH" = arm64 ]; then payload="$WORK_DIR/nsis/\$PLUGINSDIR/app-arm64.7z"; else payload="$WORK_DIR/nsis/\$PLUGINSDIR/app-64.7z"; fi
  [ -f "$payload" ] || die "安装包里找不到 $payload（架构不匹配？）"

  c_info "解应用载荷（$ARCH）"
  rm -rf "$WORK_DIR/appwin" && mkdir -p "$WORK_DIR/appwin"
  "$z7" x -y -o"$WORK_DIR/appwin" "$payload" >/dev/null 2>&1 || die "app 载荷解包失败"
  [ -f "$WORK_DIR/appwin/resources/app.asar" ] || die "载荷里没有 resources/app.asar"

  mkdir -p "$dest"
  cp "$WORK_DIR/appwin/resources/app.asar" "$dest/app.asar"
  [ -d "$WORK_DIR/appwin/resources/app.asar.unpacked" ] && cp -a "$WORK_DIR/appwin/resources/app.asar.unpacked" "$dest/"
  printf 'provider: generic\nurl: https://api.bilibili.com/x/elec-frontend/update/\nupdaterCacheDirName: bilibili-updater\n' > "$dest/app-update.yml"
}

get_electron() { # get_electron DEST_DIR
  local dest=$1 name="electron-v${ELECTRON_VERSION}-linux-${ARCH}.zip"
  c_info "获取 Linux Electron 运行时 ${ELECTRON_VERSION}（${ARCH}）"
  if ! fetch "$ELECTRON_MIRROR/$name" "$CACHE_DIR/$name"; then
    c_warn "镜像失败，改用 GitHub"
    fetch "$ELECTRON_GITHUB/$name" "$CACHE_DIR/$name" || die "Electron 运行时下载失败"
  fi
  rm -rf "$dest" && mkdir -p "$dest"
  unzip -q "$CACHE_DIR/$name" -d "$dest" || die "Electron 解压失败"
  chmod +x "$dest/electron"
}

write_launcher() { # write_launcher DIR
  local dir=$1
  mkdir -p "$dir/bin" "$dir/shim"
  cat > "$dir/bin/bililinux" <<'LAUNCHER'
#!/bin/sh
# 哔哩哔哩客户端 Linux 启动器
set -e
SELF=$0
while [ -h "$SELF" ]; do
  DIR=$(cd -P "$(dirname "$SELF")" >/dev/null 2>&1 && pwd)
  SELF=$(readlink "$SELF")
  case $SELF in /*) ;; *) SELF=$DIR/$SELF ;; esac
done
ROOT=$(cd -P "$(dirname "$SELF")/.." >/dev/null 2>&1 && pwd)

DATA_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/bilibili
RUNTIME_FILE=$DATA_DIR/.runtime
# Windows 上靠 http://localhost:22331 判断单实例；Linux 上该服务不常驻，
# 残留这条记录会直接退出，所以启动前剥掉。
[ -f "$RUNTIME_FILE" ] && sed -i 's#http://localhost:22331##g' "$RUNTIME_FILE" 2>/dev/null || true

export ELECTRON_FORCE_IS_PACKAGED=true
export APPIMAGE=1
export PATH="$ROOT/shim:$PATH"

# 非 win32 平台一律走 macOS 分支，会执行 execSync('sw_vers')
SANDBOX=
[ -u "$ROOT/runtime/chrome-sandbox" ] || SANDBOX=--no-sandbox

exec "$ROOT/runtime/electron" "$ROOT/app/app.asar" $SANDBOX "$@"
LAUNCHER
  chmod +x "$dir/bin/bililinux"

  cat > "$dir/shim/sw_vers" <<'SHIM'
#!/bin/sh
case "$1" in
  -productVersion) echo "14.5" ;;
  -buildVersion)   echo "23F79" ;;
  -productName)    echo "macOS" ;;
  *) printf 'ProductName:\t\tmacOS\nProductVersion:\t\t14.5\nBuildVersion:\t\t23F79\n' ;;
esac
SHIM
  chmod +x "$dir/shim/sw_vers"

  cat > "$dir/bililinux.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=哔哩哔哩
Comment=哔哩哔哩 PC 客户端（Linux 移植版）
Exec=bililinux %U
Terminal=false
Categories=AudioVideo;Video;Network;
Keywords=bilibili;b站;哔哩哔哩;video;
DESKTOP
}

assemble() { # assemble APPDIR
  local a=$1
  rm -rf "$a" && mkdir -p "$a/app"
  extract_asar "$INSTALLER" "$a/app"
  get_electron "$a/runtime"
  write_launcher "$a"
  # 用官方包里的图标（仅本机使用）
  if [ -f "$WORK_DIR/appwin/resources/app.asar.unpacked/main/assets/images/icon.png" ]; then :; fi
  printf '#!/bin/sh\nHERE=$(dirname "$(readlink -f "$0")")\nexec "$HERE/bin/bililinux" "$@"\n' > "$a/AppRun"
  chmod +x "$a/AppRun"
}

build_appimage() { # build_appimage APPDIR OUTPUT
  local a=$1 out=$2 rt="$CACHE_DIR/runtime-$ARCH"
  local rtname; [ "$ARCH" = arm64 ] && rtname=runtime-aarch64 || rtname=runtime-x86_64
  c_info "获取 AppImage runtime"
  fetch "$APPIMAGE_RUNTIME_BASE/$rtname" "$rt" || die "AppImage runtime 下载失败"
  c_info "打包 squashfs（zstd，约 1–2 分钟）"
  mksquashfs "$a" "$WORK_DIR/app.squashfs" -root-owned -noappend \
    -comp zstd -Xcompression-level 19 -b 128K -no-progress >/dev/null 2>&1 || die "mksquashfs 失败"
  cat "$rt" "$WORK_DIR/app.squashfs" > "$out"
  chmod +x "$out"
}

build_deb() { # build_deb APPDIR OUTPUT
  local a=$1 out=$2 d="$WORK_DIR/deb"
  local debarch; [ "$ARCH" = arm64 ] && debarch=arm64 || debarch=amd64
  c_info "打包 deb"
  rm -rf "$d"
  mkdir -p "$d/DEBIAN" "$d/opt/bililinux" "$d/usr/bin" "$d/usr/share/applications"
  cp -a "$a/app" "$a/runtime" "$a/shim" "$a/bin" "$d/opt/bililinux"/
  sed 's#^Exec=.*#Exec=/opt/bililinux/bin/bililinux %U#' "$a/bililinux.desktop" > "$d/usr/share/applications/bililinux.desktop"
  ln -sf /opt/bililinux/bin/bililinux "$d/usr/bin/bililinux"
  cat > "$d/DEBIAN/control" <<CONTROL
Package: bililinux
Version: ${APP_VERSION}
Section: video
Priority: optional
Architecture: ${debarch}
Installed-Size: $(du -sk "$d/opt" | cut -f1)
Depends: libnss3, libgbm1, libgtk-3-0t64 | libgtk-3-0, libasound2t64 | libasound2, libatk-bridge2.0-0t64 | libatk-bridge2.0-0, libxss1, libdrm2, libxkbcommon0, libxcomposite1, libxdamage1, libxrandr2, libcups2, libpango-1.0-0, libcairo2
Maintainer: local
Description: 哔哩哔哩 PC 客户端（本机构建的 Linux 移植版）
 由 build.sh 在本地从官方安装包转换生成，仅供本机使用。
CONTROL
  cat > "$d/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
if [ -f /opt/bililinux/runtime/chrome-sandbox ]; then
  chown root:root /opt/bililinux/runtime/chrome-sandbox
  chmod 4755 /opt/bililinux/runtime/chrome-sandbox
fi
update-desktop-database -q /usr/share/applications 2>/dev/null || true
exit 0
POSTINST
  cat > "$d/DEBIAN/prerm" <<'PRERM'
#!/bin/sh
set -e
pkill -f "/opt/bililinux/runtime/electron" 2>/dev/null || true
exit 0
PRERM
  chmod 755 "$d/DEBIAN/postinst" "$d/DEBIAN/prerm"
  dpkg-deb --root-owner-group -Zxz --build "$d" "$out" >/dev/null
}

build_portable() { # build_portable APPDIR OUTPUT
  local a=$1 out=$2 p="$WORK_DIR/portable/bililinux-$APP_VERSION"
  c_info "打包便携版"
  rm -rf "$WORK_DIR/portable" && mkdir -p "$p"
  cp -a "$a/app" "$a/runtime" "$a/shim" "$a/bin" "$p"/
  cat > "$p/install.sh" <<'INSTALLER'
#!/bin/sh
set -e
SRC=$(cd "$(dirname "$0")" && pwd)
PREFIX=${PREFIX:-$HOME/.local}
DEST=$PREFIX/opt/bililinux
rm -rf "$DEST"; mkdir -p "$DEST" "$PREFIX/bin" "$PREFIX/share/applications"
cp -a "$SRC/app" "$SRC/runtime" "$SRC/shim" "$SRC/bin" "$DEST"/
ln -sf "$DEST/bin/bililinux" "$PREFIX/bin/bililinux"
cat > "$PREFIX/share/applications/bililinux.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=哔哩哔哩
Exec=$DEST/bin/bililinux %U
Terminal=false
Categories=AudioVideo;Video;Network;
EOF
update-desktop-database -q "$PREFIX/share/applications" 2>/dev/null || true
echo "已安装到 $DEST，启动命令：$PREFIX/bin/bililinux"
INSTALLER
  chmod +x "$p/install.sh"
  tar czf "$out" -C "$WORK_DIR/portable" "bililinux-$APP_VERSION"
}

install_output() { # install_output FILE FORMAT
  local f=$1 fmt=$2
  case "$fmt" in
    deb)      sudo apt install -y "$f" || sudo dpkg -i "$f" ;;
    portable) tmp=$(mktemp -d); tar xzf "$f" -C "$tmp"; "$tmp"/*/install.sh; rm -rf "$tmp" ;;
    appimage) mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications"
              install -m755 "$f" "$HOME/.local/bin/bililinux.AppImage"
              echo "已放到 ~/.local/bin/bililinux.AppImage，可直接运行" ;;
  esac
}

# ------------------------------------------------------------------ 主流程
main() {
  detect_arch
  detect_format
  need_tools
  mkdir -p "$CACHE_DIR"

  WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/bililinux-build.XXXXXX")
  trap '[ "$KEEP" = 1 ] || rm -rf "$WORK_DIR"' EXIT

  c_info "目标：格式=$FORMAT 架构=$ARCH 输出=$OUT_DIR"
  INSTALLER=$(get_installer)

  local appdir="$WORK_DIR/AppDir"
  assemble "$appdir"

  mkdir -p "$OUT_DIR"
  local aname; [ "$ARCH" = x64 ] && aname=x86_64 || aname=arm64
  local out
  case "$FORMAT" in
    appimage)
      out="$OUT_DIR/BiliLinux-${APP_VERSION}-${aname}.AppImage"
      build_appimage "$appdir" "$out" ;;
    deb)
      local debarch; [ "$ARCH" = arm64 ] && debarch=arm64 || debarch=amd64
      out="$OUT_DIR/bililinux_${APP_VERSION}_${debarch}.deb"
      build_deb "$appdir" "$out" ;;
    portable)
      out="$OUT_DIR/bililinux-${APP_VERSION}-portable-${aname}.tar.gz"
      build_portable "$appdir" "$out" ;;
    *) die "未知格式：$FORMAT" ;;
  esac

  c_info "完成：$out（$(du -h "$out" | cut -f1)）"
  c_info "sha256：$(sha256_of "$out")"
  [ "$DO_INSTALL" = 1 ] && install_output "$out" "$FORMAT"
  echo
  echo "提示：产物内含官方客户端代码，仅供本机使用，请勿再分发。"
}

main
