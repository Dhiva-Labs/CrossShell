<#
.SYNOPSIS
  Smoke test of an extracted Windows release (the unpacked zip) on the machine
  it was built for. Needs PowerShell 7.

.DESCRIPTION
    scripts\smoke-windows.ps1 -Dir <extracted-folder> [-NativeCapture] [-App]

  1. engine, synthetic backend: crossshell-host --synthetic serves its test
     pattern, crossshell-view --snapshot connects, decodes and saves a PNG.
  2. -NativeCapture: the same against the real desktop (DXGI Desktop
     Duplication), checking that a frame of the desktop's size arrives.
  3. -App: cross_shell.exe starts, renders, saves a picture of its own window
     (CROSSSHELL_SHOT) and has started the bundled crossshell-host.exe. A
     release build must also ignore the end-to-end test hooks (CROSSSHELL_TEST_*).
     The app runs with your real profile (it creates its identity and keys
     and starts the agent), so use this step on a throwaway machine such as a
     CI runner.

  Steps 1 and 2 keep the engine's runtime files in a private %LOCALAPPDATA%.
#>
param(
    [Parameter(Mandatory)]
    [string]$Dir,
    [switch]$NativeCapture,
    [switch]$App
)
$ErrorActionPreference = 'Stop'
$Dir = (Resolve-Path $Dir).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) "crossshell-smoke-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $tmp | Out-Null

# Run a program and wait for it, returning its exit code. GUI-subsystem
# programs (the engine and the app) write to redirected handles just the same.
function Invoke-Program([string]$Path, [string[]]$Arguments, [string]$Name, [string]$StdinFile, [int]$TimeoutSec = 120) {
    $p = @{
        FilePath               = $Path
        PassThru               = $true
        RedirectStandardOutput = "$tmp\$Name.out"
        RedirectStandardError  = "$tmp\$Name.err"
    }
    if ($Arguments) { $p.ArgumentList = $Arguments }
    if ($StdinFile) { $p.RedirectStandardInput = $StdinFile }
    $proc = Start-Process @p
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        Stop-Process -Id $proc.Id -Force
        throw "$Name did not exit within $TimeoutSec s"
    }
    $proc.WaitForExit()
    return $proc.ExitCode
}

function Show-Logs([string]$Name) {
    foreach ($ext in 'out', 'err') {
        $f = "$tmp\$Name.$ext"
        if ((Test-Path $f) -and (Get-Item $f).Length -gt 0) {
            Write-Host "--- $Name.$ext"
            Get-Content $f | ForEach-Object { Write-Host $_ }
        }
    }
}

function Wait-ForFile([string]$Path, [int]$Seconds) {
    for ($i = 0; $i -lt $Seconds * 5; $i++) {
        if ((Test-Path $Path) -and (Get-Item $Path).Length -gt 0) { return }
        Start-Sleep -Milliseconds 200
    }
    throw "timed out after $Seconds s waiting for $Path"
}

function Get-PngSize([string]$Path) {
    $b = [IO.File]::ReadAllBytes($Path)
    $sig = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
    for ($i = 0; $i -lt 8; $i++) { if ($b[$i] -ne $sig[$i]) { throw "$Path is not a PNG file" } }
    $w = ([int]$b[16] -shl 24) -bor ([int]$b[17] -shl 16) -bor ([int]$b[18] -shl 8) -bor [int]$b[19]
    $h = ([int]$b[20] -shl 24) -bor ([int]$b[21] -shl 16) -bor ([int]$b[22] -shl 8) -bor [int]$b[23]
    return @{ Width = $w; Height = $h; Bytes = $b.Length }
}

