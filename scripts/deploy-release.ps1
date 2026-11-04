<#
Deploy the Windows release build to the runnable folder.

Why this exists:
  Flutter builds produced inside a sandboxed/agent environment inherit NTFS
  Low integrity labels. Windows then starts the app at Low IL, and media_kit
  cannot create its temp playlist file under %TEMP% (PathAccessException,
  errno=5) - video playback fails. This script copies the build, resets the
  labels to Medium for the whole folder, and updates the desktop shortcut.

Usage (from the repo root):
  powershell -ExecutionPolicy Bypass -File scripts\deploy-release.ps1
#>
param(
    [string]$ProjectRoot = "E:\dev\NovaPlay",
    [string]$TargetDir   = "E:\项目\NovaPlay\运行版",
    [string]$Shortcut    = "$env:USERPROFILE\Desktop\NovaPlay.lnk"
)

$ErrorActionPreference = "Stop"

$release = Join-Path $ProjectRoot "build\windows\x64\runner\Release"
$exeSource = Join-Path $release "nova_play.exe"
if (-not (Test-Path $exeSource)) {
    throw "Release build not found: $exeSource (run 'flutter build windows --release' first)"
}

Get-Process nova_play -ErrorAction SilentlyContinue | Stop-Process -Force

New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
Get-ChildItem $TargetDir -Exclude "启动截图.png" | Remove-Item -Recurse -Force
Copy-Item (Join-Path $release "*") $TargetDir -Recurse -Force

$readme = Join-Path $ProjectRoot "README.md"
if (Test-Path $readme) {
    Copy-Item $readme (Join-Path $TargetDir "README.md") -Force
}

# Reset integrity labels AFTER copying (copy may preserve Low labels).
& icacls $TargetDir /setintegritylevel Medium /T | Out-Null
$low = (& icacls $TargetDir /T) | Select-String "Low Mandatory"
if ($low) {
    throw "Some files still have Low integrity labels; check permissions and rerun icacls."
}

# Update desktop shortcut.
$exe = Join-Path $TargetDir "nova_play.exe"
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut($Shortcut)
$link.TargetPath = $exe
$link.WorkingDirectory = $TargetDir
$link.Save()

Write-Host "Deployed: $TargetDir"
Write-Host "Shortcut: $Shortcut"
