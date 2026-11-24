$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$here = $PSScriptRoot
$src = Get-Content (Join-Path $here 'DemoAnalyzer.ps1') -Raw -Encoding UTF8
$src = $src.Substring(0, $src.IndexOf('# ---------------- 入口 ----------------'))
$src = $src -replace '(?s)^\s*param\s*\(.*?\)\s*\r?\n', ''
$src = $src -replace '(?m)^\$Root\s*=.*$', ('$Root = ' + "'" + $here + "'")
Invoke-Expression $src

$round = 18
if ($args.Count -ge 1) { $round = [int]$args[0] }

$form = Show-Gui
$form.StartPosition = 'Manual'
$form.Location = New-Object System.Drawing.Point(-4000, -4000)
$form.Size = New-Object System.Drawing.Size(1560, 820)
$form.Show()
for ($i = 0; $i -lt 30; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 60 }

$rep = Load-Report -JsonPath (Join-Path $here 'out\report.json')
$script:App.Report = $rep
$script:App.Checks['first'].Checked = $true
$script:App.Checks['second'].Checked = $true
Render-View -Report $rep
Render-Timeline
for ($i = 0; $i -lt 50; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 60 }

# 走真实点击路径，选中指定回合
$flow = $script:App.TimelineFlow
$cards = @($flow.Controls)
$idx = $round - 1
if ($idx -ge 0 -and $idx -lt $cards.Count) {
    # 必须走真实鼠标序列：MouseDown 落在卡片的子控件上（tlStartPan 会把 Capture
    # 交给 flow），MouseUp 发给 flow（单击判定在 $tlEndPan 里）。
    # 直接反射调 Control.OnClick 是没用的 —— 卡片根本收不到 Click，见 README。
    $card = $cards[$idx]
    $child = $card
    if ($card.Controls.Count -gt 0) { $child = $card.Controls[0] }
    $mDown = [System.Windows.Forms.Control].GetMethod('OnMouseDown', [System.Reflection.BindingFlags]'NonPublic,Instance')
    $mUp = [System.Windows.Forms.Control].GetMethod('OnMouseUp', [System.Reflection.BindingFlags]'NonPublic,Instance')
    $a1 = New-Object 'object[]' 1
    $a1[0] = [System.Windows.Forms.MouseEventArgs]::new([System.Windows.Forms.MouseButtons]::Left, 1, 5, 5, 0)
    $mDown.Invoke($child, $a1)
    $p = $card.Location
    $a2 = New-Object 'object[]' 1
    $a2[0] = [System.Windows.Forms.MouseEventArgs]::new([System.Windows.Forms.MouseButtons]::Left, 1, ($p.X + 5), ($p.Y + 5), 0)
    $mUp.Invoke($flow, $a2)
}
for ($i = 0; $i -lt 20; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 60 }

# 截图前先确认面板真的填上了：空状态也能截出图，但那张图没有意义。
if (-not $script:App.DetailInfo) { throw "点击第 $round 张卡片后详情面板还是空的，截图没有意义" }
"面板已填充: 第 $($script:App.DetailInfo['round']) 回合，$(@($script:App.DetailRows).Count) 行"

$bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
$form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
$out = Join-Path $here ("out\shot_detail_r{0}.png" -f $round)
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
"截图: $out ($($bmp.Width)x$($bmp.Height))"

$dp = $script:App.DetailPanel
$bmp2 = New-Object System.Drawing.Bitmap($dp.Width, $dp.Height)
$dp.DrawToBitmap($bmp2, (New-Object System.Drawing.Rectangle(0, 0, $dp.Width, $dp.Height)))
$out2 = Join-Path $here ("out\panel_r{0}.png" -f $round)
$bmp2.Save($out2, [System.Drawing.Imaging.ImageFormat]::Png)
"面板: $out2 ($($bmp2.Width)x$($bmp2.Height))"

$bmp.Dispose(); $bmp2.Dispose()
$form.Close(); $form.Dispose()
