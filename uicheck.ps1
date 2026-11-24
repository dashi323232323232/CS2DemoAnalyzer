$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$here = $PSScriptRoot
$src = Get-Content (Join-Path $here 'DemoAnalyzer.ps1') -Raw -Encoding UTF8
$src = $src.Substring(0, $src.IndexOf('# ---------------- 入口 ----------------'))
$src = $src -replace '(?s)^\s*param\s*\(.*?\)\s*\r?\n', ''
$src = $src -replace '(?m)^\$Root\s*=.*$', ('$Root = ' + "'" + $here + "'")
Invoke-Expression $src

$fail = 0
function Chk($name, $cond, $detail) {
    if ($cond) { "  OK   $name  $detail" }
    else { "  FAIL $name  $detail"; $script:fail++ }
}
function Rgb($c) { if (-not $c) { return 'null' } return "$($c.R),$($c.G),$($c.B)" }
function RegSize($c) {
    if (-not $c -or -not $c.Region) { return 'NO-REGION' }
    $w = [int]$c.ClientSize.Width; $h = [int]$c.ClientSize.Height
    $tl = $c.Region.IsVisible(0, 0)
    $tr = $c.Region.IsVisible(($w - 1), 0)
    $bl = $c.Region.IsVisible(0, ($h - 1))
    $br = $c.Region.IsVisible(($w - 1), ($h - 1))
    $mid = $c.Region.IsVisible([int]($w / 2), [int]($h / 2))
    return ("TL={0} TR={1} BL={2} BR={3} MID={4}" -f $tl, $tr, $bl, $br, $mid)
}
function Find-Ctl($root, $type) {
    foreach ($c in $root.Controls) {
        if ($c -is $type) { return $c }
        $r = Find-Ctl $c $type
        if ($r) { return $r }
    }
    return $null
}
function Find-ByBack($root, $rgb) {
    $res = @()
    foreach ($c in $root.Controls) {
        if ($c.BackColor.R -eq $rgb[0] -and $c.BackColor.G -eq $rgb[1] -and $c.BackColor.B -eq $rgb[2]) { $res += $c }
        $res += Find-ByBack $c $rgb
    }
    return $res
}

$form = Show-Gui
$app = $script:App
$form.StartPosition = 'Manual'
$form.Location = New-Object System.Drawing.Point(-4000, -4000)
$form.Size = New-Object System.Drawing.Size(1560, 820)
$form.Show()
for ($i = 0; $i -lt 30; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40 }

$rep = Load-Report -JsonPath (Join-Path $here 'out\report.json')
$script:App.Report = $rep
$app.Checks['first'].Checked = $true
$app.Checks['second'].Checked = $true
Render-View -Report $rep
Render-Timeline
for ($i = 0; $i -lt 40; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40 }

"==== 任务#3 UI 圆角化 属性核对 ===="
$bg = @(241, 243, 248)
$edge = @(222, 226, 235)

Chk 'form.BackColor' ($form.BackColor.R -eq $bg[0] -and $form.BackColor.G -eq $bg[1] -and $form.BackColor.B -eq $bg[2]) (Rgb $form.BackColor)

# 主界面改成了「左侧导航 + 右侧功能区」的壳，$form.Controls[0] 现在是那个壳，
# 原来的根布局（4 行的 TableLayoutPanel）挂在 demo 页里面。
$root = $script:App.Nav.Pages['demo'].Controls[0]
$top = $root.GetControlFromPosition(0, 0)
Chk 'top card BackColor White' ($top -and $top.BackColor.R -eq 255 -and $top.BackColor.G -eq 255 -and $top.BackColor.B -eq 255) (Rgb $top.BackColor)
Chk 'top card Region' ($top.Region -ne $null) ("client {0}x{1} region {2}" -f $top.ClientSize.Width, $top.ClientSize.Height, (RegSize $top))
Chk 'top card Tag.r=12' ($top.Tag -and $top.Tag.r -eq 12) ("r=" + $top.Tag.r)

$btns = @($top.Controls | Where-Object { $_ -is [System.Windows.Forms.Button] })
Chk '3 buttons' ($btns.Count -eq 3) ("count=" + $btns.Count)
foreach ($b in $btns) {
    Chk ("btn '" + $b.Text + "'") ($b.FlatStyle -eq 'Flat' -and $b.Region -ne $null -and $b.Tag.r -eq 9) ("flat=" + $b.FlatStyle + " region=" + (RegSize $b) + " r=" + $b.Tag.r + " back=" + (Rgb $b.BackColor) + " enabled=" + $b.Enabled)
}
$bRun = @($btns | Where-Object { $_.Text -eq '开始分析' })[0]
Chk 'btnRun disabled color' (-not $bRun.Enabled -and $bRun.BackColor.R -eq 229 -and $bRun.BackColor.G -eq 232 -and $bRun.BackColor.B -eq 239) (Rgb $bRun.BackColor)

