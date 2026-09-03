# Build a Tauraro UI program into a bootable UEFI application (BOOTX64.EFI),
# on Windows, using only the compiler SDK's bundled zig -- no gnu-efi, no
# separate EDK2 build, nothing beyond what's already installed.
#
#   .\scripts\build-uefi.ps1
#   .\scripts\run-uefi.ps1
#
# Unlike the Cortex-M path (build-bare.ps1), there is no --emit-ld and no
# @entry in the Tauraro source: UEFI firmware IS the boot glue (reset
# vectors, memory setup, the boot menu all already happened before anything
# here runs), and Tauraro's --freestanding only generates that machinery for
# Cortex-M and RISC-V. So the shape here is different: Tauraro compiles a
# plain callable function to C, a small hand-written zig stub (boot.zig)
# provides the real UEFI entry point and calls it, and `zig build-exe` links
# the two together directly -- it accepts .zig and .c sources in one
# invocation, so no separate object-file or linker-script step is needed.

param(
    [string]$Source  = "examples\uefi_demo\render.tr",
    [string]$Stub    = "examples\uefi_demo\boot.zig",
    [string]$OutDir  = "build-uefi",
    [switch]$Strict
)

$ErrorActionPreference = "Stop"

$sdk = "C:\Users\HomePC\.taupkg\bin\tauraroc-windows-x64"
$tauraroc = Join-Path $sdk "tauraroc.exe"
$zig = Join-Path $sdk "zig\zig.exe"

foreach ($tool in @($tauraroc, $zig)) {
    if (-not (Test-Path $tool)) { throw "missing tool: $tool" }
}
foreach ($src in @($Source, $Stub)) {
    if (-not (Test-Path $src)) { throw "no such source file: $src" }
}

$root = (Get-Location).Path
$out = Join-Path $root $OutDir
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Force $out | Out-Null

# --- 1. Tauraro -> freestanding C (no --emit-ld: UEFI needs no linker script,
#        the firmware's own PE loader handles that) -------------------------
$srcFull = (Resolve-Path $Source).Path

Push-Location $out
try {
    $trArgs = @($srcFull, "--freestanding", "--emit", "c")
    if ($Strict) { $trArgs += "--strict" }
    & $tauraroc @trArgs
    if ($LASTEXITCODE -ne 0) { throw "tauraroc failed (exit $LASTEXITCODE)" }
} finally {
    Pop-Location
}

# --- 2. zig + generated C -> BOOTX64.EFI, one invocation --------------------
#
# -U_WIN32 -U_WIN64 -U_MSC_VER: zig's x86_64-uefi target predefines these
# (UEFI genuinely shares the Microsoft x64 calling convention and PE format,
# so this is a deliberate zig choice, not a bug in zig). tauraro_rt.h treats
# bare _WIN32 as "real hosted Windows, windows.h/psapi/bcrypt are available"
# without checking TAURARO_KERNEL first -- a real gap in the runtime header,
# see tau_bugs.txt. Undefining them here is the workaround until that's
# fixed upstream.
$csrc = Get-ChildItem -Path (Join-Path $out "build") -Recurse -Filter *.c | ForEach-Object { $_.FullName }
if ($csrc.Count -eq 0) { throw "tauraroc emitted no C sources" }

$stubFull = (Resolve-Path $Stub).Path
Write-Host "linking boot.zig + $($csrc.Count) C file(s) for x86_64-uefi"

$espDir = Join-Path $out "esp\EFI\BOOT"
New-Item -ItemType Directory -Force $espDir | Out-Null
$elf = Join-Path $espDir "BOOTX64.EFI"
$log = Join-Path $out "build.log"

$inc = Join-Path $out "build\include"
$quotedC = ($csrc | ForEach-Object { '"' + $_ + '"' }) -join ' '

# -cflags ... -- : zig build-exe requires C-only flags (here, the -U's that
# undefine zig's UEFI-target Windows-ABI predefines -- see the comment above)
# to be bracketed and placed before the .c sources they apply to; a bare
# top-level -U_WIN32 is rejected as an unrecognized build-exe option. The
# .zig stub is a separate positional argument outside that bracket.
#
# Redirect through cmd, not PowerShell's 2>&1: in PS 5.1 a native tool's
# stderr redirected that way comes back as ErrorRecords and trips
# ErrorActionPreference=Stop even on a clean, successful build.
$cmdline = '"' + $zig + '" build-exe' +
           ' -target x86_64-uefi -mcpu baseline' +
           ' -I "' + (Join-Path $out "build") + '" -I "' + $inc + '"' +
           ' -cflags -U_WIN32 -U_WIN64 -U_MSC_VER -- ' + $quotedC +
           ' "' + $stubFull + '"' +
           ' -fno-strip -femit-bin="' + $elf + '"' +
           ' > "' + $log + '" 2>&1'
& cmd /c $cmdline

if ($LASTEXITCODE -ne 0) {
    Write-Host "build FAILED -- errors:" -ForegroundColor Red
    Select-String -Path $log -Pattern "error:" | Select-Object -First 20 -ExpandProperty Line
    throw "zig build-exe failed (exit $LASTEXITCODE); full log at $log"
}

# --- 3. Confirm we produced a genuine PE, not a stale/empty file -----------
$b = [System.IO.File]::ReadAllBytes($elf)
if ($b.Length -lt 2 -or $b[0] -ne 0x4D -or $b[1] -ne 0x5A) {
    throw "$elf does not start with the MZ signature -- not a valid PE"
}

Write-Host ""
Write-Host "built $elf" -ForegroundColor Green
Write-Host "  $((Get-Item $elf).Length) bytes"
Write-Host ""
Write-Host "run it with:"
Write-Host "  .\scripts\run-uefi.ps1"
