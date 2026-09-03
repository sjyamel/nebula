# Build (optionally) and boot a Tauraro UEFI app under QEMU + OVMF, with a
# real graphical window -- this is the whole point of the UEFI target over
# the Cortex-M/UART one: no PPM capture step, QEMU just shows it.
#
#   .\scripts\run-uefi.ps1
#
# Also captures an automated screendump via QEMU's monitor so this can be
# verified without a human watching the window (-Screenshot, on by default).
# Pass -NoWindow to skip opening the interactive gtk window entirely, e.g.
# for a quick unattended check.
#
# QEMU ships OVMF itself (share\edk2-x86_64-code.fd) -- nothing else to
# install.

param(
    [string]$Source     = "examples\uefi_demo\render.tr",
    [string]$Stub       = "examples\uefi_demo\boot.zig",
    [string]$OutDir     = "build-uefi",
    [bool]$Build        = $true,
    [switch]$NoWindow,
    [bool]$Screenshot   = $true,
    [int]$BootSeconds   = 10
)

$ErrorActionPreference = "Stop"

$qemu = "C:\Program Files\qemu\qemu-system-x86_64.exe"
$ovmf = "C:\Program Files\qemu\share\edk2-x86_64-code.fd"
foreach ($f in @($qemu, $ovmf)) {
    if (-not (Test-Path $f)) { throw "missing: $f -- install with: winget install --id SoftwareFreedomConservancy.QEMU (run as admin)" }
}

if ($Build) {
    $buildScript = Join-Path $PSScriptRoot "build-uefi.ps1"
    & $buildScript -Source $Source -Stub $Stub -OutDir $OutDir
    if ($LASTEXITCODE -ne 0) { throw "build-uefi.ps1 failed" }
}

$espRoot = Join-Path (Resolve-Path $OutDir).Path "esp"
$elf = Join-Path $espRoot "EFI\BOOT\BOOTX64.EFI"
if (-not (Test-Path $elf)) { throw "no BOOTX64.EFI at $elf -- build it first" }

# A single pre-quoted string, not a -ArgumentList array: PowerShell 5.1's
# Start-Process does not reliably quote array elements that contain spaces,
# and both the OVMF firmware path and the ESP directory are typically under
# "C:\Program Files\..." -- an unquoted array element there gets split at
# the space and QEMU reports "Could not open 'C:\Program'".
$argParts = @(
    "-M", "q35", "-m", "256",
    "-drive", "`"if=pflash,format=raw,readonly=on,file=$ovmf`"",
    "-drive", "`"format=raw,file=fat:rw:$espRoot`"",
    "-vga", "std"
)

if ($NoWindow) {
    $argParts += @("-display", "none")
} else {
    $argParts += @("-display", "gtk")
}

if ($Screenshot) {
    $monPort = 45500 + (Get-Random -Maximum 400)
    $argParts += @("-monitor", "telnet:127.0.0.1:$monPort,server,nowait")
} else {
    $argParts += @("-monitor", "none")
}

$argString = $argParts -join ' '

Write-Host "booting $elf under qemu-system-x86_64 -M q35 (OVMF)"
if (-not $NoWindow) {
    Write-Host "a QEMU window should open shortly -- close it, or Ctrl+C here, when done."
}

$qemuErrLog = Join-Path $OutDir "qemu_stderr.txt"
if (Test-Path $qemuErrLog) { Remove-Item $qemuErrLog -Force }
$psi = Start-Process -FilePath $qemu -ArgumentList $argString -PassThru -WindowStyle Normal -RedirectStandardError $qemuErrLog

if ($Screenshot) {
    if ($psi.HasExited) {
        Write-Host "qemu exited immediately (code $($psi.ExitCode)) -- it never got to boot anything" -ForegroundColor Red
    }

    $shotPpm = Join-Path $OutDir "screenshot.ppm"
    if (Test-Path $shotPpm) { Remove-Item $shotPpm -Force }

    # The monitor's telnet listener binds at qemu startup, well before OVMF
    # finishes its own boot, but retry rather than assuming the first
    # connection attempt lands -- a single fixed sleep before one attempt was
    # unreliable in practice.
    # The monitor socket binds almost immediately at qemu startup -- that is
    # NOT the same as OVMF (and then our app) having finished booting, so this
    # loop only waits for the socket, then a separate sleep below covers the
    # actual boot time before the screenshot is taken.
    $client = $null
    $connectDeadline = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $connectDeadline) {
        try {
            $client = New-Object System.Net.Sockets.TcpClient("127.0.0.1", $monPort)
            break
        } catch {
            Start-Sleep -Milliseconds 300
        }
    }

    if ($null -ne $client) {
        Start-Sleep -Seconds $BootSeconds
    }

    if ($null -eq $client) {
        Write-Host "could not reach the QEMU monitor on port $monPort within 5s" -ForegroundColor Yellow
        if ($psi.HasExited) {
            Write-Host "qemu has exited (code $($psi.ExitCode))" -ForegroundColor Red
        }
        if ((Test-Path $qemuErrLog) -and (Get-Item $qemuErrLog).Length -gt 0) {
            Write-Host "qemu stderr:"
            Get-Content $qemuErrLog | ForEach-Object { Write-Host "  $_" }
        }
    } else {
        try {
            $stream = $client.GetStream()
            Start-Sleep -Milliseconds 500
            # Drain the HMP banner so it doesn't end up inside the .ppm path arg.
            while ($stream.DataAvailable) { $stream.ReadByte() | Out-Null }

            $cmd = "screendump " + (Resolve-Path $OutDir).Path + "\screenshot.ppm`n"
            $bytes = [System.Text.Encoding]::ASCII.GetBytes($cmd)
            $stream.Write($bytes, 0, $bytes.Length)
            Start-Sleep -Seconds 1
            $stream.Close()
            $client.Close()
        } catch {
            Write-Host "monitor connected but screendump failed ($_)" -ForegroundColor Yellow
        }
    }

    if (Test-Path $shotPpm) {
        $pngScript = Join-Path $PSScriptRoot "ppm-to-png.ps1"
        & $pngScript -Ppm $shotPpm -Scale 1
    } else {
        Write-Host "no screenshot captured -- the app may still be mid-boot; try -BootSeconds larger" -ForegroundColor Yellow
    }
}

if ($NoWindow) {
    Start-Sleep -Seconds 2
    if (-not $psi.HasExited) {
        Stop-Process -Id $psi.Id -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-Host ""
    Write-Host "QEMU is running in its own window (PID $($psi.Id)). Close it when done."
}
