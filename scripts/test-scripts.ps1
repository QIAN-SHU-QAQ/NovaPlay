<#
Regression tests for the packaging/deploy path boundaries.

These run on CI (after the unit tests) and locally. They create synthetic build
directories, so they never touch a real user profile, running app, or ACLs.

Covered cases:
  - package-portable.ps1 refuses BuildDir == staging dir and keeps the source.
  - package-portable.ps1 refuses OutputDir nested inside BuildDir.
  - package-portable.ps1 still produces a runnable ZIP for a valid build.
  - deploy-release.ps1 refuses TargetDir == BuildDir and keeps the source.
  - deploy-release.ps1 refuses TargetDir that is an ancestor of BuildDir.

Usage:
  powershell -ExecutionPolicy Bypass -File scripts\test-scripts.ps1
#>
$ErrorActionPreference = "Stop"

$packageScript = Join-Path $PSScriptRoot "package-portable.ps1"
$deployScript = Join-Path $PSScriptRoot "deploy-release.ps1"
$script:failures = @()
$tempRoots = @()

function New-TempRoot([string]$Name) {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("nova_script_test_" + $Name + "_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $root | Out-Null
    $script:tempRoots += $root
    return $root
}

# Minimal synthetic Flutter Windows release layout (enough for both scripts).
function New-FakeBuild([string]$Dir) {
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Dir "data\flutter_assets") -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $Dir "nova_play.exe") -Value "fake exe" -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $Dir "flutter_windows.dll") -Value "fake dll" -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $Dir "data\app.so") -Value "fake aot" -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $Dir "data\icudtl.dat") -Value "fake icu" -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $Dir "data\flutter_assets\NOTICES.Z") -Value "fake notices" -Encoding ASCII
}

function Test-SourceIntact([string]$Name, [string]$Dir) {
    $exe = Join-Path $Dir "nova_play.exe"
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        $script:failures += "$Name：失败后源目录被破坏：$Dir"
        Write-Host "FAIL: $Name (source destroyed)"
        return
    }
    Write-Host "PASS: $Name (source intact)"
}

function Run-ExpectFailure(
    [string]$Name,
    [string]$ScriptPath,
    [hashtable]$Arguments,
    [string]$ExpectedPattern
) {
    try {
        & $ScriptPath @Arguments *> $null
    } catch {
        if ("$_" -match $ExpectedPattern) {
            Write-Host "PASS: $Name"
            return
        }
        $script:failures += "$Name：错误消息不匹配：$_"
        Write-Host "FAIL: $Name (unexpected error: $_)"
        return
    }
    $script:failures += "$Name：应当失败但成功退出"
    Write-Host "FAIL: $Name (expected failure, got success)"
}

try {
    # 1. package: BuildDir == staging dir must fail before deleting anything.
    $root1 = New-TempRoot "pkg_stage_overlap"
    $dist1 = Join-Path $root1 "dist"
    $stage1 = Join-Path $dist1 "NovaPlay-1.0.0-windows-x64"
    New-FakeBuild $stage1
    Run-ExpectFailure "package: BuildDir == staging" $packageScript @{
        BuildDir = $stage1
        OutputDir = $dist1
        Version = "1.0.0"
    } "BuildDir 不能与 staging"
    Test-SourceIntact "package: BuildDir == staging" $stage1

    # 2. package: OutputDir nested inside BuildDir must fail.
    $root2 = New-TempRoot "pkg_output_inside"
    $build2 = Join-Path $root2 "build"
    New-FakeBuild $build2
    Run-ExpectFailure "package: OutputDir inside BuildDir" $packageScript @{
        BuildDir = $build2
        OutputDir = (Join-Path $build2 "dist")
        Version = "1.0.0"
    } "BuildDir 不能与"
    Test-SourceIntact "package: OutputDir inside BuildDir" $build2

    # 3. package: valid build still produces a runnable ZIP + checksum.
    $root3 = New-TempRoot "pkg_success"
    $build3 = Join-Path $root3 "build"
    New-FakeBuild $build3
    $out3 = Join-Path $root3 "dist"
    & $packageScript -BuildDir $build3 -OutputDir $out3 -Version "9.9.9" *> $null
    $zip3 = Join-Path $out3 "NovaPlay-9.9.9-windows-x64.zip"
    $sha3 = "$zip3.sha256"
    if (-not (Test-Path -LiteralPath $zip3)) {
        $script:failures += "package: 成功用例没有生成 ZIP"
        Write-Host "FAIL: package success (no zip)"
    } elseif (-not (Test-Path -LiteralPath $sha3)) {
        $script:failures += "package: 成功用例没有生成 SHA-256"
        Write-Host "FAIL: package success (no sha256)"
    } else {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [System.IO.Compression.ZipFile]::OpenRead($zip3)
        $entryNames = @($archive.Entries | ForEach-Object { $_.FullName })
        $archive.Dispose()
        $hasExe = $entryNames -contains "nova_play.exe"
        $hasData = @($entryNames | Where-Object { $_ -like "data*" }).Count -gt 0
        if ($hasExe -and $hasData) {
            Write-Host "PASS: package success (zip + sha256 + exe/data)"
        } else {
            $script:failures += "package: 成功用例的 ZIP 缺少运行文件"
            Write-Host "FAIL: package success (missing runnable files)"
        }
    }

    # 4. deploy: TargetDir == BuildDir must fail before clearing/stopping anything.
    $root4 = New-TempRoot "deploy_same"
    $build4 = Join-Path $root4 "run"
    New-FakeBuild $build4
    Run-ExpectFailure "deploy: TargetDir == BuildDir" $deployScript @{
        BuildDir = $build4
        TargetDir = $build4
        SkipShortcut = $true
    } "TargetDir 不能与 BuildDir"
    Test-SourceIntact "deploy: TargetDir == BuildDir" $build4

    # 5. deploy: TargetDir ancestor of BuildDir must fail.
    $root5 = New-TempRoot "deploy_parent"
    $parent5 = Join-Path $root5 "parent"
    $build5 = Join-Path $parent5 "run"
    New-FakeBuild $build5
    Run-ExpectFailure "deploy: TargetDir contains BuildDir" $deployScript @{
        BuildDir = $build5
        TargetDir = $parent5
        SkipShortcut = $true
    } "TargetDir 不能与 BuildDir"
    Test-SourceIntact "deploy: TargetDir contains BuildDir" $build5
} finally {
    foreach ($root in $script:tempRoots) {
        if (Test-Path -LiteralPath $root) {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($script:failures.Count -gt 0) {
    Write-Host ""
    Write-Host "脚本边界回归失败 $($script:failures.Count) 项：" -ForegroundColor Red
    foreach ($failure in $script:failures) { Write-Host " - $failure" -ForegroundColor Red }
    exit 1
}

Write-Host ""
Write-Host "脚本边界回归全部通过。"
