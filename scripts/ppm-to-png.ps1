# Convert a PPM into a PNG that Windows Photos/Explorer can actually display.
#
# Windows has no built-in viewer for .ppm: Explorer shows no thumbnail and
# double-clicking either does nothing or opens the raw numbers in Notepad.
# This exists so run-bare.ps1, run-uefi.ps1, and the hosted demo's output are
# all actually visible without installing IrfanView/GIMP.
#
# Handles both PPM variants this project produces:
#   P3 (ASCII)  -- BufferCanvas.save_ppm / FrameBuffer.emit_ppm, and what the
#                  bare-metal demo streams out over UART via run-bare.ps1.
#   P6 (binary) -- what QEMU's own `screendump` monitor command writes,
#                  which run-uefi.ps1 uses to capture the UEFI demo.
#
#   .\scripts\ppm-to-png.ps1 -Ppm build-bare\out.ppm
#   .\scripts\ppm-to-png.ps1 -Ppm examples\hosted_demo\out_1.ppm -Open
#   .\scripts\ppm-to-png.ps1 -Ppm build-uefi\screenshot.ppm -Scale 1 -Open
#
# -Scale enlarges the image with nearest-neighbour (no blur) before saving.
# Defaults to 8 for the tiny emulated framebuffers (bare demo is 64x48 --
# a postage stamp at native size); pass -Scale 1 for a QEMU screendump,
# which is already full display resolution.

param(
    [Parameter(Mandatory = $true)]
    [string]$Ppm,

    [string]$Png = "",

    [int]$Scale = 8,

    [switch]$Open
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $Ppm)) { throw "no such file: $Ppm" }
if ($Png -eq "") { $Png = [System.IO.Path]::ChangeExtension($Ppm, "png") }

$allBytes = [System.IO.File]::ReadAllBytes($Ppm)
if ($allBytes.Length -lt 2) { throw "$Ppm is empty or truncated" }

$magic = [System.Text.Encoding]::ASCII.GetString($allBytes, 0, 2)
Add-Type -AssemblyName System.Drawing

if ($magic -eq "P3") {
    # ASCII PPM. Trailing diagnostic lines (run-bare.ps1's "# ..." lines,
    # "parse: ok") are already stripped by run-bare.ps1 before it writes the
    # .ppm, but tolerate them here too in case this is pointed at a raw,
    # unfiltered capture.
    $lines = Get-Content $Ppm | Where-Object { $_ -notmatch '^#' -and $_ -notmatch '^parse:' }

    if ($lines.Count -lt 3 -or $lines[0].Trim() -ne "P3") {
        throw "$Ppm has P3 magic but a malformed header"
    }

    $dims = ($lines[1].Trim() -split '\s+')
    $w = [int]$dims[0]
    $h = [int]$dims[1]
    Write-Host "reading $Ppm (P3 ASCII, $w x $h)"

    # Values may be wrapped across lines, so tokenize everything after the
    # three header lines as one stream rather than assuming one row per line.
    $rest = ($lines[3..($lines.Count - 1)] -join ' ')
    $tokens = $rest -split '\s+' | Where-Object { $_ -ne '' }

    $expected = $w * $h * 3
    if ($tokens.Count -lt $expected) {
        throw "$Ppm is truncated: expected $expected pixel values, found $($tokens.Count). If this came from run-bare.ps1, re-run with a larger -MaxSeconds."
    }

    $bmp = New-Object -TypeName System.Drawing.Bitmap -ArgumentList $w, $h
    $i = 0
    for ($y = 0; $y -lt $h; $y++) {
        for ($x = 0; $x -lt $w; $x++) {
            $r = [int]$tokens[$i]; $g = [int]$tokens[$i + 1]; $b = [int]$tokens[$i + 2]
            $i += 3
            $bmp.SetPixel($x, $y, [System.Drawing.Color]::FromArgb($r, $g, $b))
        }
    }
} elseif ($magic -eq "P6") {
    # Binary PPM, as QEMU's `screendump` writes: "P6\n<w> <h>\n<maxval>\n"
    # then raw R,G,B bytes -- no ASCII pixel data, so this cannot share the
    # P3 tokenizer above.
    $text = [System.Text.Encoding]::ASCII.GetString($allBytes, 0, [Math]::Min(64, $allBytes.Length))
    $nl1 = $text.IndexOf("`n")
    $nl2 = $text.IndexOf("`n", $nl1 + 1)
    $nl3 = $text.IndexOf("`n", $nl2 + 1)
    if ($nl1 -lt 0 -or $nl2 -lt 0 -or $nl3 -lt 0) { throw "$Ppm has P6 magic but a malformed header" }

    $dims = $text.Substring($nl1 + 1, $nl2 - $nl1 - 1).Trim() -split '\s+'
    $w = [int]$dims[0]
    $h = [int]$dims[1]
    $dataStart = $nl3 + 1
    Write-Host "reading $Ppm (P6 binary, $w x $h)"

    $expectedBytes = $dataStart + ($w * $h * 3)
    if ($allBytes.Length -lt $expectedBytes) {
        throw "$Ppm is truncated: expected $expectedBytes bytes, found $($allBytes.Length)"
    }

    $bmp = New-Object -TypeName System.Drawing.Bitmap -ArgumentList $w, $h
    $i = $dataStart
    for ($y = 0; $y -lt $h; $y++) {
        for ($x = 0; $x -lt $w; $x++) {
            $r = $allBytes[$i]; $g = $allBytes[$i + 1]; $b = $allBytes[$i + 2]
            $i += 3
            $bmp.SetPixel($x, $y, [System.Drawing.Color]::FromArgb($r, $g, $b))
        }
    }
} else {
    throw "$Ppm is neither P3 nor P6 -- first two bytes were '$magic'"
}

if ($Scale -gt 1) {
    $scaledW = $w * $Scale
    $scaledH = $h * $Scale
    $scaled = New-Object -TypeName System.Drawing.Bitmap -ArgumentList $scaledW, $scaledH
    $gfx = [System.Drawing.Graphics]::FromImage($scaled)
    # Nearest-neighbour, not bilinear: this is a pixel-art-scale rasteriser
    # output: blurring it would hide exactly the edges worth checking.
    $gfx.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
    $gfx.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $gfx.DrawImage($bmp, 0, 0, $scaledW, $scaledH)
    $gfx.Dispose()
    $bmp.Dispose()
    $bmp = $scaled
}

$bmp.Save($Png, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

Write-Host "wrote $Png" -ForegroundColor Green

if ($Open) {
    Start-Process $Png
}
