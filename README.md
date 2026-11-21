# bilibili-linux-port

把**哔哩哔哩官方 Windows 客户端**移植到 Linux 的构建工具集。

本仓库**不包含任何官方二进制**。你从官方源下载安装包，在本机自行构建。

> 非官方项目，与上海幻电信息科技有限公司无关。

## 原理

官方客户端是 Electron 应用（v1.20.0 基于 Electron 22.3.27 / Chromium 108，从 exe 的版本串读出）。
因此移植不需要改应用逻辑：

1. 从官方安装包（NSIS）里取出 `app-64.7z` / `app-arm64.7z`，再取出 `resources/app.asar`
2. 用同版本的 **Linux** Electron 运行时加载这个 asar
3. 补三处平台差异（见下），其余原样运行

## 需要修补的三处

| 现象 | 原因 | 处理 |
|---|---|---|
| 启动日志 `sw_vers: not found` | 主进程只区分 win32 与「其他」，非 Windows 一律走 macOS 分支，执行 `execSync('sw_vers')` | `shim/sw_vers` 输出 macOS 版本信息，置于 PATH 前 |
| 第二次启动直接退出，日志 `Exist instance focused!` | Windows 上靠 `http://localhost:22331` 本地服务判断单实例，Linux 上该服务不常驻，但 `.runtime` 里残留该 URL | 启动前 `sed` 删除 `localServer` 字段 |
| 弹窗「程序异常，继续运行可能存在安全风险！错误代码：022」 | 启动自检在非 Windows 环境必然失败（同时会记录 012/022），属于告警而非崩溃 | 可选：在 asar 的 `index.js` 前注入窗口守卫，隐藏标题为 `Error` 或正文含「错误代码」的窗口 |

关于第三点，实测：**不打补丁客户端也能正常工作**（首页、登录、播放器窗口、下载均可用），022 只是自检告警。补丁仅用于消除弹窗。

## 构建

```sh
# 1) 官方安装包（winget 清单里有版本对应的 URL，可核对 sha256）
curl -LO https://dl.hdslb.com/mobile/pack/bili_win/30389763/public/bilibili-setup-v1.20.0.exe

# 2) 解 NSIS → app-64.7z → app.asar
7zz x bilibili-setup-v1.20.0.exe
7zz x 'x/$PLUGINSDIR/app-64.7z' -oapp

# 3) 取 Linux 版 Electron 运行时（版本不必与 Windows 端完全一致，33.4.11 实测可用）
#    https://cdn.npmmirror.com/binaries/electron/33.4.11/electron-v33.4.11-linux-x64.zip

# 4) 打 deb
bash scripts/build-deb.sh
```

`build-deb.sh` 期望这几个位置（可用环境变量覆盖）：

| 变量 | 默认值 |
|---|---|
| `SRC_ASAR` | `/tmp/bili-port/run/resources/app.asar` |
| `SRC_UNPACKED` | `/tmp/bili-port/run/resources/app.asar.unpacked` |
| `ELECTRON_DIST` | `../bililinux/node_modules/electron/dist` |

AppImage 用 zstd 压缩的 squashfs 加 [type2-runtime](https://github.com/AppImage/type2-runtime) 拼装：

```sh
mksquashfs AppDir out.squashfs -root-owned -noappend -comp zstd -Xcompression-level 19 -b 128K
cat runtime-x86_64 out.squashfs > BiliLinux-1.20.0-x86_64.AppImage
```

> 注意：type2-runtime 只支持 zlib 和 zstd，用 xz 压缩会报
> `Squashfs image uses xz compression, this version supports only zlib, zstd`。

## 产物形态

| 格式 | 适用 | 说明 |
|---|---|---|
| AppImage | 任何 glibc ≥ 2.31 的 x86_64/arm64 发行版 | 免安装；FUSE 不可用时 `APPIMAGE_EXTRACT_AND_RUN=1` |
| 便携包 + `install.sh` | 同上 | 装进 `~/.local`，不需要 root |
| deb | Debian / Ubuntu 系 | `postinst` 会把 `chrome-sandbox` 设为 setuid |

arm64 与 x86_64 的差异只有三样：应用载荷（官方 `app-arm64.7z`）、Electron 运行时
（`electron-v33.4.11-linux-arm64.zip`）、AppImage runtime（`runtime-aarch64`）。

## 已知限制

- Windows 专属功能不可用：游戏中心、桌面宠物、原生屏幕采集（`@nut-tree/libnut-win32`）、依赖 22331 本地服务的部分链路
- 自动更新不可用（更新源只提供 Windows 安装包），日志里的 `ENOENT app-update.yml` 属预期
- 依赖网页层 DOM 的功能可能随官方前端改版失效

## 法律

官方客户端 `package.json` 的 license 是 `UNLICENSED`。本仓库只提供构建脚本与兼容垫片，
不包含、也不分发任何官方二进制。请只在你自己的机器上构建和使用，不要把构建产物再分发。

## License

本仓库的脚本以 MIT 发布；哔哩哔哩客户端本身版权归其权利人所有。