# host (--synthetic or native) on a private runtime dir, then view --snapshot.
function Test-Engine([string]$Name, [int]$Port, [string[]]$HostArgs, [int]$Frames) {
    $local = Join-Path $tmp "$Name-localappdata"
    New-Item -ItemType Directory -Path $local | Out-Null
    $saved = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = $local
    $hostProc = $null
    try {
        $hostProc = Start-Process -FilePath "$Dir\crossshell-host.exe" -PassThru `
            -ArgumentList ($HostArgs + @('--no-clipboard', '--port', "$Port")) `
            -RedirectStandardOutput "$tmp\$Name-host.out" -RedirectStandardError "$tmp\$Name-host.err"
        $info = "$local\CrossShell\host.json"
        Wait-ForFile $info 20
        $token = (Get-Content -Raw $info | ConvertFrom-Json).token
        Set-Content -Path "$tmp\$Name.token" -Value $token
        $png = "$tmp\$Name.png"
        $code = Invoke-Program "$Dir\crossshell-view.exe" @('--port', "$Port", '--snapshot', $png, '--frames', "$Frames") `
            "$Name-view" "$tmp\$Name.token" 150
        Show-Logs "$Name-view"
        if ($code -ne 0) { Show-Logs "$Name-host"; throw "crossshell-view --snapshot exited with $code" }
        return Get-PngSize $png
    } finally {
        if ($hostProc -and -not $hostProc.HasExited) { Stop-Process -Id $hostProc.Id -Force }
        $env:LOCALAPPDATA = $saved
    }
}

try {
    Write-Host '== versions'
    foreach ($exe in 'crossshell-host', 'crossshell-view') {
        $code = Invoke-Program "$Dir\$exe.exe" @('--version') "$exe-version"
        Show-Logs "$exe-version"
        if ($code -ne 0) { throw "$exe --version exited with $code" }
    }

    Write-Host '== 1. synthetic backend: host -> view --snapshot'
    $s = Test-Engine 'synthetic' 47831 @('--synthetic') 30
    "synthetic snapshot: $($s.Width)x$($s.Height), $($s.Bytes) bytes"
    if ($s.Width -ne 1280 -or $s.Height -ne 720 -or $s.Bytes -lt 1000) { throw 'unexpected synthetic snapshot' }

    if ($NativeCapture) {
        Write-Host '== 2. native backend (DXGI Desktop Duplication): host -> view --snapshot'
        Add-Type -AssemblyName System.Windows.Forms
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        "primary screen: $($screen.Width)x$($screen.Height)"
        $n = Test-Engine 'native' 47832 @() 5
        "native snapshot: $($n.Width)x$($n.Height), $($n.Bytes) bytes"
        if ($n.Width -lt 640 -or $n.Height -lt 480) { throw 'unexpected native snapshot size' }
    }

    if ($App) {
        Write-Host '== 3. app: render a frame and start the bundled agent'
        # The app finds its folders through the Windows known-folder API, so
        # it needs the real profile; clear what an earlier run left behind.
        $agentDir = Join-Path $env:LOCALAPPDATA 'CrossShell'
        Get-Process -Name 'crossshell-host' -ErrorAction SilentlyContinue | Stop-Process -Force
        Remove-Item -Force -ErrorAction SilentlyContinue "$agentDir\host.json"
        $env:CROSSSHELL_SHOT = "$tmp\app.png"
        $env:CROSSSHELL_SHOT_DELAY = '8'
        $env:CROSSSHELL_TEST_LOG = "$tmp\hooks.log"
        $env:CROSSSHELL_TEST_AUTOCONFIRM = '1'
        # The app starts crossshell-host.exe (next to it) when it opens, and
        # exits by itself once it has saved the picture.
        $appProc = Start-Process -FilePath "$Dir\cross_shell.exe" -PassThru `
            -RedirectStandardOutput "$tmp\app.out" -RedirectStandardError "$tmp\app.err"
        $started = Get-Date
        while (-not $appProc.HasExited -and ((Get-Date) - $started).TotalSeconds -lt 120) {
            Start-Sleep -Seconds 1
            $appProc.Refresh()
        }
        if (-not $appProc.HasExited) {
            Write-Host 'the app is still running after 120 s'
            "window handle $($appProc.MainWindowHandle), title '$($appProc.MainWindowTitle)', responding $($appProc.Responding)"
            "picture saved: $(Test-Path $env:CROSSSHELL_SHOT); agent info written: $(Test-Path "$agentDir\host.json")"
            Show-Logs 'app'
            Write-Host '--- files written since the start'
            foreach ($root in $env:APPDATA, $env:LOCALAPPDATA, $tmp) {
                Get-ChildItem -Path $root -Recurse -File -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -gt $started } |
                    ForEach-Object { Write-Host ('{0,10} {1}' -f $_.Length, $_.FullName) }
            }
            Stop-Process -Id $appProc.Id -Force
            throw 'cross_shell.exe did not exit'
        }
        $code = $appProc.ExitCode
        Show-Logs 'app'
        if ($code -ne 0) { throw "cross_shell.exe exited with $code" }
        if (-not (Test-Path $env:CROSSSHELL_SHOT)) { throw 'the app saved no picture' }
        $png = Get-PngSize $env:CROSSSHELL_SHOT
        "app picture: $($png.Width)x$($png.Height), $($png.Bytes) bytes"
        if ($png.Width -lt 600 -or $png.Height -lt 400) { throw 'unexpected app picture size' }
        $release = (-not $env:CROSSSHELL_BUILD_MODE) -or ($env:CROSSSHELL_BUILD_MODE -eq 'release')
        if ($release -and (Test-Path $env:CROSSSHELL_TEST_LOG)) {
            throw "this release build honoured the end-to-end test hooks: $(Get-Content -Raw $env:CROSSSHELL_TEST_LOG)"
        }
        if (-not (Test-Path "$agentDir\host.json")) { throw 'the app did not start crossshell-host.exe' }
        $m = Get-Content -Raw "$agentDir\host.json" | ConvertFrom-Json
        "agent started by the app: pid $($m.pid) port $($m.port) ver $($m.ver)"
        Stop-Process -Id $m.pid -Force -ErrorAction SilentlyContinue
    }
    Write-Host 'smoke test passed'
} finally {
    Get-Process -Name 'crossshell-host', 'crossshell-view', 'cross_shell' -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
