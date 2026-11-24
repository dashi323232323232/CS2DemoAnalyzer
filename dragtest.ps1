# dragtest.ps1 — 拖动回归测试：用 SendMessage 直接给控件窗口发鼠标消息，
# 不移动真实光标、不抢焦点。窗口位置挪到屏幕外，用户看不见。
$ErrorActionPreference = 'Stop'
$fail = 0
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @'
using System;
using System.Runtime.InteropServices;
public class SM {
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  public const uint WM_MOUSEMOVE = 0x0200, WM_LBUTTONDOWN = 0x0201, WM_LBUTTONUP = 0x0202;
  public const int MK_LBUTTON = 0x0001;
  public static IntPtr LP(int x, int y) { return (IntPtr)((y << 16) | (x & 0xFFFF)); }
  public static void MoveTo(IntPtr h, int x, int y, bool down) {
    SendMessage(h, WM_MOUSEMOVE, (IntPtr)(down ? MK_LBUTTON : 0), LP(x, y));
  }
  public static void Down(IntPtr h, int x, int y) { SendMessage(h, WM_LBUTTONDOWN, (IntPtr)MK_LBUTTON, LP(x, y)); }
  public static void Up(IntPtr h, int x, int y)   { SendMessage(h, WM_LBUTTONUP,   IntPtr.Zero,     LP(x, y)); }
}
'@

$here = $PSScriptRoot
$src = Get-Content (Join-Path $here 'DemoAnalyzer.ps1') -Raw -Encoding UTF8
$src = $src.Substring(0, $src.IndexOf('# ---------------- 入口 ----------------'))
$src = $src -replace '(?s)^\s*param\s*\(.*?\)\s*\r?\n', ''
$src = $src -replace '(?m)^\$Root\s*=.*$', ('$Root = ' + "'" + $here + "'")
Invoke-Expression $src

$form = Show-Gui
$app = $script:App
# 挪到屏幕外，用户看不见；SendMessage 用客户区坐标，与窗口位置无关
$form.StartPosition = 'Manual'
$form.Location = New-Object System.Drawing.Point(-4000, -4000)
$form.Show()
for ($i = 0; $i -lt 25; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }

function Drag {
    param([IntPtr]$H, [int]$X, [int]$Y, [int]$Dx = 0, [int]$Dy = 0, [int]$Steps = 12)
    [SM]::Down($H, $X, $Y)
    [System.Windows.Forms.Application]::DoEvents()
    for ($i = 1; $i -le $Steps; $i++) {
        [SM]::MoveTo($H, $X + [int]($Dx * $i / $Steps), $Y + [int]($Dy * $i / $Steps), $true)
        [System.Windows.Forms.Application]::DoEvents()
    }
    [SM]::Up($H, $X + $Dx, $Y + $Dy)
    [System.Windows.Forms.Application]::DoEvents()
}

"窗体位置 = $($form.Location)   (屏幕外，不影响你)"
""

