# tltest.ps1 — 时间轴专项回归测试
# 1) 纵向不用拖滑块：卡片总高必须放得下（含横向滚动条的占用）
# 2) X 轴能左右拖：按住「卡片」也能拖（卡片曾把 flow 的 MouseDown 挡掉）
# 3) 中间轴 = 回合数 + 获胜方式
# 4) 上下两条 = 双方存活人数 × 小条
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @'
using System;
using System.Runtime.InteropServices;
public class TL {
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  public const uint WM_MOUSEMOVE = 0x0200, WM_LBUTTONDOWN = 0x0201, WM_LBUTTONUP = 0x0202;
  public const int MK_LBUTTON = 0x0001;
  public static IntPtr LP(int x, int y) { return (IntPtr)((y << 16) | (x & 0xFFFF)); }
  public static void Down(IntPtr h, int x, int y) { SendMessage(h, WM_LBUTTONDOWN, (IntPtr)MK_LBUTTON, LP(x, y)); }
  public static void Move(IntPtr h, int x, int y, bool down) { SendMessage(h, WM_MOUSEMOVE, (IntPtr)(down ? MK_LBUTTON : 0), LP(x, y)); }
  public static void Up(IntPtr h, int x, int y) { SendMessage(h, WM_LBUTTONUP, IntPtr.Zero, LP(x, y)); }
}
'@

$here = $PSScriptRoot
$src = [System.IO.File]::ReadAllText((Join-Path $here 'DemoAnalyzer.ps1'), [System.Text.Encoding]::UTF8)
$idx = $src.IndexOf('# ---------------- 入口 ----------------')
$src = $src.Substring(0, $idx)
$src = $src -replace '(?s)^\s*param\s*\(.*?\)\s*\r?\n', ''
$src = $src -replace '(?m)^\$Root\s*=.*$', ('$Root = ' + "'" + $here + "'")
Invoke-Expression $src

$form = Show-Gui
$app = $script:App
$form.StartPosition = 'Manual'
$form.Location = New-Object System.Drawing.Point(-4000, -4000)
$form.Show()
for ($i = 0; $i -lt 30; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40 }

# 载入报告并渲染（勾上半场+下半场）
$rep = Load-Report -JsonPath $OutJson
$app.Report = $rep
$app._suspendView = $true
foreach ($k in @('first', 'second', 'overtime')) { $app.Checks[$k].Checked = ($k -ne 'overtime') }
$app._suspendView = $false
Render-View -Report $rep
Render-Timeline
for ($i = 0; $i -lt 30; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40 }

$flow = $app.TimelineFlow
# 换边分隔条和卡片列混在同一个 FlowLayoutPanel 里，先按标记拆开：
# 只有卡片列才有「回合数 / 获胜方式 / 上下两排方块」那套结构。
$items = @($flow.Controls)
$cards = @($items | Where-Object { $_.AccessibleName -ne 'tl-divider' })
$dividers = @($items | Where-Object { $_.AccessibleName -eq 'tl-divider' })
"时间轴标题      : $($app.TimelineLbl.Text)"
"卡片数          : $($cards.Count)   （另有换边分隔条 $($dividers.Count) 条）"
"flow 客户区     : $($flow.ClientSize.Width) x $($flow.ClientSize.Height)"
"横向滚动条可见  : $($flow.HorizontalScroll.Visible)"
"纵向滚动条可见  : $($flow.VerticalScroll.Visible)"
""

# ---------- 0) 标题不能压住 flow（这就是「显示不全」的根因） ----------
# WinForms 的停靠按 z 序「反着」处理：后 Add 的先停靠。如果先 Add 标题再 Add flow，
# flow 会先占满整块、标题再压在它上面，时间轴最上面 18px 被盖住、第一排方块看不见。
$lblB = $app.TimelineLbl
"标题 Bounds     : $($lblB.Bounds)"
"flow Bounds     : $($flow.Bounds)"
$overlapY = [Math]::Max(0, [Math]::Min($lblB.Bottom, $flow.Bottom) - [Math]::Max($lblB.Top, $flow.Top))
$okNoOverlap = ($overlapY -eq 0)
"==> 标题与 flow 不重叠: $(if ($okNoOverlap) { 'OK' } else { "FAIL 纵向重叠 $overlapY px —— 标题会盖住时间轴顶部" })"
# flow 必须正好从标题下沿开始
$okBelow = ([Math]::Abs($flow.Top - $lblB.Bottom) -le 1)
"==> flow 紧接标题下沿   : $(if ($okBelow) { 'OK' } else { "FAIL flow.Top=$($flow.Top) 标题底=$($lblB.Bottom)" })"
""