$pp = $root.GetControlFromPosition(0, 1)
Chk 'pp card BackColor White' ($pp.BackColor.R -eq 255 -and $pp.BackColor.G -eq 255 -and $pp.BackColor.B -eq 255) (Rgb $pp.BackColor)
Chk 'pp card Region' ($pp.Region -ne $null) ("client {0}x{1} region {2}" -f $pp.ClientSize.Width, $pp.ClientSize.Height, (RegSize $pp))
Chk 'pp card Tag.r=12' ($pp.Tag.r -eq 12) ("r=" + $pp.Tag.r)

$tl = $app.TimelineHost
Chk 'tlHost card BackColor White' ($tl.BackColor.R -eq 255 -and $tl.BackColor.G -eq 255 -and $tl.BackColor.B -eq 255) (Rgb $tl.BackColor)
Chk 'tlHost card Region' ($tl.Region -ne $null) ("client {0}x{1} region {2}" -f $tl.ClientSize.Width, $tl.ClientSize.Height, (RegSize $tl))

$tabs = Find-Ctl $form ([System.Windows.Forms.TabControl])
Chk 'tabs DrawMode OwnerDrawFixed' ($tabs.DrawMode -eq 'OwnerDrawFixed') ("drawmode=" + $tabs.DrawMode)
Chk 'tabs ItemSize 132x34' ($tabs.ItemSize.Width -eq 132 -and $tabs.ItemSize.Height -eq 34) ("itemsize=" + $tabs.ItemSize)
foreach ($tp in $tabs.TabPages) {
    Chk ('tabpage ' + $tp.Text + ' gray') ($tp.BackColor.R -eq $bg[0] -and $tp.BackColor.G -eq $bg[1] -and $tp.BackColor.B -eq $bg[2]) (Rgb $tp.BackColor)
}

$sp = $app.Splits[0]
foreach ($pn in @($sp.Panel1, $sp.Panel2)) {
    Chk 'split panel White' ($pn.BackColor.R -eq 255 -and $pn.BackColor.G -eq 255 -and $pn.BackColor.B -eq 255) (Rgb $pn.BackColor)
    Chk 'split panel Region' ($pn.Region -ne $null) ("client {0}x{1} region {2}" -f $pn.ClientSize.Width, $pn.ClientSize.Height, (RegSize $pn))
    Chk 'split panel Tag.r=12' ($pn.Tag -and $pn.Tag.r -eq 12) ("r=" + $pn.Tag.r)
}

$wraps = @(Find-ByBack $sp $edge | Where-Object { $_.Tag -and $_.Tag.r -eq 10 })
Chk 'grid wrap panels found' ($wraps.Count -eq 2) ("count=" + $wraps.Count)
foreach ($w in $wraps) {
    Chk 'wrap edge bg + Region' ($w.Region -ne $null -and $w.Tag.r -eq 10) ("client {0}x{1} region {2} r={3} pad={4}" -f $w.ClientSize.Width, $w.ClientSize.Height, (RegSize $w), $w.Tag.r, $w.Padding.All)
    $gg = @($w.Controls | Where-Object { $_ -is [System.Windows.Forms.DataGridView] })
    Chk 'wrap holds grid' ($gg.Count -eq 1) ("grids=" + $gg.Count)
    if ($gg.Count -eq 1) { Chk 'grid Tag.pan kept' ($gg[0].Tag.ContainsKey('pan')) ("keys=" + (($gg[0].Tag.Keys) -join ',')) }
}

# 时间轴 8x8 方块
$cols = @($app.TimelineFlow.Controls | Where-Object { $_.AccessibleName -ne 'tl-divider' })
$sq = @()
foreach ($c in $cols) { foreach ($p in $c.Controls) { if ($p -is [System.Windows.Forms.Panel] -and $p.Height -ne 2) { $sq += @($p.Controls) } } }
Chk 'timeline squares found' ($sq.Count -gt 0) ("count=" + $sq.Count)
$noReg = @($sq | Where-Object { -not $_.Region })
Chk 'all timeline squares rounded' ($noReg.Count -eq 0) ("without region=" + $noReg.Count)

""
if ($fail -eq 0) { "UICHECK OK" } else { "UICHECK FAILED ($fail)"; $form.Close(); $form.Dispose(); exit 1 }
$form.Close(); $form.Dispose()
