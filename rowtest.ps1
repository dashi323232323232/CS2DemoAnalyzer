$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$here = $PSScriptRoot
$src = Get-Content (Join-Path $here 'DemoAnalyzer.ps1') -Raw -Encoding UTF8
$src = $src.Substring(0, $src.IndexOf('# ---------------- 入口 ----------------'))
$src = $src -replace '(?s)^\s*param\s*\(.*?\)\s*\r?\n', ''
$src = $src -replace '(?m)^\$Root\s*=.*$', ('$Root = ' + "'" + $here + "'")
Invoke-Expression $src

$font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
"=== 字体度量 (Microsoft YaHei UI 9.5pt) ==="
"  Font.Height                  = $($font.Height)"
"  MeasureText('离子安').Height = $([System.Windows.Forms.TextRenderer]::MeasureText('离子安', $font).Height)"
""
"=== 实际渲染的表格：行高 vs 文字墨迹 ==="
$form = Show-Gui
$app = $script:App
$form.StartPosition = 'Manual'
$form.Location = New-Object System.Drawing.Point(-4000, -4000)
$form.Show()
for ($i = 0; $i -lt 30; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 60 }

$rep = Load-Report -JsonPath (Join-Path $here 'out\report.json')
$script:App.Report = $rep
$script:App.Checks['first'].Checked = $true
Render-View -Report $rep
for ($i = 0; $i -lt 40; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 60 }

$g = $app.Grids['main']['A']
"  行数=$($g.Rows.Count)  RowTemplate.Height=$($g.RowTemplate.Height)"
"  ColumnHeadersHeight=$($g.ColumnHeadersHeight)  ClientSize=$($g.ClientSize.Width)x$($g.ClientSize.Height)"
if ($g.Rows.Count -gt 0) { "  第一行 Height=$($g.Rows[0].Height)" }
if ($g.Rows.Count -gt 1) { "  第二行 Height=$($g.Rows[1].Height)" }

$bmp = New-Object System.Drawing.Bitmap($g.ClientSize.Width, $g.ClientSize.Height)
$g.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $bmp.Width, $bmp.Height)))
$out = Join-Path $here 'out\grid_zoom.png'
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
"  表格位图: $out ($($bmp.Width)x$($bmp.Height))"

function Ink($y) {
    $n = 0
    for ($x = 0; $x -lt $bmp.Width; $x++) {
        $c = $bmp.GetPixel($x, $y)
        if ((0.299 * $c.R + 0.587 * $c.G + 0.114 * $c.B) -lt 170) { $n++ }
    }
    return $n
}
""
$top = $g.ColumnHeadersHeight
$rh = $g.RowTemplate.Height
"  表头占 y0..$($top-1)；第 1 行占 y$top..$($top+$rh-1)；第 2 行占 y$($top+$rh)..$($top+2*$rh-1)"
"  逐 y 墨迹:"
for ($y = 0; $y -lt [Math]::Min($bmp.Height, $top + 2 * $rh + 2); $y++) {
    $n = Ink $y
    $bar = '#' * [Math]::Min(50, [int]($n / 6))
    "    y={0,3}  {1,4}  {2}" -f $y, $n, $bar
}
$bmp.Dispose()
$form.Close(); $form.Dispose()
"done"