# ---------- 1) 纵向放得下 ----------
$need = 0
foreach ($c in $items) { $need = [Math]::Max($need, $c.Height + $c.Margin.Vertical) }
# 若横向滚动条出现，会占掉约 17px 客户区高度
$hscroll = if ($flow.HorizontalScroll.Visible) { [System.Windows.Forms.SystemInformation]::HorizontalScrollBarHeight } else { 0 }
$avail = $flow.ClientSize.Height - $hscroll - $flow.Padding.Vertical
"卡片所需高      : $need  (可用 $avail，含横向滚动条占用 $hscroll)"
$okFit = ($need -le $avail)
"==> 纵向不用拖滑块: $(if ($okFit) { 'OK' } else { "FAIL 超出 $($need - $avail)px" })"
$okNoVScroll = -not $flow.VerticalScroll.Visible
"==> 无纵向滚动条  : $(if ($okNoVScroll) { 'OK' } else { 'FAIL' })"
""

# ---------- 3) + 4) 一列的内容：轴线 + 回合数 + 获胜方式 + 上下方块 ----------
# 结构约定：每列是 1 个无边框 Panel，里面有
#   - 1 条轴线（Height=2）
#   - 2 个方块行（Height=10，分别装队伍1/队伍2 的方块）
#   - 2 个 Label（回合数 R##、获胜方式）
function Get-ColParts($col) {
    $labels = @($col.Controls | Where-Object { $_ -is [System.Windows.Forms.Label] })
    $panels = @($col.Controls | Where-Object { $_ -is [System.Windows.Forms.Panel] })
    [pscustomobject]@{
        Axis   = @($panels | Where-Object { $_.Height -eq 2 }) | Select-Object -First 1
        Rows   = @($panels | Where-Object { $_.Height -ne 2 } | Sort-Object Top)
        Labels = $labels
        Rnd    = ($labels | Where-Object { $_.Text -match '^R\d+$' } | Select-Object -First 1)
        Win    = ($labels | Where-Object { $_.Text -notmatch '^R\d+$' } | Select-Object -First 1)
    }
}

$bad = @()
foreach ($col in $cards) {
    $p = Get-ColParts $col
    if ($col.BorderStyle -ne 'None') { $bad += "列还有边框（应当是 None）" }
    if (-not $p.Axis) { $bad += "缺中间轴线" }
    if ($p.Rows.Count -ne 2) { $bad += "方块行数=$($p.Rows.Count)（应为2）" }
    if (-not $p.Rnd) { $bad += "缺回合数" }
    if (-not $p.Win -or $p.Win.Text -eq '') { $bad += "缺获胜方式" }
}
"一列结构检查    : $(if ($bad.Count -eq 0) { 'OK（无边框列 = 轴线 + 回合数 + 获胜方式 + 上下两排方块）' } else { 'FAIL ' + (($bad | Select-Object -Unique) -join '; ') })"
$okStruct = ($bad.Count -eq 0)

# 逐回合核对方块数量 == 报告里的存活人数
$tl = @($rep['timeline'] | Where-Object { $_.period -ne 'overtime' } | Sort-Object { [int]$_.round })
$mismatch = @()
for ($i = 0; $i -lt [Math]::Min($cards.Count, $tl.Count); $i++) {
    $p = Get-ColParts $cards[$i]
    $a = @($p.Rows[0].Controls).Count
    $b = @($p.Rows[1].Controls).Count
    $wantA = [int]$tl[$i]['alive']['A']
    $wantB = [int]$tl[$i]['alive']['B']
    if ($a -ne $wantA -or $b -ne $wantB) {
        $mismatch += ("R{0}: 上={1}(应{2}) 下={3}(应{4})" -f $tl[$i]['round'], $a, $wantA, $b, $wantB)
    }
}
"方块数量核对    : $(if ($mismatch.Count -eq 0) { 'OK（与报告 alive 完全一致）' } else { 'FAIL ' + ($mismatch -join '; ') })"
$okBars = ($mismatch.Count -eq 0)

