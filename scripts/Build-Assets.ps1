# Disegna le immagini col robot Android, senza file esterni:
#   apk.ico    icona dei file .apk e del launcher (quadrato blu arrotondato, robot verde)
#   droid.png  quadrato 512px, mostrato nel popup quando l'APK non ha un'icona sua
#
# Draws the images with the Android robot, without external files:
# apk.ico    icon for .apk files and the launcher (rounded blue square, green robot)
# droid.png  512px square, shown in the popup when the APK has no icon of its own
param(
    [Parameter(Mandatory)][string]$OutDir
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Force $OutDir | Out-Null

$navy  = [Drawing.ColorTranslator]::FromHtml('#073042')
$green = [Drawing.ColorTranslator]::FromHtml('#3DDC84')

# testa del robot, con le coordinate di un'immagine di riferimento 1000x600
# robot head, using the coordinates of a 1000x600 reference image
function New-RobotBitmap([int]$size, [bool]$rounded = $true) {
    $bmp = New-Object Drawing.Bitmap $size, $size, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([Drawing.Color]::Transparent)

    if ($rounded) {
        $r = [Math]::Max(2, [int]($size * 0.22))
        $m = [Math]::Max(0, [int]($size * 0.02))
        $bg = New-Object Drawing.Drawing2D.GraphicsPath
        $bg.AddArc($m, $m, $r, $r, 180, 90)
        $bg.AddArc($size - $m - $r - 1, $m, $r, $r, 270, 90)
        $bg.AddArc($size - $m - $r - 1, $size - $m - $r - 1, $r, $r, 0, 90)
        $bg.AddArc($m, $size - $m - $r - 1, $r, $r, 90, 90)
        $bg.CloseFigure()
        $g.FillPath((New-Object Drawing.SolidBrush $navy), $bg)
    } else {
        $g.Clear($navy)
    }

    # il robot sta in 330..670 x 150..345: lo centro e lo scalo al 66% dell'icona
    # the robot fits in 330..670 x 150..345: it is centred and scaled to 66% of the icon
    $k = 0.66 * $size / 340.0
    $g.TranslateTransform($size / 2.0, $size / 2.0)
    $g.ScaleTransform($k, $k)
    $g.TranslateTransform(-500, -247.5)

    $g.FillPie((New-Object Drawing.SolidBrush $green), 330, 187, 340, 310, 180, 180)     # testa / head
    $navyBrush = New-Object Drawing.SolidBrush $navy
    $g.FillEllipse($navyBrush, 423 - 14, 278 - 14, 28, 28)                                # occhi / eyes
    $g.FillEllipse($navyBrush, 578 - 14, 278 - 14, 28, 28)
    $pen = New-Object Drawing.Pen $green, 13
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
    $g.DrawLine($pen, 392, 157, 424, 202)                                                 # antenne / antennas
    $g.DrawLine($pen, 606, 157, 574, 202)
    $g.Dispose()
    $bmp
}

$sq = New-RobotBitmap 512 $false
$sq.Save((Join-Path $OutDir 'droid.png'), [Drawing.Imaging.ImageFormat]::Png)
$sq.Dispose()

$sizes = 16, 24, 32, 48, 64, 128, 256
$pngs = @()
foreach ($s in $sizes) {
    $b = New-RobotBitmap $s
    $ms = New-Object IO.MemoryStream
    $b.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
    $pngs += , $ms.ToArray()
    $b.Dispose()
}
$fs = [IO.File]::Create((Join-Path $OutDir 'apk.ico'))
$bw = New-Object IO.BinaryWriter $fs
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)            # ICONDIR
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $wh = $sizes[$i]; if ($wh -ge 256) { $wh = 0 }
    $bw.Write([byte]$wh); $bw.Write([byte]$wh); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32)
    $bw.Write([uint32]$pngs[$i].Length); $bw.Write([uint32]$offset)
    $offset += $pngs[$i].Length
}
foreach ($p in $pngs) { $bw.Write($p) }
$bw.Close(); $fs.Close()
