# Build a Nebula program into a browser-loadable .wasm, using tauraroc's
# turnkey `--target wasm` link (added alongside `--wasm-memory`). There is no
# separate zig invocation in this script anymore -- tauraroc compiles each
# generated module to a CACHED wasm object (`zig cc -c`, reused across builds
# whose generated C didn't change) and links them directly with `wasm-ld`.
#
# This replaces the old build-exe-based version, which reran zig's own build
# driver (`zig build-exe -O ReleaseSmall`) over every C file on every build --
# non-incremental and memory-hungry (8.8GB peak RSS linking this toolkit's
# ~30 files, which read as a build that "just never finishes" on a box with
# less headroom). See tauraro/src/main.tr's compile_wasm_incremental for the
# full story. A second, independent fix (the actual dominant cost for THIS
# toolkit) was a codegen bug: large List[u8] literals (the embedded font
# bitmaps) generated one C function call PER ELEMENT -- 22,800 of them for
# the largest font table -- which is what really made a cold build take an
# hour+; that's fixed in tauraroc's list-literal codegen, not in this script.
#
#   .\scripts\build-web.ps1
#   .\scripts\build-web.ps1 -Source examples\web_demo\render_web.tr -OutDir build-web
#
# Then serve build-web/ over HTTP (a file:// page cannot fetch the .wasm):
#   python3 -m http.server 8000 --directory build-web
#
# Two flags stay load-bearing here (now handled INSIDE tauraroc's own wasm
# link path, not hand-passed to zig):
#
#   --freestanding   `--target wasm` ALONE FAILS. tauraro_rt.h includes
#                    <stdio.h>, and bare wasm has no libc. --freestanding
#                    defines TAURARO_KERNEL, the same switch the UEFI and
#                    Cortex-M tiers rely on. The cost is that the program
#                    must supply @allocator/@free/@realloc/@calloc itself.
#   --wasm-memory    Initial linear memory in MB (tauraroc default: 64).
#
# `pub export def` visibility and JS-host `extern "C"` imports
# (toolkit.render.web.canvas2d_renderer's Canvas2D calls) are always-on
# inside tauraroc's wasm link path now -- no more -rdynamic/--import-symbols
# to remember to pass by hand.

param(
    [string]$Source = "examples\web_demo\render_web.tr",
    [string]$OutDir = "build-web",
    [int]$MemoryMB  = 64,
    # Passed straight through to tauraroc as -O<Opt>. Each generated .c is
    # compiled to its own cached object (build/ is NOT wiped between runs
    # anymore -- see the note below), so switching this only recompiles what
    # actually depends on it, not the whole toolkit. Use 0 to iterate, s to
    # ship/measure size.
    [ValidateSet("0", "1", "2", "3", "s")]
    [string]$Opt = "s"
)

$ErrorActionPreference = "Stop"

$sdk = Join-Path $env:USERPROFILE ".taupkg\bin\tauraroc-windows-x64"
$tauraroc = Join-Path $sdk "tauraroc.exe"
if (-not (Test-Path $tauraroc)) { throw "missing tool: $tauraroc" }
if (-not (Test-Path $Source)) { throw "no such source file: $Source" }

$root = (Get-Location).Path
$out = Join-Path $root $OutDir
New-Item -ItemType Directory -Force $out | Out-Null

$srcFull = (Resolve-Path $Source).Path
$wasm = Join-Path $out "nebula.wasm"

# Build from the repo root so toolkit.* module paths resolve. build/ is
# intentionally NOT wiped here (the old script wiped it every run, which is
# exactly what defeated its own incremental caching, on top of driving zig
# build-exe directly): tauraroc's own per-module invalidation hashes each
# generated .c's CONTENT (not mtime, not a directory glob), so switching
# -Opt/-MemoryMB or even $Source is handled correctly -- only the modules
# whose generated C actually changed get recompiled, everything else reuses
# its cached object from build/*.o.
& $tauraroc $srcFull --target wasm --freestanding "-O$Opt" --wasm-memory $MemoryMB -o $wasm
if ($LASTEXITCODE -ne 0) { throw "tauraroc failed (exit $LASTEXITCODE)" }

# Copy every host-page asset next to main.tr, not just index.html -- a web
# app can have a manifest.json/icons/CSS/etc. of its own (examples/web_ide
# does, for real PWA-installable-standalone-window support). Everything
# except the .tr source itself and this script's own output files.
$srcDir = Split-Path $srcFull
Get-ChildItem $srcDir -File | Where-Object { $_.Extension -ne ".tr" } | ForEach-Object {
    Copy-Item $_.FullName $out -Force
}

Write-Host ""
Write-Host "built $wasm" -ForegroundColor Green
Write-Host "  $((Get-Item $wasm).Length) bytes, $MemoryMB MB linear memory"
Write-Host ""
Write-Host "serve it with:"
Write-Host "  python3 -m http.server 8000 --directory $OutDir"
Write-Host "  then open http://localhost:8000/"