# 对称性 + 轴线连续 + 方块居中
$asym = @()
$axisY = $null
foreach ($col in $cards) {
    $p = Get-ColParts $col
    if (-not $p.Axis -or $p.Rows.Count -ne 2) { continue }
    if ($null -eq $axisY) { $axisY = $p.Axis.Top + $p.Axis.Height / 2.0 }
    $cy = $p.Axis.Top + $p.Axis.Height / 2.0
    $topC = $p.Rows[0].Top + $p.Rows[0].Height / 2.0
    $botC = $p.Rows[1].Top + $p.Rows[1].Height / 2.0
    # 上下两排必须相对「轴线」镜像
    if ([Math]::Abs(($cy - $topC) - ($botC - $cy)) -gt 1.0) {
        $asym += ("上下排不相对轴线镜像: 上={0:N1} 轴={1:N1} 下={2:N1}" -f $topC, $cy, $botC)
    }
    # 上排必须在轴线上方、下排必须在下方
    if ($p.Rows[0].Bottom -gt $p.Axis.Top) { $asym += "上排在轴线下方（压线了）" }
    if ($p.Rows[1].Top -lt $p.Axis.Bottom) { $asym += "下排在轴线上方（压线了）" }
    # 轴线必须横跨整列，否则接不成一条连续的线
    if ($p.Axis.Left -ne 0 -or $p.Axis.Width -ne $col.ClientSize.Width) {
        $asym += ("轴线没横跨整列: Left={0} Width={1} 列宽={2}" -f $p.Axis.Left, $p.Axis.Width, $col.ClientSize.Width)
    }
    # 方块在行里水平居中：左右留白之差不超过 2px
    foreach ($row in $p.Rows) {
        $sq = @($row.Controls)
        if ($sq.Count -eq 0) { continue }
        $left = ($sq | Measure-Object -Property Left -Minimum).Minimum
        $rightMost = ($sq | ForEach-Object { $_.Left + $_.Width } | Measure-Object -Maximum).Maximum
        if ([Math]::Abs($left - ($row.Width - $rightMost)) -gt 2) {
            $asym += ("方块没居中: 左留白={0} 右留白={1}" -f $left, ($row.Width - $rightMost))
        }
        # 方块必须是方的
        foreach ($s in $sq) {
            if ($s.Width -ne $s.Height) { $asym += "方块不是正方形 $($s.Width)x$($s.Height)" }
        }
    }
}
# 相邻两块的轴线必须首尾相接（列与列、列与换边分隔条之间都不能有横向空隙）
# 这里必须遍历 $items 而不是 $cards：分隔条也是整条轴上的一节。
$gaps = @()
for ($i = 0; $i -lt $items.Count - 1; $i++) {
    $a = $items[$i]; $b = $items[$i + 1]
    if ($b.Left -ne ($a.Left + $a.Width)) {
        $gaps += ("第{0}->{1} 块之间有 {2}px 空隙" -f ($i + 1), ($i + 2), ($b.Left - ($a.Left + $a.Width)))
    }
}
"上下/居中对称   : $(if ($asym.Count -eq 0) { 'OK（相对轴线镜像，方块是正方形且水平居中）' } else { 'FAIL ' + (($asym | Select-Object -First 3) -join '; ') })"
"轴线连成一条线  : $(if ($gaps.Count -eq 0) { "OK（$($items.Count) 块（含 $($dividers.Count) 条分隔条）首尾相接，无空隙）" } else { 'FAIL ' + (($gaps | Select-Object -First 3) -join '; ') })"
$okSym = ($asym.Count -eq 0) -and ($gaps.Count -eq 0)

