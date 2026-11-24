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
for ($i = 0; $i -lt 30; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 60 }

$rep = Load-Report -JsonPath (Join-Path $here 'out\report.json')
$script:App.Report = $rep
$app.Checks['first'].Checked = $true
$app.Checks['second'].Checked = $true
Render-View -Report $rep
Render-Timeline
for ($i = 0; $i -lt 40; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 60 }

"=== 布局 ==="
$dp = $app.DetailPanel
"  详情面板: $($dp.Width) x $($dp.Height)  Dock=$($dp.Dock)  可见=$($dp.Visible)"
$tabs = $app.Tabs
"  页签: $($tabs.Width) x $($tabs.Height)  Left=$($tabs.Left)"
"  面板 Left=$($dp.Left)  -> 面板在页签右边: $($dp.Left -ge ($tabs.Left + $tabs.Width))"
""
"=== 初始状态 ==="
"  DetailInfo = $($app.DetailInfo)   行数 = $(@($app.DetailRows).Count)"
""

$flow = $app.TimelineFlow
$cards = @($flow.Controls | Where-Object { $_.AccessibleName -ne 'tl-divider' })
$dividers = @($flow.Controls | Where-Object { $_.AccessibleName -eq 'tl-divider' })
"时间轴卡片数 = $($cards.Count)   （另有换边分隔条 $($dividers.Count) 条）"
""

$mDown = [System.Windows.Forms.Control].GetMethod('OnMouseDown', [System.Reflection.BindingFlags]'NonPublic,Instance')
$mMove = [System.Windows.Forms.Control].GetMethod('OnMouseMove', [System.Reflection.BindingFlags]'NonPublic,Instance')
$mUp = [System.Windows.Forms.Control].GetMethod('OnMouseUp', [System.Reflection.BindingFlags]'NonPublic,Instance')

function Raise-Mouse($mi, $ctrl, $x, $y) {
    $a = New-Object 'object[]' 1
    # 用 ::new() 而不是 New-Object：后者返回的对象带 PSObject 包装，
    # 塞进 object[] 再反射调用会因为类型转换失败而抛异常。
    $a[0] = [System.Windows.Forms.MouseEventArgs]::new([System.Windows.Forms.MouseButtons]::Left, 1, $x, $y, 0)
    $mi.Invoke($ctrl, $a)
}

# 真实输入序列：MouseDown 落在卡片里的子控件上（tlStartPan 会把 Capture 交给 flow），
# 之后 MouseUp 归 flow 收 —— 单击判定就发生在 flow 的 MouseUp 里。
# 早先的测试直接反射调 Control.OnClick，绕过了整条真实路径，所以没测出「点了没反应」。
function Click-Card($card) {
    $child = $card
    if ($card.Controls.Count -gt 0) { $child = $card.Controls[0] }
    $p = $card.Location
    Raise-Mouse $mDown $child 5 5
    Raise-Mouse $mUp $flow ($p.X + 5) ($p.Y + 5)
}

function Drag-Card($card) {
    $child = $card
    if ($card.Controls.Count -gt 0) { $child = $card.Controls[0] }
    $p = $card.Location
    Raise-Mouse $mDown $child 5 5
    Raise-Mouse $mMove $flow ($p.X + 5) ($p.Y + 5)   # 起点，还没过阈值
    Raise-Mouse $mMove $flow ($p.X + 65) ($p.Y + 5)  # 超过 5px = 真拖动
    Raise-Mouse $mUp $flow ($p.X + 65) ($p.Y + 5)
}

$ok = $true