"===== 0) 两个队伍是上下排列 ====="
$sp0 = $app.Splits[0]
$p1 = $sp0.Panel1; $p2 = $sp0.Panel2
"方向 = $($sp0.Orientation)   Panel1 = {0}x{1} @{2},{3}   Panel2 = {4}x{5} @{6},{7}" -f `
    $p1.Width, $p1.Height, $p1.Left, $p1.Top, $p2.Width, $p2.Height, $p2.Left, $p2.Top
$okStack = ($sp0.Orientation -eq 'Horizontal') -and ($p2.Top -gt $p1.Top) -and
           ([Math]::Abs($p2.Left - $p1.Left) -le 4) -and ($p1.Width -eq $p2.Width)
if ($okStack) { "==> 上下排列（队伍1 在上、队伍2 在下，两张表等宽）OK" }
else { "==> 上下排列 FAIL"; $fail++ }

""
"===== 1) 分隔条拖动 ====="
$sp = $app.Splits[0]
$b1 = $sp.SplitterDistance
if ($sp.Orientation -eq 'Horizontal') {
    # 上下排列：分隔条是横的，抓它在屏幕上的中点往上拖
    $sx = [int]($sp.Width / 2)
    $sy = $sp.SplitterDistance + [int]($sp.SplitterWidth / 2)
    Drag -H $sp.Handle -X $sx -Y $sy -Dy -60
    $axis = '纵向'
} else {
    $sx = $sp.SplitterDistance + [int]($sp.SplitterWidth / 2)
    $sy = [int]($sp.Height / 2)
    Drag -H $sp.Handle -X $sx -Y $sy -Dx -160
    $axis = '横向'
}
"方向=$($sp.Orientation)（$axis）  SplitterDistance $b1 -> $($sp.SplitterDistance)   变化 $($sp.SplitterDistance - $b1)"
if ($sp.SplitterDistance -ne $b1) { "==> 分隔条可拖动 OK" } else { "==> 分隔条拖不动 FAIL"; $fail++ }

""
"===== 2) 表格内容左右拖拽 ====="
# 必须先载入数据：空表格在空白处 HitTest 不是 Cell，处理器会直接返回
if (Test-Path $OutJson) {
    $rep = Load-Report -JsonPath $OutJson
    $app.Report = $rep
    $app.Checks['first'].Checked = $true
    Render-View -Report $rep
    for ($i = 0; $i -lt 10; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
    "已载入数据，表格行数 = $($app.Grids['main']['A'].Rows.Count)"
}
else { "!! 没有 $OutJson，无法测试" }

# 上下排列后每张表独占整宽：1560 宽下列总宽 978 全能显示、没有横向溢出，
# 平移就没东西可拖。把窗体压到最小宽度（MinimumSize = 1000，再小会被钳回去）
# 让列溢出，才测得到平移本身——平移本来就是给窄窗口 / 列多的场合准备的。
$form.Size = New-Object System.Drawing.Size(1000, 820)
for ($i = 0; $i -lt 20; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40 }

$g = $app.Grids['main']['A']
$total = 0
foreach ($c in $g.Columns) { $total += [int]$c.Width }
"列总宽 $total  可视宽 $($g.ClientSize.Width)  可滚 $($total - $g.ClientSize.Width)"
$ht = $g.HitTest(120, 70)
"HitTest(120,70) 类型 = $($ht.Type)   行 = $($ht.RowIndex)"

$off0 = [int]$g.HorizontalScrollingOffset
Drag -H $g.Handle -X 120 -Y 70 -Dx -180
$off1 = [int]$g.HorizontalScrollingOffset
"往左拖: 偏移 $off0 -> $off1   变化 $($off1 - $off0)"
if ($off1 -gt $off0) { "==> 往左拖 = 内容左移、看到右边的列  OK" } else { "==> 表格拖不动 FAIL"; $fail++ }

Drag -H $g.Handle -X 120 -Y 70 -Dx 120
$off2 = [int]$g.HorizontalScrollingOffset
"往右拖: 偏移 $off1 -> $off2   变化 $($off2 - $off1)"
if ($off2 -lt $off1) { "==> 往右拖 = 内容右移  OK" } else { "==> 回拖失败 FAIL"; $fail++ }

# 单击（无位移）不应触发平移
$off3 = [int]$g.HorizontalScrollingOffset
[SM]::Down($g.Handle, 120, 70); [System.Windows.Forms.Application]::DoEvents()
[SM]::Up($g.Handle, 120, 70); [System.Windows.Forms.Application]::DoEvents()
$off4 = [int]$g.HorizontalScrollingOffset
"单击一下: 偏移 $off3 -> $off4   (应当不变)"
if ($off4 -eq $off3) { "==> 单击不误触发  OK" } else { "==> 单击误触发 FAIL"; $fail++ }

""
"===== 3) 上下限钳制 ====="
$g.HorizontalScrollingOffset = 0
Drag -H $g.Handle -X 400 -Y 70 -Dx -3000 -Steps 20
$o = [int]$g.HorizontalScrollingOffset
"往左狂拖: 偏移 = $o   (应等于最大值 $($total - $g.ClientSize.Width)，且不为负)"
$g.HorizontalScrollingOffset = 0
Drag -H $g.Handle -X 120 -Y 70 -Dx 3000 -Steps 20
$o2 = [int]$g.HorizontalScrollingOffset
"往右狂拖: 偏移 = $o2   (应为 0)"
$g.HorizontalScrollingOffset = 0

""
"===== 4) 表格下方空白区也能拖 ====="
$rowsBottom = $g.ColumnHeadersHeight + $g.Rows.Count * 22
$emptyY = [int]($g.ClientSize.Height - 30)
$htE = $g.HitTest(120, $emptyY)
"空白区 y=$emptyY  HitTest 类型 = $($htE.Type)"
$e0 = [int]$g.HorizontalScrollingOffset
Drag -H $g.Handle -X 120 -Y $emptyY -Dx -150
$e1 = [int]$g.HorizontalScrollingOffset
"空白区拖动: 偏移 $e0 -> $e1"
if ($e1 -gt $e0) { "==> 空白区也能拖  OK" } else { "==> 空白区拖不动 FAIL"; $fail++ }

""
"===== 5) 表头上拖不应平移（那是拖宽列） ====="
$g.HorizontalScrollingOffset = 0
$w0 = [int]$g.Columns[2].Width
$htH = $g.HitTest(200, 8)
"表头 y=8  HitTest 类型 = $($htH.Type)  列 = $($htH.ColumnIndex)"
Drag -H $g.Handle -X 200 -Y 8 -Dx -60
$h1 = [int]$g.HorizontalScrollingOffset
$w1 = [int]$g.Columns[2].Width
"表头拖动: 横向偏移 $h1 (应为 0)   列宽 $w0 -> $w1"
if ($h1 -eq 0) { "==> 表头拖动不触发平移  OK" } else { "==> 表头误触发平移 FAIL"; $fail++ }

""
"===== 6) 六个表格都挂上了平移 ====="
$n = 0
foreach ($pk in @('main', 'util', 'fun')) {
    foreach ($rid in @('A', 'B')) {
        $gg = $app.Grids[$pk][$rid]
        if ($gg.Tag -and $gg.Tag.ContainsKey('pan')) { $n++ }
    }
}
"挂载平移的表格数 = $n / 6"
if ($n -eq 6) { "==> 全部挂载  OK" } else { "==> 有遗漏 FAIL"; $fail++ }

$form.Close(); $form.Dispose()
if ($fail -eq 0) { "DRAGTEST OK" } else { "DRAGTEST FAILED（$fail 项）"; exit 1 }
