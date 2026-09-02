# Build a --freestanding Tauraro program into a Cortex-M ELF, on Windows,
# using only the compiler SDK's bundled zig. No arm-none-eabi-gcc required.
#
#   .\scripts\build-bare.ps1 -Source examples\bare_demo\main.tr
#   qemu-system-arm -M mps2-an385 -nographic -kernel build-bare\app.elf
#
# The flags here differ from the ones in the upstream docs, which do not work
# with the bundled zig. Both differences were found by trying the documented
# command and reading the linker errors:
#
#   1. The docs pass -nostdlib. With zig that also drops compiler_rt, so every
#      64-bit and soft-float helper the Cortex-M3 lacks comes back as
#      "undefined symbol: __aeabi_dsub" (and dmul, d2iz, i2d, uldivmod, ...).
#      Use -nostartfiles instead: it keeps compiler_rt while still leaving out
#      the C runtime startup files, which is what a bare-metal image actually
#      needs. The arm-none-eabi-gcc path solves the same problem with -lgcc.
#
#   2. zig enables UBSan by default, which needs __ubsan_handle_* at link time.
#      Nothing provides those freestanding, so turn it off explicitly.

param(
    [Parameter(Mandatory = $true)]
    [string]$Source,

    [string]$OutDir = "build-bare",
    [string]$Cpu    = "cortex_m3",
    [string]$Target = "thumb-freestanding-eabi",
    [switch]$Strict
)

$ErrorActionPreference = "Stop"

$sdk = "C:\Users\HomePC\.taupkg\bin\tauraroc-windows-x64"
$tauraroc = Join-Path $sdk "tauraroc.exe"
$zig = Join-Path $sdk "zig\zig.exe"

foreach ($tool in @($tauraroc, $zig)) {
    if (-not (Test-Path $tool)) { throw "missing tool: $tool" }
}
if (-not (Test-Path $Source)) { throw "no such source file: $Source" }

$root = (Get-Location).Path
$out = Join-Path $root $OutDir
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Force $out | Out-Null

# --- 1. Tauraro -> freestanding C + linker script -------------------------
# tauraroc writes its C into build/ relative to the CWD, so run it from $out.
$ld = Join-Path $out "app.ld"
# Resolve before the Push-Location below, and accept an already-absolute path.
$srcFull = (Resolve-Path $Source).Path

Push-Location $out
try {
    $trArgs = @($srcFull, "--freestanding", "--emit", "c", "--emit-ld", $ld)
    if ($Strict) { $trArgs += "--strict" }
    & $tauraroc @trArgs
    if ($LASTEXITCODE -ne 0) { throw "tauraroc failed (exit $LASTEXITCODE)" }
} finally {
    Pop-Location
}

# --- 2. Freestanding C -> Cortex-M ELF via bundled zig --------------------
$csrc = Get-ChildItem -Path (Join-Path $out "build") -Recurse -Filter *.c | ForEach-Object { $_.FullName }
if ($csrc.Count -eq 0) { throw "tauraroc emitted no C sources" }
Write-Host "compiling $($csrc.Count) C file(s) for $Target / $Cpu"

$elf = Join-Path $out "app.elf"
$log = Join-Path $out "link.log"

# Redirect through cmd rather than PowerShell. In PS 5.1 a native command's
# stderr redirected with 2>&1 comes back as ErrorRecords, which trips
# ErrorActionPreference=Stop even when the linker only emitted a warning and
# exited 0. (ld.lld always warns "cannot find entry symbol _start" here; on
# Cortex-M the .isr_vector table drives reset, so that warning is expected.)
$inc = Join-Path $out "build\include"
$quoted = ($csrc | ForEach-Object { '"' + $_ + '"' }) -join ' '
$cmdline = '"' + $zig + '" cc -target ' + $Target + ' "-mcpu=' + $Cpu + '"' +
           ' -ffreestanding -nostartfiles -fno-sanitize=undefined -w' +
           ' -T "' + $ld + '" -I "' + $inc + '"' +
           ' -o "' + $elf + '" ' + $quoted + ' > "' + $log + '" 2>&1'
& cmd /c $cmdline

if ($LASTEXITCODE -ne 0) {
    Write-Host "link FAILED -- errors:" -ForegroundColor Red
    Select-String -Path $log -Pattern "error:" | Select-Object -First 20 -ExpandProperty Line
    throw "zig cc failed (exit $LASTEXITCODE); full log at $log"
}

# --- 3. Confirm we produced a 32-bit ARM executable, not a host binary ----
$b = [System.IO.File]::ReadAllBytes($elf)
$machine = $b[18] + $b[19] * 256
if ($machine -ne 40) { throw "expected ARM (e_machine 40), got $machine" }

$entry = "0x" + ("{0:x8}" -f ($b[24] + $b[25] * 256 + $b[26] * 65536 + $b[27] * 16777216))
Write-Host ""
Write-Host "built $elf" -ForegroundColor Green
Write-Host "  ARM 32-bit executable, entry $entry, $((Get-Item $elf).Length) bytes"
Write-Host ""
Write-Host "run it with:"
Write-Host "  qemu-system-arm -M mps2-an385 -nographic -kernel $elf"
