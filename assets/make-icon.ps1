# Draws assets/icon.ico (a VR headset on a rounded teal square) at 16-256 px.
# Run again after changing the drawing; the .ico is committed so users don't need to.
Add-Type -AssemblyName System.Drawing

function New-RoundedRect([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = 2 * $r
    $p.AddArc($x, $y, $d, $d, 180, 90); $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90); $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function New-IconBitmap([int]$size) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $s = $size / 256.0

    $bg = New-RoundedRect (8 * $s) (8 * $s) (240 * $s) (240 * $s) (52 * $s)
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.PointF(0, 0)), (New-Object System.Drawing.PointF($size, $size)),
        [System.Drawing.Color]::FromArgb(255, 20, 184, 166), [System.Drawing.Color]::FromArgb(255, 37, 99, 235))
    $g.FillPath($brush, $bg)

    # Headset: strap, visor with two lens cut-outs and a nose notch.
    $white = [System.Drawing.Brushes]::White
    $g.FillRectangle($white, 22 * $s, 112 * $s, 212 * $s, 22 * $s)
    $visor = New-RoundedRect (40 * $s) (78 * $s) (176 * $s) (100 * $s) (34 * $s)
    $g.FillPath($white, $visor)
    $lens = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 30, 120, 200))
    $g.FillEllipse($lens, 66 * $s, 104 * $s, 46 * $s, 46 * $s)
    $g.FillEllipse($lens, 144 * $s, 104 * $s, 46 * $s, 46 * $s)
    # Nose notch cut into the visor's bottom edge, painted with the background gradient.
    $g.FillEllipse($brush, 104 * $s, 152 * $s, 48 * $s, 52 * $s)

    $g.Dispose()
    return $bmp
}

# ICO file with one PNG-compressed image per size.
$sizes = 16, 24, 32, 48, 64, 128, 256
$pngs = foreach ($size in $sizes) {
    $ms = New-Object IO.MemoryStream
    (New-IconBitmap $size).Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    , $ms.ToArray()
}
$out = New-Object IO.MemoryStream
$w = New-Object IO.BinaryWriter $out
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $dim = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
    $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([uint16]1); $w.Write([uint16]32)
    $w.Write([uint32]$pngs[$i].Length); $w.Write([uint32]$offset)
    $offset += $pngs[$i].Length
}
foreach ($png in $pngs) { $w.Write($png) }
[IO.File]::WriteAllBytes((Join-Path $PSScriptRoot 'icon.ico'), $out.ToArray())
(New-IconBitmap 256).Save((Join-Path $PSScriptRoot 'icon.png'), [System.Drawing.Imaging.ImageFormat]::Png)
