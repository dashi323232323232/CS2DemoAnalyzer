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
$form.Location = New-Object System.Drawing.Point(-4000, -4000)
$form.Size = New-Object System.Drawing.Size(1560, 820)
$form.Show()
for ($i = 0; $i -lt 30; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }

$rep = Load-Report -JsonPath (Join-Path $here 'out\report.json')
$script:App.Report = $rep
$app.Checks['first'].Checked = $true
$app.Checks['second'].Checked = $true

foreach ($w in @(620, 560, 540, 520, 500)) {
    $app.DetailPanel.Width = $w
    Render-View -Report $rep
    Render-Timeline
    for ($i = 0; $i -lt 25; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40 }
    $g = $app.Grids['main']['A']
    $sum = 0
    foreach ($c in $g.Columns) { $sum += [int]$c.Width }
    $need = $sum + 3 + $(if ($g.RowHeadersVisible) { $g.RowHeadersWidth } else { 0 }) + $(if ($g.VerticalScrollBar.Visible) { [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth } else { 0 })
    $cl = [int]$g.ClientSize.Width
    "详情栏 {0,3}px | 页签 {1,3}px | 表格客户区 {2,4}px 需要 {3,4}px  -> {4}" -f `
        $w, $app.Tabs.Width, $cl, $need, $(if ($need -le $cl) { '不用横向滚动' } else { "差 $($need - $cl)px，要横向滚动" })
}
$form.Close(); $form.Dispose()
