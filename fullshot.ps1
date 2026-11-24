$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$here = $PSScriptRoot
$src = Get-Content (Join-Path $here 'DemoAnalyzer.ps1') -Raw -Encoding UTF8
$src = $src.Substring(0, $src.IndexOf('# ---------------- 入口 ----------------'))
$src = $src -replace '(?s)^\s*param\s*\(.*?\)\s*\r?\n', ''
$src = $src -replace '(?m)^\$Root\s*=.*$', ('$Root = ' + "'" + $here + "'")
Invoke-Expression $src

$form = Show-Gui
$app = $script:App
$form.StartPosition = 'Manual'
$form.Location = New-Object System.Drawing.Point(20, 20)
$form.Size = New-Object System.Drawing.Size(1560, 820)
$form.Show()
for ($i = 0; $i -lt 30; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 60 }

$rep = Load-Report -JsonPath (Join-Path $here 'out\report.json')
$script:App.Report = $rep
$app.Checks['first'].Checked = $true
$app.Checks['second'].Checked = $true
Render-View -Report $rep
Render-Timeline
for ($i = 0; $i -lt 50; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 60 }

# 整窗截图
$bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
$form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $bmp.Width, $bmp.Height)))
$out = Join-Path $here 'out\shot_window.png'
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
"整窗截图: $out ($($bmp.Width)x$($bmp.Height))"
$bmp.Dispose()

# 顺便报告表格实际行高与可见行数
foreach ($pk in @('main')) {
    foreach ($rid in @('A', 'B')) {
        $g = $app.Grids[$pk][$rid]
        $need = [int][Math]::Ceiling([System.Windows.Forms.TextRenderer]::MeasureText('汉字', $g.Font).Height)
        "  [{0}/{1}] 行数={2} 行高={3} 表头高={4} 字号={5}pt 行盒={6}px 可视高={7} 可容纳行数={8}" -f `
            $pk, $rid, $g.Rows.Count, $g.RowTemplate.Height, $g.ColumnHeadersHeight,
            $g.Font.Size, $need, $g.ClientSize.Height,
            [Math]::Floor(($g.ClientSize.Height - $g.ColumnHeadersHeight) / $g.RowTemplate.Height)
    }
}
$form.Close(); $form.Dispose()
"done"
