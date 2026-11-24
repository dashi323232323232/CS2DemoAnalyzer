$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$here = $PSScriptRoot

function Sym($c) {
    $r = [int]$c.R; $g = [int]$c.G; $b = [int]$c.B
    if ($r -eq 241 -and $g -eq 243 -and $b -eq 248) { return 'S' }
    if ($r -eq 228 -and $g -eq 232 -and $b -eq 241) { return 'u' }
    if ($r -eq 222 -and $g -eq 226 -and $b -eq 235) { return ':' }
    if ($r -eq 229 -and $g -eq 232 -and $b -eq 239) { return 'o' }
    if ($r -ge 252 -and $g -ge 252 -and $b -ge 252) { return ' ' }
    if ($b -gt 150 -and $b -gt ($r + 50)) { return 'B' }
    if ($r -lt 150 -and $g -lt 150 -and $b -lt 160) { return '#' }
    if ([Math]::Abs($r - 240) -le 3 -and [Math]::Abs($g - 240) -le 3 -and [Math]::Abs($b - 240) -le 3) { return '-' }
    return '?'
}

function Dump($bmp, $x0, $y0, $w, $h, $title) {
    "---- $title  origin=($x0,$y0) ${w}x${h} ----"
    "      " + (($x0..($x0 + $w - 1)) | ForEach-Object { if ($_ % 10 -eq 0) { [string]([int](($_ / 10)) % 10) } else { ' ' } }) -join ''
    for ($y = 0; $y -lt $h; $y++) {
        $sb = New-Object System.Text.StringBuilder
        for ($x = 0; $x -lt $w; $x++) {
            $px = $bmp.GetPixel($x0 + $x, $y0 + $y)
            [void]$sb.Append((Sym $px))
        }
        "{0,4} |{1}|" -f ($y0 + $y), $sb.ToString()
    }
}

$bmp = [System.Drawing.Bitmap]::FromFile((Join-Path $here 'out\ui_1_main.png'))

Dump $bmp 6 304 200 46 'tab strip (1px): S=page-bg u=unselected-tab o=disabled-btn : =edge'
""
Dump $bmp 6 36 60 20 'top card corner (1px): S=page-bg edge=: white=inner'
""

# 时间轴第一列的方块左上角：先找第一个 8x8 方块
$tlTop = -1
for ($y = 200; $y -lt 320; $y++) { $c = $bmp.GetPixel(700, $y); if ($c.R -ge 252 -and $c.G -ge 252 -and $c.B -ge 252) { $tlTop = $y; break } }
"timeline white top at x=700: y=$tlTop"
if ($tlTop -ge 0) { Dump $bmp 6 ($tlTop - 2) 70 34 'timeline first card top (1px)' }

$bmp.Dispose()
"done"
