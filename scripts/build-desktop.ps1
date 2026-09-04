# Build a Tauraro UI program into a real Windows desktop .exe with a live
# SDL2 window, on Windows, using only the compiler SDK (no manual bindgen
# step -- toolkit/render/desktop/sdl_bindings.tr is already generated and
# committed; see the header comment there for how to regenerate it).
#
#   .\scripts\build-desktop.ps1
#   .\build-desktop\app.exe
#
# Unlike build-bare.ps1/build-uefi.ps1, this is an ordinary HOSTED build --
# no --freestanding, no linker script, no zig cross-target. The only thing
# desktop needs beyond a normal `tauraroc app.tr -o app.exe` is linking
# against SDL2's mingw64 import library and getting SDL2.dll next to the
# built exe (Windows resolves DLLs from the exe's own directory first, so no
# PATH changes are needed for the built app to run standalone).

param(
    [string]$Source = "examples\desktop_demo\main.tr",
    [string]$OutDir = "build-desktop",
    [string]$MingwRoot = "C:\msys64\mingw64"
)

$ErrorActionPreference = "Stop"

$sdk = Join-Path $env:USERPROFILE ".taupkg\bin\tauraroc-windows-x64"
$tauraroc = Join-Path $sdk "tauraroc.exe"
if (-not (Test-Path $tauraroc)) { throw "missing tool: $tauraroc" }
if (-not (Test-Path $Source)) { throw "no such source file: $Source" }

$sdl2ImportLib = Join-Path $MingwRoot "lib\libSDL2.dll.a"
$sdl2Dll = Join-Path $MingwRoot "bin\SDL2.dll"
foreach ($f in @($sdl2ImportLib, $sdl2Dll)) {
    if (-not (Test-Path $f)) {
        throw "missing SDL2 dev files: $f -- install with: pacman -S mingw-w64-x86_64-SDL2"
    }
}

$root = (Get-Location).Path
$out = Join-Path $root $OutDir
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Force $out | Out-Null

$srcFull = (Resolve-Path $Source).Path
$exe = Join-Path $out "app.exe"

Push-Location $out
try {
    # `--link <path>` links the SDL2 import lib by exact path -- avoids
    # relying on a `-L` search-path flag (tauraroc has none; only `--link
    # <path>` and `-l<name>` against the driver's own default paths exist).
    & $tauraroc $srcFull --link $sdl2ImportLib -o $exe
    if ($LASTEXITCODE -ne 0) { throw "tauraroc failed (exit $LASTEXITCODE)" }
} finally {
    Pop-Location
}

# SDL2.dll is a redistributable runtime dependency, not part of the source
# tree (.gitignore excludes it) -- copy it next to the exe on every build.
Copy-Item $sdl2Dll (Join-Path $out "SDL2.dll") -Force

Write-Host ""
Write-Host "built $exe" -ForegroundColor Green
Write-Host "  $((Get-Item $exe).Length) bytes, SDL2.dll copied alongside"
Write-Host ""
Write-Host "run it with:"
Write-Host "  .\$OutDir\app.exe"
