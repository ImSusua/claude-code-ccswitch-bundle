#requires -Version 5.1
<#
.SYNOPSIS
  Claude Code + CC Switch 合并安装包 - 卸载脚本
.DESCRIPTION
  移除本安装包安装的组件、PATH 条目与快捷方式。
  默认保留用户数据（~/.claude 配置、CC Switch 配置）。
.PARAMETER PurgeUserData
  同时删除 Claude Code 用户配置（~/.claude 与 ~/.claude.json）
#>
param([switch]$PurgeUserData)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$ClaudeDir = Join-Path $env:LOCALAPPDATA 'Programs\ClaudeCode'
$NodeRoot  = Join-Path $env:LOCALAPPDATA 'Programs\ClaudeCode-Bundle'
$SwitchDir = Join-Path $env:LOCALAPPDATA 'Programs\CC-Switch'

function Remove-UserPathEntry {
  param([string]$Directory)
  $cur = [Environment]::GetEnvironmentVariable('Path', 'User')
  if (-not $cur) { return }
  $parts = @($cur -split ';' | Where-Object { $_ -and $_.Trim() -and ($_ -ne $Directory) })
  $new = $parts -join ';'
  if ($new -ne $cur) {
    [Environment]::SetEnvironmentVariable('Path', $new, 'User')
    Write-Host "已从用户 PATH 移除: $Directory"
  }
}

function Remove-Shortcut {
  param([string]$LinkPath)
  if (Test-Path -LiteralPath $LinkPath) {
    Remove-Item -LiteralPath $LinkPath -Force
    Write-Host "已删除快捷方式: $LinkPath"
  }
}

Write-Host 'Claude Code + CC Switch 合并安装包 - 卸载' -ForegroundColor Cyan

Remove-UserPathEntry -Directory $ClaudeDir
Remove-UserPathEntry -Directory (Join-Path $NodeRoot 'node')
Remove-UserPathEntry -Directory $SwitchDir

foreach ($d in @($ClaudeDir, $NodeRoot, $SwitchDir)) {
  # 只删除本安装包约定位置，且路径必须位于 LOCALAPPDATA\Programs 下，防止误删
  if ($d -like "$env:LOCALAPPDATA\Programs\*" -and (Test-Path -LiteralPath $d)) {
    Remove-Item -LiteralPath $d -Recurse -Force
    Write-Host "已删除目录: $d"
  }
}

Remove-Shortcut -LinkPath (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\CC Switch.lnk')
Remove-Shortcut -LinkPath (Join-Path ([Environment]::GetFolderPath('Desktop')) 'CC Switch.lnk')

if ($PurgeUserData) {
  foreach ($p in @((Join-Path $env:USERPROFILE '.claude'), (Join-Path $env:USERPROFILE '.claude.json'))) {
    if (Test-Path -LiteralPath $p) {
      Remove-Item -LiteralPath $p -Recurse -Force
      Write-Host "已删除用户数据: $p"
    }
  }
} else {
  Write-Host ''
  Write-Host '已保留用户数据（~/.claude 配置、API 供应商配置、CC Switch 配置）。' -ForegroundColor Yellow
  Write-Host '如需彻底清除请运行: powershell -File uninstall.ps1 -PurgeUserData'
}

Write-Host ''
Write-Host '卸载完成。' -ForegroundColor Green
