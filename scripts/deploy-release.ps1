<#
Deploy the Windows release build to a runnable folder.

Why this exists:
  Flutter builds produced inside a sandboxed/agent environment inherit NTFS
  Low integrity labels. Windows then starts the app at Low IL, and media_kit
  cannot create its temp playlist file under %TEMP% (PathAccessException,
  errno=5) - video playback fails. This script copies the build, resets the
  labels to Medium for the whole folder, and optionally updates the desktop
  shortcut.

All paths are explicit parameters with validation; there are no hard-coded
machine-specific paths. Defaults are derived from the repository location.

Usage (from the repo root):
  powershell -ExecutionPolicy Bypass -File scripts\deploy-release.ps1

  # explicit paths, skip shortcut
  powershell -ExecutionPolicy Bypass -File scripts\deploy-release.ps1 `
      -TargetDir "D:\Apps\NovaPlay" -SkipShortcut
#>
param(
    [string]$ProjectRoot = "",
    [string]$BuildDir = "",
    [string]$TargetDir = "",
    [string]$Shortcut = "$env:USERPROFILE\Desktop\NovaPlay.lnk",
    [switch]$SkipShortcut
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}
$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path

if ([string]::IsNullOrWhiteSpace($BuildDir)) {
    $BuildDir = Join-Path $ProjectRoot "build\windows\x64\runner\Release"
}
$BuildDir = (Resolve-Path -LiteralPath $BuildDir).Path

if ([string]::IsNullOrWhiteSpace($TargetDir)) {
    $TargetDir = Join-Path $ProjectRoot "运行版"
}
$TargetDir = [System.IO.Path]::GetFullPath($TargetDir)
$normalizedTarget = $TargetDir.TrimEnd('\')

# ---- safety: never clear/mirror into a system directory or the repo root ----
$systemRoots = @(
    $env:SystemRoot,
    $env:ProgramFiles,
    ${env:ProgramFiles(x86)},
    $env:USERPROFILE,
    [System.IO.Path]::GetPathRoot($TargetDir)
)
foreach ($root in $systemRoots) {
    if (-not [string]::IsNullOrWhiteSpace($root) -and
        $normalizedTarget -eq $root.TrimEnd('\')) {
        throw "拒绝部署到系统目录或盘符根目录：$TargetDir"
    }
}
if ($normalizedTarget -eq $ProjectRoot.TrimEnd('\')) {
    throw "TargetDir 不能是仓库根目录：$TargetDir"
}

$exeSource = Join-Path $BuildDir "nova_play.exe"
if (-not (Test-Path -LiteralPath $exeSource -PathType Leaf)) {
    throw "找不到 Release 构建：$exeSource（请先执行 flutter build windows --release）"
}
if (-not (Test-Path -LiteralPath (Join-Path $BuildDir "data") -PathType Container)) {
    throw "Release 构建缺少 data 目录：$BuildDir"
}

Get-Process nova_play -ErrorAction SilentlyContinue | Stop-Process -Force

if (-not (Test-Path -LiteralPath $TargetDir)) {
    New-Item -ItemType Directory -Path $TargetDir | Out-Null
}
# Only clear the target folder itself (keep an optional screenshot placeholder).
Get-ChildItem -LiteralPath $TargetDir -Force |
    Where-Object { $_.Name -ne "启动截图.png" } |
    Remove-Item -Recurse -Force

Copy-Item -Path (Join-Path $BuildDir "*") -Destination $TargetDir -Recurse -Force

foreach ($doc in @("README.md", "LICENSE")) {
    $source = Join-Path $ProjectRoot $doc
    if (Test-Path -LiteralPath $source) {
        Copy-Item -LiteralPath $source -Destination $TargetDir -Force
    }
}

# Reset integrity labels AFTER copying (copy may preserve Low labels).
& icacls $TargetDir /setintegritylevel Medium /T | Out-Null
$low = (& icacls $TargetDir /T) | Select-String "Low Mandatory"
if ($low) {
    throw "Some files still have Low integrity labels; check permissions and rerun icacls."
}

if (-not $SkipShortcut -and -not [string]::IsNullOrWhiteSpace($Shortcut)) {
    $shortcutDir = Split-Path -Parent $Shortcut
    if (-not (Test-Path -LiteralPath $shortcutDir -PathType Container)) {
        throw "快捷方式目录不存在：$shortcutDir"
    }
    $exe = Join-Path $TargetDir "nova_play.exe"
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($Shortcut)
    $link.TargetPath = $exe
    $link.WorkingDirectory = $TargetDir
    $link.Save()
    Write-Host "Shortcut: $Shortcut"
}

Write-Host "Deployed: $TargetDir"
