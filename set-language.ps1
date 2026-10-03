#requires -Version 5.1
<#
.SYNOPSIS
  Claude Code 中文语言设置工具（独立运行，适合已安装 Claude Code 的用户）
.DESCRIPTION
  - 写入 Claude Code 官方 language 设置（~/.claude/settings.json，合并写入、保留你的其他配置）
  - 同步维护全局 ~/.claude/CLAUDE.md 的幂等语言规则块（双保险）
  - 对 npm 安装、官方原生安装、离线合并安装包安装的用户均适用
  - 不联网、不需要管理员权限
.PARAMETER Language
  直接设置指定语言（如: 简体中文 / traditional chinese / english），不带此参数时显示交互菜单
.PARAMETER Show
  仅显示当前语言设置
.PARAMETER Remove
  还原：移除 language 设置与 CLAUDE.md 语言规则块
#>
param(
  [Parameter(Position = 0)][string]$Language = '',
  [switch]$Show,
  [switch]$Remove
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$SettingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'
$ClaudeMdPath = Join-Path $env:USERPROFILE '.claude\CLAUDE.md'
$MarkerBegin  = '<!-- cc-bundle:language BEGIN -->'
$MarkerEnd    = '<!-- cc-bundle:language END -->'

function Write-Ok   { param($m) Write-Host $m -ForegroundColor Green }
function Write-Warn { param($m) Write-Host $m -ForegroundColor Yellow }
function Write-Info { param($m) Write-Host $m -ForegroundColor Gray }

# 定位 claude 可执行文件（仅用于展示版本，找不到不影响配置写入）
function Get-ClaudePath {
  $cands = @()
  try { $cands += (Get-Command claude -ErrorAction SilentlyContinue).Source } catch { }
  $cands += @(
    (Join-Path $env:LOCALAPPDATA 'Programs\ClaudeCode\claude.exe'),
    (Join-Path $env:USERPROFILE '.local\bin\claude.exe'),
    (Join-Path $env:APPDATA 'npm\claude.cmd')
  )
  foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
  return $null
}

# 读取 JSON 文件中的 language 键（文件/键不存在返回 $null）
function Get-LanguageKey {
  try {
    if (-not (Test-Path -LiteralPath $SettingsPath)) { return $null }
    $raw = Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8
    if (-not ($raw -and $raw.Trim())) { return $null }
    $obj = $raw | ConvertFrom-Json
    $prop = $obj.PSObject.Properties['language']
    if ($prop) { return [string]$prop.Value }
  } catch { }
  return $null
}

# 合并写入 language 键（保留 JSON 其余内容）
function Set-LanguageKey {
  param([string]$Value)
  $obj = $null
  if (Test-Path -LiteralPath $SettingsPath) {
    $raw = Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8
    if ($raw -and $raw.Trim()) { $obj = $raw | ConvertFrom-Json }
  }
  if (-not $obj) { $obj = New-Object System.Management.Automation.PSObject }
  $prop = $obj.PSObject.Properties['language']
  if ($prop) { $prop.Value = $Value } else { $obj | Add-Member -NotePropertyName language -NotePropertyValue $Value }
  $dir = Split-Path -Parent $SettingsPath
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [System.IO.File]::WriteAllText($SettingsPath, ($obj | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
}

# 从 JSON 中移除 language 键
function Remove-LanguageKey {
  if (-not (Test-Path -LiteralPath $SettingsPath)) { return $false }
  $raw = Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8
  if (-not ($raw -and $raw.Trim())) { return $false }
  $obj = $raw | ConvertFrom-Json
  $prop = $obj.PSObject.Properties['language']
  if (-not $prop) { return $false }
  $obj.PSObject.Properties.Remove('language')
  [System.IO.File]::WriteAllText($SettingsPath, ($obj | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
  return $true
}

# 生成语言规则块
function New-LanguageBlock {
  param([string]$Value)
  @"
## 语言 / Language
$MarkerBegin
- 默认回复语言：$Value（代码、命令、专有名词除外），除非用户明确要求其他语言。
- Always respond in $Value unless the user explicitly asks for another language.
$MarkerEnd
"@
}

# CLAUDE.md：已有标记块则原位替换，否则追加（幂等）
function Update-ClaudeMd {
  param([string]$Value)
  $block = (New-LanguageBlock -Value $Value).TrimEnd()
  if (Test-Path -LiteralPath $ClaudeMdPath) {
    $content = Get-Content -LiteralPath $ClaudeMdPath -Raw -Encoding UTF8
    if ($content -match [regex]::Escape($MarkerBegin)) {
      # 原位替换 BEGIN..END 之间的内容（字符串切片，避免正则替换串的特殊字符问题）
      $start = $content.IndexOf($MarkerBegin)
      $endIdx = $content.IndexOf($MarkerEnd, $start)
      if ($endIdx -lt 0) { throw 'CLAUDE.md 语言标记块不完整（缺少 END 标记），请手动检查该文件' }
      $head = $content.Substring(0, $start)
      # 旧块的标题行在标记之外，替换时去掉，避免标题重复
      $head = [regex]::Replace($head, '## 语言 / Language\s*$', '')
      $tail = $content.Substring($endIdx + $MarkerEnd.Length)
      [System.IO.File]::WriteAllText($ClaudeMdPath, $head + $block + $tail, (New-Object System.Text.UTF8Encoding($false)))
      return 'updated'
    } else {
      [System.IO.File]::WriteAllText($ClaudeMdPath, $content.TrimEnd() + "`r`n`r`n" + $block + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
      return 'appended'
    }
  } else {
    $dir = Split-Path -Parent $ClaudeMdPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($ClaudeMdPath, $block + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    return 'created'
  }
}

# CLAUDE.md：移除语言规则块（连带标题行）
function Remove-ClaudeMdBlock {
  if (-not (Test-Path -LiteralPath $ClaudeMdPath)) { return $false }
  $content = Get-Content -LiteralPath $ClaudeMdPath -Raw -Encoding UTF8
  if ($content -notmatch [regex]::Escape($MarkerBegin)) { return $false }
  $pattern = '(?s)\r?\n?## 语言 / Language\r?\n' + [regex]::Escape($MarkerBegin) + '.*?' + [regex]::Escape($MarkerEnd) + '\r?\n?'
  $new = [regex]::Replace($content, $pattern, '')
  [System.IO.File]::WriteAllText($ClaudeMdPath, $new, (New-Object System.Text.UTF8Encoding($false)))
  return $true
}

function Show-Current {
  $cur = Get-LanguageKey
  if ($cur) { Write-Ok "当前 language 设置: $cur ($SettingsPath)" }
  else { Write-Warn "当前未设置 language ($SettingsPath)" }
  if (Test-Path -LiteralPath $ClaudeMdPath) {
    $md = Get-Content -LiteralPath $ClaudeMdPath -Raw -Encoding UTF8
    if ($md -match [regex]::Escape($MarkerBegin)) { Write-Info "全局 CLAUDE.md: 已包含语言规则块 ($ClaudeMdPath)" }
    else { Write-Info "全局 CLAUDE.md: 无语言规则块" }
  } else { Write-Info "全局 CLAUDE.md: 不存在" }
  $claude = Get-ClaudePath
  if ($claude) {
    try { $v = (& $claude --version 2>$null | Out-String).Trim() } catch { $v = '' }
    Write-Info "Claude Code: $v ($claude)"
  } else {
    Write-Warn "未在 PATH 或常见位置找到 claude，配置仍会写入（对之后安装的 Claude Code 同样生效）"
  }
}

Write-Host ''
Write-Host '  Claude Code 中文语言设置工具' -ForegroundColor Cyan
Write-Host "  用户配置: $SettingsPath" -ForegroundColor DarkCyan
Write-Host ''

if ($Show) { Show-Current; exit 0 }

if ($Remove) {
  $a = Remove-LanguageKey
  $b = Remove-ClaudeMdBlock
  if ($a) { Write-Ok '已移除 settings.json 中的 language 设置' } else { Write-Info 'settings.json 本无 language 设置' }
  if ($b) { Write-Ok '已移除 CLAUDE.md 中的语言规则块' } else { Write-Info 'CLAUDE.md 本无语言规则块' }
  Write-Host ''
  exit 0
}

# 交互菜单（未直接指定语言时）
if (-not $Language) {
  Write-Host '  请选择 Claude Code 的回复语言：' -ForegroundColor White
  Write-Host '   [1] 简体中文（推荐）'
  Write-Host '   [2] 繁體中文'
  Write-Host '   [3] English'
  Write-Host '   [4] 自定义（输入任意语言描述）'
  Write-Host '   [0] 退出'
  $choice = Read-Host '  请输入序号'
  switch ($choice.Trim()) {
    '1' { $Language = 'simplified chinese' }
    '2' { $Language = 'traditional chinese' }
    '3' { $Language = 'english' }
    '4' { $Language = (Read-Host '  请输入语言描述（如 日本語 / français）').Trim() }
    '0' { exit 0 }
    default { Write-Warn "无效输入: $choice"; exit 1 }
  }
  Write-Host ''
}

if (-not $Language) { Write-Warn '语言为空，未做任何修改'; exit 1 }

# 写入
Set-LanguageKey -Value $Language
Write-Ok "已写入官方语言设置: ~/.claude/settings.json => language = $Language"
$act = Update-ClaudeMd -Value $Language
switch ($act) {
  'created'  { Write-Ok '已创建全局 CLAUDE.md 并写入语言规则块' }
  'appended' { Write-Ok '已在全局 CLAUDE.md 追加语言规则块' }
  'updated'  { Write-Ok '已更新全局 CLAUDE.md 中的语言规则块' }
}
Write-Host ''
Show-Current
Write-Host ''
Write-Ok '完成！新开的 claude 会话即生效（正在运行的会话请退出重进）。'
Write-Info '提示：该设置控制 AI 回复语言；Claude Code 终端界面官方暂无简体中文。'
