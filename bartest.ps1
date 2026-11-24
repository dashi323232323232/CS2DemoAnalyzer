$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class BarRes {
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

$fail = 0
function Check($name, $cond, $detail) {
    if ($cond) { "  OK   $name  $detail" }
    else { "  FAIL $name  $detail"; $script:fail++ }
}

$form = Show-Gui
$form.StartPosition = 'Manual'
$form.Location = New-Object System.Drawing.Point(-4000, -4000)
$form.Size = New-Object System.Drawing.Size(1560, 820)
$form.Show()
for ($i = 0; $i -lt 20; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40 }

$bar = $script:App.Bar

'=== 控件类型 ==='
"  实际类型 = $($bar.GetType().FullName)"
Check '进度条是自绘 Panel' ($bar -is [System.Windows.Forms.Panel]) ''
Check '不再是系统 ProgressBar' (-not ($bar -is [System.Windows.Forms.ProgressBar])) ''

'=== Value / Minimum / Maximum 语义（调用点和 clicktest.ps1 都靠它）==='
$bar.Minimum = 0
$bar.Maximum = 100
$bar.Value = 0
Check 'Value 读回 0' ($bar.Value -eq 0) "读回 $($bar.Value)"
$bar.Value = 37
Check 'Value 写 37' ($bar.Value -eq 37) "读回 $($bar.Value)"
Check 'Minimum 读回 0' ($bar.Minimum -eq 0) "读回 $($bar.Minimum)"
Check 'Maximum 读回 100' ($bar.Maximum -eq 100) "读回 $($bar.Maximum)"
Check 'Value 是 Int32' ($bar.Value.GetType().Name -eq 'Int32') "实际 $($bar.Value.GetType().Name)"

$w = $bar.Width
$h = $bar.Height
$bmp = New-Object System.Drawing.Bitmap($w, $h)
$rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)

# 量中间一行里蓝色填充的像素占比。DrawToBitmap 之前刻意不 DoEvents：
# 自绘的话设完 Value 当场就是最终样子；系统 ProgressBar 会补间，量出来会偏小。
function Fill-Pct($bar, $bmp, $rect) {
    $bar.DrawToBitmap($bmp, $rect)
    $y = [int]($bmp.Height / 2)
    $n = 0
    for ($x = 0; $x -lt $bmp.Width; $x++) {
        $c = $bmp.GetPixel($x, $y)
        if (($c.B - $c.R) -gt 40) { $n++ }
    }
    return [int][math]::Round(100.0 * $n / $bmp.Width)
}

'=== 填充比例 vs Value（设完立刻量，中间不泵消息）==='
foreach ($v in @(0, 25, 50, 75, 100)) {
    $bar.Value = $v
    $pct = Fill-Pct $bar $bmp $rect
    Check "Value=$v" ([math]::Abs($pct - $v) -le 1) "实测填充 $pct%"
}

'=== Minimum/Maximum 不是 0/100 时按比例换算 ==='
$bar.Minimum = 0
$bar.Maximum = 200
$bar.Value = 50
$pct = Fill-Pct $bar $bmp $rect
Check 'Max=200 Value=50 -> 25%' ([math]::Abs($pct - 25) -le 1) "实测填充 $pct%"
$bar.Maximum = 100

'=== GDI 句柄（每换一个宽度就重建填充路径和渐变，旧的必须回收）==='
$bar.Value = 0
[void](Fill-Pct $bar $bmp $rect)
$before = [BarRes]::Gdi()
for ($i = 0; $i -lt 300; $i++) {
    $bar.Value = ($i % 101)
    $bar.DrawToBitmap($bmp, $rect)
}
$after = [BarRes]::Gdi()
Check '300 次换值重绘不涨 GDI' (($after - $before) -le 20) "增加 $($after - $before)"

$bmp.Dispose()
$form.Close()
$form.Dispose()

if ($fail -eq 0) { 'BARTEST OK' } else { "BARTEST FAILED（$fail 项）"; exit 1 }
