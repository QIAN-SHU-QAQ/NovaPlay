<#
Build a portable Windows preview ZIP from a release build.

The package contains the complete runnable directory (exe + DLLs + data),
LICENSE, README and a Chinese usage note. It refuses to package if required
files are missing or if personal/runtime artifacts are found inside.

Usage (from the repo root, after 'flutter build windows --release'):
  powershell -ExecutionPolicy Bypass -File scripts\package-portable.ps1

Or with explicit paths/version:
  powershell -ExecutionPolicy Bypass -File scripts\package-portable.ps1 `
      -BuildDir build\windows\x64\runner\Release -OutputDir dist -Version 1.0.0
#>
param(
    [string]$BuildDir = "",
    [string]$OutputDir = "",
    [string]$Version = "",
    [switch]$SkipContentChecks
)

$ErrorActionPreference = "Stop"

# Resolve junction/symlink chains so two spellings of the same directory cannot
# bypass the overlap checks below.
function Resolve-RealPath([string]$Path) {
    $full = [System.IO.Path]::GetFullPath($Path)
    for ($i = 0; $i -lt 10; $i++) {
        $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) { break }
        $target = $item.LinkTarget
        if ([string]::IsNullOrWhiteSpace($target)) { break }
        if (-not [System.IO.Path]::IsPathRooted($target)) {
            $target = Join-Path (Split-Path -Parent $full) $target
        }
        $full = [System.IO.Path]::GetFullPath($target)
    }
    return $full.TrimEnd('\')
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

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if ([string]::IsNullOrWhiteSpace($BuildDir)) {
    $BuildDir = Join-Path $repoRoot "build\windows\x64\runner\Release"
}
$BuildDir = (Resolve-Path $BuildDir).Path

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $repoRoot "dist"
}
$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)

# ---- safety: never write a package into a system root / drive root ----
$forbiddenRoots = @(
    ($env:SystemRoot.TrimEnd('\')),
    ($env:ProgramFiles.TrimEnd('\')),
    (${env:ProgramFiles(x86)}.TrimEnd('\')),
    ($env:USERPROFILE.TrimEnd('\')),
    ([System.IO.Path]::GetPathRoot($OutputDir).TrimEnd('\'))
)
if ($forbiddenRoots -contains $OutputDir.TrimEnd('\')) {
    throw "OutputDir 不能是系统目录或盘符根目录：$OutputDir"
}

# ---- required runtime files ----
$requiredFiles = @(
    "nova_play.exe",
    "flutter_windows.dll"
)
$requiredDirs = @("data")

foreach ($name in $requiredFiles) {
    $path = Join-Path $BuildDir $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "缺少必需文件：$path（请先执行 flutter build windows --release）"
    }
}
foreach ($name in $requiredDirs) {
    $path = Join-Path $BuildDir $name
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        throw "缺少必需目录：$path"
    }
    if (-not (Get-ChildItem -LiteralPath $path -Recurse -File | Select-Object -First 1)) {
        throw "必需目录为空：$path"
    }
}

if (-not $SkipContentChecks) {
    $appSo = Join-Path $BuildDir "data\app.so"
    if (-not (Test-Path -LiteralPath $appSo -PathType Leaf)) {
        throw "缺少 AOT 产物：$appSo"
    }
    $notices = Join-Path $BuildDir "data\flutter_assets\NOTICES.Z"
    if (-not (Test-Path -LiteralPath $notices -PathType Leaf)) {
        throw "缺少依赖许可文件：$notices"
    }
}

# ---- version ----
if ([string]::IsNullOrWhiteSpace($Version)) {
    $pubspec = Get-Content -LiteralPath (Join-Path $repoRoot "pubspec.yaml") -Raw
    $match = [regex]::Match($pubspec, "(?m)^version:\s*([0-9A-Za-z._+\-]+)")
    if (-not $match.Success) {
        throw "无法从 pubspec.yaml 读取版本号，请显式传入 -Version"
    }
    $Version = $match.Groups[1].Value.Split('+')[0]
}
$Version = $Version.Trim().TrimStart('v')
if ($Version -notmatch '^[0-9A-Za-z._\-]+$') {
    throw "版本号只能包含字母、数字、点、下划线和连字符：$Version"
}

$packageName = "NovaPlay-$Version-windows-x64"
$stage = Join-Path $OutputDir $packageName
$zipPath = Join-Path $OutputDir "$packageName.zip"
$shaPath = "$zipPath.sha256"

# ---- safety: input and staging/output must never overlap ----
# Re-packaging an old staging directory (BuildDir == stage) used to delete the
# build source here and still report success with a docs-only ZIP.
if (Test-PathOverlap $BuildDir $stage) {
    throw "BuildDir 不能与 staging 目录相同或互相包含：BuildDir=$BuildDir stage=$stage"
}
if (Test-PathOverlap $BuildDir $OutputDir) {
    throw "BuildDir 不能与 OutputDir 相同或互相包含：BuildDir=$BuildDir OutputDir=$OutputDir"
}
if (Test-PathOverlap $BuildDir $zipPath) {
    throw "BuildDir 不能包含 ZIP 输出路径：BuildDir=$BuildDir zip=$zipPath"
}

# ---- stage ----
if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir | Out-Null
}
if (Test-Path -LiteralPath $stage) {
    Remove-Item -LiteralPath $stage -Recurse -Force
}
New-Item -ItemType Directory -Path $stage | Out-Null

Copy-Item -Path (Join-Path $BuildDir "*") -Destination $stage -Recurse -Force

foreach ($doc in @("LICENSE", "README.md")) {
    $source = Join-Path $repoRoot $doc
    if (Test-Path -LiteralPath $source) {
        Copy-Item -LiteralPath $source -Destination $stage -Force
    }
}
$usage = Join-Path $repoRoot "docs\preview-usage.md"
if (Test-Path -LiteralPath $usage) {
    Copy-Item -LiteralPath $usage -Destination (Join-Path $stage "使用说明.md") -Force
}

# ---- never ship personal/runtime artifacts ----
$forbiddenPatterns = @(
    "*.log",
    "*.pdb",
    "*.tmp",
    "shared_preferences.json",
    "pending_ops*",
    ".env",
    "*.m3u8",
    "cookies.txt"
)
$forbidden = @()
foreach ($file in (Get-ChildItem -LiteralPath $stage -Recurse -File)) {
    foreach ($pattern in $forbiddenPatterns) {
        if ($file.Name -like $pattern) {
            $forbidden += $file.FullName
            break
        }
    }
}
if ($forbidden.Count -gt 0) {
    throw ("包内发现不应分发的文件：" + ($forbidden -join ", "))
}

# ---- final staging validation: never produce a ZIP without runnable files ----
$stageExe = Join-Path $stage "nova_play.exe"
$stageDll = Join-Path $stage "flutter_windows.dll"
$stageData = Join-Path $stage "data"
if (-not (Test-Path -LiteralPath $stageExe -PathType Leaf)) {
    throw "staging 缺少 nova_play.exe，拒绝生成 ZIP：$stage"
}
if (-not (Test-Path -LiteralPath $stageDll -PathType Leaf)) {
    throw "staging 缺少 flutter_windows.dll，拒绝生成 ZIP：$stage"
}
if (-not (Test-Path -LiteralPath $stageData -PathType Container)) {
    throw "staging 缺少 data 目录，拒绝生成 ZIP：$stage"
}
if (-not (Get-ChildItem -LiteralPath $stageData -Recurse -File | Select-Object -First 1)) {
    throw "staging 的 data 目录为空，拒绝生成 ZIP：$stage"
}
# The source must still be intact after staging (guards against path overlap bugs).
if (-not (Test-Path -LiteralPath (Join-Path $BuildDir "nova_play.exe") -PathType Leaf)) {
    throw "打包过程中 BuildDir 被修改/删除：$BuildDir"
}

# ---- zip + checksum ----
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}
Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zipPath -CompressionLevel Optimal

$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLower()
$checksumLine = "$hash  $packageName.zip"
Set-Content -LiteralPath $shaPath -Value $checksumLine -Encoding ASCII

$fileCount = (Get-ChildItem -LiteralPath $stage -Recurse -File | Measure-Object).Count
$sizeMb = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 1)

Write-Output "Package : $zipPath"
Write-Output "SHA-256 : $hash"
Write-Output "Checksum: $shaPath"
Write-Output "Version : $Version"
Write-Output "Files   : $fileCount"
Write-Output "Size    : $sizeMb MB"
