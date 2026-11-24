# clicktest.ps1 — 无人值守回归测试：构建 GUI、触发真实按钮回调、
# 用 Timer 在分析过程中采样进度条，校验进度条真的在动且结果正确。
# 放在项目根目录。它会加载 DemoAnalyzer.ps1 的函数定义（剥掉末尾交互式入口），
# 并手工修正 $Root —— 因为 Invoke-Expression 拿不到 $PSScriptRoot。

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$here = $PSScriptRoot
$src = Get-Content (Join-Path $here 'DemoAnalyzer.ps1') -Raw -Encoding UTF8
$idx = $src.IndexOf('# ---------------- 入口 ----------------')
if ($idx -lt 0) { throw '找不到入口分隔标记' }
$src = $src.Substring(0, $idx)
$src = $src -replace '(?s)^\s*param\s*\(.*?\)\s*\r?\n', ''
# Invoke-Expression 里 $PSScriptRoot 为空，会回退到当前目录 —— 这里直接锚定真实根目录
$src = $src -replace '(?m)^\$Root\s*=.*$', ('$Root = ' + "'" + $here + "'")
Invoke-Expression $src

$demo = 'E:\SteamLibrary\steamapps\common\Counter-Strike Global Offensive\game\csgo\g161-20260815040923040126584_de_mirage.dem'

"Root          : $Root"
"Analyzer      : $Analyzer   (存在=$(Test-Path $Analyzer))"
""

$form = Show-Gui
$app = $script:App

"窗体标题      : $($form.Text)"
"页签          : $((($app.Tabs.TabPages | ForEach-Object { $_.Text }) -join ' / '))"
"进度条        : 存在=$($null -ne $app.Bar)  范围=$($app.Bar.Minimum)-$($app.Bar.Maximum)"
"python        : $($app.Py)"

$form.Show()
[System.Windows.Forms.Application]::DoEvents()

# ---- 用 Timer 采样进度条，证明它真的在动 ----
$samples = New-Object System.Collections.ArrayList
$stages = New-Object System.Collections.ArrayList
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 50
$timer.Add_Tick({
        $v = $script:App.Bar.Value
        if ($samples.Count -eq 0 -or $samples[$samples.Count - 1] -ne $v) {
            [void]$samples.Add($v)
        }
        $t = $script:App.Status.Text
        if ($stages.Count -eq 0 -or $stages[$stages.Count - 1] -ne $t) {
            [void]$stages.Add($t)
        }
    })
$timer.Start()

# ---- 模拟「选择 demo 文件」的回调效果 ----
$app.Demo = $demo
$app.FileLbl.Text = $demo
$app.BtnRun.Enabled = $true
"模拟选择      : OK"
""

# ---- 触发「开始分析」真实回调（内部会泵消息，Timer 得以采样） ----
$t0 = Get-Date
$app.BtnRun.PerformClick()
$elapsed = ((Get-Date) - $t0).TotalSeconds
$timer.Stop()

""
"分析耗时      : $([math]::Round($elapsed,1))s"
"进度条采样值  : $($samples -join ' -> ')"
"采样档位个数  : $($samples.Count)"
""
"状态文本轨迹  :"
foreach ($s in $stages) { "   $s" }
""
"最终状态栏    : $($app.Status.Text)"
"最终进度条    : $($app.Bar.Value)"
"导出按钮可用  : $($app.BtnCsv.Enabled)"

if ($null -ne $app.Report) {
    "报告玩家数    : $($app.Report['players'].Count)"
    "队伍1         : $($app.Report['teams']['A']['label'])  开局 $($app.Report['teams']['A']['start_side'])"
    "队伍2         : $($app.Report['teams']['B']['label'])  开局 $($app.Report['teams']['B']['start_side'])"
}

