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
# OVMF firmware: tries two install layouts (whichever is present), since
# different QEMU distributions ship it differently --
#   1. winget's SoftwareFreedomConservancy.QEMU package: a single
#      self-contained "C:\Program Files\qemu\share\edk2-x86_64-code.fd" (code
#      + variable store combined) -- one read-only pflash drive is enough.
#   2. MSYS2's mingw-w64-x86_64-qemu package: SPLIT code/vars images
#      (edk2-x86_64-code.fd has no variable store of its own) -- booting with
#      only that file as a single read-only pflash drive fails to load at
#      all; needs a SECOND, writable pflash drive for vars (a fresh zeroed
#      4 MiB image is fine -- OVMF initializes it on first boot).
# Pass -Qemu/-OvmfCode/-OvmfVars to override auto-detection entirely.

param(
    [string]$Source     = "examples\uefi_demo\render.tr",
    [string]$Stub       = "examples\uefi_demo\boot.zig",
    [string]$OutDir     = "build-uefi",
    [bool]$Build        = $true,
    [switch]$NoWindow,
    [bool]$Screenshot   = $true,
    # MSYS2's OVMF build shows its own TianoCore boot-manager menu before
    # loading BOOTX64.EFI (dismissed automatically via a `sendkey ret` nudge,
    # below) -- 10s wasn't enough headroom for menu-dismiss + actual app
    # boot together in practice; 20s was reliable. Override lower for the
    # winget OVMF (no menu, boots BOOTX64.EFI immediately).
    [int]$BootSeconds   = 20,
    [string]$Qemu       = "",
    [string]$OvmfCode   = "",
    [string]$OvmfVars   = ""
)

$ErrorActionPreference = "Stop"

$needsVarsDrive = $false
if ($Qemu -eq "" -or $OvmfCode -eq "") {
    $wingetQemu = "C:\Program Files\qemu\qemu-system-x86_64.exe"
    $wingetOvmf = "C:\Program Files\qemu\share\edk2-x86_64-code.fd"
    $msys2Qemu  = "C:\msys64\mingw64\bin\qemu-system-x86_64.exe"
    $msys2Ovmf  = "C:\msys64\mingw64\share\qemu\edk2-x86_64-code.fd"

    if ((Test-Path $wingetQemu) -and (Test-Path $wingetOvmf)) {
        if ($Qemu -eq "") { $Qemu = $wingetQemu }
        if ($OvmfCode -eq "") { $OvmfCode = $wingetOvmf }
    } elseif ((Test-Path $msys2Qemu) -and (Test-Path $msys2Ovmf)) {
        if ($Qemu -eq "") { $Qemu = $msys2Qemu }
        if ($OvmfCode -eq "") { $OvmfCode = $msys2Ovmf }
        $needsVarsDrive = $true
    } else {
        throw "no QEMU+OVMF install found (checked $wingetQemu and $msys2Qemu) -- " +
              "install with: winget install --id SoftwareFreedomConservancy.QEMU (run as admin), " +
              "or: pacman -S mingw-w64-x86_64-qemu"
    }
}
foreach ($f in @($Qemu, $OvmfCode)) {
    if (-not (Test-Path $f)) { throw "missing: $f" }
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
    "-drive", "`"if=pflash,format=raw,readonly=on,file=$OvmfCode`""
)

if ($needsVarsDrive) {
    # Split OVMF (MSYS2's package): needs its own writable vars store, or the
    # firmware never loads at all ("could not load PC BIOS" from a single
    # read-only code-only pflash drive). A fresh zeroed 4 MiB image per
    # $OutDir is fine -- OVMF initializes it on first boot; not reused across
    # builds since $OutDir is wiped by build-uefi.ps1/build-uefi-turnkey.ps1
    # each run anyway.
    if ($OvmfVars -eq "") {
        $OvmfVars = Join-Path (Resolve-Path $OutDir).Path "ovmf_vars.fd"
        $fs = [System.IO.File]::Create($OvmfVars)
        $fs.SetLength(4MB)
        $fs.Close()
    }
    $argParts += @("-drive", "`"if=pflash,format=raw,file=$OvmfVars`"")
}

$argParts += @(
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

    # Built from an ABSOLUTE resolved base, not a bare relative Join-Path:
    # .NET file APIs (ReadAllBytes, used by ppm-to-png.ps1) resolve relative
    # paths against [Environment]::CurrentDirectory, which PowerShell's
    # Set-Location does not reliably keep in sync with $PWD across a
    # long-lived host process -- a relative $shotPpm silently resolved
    # against a stale directory from an unrelated earlier command in the
    # same session, "finding" nothing at a path in the wrong repo entirely.
    $shotPpm = Join-Path (Resolve-Path $OutDir).Path "screenshot.ppm"
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

            # MSYS2's OVMF build sits at its own TianoCore splash / boot-manager
            # menu waiting for a keypress before it ever loads BOOTX64.EFI --
            # confirmed by an early screendump showing only the TianoCore logo
            # after 20s with nothing sent. `sendkey ret` a couple of times
            # nudges it through the menu to the default (only) boot entry,
            # same as a human pressing Enter at the console -- harmless once
            # already past the menu (an extra Enter reaching our own app's
            # click-only event loop is a no-op). Then the real boot-time wait.
            1..3 | ForEach-Object {
                $kb = [System.Text.Encoding]::ASCII.GetBytes("sendkey ret`n")
                $stream.Write($kb, 0, $kb.Length)
                Start-Sleep -Milliseconds 500
            }
            while ($stream.DataAvailable) { $stream.ReadByte() | Out-Null }
            Start-Sleep -Seconds $BootSeconds

            # QEMU's HMP line reader treats backslash as an escape prefix
            # (confirmed: a raw Windows path triggers "unsupported escape
            # code: '\U'"), so backslashes must become forward slashes first
            # (Windows accepts either) -- and the whole thing still needs
            # quoting for the space in a username like "Yusee Habibu".
            $ppmPathFwd = (Resolve-Path $OutDir).Path.Replace('\', '/') + "/screenshot.ppm"
            $cmd = 'screendump "' + $ppmPathFwd + '"' + "`n"
            $bytes = [System.Text.Encoding]::ASCII.GetBytes($cmd)
            $stream.Write($bytes, 0, $bytes.Length)
            Start-Sleep -Seconds 1
            # Read back whatever HMP echoed (its own error text, if any) so a
            # failed screendump is diagnosable instead of just "no screenshot".
            $replyBytes = New-Object System.Collections.Generic.List[byte]
            while ($stream.DataAvailable) { $replyBytes.Add([byte]$stream.ReadByte()) }
            if ($replyBytes.Count -gt 0) {
                $reply = [System.Text.Encoding]::ASCII.GetString($replyBytes.ToArray()).Trim()
                if ($reply -ne "") { Write-Host "monitor reply: $reply" -ForegroundColor DarkGray }
            }
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
