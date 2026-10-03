#requires -Version 5.1
<#
.SYNOPSIS
  Claude Code CLI + CC Switch 合并安装包（离线优先，国内镜像自动回退）
.DESCRIPTION
  - 全部用户级安装，不需要管理员权限
  - 优先使用内嵌资源完成离线安装；内嵌资源缺失/校验失败时自动回退国内镜像下载
  - 自动为 Claude Code 配置全局中文
  - 自动安装缺失依赖（Node.js 22 便携版 / git 提示 / WebView2 检测）
.PARAMETER ClaudeOnly
  只安装 Claude Code CLI（含中文配置、依赖检查）
.PARAMETER SwitchOnly
  只安装 CC Switch
.PARAMETER ForceNode
  即使已检测到 Node.js 也强制安装内嵌便携版 Node 22
.PARAMETER SetNpmMirror
  将系统 npm 的默认 registry 一并设置为 npmmirror 国内镜像
.PARAMETER OfflineOnly
  禁止任何联网下载；内嵌资源损坏时直接报错退出
.PARAMETER NoShortcuts
  不创建开始菜单/桌面快捷方式
.PARAMETER Repair
  忽略已安装的同版本，强制重装
.PARAMETER NoLaunch
  安装完成后不自动打开 CC Switch
#>
param(
  [switch]$ClaudeOnly,
  [switch]$SwitchOnly,
  [switch]$ForceNode,
  [switch]$SetNpmMirror,
  [switch]$OfflineOnly,
  [switch]$NoShortcuts,
  [switch]$Repair,
  [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$script:BundleRoot = $PSScriptRoot
if (-not $script:BundleRoot) { $script:BundleRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$ResDir    = Join-Path $script:BundleRoot 'resources'
$LogFile   = Join-Path $env:TEMP 'cc-bundle-install.log'
$Versions  = Get-Content -LiteralPath (Join-Path $script:BundleRoot 'versions.json') -Raw -Encoding UTF8 | ConvertFrom-Json

# —— 安装位置（全部在用户目录下，无需管理员）——
$ClaudeDir = Join-Path $env:LOCALAPPDATA 'Programs\ClaudeCode'
$NodeRoot  = Join-Path $env:LOCALAPPDATA 'Programs\ClaudeCode-Bundle'
$NodeDir   = Join-Path $NodeRoot 'node'
$SwitchDir = Join-Path $env:LOCALAPPDATA 'Programs\CC-Switch'

$script:UsedMirror = New-Object System.Collections.Generic.List[string]

# ============================ 基础工具 ============================

function Write-Log {
  param([string]$Message, [string]$Level = 'INFO', [string]$Color = 'Gray')
  $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
  try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch { }
  Write-Host $Message -ForegroundColor $Color
}
function Write-Step { param([string]$m) Write-Host ''; Write-Host "==> $m" -ForegroundColor Cyan; Add-Content -LiteralPath $LogFile -Value "`n==> $m" -Encoding UTF8 }
function Write-Ok   { param([string]$m) Write-Log -Message $m -Level 'OK' -Color 'Green' }
function Write-Warn { param([string]$m) Write-Log -Message $m -Level 'WARN' -Color 'Yellow' }
function Write-Err  { param([string]$m) Write-Log -Message $m -Level 'ERROR' -Color 'Red' }

function Get-Sha256 {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return '' }
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# 校验内嵌资源是否存在且完整
function Test-Resource {
  param([string]$RelativePath, [string]$ExpectedSha256)
  $full = Join-Path $ResDir $RelativePath
  if (-not (Test-Path -LiteralPath $full)) { return $false }
  if (-not $ExpectedSha256) { return $true }
  return ((Get-Sha256 -Path $full) -eq $ExpectedSha256.ToLowerInvariant())
}

# 多地址依次尝试下载（curl.exe 优先，Invoke-WebRequest 兜底）
function Invoke-Download {
  param([string[]]$Urls, [string]$OutFile, [string]$Label)
  $tmp = "$OutFile.downloading"
  if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
  $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
  foreach ($u in $Urls) {
    Write-Log "  尝试下载: $u"
    try {
      if ($curl) {
        & $curl.Source -L --fail --silent --show-error --connect-timeout 20 --max-time 3600 -o $tmp $u 2>$null
        $ok = ($LASTEXITCODE -eq 0)
      } else {
        Invoke-WebRequest -Uri $u -OutFile $tmp -UseBasicParsing -TimeoutSec 3600
        $ok = $true
      }
      if ($ok -and (Test-Path -LiteralPath $tmp) -and ((Get-Item -LiteralPath $tmp).Length -gt 0)) {
        Move-Item -LiteralPath $tmp -Destination $OutFile -Force
        Write-Ok "  下载完成: $Label ($('{0:N1}' -f ((Get-Item -LiteralPath $OutFile).Length / 1MB)) MB)"
        return $true
      }
    } catch {
      Write-Warn "  下载失败: $($_.Exception.Message)"
    }
  }
  if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
  return $false
}

# 把目录加入用户 PATH（幂等），并同步到当前会话
function Add-UserPath {
  param([string]$Directory)
  $cur = [Environment]::GetEnvironmentVariable('Path', 'User')
  if (-not $cur) { $cur = '' }
  $parts = @($cur -split ';' | Where-Object { $_ -and $_.Trim() })
  if ($parts -notcontains $Directory) {
    $new = (@($Directory) + $parts) -join ';'
    [Environment]::SetEnvironmentVariable('Path', $new, 'User')
    Write-Ok "已写入用户 PATH: $Directory"
  }
  if (-not (($env:Path -split ';') -contains $Directory)) { $env:Path = "$Directory;$env:Path" }
}

function Expand-ZipSafe {
  param([string]$ZipPath, [string]$Destination)
  if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction SilentlyContinue }
  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  Expand-Archive -LiteralPath $ZipPath -DestinationPath $Destination -Force
}

function New-Shortcut {
  param([string]$LinkPath, [string]$TargetPath, [string]$WorkingDir, [string]$Description)
  try {
    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($LinkPath)
    $lnk.TargetPath = $TargetPath
    $lnk.WorkingDirectory = $WorkingDir
    $lnk.Description = $Description
    $lnk.Save()
  } catch { Write-Warn "创建快捷方式失败($LinkPath): $($_.Exception.Message)" }
}

# ============================ Claude Code ============================

function Install-Claude {
  Write-Step "安装 Claude Code CLI $($Versions.claudeCode.version)（$($Versions.claudeCode.platform)）"
  $exe = Join-Path $ClaudeDir 'claude.exe'
  $src = Join-Path $ResDir (@($Versions.claudeCode.resource -split '/') -join '\')

  # 已装同版本则跳过
  if (-not $Repair -and (Test-Path -LiteralPath $exe)) {
    try { $ver = (& $exe --version 2>$null | Select-Object -First 1) } catch { $ver = '' }
    if ("$ver" -like "*$($Versions.claudeCode.version)*") {
      Write-Ok "检测到 Claude Code $ver 已安装，跳过（如需重装请加 -Repair 参数）"
      Add-UserPath -Directory $ClaudeDir
      return
    }
  }

  New-Item -ItemType Directory -Force -Path $ClaudeDir | Out-Null
  $installed = $false

  # 路径 1：内嵌资源离线安装
  if (Test-Resource -RelativePath $Versions.claudeCode.resource -ExpectedSha256 $Versions.claudeCode.sha256) {
    Copy-Item -LiteralPath $src -Destination $exe -Force
    Write-Ok "已从内嵌资源离线安装 Claude Code（未联网）"
    $installed = $true
  }
  # 路径 2：镜像回退下载（国内镜像优先，官方兜底）
  elseif ($OfflineOnly) {
    throw "内嵌 claude.exe 缺失或校验失败，且已指定 -OfflineOnly 禁止联网，无法继续。"
  }
  else {
    Write-Warn "内嵌资源缺失或校验失败，自动回退：从镜像源下载 claude-code 平台包..."
    $script:UsedMirror.Add('Claude Code 平台包（镜像下载）')
    $v = $Versions.claudeCode.version
    $pkg = $Versions.claudeCode.npmPackage
    $pkgName = $pkg -replace '^@[^/]+/', ''   # 作用域包的 tgz 文件名不含 @scope/
    $tgz = Join-Path $env:TEMP "$pkgName-$v.tgz"
    $ok = Invoke-Download -Label "$pkg $v" -OutFile $tgz -Urls @(
      "$($Versions.mirrors.npmRegistry)/$pkg/-/$pkgName-$v.tgz",
      "https://registry.npmjs.org/$pkg/-/$pkgName-$v.tgz"
    )
    if (-not $ok) { throw "镜像与官方源均下载失败，请检查网络后重试。" }
    $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
    if (-not $tar) { throw "系统缺少 tar.exe（Windows 10 1803+ 自带），无法解压下载的平台包。" }
    $xdir = Join-Path $env:TEMP 'claude-code-extract'
    if (Test-Path -LiteralPath $xdir) { Remove-Item -LiteralPath $xdir -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path $xdir | Out-Null
    & tar.exe -xzf $tgz -C $xdir
    if ($LASTEXITCODE -ne 0) { throw "解压平台包失败。" }
    $bin = Join-Path $xdir 'package\claude.exe'
    if (-not (Test-Path -LiteralPath $bin)) { throw "平台包中未找到 claude.exe。" }
    Copy-Item -LiteralPath $bin -Destination $exe -Force
    Remove-Item -LiteralPath $xdir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tgz -Force -ErrorAction SilentlyContinue
    $installed = $true
  }

  if (-not $installed) { throw "Claude Code 安装失败。" }
  Add-UserPath -Directory $ClaudeDir
  $verOut = (& $exe --version 2>&1 | Out-String).Trim()
  if ($verOut -notlike "*$($Versions.claudeCode.version)*") { throw "claude.exe 无法运行（$verOut）。" }
  Write-Ok "Claude Code 就绪: $verOut"
}

# ============================ 全局中文 ============================

# 合并写入 JSON 文件中的 language 键（保留其余内容）
function Set-JsonLanguageKey {
  param([string]$Path, [string]$Value)
  try {
    $obj = $null
    if (Test-Path -LiteralPath $Path) {
      $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
      if ($raw -and $raw.Trim()) { $obj = $raw | ConvertFrom-Json }
    }
    if (-not $obj) { $obj = New-Object System.Management.Automation.PSObject }
    $prop = $obj.PSObject.Properties['language']
    if ($prop) { $prop.Value = $Value } else { $obj | Add-Member -NotePropertyName language -NotePropertyValue $Value }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($Path, ($obj | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    return $true
  } catch {
    Write-Warn "写入 $Path 失败: $($_.Exception.Message)"
    return $false
  }
}

function Set-ChineseLanguage {
  Write-Step "配置 Claude Code 全局中文"
  $exe = Join-Path $ClaudeDir 'claude.exe'
  if (-not (Test-Path -LiteralPath $exe)) { Write-Warn "未找到 claude.exe，跳过中文配置。"; return }

  # 1) 官方 settings 键 language（Scope: 任意配置文件；用户级为 ~/.claude/settings.json）
  #    官方文档：该值会作为“始终用该语言回复”的指令传给模型，Claude Code 不校验其取值
  $sj = Join-Path $env:USERPROFILE '.claude\settings.json'
  if (Set-JsonLanguageKey -Path $sj -Value 'simplified chinese') {
    Write-Ok "已写入官方语言设置: ~/.claude/settings.json => language = simplified chinese"
  }

  # 2) 全局 CLAUDE.md 强化（幂等，带标记块，兼容任何版本）
  $claudeHome = Join-Path $env:USERPROFILE '.claude'
  New-Item -ItemType Directory -Force -Path $claudeHome | Out-Null
  $md = Join-Path $claudeHome 'CLAUDE.md'
  $block = @"
## 语言 / Language
<!-- cc-bundle:language BEGIN -->
- 始终使用简体中文回复（代码、命令、专有名词除外），除非用户明确要求其他语言。
- Always respond in Simplified Chinese unless the user explicitly asks for another language.
<!-- cc-bundle:language END -->
"@
  if (Test-Path -LiteralPath $md) {
    $content = Get-Content -LiteralPath $md -Raw -Encoding UTF8
    if ($content -notmatch 'cc-bundle:language BEGIN') {
      Add-Content -LiteralPath $md -Value "`n$block" -Encoding UTF8
      Write-Ok "已在全局 CLAUDE.md 追加中文语言规则（幂等标记块）"
    } else {
      Write-Log "  全局 CLAUDE.md 已包含语言规则，跳过"
    }
  } else {
    Set-Content -LiteralPath $md -Value $block -Encoding UTF8
    Write-Ok "已创建全局 CLAUDE.md 并写入中文语言规则"
  }
  Write-Ok "全局中文配置完成"
}

# ============================ 依赖：Node.js ============================

function Install-NodeIfNeeded {
  Write-Step "检查 Node.js 环境（自动安装依赖）"
  if (-not $ForceNode) {
    $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
    if ($nodeCmd) {
      $nv = (& node --version 2>$null)
      Write-Ok "检测到 Node.js $nv，跳过便携版安装（如需强制安装内嵌版请加 -ForceNode）"
      return
    }
  }
  $v = $Versions.node.version
  $zipName = "node-v$v-win-x64.zip"
  $zip = Join-Path $ResDir "node\$zipName"
  $ok = $false

  if (Test-Resource -RelativePath "node/$zipName" -ExpectedSha256 $Versions.node.sha256) {
    Write-Log "  使用内嵌便携版 Node.js v$v（未联网）"
    $ok = $true
  } elseif ($OfflineOnly) {
    throw "内嵌 Node.js 缺失或校验失败，且已指定 -OfflineOnly。"
  } else {
    Write-Warn "内嵌 Node.js 缺失或校验失败，自动回退：从国内镜像下载 Node.js v$v ..."
    $script:UsedMirror.Add("Node.js v$v（镜像下载）")
    $dl = Join-Path $env:TEMP $zipName
    $ok = Invoke-Download -Label "Node.js v$v" -OutFile $dl -Urls @(
      "$($Versions.mirrors.nodeDist)/v$v/$zipName",
      "$($Versions.mirrors.nodeDistOfficial)/v$v/$zipName"
    )
    if ($ok) { $zip = $dl }
  }
  if (-not $ok) { throw "Node.js 安装包获取失败。" }

  # 解压到固定目录（zip 内层目录名可能变化，解压后归位为 ...\node）
  $stage = Join-Path $NodeRoot 'stage'
  Expand-ZipSafe -ZipPath $zip -Destination $stage
  $inner = Get-ChildItem -LiteralPath $stage -Directory | Select-Object -First 1
  if (-not $inner) { throw "Node.js 压缩包结构异常。" }
  if (Test-Path -LiteralPath $NodeDir) { Remove-Item -LiteralPath $NodeDir -Recurse -Force }
  Move-Item -LiteralPath $inner.FullName -Destination $NodeDir
  Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue

  Add-UserPath -Directory $NodeDir

  # 便携版 npm 默认走国内镜像（只影响该便携 npm，不改系统配置）
  $npmrc = Join-Path $NodeDir 'node_modules\npm\npmrc'
  try {
    Set-Content -LiteralPath $npmrc -Value "registry=$($Versions.mirrors.npmRegistry)" -Encoding ASCII
    Write-Ok "便携版 npm 已配置国内镜像 registry"
  } catch { Write-Warn "写入便携 npm 镜像配置失败: $($_.Exception.Message)" }

  $nv2 = (& (Join-Path $NodeDir 'node.exe') --version 2>$null)
  Write-Ok "Node.js 便携版就绪: $nv2 -> $NodeDir"

  # 可选：把系统 npm 默认源也切换为国内镜像
  if ($SetNpmMirror -and (Get-Command npm -ErrorAction SilentlyContinue)) {
    try { npm config set registry $Versions.mirrors.npmRegistry; Write-Ok "系统 npm registry 已设为 $($Versions.mirrors.npmRegistry)" }
    catch { Write-Warn "设置系统 npm registry 失败: $($_.Exception.Message)" }
  }
}

# ============================ 依赖：git ============================

function Install-GitIfNeeded {
  Write-Step "检查 git（Claude Code 部分功能依赖）"
  if (Get-Command git -ErrorAction SilentlyContinue) {
    Write-Ok "git 已安装: $((& git --version 2>$null))"
    return
  }
  Write-Warn "未检测到 git（可选依赖，不影响 claude 基本使用）"
  if ($OfflineOnly) { return }
  $wg = Get-Command winget -ErrorAction SilentlyContinue
  if ($wg) {
    Write-Log "  尝试通过 winget 静默安装 Git..."
    try {
      & $wg.Source install --id Git.Git -e --silent --accept-package-agreements --accept-source-agreements 2>$null
      if ($LASTEXITCODE -eq 0 -and (Get-Command git -ErrorAction SilentlyContinue)) { Write-Ok "git 安装完成"; return }
    } catch { Write-Warn "winget 安装失败: $($_.Exception.Message)" }
  }
  Write-Warn "可手动安装 git（国内镜像）: $($Versions.mirrors.gitForWindows)"
}

# ============================ CC Switch ============================

function Test-WebView2 {
  $keys = @(
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
    'HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
    'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
  )
  foreach ($k in $keys) {
    try {
      if (Test-Path $k) {
        $pv = (Get-ItemProperty -Path $k -ErrorAction SilentlyContinue).pv
        if ($pv) { return $true }
      }
    } catch { }
  }
  return $false
}

function Install-CCSwitch {
  Write-Step "安装 CC Switch $($Versions.ccSwitch.version)（供应商切换器）"
  $zipName = "CC-Switch-v$($Versions.ccSwitch.version)-Windows-Portable.zip"
  $zip = Join-Path $ResDir "ccswitch\$zipName"

  if (Test-Resource -RelativePath "ccswitch/$zipName" -ExpectedSha256 $Versions.ccSwitch.sha256) {
    Write-Log "  使用内嵌 CC Switch 便携版（未联网）"
  } elseif ($OfflineOnly) {
    throw "内嵌 CC Switch 缺失或校验失败，且已指定 -OfflineOnly。"
  } else {
    Write-Warn "内嵌资源缺失或校验失败，自动回退：从 GitHub 国内加速镜像下载..."
    $script:UsedMirror.Add('CC Switch（GitHub 镜像下载）')
    $gh = "https://github.com/farion1231/cc-switch/releases/download/v$($Versions.ccSwitch.version)/$zipName"
    $dl = Join-Path $env:TEMP $zipName
    $urls = @($Versions.mirrors.githubProxies | ForEach-Object { $_ + $gh }) + @($gh)
    $ok = Invoke-Download -Label "CC Switch v$($Versions.ccSwitch.version)" -OutFile $dl -Urls $urls
    if (-not $ok) { throw "CC Switch 下载失败（含镜像）。" }
    $zip = $dl
  }

  Expand-ZipSafe -ZipPath $zip -Destination $SwitchDir
  $switchExe = Join-Path $SwitchDir 'cc-switch.exe'
  if (-not (Test-Path -LiteralPath $switchExe)) { throw "解压后未找到 cc-switch.exe。" }
  Write-Ok "CC Switch 便携版已安装: $SwitchDir"

  # WebView2 运行时检测（cc-switch 界面依赖）
  if (-not (Test-WebView2)) {
    Write-Warn "未检测到 WebView2 运行时（CC Switch 界面需要）"
    if (-not $OfflineOnly) {
      Write-Log "  尝试从微软官方下载 WebView2 Bootstrapper 并静默安装..."
      $wv = Join-Path $env:TEMP 'MicrosoftEdgeWebview2Setup.exe'
      if (Invoke-Download -Label 'WebView2 Bootstrapper' -OutFile $wv -Urls @($Versions.mirrors.webview2Bootstrapper)) {
        try {
          Start-Process -FilePath $wv -ArgumentList '/silent','/install' -Wait
          if (Test-WebView2) { Write-Ok "WebView2 运行时安装完成" }
          else { Write-Warn "WebView2 安装后仍未检测到（可能需要管理员权限），请手动运行: $wv" }
        } catch { Write-Warn "WebView2 静默安装失败，请手动运行: $wv" }
      }
    } else {
      Write-Warn "请手动下载安装 WebView2: $($Versions.mirrors.webview2Bootstrapper)"
    }
  } else {
    Write-Ok "WebView2 运行时已存在"
  }

  # 快捷方式（开始菜单 + 桌面）
  if (-not $NoShortcuts) {
    $smDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    New-Shortcut -LinkPath (Join-Path $smDir 'CC Switch.lnk') -TargetPath $switchExe -WorkingDir $SwitchDir -Description 'CC Switch - Claude Code/Codex 供应商切换器'
    $desktop = [Environment]::GetFolderPath('Desktop')
    New-Shortcut -LinkPath (Join-Path $desktop 'CC Switch.lnk') -TargetPath $switchExe -WorkingDir $SwitchDir -Description 'CC Switch - Claude Code/Codex 供应商切换器'
    Write-Ok "已创建开始菜单与桌面快捷方式"
  }

  # 自动打开 CC Switch，引导完成首次供应商配置：
  # 不配置供应商时 claude 会直连 api.anthropic.com，在国内网络下会被 403 拒绝
  if (-not $NoLaunch) {
    try {
      Start-Process -FilePath $switchExe -WorkingDirectory $SwitchDir | Out-Null
      Write-Ok "已自动打开 CC Switch —— 请先添加并启用你的 API 供应商（Base URL + API Key），claude 才能使用"
    } catch {
      Write-Warn "自动打开 CC Switch 失败，请手动启动: $switchExe"
    }
  }
}

# ============================ 主流程 ============================

function Show-Summary {
  Write-Host ''
  Write-Host '================== 安装结果 ==================' -ForegroundColor Cyan
  $rows = @()
  if (Test-Path -LiteralPath (Join-Path $ClaudeDir 'claude.exe')) {
    $rows += [pscustomobject]@{ 组件 = 'Claude Code CLI'; 位置 = $ClaudeDir; 状态 = (& (Join-Path $ClaudeDir 'claude.exe') --version 2>$null | Select-Object -First 1) }
  }
  if (Test-Path -LiteralPath (Join-Path $NodeDir 'node.exe')) {
    $rows += [pscustomobject]@{ 组件 = 'Node.js (便携)'; 位置 = $NodeDir; 状态 = (& (Join-Path $NodeDir 'node.exe') --version 2>$null) }
  }
  if (Test-Path -LiteralPath (Join-Path $SwitchDir 'cc-switch.exe')) {
    $rows += [pscustomobject]@{ 组件 = 'CC Switch'; 位置 = $SwitchDir; 状态 = "v$($Versions.ccSwitch.version)" }
  }
  $rows | Format-Table -AutoSize | Out-Host
  if ($script:UsedMirror.Count -gt 0) {
    Write-Warn "本次安装以下组件走了镜像下载回退: $($script:UsedMirror -join '、')"
  } else {
    Write-Ok "本次安装全程使用内嵌资源，未联网下载。"
  }
  Write-Host '----------------------------------------------'
  Write-Host '使用提示:' -ForegroundColor Cyan
  Write-Host '  1. 新开一个终端窗口，输入 claude 即可启动（当前已打开的终端需重开才能识别 PATH）。'
  Write-Host '  2. Claude Code 已默认全局中文（官方 language 设置 + 全局 CLAUDE.md 双保险）。'
  Write-Host '  3. 必做：在 CC Switch 里添加并启用 API 供应商（Base URL + API Key），否则 claude 直连官方端点会被 403 拒绝。'
  Write-Host "  4. 安装日志: $LogFile"
  Write-Host '==============================================' -ForegroundColor Cyan
}

try {
  Write-Host ''
  Write-Host '  Claude Code CLI + CC Switch 合并安装包 v' -NoNewline -ForegroundColor Cyan
  Write-Host $Versions.bundleVersion -ForegroundColor Cyan
  Write-Host '  （离线优先 · 国内镜像自动回退 · 全局中文 · 依赖自动安装）' -ForegroundColor DarkCyan
  Write-Host "  资源目录: $ResDir"

  if (-not (Test-Path -LiteralPath $ResDir)) { throw "未找到 resources 资源目录，请确认解压完整后再运行。" }

  if (-not $SwitchOnly) {
    Install-Claude
    Set-ChineseLanguage
    Install-NodeIfNeeded
    Install-GitIfNeeded
  }
  if (-not $ClaudeOnly) {
    Install-CCSwitch
  }

  Show-Summary
  exit 0
} catch {
  Write-Err "安装失败: $($_.Exception.Message)"
  Write-Err "详细日志: $LogFile"
  exit 1
}