function Set-Periods {
    param([string[]]$Keys)
    foreach ($k in @('first', 'second', 'overtime')) {
        $app.Checks[$k].Checked = ($Keys -contains $k)
    }
    # DemoAnalyzer 用 120ms 防抖 Timer 合并快速连点；测试里要等它渲染完
    for ($i = 0; $i -lt 8; $i++) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 40
    }
    # 兜底：若 Timer 仍在跑，强制刷新一次
    if ($app._viewTimer -and $app._viewTimer.Enabled) {
        $app._viewTimer.Stop()
        Render-View -Report $app.Report
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Dump-Page {
    param([string]$PeriodKey, [string]$PageKey, [string]$Title)
    Set-Periods @($PeriodKey)
    $ra = $app.Grids[$PageKey]['A'].Rows.Count
    $rb = $app.Grids[$PageKey]['B'].Rows.Count
    "  [{0}/{1}] 队伍1={2}行 队伍2={3}行   {4}" -f $PeriodKey, $Title, $ra, $rb, $app.PeriodInfo.Text
    if ($ra -gt 0) {
        "      队1首行: " + (($app.Grids[$PageKey]['A'].Rows[0].Cells | ForEach-Object { $_.Value }) -join ' | ')
    }
    if ($rb -gt 0) {
        "      队2首行: " + (($app.Grids[$PageKey]['B'].Rows[0].Cells | ForEach-Object { $_.Value }) -join ' | ')
    }
}

""
"---- 9 种组合（3 半场 x 3 页，单选）----"
foreach ($pk in @('first', 'second', 'overtime')) {
    foreach ($page in @(@('main', '主要数据'), @('util', '道具伤害'), @('fun', '娱乐数据'))) {
        Dump-Page -PeriodKey $pk -PageKey $page[0] -Title $page[1]
    }
}

""
"---- 多选叠加 ----"
foreach ($combo in @(
        @(@('first', 'second'), '上半场+下半场'),
        @(@('first', 'second', 'overtime'), '全部三个'),
        @(@('second', 'overtime'), '下半场+加时'),
        @(@(), '全不勾'))) {
    Set-Periods $combo[0]
    "  [{0}] 队伍1={1}行 队伍2={2}行   {3}" -f $combo[1],
    $app.Grids['main']['A'].Rows.Count, $app.Grids['main']['B'].Rows.Count,
    $app.PeriodInfo.Text
    if ($app.Grids['main']['A'].Rows.Count -gt 0) {
        "      队1首行: " + (($app.Grids['main']['A'].Rows[0].Cells | ForEach-Object { $_.Value }) -join ' | ')
    }
}

# ---- 叠加口径核对（列下标：1=Rating 2=击杀 8=总伤害 9=ADR）----
# 计数类相加；派生指标（ADR / K/D / 爆头率 / 道具占比 / Rating）按叠加后数据重算，
# 不是把两个半场的比率取平均 —— 这是后来改定的口径，见 Merge-Periods。
Set-Periods @('first')
$kFirst = 0
foreach ($r in $app.Grids['main']['A'].Rows) { $kFirst += [int]$r.Cells[2].Value }
# 首行（离子安）的伤害/ADR/Rating —— 下面核对必须始终是同一个人
$dmgFirst = [int]$app.Grids['main']['A'].Rows[0].Cells[8].Value
$adrFirst = [double]$app.Grids['main']['A'].Rows[0].Cells[9].Value
$ratFirst = [double]$app.Grids['main']['A'].Rows[0].Cells[1].Value
$rdFirst = [int]$app.Report['periods']['first']['rounds']

Set-Periods @('second')
$kSecond = 0
foreach ($r in $app.Grids['main']['A'].Rows) { $kSecond += [int]$r.Cells[2].Value }
$dmgSecond = [int]$app.Grids['main']['A'].Rows[0].Cells[8].Value
$adrSecond = [double]$app.Grids['main']['A'].Rows[0].Cells[9].Value
$ratSecond = [double]$app.Grids['main']['A'].Rows[0].Cells[1].Value
$rdSecond = [int]$app.Report['periods']['second']['rounds']

Set-Periods @('first', 'second')
$kBoth = 0
foreach ($r in $app.Grids['main']['A'].Rows) { $kBoth += [int]$r.Cells[2].Value }
$adrBoth = [double]$app.Grids['main']['A'].Rows[0].Cells[9].Value
$ratBoth = [double]$app.Grids['main']['A'].Rows[0].Cells[1].Value

# 期望：总伤害 / 总回合（整场口径），而不是 (上半场ADR + 下半场ADR) / 2
$adrRecompute = [math]::Round(($dmgFirst + $dmgSecond) / [double]($rdFirst + $rdSecond), 1)
$adrNaiveAvg = [math]::Round(($adrFirst + $adrSecond) / 2, 2)

""
"核对 击杀   上半场={0} 下半场={1} 叠加={2}  应当相加={3}" -f $kFirst, $kSecond, $kBoth, ($kFirst + $kSecond)
"核对 ADR    上半场={0} 下半场={1} 叠加={2}  按叠加重算={3}（取平均会是 {4}）" -f `
    $adrFirst, $adrSecond, $adrBoth, $adrRecompute, $adrNaiveAvg
"核对 Rating 上半场={0} 下半场={1} 叠加={2}  （按叠加后数据重算，非取平均）" -f $ratFirst, $ratSecond, $ratBoth

# ---- 断言 ----
Set-Periods @('first')

$m = $app.Grids['main']
$u = $app.Grids['util']
$f = $app.Grids['fun']

$okReport = ($null -ne $app.Report)
$okFirst = ($m['A'].Rows.Count -eq 5) -and ($m['B'].Rows.Count -eq 5)
$okPages = ($u['A'].Rows.Count -eq 5) -and ($u['B'].Rows.Count -eq 5) -and
           ($f['A'].Rows.Count -eq 5) -and ($f['B'].Rows.Count -eq 5)
$okBar = ($app.Bar.Value -eq 100)
$okSamples = ($samples.Count -ge 3)
$okCsv = $app.BtnCsv.Enabled
$okSplits = ($app.Splits.Count -eq 3) -and
            (@($app.Splits | Where-Object { -not $_.IsSplitterFixed }).Count -eq 3)

Set-Periods @('second')
$okSecond = ($app.Grids['main']['A'].Rows.Count -eq 5)

Set-Periods @('overtime')
$okOt = ($app.Grids['main']['A'].Rows.Count -eq 0)

# 叠加：计数类相加；派生指标按叠加后数据重算（不是把两个半场的比率取平均）
$okSum = ($kBoth -eq ($kFirst + $kSecond))
$okAvg = ([math]::Abs($adrBoth - $adrRecompute) -lt 0.15)

Set-Periods @()
$okNone = ($app.Grids['main']['A'].Rows.Count -eq 0)
$okNoneMsg = ($app.PeriodInfo.Text -eq '未选择半场')

""
"断言 报告=$okReport 上半场=$okFirst 三个页面=$okPages 进度条=$okBar 采样=$okSamples"
"断言 下半场切换=$okSecond 加时空=$okOt 导出可用=$okCsv 可拖动分栏=$okSplits"
"断言 叠加求和=$okSum 派生指标按叠加重算=$okAvg 全不勾清空=$okNone 提示=$okNoneMsg"

$ok = $okReport -and $okFirst -and $okPages -and $okBar -and $okSamples -and
      $okSecond -and $okOt -and $okCsv -and $okSplits -and
      $okSum -and $okAvg -and $okNone -and $okNoneMsg

$timer.Dispose()
$form.Close()
$form.Dispose()

if ($ok) { "CLICKTEST OK" } else { "CLICKTEST FAILED"; exit 1 }
