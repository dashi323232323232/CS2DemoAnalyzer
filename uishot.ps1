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
$form.Location = New-Object System.Drawing.Point(0, 0)
$form.Size = New-Object System.Drawing.Size(1560, 820)
$form.TopMost = $true
$form.Show()
$form.Activate()
for ($i = 0; $i -lt 40; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }

$rep = Load-Report -JsonPath (Join-Path $here 'out\report.json')
$script:App.Report = $rep
$app.Checks['first'].Checked = $true
$app.Checks['second'].Checked = $true
Render-View -Report $rep
Render-Timeline
for ($i = 0; $i -lt 60; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }

function Shot($name) {
    for ($i = 0; $i -lt 25; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 30 }
    $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($form.Location.X, $form.Location.Y, 0, 0, $bmp.Size)
    $g.Dispose()
    $p = Join-Path $here ('out\' + $name + '.png')
    $bmp.Save($p, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    "shot -> $p"
}

function Find-Ctl($root, $type) {
    foreach ($c in $root.Controls) {
        if ($c -is $type) { return $c }
        $r = Find-Ctl $c $type
        if ($r) { return $r }
    }
    return $null
}

Shot 'ui_1_main'

$tabs = Find-Ctl $form ([System.Windows.Forms.TabControl])
if ($tabs) { $tabs.SelectedIndex = 1 }
Shot 'ui_2_util'

if ($tabs) { $tabs.SelectedIndex = 0 }
Render-Detail -Report $rep -Round 5
Shot 'ui_3_detail'

$form.Close(); $form.Dispose()
"done"
