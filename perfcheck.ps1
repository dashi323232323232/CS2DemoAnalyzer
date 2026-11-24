$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class Res {
  [DllImport("user32.dll")] public static extern uint GetGuiResources(IntPtr h, uint f);
  [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
  public static uint Gdi()  { return GetGuiResources(GetCurrentProcess(), 0); }
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
$form.StartPosition = 'Manual'
$form.Location = New-Object System.Drawing.Point(-4000, -4000)
$form.Size = New-Object System.Drawing.Size(1560, 820)
$form.Show()
for ($i = 0; $i -lt 30; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }

$rep = Load-Report -JsonPath (Join-Path $here 'out\report.json')
$script:App.Report = $rep
$app.Checks['first'].Checked = $true
$app.Checks['second'].Checked = $true
Render-View -Report $rep
Render-Timeline
Render-Detail -Report $rep -Round 18
for ($i = 0; $i -lt 40; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40 }

'=== 双缓冲 ==='
foreach ($pair in @(@('Form', $form), @('TimelineFlow', $app.TimelineFlow), @('DetailPanel', $app.DetailPanel),
        @('表格A', $app.Grids['main']['A']), @('表格B', $app.Grids['main']['B']),
        @('时间轴列1', $app.TimelineFlow.Controls[0]))) {
    $pi = $pair[1].GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'NonPublic,Instance,Public')
    "  {0,-13} {1}" -f $pair[0], $pi.GetValue($pair[1])
}
''
'=== GDI 句柄泄漏（详情面板重绘 300 次）==='
$bmp = New-Object System.Drawing.Bitmap($app.DetailPanel.Width, $app.DetailPanel.Height)
$r = New-Object System.Drawing.Rectangle(0, 0, $app.DetailPanel.Width, $app.DetailPanel.Height)
$app.DetailPanel.DrawToBitmap($bmp, $r)
$before = [Res]::Gdi()
for ($i = 0; $i -lt 300; $i++) { $app.DetailPanel.DrawToBitmap($bmp, $r) }
$after = [Res]::Gdi()
"  重绘前 GDI = $before   重绘后 = $after   增加 $($after - $before)（修复前每次约 +6）"
$bmp.Dispose()
''
'=== 整窗重绘耗时 ==='
$b2 = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
$r2 = New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)
$form.DrawToBitmap($b2, $r2)
$sw = [System.Diagnostics.Stopwatch]::StartNew()
for ($i = 0; $i -lt 20; $i++) { $form.DrawToBitmap($b2, $r2) }
$sw.Stop()
"  整窗 20 次 = $($sw.ElapsedMilliseconds) ms  （每次 $([int]($sw.ElapsedMilliseconds / 20)) ms）"
$b2.Dispose()
''
'=== 分隔条拖动（改 SplitterDistance 40 步）==='
$sp = $app.Splits[0]
$sw2 = [System.Diagnostics.Stopwatch]::StartNew()
for ($i = 0; $i -lt 40; $i++) {
    try { $sp.SplitterDistance = (120 + ($i % 20)) } catch { }
    [System.Windows.Forms.Application]::DoEvents()
}
$sw2.Stop()
"  40 步 = $($sw2.ElapsedMilliseconds) ms  （每步 $([int]($sw2.ElapsedMilliseconds / 40)) ms）"
''
'=== 时间轴平移 40 步 ==='
$sw3 = [System.Diagnostics.Stopwatch]::StartNew()
for ($i = 0; $i -lt 40; $i++) {
    $app.TimelineFlow.AutoScrollPosition = New-Object System.Drawing.Point(($i * 3), 0)
    [System.Windows.Forms.Application]::DoEvents()
}
$sw3.Stop()
"  40 步 = $($sw3.ElapsedMilliseconds) ms  （每步 $([int]($sw3.ElapsedMilliseconds / 40)) ms）"
$form.Close(); $form.Dispose()
