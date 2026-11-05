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

# Resolve every existing parent component's junction/symlink chain, not only
# the leaf: `alias\run` must be recognized as the same location as `real\run`
# when `alias` is a junction to `real`. Nonexistent suffixes are appended;
# loops/excessive nesting are rejected instead of silently passing.
function Get-LinkTarget([string]$Path) {
    # PowerShell 7 exposes LinkTarget; Windows PowerShell 5.1 exposes Target.
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    if ($null -ne $item.PSObject.Properties['LinkTarget']) {
        $value = $item.LinkTarget
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    }
    if ($null -ne $item.PSObject.Properties['Target']) {
        $value = @($item.Target) | Select-Object -First 1
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    }
    return $null
}
function Resolve-RealPath {
    param(
        [string]$Path,
        [int]$Depth = 0,
        [hashtable]$Visited
    )
    if ($Depth -gt 8) {
        throw "路径链接层级过深，无法安全解析：$Path"
    }
    if ($null -eq $Visited) { $Visited = @{} }

    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    $relative = if ($full.Length -gt $root.Length) {
        $full.Substring($root.Length)
    } else {
        ''
    }
    $current = $root
    $missing = @()
    $parts = @($relative -split '[\\/]' | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    })

    foreach ($part in $parts) {
        if ($missing.Count -gt 0) {
            $missing += $part
            continue
        }
        $candidate = Join-Path $current $part
        $item = Get-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) {
            $missing += $part
            continue
        }
        $target = Get-LinkTarget $candidate
        if (-not [string]::IsNullOrWhiteSpace($target)) {
            if (-not [System.IO.Path]::IsPathRooted($target)) {
                $target = Join-Path (Split-Path -Parent $candidate) $target
            }
            $targetFull = [System.IO.Path]::GetFullPath($target)
            $key = $targetFull.ToLowerInvariant()
            if ($Visited.ContainsKey($key)) {
                throw "路径链接存在循环，无法安全解析：$Path"
            }
            $Visited[$key] = $true
            $candidate = Resolve-RealPath -Path $targetFull -Depth ($Depth + 1) -Visited $Visited
        }
        $current = $candidate
    }

    foreach ($suffix in $missing) {
        $current = Join-Path $current $suffix
    }
    return $current.TrimEnd('\')
}

function Test-SamePath([string]$A, [string]$B) {
    return (Resolve-RealPath $A) -eq (Resolve-RealPath $B)
}

function Test-PathOverlap([string]$A, [string]$B) {
    $ra = Resolve-RealPath $A
    $rb = Resolve-RealPath $B
    if ($ra -eq $rb) { return $true }
    $sep = [System.IO.Path]::DirectorySeparatorChar
    if ($ra.StartsWith($rb + $sep, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    if ($rb.StartsWith($ra + $sep, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    return $false
}

function Test-IsSameOrAncestor([string]$A, [string]$B) {
    $ra = Resolve-RealPath $A
    $rb = Resolve-RealPath $B
    if ($ra -eq $rb) { return $true }
    $sep = [System.IO.Path]::DirectorySeparatorChar
    return $rb.StartsWith($ra + $sep, [System.StringComparison]::OrdinalIgnoreCase)
}

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

# The deploy step clears TargetDir. Refuse any relationship with the build
# source (same dir, parent or child) before stopping processes or deleting files.
if (Test-PathOverlap $TargetDir $BuildDir) {
    throw "TargetDir 不能与 BuildDir 相同或互相包含：TargetDir=$TargetDir BuildDir=$BuildDir"
}
# Allow the default target inside the repo, but never allow clearing a directory
# that contains the repository (e.g. -TargetDir D:\ where the repo lives).
if (Test-IsSameOrAncestor $TargetDir $ProjectRoot) {
    throw "TargetDir 不能是仓库根目录或其祖先目录：$TargetDir"
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