# ---- 真实单击必须能切右侧面板 ----
foreach ($idx in @(0, 4, 11, 17)) {
    if ($idx -ge $cards.Count) { continue }
    Click-Card $cards[$idx]
    for ($i = 0; $i -lt 6; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40 }
    $expect = [int]$rep['timeline'][$idx]['round']
    $got = if ($app.DetailInfo) { [int]$app.DetailInfo['round'] } else { -1 }
    $nrow = @($app.DetailRows).Count
    $nexp = @($rep['timeline'][$idx]['detail']).Count
    $good = ($got -eq $expect -and $nrow -eq $nexp)
    if (-not $good) { $ok = $false }
    "  真实单击第 {0,2} 张卡片 -> 面板显示第 {1} 回合（应为 {2}），{3} 行（应为 {4}）  {5}" -f `
        ($idx + 1), $got, $expect, $nrow, $nexp, $(if ($good) { 'OK' } else { 'FAIL' })
}

# ---- 拖动之后不能误开详情面板 ----
Click-Card $cards[0]
for ($i = 0; $i -lt 6; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40 }
$before = if ($app.DetailInfo) { [int]$app.DetailInfo['round'] } else { -1 }
Drag-Card $cards[3]
for ($i = 0; $i -lt 6; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40 }
$after = if ($app.DetailInfo) { [int]$app.DetailInfo['round'] } else { -1 }
$dragOk = ($after -eq $before)
if (-not $dragOk) { $ok = $false }
"  拖动第 4 张卡片 -> 面板仍是第 {0} 回合（拖动前是第 {1} 回合）  {2}" -f $after, $before, $(if ($dragOk) { 'OK' } else { 'FAIL' })

# ---- 拖动之后重新单击，应当正常切换 ----
Click-Card $cards[3]
for ($i = 0; $i -lt 6; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40 }
$after2 = if ($app.DetailInfo) { [int]$app.DetailInfo['round'] } else { -1 }
$clickOk = ($after2 -eq [int]$rep['timeline'][3]['round'])
if (-not $clickOk) { $ok = $false }
"  拖动后重新单击第 4 张卡片 -> 面板显示第 {0} 回合（应为 {1}）  {2}" -f $after2, [int]$rep['timeline'][3]['round'], $(if ($clickOk) { 'OK' } else { 'FAIL' })
""

# ---- 选中的那一列必须在时间轴上标出来 ----
# 列本身 + 两个「方块行」容器都要变色；只改列的话会被白底的方块行盖住。
function Get-ColBg($round) {
    $c = $app.TlColumns[$round]
    if (-not $c) { return $null }
    $rows = @($c.Controls | Where-Object { $_ -is [System.Windows.Forms.Panel] -and $_.Height -ne 2 })
    return [pscustomobject]@{
        Col  = $c.BackColor
        Rows = @($rows | ForEach-Object { $_.BackColor })
    }
}
$sel = [int]$app.SelectedRound
$selBg = Get-ColBg $sel
$other = @($rep['timeline'] | Where-Object { [int]$_['round'] -ne $sel })[0]
$othBg = Get-ColBg ([int]$other['round'])
$selGood = $selBg -and ($selBg.Col.ToArgb() -eq (Get-TlSelColor).ToArgb()) -and
           (@($selBg.Rows | Where-Object { $_.ToArgb() -ne (Get-TlSelColor).ToArgb() }).Count -eq 0)
$othGood = $othBg -and ($othBg.Col.ToArgb() -eq [System.Drawing.Color]::White.ToArgb()) -and
           (@($othBg.Rows | Where-Object { $_.ToArgb() -ne [System.Drawing.Color]::White.ToArgb() }).Count -eq 0)
if (-not ($selGood -and $othGood)) { $ok = $false }
"  选中第 {0} 回合的高亮 -> 列底色 {1}，方块行 {2} 个  {3}" -f `
    $sel, $(if ($selGood) { '已上色' } else { "不对 $($selBg.Col)" }), @($selBg.Rows).Count, $(if ($selGood) { 'OK' } else { 'FAIL' })
"  未选中的第 {0} 回合       -> 列底色 {1}  {2}" -f `
    [int]$other['round'], $(if ($othGood) { '白色（未受影响）' } else { "不对 $($othBg.Col)" }), $(if ($othGood) { 'OK' } else { 'FAIL' })
""

# ---- 标题区：分隔线不能压在副标题上，滚动高度必须和标题区同源 ----
# 曾经 $headH 在 Paint 里写死 48、分隔线画在 48-8=40，而副标题从 y=33 起、
# 9pt 雅黑高 17px（占 33..50）—— 线正好把副标题那一行的字整个盖掉。
# 同一组数字还在 Render-Detail 里又写了一遍算滚动高度，改一处必坏另一处。
# 这个 bug 之前没有任何断言覆盖，所以补在这里。
$gdi = $script:DetailGdi
$subH = [System.Windows.Forms.TextRenderer]::MeasureText('上半场    比分 0:0    开局 CT = 队伍1', $gdi.FontBody).Height
$divOk = ([int]$gdi.YDiv -ge ([int]$gdi.YSub + $subH))
if (-not $divOk) { $ok = $false }
"  分隔线 y={0}，副标题占 {1}..{2}  -> {3}" -f $gdi.YDiv, $gdi.YSub, ([int]$gdi.YSub + $subH), $(if ($divOk) { 'OK（在副标题下方）' } else { 'FAIL（压在副标题上）' })

$nRows = @($app.DetailRows).Count
$wantScroll = [int]$gdi.HeadH + ($nRows * [int]$gdi.RowH) + 14
$gotScroll = [int]$dp.AutoScrollMinSize.Height
$scrollOk = ($wantScroll -eq $gotScroll)
if (-not $scrollOk) { $ok = $false }
"  滚动高度 {0} = 标题 {1} + {2} 行 x {3} + 14  -> {4}" -f `
    $gotScroll, $gdi.HeadH, $nRows, $gdi.RowH, $(if ($scrollOk) { 'OK' } else { "FAIL（应为 $wantScroll）" })
""

"=== 面板位图 ==="
$bmp = New-Object System.Drawing.Bitmap($dp.Width, [Math]::Min($dp.Height, 420))
$dp.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $bmp.Width, $bmp.Height)))
$out = Join-Path $here 'out\detail_panel.png'
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
"  面板位图: $out ($($bmp.Width)x$($bmp.Height))"
""
"  当前面板内容: 第 $($app.DetailInfo['round']) 回合  $($app.DetailInfo['period'])  比分 $($app.DetailInfo['scoreA']):$($app.DetailInfo['scoreB'])"
foreach ($r in $app.DetailRows) {
    $k = $r['kind']
    if ($k -eq 'kill') {
        "    {0,-5} {1}v{2}  {3}({4}) -> {5}({6})  {7}" -f $r['t'], $r['alive_a'], $r['alive_b'], $r['attacker'], $r['attacker_side'], $r['victim'], $r['victim_side'], $r['weapon']
    } elseif ($k -eq 'plant' -or $k -eq 'defuse') {
        "    {0,-5} {1}v{2}  {3} {4}({5})" -f $r['t'], $r['alive_a'], $r['alive_b'], $k, $r['user'], $r['user_side']
    } else {
        "    {0,-5} {1}v{2}  {3}" -f $r['t'], $r['alive_a'], $r['alive_b'], ($r['text'] + $r['reason'])
    }
}
$bmp.Dispose()
$form.Close(); $form.Dispose()
if ($ok) { "DETAILTEST OK" } else { "DETAILTEST FAIL"; exit 1 }
