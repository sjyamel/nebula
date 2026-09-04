# Build a Tauraro UI program into a bootable UEFI application (BOOTX64.EFI),
# using tauraroc's turnkey `--target uefi-x64` (added 2026-09-04) -- unlike
# build-uefi.ps1, there is no hand-written boot.zig stub anywhere in this
# script: the compiler generates the equivalent glue (AllocatePool for a
# heap, GOP-locate for a framebuffer, call the program's exported entry)
# internally and drives `zig build-exe` itself. One tauraroc invocation, no
# separate link step.
#
#   .\scripts\build-uefi-turnkey.ps1
#   .\scripts\run-uefi.ps1 -OutDir build-uefi-turnkey -Build:$false
#
# `render.tr` needs no changes to work here: the compiler looks for a
# `pub export def` named `tauraro_uefi_main` first, falling back to
# `tauraro_ui_render` for source written against the older hand-glue
# convention (nebula's own render.tr uses the latter, unchanged) -- both with
# signature (fb: Pointer[u32], width: int, height: int, pitch: int) -> void.
# `tauraro_heap_init(base: Pointer[u8], size: usize) -> void`, if exported, is
# called first with a 16 MiB AllocatePool'd block.
#
# Kept as a SEPARATE script from build-uefi.ps1 (not a replacement) -- see
# CLAUDE.md's 2026-09-04 UEFI note: boot.zig/build-uefi.ps1 remain the
# reference for anything beyond the two-export convention (custom heap size,
# input devices, multiple windows).

param(
    [string]$Source = "examples\uefi_demo\render.tr",
    [string]$OutDir = "build-uefi-turnkey",
    [switch]$Strict
)

$ErrorActionPreference = "Stop"

$sdk = Join-Path $env:USERPROFILE ".taupkg\bin\tauraroc-windows-x64"
$tauraroc = Join-Path $sdk "tauraroc.exe"
if (-not (Test-Path $tauraroc)) { throw "missing tool: $tauraroc" }
if (-not (Test-Path $Source)) { throw "no such source file: $Source" }

$root = (Get-Location).Path
$out = Join-Path $root $OutDir
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Force $out | Out-Null

$srcFull = (Resolve-Path $Source).Path
$espDir = Join-Path $out "esp\EFI\BOOT"
New-Item -ItemType Directory -Force $espDir | Out-Null
$efi = Join-Path $espDir "BOOTX64.EFI"

# Build to a lowercase stem first, not directly to "BOOTX64.EFI": tauraroc's
# `-o` extension handling (ensure_ext) compares suffixes case-sensitively, so
# an uppercase ".EFI" target doesn't match its own appended lowercase ".efi"
# and gets a second suffix appended ("BOOTX64.EFI.efi"). Build "app" (->
# app.efi) then copy into the ESP layout under the exact case UEFI firmware
# expects for the removable-media boot path.
$appStem = Join-Path $out "app"
Push-Location $out
try {
    $trArgs = @($srcFull, "--target", "uefi-x64", "--freestanding", "-o", $appStem)
    if ($Strict) { $trArgs += "--strict" }
    & $tauraroc @trArgs
    if ($LASTEXITCODE -ne 0) { throw "tauraroc failed (exit $LASTEXITCODE)" }
} finally {
    Pop-Location
}
Copy-Item "$appStem.efi" $efi -Force

# Confirm we produced a genuine PE, not a stale/empty file.
$b = [System.IO.File]::ReadAllBytes($efi)
if ($b.Length -lt 2 -or $b[0] -ne 0x4D -or $b[1] -ne 0x5A) {
    throw "$efi does not start with the MZ signature -- not a valid PE"
}

Write-Host ""
Write-Host "built $efi" -ForegroundColor Green
Write-Host "  $((Get-Item $efi).Length) bytes, zero hand-written stub code"
Write-Host ""
Write-Host "boot it with:"
Write-Host "  .\scripts\run-uefi.ps1 -OutDir $OutDir -Build:`$false"