# ---------- 5) 换边分隔条 ----------
# 相邻两回合的 ct_roster（哪支队当 CT）不同 = 换边。加时整段都叫 overtime、
# 段内还会再换边，所以只能靠 ct_roster 判断，不能靠 period。
$wantSwap = @()
for ($i = 1; $i -lt $tl.Count; $i++) {
    if ([string]$tl[$i - 1]['ct_roster'] -ne [string]$tl[$i]['ct_roster']) { $wantSwap += $i }
}
# 分隔条在 $items 里的下标 -> 换算成「它前面有几张卡片」
$gotSwap = @()
foreach ($d in $dividers) {
    $idx = -1
    for ($k = 0; $k -lt $items.Count; $k++) {
        if ([object]::ReferenceEquals($items[$k], $d)) { $idx = $k; break }
    }
    $before = 0
    for ($k = 0; $k -lt $idx; $k++) {
        if ($items[$k].AccessibleName -ne 'tl-divider') { $before++ }
    }
    $gotSwap += $before
}
$swapSame = ($gotSwap.Count -eq $wantSwap.Count)
if ($swapSame) {
    for ($i = 0; $i -lt $wantSwap.Count; $i++) { if ($gotSwap[$i] -ne $wantSwap[$i]) { $swapSame = $false } }
}
"换边分隔条      : $(if ($swapSame) { "OK（$($dividers.Count) 条，正好等于换边次数，位置也对）" } else { "FAIL 期望在第 $($wantSwap -join ',') 张卡片前各一条（共 $($wantSwap.Count) 条），实际在第 $($gotSwap -join ',') 张卡片前（共 $($gotSwap.Count) 条）" })"

# 分隔条自己也要有横向轴线片段 + 整列高的竖线，否则整条轴会在换边处断掉
$axisTop = if ($null -ne $axisY) { [int]($axisY - 1) } else { 28 }
$divBad = @()
foreach ($d in $dividers) {
    $ps = @($d.Controls | Where-Object { $_ -is [System.Windows.Forms.Panel] })
    $ha = @($ps | Where-Object { $_.Height -eq 2 })
    $vl = @($ps | Where-Object { $_.Height -gt 2 })
    if ($ha.Count -ne 1) {
        $divBad += "分隔条横向轴线片段数=$($ha.Count)（应为 1）"
    } elseif ($ha[0].Top -ne $axisTop -or $ha[0].Left -ne 0 -or $ha[0].Width -ne $d.ClientSize.Width) {
        $divBad += ("分隔条轴线没接上: Top={0}(应{1}) Left={2} Width={3}(应{4})" -f $ha[0].Top, $axisTop, $ha[0].Left, $ha[0].Width, $d.ClientSize.Width)
    }
    if ($vl.Count -ne 1) {
        $divBad += "分隔条竖线数=$($vl.Count)（应为 1）"
    } elseif ($vl[0].Height -ne $d.ClientSize.Height) {
        $divBad += ("分隔条竖线没整列高: {0} != {1}" -f $vl[0].Height, $d.ClientSize.Height)
    }
}
"分隔条接上轴线  : $(if ($divBad.Count -eq 0) { 'OK（横向轴线片段横跨整条，竖线整列高）' } else { 'FAIL ' + (($divBad | Select-Object -Unique) -join '; ') })"
$okDiv = ($swapSame -and $divBad.Count -eq 0)

