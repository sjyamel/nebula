# Build (optionally) and run a --freestanding Tauraro program under QEMU,
# capturing its UART output to a .ppm.
#
#   .\scripts\run-bare.ps1 -Source examples\bare_demo\main.tr
#
# That single command replaces the two-step build-bare.ps1 + qemu-system-arm
# dance: it builds, boots the firmware under qemu-system-arm -M mps2-an385,
# waits for output to arrive and settle, kills the emulator (the firmware
# never halts -- there is no OS to exit to, so a timeout is the correct way to
# stop it), and splits the captured UART stream into the image and its
# trailing diagnostics.
#
# To run an already-built ELF without rebuilding:
#   .\scripts\run-bare.ps1 -Elf build-bare\app.elf -Build:$false

param(
    [string]$Source   = "examples\bare_demo\main.tr",
    [string]$Elf      = "build-bare\app.elf",
    [string]$OutDir   = "build-bare",
    [string]$Machine  = "mps2-an385",
    [int]$MaxSeconds  = 20,
    [bool]$Build      = $true
)

$ErrorActionPreference = "Stop"

$qemu = "C:\Program Files\qemu\qemu-system-arm.exe"
if (-not (Test-Path $qemu)) {
    throw "qemu-system-arm.exe not found at $qemu -- install with: winget install --id SoftwareFreedomConservancy.QEMU (run as admin), or pass a different path by editing this script."
}

if ($Build) {
    $buildScript = Join-Path $PSScriptRoot "build-bare.ps1"
    & $buildScript -Source $Source -OutDir $OutDir
    if ($LASTEXITCODE -ne 0) { throw "build-bare.ps1 failed" }
}

if (-not (Test-Path $Elf)) { throw "no ELF at $Elf -- build it first or pass -Elf" }
$elfFull = (Resolve-Path $Elf).Path
$workDir = Split-Path $elfFull

$rawOut = Join-Path $workDir "qemu_raw.txt"
$stderrFile = Join-Path $workDir "qemu_stderr.txt"
foreach ($f in @($rawOut, $stderrFile)) {
    if (Test-Path $f) { Remove-Item $f -Force }
}
# Pre-create empty so Get-Item never fails while qemu is still starting up.
New-Item -ItemType File -Path $rawOut -Force | Out-Null

Write-Host "booting $elfFull under qemu-system-arm -M $Machine"

# The firmware runs forever (no OS to return to), so it always has to be
# killed rather than allowed to exit -- there is no way around a timeout here.
#
# What changed from a naive Start-Process + RedirectStandardOutput approach:
# that pipes qemu's OWN stdout through Windows, and killing the process with
# Stop-Process -Force (TerminateProcess) does not let it flush that pipe --
# the file can come back completely empty depending on timing, which is
# exactly what happened the first time this ran on a machine other than the
# one that verified it. QEMU's own "-serial file:<path>" backend writes
# emulated-UART bytes straight to a file the moment the guest issues each MMIO
# write, independent of the host process's own stdout buffering, so a forced
# kill can no longer lose already-emitted data. Only whatever the firmware
# had not yet written by the time it is killed is missing, same as before.
$psi = Start-Process -FilePath $qemu `
    -ArgumentList @("-M", $Machine, "-nographic", "-serial", "file:$rawOut", "-monitor", "none", "-kernel", $elfFull) `
    -RedirectStandardError $stderrFile `
    -PassThru -WindowStyle Hidden

# Poll instead of a blind fixed sleep: stop as soon as output has stopped
# growing for a full second (the firmware finished emitting), or at MaxSeconds
# if it never settles.
$lastLen = -1
$stableSince = $null
$deadline = (Get-Date).AddSeconds($MaxSeconds)

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 300
    if ($psi.HasExited) { break }

    $len = (Get-Item $rawOut).Length
    if ($len -gt 0 -and $len -eq $lastLen) {
        if (-not $stableSince) { $stableSince = Get-Date }
        elseif (((Get-Date) - $stableSince).TotalMilliseconds -ge 1000) { break }
    } else {
        $stableSince = $null
    }
    $lastLen = $len
}

if (-not $psi.HasExited) {
    Stop-Process -Id $psi.Id -Force -ErrorAction SilentlyContinue
    # Give the OS a moment to release its handle on $rawOut before reading it.
    Start-Sleep -Milliseconds 200
}

if ((Get-Item $rawOut).Length -eq 0) {
    $hint = ""
    if ((Test-Path $stderrFile) -and (Get-Item $stderrFile).Length -gt 0) {
        $hint = " qemu stderr:`n" + (Get-Content $stderrFile -Raw)
    }
    throw "qemu produced no output after ${MaxSeconds}s -- the ELF may not have booted, or needs longer (try -MaxSeconds 30).$hint"
}

$lines = Get-Content $rawOut

# Split UART output into the PPM image and the trailing '#'-prefixed / 'parse:'
# diagnostic lines the demo prints after emitting the image, per the note in
# examples/bare_demo/main.tr about print() being the same stream as the image.
$imageLines = $lines | Where-Object { $_ -notmatch '^#' -and $_ -ne 'parse: ok' -and $_ -notmatch '^parse: \d+ issue' }
$diagLines  = $lines | Where-Object { $_ -match '^#' -or $_ -match '^parse:' }

$ppmPath = Join-Path $workDir "out.ppm"
$imageLines | Set-Content -Path $ppmPath -Encoding ascii

Write-Host ""
if ($imageLines.Count -ge 3 -and $imageLines[0] -eq "P3") {
    $dims = $imageLines[1]
    $declaredH = [int]($dims -split ' ')[1]
    $gotRows = $imageLines.Count - 3
    if ($gotRows -lt $declaredH) {
        Write-Host "wrote $ppmPath, but only $gotRows of $declaredH pixel rows arrived before the timeout -- it was killed too early. Re-run with a larger -MaxSeconds." -ForegroundColor Yellow
    } else {
        Write-Host "wrote $ppmPath  (P3, $dims)" -ForegroundColor Green
    }
} else {
    Write-Host "wrote $ppmPath, but it does not look like a P3 PPM -- check $rawOut" -ForegroundColor Yellow
}

if ($diagLines.Count -gt 0) {
    Write-Host ""
    Write-Host "diagnostics:"
    $diagLines | ForEach-Object { Write-Host "  $_" }
}
