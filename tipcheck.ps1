$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$here = $PSScriptRoot
$src = Get-Content (Join-Path $here 'DemoAnalyzer.ps1') -Raw -Encoding UTF8
$src = $src.Substring(0, $src.IndexOf('# ---------------- 入口 ----------------'))
$src = $src -replace '(?s)^\s*param\s*\(.*?\)\s*\r?\n', ''
$src = $src -replace '(?m)^\$Root\s*=.*$', ('$Root = ' + "'" + $here + "'")
Invoke-Expression $src

$rep = Load-Report -JsonPath (Join-Path $here 'out\report.json')
"报告回合数: $(@($rep['timeline']).Count)"
""
"=== 每回合的悬浮详情行数 ==="
foreach ($r in @($rep['timeline'])) {
    $d = Format-TimelineDetail -Round $r
    $lines = @($d -split "`r`n")
    $kills = @($r['kills']).Count
    "  R{0,-3} 击杀={1,-3} 详情行数={2,-3} 首行=[{3}]" -f `
        $r['round'], $kills, $lines.Count, $lines[0]
}
""
"=== 详情最长的一回合，完整内容 ==="
$best = $null; $bestN = -1
foreach ($r in @($rep['timeline'])) {
    $n = @($r['kills']).Count
    if ($n -gt $bestN) { $bestN = $n; $best = $r }
}
$d = Format-TimelineDetail -Round $best
"R$($best['round']) 击杀 $bestN"
$d
""
"=== 提示框控件属性 ==="
$form = Show-Gui
$tt = $script:App.TimelineTip
"  AutoPopDelay = $($tt.AutoPopDelay)"
"  InitialDelay = $($tt.InitialDelay)"
"  ShowAlways   = $($tt.ShowAlways)"
"  IsBalloon    = $($tt.IsBalloon)"
"  BackColor    = $($tt.BackColor)"
"  ForeColor    = $($tt.ForeColor)"
$form.Close(); $form.Dispose()
"done"