# 抽样打印前 6 列
""
"---- 前 6 列 ----"
for ($i = 0; $i -lt [Math]::Min(6, $cards.Count); $i++) {
    $p = Get-ColParts $cards[$i]
    $r = $tl[$i]
    "  {0} | {1} | 上方块={2} 下方块={3}  (报告 alive A={4} B={5} winner={6})" -f `
        $p.Rnd.Text, $p.Win.Text,
        @($p.Rows[0].Controls).Count, @($p.Rows[1].Controls).Count,
        $r['alive']['A'], $r['alive']['B'], $r['winner']
}
""

# ---------- 2) X 轴拖动（按在卡片上） ----------
# 缩小后的卡片很可能已经放得下（19 回合 × 63px = 1197 < 1526），
# 所以先把窗口压窄强制溢出，才能真正验证拖动。
$form.Size = New-Object System.Drawing.Size(760, 820)
for ($i = 0; $i -lt 30; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40 }
"压窄窗口后 flow : $($flow.ClientSize.Width) x $($flow.ClientSize.Height)  横向滚动条=$($flow.HorizontalScroll.Visible)"
# 压窄后横向滚动条出现，纵向空间最紧 —— 这时也必须没有纵向滚动条
$okNoVScroll2 = -not $flow.VerticalScroll.Visible
"==> 压窄后仍无纵向滚动条: $(if ($okNoVScroll2) { 'OK' } else { 'FAIL' })"
$maxX = [int]$flow.HorizontalScroll.Maximum - [int]$flow.HorizontalScroll.LargeChange + 1
"可滚动范围      : 0 .. $maxX"
if ($maxX -le 0) {
    "!! 内容没有超出可视宽度，无法测试横向拖动"
    $okDrag = $false
    $okDragBack = $false
    $okClick = $false
}
else {
    $flow.AutoScrollPosition = New-Object System.Drawing.Point(0, 0)
    [System.Windows.Forms.Application]::DoEvents()

    # 把「卡片上的一个点」换算成屏幕坐标，再分别转成卡片 / flow 的客户区坐标，
    # 这样两次消息指的是同一个物理点，位移才有意义。
    $card = $cards[1]
    $cardOrigin = $card.PointToScreen((New-Object System.Drawing.Point(0, 0)))
    $flowOrigin = $flow.PointToScreen((New-Object System.Drawing.Point(0, 0)))
    $sx = $cardOrigin.X + 20
    $sy = $cardOrigin.Y + 20

    $before = -[int]$flow.AutoScrollPosition.X
    [TL]::Down($card.Handle, ($sx - $cardOrigin.X), ($sy - $cardOrigin.Y))
    [System.Windows.Forms.Application]::DoEvents()
    for ($i = 1; $i -le 10; $i++) {
        $px = $sx - [int](160 * $i / 10)
        [TL]::Move($flow.Handle, ($px - $flowOrigin.X), ($sy - $flowOrigin.Y), $true)
        [System.Windows.Forms.Application]::DoEvents()
    }
    [TL]::Up($flow.Handle, ($sx - 160 - $flowOrigin.X), ($sy - $flowOrigin.Y))
    [System.Windows.Forms.Application]::DoEvents()
    $after = -[int]$flow.AutoScrollPosition.X
    "按住卡片往左拖160px: 滚动偏移 $before -> $after   变化 $($after - $before)"
    $okDrag = ($after -gt $before)
    "==> 卡片上起拖可横向滚动: $(if ($okDrag) { 'OK' } else { 'FAIL' })"

    # 反向拖回
    $cardOrigin2 = $card.PointToScreen((New-Object System.Drawing.Point(0, 0)))
    $flowOrigin2 = $flow.PointToScreen((New-Object System.Drawing.Point(0, 0)))
    $sx2 = $cardOrigin2.X + 20
    $sy2 = $cardOrigin2.Y + 20
    $b2 = -[int]$flow.AutoScrollPosition.X
    [TL]::Down($card.Handle, ($sx2 - $cardOrigin2.X), ($sy2 - $cardOrigin2.Y))
    [System.Windows.Forms.Application]::DoEvents()
    for ($i = 1; $i -le 10; $i++) {
        $px = $sx2 + [int](120 * $i / 10)
        [TL]::Move($flow.Handle, ($px - $flowOrigin2.X), ($sy2 - $flowOrigin2.Y), $true)
        [System.Windows.Forms.Application]::DoEvents()
    }
    [TL]::Up($flow.Handle, ($sx2 + 120 - $flowOrigin2.X), ($sy2 - $flowOrigin2.Y))
    [System.Windows.Forms.Application]::DoEvents()
    $a2 = -[int]$flow.AutoScrollPosition.X
    "按住卡片往右拖120px: 滚动偏移 $b2 -> $a2   变化 $($a2 - $b2)"
    $okDragBack = ($a2 -lt $b2)
    "==> 反向拖回      : $(if ($okDragBack) { 'OK' } else { 'FAIL' })"

    # 单击（无位移）不应滚动
    $c3 = $card.PointToScreen((New-Object System.Drawing.Point(0, 0)))
    $b3 = -[int]$flow.AutoScrollPosition.X
    [TL]::Down($card.Handle, 20, 20); [System.Windows.Forms.Application]::DoEvents()
    [TL]::Up($flow.Handle, ($c3.X + 20 - $flowOrigin2.X), ($c3.Y + 20 - $flowOrigin2.Y))
    [System.Windows.Forms.Application]::DoEvents()
    $a3 = -[int]$flow.AutoScrollPosition.X
    $okClick = ($a3 -eq $b3)
    "单击一下          : 偏移 $b3 -> $a3  (应当不变)"
    "==> 单击不误滚动  : $(if ($okClick) { 'OK' } else { 'FAIL' })"
}

""
$ok = $okNoOverlap -and $okBelow -and $okFit -and $okNoVScroll -and $okNoVScroll2 -and $okStruct -and $okBars -and $okSym -and $okDiv -and $okDrag -and $okDragBack -and $okClick
$form.Close(); $form.Dispose()
if ($ok) { "TLTEST OK" } else { "TLTEST FAILED"; exit 1 }
