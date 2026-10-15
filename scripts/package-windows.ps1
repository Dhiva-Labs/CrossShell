<#
.SYNOPSIS
  Package the Windows release on the machine that built it (x64 or arm64).

.DESCRIPTION
  Expects the Flutter release build (app\build\windows\<arch>\runner\Release)
  and the native Rust engine build (engine\target\release). Copies
  crossshell-host.exe and crossshell-view.exe next to cross_shell.exe, where
  the app looks for them, and writes dist\crossshell-<ver>-windows-<arch>.zip
  with the files at the zip root (the same layout as the x64 release built by
  scripts/build-windows.sh).

  The architecture comes from the machine (PROCESSOR_ARCHITECTURE) unless
  -Arch is given. Flutter cannot cross-compile Windows, so each architecture
  is built on a machine of that architecture (CI uses windows-latest for x64
  and windows-11-arm for arm64).

    scripts\package-windows.ps1 [-Arch x64|arm64] [-OutDir dist]
#>
param(
    [ValidateSet('x64', 'arm64')]
    [string]$Arch,
    [string]$OutDir,
    [string]$EngineDir,
    # CROSSSHELL_BUILD_MODE=profile keeps the end-to-end test hooks (lib/dev/).
    [ValidateSet('release', 'profile')]
    [string]$Mode = $(if ($env:CROSSSHELL_BUILD_MODE) { $env:CROSSSHELL_BUILD_MODE } else { 'release' })
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

if (-not $Arch) {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { $Arch = 'x64' }
        'ARM64' { $Arch = 'arm64' }
        default { throw "unsupported PROCESSOR_ARCHITECTURE '$env:PROCESSOR_ARCHITECTURE' (AMD64 or ARM64)" }
    }
}
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }
if (-not $EngineDir) { $EngineDir = Join-Path $root 'engine\target\release' }

$versionLine = Select-String -Path (Join-Path $root 'engine\Cargo.toml') -Pattern '^version\s*=\s*"([^"]+)"' |
    Select-Object -First 1
if (-not $versionLine) { throw 'no version in engine\Cargo.toml' }
$version = $versionLine.Matches[0].Groups[1].Value

$modeDir = (Get-Culture).TextInfo.ToTitleCase($Mode)
$release = Join-Path $root "app\build\windows\$Arch\runner\$modeDir"
if (-not (Test-Path (Join-Path $release 'cross_shell.exe'))) {
    throw "$release\cross_shell.exe not found: run 'flutter build windows --$Mode' first"
}
foreach ($exe in 'crossshell-host.exe', 'crossshell-view.exe') {
    $src = Join-Path $EngineDir $exe
    if (-not (Test-Path $src)) {
        throw "$src not found: run 'cargo build --release -p crossshell-host -p crossshell-view' in engine first"
    }
    Copy-Item -Force $src $release
}

$name = "crossshell-$version-windows-$Arch"
if ($Mode -ne 'release') { $name = "$name-$Mode" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$zip = Join-Path (Resolve-Path $OutDir).Path "$name.zip"
if (Test-Path $zip) { Remove-Item $zip }

# [IO.Compression.ZipFile] on PowerShell 7 / .NET writes '/' separators in the
# entry names; Windows PowerShell 5's Compress-Archive writes '\'.
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory(
    $release, $zip, [IO.Compression.CompressionLevel]::Optimal, $false)
Write-Host "built $zip"
