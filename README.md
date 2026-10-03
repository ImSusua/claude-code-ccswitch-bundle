# Claude Code CLI + CC Switch 离线合并安装包

一个安装包，同时装好：

| 组件 | 版本 | 说明 |
|---|---|---|
| **Claude Code CLI** | 2.1.287 (win32-x64 原生二进制) | Anthropic 官方 CLI，内嵌完整原生程序，**运行不需要 Node.js** |
| **CC Switch** | 3.20.4 (Windows 便携版) | Claude Code / Codex 供应商(API)配置切换器 GUI |
| **Node.js** | 22.23.3 LTS (便携版) | 依赖组件：本机没有 Node 时自动安装（MCP、npx 等生态需要） |

**全程离线可装** —— 所有资源都内嵌在 `resources/` 目录，安装时不联网。仅当内嵌资源缺失或校验失败时，脚本才自动回退到**国内镜像源**下载（npmmirror、GitHub 加速代理、微软官方 CDN），官方源作最后兜底。

> ⬇️ **下载安装包**：见 [Releases](https://github.com/ImSusua/claude-code-ccswitch-bundle/releases) —— 下载 zip → 解压到任意本地目录 → 双击 `安装.cmd`。本仓库只含脚本源码，完整安装包（含内嵌资源）在 Releases。

---

## 安装方法

1. 把整个压缩包解压到**任意本地目录**（不要在压缩软件里直接双击运行）。
2. 双击 **`安装.cmd`**。全部用户级安装，**不需要管理员权限**。安装完成后会自动打开 CC Switch。
3. **必做**：在 CC Switch 里添加你的 API 供应商（填服务商提供的 **Base URL** 和 **API Key**）并启用切换 —— 这一步不做，`claude` 会直连 Anthropic 官方端点，在国内网络下报 `Status 403` 无法使用。
4. 配置好供应商后，**新开一个终端窗口**输入 `claude` 即可使用（已打开的终端要重开才能识别 PATH 和新配置）。会话内输入 `/status` 可确认当前 Base URL 是否生效。

## 安装了什么、装在哪

| 内容 | 位置 |
|---|---|
| claude.exe | `%LOCALAPPDATA%\Programs\ClaudeCode\`（已加入用户 PATH） |
| Node.js 便携版（仅当本机没有 Node 时） | `%LOCALAPPDATA%\Programs\ClaudeCode-Bundle\node\`（已加入用户 PATH，其 npm 默认走 npmmirror） |
| CC Switch | `%LOCALAPPDATA%\Programs\CC-Switch\`（创建开始菜单 + 桌面快捷方式） |
| 全局中文配置 | 官方 `language` 设置（写入 `~/.claude/settings.json`）+ 全局 `~/.claude/CLAUDE.md` 追加幂等语言规则块 |
| 安装日志 | `%TEMP%\cc-bundle-install.log` |

## 中文说明

安装脚本会做两层中文配置：

1. **官方设置**：在 `~/.claude/settings.json` 写入 `"language": "simplified chinese"`（Claude Code 官方 language 设置，全局生效）；
2. **全局 CLAUDE.md 强化**：在 `~/.claude/CLAUDE.md` 追加带 `<!-- cc-bundle:language BEGIN/END -->` 标记的规则块，确保回复始终是简体中文。该块带标记、幂等，重复安装不会重复追加；卸载脚本默认不动你的 CLAUDE.md。

**关于界面语言**：`language` 设置控制的是 **回复语言**（AI 回复、会话标题等）。Claude Code 终端界面（菜单、面板等）官方目前**没有简体中文版**，这是官方现状而非本包问题；CC Switch 图形界面的语言可在其 **设置（Settings）→ Language** 中切换为简体中文。

## 命令行参数（进阶）

对 `安装.cmd` 传参即可（例如在 cmd 里运行 `安装.cmd -ClaudeOnly`）：

| 参数 | 作用 |
|---|---|
| `-ClaudeOnly` | 只安装 Claude Code CLI + 中文配置 + 依赖检查 |
| `-SwitchOnly` | 只安装 CC Switch |
| `-ForceNode` | 本机已有 Node 也强制安装内嵌便携版 Node 22 |
| `-SetNpmMirror` | 把**系统** npm 的默认 registry 也设为 npmmirror（默认只配置便携 npm，不动你的系统配置） |
| `-OfflineOnly` | 禁止任何联网下载；内嵌资源损坏时直接报错 |
| `-NoShortcuts` | 不创建快捷方式 |
| `-Repair` | 忽略已安装的同版本，强制重装 |
| `-NoLaunch` | 安装完成后不自动打开 CC Switch |

## 镜像回退策略

内嵌资源校验（SHA256）失败或缺失时，按以下顺序自动回退：

- **Claude Code**：`registry.npmmirror.com` → `registry.npmjs.org`（下载平台包后自动解压部署）
- **Node.js**：`npmmirror.com/mirrors/node` → `nodejs.org/dist`
- **CC Switch**：`ghfast.top` → `ghproxy.net`（GitHub 加速代理）→ GitHub 官方
- **WebView2 运行时**（CC Switch 界面依赖，若系统缺失）：微软官方 CDN

## 常见问题

- **报错 `Unable to connect to Anthropic services` / `Failed to connect to api.anthropic.com: Status 403`**：
  说明 claude 没有可用的 API 供应商，直连了 Anthropic 官方端点（国内网络会被 Cloudflare 以 403 拒绝）。解决：
  1. 打开 CC Switch → **添加供应商**（填服务商提供的 Base URL 与 API Key，中转/代理服务商都提供这两项）→ **启用**该供应商；
  2. **重开终端窗口**再运行 `claude`（旧终端里的环境变量不会自动刷新）；
  3. 在 claude 会话里输入 `/status` 确认 Base URL 已指向你的供应商；
  4. 若要走 Anthropic 官方账号（`/login`），需要能正常访问 Anthropic 的网络环境，且官方对部分地区/网络返回 403。
- **双击 `安装.cmd` 一闪而过**：请先解压整个包再运行；报错信息看 `%TEMP%\cc-bundle-install.log`。
- **SmartScreen 拦截**：安装.cmd 已自动对包内文件执行 `Unblock-File`；若仍被拦截，点“仍要运行”。
- **新终端里 `claude` 不是内部命令**：重开终端窗口让 PATH 生效；或注销重新登录。
- **CC Switch 打不开**：多为系统缺少 WebView2 运行时，安装器会尝试自动装；也可手动下载 <https://developer.microsoft.com/microsoft-edge/webview2/>。
- **CC Switch 界面是英文**：在其 设置（Settings）→ Language 里切换为简体中文。
- **git 未安装**：可选依赖，安装器会提示并尝试 winget；国内手动下载：<https://npmmirror.com/mirrors/git-for-windows/>。

## 卸载

双击 **`卸载.cmd`**：移除程序、PATH 条目和快捷方式，**保留** `~/.claude`、`~/.claude.json` 与 CC Switch 配置。
彻底清除（含用户配置）：`powershell -ExecutionPolicy Bypass -File uninstall.ps1 -PurgeUserData`。

## 版本信息（本包内置）

- Claude Code CLI: 2.1.287 — sha256 `6d5be51f0edfe342...`（见 `versions.json`）
- Node.js: v22.23.3 (win-x64) — sha256 `2b0ff57b049c...`
- CC Switch: 3.20.4 (Windows Portable) — sha256 `227288532bf...`

## 许可

- 本仓库脚本以 [MIT](./LICENSE) 提供
- 内嵌组件版权归各自作者：Claude Code（Anthropic）、CC Switch（[farion1231/cc-switch](https://github.com/farion1231/cc-switch)，MIT）、Node.js（MIT）
