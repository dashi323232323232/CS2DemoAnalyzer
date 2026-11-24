# DemoAnalyzer.ps1 — CS2 demo 分析客户端（WinForms）
# 用法:
#   双击 启动.vbs
#   或: powershell -STA -ExecutionPolicy Bypass -File DemoAnalyzer.ps1 -DemoPath "x.dem"
#   命令行自检: ... -Cli -DemoPath "x.dem"
#   构建自检(不开窗): ... -SelfTest

param(
    [string]$DemoPath = '',
    [switch]$Cli,
    [switch]$SelfTest,
    [switch]$AutoRun
)

$ErrorActionPreference = 'Stop'

$Root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$Analyzer = Join-Path $Root 'src\analyzer.py'
$OutDir = Join-Path $Root 'out'
$OutJson = Join-Path $OutDir 'report.json'

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

# ---------------- Python 定位 ----------------
function Find-Python {
    $cands = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python311\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python310\python.exe'),
        'C:\Python311\python.exe',
        'C:\Python312\python.exe'
    )
    foreach ($c in $cands) {
        if (Test-Path $c) { return $c }
    }
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# ---------------- 调用分析器 ----------------
# 关于「不弹终端」：
#   直接用 Start-Process 起 python.exe，并加 -WindowStyle Hidden，
#   这样既不会创建可见控制台，也不依赖 cmd 包装。
#   不要再改回 `cmd.exe /c`：那会新开一个黑框终端。
function Get-ProgressPath { Join-Path $OutDir 'progress.json' }
function Get-LogPath { Join-Path $OutDir 'analyzer.log' }
function Get-GuiErrorPath { Join-Path $OutDir 'gui_error.log' }

# 统一的错误出口：先落盘到 out/gui_error.log（含堆栈），再弹窗。
# 设了 DEMOANALYZER_HEADLESS=1 就只落盘不弹窗 —— 无人值守回归测试必须这样，
# 否则一个弹窗就会把测试进程永久卡住，而且会盖住真正的报错内容。
function Show-GuiError {
    param([string]$Context, $Detail)
    $msg = ''
    $stack = ''
    if ($Detail -is [System.Management.Automation.ErrorRecord]) {
        $msg = [string]$Detail.Exception.Message
        $stack = [string]$Detail.ScriptStackTrace
    }
    elseif ($Detail -is [System.Exception]) {
        $msg = [string]$Detail.Message
        $stack = [string]$Detail.StackTrace
    }
    else {
        $msg = [string]$Detail
    }
    if (-not $msg) { $msg = '(异常没有消息)' }
    try {
        $line = "[{0}] {1}`r`n  {2}`r`n  {3}`r`n" -f `
            (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Context, $msg, $stack
        Add-Content -LiteralPath (Get-GuiErrorPath) -Value $line -Encoding UTF8
    }
    catch { }
    if ($env:DEMOANALYZER_HEADLESS -eq '1') { return }
    [System.Windows.Forms.MessageBox]::Show($msg, $Context, 'OK', 'Error') | Out-Null
}

function Get-AnalysisArgs {
    param([string]$Demo, [string]$JsonOut, [string]$ProgFile)
    # 必须返回「单个已加引号的字符串」：Start-Process -ArgumentList 传数组时
    # 只用空格拼接、不加引号，含空格的路径（如 Counter-Strike Global Offensive）
    # 会被拆成多个参数，python 直接退出 1。
    return ('"{0}" "{1}" "{2}" "{3}"' -f $Analyzer, $Demo, $JsonOut, $ProgFile)
}

function Assert-AnalysisOk {
    param([string]$JsonOut, [string]$LogFile, [int]$Code)

    $errFile = "$JsonOut.error.txt"
    if ((Test-Path $errFile) -and -not (Test-Path $JsonOut)) {
        throw ("分析器异常:`r`n" + (Get-Content $errFile -Raw -Encoding UTF8))
    }
    if (-not (Test-Path $JsonOut)) {
        $tail = if (Test-Path $LogFile) { Get-Content $LogFile -Raw -Encoding UTF8 } else { '(无日志)' }
        throw ("没有生成报告文件。python 退出码=$Code`r`n" + $tail)
    }
}

function Start-AnalysisProcess {
    param([string]$Py, [string]$Demo, [string]$JsonOut, [string]$ProgFile, [string]$LogFile)

    $errFile = "$JsonOut.error.txt"
    if (Test-Path $JsonOut) { Remove-Item $JsonOut -Force }
    if (Test-Path $errFile) { Remove-Item $errFile -Force }
    if (Test-Path $ProgFile) { Remove-Item $ProgFile -Force }

    $argList = Get-AnalysisArgs -Demo $Demo -JsonOut $JsonOut -ProgFile $ProgFile

    # -WindowStyle Hidden 是关键：不创建可见控制台窗口。
    try {
        return (Start-Process -FilePath $Py -ArgumentList $argList `
                -WindowStyle Hidden -PassThru `
                -RedirectStandardOutput $LogFile -RedirectStandardError "$LogFile.err")
    }
    catch {
        return (Start-Process -FilePath $Py -ArgumentList $argList `
                -WindowStyle Hidden -PassThru)
    }
}

function Invoke-Analysis {
    param([string]$Py, [string]$Demo, [string]$JsonOut)

    $progFile = Get-ProgressPath
    $logFile = Get-LogPath
    $p = Start-AnalysisProcess -Py $Py -Demo $Demo -JsonOut $JsonOut `
        -ProgFile $progFile -LogFile $logFile
    $p.WaitForExit()

    Assert-AnalysisOk -JsonOut $JsonOut -LogFile $logFile -Code $p.ExitCode
}

# 读进度文件。文件可能正被写入，失败就跳过这一拍。
function Read-Progress {
    param([string]$ProgFile)
    if (-not (Test-Path $ProgFile)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText($ProgFile, [System.Text.Encoding]::UTF8)
        if (-not $raw.Trim()) { return $null }
        return ($raw | ConvertFrom-Json)
    }
    catch { return $null }
}

# ---------------- 读报告 ----------------
function Load-Report {
    param([string]$JsonPath)
    Add-Type -AssemblyName System.Web.Extensions
    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $ser.MaxJsonLength = [int]::MaxValue
    $raw = [System.IO.File]::ReadAllText($JsonPath, [System.Text.Encoding]::UTF8)
    return $ser.DeserializeObject($raw)
}

# ---------------- 三个页面的列定义 ----------------
# 第一页：只保留主要数据
$ColsMain = @(
    @{ H = '玩家';     K = 'name';           W = 158; A = 'L' },
    @{ H = 'Rating';   K = 'rating';         W = 62;  A = 'C'
        T = '近似 HLTV Rating 2.0。四项统计都等于基准值的球员正好是 1.00，越高越强。' },
    @{ H = '击杀';     K = 'kills';          W = 54;  A = 'C' },
    @{ H = '死亡';     K = 'deaths';         W = 54;  A = 'C' },
    @{ H = '助攻';     K = 'assists';        W = 54;  A = 'C' },
    @{ H = 'K/D';      K = 'kd';             W = 56;  A = 'C'
        T = '击杀 ÷ 死亡。' },
    @{ H = '爆头';     K = 'headshots';      W = 54;  A = 'C' },
    @{ H = '爆头率%';  K = 'hs_rate';        W = 70;  A = 'C'
        T = '爆头击杀 ÷ 总击杀。' },
    @{ H = '总伤害';   K = 'damage';         W = 70;  A = 'C'
        T = '只算打在敌人身上的伤害，不含队友伤害和自伤。' },
    @{ H = 'ADR';      K = 'adr';            W = 62;  A = 'C'
        T = '每回合平均伤害 = 总伤害 ÷ 参与回合。' },
    @{ H = '首杀';     K = 'opening_kills';  W = 54;  A = 'C'
        T = '每回合的第一个击杀。' },
    @{ H = '首死';     K = 'opening_deaths'; W = 54;  A = 'C'
        T = '每回合的第一个死亡。' },
    @{ H = '2K';       K = 'multi2';         W = 44;  A = 'C'
        T = '单回合杀 2 人及以上的回合数。' },
    @{ H = '3K';       K = 'multi3';         W = 44;  A = 'C'
        T = '单回合杀 3 人及以上的回合数。' },
    @{ H = '4K';       K = 'multi4';         W = 44;  A = 'C'
        T = '单回合杀 4 人及以上的回合数。' },
    @{ H = '5K';       K = 'multi5';         W = 44;  A = 'C'
        T = '单回合杀 5 人的回合数（团灭对面）。' }
)

# 第二页：道具伤害
$ColsUtil = @(
    @{ H = '玩家';       K = 'name';                W = 158; A = 'L' },
    @{ H = '手雷伤害';   K = 'he_damage';           W = 80;  A = 'C'
        T = 'HE 手雷造成的伤害。' },
    @{ H = '燃烧伤害';   K = 'fire_damage';         W = 80;  A = 'C'
        T = '燃烧瓶 / 燃烧弹（inferno、molotov、incendiarygrenade、firebomb）造成的伤害。' },
    @{ H = '诱饵伤害';   K = 'decoy_damage';        W = 80;  A = 'C'
        T = '诱饵弹造成的伤害。' },
    @{ H = '道具总伤';   K = 'utility_damage';      W = 80;  A = 'C'
        T = '手雷 + 燃烧 + 诱饵 三项之和。' },
    @{ H = '占比%';      K = 'utility_rate';        W = 62;  A = 'C'
        T = '道具总伤 ÷（对敌伤害 + 队友伤害）。也就是你打出的全部伤害里，有多少是道具造成的。' },
    @{ H = '每回合';     K = 'utility_per_round';   W = 70;  A = 'C'
        T = '道具总伤 ÷ 参与回合。' },
    @{ H = '手雷击杀';   K = 'he_kills';            W = 80;  A = 'C'
        T = '用 HE 手雷完成的击杀。' },
    @{ H = '燃烧击杀';   K = 'fire_kills';          W = 80;  A = 'C'
        T = '用燃烧瓶 / 燃烧弹完成的击杀。' },
    @{ H = '闪光助攻';   K = 'flash_assists';       W = 80;  A = 'C'
        T = '致盲助攻：被你闪到的敌人随后被队友击杀。' }
)

# 第三页：娱乐数据
$ColsFun = @(
    @{ H = '玩家';       K = 'name';            W = 158; A = 'L' },
    @{ H = '杀鸡';       K = 'chicken_kills';   W = 58;  A = 'C'
        T = '击杀小鸡的次数。' },
    @{ H = '刀杀';       K = 'knife_kills';     W = 58;  A = 'C'
        T = '用刀完成的击杀。' },
    @{ H = '电击枪杀';   K = 'zeus_kills';      W = 74;  A = 'C'
        T = '用电击枪（Zeus x27）完成的击杀。' },
    @{ H = '下包';       K = 'plants';          W = 58;  A = 'C'
        T = '成功安放 C4 的次数。' },
    @{ H = '拆包';       K = 'defuses';         W = 58;  A = 'C'
        T = '成功拆除 C4 的次数。' },
    @{ H = '团队击杀';   K = 'teamkills';       W = 74;  A = 'C'
        T = '击杀队友的次数（TK）。' },
    @{ H = '自杀';       K = 'suicides';        W = 58;  A = 'C'
        T = '自杀，或死于摔落 / 自己道具爆炸等世界伤害。' },
    @{ H = '团队伤害';   K = 'team_damage';     W = 74;  A = 'C'
        T = '打在队友身上的伤害合计（友军火力）。已经包含击杀队友的那一下，不会重复计算。' },
    @{ H = '参与回合';   K = 'rounds';          W = 74;  A = 'C'
        T = '该阶段实际参与的回合数，也是 ADR 的分母。' }
)

# ---------------- HLTV Major 模拟器数据 ----------------
# HLTV 有 Cloudflare 人机验证，Python / curl 直连一律 403（实测），
# 只有带真实浏览器指纹的请求才拿得到页面。所以这里不联网抓，
# 而是读一个已固化到本地的快照：data\hltv-major.json。
# 快照由 tools\fetch-hltv-sim.py 生成，重新抓一次就更新。
$HltvJson = Join-Path $Root 'data\hltv-major.json'

# Swiss 轮的场次分组名 -> 中文。
# 桶名是「已赢数 + 已输数」的英文，ZeroZero = 0 胜 0 负。
$SwissBnNames = @{
    ZeroZero = '0-0'; OneZero = '1-0'; ZeroOne = '0-1'; TwoZero = '2-0'
    OneOne = '1-1'; ZeroTwo = '0-2'; ThreeZero = '3-0'; TwoOne = '2-1'
    OneTwo = '1-2'; ZeroThree = '0-3'; ThreeOne = '3-1'; TwoTwo = '2-2'
    OneThree = '1-3'; ThreeTwo = '3-2'; TwoThree = '2-3'
}

function Load-Hltv {
    if (-not (Test-Path $HltvJson)) { return $null }
    try {
        return (Get-Content $HltvJson -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        return $null
    }
}

# ---------------- GUI ----------------
# 重要：所有跨回调共享的对象必须放在 $script: 作用域。
# 事件回调是在 Show-Gui 返回之后才触发的，函数局部变量那时已经不存在，
# 会退化成 $null 并抛 "在此对象上找不到属性"。
$script:App = @{
    Form         = $null
    Tabs         = $null
    Grids        = @{ main = @{}; util = @{}; fun = @{} }
    TeamLbls     = @{ main = @{}; util = @{}; fun = @{} }
    Cols         = @{ main = $ColsMain; util = $ColsUtil; fun = $ColsFun }
    Checks       = @{}
    Splits       = (New-Object System.Collections.ArrayList)
    PeriodInfo   = $null
    Period       = 'first'
    Status       = $null
    FileLbl      = $null
    BtnRun       = $null
    BtnPick      = $null
    BtnCsv       = $null
    Bar          = $null
    Py           = $null
    Report       = $null
    Demo         = ''
    TimelineFlow = $null
    TimelineLbl  = $null
    TimelineHost = $null
    TimelineTip  = $null
    DetailPanel  = $null
    DetailInfo   = $null
    DetailRows   = @()
    _suspendView = $false
    _tlDrag      = @{ pan=$false; startX=0; startScroll=0; moved=$false }
    _tlStartPan  = $null
    # 时间轴列的索引：回合号 -> 列控件。用来只改「选中」和「悬停」涉及的那两列，
    # 不用整条时间轴重建。
    TlColumns    = @{}
    SelectedRound = 0
    # 注意：这里只能存 RGB 分量，不能写 [System.Drawing.Color]::FromArgb(...)。
    # $script:App 是在脚本加载时构建的，那一刻 System.Drawing 还没 Add-Type，
    # 写类型名会直接抛「找不到类型 [System.Drawing.Color]」，软件根本起不来。
    # （headless 测试先 Add-Type 再载入源码，会把这个顺序问题掩盖掉。）
    TlSelRgb     = @(219, 234, 254)
    TlHoverRgb   = @(235, 242, 255)
}

# ---------------- 绘制性能 ----------------
# DoubleBuffered 是 Control 的 protected 属性，PowerShell 里点不出来，只能反射设。
# 不设的话每个控件都直接往屏幕上画，拖动分隔条 / 滚动 / 移动窗口时会闪成一片，
# 看起来就是「很卡」。DataGridView 尤其明显：它 resize 时会全量重绘所有单元格。
function Enable-DoubleBuffer {
    param($Control)
    if (-not $Control) { return }
    try {
        $pi = $Control.GetType().GetProperty('DoubleBuffered',
            [System.Reflection.BindingFlags]'NonPublic,Instance,Public')
        if ($pi -and $pi.CanWrite) { $pi.SetValue($Control, $true, $null) }
    } catch { }
}

# 改整列的背景色：列本身 + 两个「方块行」容器。
# 只改列是不够的 —— 方块行是白底 Panel，会把列的背景整个盖住，
# 高亮基本看不见（之前悬停高亮就是这个问题）。
# 轴线（Height=2）和方块本身不动：方块有自己的队色，轴线要接成连续的一条线。
function Set-TlColumnBg {
    param($Col, $Color)
    if (-not $Col) { return }
    try { $Col.BackColor = $Color } catch { }
    foreach ($c in $Col.Controls) {
        if ($c -is [System.Windows.Forms.Panel] -and $c.Height -ne 2) {
            try { $c.BackColor = $Color } catch { }
        }
    }
}

# 当前选中的回合要能看出来，否则点了卡片之后左边完全不知道选了哪一回合。
function Get-TlSelColor {
    $r = $script:App.TlSelRgb
    return [System.Drawing.Color]::FromArgb($r[0], $r[1], $r[2])
}
function Set-TlSelected {
    param([int]$Round, [bool]$On)
    $m = $script:App.TlColumns
    if (-not $m -or $Round -le 0 -or -not $m.ContainsKey($Round)) { return }
    $bg = if ($On) { Get-TlSelColor } else { [System.Drawing.Color]::White }
    Set-TlColumnBg -Col $m[$Round] -Color $bg
}

# 把一整棵控件树都开上双缓冲（Form 自己的 DoubleBuffered 管不到子控件）
function Enable-DoubleBufferTree {
    param($Control)
    if (-not $Control) { return }
    Enable-DoubleBuffer $Control
    foreach ($c in $Control.Controls) { Enable-DoubleBufferTree $c }
}

# ---------------- 圆角 UI 工具 ----------------
# 底色/描边用 RGB 分量存：脚本加载时还没 Add-Type，不能出现类型名。
$script:UiBgRgb = @(241, 243, 248)
$script:UiEdgeRgb = @(222, 226, 235)

function Get-UiBg { return [System.Drawing.Color]::FromArgb($script:UiBgRgb[0], $script:UiBgRgb[1], $script:UiBgRgb[2]) }
function Get-UiEdge { return [System.Drawing.Color]::FromArgb($script:UiEdgeRgb[0], $script:UiEdgeRgb[1], $script:UiEdgeRgb[2]) }

# 四角都圆的矩形路径
function Get-RoundPath {
    param([int]$W, [int]$H, [int]$R)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    if ($W -lt 2 -or $H -lt 2) { return $p }
    if ($R -lt 1) { $R = 1 }
    if (($R * 2) -gt $W) { $R = [int][math]::Floor($W / 2) }
    if (($R * 2) -gt $H) { $R = [int][math]::Floor($H / 2) }
    if ($R -lt 1) { $R = 1 }
    $d = $R * 2
    $p.AddArc(0, 0, $d, $d, 180, 90)
    $p.AddArc(($W - $d), 0, $d, $d, 270, 90)
    $p.AddArc(($W - $d), ($H - $d), $d, $d, 0, 90)
    $p.AddArc(0, ($H - $d), $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

# 只圆上面两个角（页签用）
function Get-RoundTopPath {
    param([int]$W, [int]$H, [int]$R)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    if ($W -lt 2 -or $H -lt 2) { return $p }
    if ($R -lt 1) { $R = 1 }
    if (($R * 2) -gt $W) { $R = [int][math]::Floor($W / 2) }
    if (($R * 2) -gt $H) { $R = [int][math]::Floor($H / 2) }
    if ($R -lt 1) { $R = 1 }
    $d = $R * 2
    $p.AddArc(0, 0, $d, $d, 180, 90)
    $p.AddArc(($W - $d), 0, $d, $d, 270, 90)
    $p.AddLine($W, $R, $W, $H)
    $p.AddLine($W, $H, 0, $H)
    $p.CloseFigure()
    return $p
}

# 给控件套圆角 Region。只动 Region，不改尺寸/坐标/Tag 里已有的东西。
function Set-RoundedRegion {
    param($Control, [int]$Radius = 10)
    if (-not $Control) { return }
    $w = [int]$Control.ClientSize.Width
    $h = [int]$Control.ClientSize.Height
    if ($w -lt 4 -or $h -lt 4) { return }
    $old = $Control.Region
    $np = $null
    try {
        $np = [System.Drawing.Region]::new((Get-RoundPath -W $w -H $h -R $Radius))
        $Control.Region = $np
    } catch {
        if ($np) { $np.Dispose() }
        return
    }
    if ($old) { $old.Dispose() }
}

# 圆角 + 尺寸变化时自动重算 Region（半径存在 Tag 上；回调里不能用函数局部变量）
function Enable-RoundRegion {
    param($Control, [int]$Radius = 12)
    if (-not $Control) { return }
    $Control.Tag = @{ r = $Radius }
    Set-RoundedRegion -Control $Control -Radius $Radius
    $Control.Add_Resize([System.EventHandler]{
            param($s, $e)
            $r = 12
            try { if ($s.Tag -and $s.Tag.r) { $r = [int]$s.Tag.r } } catch { }
            Set-RoundedRegion -Control $s -Radius $r
            $s.Invalidate()
        })
}

# 圆角卡片 = 圆角 Region + 1px 圆角描边（底色自己设）
function Enable-RoundCard {
    param($Control, [int]$Radius = 12)
    if (-not $Control) { return }
    Enable-RoundRegion -Control $Control -Radius $Radius
    $Control.Add_Paint({
            param($s, $e)
            $r = 12
            try { if ($s.Tag -and $s.Tag.r) { $r = [int]$s.Tag.r } } catch { }
            $w = [int]$s.ClientSize.Width
            $h = [int]$s.ClientSize.Height
            if ($w -lt 4 -or $h -lt 4) { return }
            $g = $e.Graphics
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $p = Get-RoundPath -W ($w - 1) -H ($h - 1) -R $r
            $pen = [System.Drawing.Pen]::new((Get-UiEdge), 1)
            try { $g.DrawPath($pen, $p) } finally { $pen.Dispose(); $p.Dispose() }
        })
}

# 圆角扁平按钮：底色/悬停色走 FlatAppearance，描边自己画；禁用时换成浅灰。
function New-RoundButton {
    param([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H,
        [int[]]$Back, [int[]]$Fore, [int[]]$Hover, [int[]]$Edge, [int]$Radius = 9)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = New-Object System.Drawing.Point($X, $Y)
    $b.Size = New-Object System.Drawing.Size($W, $H)
    $b.FlatStyle = 'Flat'
    $b.UseVisualStyleBackColor = $false
    $b.FlatAppearance.BorderSize = 0
    $b.Tag = @{
        back  = [System.Drawing.Color]::FromArgb($Back[0], $Back[1], $Back[2])
        hover = [System.Drawing.Color]::FromArgb($Hover[0], $Hover[1], $Hover[2])
        fore  = [System.Drawing.Color]::FromArgb($Fore[0], $Fore[1], $Fore[2])
        edge  = [System.Drawing.Color]::FromArgb($Edge[0], $Edge[1], $Edge[2])
        off   = [System.Drawing.Color]::FromArgb(229, 232, 239)
        edgeoff = [System.Drawing.Color]::FromArgb(211, 217, 230)
        r     = $Radius
    }
    $b.ForeColor = $b.Tag.fore
    $b.BackColor = $b.Tag.back
    $b.FlatAppearance.MouseOverBackColor = $b.Tag.hover
    $b.FlatAppearance.MouseDownBackColor = $b.Tag.hover
    $b.Add_EnabledChanged([System.EventHandler]{
            param($s, $e)
            $t = $s.Tag
            if (-not $t) { return }
            if ($s.Enabled) { $s.BackColor = $t.back } else { $s.BackColor = $t.off }
            $s.Invalidate()
        })
    $b.Add_Resize([System.EventHandler]{
            param($s, $e)
            $r = 9
            try { if ($s.Tag -and $s.Tag.r) { $r = [int]$s.Tag.r } } catch { }
            Set-RoundedRegion -Control $s -Radius $r
        })
    $b.Add_Paint({
            param($s, $e)
            $t = $s.Tag
            if (-not $t) { return }
            $w = [int]$s.ClientSize.Width
            $h = [int]$s.ClientSize.Height
            if ($w -lt 4 -or $h -lt 4) { return }
            $g = $e.Graphics
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $p = Get-RoundPath -W ($w - 1) -H ($h - 1) -R ([int]$t.r)
            $ec = if ($s.Enabled) { $t.edge } else { $t.edgeoff }
            $pen = [System.Drawing.Pen]::new($ec, 1)
            try { $g.DrawPath($pen, $p) } finally { $pen.Dispose(); $p.Dispose() }
        })
    Set-RoundedRegion -Control $b -Radius $Radius
    return $b
}

# ---------------- 左侧导航 ----------------
# 导航按钮自己画：选中态是浅蓝底 + 左侧 3px 蓝条，未选中是透明底，
# 悬停变浅灰。用 Panel + Paint，和项目里其他自绘控件保持同一套画法。
function New-NavButton {
    param([string]$Text, [int]$Y)
    $b = New-Object System.Windows.Forms.Panel
    $b.Location = New-Object System.Drawing.Point(8, $Y)
    $b.Size = New-Object System.Drawing.Size(160, 38)
    $b.BackColor = [System.Drawing.Color]::Transparent
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.Tag = @{ text = $Text; active = $false; hover = $false }
    $b.Add_Paint({
            param($s, $e)
            $t = $s.Tag
            $g = $e.Graphics
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $w = $s.Width; $h = $s.Height
            if ($t.active -or $t.hover) {
                $bg = if ($t.active) { [System.Drawing.Color]::FromArgb(238, 243, 254) }
                else { [System.Drawing.Color]::FromArgb(245, 247, 250) }
                $br = New-Object System.Drawing.SolidBrush($bg)
                try { $g.FillRectangle($br, 0, 0, $w, $h) } finally { $br.Dispose() }
            }
            if ($t.active) {
                $bar = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(37, 99, 235))
                try { $g.FillRectangle($bar, 0, 6, 3, $h - 12) } finally { $bar.Dispose() }
            }
            $fc = if ($t.active) { [System.Drawing.Color]::FromArgb(37, 99, 235) }
            else { [System.Drawing.Color]::FromArgb(55, 65, 81) }
            $font = if ($t.active) { New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold) }
            else { New-Object System.Drawing.Font('Microsoft YaHei UI', 10) }
            $tb = New-Object System.Drawing.SolidBrush($fc)
            try {
                $g.DrawString($t.text, $font, $tb, 16, [single](($h - $font.Height) / 2))
            } finally { $tb.Dispose(); $font.Dispose() }
        })
    $b.Add_MouseEnter({ param($s, $e) $s.Tag.hover = $true; $s.Invalidate() })
    $b.Add_MouseLeave({ param($s, $e) $s.Tag.hover = $false; $s.Invalidate() })
    return $b
}

# ---------------- Major Pick'em：Live 数据 + 交互式 Swiss ----------------
# 数据来源：HLTV 移动端 API（见 tools/hltv_mobile.py）。
# 网页版有 Cloudflare，普通 HTTP 客户端一律 403；但官方 Android 客户端的
# /mobile/ 接口只认移动端 UA，直接 GET 就返回 JSON，不需要 cookie 或代理。
$HltvLiveJson = Join-Path $Root 'data\major-live.json'

function Load-HltvLive {
    if (-not (Test-Path $HltvLiveJson)) { return $null }
    try { return (Get-Content $HltvLiveJson -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return $null }
}

# 旧快照（模拟器整页抓下来的）当兜底：Live 数据没有的时候还能显示赛程
$HltvJson = Join-Path $Root 'data\hltv-major.json'
function Load-Hltv {
    if (-not (Test-Path $HltvJson)) { return $null }
    try { return (Get-Content $HltvJson -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return $null }
}

# logo 缓存：Image.FromFile 只加载一次。别在 Paint 里反复 New，
# 那会持续泄漏 GDI 句柄，拖几十秒界面就卡死。
$script:LogoCache = @{}

function Clear-LogoCache {
    foreach ($k in @($script:LogoCache.Keys)) {
        try { if ($script:LogoCache[$k]) { $script:LogoCache[$k].Dispose() } } catch { }
    }
    $script:LogoCache = @{}
}

function Get-TeamLogo {
    param([string]$Name)
    if (-not $Name) { return $null }
    if ($script:LogoCache.ContainsKey($Name)) { return $script:LogoCache[$Name] }
    $img = $null
    try {
        $safe = ($Name -replace '[^\w\-]', '_')
        $p = Join-Path $Root ("assets\logos\$safe.png")
        if (Test-Path $p) {
            # 从字节流加载，避免锁住文件（Image.FromFile 会一直占着句柄）
            $bytes = [System.IO.File]::ReadAllBytes($p)
            $ms = New-Object System.IO.MemoryStream(,$bytes)
            $img = [System.Drawing.Image]::FromStream($ms)
        }
    } catch { $img = $null }
    $script:LogoCache[$Name] = $img
    return $img
}

# ---- Swiss 引擎 ----
# 完整的 Swiss 配对/推进逻辑放在 src/pickem.ps1，那里有对着 HLTV 真实赛果的回归测试
# （test-pickem.ps1，首轮与第二轮对阵 8/8 命中）。这里只负责 dot-source 进来。
. (Join-Path $Root "src\pickem.ps1")

# ---- 画布：HLTV 版式（深色底、Logo、点谁谁赢） ----
function New-PickemCanvas {
    param($St)

    $cv = New-Object System.Windows.Forms.Panel
    $cv.Dock = 'Fill'
    $cv.BackColor = [System.Drawing.Color]::FromArgb(18, 20, 26)
    $cv.Cursor = [System.Windows.Forms.Cursors]::Hand
    $cv.Margin = New-Object System.Windows.Forms.Padding(0)
    Enable-DoubleBuffer $cv

    $th = @{
        Bg      = [System.Drawing.Color]::FromArgb(18, 20, 26)
        Card    = [System.Drawing.Color]::FromArgb(28, 31, 38)
        CardWin = [System.Drawing.Color]::FromArgb(30, 58, 44)
        CardHov = [System.Drawing.Color]::FromArgb(38, 43, 54)
        Edge    = [System.Drawing.Color]::FromArgb(48, 53, 62)
        EdgeWin = [System.Drawing.Color]::FromArgb(72, 187, 120)
        Txt     = [System.Drawing.Color]::FromArgb(235, 238, 243)
        Dim     = [System.Drawing.Color]::FromArgb(118, 126, 138)
        Accent  = [System.Drawing.Color]::FromArgb(96, 165, 250)
        Win     = [System.Drawing.Color]::FromArgb(72, 187, 120)
        Lose    = [System.Drawing.Color]::FromArgb(220, 100, 100)
        GroupBg = [System.Drawing.Color]::FromArgb(24, 26, 33)
        FontNm  = (New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5))
        FontNmB = (New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5, [System.Drawing.FontStyle]::Bold))
        FontHd  = (New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5, [System.Drawing.FontStyle]::Bold))
        FontSm  = (New-Object System.Drawing.Font('Microsoft YaHei UI', 8))
        FontVs  = (New-Object System.Drawing.Font('Segoe UI', 7.5, [System.Drawing.FontStyle]::Bold))
    }

    $CW = 218; $ROW = 37; $CH = 97; $GAP = 7
    $HEAD = 20; $GGAP = 14; $COLW = 250; $PADX = 22; $PADY = 34

    $cv.Tag = @{
        St = $St; Th = $th
        Pan = @{ X = 0; Y = 0 }
        Drag = @{ On = $false; X = 0; Y = 0; Moved = $false }
        Hover = $null
        Cards = (New-Object System.Collections.ArrayList)
        Groups = $null
        ByCol = $null
        CW = $CW; ROW = $ROW; CH = $CH; GAP = $GAP
        HEAD = $HEAD; GGAP = $GGAP; COLW = $COLW; PADX = $PADX; PADY = $PADY
    }

    # 布局计算
    $cv.Tag.ReLayout = {
        param($self)
        $t = $self.Tag
        $groups = Get-SwissGroups -Stage $t.St
        $byCol = @{}
        foreach ($k in @($groups.Keys)) {
            $g = $groups[$k]
            $col = [int]$g.W + [int]$g.L
            if (-not $byCol.ContainsKey($col)) { $byCol[$col] = (New-Object System.Collections.ArrayList) }
            [void]$byCol[$col].Add($g)
        }
        $maxY = 0
        foreach ($col in @($byCol.Keys)) {
            $y = $t.PADY
            $list = @($byCol[$col]) | Sort-Object @{ Expression = { - [int]$_.W } }
            foreach ($g in $list) {
                $g.Y = $y
                $n = @($g.Items).Count
                $g.BoxH = [Math]::Max(1, $n) * ($t.CH + $t.GAP) - $t.GAP
                $y = $y + $t.HEAD + $g.BoxH + $t.GGAP
            }
            if ($y -gt $maxY) { $maxY = $y }
        }
        $cards = (New-Object System.Collections.ArrayList)
        foreach ($col in @($byCol.Keys)) {
            foreach ($g in @($byCol[$col])) {
                $x = $t.PADX + ([int]$col) * $t.COLW
                $yy = $g.Y + $t.HEAD
                $i = 0
                foreach ($mt in @($g.Items)) {
                    [void]$cards.Add(@{ Match = $mt; X = $x; Y = $yy + $i * ($t.CH + $t.GAP)
                            W = [int]$t.CW; H = [int]$t.CH; Wa = [int]$g.W; La = [int]$g.L })
                    $i++
                }
            }
        }
        $t.Cards = $cards
        $t.Groups = $groups
        $t.ByCol = $byCol
        $t.TotalH = $maxY + $t.PADY
    }
    & $cv.Tag.ReLayout $cv

    $cv.Add_Paint({
            param($s, $e)
            $t = $s.Tag
            $th = $t.Th
            $g = $e.Graphics
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
            $g.Clear($th.Bg)
            $px = $t.Pan.X; $py = $t.Pan.Y

            # 列标题
            $hb = New-Object System.Drawing.SolidBrush($th.Dim)
            try {
                foreach ($ci in (@($t.ByCol.Keys) | Sort-Object)) {
                    $x = $t.PADX + ([int]$ci) * $t.COLW + $px
                    $cap = if ([int]$ci -eq 0) { '第一轮' } elseif ([int]$ci -ge 4) { '出线 / 淘汰' } else { '第{0}轮' -f ([int]$ci + 1) }
                    $g.DrawString($cap, $th.FontHd, $hb, [single]$x, [single]([int]$py + 8))
                }
            } finally { $hb.Dispose() }

            # 组底板
            foreach ($k in @($t.Groups.Keys)) {
                $grp = $t.Groups[$k]
                $col = [int]$grp.W + [int]$grp.L
                $x = $t.PADX + $col * $t.COLW + $px
                $y = $grp.Y + $py
                $bg = New-Object System.Drawing.SolidBrush($th.GroupBg)
                try {
                    $rr = New-Object System.Drawing.Rectangle([int]$x, [int]($y - 4), [int]$t.CW, [int]($grp.BoxH + 8))
                    $g.FillRectangle($bg, $rr)
                } finally { $bg.Dispose() }
                $ab = New-Object System.Drawing.SolidBrush($th.Accent)
                try { $g.DrawString(('{0}-{1}' -f $grp.W, $grp.L), $th.FontSm, $ab, [single]($x + 7), [single]($y + 4)) } finally { $ab.Dispose() }
            }

            # 卡片
            $idx = 0
            foreach ($cd in $t.Cards) {
                $x = $cd.X + $px
                $y = $cd.Y + $py
                $cw = [int]$cd.W; $chh = [int]$cd.H; $rowH = [int]$t.ROW
                if ($x -gt ($s.Width + 300) -or ($x + $cw) -lt -300) { $idx++; continue }

                $mt = $cd.Match
                $hovA = ($t.Hover -and $t.Hover.Card -eq $idx -and $t.Hover.Side -eq 'A')
                $hovB = ($t.Hover -and $t.Hover.Card -eq $idx -and $t.Hover.Side -eq 'B')
                $wonA = ($mt.Winner -eq 'A'); $wonB = ($mt.Winner -eq 'B')
                $isDone = [bool]$mt.Winner

                $gs = $g.Save()
                $g.TranslateTransform([single]$x, [single]$y)
                try {
                    $path = Get-RoundPath -W $cw -H $chh -R 9
                    $fill = New-Object System.Drawing.SolidBrush($th.Card)
                    $pen = New-Object System.Drawing.Pen($(if ($isDone) { $th.EdgeWin } else { $th.Edge }), 1)
                    try { $g.FillPath($fill, $path); $g.DrawPath($pen, $path) }
                    finally { $fill.Dispose(); $pen.Dispose(); $path.Dispose() }

                    $si = 0
                    foreach ($side in @('A', 'B')) {
                        $nm = if ($side -eq 'A') { [string]$mt.A } else { [string]$mt.B }
                        $ry = 6 + $si * $rowH
                        $isHov = if ($side -eq 'A') { $hovA } else { $hovB }
                        $isWin = if ($side -eq 'A') { $wonA } else { $wonB }
                        $isLos = ($isDone -and -not $isWin)

                        if ($isWin -or $isHov) {
                            $hb2 = New-Object System.Drawing.SolidBrush($(if ($isWin) { $th.CardWin } else { $th.CardHov }))
                            $hp = Get-RoundPath -W ($cw - 8) -H ($rowH - 2) -R 6
                            $g2 = $g.Save()
                            $g.TranslateTransform(4, [single]($ry - 1))
                            try { $g.FillPath($hb2, $hp) } finally { $g.Restore($g2); $hb2.Dispose(); $hp.Dispose() }
                        }

                        $logo = Get-TeamLogo -Name $nm
                        $lx = 9; $ly = $ry + 4; $ls = 26
                        if ($logo) { $g.DrawImage($logo, (New-Object System.Drawing.Rectangle($lx, $ly, $ls, $ls))) }
                        else {
                            $ph = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(42, 47, 58))
                            try { $g.FillEllipse($ph, $lx, $ly, $ls, $ls) } finally { $ph.Dispose() }
                        }

                        $fc = if ($isLos) { $th.Dim } else { $th.Txt }
                        $fb = New-Object System.Drawing.SolidBrush($fc)
                        $fnt = if ($isWin) { $th.FontNmB } else { $th.FontNm }
                        try {
                            $short = $nm
                            if ($short.Length -gt 15) { $short = $short.Substring(0, 14) + '..' }
                            $g.DrawString($short, $fnt, $fb, [single]($lx + $ls + 7), [single]($ly + 5))
                        } finally { $fb.Dispose() }

                        if ($isWin) {
                            $wb = New-Object System.Drawing.SolidBrush($th.Win)
                            try { $g.DrawString('W', $th.FontVs, $wb, [single]($cw - 19), [single]($ry + 12)) } finally { $wb.Dispose() }
                        } elseif ($isLos) {
                            $lb = New-Object System.Drawing.SolidBrush($th.Lose)
                            try { $g.DrawString('L', $th.FontVs, $lb, [single]($cw - 19), [single]($ry + 12)) } finally { $lb.Dispose() }
                        }

                        if ($side -eq 'A') {
                            $sep = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(58, 64, 76), 1)
                            try { $g.DrawLine($sep, 9, ($rowH + 4), ($cw - 9), ($rowH + 4)) } finally { $sep.Dispose() }
                        }
                        $si++
                    }

                    # 底部：BO 标记 / 比分
                    $ft = New-Object System.Drawing.SolidBrush($th.Dim)
                    try {
                        $boTxt = if ([int]$mt.Bo -ge 3) { 'BO3' } else { 'BO1' }
                        $boCol = if ([int]$mt.Bo -ge 3) { [System.Drawing.Color]::FromArgb(214, 160, 74) } else { $th.Dim }
                        $ft2 = New-Object System.Drawing.SolidBrush($boCol)
                        try { $g.DrawString($boTxt, $th.FontSm, $ft2, [single]($cw - 34), [single]($chh - 14)) } finally { $ft2.Dispose() }
                    } finally { $ft.Dispose() }
                } finally { $g.Restore($gs) }
                $idx++
            }
        })

    $cv.Tag.HitTest = {
        param($self, $mx, $my)
        $t = $self.Tag
        $i = 0
        foreach ($cd in $t.Cards) {
            $x = $cd.X + $t.Pan.X; $y = $cd.Y + $t.Pan.Y
            if ($mx -ge $x -and $mx -le ($x + [int]$cd.W) -and $my -ge $y -and $my -le ($y + [int]$cd.H)) {
                $rel = $my - $y
                $side = if ($rel -lt (6 + [int]$t.ROW)) { 'A' } else { 'B' }
                return @{ Card = $i; Side = $side }
            }
            $i++
        }
        return $null
    }

    $cv.Add_MouseDown({ param($s, $e) $s.Tag.Drag.On = $true; $s.Tag.Drag.X = $e.X; $s.Tag.Drag.Y = $e.Y; $s.Tag.Drag.Moved = $false })
    $cv.Add_MouseUp({
            param($s, $e)
            $t = $s.Tag
            $was = $t.Drag.Moved
            $t.Drag.On = $false
            if ($was) { return }
            $hit = & $t.HitTest $s $e.X $e.Y
            if (-not $hit) { return }
            $cd = $t.Cards[$hit.Card]
            if ($cd.Match.Winner) { return }
            if (Set-SwissWinner -Stage $t.St -Match $cd.Match -Side $hit.Side) {
                Update-SwissStage -Stage $t.St | Out-Null
                & $t.ReLayout $s
                $s.Invalidate()
                if ($t.OnChanged) { & $t.OnChanged }
            }
        })
    $cv.Add_MouseMove({
            param($s, $e)
            $t = $s.Tag
            if ($t.Drag.On) {
                $dx = $e.X - $t.Drag.X; $dy = $e.Y - $t.Drag.Y
                if ([Math]::Abs($dx) -gt 2 -or [Math]::Abs($dy) -gt 2) { $t.Drag.Moved = $true }
                $t.Pan.X += $dx; $t.Pan.Y += $dy
                $t.Drag.X = $e.X; $t.Drag.Y = $e.Y
                $s.Invalidate()
            } else {
                $hit = & $t.HitTest $s $e.X $e.Y
                $old = $t.Hover
                $chg = $false
                if (-not $hit -and $old) { $chg = $true }
                elseif ($hit -and (-not $old -or $old.Card -ne $hit.Card -or $old.Side -ne $hit.Side)) { $chg = $true }
                $t.Hover = $hit
                if ($chg) { $s.Invalidate() }
                $s.Cursor = if ($hit) { [System.Windows.Forms.Cursors]::Hand } else { [System.Windows.Forms.Cursors]::SizeAll }
            }
        })
    $cv.Add_MouseWheel({ param($s, $e) $s.Tag.Pan.Y += [int]($e.Delta / 3); $s.Invalidate() })
    $cv.Add_Resize({ param($s, $e) $s.Invalidate() })

    return $cv
}


# ---- 页面 ----
# ---- Pick'em 页面：四个阶段页签（Stage 1/2/3 + Playoffs）----
function New-PickemPage {
    $page = New-Object System.Windows.Forms.Panel
    $page.Dock = 'Fill'
    $page.BackColor = [System.Drawing.Color]::FromArgb(18, 20, 26)
    $page.Visible = $false
    $page.Margin = New-Object System.Windows.Forms.Padding(0)

    $lay = New-Object System.Windows.Forms.TableLayoutPanel
    $lay.Dock = 'Fill'
    $lay.ColumnCount = 1
    $lay.RowCount = 3
    $lay.BackColor = [System.Drawing.Color]::FromArgb(18, 20, 26)
    $lay.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100))) | Out-Null
    $lay.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 58))) | Out-Null
    $lay.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100))) | Out-Null
    $lay.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 32))) | Out-Null
    $page.Controls.Add($lay)

    $head = New-Object System.Windows.Forms.Panel
    $head.Dock = 'Fill'
    $head.BackColor = [System.Drawing.Color]::FromArgb(24, 26, 33)
    $head.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 4)
    $lay.Controls.Add($head, 0, 0)

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Location = New-Object System.Drawing.Point(16, 6)
    $lblTitle.Size = New-Object System.Drawing.Size(700, 24)
    $lblTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 12, [System.Drawing.FontStyle]::Bold)
    $lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(240, 243, 248)
    $lblTitle.Text = 'Major Pick''em'
    $head.Controls.Add($lblTitle)

    $lblSub = New-Object System.Windows.Forms.Label
    $lblSub.Location = New-Object System.Drawing.Point(18, 31)
    $lblSub.Size = New-Object System.Drawing.Size(1000, 18)
    $lblSub.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
    $lblSub.ForeColor = [System.Drawing.Color]::FromArgb(130, 138, 150)
    $lblSub.Text = '正在读取…'
    $head.Controls.Add($lblSub)

    $btnReset = New-Object System.Windows.Forms.Button
    $btnReset.Text = '重置'
    $btnReset.Size = New-Object System.Drawing.Size(70, 26)
    $btnReset.Location = New-Object System.Drawing.Point(1120, 14)
    $btnReset.FlatStyle = 'Flat'
    $btnReset.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(62, 68, 80)
    $btnReset.BackColor = [System.Drawing.Color]::FromArgb(32, 36, 44)
    $btnReset.ForeColor = [System.Drawing.Color]::FromArgb(212, 218, 228)
    $btnReset.Anchor = 'Top,Right'
    $btnReset.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $head.Controls.Add($btnReset)

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = 'Fill'
    $tabs.ItemSize = New-Object System.Drawing.Size(126, 30)
    $tabs.SizeMode = 'Fixed'
    $tabs.Margin = New-Object System.Windows.Forms.Padding(0)
    $tabs.Padding = New-Object System.Drawing.Point(14, 5)
    $tabs.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
    $lay.Controls.Add($tabs, 0, 1)

    $foot = New-Object System.Windows.Forms.Panel
    $foot.Dock = 'Fill'
    $foot.BackColor = [System.Drawing.Color]::FromArgb(24, 26, 33)
    $lay.Controls.Add($foot, 0, 2)

    $lblFoot = New-Object System.Windows.Forms.Label
    $lblFoot.Dock = 'Fill'
    $lblFoot.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
    $lblFoot.ForeColor = [System.Drawing.Color]::FromArgb(150, 158, 170)
    $lblFoot.TextAlign = 'MiddleLeft'
    $lblFoot.Padding = New-Object System.Windows.Forms.Padding(14, 0, 0, 0)
    $lblFoot.Text = ''
    $foot.Controls.Add($lblFoot)

    $page.Tag = @{
        Stages   = (New-Object System.Collections.ArrayList)
        Tabs     = $tabs
        Sub      = $lblSub
        Foot     = $lblFoot
        Title    = $lblTitle
        ResetBtn = $btnReset
        Data     = $null
    }

    $btnReset.Add_Click({
            $p = $script:App.Nav.Pages['hltv']
            if ($p) { Render-PickemPage -Page $p }
        })

    return $page
}


# 渲染整个 Pick'em 页：建 Stage 1/2/3 + Playoffs 四个页签
function Render-PickemPage {
    param($Page)
    if (-not $Page) { return }
    $t = $Page.Tag

    $data = $null
    $allPath = Join-Path $Root 'data\all-stages.json'
    if (Test-Path $allPath) {
        try { $data = Get-Content $allPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    if (-not $data) {
        $t.Sub.Text = '没有 data\all-stages.json'
        return
    }

    $t.Data = $data
    $t.Title.Text = ('Major Pick''em — ' + $data.event)
    $t.Tabs.TabPages.Clear()
    [void]$t.Stages.Clear()

    for ($i = 0; $i -lt 3; $i++) {
        $sd = $data.stages[$i]
        $teams = @()
        foreach ($tm in @($sd.teams)) {
            $teams += @{ name = $tm.name; teamId = $tm.teamId; logo = $tm.logo; seed = $tm.seed }
        }
        $st = New-SwissStage -Name $sd.name -Teams $teams
        Add-SwissRound -Stage $st
        [void]$t.Stages.Add($st)

        $tp = New-Object System.Windows.Forms.TabPage
        $tp.Text = $sd.name
        $tp.BackColor = [System.Drawing.Color]::FromArgb(18, 20, 26)
        $tp.Padding = New-Object System.Windows.Forms.Padding(0)
        $t.Tabs.TabPages.Add($tp)
    }

    $poTp = New-Object System.Windows.Forms.TabPage
    $poTp.Text = 'Playoffs'
    $poTp.BackColor = [System.Drawing.Color]::FromArgb(18, 20, 26)
    $poTp.Padding = New-Object System.Windows.Forms.Padding(0)
    $t.Tabs.TabPages.Add($poTp)

    $live = $null
    $livePath = Join-Path $Root 'data\major-live.json'
    if (Test-Path $livePath) {
        try { $live = Get-Content $livePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    if ($live) { Apply-RealResults -Stage $t.Stages[0] -Live $live }

    Build-PickemTabs -Page $Page
}

function Apply-RealResults {
    param($Stage, $Live)
    if (-not $Live) { return }
    $byPair = @{}
    foreach ($m in @($Live.matches | Where-Object { $_.finished -and $_.winnerId })) {
        $k = ((@($m.a, $m.b) | Sort-Object { $_.ToLowerInvariant() }) -join '|').ToLower()
        $byPair[$k] = $m
    }
    for ($guard = 0; $guard -lt 6; $guard++) {
        $pending = @($Stage.Matches | Where-Object { -not $_.Winner })
        foreach ($mt in $pending) {
            $k = ((@($mt.A, $mt.B) | Sort-Object { $_.ToLowerInvariant() }) -join '|').ToLower()
            if ($byPair.ContainsKey($k)) {
                $rm = $byPair[$k]
                $winName = if ([string]$rm.aId -eq [string]$rm.winnerId) { $rm.a } else { $rm.b }
                $side = if ($mt.A -eq $winName) { 'A' } else { 'B' }
                Set-SwissWinner -Stage $Stage -Match $mt -Side $side | Out-Null
            }
        }
        if (-not (Update-SwissStage -Stage $Stage)) { break }
    }
}

function Build-PickemTabs {
    param($Page)
    $t = $Page.Tag
    for ($i = 0; $i -lt 3; $i++) {
        $tp = $t.Tabs.TabPages[$i]
        $tp.Controls.Clear()
        $cv = New-PickemCanvas -St $t.Stages[$i]
        $cv.Tag.StageIndex = $i
        $pageRef = $Page
        $cv.Tag.OnChanged = { param($s) Update-PickemChain -Page $pageRef }.GetNewClosure()
        $tp.Controls.Add($cv)
    }
    Update-PickemChain -Page $Page
}

function Update-PickemChain {
    param($Page)
    $t = $Page.Tag
    $parts = @()
    foreach ($st in $t.Stages) {
        $alive = @($st.TeamList | Where-Object { $_.Status -eq 'alive' }).Count
        $q = @($st.Qualified).Count
        $e = @($st.Eliminated).Count
        $parts += ('{0}: 晋级 {1} · 淘汰 {2} · 进行中 {3}' -f $st.Name, $q, $e, $alive)
    }
    $t.Foot.Text = ($parts -join '　｜　')

    foreach ($tp in @($t.Tabs.TabPages)) {
        foreach ($c in @($tp.Controls)) {
            if ($c.Tag -and $c.Tag.ReLayout) { & $c.Tag.ReLayout $c; $c.Invalidate() }
        }
    }

    # Playoffs 页：8 强名单随 Stage 3 的进度变化，每次都要重建这张树
    if ($t.Tabs.TabPages.Count -ge 4) {
        $poTp = $t.Tabs.TabPages[3]
        $needNew = ($poTp.Controls.Count -eq 0)
        if ($needNew) {
            $po = New-PlayoffCanvas -Stage1 $t.Stages[0] -Stage2 $t.Stages[1] -Stage3 $t.Stages[2]
            $poTp.Controls.Add($po)
        } else {
            # 已有画布：只更新名单并重画，避免每次重排把用户拖动位置清掉
            $po = $poTp.Controls[0]
            if ($po.Tag) {
                $eight = @(Get-SwissQualified -Stage $t.Stages[2])
                if ($eight.Count -lt 8) {
                    foreach ($x in @(Get-SwissQualified -Stage $t.Stages[1])) {
                        if ($eight.Count -ge 8) { break }
                        if (-not (@($eight | ForEach-Object { $_.Name }) -contains $x.Name)) { $eight += $x }
                    }
                }
                $po.Tag.Eight = $eight
                $po.Invalidate()
            }
        }
    }
}


# ---- 淘汰赛树状图 ----
# 8 队单败：QF 4 场 / SF 2 场 / F 1 场。
# 种子按 Valve 规则配：1v8 / 4v5 / 2v7 / 3v6（这四个组合在 HLTV 的
# placement.quarterfinals 里是写死的，已验证）。
function New-PlayoffCanvas {
    param($Stage1, $Stage2, $Stage3)

    $cv = New-Object System.Windows.Forms.Panel
    $cv.Dock = 'Fill'
    $cv.BackColor = [System.Drawing.Color]::FromArgb(18, 20, 26)
    $cv.Margin = New-Object System.Windows.Forms.Padding(0)
    $cv.Cursor = [System.Windows.Forms.Cursors]::Hand
    Enable-DoubleBuffer $cv

    $th = @{
        Bg    = [System.Drawing.Color]::FromArgb(18, 20, 26)
        Card  = [System.Drawing.Color]::FromArgb(28, 31, 38)
        Edge  = [System.Drawing.Color]::FromArgb(48, 53, 62)
        Txt   = [System.Drawing.Color]::FromArgb(235, 238, 243)
        Dim   = [System.Drawing.Color]::FromArgb(120, 128, 140)
        Accent= [System.Drawing.Color]::FromArgb(96, 165, 250)
        Line  = [System.Drawing.Color]::FromArgb(56, 62, 74)
        FontNm = (New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5))
        FontHd = (New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5, [System.Drawing.FontStyle]::Bold))
        FontSm = (New-Object System.Drawing.Font('Microsoft YaHei UI', 8))
    }

    $cv.Tag = @{
        Th = $th
        S1 = $Stage1; S2 = $Stage2; S3 = $Stage3
        Pan = @{ X = 0; Y = 0 }
        Drag = @{ On = $false; X = 0; Y = 0 }
        Slots = (New-Object System.Collections.ArrayList)
    }

    # 组出 8 强名单：优先用 Stage 3 的晋级者；不够就按 Stage 1/2 补
    $eight = @()
    if ($Stage3) { $eight = @(Get-SwissQualified -Stage $Stage3) }
    if ($eight.Count -lt 8 -and $Stage2) {
        foreach ($t in @(Get-SwissQualified -Stage $Stage2)) {
            if ($eight.Count -ge 8) { break }
            if (-not (@($eight | ForEach-Object { $_.Name }) -contains $t.Name)) { $eight += $t }
        }
    }
    $cv.Tag.Eight = $eight

    $cv.Add_Paint({
            param($s, $e)
            $t = $s.Tag
            $th = $t.Th
            $g = $e.Graphics
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
            $g.Clear($th.Bg)
            $px = $t.Pan.X; $py = $t.Pan.Y

            $CW = 214; $CH = 62; $COLW = 286; $PADX = 24; $PADY = 52

            $names = @('八强 (QF)', '四强 (SF)', '决赛 (Final)')
            $hb = New-Object System.Drawing.SolidBrush($th.Accent)
            try {
                for ($c = 0; $c -lt 3; $c++) {
                    $g.DrawString($names[$c], $th.FontHd, $hb, [single]($PADX + $c * $COLW + $px), [single](12 + $py))
                }
            } finally { $hb.Dispose() }

            # 槽位坐标：QF 4 个均分，SF 2 个取中点，F 1 个居中
            $boxes = @{}
            for ($c = 0; $c -lt 3; $c++) {
                $n = if ($c -eq 0) { 4 } elseif ($c -eq 1) { 2 } else { 1 }
                $gap = if ($c -eq 0) { 108 } elseif ($c -eq 1) { 216 } else { 0 }
                $startY = $PADY
                if ($c -eq 1) { $startY = $PADY + 54 }
                if ($c -eq 2) { $startY = $PADY + 162 }
                for ($i = 0; $i -lt $n; $i++) {
                    $boxes["$c-$i"] = @{
                        X = $PADX + $c * $COLW + $px
                        Y = $startY + $i * $gap + $py
                    }
                }
            }

            # 连线
            $pen = New-Object System.Drawing.Pen($th.Line, 1.3)
            try {
                for ($c = 0; $c -lt 2; $c++) {
                    $n = if ($c -eq 0) { 4 } else { 2 }
                    for ($i = 0; $i -lt $n; $i++) {
                        $src = $boxes["$c-$i"]
                        $dst = $boxes["$($c+1)-$([int]($i / 2))"]
                        if (-not $src -or -not $dst) { continue }
                        $g.DrawLine($pen, $src.X + $CW, $src.Y + $CH / 2, $dst.X, $dst.Y + $CH / 2)
                    }
                }
            } finally { $pen.Dispose() }

            # 卡片
            for ($c = 0; $c -lt 3; $c++) {
                $n = if ($c -eq 0) { 4 } elseif ($c -eq 1) { 2 } else { 1 }
                for ($i = 0; $i -lt $n; $i++) {
                    $bx = $boxes["$c-$i"]
                    $x = $bx.X; $y = $bx.Y

                    $path = Get-RoundPath -W $CW -H $CH -R 9
                    $fill = New-Object System.Drawing.SolidBrush($th.Card)
                    $pen2 = New-Object System.Drawing.Pen($th.Edge, 1)
                    $gs = $g.Save()
                    $g.TranslateTransform([single]$x, [single]$y)
                    try { $g.FillPath($fill, $path); $g.DrawPath($pen2, $path) }
                    finally { $g.Restore($gs); $fill.Dispose(); $pen2.Dispose(); $path.Dispose() }

                    # 八强：按种子规则填真实队名
                    $n1 = 'TBD'; $n2 = 'TBD'
                    if ($c -eq 0 -and $t.Eight.Count -ge 8) {
                        # 1v8 / 4v5 / 2v7 / 3v6
                        $pairs = @(@(0, 7), @(3, 4), @(1, 6), @(2, 5))
                        $pi = $pairs[$i]
                        $n1 = $t.Eight[$pi[0]].Name
                        $n2 = $t.Eight[$pi[1]].Name
                    }

                    $tb = New-Object System.Drawing.SolidBrush($th.Txt)
                    $db = New-Object System.Drawing.SolidBrush($th.Dim)
                    try {
                        $g.DrawString($n1, $th.FontNm, $tb, [single]($x + 10), [single]($y + 8))
                        $g.DrawString($n2, $th.FontNm, $tb, [single]($x + 10), [single]($y + 32))
                        if ($c -eq 0) {
                            $g.DrawString(('QF{0}' -f ($i + 1)), $th.FontSm, $db, [single]($x + $CW - 40), [single]($y + $CH - 16))
                        }
                    } finally { $tb.Dispose(); $db.Dispose() }
                }
            }
        })

    $cv.Add_MouseDown({ param($s, $e) $s.Tag.Drag.On = $true; $s.Tag.Drag.X = $e.X; $s.Tag.Drag.Y = $e.Y })
    $cv.Add_MouseMove({
            param($s, $e)
            if ($s.Tag.Drag.On) {
                $s.Tag.Pan.X += ($e.X - $s.Tag.Drag.X)
                $s.Tag.Pan.Y += ($e.Y - $s.Tag.Drag.Y)
                $s.Tag.Drag.X = $e.X; $s.Tag.Drag.Y = $e.Y
                $s.Invalidate()
            }
        })
    $cv.Add_MouseUp({ param($s, $e) $s.Tag.Drag.On = $false })
    $cv.Add_Resize({ param($s, $e) $s.Invalidate() })

    return $cv
}

# ---- 关于页 ----
function New-AboutPage {
    $page = New-Object System.Windows.Forms.Panel
    $page.Dock = 'Fill'
    $page.BackColor = (Get-UiBg)
    $page.Visible = $false

    $card = New-Object System.Windows.Forms.Panel
    $card.Dock = 'Fill'
    $card.BackColor = [System.Drawing.Color]::White
    $card.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
    Enable-RoundCard -Control $card -Radius 12
    $page.Controls.Add($card)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Multiline = $true
    $txt.ReadOnly = $true
    $txt.BorderStyle = 'None'
    $txt.ScrollBars = 'Vertical'
    $txt.WordWrap = $false
    $txt.Dock = 'Fill'
    $txt.BackColor = [System.Drawing.Color]::White
    $txt.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
    $txt.ForeColor = [System.Drawing.Color]::FromArgb(55, 65, 81)
    $txt.Margin = New-Object System.Windows.Forms.Padding(18, 18, 18, 18)

    $lines = @(
        'CS2 工具',
        '',
        '一个本地运行的 CS2 小工具集合。',
        '',
        'Demo 统计',
        '  导入 CS2 / CS:GO 的 .dem 录像，按半场分段、按队伍分栏统计每个玩家的表现。',
        '  需要 Python 3.10+ 并安装 demoparser2 与 pandas。',
        '',
        'Major Pick''em',
        '  读取 HLTV Major 的实时比赛数据，按 Valve Swiss 规则排对阵：',
        '    首轮按种子对折（1 号打 9 号，2 号打 10 号 …）',
        '    之后按战绩分组，赢一场进「胜场+1」的组，输一场进「负场+1」的组',
        '    先到 3 胜直接晋级，先到 3 负直接淘汰',
        '    2 胜或 2 负的组打 BO3，其余 BO1',
        '  点某一队就是判它赢，对阵会自动推进到下一轮。整张图可以拖动。',
        '',
        '数据来源',
        '  HLTV 移动端 API（https://www.hltv.org/mobile/）。',
        '  网页版有 Cloudflare 人机验证，普通 HTTP 客户端一律 403；',
        '  官方 Android 客户端走的 /mobile/ 接口只认移动端 UA，可以直接取 JSON。',
        '  刷新数据：python tools\hltv_mobile.py --event 9303',
        '',
        '关于',
        '  界面：PowerShell 5.1 + WinForms，自绘圆角卡片、进度条与对阵图。',
        '  分析核心：src\analyzer.py，demoparser2 后端。'
    )
    $txt.Text = ($lines -join [Environment]::NewLine)
    $card.Controls.Add($txt)
    return $page
}

# 切页：只切可见性和高亮。页面停在内存里，切回去状态都还在。
function Show-Page {
    param([string]$Key)
    $nav = $script:App.Nav
    if (-not $nav) { return }
    if (-not $nav.Pages.ContainsKey($Key)) { return }
    foreach ($k in $nav.Pages.Keys) {
        $nav.Pages[$k].Visible = ($k -eq $Key)
    }
    foreach ($item in $nav.Items) {
        $isCur = ($item.Key -eq $Key)
        $item.Btn.Tag.active = $isCur
        $item.Btn.Invalidate()
    }
    $nav.Active = $Key
}

# 往导航栏里加一项并返回它的页面容器。
function Add-NavItem {
    param([string]$Key, [string]$Text, [int]$Y, [switch]$Select)
    $nav = $script:App.Nav
    $btn = New-NavButton -Text $Text -Y $Y
    $keyCopy = $Key
    $btn.Add_Click({ param($s, $e) Show-Page -Key $keyCopy }.GetNewClosure())
    $nav.NavBar.Controls.Add($btn)
    [void]$nav.Items.Add(@{ Key = $Key; Btn = $btn })
    if ($Select) { Show-Page -Key $Key }
    return $btn
}

function Set-Status {
    param([string]$Text, $Color)
    if ($script:App.Status) {
        $script:App.Status.Text = $Text
        if ($Color) { $script:App.Status.ForeColor = $Color }
    }
}

$PeriodOrder = @('first', 'second', 'overtime')
$PeriodNames = @{ first = '上半场'; second = '下半场'; overtime = '加时' }

# 多选半场时怎么合并：
#   计数类 -> 相加（叠加）
#   派生指标 -> 按叠加后数据重算（adr/kd/hs_rate/占比等），rating 用叠加后数据重算压缩评分
$SumKeys = @(
    'kills', 'deaths', 'assists', 'headshots', 'damage',
    'opening_kills', 'opening_deaths', 'multi2', 'multi3', 'multi4', 'multi5',
    'he_damage', 'fire_damage', 'decoy_damage', 'utility_damage',
    'he_kills', 'fire_kills',
    'chicken_kills', 'knife_kills', 'zeus_kills', 'plants', 'defuses',
    'teamkills', 'suicides', 'team_damage', 'flash_assists', 'rounds'
)
# 仅用于展示平均的派生指标（重算后不再用平均；保留用于单段兼容）
$AvgKeys = @('rating', 'adr', 'kd', 'hs_rate', 'utility_rate', 'utility_per_round')
# 前端重算派生指标的常数（必须与 analyzer.py 的 Rating 公式逐项一致）
$RatingKB = 0.679; $RatingSP = 0.317; $RatingMKP = 0.158; $RatingAP = 0.106
# 四项权重。击杀项 = K/D 的主要来源；助攻项基准 0.106 偏低、实际容易超标，
# 权重调低才不会喧宾夺主。除数取权重之和，保证「四项都等于基准」的球员正好是 1.00。
$RatingWKP = 1.5; $RatingWSP = 0.7; $RatingWMKP = 1.0; $RatingWAP = 0.4
$RatingDiv = $RatingWKP + $RatingWSP + $RatingWMKP + $RatingWAP
$RatingCompHigh = 0.85; $RatingCompLow = 0.65; $RatingMin = 0.50; $RatingMax = 1.95

# 返回被勾选的半场键。调用方用 @(...) 包一层，这样只有一项时也还是数组。
function Get-CheckedPeriods {
    $sel = @()
    foreach ($k in $PeriodOrder) {
        $cb = $script:App.Checks[$k]
        if ($cb -and $cb.Checked) { $sel += $k }
    }
    return $sel
}

# 把勾选的半场合成一份「队伍 -> 玩家列表」。只勾一个时结果就是它本身。
function Merge-Periods {
    param($Report, $Keys)

    $acc = @{}
    $order = New-Object System.Collections.ArrayList
    $bounds = @{ first = $null; last = $null; rounds = 0 }

    foreach ($k in $PeriodOrder) {
        if ($Keys -notcontains $k) { continue }
        $per = $null
        try { $per = $Report['periods'][$k] } catch { $per = $null }
        if (-not $per -or -not $per['has_data']) { continue }

        if ($null -eq $bounds['first'] -or [int]$per['first_round'] -lt $bounds['first']) {
            $bounds['first'] = [int]$per['first_round']
        }
        if ($null -eq $bounds['last'] -or [int]$per['last_round'] -gt $bounds['last']) {
            $bounds['last'] = [int]$per['last_round']
        }
        $bounds['rounds'] = [int]$bounds['rounds'] + [int]$per['rounds']

        foreach ($rid in @('A', 'B')) {
            foreach ($p in @($per['teams'][$rid]['players'])) {
                $nm = [string]$p['name']
                if (-not $acc.ContainsKey($nm)) {
                    $e = @{ roster = $rid; steamid = [string]$p['steamid']; n = 0
                        sums = @{}; avgs = @{}
                    }
                    foreach ($f in $SumKeys) { $e.sums[$f] = 0 }
                    foreach ($f in $AvgKeys) { $e.avgs[$f] = 0.0 }
                    $acc[$nm] = $e
                    [void]$order.Add($nm)
                }
                $e = $acc[$nm]
                foreach ($f in $SumKeys) { $e.sums[$f] = [int]$e.sums[$f] + [int]$p[$f] }
                foreach ($f in $AvgKeys) { $e.avgs[$f] = [double]$e.avgs[$f] + [double]$p[$f] }
                $e.n = [int]$e.n + 1
            }
        }
    }

    $listA = New-Object System.Collections.ArrayList
    $listB = New-Object System.Collections.ArrayList
    foreach ($nm in $order) {
        $e = $acc[$nm]
        $o = @{ name = $nm; steamid = $e.steamid; roster = $e.roster }
        foreach ($f in $SumKeys) { $o[$f] = [int]$e.sums[$f] }
        # 派生指标按叠加后数据重算，不再取各半场平均
        $rd = [int]$e.sums['rounds']
        $kills = [int]$e.sums['kills']; $deaths = [int]$e.sums['deaths']
        $kd = 0.0; if ($deaths -gt 0) { $kd = [math]::Round([double]$kills / [double]$deaths, 2) } elseif ($kills -gt 0) { $kd = [double]$kills }
        $adr = 0.0; if ($rd -gt 0) { $adr = [math]::Round([double]$e.sums['damage'] / [double]$rd, 1) }
        $hsr = 0.0; if ($kills -gt 0) { $hsr = [math]::Round(100.0 * [int]$e.sums['headshots'] / [double]$kills, 1) }
        $utilDmg = [int]$e.sums['he_damage'] + [int]$e.sums['fire_damage'] + [int]$e.sums['decoy_damage']
        $totalDmg = [int]$e.sums['damage'] + [int]$e.sums['team_damage']
        $urate = 0.0; if ($totalDmg -gt 0) { $urate = [math]::Round(100.0 * $utilDmg / [double]$totalDmg, 1) }
        $upr = 0.0; if ($rd -gt 0) { $upr = [math]::Round([double]$utilDmg / [double]$rd, 1) }
        # Rating 按叠加后 kills/deaths/multi2/assists 重算，与 analyzer.py 一致
        $rating = 0.0
        if ($rd -gt 0) {
            $kp = [double]$kills / [double]$rd
            $sp = [double]($rd - $deaths) / [double]$rd
            if ($sp -lt 0) { $sp = 0 }; if ($sp -gt 1) { $sp = 1 }
            $mkp = [double]([int]$e.sums['multi2']) / [double]$rd
            $ap = [double]([int]$e.sums['assists']) / [double]$rd
            $raw = ($RatingWKP*($kp/$RatingKB) + $RatingWSP*($sp/$RatingSP) + $RatingWMKP*($mkp/$RatingMKP) + $RatingWAP*($ap/$RatingAP)) / $RatingDiv
            $comp = if ($raw -ge 1.0) { $RatingCompHigh } else { $RatingCompLow }
            $val = 1.0 + ($raw - 1.0) * $comp
            if ($val -lt $RatingMin) { $val = $RatingMin } elseif ($val -gt $RatingMax) { $val = $RatingMax }
            $rating = [math]::Round($val, 2)
        }
        $o['kd'] = $kd; $o['adr'] = $adr; $o['hs_rate'] = $hsr
        $o['utility_damage'] = $utilDmg; $o['utility_rate'] = $urate; $o['utility_per_round'] = $upr
        $o['rating'] = $rating
        if ($e.roster -eq 'A') { [void]$listA.Add($o) } else { [void]$listB.Add($o) }
    }

    # 按 Rating 降序，其次击杀、伤害
    $rA = @($listA | Sort-Object @{ Expression = { -[double]$_.rating } }, @{ Expression = { -[int]$_.kills } }, @{ Expression = { -[int]$_.damage } })
    $rB = @($listB | Sort-Object @{ Expression = { -[double]$_.rating } }, @{ Expression = { -[int]$_.kills } }, @{ Expression = { -[int]$_.damage } })

    return @{ A = $rA; B = $rB; bounds = $bounds }
}

function Format-TimelineDetail {
    param($Round)
    $lines = @()
    $lines += ("第 {0} 回合  {1}  比分 {2}:{3}  CT={4}" -f $Round['round'], $Round['period'], $Round['score']['A'], $Round['score']['B'], $Round['ct_roster'])
    $win = $Round['winner']
    $rs = $Round['end_reason']
    if ($win) {
        $wlab = if ($win -eq 'A') { '队伍1' } else { '队伍2' }
        if ($rs) { $lines += ("胜者：{0}（{1}）" -f $wlab, $rs) } else { $lines += ("胜者：{0}" -f $wlab) }
    }
    elseif ($rs) { $lines += ("结束：{0}" -f $rs) }
    if ($Round['plant']) { $lines += ("下包：{0}  点位 {1}" -f $Round['plant']['user'], $Round['plant']['site']) }
    if ($Round['defuse']) { $lines += ("拆包：{0}" -f $Round['defuse']['user']) }
    if ($Round['first_kill']) {
        $fk = $Round['first_kill']
        $hs = if ($fk['headshot']) { ' 爆头' } else { '' }
        $lines += ("首杀：{0} → {1}  {2}{3}" -f $fk['attacker'], $fk['victim'], $fk['weapon'], $hs)
    }
    if ($Round['multi'] -and @($Round['multi']).Count -gt 0) {
        $lines += ("多杀：" + (($Round['multi'] | ForEach-Object { "{0} {1}K" -f $_['name'], $_['kills'] }) -join ' / '))
    }
    $kills = @($Round['kills'])
    if ($kills.Count -gt 0) {
        $lines += ("击杀（{0}）：" -f $kills.Count)
        foreach ($k in $kills) {
            $hs = if ($k['headshot']) { ' HS' } else { '' }
            $pen = if ($k['penetrated']) { ' 穿墙' } else { '' }
            $sm = if ($k['thrusmoke']) { ' 烟' } else { '' }
            $lines += ("  {0} → {1}  {2}{3}{4}{5}" -f $k['attacker'], $k['victim'], $k['weapon'], $hs, $pen, $sm)
        }
    }
    else { $lines += "无击杀记录" }
    return ($lines -join "`r`n")
}

function Render-Timeline {
    $tt = $script:App.TimelineTip
    $flow = $script:App.TimelineFlow
    $hostPanel = $script:App.TimelineHost
    $lbl = $script:App.TimelineLbl
    if (-not $flow -or -not $lbl) { return }

    $rep = $script:App.Report
    $sel = @(Get-CheckedPeriods)
    # 列控件要重建，索引表跟着清空
    $script:App.TlColumns = @{}
    # 批量操作：暂停布局并挂起绘制，避免 20+ 卡片逐个创建时的闪烁与假卡死
    $flow.SuspendLayout()
    try { [System.Windows.Forms.Control]::SuspendLayout($flow) } catch { }
    # 暂停外层 host 的重绘
    try { if ($hostPanel) { $hostPanel.SuspendLayout() } } catch { }
    try {
        foreach ($c in @($flow.Controls)) { $flow.Controls.Remove($c); $c.Dispose() }

        if (-not $rep) { $lbl.Text = "时间轴 — 尚未分析"; return }
        if ($sel.Count -eq 0) { $lbl.Text = "时间轴 — 请至少勾选一个半场"; return }

        $periodSet = @{}
        foreach ($k in $sel) { $periodSet[$k] = $true }
        $all = @()
        try { $all = @($rep['timeline']) } catch { $all = @() }
        $filtered = @($all | Where-Object { $periodSet.ContainsKey([string]$_['period']) } | Sort-Object { [int]$_['round'] })

        if ($filtered.Count -eq 0) { $lbl.Text = "时间轴 — 所选半场无回合"; return }
        $lbl.Text = ("时间轴 — {0} 回合  （鼠标悬停看详情）" -f $filtered.Count)

        $startPan = $script:App._tlStartPan

        # 列上要用的字体只建一次。原来是在循环里 New-Object，20 列就是 40 个
        # Font 对象，既拖慢构建又泄漏 GDI 句柄（Label 释放时不会 Dispose 自己
        # 被赋值的 Font）。列数再多也是这两个字体。
        if (-not $script:TimelineGdi) {
            $script:TimelineGdi = @{
                FontRnd = [System.Drawing.Font]::new('Microsoft YaHei UI', 7.5, [System.Drawing.FontStyle]::Bold)
                FontWin = [System.Drawing.Font]::new('Microsoft YaHei UI', 6.5)
            }
        }
        $tlGdi = $script:TimelineGdi

        # 换边判断的基准：上一条记录的 ct_roster（「这回合哪支队当 CT」）。
        # 不能用 period —— 加时整段都叫 overtime，段内还会再换边。
        $prevCt = $null
        $divW = 12

        foreach ($r in $filtered) {
            $rnd = [int]$r['round']
            $ctNow = [string]$r['ct_roster']

            # ---- 换边分隔条 ----
            # 相邻两回合的 ct_roster 不同 = 换边（中场一次，加时里每换一次边一次）。
            # 插在「换边后那一列」之前：整列高的竖线 + 一条横向轴线片段
            # （y=28、高 2，和左右两列的轴线同高同色，整条轴不会断）。
            if ($prevCt -and $ctNow -and $prevCt -ne $ctNow) {
                $div = New-Object System.Windows.Forms.Panel
                $div.Size = New-Object System.Drawing.Size($divW, 58)
                $div.Margin = New-Object System.Windows.Forms.Padding(0, 3, 0, 3)
                $div.BackColor = [System.Drawing.Color]::White
                # 标记：测试靠它把分隔条和「卡片列」区分开
                $div.AccessibleName = 'tl-divider'
                $haxis = New-Object System.Windows.Forms.Panel
                $haxis.Bounds = New-Object System.Drawing.Rectangle(0, 28, $divW, 2)
                $haxis.BackColor = [System.Drawing.Color]::FromArgb(120, 120, 120)
                $vline = New-Object System.Windows.Forms.Panel
                $vline.Bounds = New-Object System.Drawing.Rectangle(([int]($divW / 2) - 1), 0, 2, 58)
                $vline.BackColor = [System.Drawing.Color]::FromArgb(150, 152, 165)
                $div.Controls.Add($haxis)
                $div.Controls.Add($vline)
                Enable-DoubleBufferTree $div
                # 按在分隔条上也要能横向拖动时间轴（否则多出 12px 的死区）
                if ($startPan) { $div.Add_MouseDown($startPan) }
                [void]$flow.Controls.Add($div)
            }
            $prevCt = $ctNow

            $winner = [string]$r['winner']
            $reason = [string]$r['end_reason']
            $aliveA = 0; $aliveB = 0
            try { $aliveA = [int]$r['alive']['A']; $aliveB = [int]$r['alive']['B'] } catch { }
            $detail = Format-TimelineDetail -Round $r

            # ---- 一列 = 中间一条轴线 + 上下两排方块 ----
            # 上排 = 队伍1 结束时存活人数（一人一个方块），下排 = 队伍2。
            # 没有外框：列与列之间横向边距为 0，轴线接起来就是贯穿整条时间轴的一条线。
            # 纵向严格镜像（列高 58、中心 29）：
            #   上排中心 6  ←→ 下排中心 52    (29-6 = 52-29 = 23)
            #   回合中心 17 ←→ 获胜中心 41    (29-17 = 41-29 = 12)
            # 高度预算：行高 116 - host 上下边距 6 - host 内边距 8 - 标题 18
            #          - flow 上内边距 4 - 横向滚动条 17 = 63px 可用；列 58 + 上下边距 6 = 64。
            $colW = 56
            $col = New-Object System.Windows.Forms.Panel
            $col.Size = New-Object System.Drawing.Size($colW, 58)
            $col.Margin = New-Object System.Windows.Forms.Padding(0, 3, 0, 3)
            $col.BorderStyle = 'None'
            $col.BackColor = [System.Drawing.Color]::White
            $col.Tag = $detail

            # 中间那条轴线（横跨整列，相邻列首尾相接）
            $axis = New-Object System.Windows.Forms.Panel
            $axis.Bounds = New-Object System.Drawing.Rectangle(0, 28, $colW, 2)
            $axis.BackColor = [System.Drawing.Color]::FromArgb(120, 120, 120)
            $axis.Tag = $detail

            # 轴上：回合数，按胜方染色
            $lbRnd = New-Object System.Windows.Forms.Label
            $lbRnd.AutoSize = $false
            $lbRnd.TextAlign = 'MiddleCenter'
            $lbRnd.Bounds = New-Object System.Drawing.Rectangle(0, 11, $colW, 12)
            $lbRnd.Font = $tlGdi.FontRnd
            $lbRnd.Text = ('R{0}' -f $rnd)
            if ($winner -eq 'A') { $lbRnd.ForeColor = [System.Drawing.Color]::FromArgb(29, 78, 216) }
            elseif ($winner -eq 'B') { $lbRnd.ForeColor = [System.Drawing.Color]::FromArgb(194, 65, 12) }
            else { $lbRnd.ForeColor = [System.Drawing.Color]::DimGray }
            $lbRnd.Tag = $detail

            # 轴下：获胜方式
            $lbWin = New-Object System.Windows.Forms.Label
            $lbWin.AutoSize = $false
            $lbWin.TextAlign = 'MiddleCenter'
            $lbWin.Bounds = New-Object System.Drawing.Rectangle(0, 35, $colW, 12)
            $lbWin.Font = $tlGdi.FontWin
            $lbWin.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
            $lbWin.Text = if ($reason) { $reason } else { '—' }
            $lbWin.Tag = $detail

            # 上下两排方块
            $pnlA = New-Object System.Windows.Forms.Panel
            $pnlA.Bounds = New-Object System.Drawing.Rectangle(0, 1, $colW, 10)
            $pnlA.BackColor = [System.Drawing.Color]::White
            $pnlA.Tag = $detail

            $pnlB = New-Object System.Windows.Forms.Panel
            $pnlB.Bounds = New-Object System.Drawing.Rectangle(0, 47, $colW, 10)
            $pnlB.BackColor = [System.Drawing.Color]::White
            $pnlB.Tag = $detail

            $sqA = [System.Drawing.Color]::FromArgb(37, 99, 235)
            $sqB = [System.Drawing.Color]::FromArgb(234, 88, 12)
            $sqsA = @(); $sqsB = @()
            # 方块 8x8、间隔 2，整体在列里水平居中：n 个占 10n-2 宽
            $x0A = [int][math]::Round(($colW - (10 * $aliveA - 2)) / 2.0)
            if ($aliveA -gt 0 -and $x0A -lt 0) { $x0A = 0 }
            for ($i = 0; $i -lt $aliveA; $i++) {
                $b = New-Object System.Windows.Forms.Panel
                $b.Size = New-Object System.Drawing.Size(8, 8)
                $b.Location = New-Object System.Drawing.Point(($x0A + $i * 10), 1)
                $b.BackColor = $sqA
                $b.Tag = $detail
                Set-RoundedRegion -Control $b -Radius 2
                $pnlA.Controls.Add($b)
                $sqsA += $b
            }
            $x0B = [int][math]::Round(($colW - (10 * $aliveB - 2)) / 2.0)
            if ($aliveB -gt 0 -and $x0B -lt 0) { $x0B = 0 }
            for ($i = 0; $i -lt $aliveB; $i++) {
                $b = New-Object System.Windows.Forms.Panel
                $b.Size = New-Object System.Drawing.Size(8, 8)
                $b.Location = New-Object System.Drawing.Point(($x0B + $i * 10), 1)
                $b.BackColor = $sqB
                $b.Tag = $detail
                Set-RoundedRegion -Control $b -Radius 2
                $pnlB.Controls.Add($b)
                $sqsB += $b
            }

            $col.Controls.Add($pnlA)
            $col.Controls.Add($lbRnd)
            $col.Controls.Add($axis)
            $col.Controls.Add($lbWin)
            $col.Controls.Add($pnlB)
            # 列是每次重绘时间轴时新建的，双缓冲要在这里开。
            # 不开的话横向拖动时每一列都直接往屏幕上画，整条轴会闪。
            Enable-DoubleBufferTree $col
            $script:App.TlColumns[$rnd] = $col

            # 悬停高亮 + 气泡详情。
            # 注意：这里不能捕获 $col —— Render-Timeline 返回后局部作用域就没了，
            # 回调里的 $col 会退化成 $null（$viewTimer 那个坑的同款）。
            # 改为从 $s 往上找「父控件是 flow」的那一层，就是整列本身。
            $showTip = {
                param($s, $e)
                $tip = $script:App.TimelineTip
                $detail2 = [string]$s.Tag
                if ($tip -and $detail2) { $tip.SetToolTip($s, $detail2) }
                try {
                    $p = $s
                    while ($p -and $p.Parent -and -not ($p.Parent -is [System.Windows.Forms.FlowLayoutPanel])) { $p = $p.Parent }
                    if ($p) {
                        $hr = $script:App.TlHoverRgb
                        Set-TlColumnBg -Col $p -Color ([System.Drawing.Color]::FromArgb($hr[0], $hr[1], $hr[2]))
                    }
                } catch { }
            }
            $hideTip = {
                param($s, $e)
                try {
                    $p = $s
                    while ($p -and $p.Parent -and -not ($p.Parent -is [System.Windows.Forms.FlowLayoutPanel])) { $p = $p.Parent }
                    # 离开时恢复成「选中色」或白色 —— 不能一律刷白，
                    # 否则鼠标划过当前选中的那一列会把选中标记擦掉。
                    if ($p) {
                        $bg = [System.Drawing.Color]::White
                        $rn2 = 0
                        try { $rn2 = [int]$p.AccessibleDescription } catch { }
                        if ($rn2 -gt 0 -and $rn2 -eq [int]$script:App.SelectedRound) { $bg = Get-TlSelColor }
                        Set-TlColumnBg -Col $p -Color $bg
                    }
                } catch { }
            }

            # 单击卡片 -> 右侧「详细信息」面板，判定在 $tlEndPan 里做
            # （卡片自己收不到 Click，原因见 $tlEndPan 的注释）。
            # 这里只把回合号写到控件上，让那边命中测试之后能读出来。
            # 不用闭包也不用 GetNewClosure()：后者会把 scriptblock 包进动态模块，
            # 回调里就找不到 Render-Detail 了（踩过一次）。
            $mouseTargets = @($col, $axis, $lbRnd, $lbWin, $pnlA, $pnlB) + $sqsA + $sqsB
            foreach ($c in $mouseTargets) {
                $c.AccessibleDescription = [string]$rnd
                $c.Add_MouseEnter($showTip)
                $c.Add_MouseLeave($hideTip)
                # 列会盖住 flow，所以按下事件必须挂在列及其所有子控件上
                if ($startPan) { $c.Add_MouseDown($startPan) }
                if ($tt) { $tt.SetToolTip($c, $detail) }
            }

            [void]$flow.Controls.Add($col)
        }

        # 恢复：重置拖拽状态与滚动位置，避免切半场后残留偏移
        try {
            $drag = $script:App._tlDrag
            if ($drag) { $drag.pan = $false; $drag.moved = $false }
            if ($flow.Controls.Count -gt 0) {
                $flow.AutoScrollPosition = New-Object System.Drawing.Point(0, 0)
            }
            $flow.Cursor = [System.Windows.Forms.Cursors]::Default
            if ($hostPanel) { $hostPanel.Cursor = [System.Windows.Forms.Cursors]::Default }
        } catch { }
    }
    finally {
        try { if ($hostPanel) { $hostPanel.ResumeLayout($true) } } catch { }
        try { [System.Windows.Forms.Control]::ResumeLayout($flow, $true) } catch { }
        $flow.ResumeLayout($true)
        try { $flow.PerformLayout(); if ($hostPanel) { $hostPanel.PerformLayout() } } catch { }
        # 列是新建的（白底），把「当前选中回合」的高亮补回来 ——
        # 切换半场勾选之后重建时间轴，选中标记不能丢。
        try { Set-TlSelected -Round ([int]$script:App.SelectedRound) -On $true } catch { }
    }
}

# 把当前勾选的半场（可能多个）渲染到三个页面的上下两张表
function Render-View {
    param($Report)

    $sel = @(Get-CheckedPeriods)
    $teams = @{ A = @(); B = @() }
    $bounds = @{ first = $null; last = $null; rounds = 0 }
    $empty = $false

    if ($Report -and $sel.Count -gt 0) {
        $m = Merge-Periods -Report $Report -Keys $sel
        $teams['A'] = @($m['A'])
        $teams['B'] = @($m['B'])
        $bounds = $m['bounds']
        if ([int]$bounds['rounds'] -eq 0) { $empty = $true }
    }

    foreach ($pk in @('main', 'util', 'fun')) {
        foreach ($rid in @('A', 'B')) {
            $grid = $script:App.Grids[$pk][$rid]
            $lbl = $script:App.TeamLbls[$pk][$rid]
            if (-not $grid) { continue }
            $grid.Rows.Clear()

            $players = @($teams[$rid])
            foreach ($p in $players) {
                $vals = @()
                foreach ($c in $script:App.Cols[$pk]) {
                    $v = $p[$c.K]
                    if ($null -eq $v) { $v = '' }
                    $vals += [string]$v
                }
                [void]$grid.Rows.Add($vals)
            }

            if (-not $lbl) { continue }
            if (-not $Report) {
                $lbl.Text = '队伍 — 尚未分析'
                continue
            }
            if ($sel.Count -eq 0) {
                $lbl.Text = '队伍 — 请至少勾选一个半场'
                continue
            }
            $ti = $Report['teams'][$rid]
            if ($empty) {
                $lbl.Text = ('{0}（开局 {1}） — 所选中阶段没有数据' -f $ti['label'], $ti['start_side'])
                continue
            }
            $sum = 0
            foreach ($p in $players) { $sum += [int]$p['kills'] }
            $lbl.Text = ('{0}（开局 {1}） — {2} 人 — 合计 {3} 杀 — 第 {4}-{5} 回合' -f $ti['label'], $ti['start_side'], $players.Count, $sum, $bounds['first'], $bounds['last'])
        }
    }

    # 阶段说明
    if ($script:App.PeriodInfo) {
        if (-not $Report) {
            $script:App.PeriodInfo.Text = '尚未分析'
        }
        elseif ($sel.Count -eq 0) {
            $script:App.PeriodInfo.Text = '未选择半场'
        }
        elseif ($empty) {
            $script:App.PeriodInfo.Text = '所选阶段本局没有数据'
        }
        else {
            $names = @()
            foreach ($k in $sel) { $names += $PeriodNames[$k] }
            $txt = '{0} — 第 {1}-{2} 回合，共 {3} 回合' -f ($names -join ' + '), $bounds['first'], $bounds['last'], $bounds['rounds']
            # 多选时的合并规则（计数类相加、派生指标按叠加后数据重算）不写在标题里，
            # 免得标题太长；规则见 README 的「多选时怎么合并」。
            $script:App.PeriodInfo.Text = $txt
        }
    }

    Render-Timeline
}

function New-TeamGrid {
    param($Cols, $Font)

    $g = New-Object System.Windows.Forms.DataGridView
    $g.Dock = 'Fill'
    $g.ReadOnly = $true
    $g.AllowUserToAddRows = $false
    $g.AllowUserToDeleteRows = $false
    $g.RowHeadersVisible = $false
    $g.SelectionMode = 'FullRowSelect'
    $g.MultiSelect = $false
    $g.AutoSizeColumnsMode = 'None'
    $g.BackgroundColor = [System.Drawing.Color]::White
    $g.AllowUserToResizeRows = $false
    # 列可以拖宽窄；不让拖列顺序 —— 否则在表头上按住会被当成"换列位置"，
    # 和下面"按住表格内容左右平移"的手感打架。
    $g.AllowUserToOrderColumns = $false
    $g.AllowUserToResizeColumns = $true
    $g.BorderStyle = 'None'
    $g.ColumnHeadersDefaultCellStyle.Font = $Font
    $g.Font = $Font

    # 行高 / 表头高必须跟着字体走。
    # DataGridView 默认行高 22px（还要再减 1px 网格线 = 21px 内容区），
    # 而 9.5pt 微软雅黑一行文字的「行盒」实测是 19px —— 中文字形的上下边缘
    # 几乎贴到行框上，稍微差一点就被裁掉（用户反馈「每行文字上下被切掉一点」）。
    # 这里实测行盒高度，再上下各留 4px 呼吸空间，换更大字体也不会再被裁。
    # 一行 27px：5 名队员 = 27(表头) + 5*27 = 162px，上下两个面板都放得下。
    $lineH = [int][Math]::Ceiling([System.Windows.Forms.TextRenderer]::MeasureText('汉字', $Font).Height)
    $g.RowTemplate.Height = $lineH + 8
    $g.ColumnHeadersHeight = $lineH + 8

    foreach ($c in $Cols) {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.HeaderText = $c.H
        $col.Width = $c.W
        $col.SortMode = 'NotSortable'
        switch ($c.A) {
            'C' { $col.DefaultCellStyle.Alignment = 'MiddleCenter' }
            'R' { $col.DefaultCellStyle.Alignment = 'MiddleRight' }
            default { $col.DefaultCellStyle.Alignment = 'MiddleLeft' }
        }
        # 表头悬浮说明（鼠标停在列标题上会弹出）
        if ($c.ContainsKey('T')) { $col.HeaderCell.ToolTipText = $c.T }
        [void]$g.Columns.Add($col)
    }

    # ---- 按住表格内容左右拖拽 = 横向平移 ----
    # 表格列比可视区宽，光靠滚轮/滚动条不好用，这里做成"抓住纸往左右拉"。
    # 用一个 4px 阈值区分"点一下选中行"和"拖动"。
    $g.Tag = @{ pan = $false; lastX = 0; moved = $false; totalW = 0 }
    $g.Add_MouseDown({
            param($s, $e)
            if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
            # 只在「单元格」或「表格内的空白」上拖；表头留给"拖宽列"，
            # 滚动条留给系统，避免互相打架。
            $ht = $s.HitTest($e.X, $e.Y)
            $ty = $ht.Type
            if ($ty -ne [System.Windows.Forms.DataGridViewHitTestType]::Cell -and
                $ty -ne [System.Windows.Forms.DataGridViewHitTestType]::None) { return }
            $s.Tag.pan = $true
            $s.Tag.lastX = $e.X
            $s.Tag.moved = $false
            # 列总宽在按下时算一次就够（拖动过程中列宽不会变）。
            # 原来放在 MouseMove 里，每移一格都要遍历一遍 Columns —— 那是
            # PSObject 属性访问，鼠标一动就是几百次，拖起来发涩。
            # GetColumnsWidth 是原生方法，比 PowerShell 循环快一个数量级。
            $total = 0
            try { $total = [int]$s.Columns.GetColumnsWidth([System.Windows.Forms.DataGridViewElementStates]::Visible) }
            catch { foreach ($c in $s.Columns) { $total += [int]$c.Width } }
            $s.Tag.totalW = $total
        })
    $g.Add_MouseMove({
            param($s, $e)
            if (-not $s.Tag.pan) { return }
            $dx = [int]$s.Tag.lastX - $e.X
            if (-not $s.Tag.moved) {
                if ([math]::Abs($dx) -lt 4) { return }
                $s.Tag.moved = $true
                $s.Cursor = [System.Windows.Forms.Cursors]::SizeWE
            }
            $s.Tag.lastX = $e.X

            $max = [int]$s.Tag.totalW - [int]$s.ClientSize.Width
            if ($max -lt 0) { $max = 0 }
            if ($max -eq 0) { return }
            $off = [int]$s.HorizontalScrollingOffset + $dx
            if ($off -lt 0) { $off = 0 }
            if ($off -gt $max) { $off = $max }
            try { $s.HorizontalScrollingOffset = $off } catch { }
        })
    $g.Add_MouseUp({
            param($s, $e)
            if ($s.Tag.pan) {
                $s.Tag.pan = $false
                $s.Tag.moved = $false
                $s.Cursor = [System.Windows.Forms.Cursors]::Default
            }
        })
    return $g
}

# 武器图标：这里原来有一整套 GDI+ 手绘剪影（按步枪 / 狙击枪 / 冲锋枪 / 手枪 /
# 霰弹枪 / 机枪 / 刀 / 手雷 / C4 / 电击枪 / 坠落伤害 共 11 类画多边形）。
# 后来改成直接在详情栏里显示武器名：手绘的轮廓再像也不是游戏内的原图，
# 反而容易认错，文字更准。相关代码已删除。
# 一页 = 上下两个队伍，各一张表
function New-TeamPage {
    param([string]$Title, [string]$Key, $Cols, $Font)

    $page = New-Object System.Windows.Forms.TabPage
    $page.Text = $Title
    $page.Tag = $Key
    $page.BackColor = (Get-UiBg)
    $page.Padding = New-Object System.Windows.Forms.Padding(4)

    # 用 SplitContainer：中间那条分隔线可以用鼠标上下拖动。
    # 两个队伍**上下排列**（队伍 1 在上、队伍 2 在下），不是左右并排：
    # 左右并排时每张表只有 ~760px，而列总宽 978px，横向摆不开、得靠拖；
    # 上下排列时每张表独占整宽，所有列一次显示完，而且下方本来就有大片空余高度。
    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock = 'Fill'
    $split.BackColor = (Get-UiBg)
    $split.Orientation = 'Horizontal'
    $split.SplitterWidth = 6
    $split.IsSplitterFixed = $false
    $split.FixedPanel = 'None'
    # Panel1MinSize / Panel2MinSize / SplitterDistance 三者互相约束，
    # 只能在窗口有真实尺寸之后设 —— 见 Show-Gui 里的 Add_Shown。
    $page.Controls.Add($split)

    foreach ($pair in @(@('A', $split.Panel1), @('B', $split.Panel2))) {
        $rid = $pair[0]
        $cell = $pair[1]
        $cell.Padding = New-Object System.Windows.Forms.Padding(6, 4, 6, 4)
        $cell.BackColor = [System.Drawing.Color]::White
        Enable-RoundRegion -Control $cell -Radius 12

        # 先加填充控件，后加停靠边控件 —— 顺序反了标签会被挤没
        $g = New-TeamGrid -Cols $Cols -Font $Font
        # 表格外面再套一层：圆角 Region 会把 DataGridView 的直角一起裁掉，
        # 1px 内边距露出来的就是描边色 —— 看起来就是一张圆角表格卡片。
        $wrap = New-Object System.Windows.Forms.Panel
        $wrap.Dock = 'Fill'
        $wrap.BackColor = (Get-UiEdge)
        $wrap.Padding = New-Object System.Windows.Forms.Padding(1)
        $wrap.Controls.Add($g)
        $cell.Controls.Add($wrap)

        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Dock = 'Top'
        $lbl.Height = 26
        $lbl.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10,
            [System.Drawing.FontStyle]::Bold)
        $lbl.Text = '队伍'
        $lbl.BackColor = [System.Drawing.Color]::White
        $cell.Controls.Add($lbl)
        Enable-RoundRegion -Control $wrap -Radius 10

        $script:App.Grids[$Key][$rid] = $g
        $script:App.TeamLbls[$Key][$rid] = $lbl
    }
    [void]$script:App.Splits.Add($split)
    return $page
}

# ==================== 右侧「详细信息」面板 ====================
# 悬停在时间轴卡片上只出悬浮窗（保持原样）；单击卡片才在这里画出该回合
# 完整的事件时间轴：倒计时 + 当时存活人数 + 击杀/下包/拆包/回合结束。
# 自绘（Panel + Paint），因为要按 CT/T 分色、还要在中间插武器图标，
# 用一堆 Label 拼会又慢又难对齐。
function New-DetailPanel {
    param($Font)

    $p = New-Object System.Windows.Forms.Panel
    $p.Dock = 'Right'
    $p.Width = 520
    $p.BackColor = [System.Drawing.Color]::White
    $p.AutoScroll = $true

    # ---- 绘制资源只建一次 ----
    # 原来是在 Paint 回调里 New-Object：每次重绘新建 4 个 Font、2 个 Pen、
    # 每行一个 SolidBrush，而结尾只 Dispose 了最后一个 Pen —— 其余全部泄漏成
    # GDI 句柄。界面重绘越多次越卡，最后会撞上每进程 1 万个 GDI 句柄的上限。
    # 这些对象整个程序生命周期都用得上，建一次就够了。
    if (-not $script:DetailGdi) {
        $script:DetailGdi = @{
            FontTitle = [System.Drawing.Font]::new('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
            FontBody  = [System.Drawing.Font]::new('Microsoft YaHei UI', 9)
            FontBold  = [System.Drawing.Font]::new('Microsoft YaHei UI', 9.5, [System.Drawing.FontStyle]::Bold)
            FontTime  = [System.Drawing.Font]::new('Consolas', 9.5, [System.Drawing.FontStyle]::Bold)
            PenEdge   = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(214, 214, 222), 1)
            PenLine   = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(205, 205, 213), 1)
            PenAxis   = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(205, 205, 213), 2)
            Brushes   = @{}
        }

        # ---- 标题区尺寸：按字体实测，Paint 和 Render-Detail 共用 ----
        # 原来 Paint 里写 $headH = 48、分隔线画在 48-8 = 40，而副标题从 y=33
        # 起、9pt 雅黑实测 17px 高（占 33..50）—— 分隔线正好横穿副标题，
        # 表现就是「回合数下面那一行被一条线贯穿」。
        # 同一组数字在 Render-Detail 里算滚动高度时又写了一遍（48 + n*26 + 14），
        # 改一处必坏另一处。现在量一次存这里，两边都读它。
        $gdi = $script:DetailGdi
        $gdi.RowH = 26
        $gdi.YTitle = 12
        $gdi.YSub = $gdi.YTitle + [System.Windows.Forms.TextRenderer]::MeasureText('第 1 回合', $gdi.FontTitle).Height + 2
        $gdi.YDiv = $gdi.YSub + [System.Windows.Forms.TextRenderer]::MeasureText('上半场    比分 0:0    开局 CT = 队伍1', $gdi.FontBody).Height + 5
        # 事件行从分隔线下方再留 7px 开始
        $gdi.HeadH = $gdi.YDiv + 7
    }
    $p.Add_Paint({
            param($s, $e)

            # 注意：这里必须走 $script:DetailGdi。Paint 回调是在 New-DetailPanel
            # 返回之后才触发的，函数里的局部变量那时已经不存在了，直接用会变成 $null。
            $gdi = $script:DetailGdi
            $g = $e.Graphics
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

            $fTitle = $gdi.FontTitle
            $fBody = $gdi.FontBody
            $fBold = $gdi.FontBold
            $fTime = $gdi.FontTime

            # 左侧一条竖线把详情栏和页签区分开：白底挨着白底容易糊成一片。
            # 画在 TranslateTransform 之前，这样滚动时它不会跟着跑。
            $g.DrawLine($gdi.PenEdge, 0, 0, 0, $s.ClientSize.Height)
            $g.TranslateTransform($s.AutoScrollPosition.X, $s.AutoScrollPosition.Y)

            # 白底（和软件其他区域一致），所以文字用深色
            $cText = [System.Drawing.Color]::FromArgb(32, 32, 36)
            $cDim = [System.Drawing.Color]::FromArgb(118, 118, 128)
            $cLine = [System.Drawing.Color]::FromArgb(205, 205, 213)
            # CT / T 用软件里原有的队色（时间轴方块同款），不用参考图那套紫/绿。
            # 白底上 T 的亮橙 (234,88,12) 对比度只有 3.5:1，换成同一色系、软件里
            # 已经在用的深橙 (194,65,12)：5.2:1；CT 蓝 (37,99,235) 是 5.2:1。
            $cCT = [System.Drawing.Color]::FromArgb(37, 99, 235)
            $cT = [System.Drawing.Color]::FromArgb(194, 65, 12)

            $padL = 14
            # 标题区尺寸由 New-DetailPanel 按字体量好后存进 $gdi，这里不再写死
            $rowH = $gdi.RowH
            $headH = $gdi.HeadH
            $xLine = $padL + 5
            # 左侧三列按内容宽度卡紧（倒计时 4 字符、存活数 3 字符），
            # 省下来的宽度留给右边三栏，详情栏整体才能压在 520px 以内。
            $xTime = $padL + 20
            $xAlive = $xTime + 40
            $xBody = $xAlive + 34

            $info = $script:App.DetailInfo
            $rows = @($script:App.DetailRows)

            $pen = $gdi.PenLine
            if (-not $info) {
                # 空状态和填充态共用同一组 y，点选回合时标题不会跳一下
                [System.Windows.Forms.TextRenderer]::DrawText($g, '详细信息', $fTitle,
                    (New-Object System.Drawing.Point($padL, $gdi.YTitle)), $cText)
                [System.Windows.Forms.TextRenderer]::DrawText($g, '点一下时间轴上的回合卡片，这里显示该回合的完整事件', $fBody,
                    (New-Object System.Drawing.Point($padL, $gdi.YSub)), $cDim)
                return
            }

            # ---- 标题：第几回合 / 半场 / 比分 / 谁开局是 CT ----
            [System.Windows.Forms.TextRenderer]::DrawText($g, ('第 {0} 回合' -f $info['round']), $fTitle,
                (New-Object System.Drawing.Point($padL, $gdi.YTitle)), $cText)
            $sub = '{0}    比分 {1}:{2}    开局 CT = 队伍{3}' -f $info['period'], $info['scoreA'], $info['scoreB'], $info['ctTeam']
            [System.Windows.Forms.TextRenderer]::DrawText($g, $sub, $fBody,
                (New-Object System.Drawing.Point($padL, $gdi.YSub)), $cDim)
            # 分隔线画在副标题下方（$gdi.YDiv 是量出来的，不再用 headH-8 这种估算）
            $g.DrawLine($pen, $padL, $gdi.YDiv, ($s.ClientSize.Width - $padL), $gdi.YDiv)

            $n = $rows.Count
            if ($n -eq 0) {
                [System.Windows.Forms.TextRenderer]::DrawText($g, '这一回合没有事件', $fBody,
                    (New-Object System.Drawing.Point($padL, $headH)), $cDim)
                return
            }

            # ---- 左侧那条贯穿的事件轴线 ----
            $g.DrawLine($gdi.PenAxis, $xLine, ($headH + $rowH / 2), $xLine, ($headH + ($n - 1) * $rowH + $rowH / 2))

            for ($i = 0; $i -lt $n; $i++) {
                $r = $rows[$i]
                $cy = [int]($headH + $i * $rowH + $rowH / 2)
                $kind = [string]$r['kind']

                # 圆点按事件归属方上色：CT 蓝、T 橙，回合开始/结束用灰
                $dot = $cDim
                if ($kind -eq 'kill') {
                    if ([string]$r['attacker_side'] -eq 'CT') { $dot = $cCT }
                    elseif ([string]$r['attacker_side'] -eq 'T') { $dot = $cT }
                }
                elseif ($kind -eq 'plant' -or $kind -eq 'defuse') {
                    if ([string]$r['user_side'] -eq 'CT') { $dot = $cCT }
                    elseif ([string]$r['user_side'] -eq 'T') { $dot = $cT }
                }
                elseif ($kind -eq 'end') {
                    if ([string]$r['winner_side'] -eq 'CT') { $dot = $cCT }
                    elseif ([string]$r['winner_side'] -eq 'T') { $dot = $cT }
                }
                # 圆点颜色按行变，按颜色缓存 Brush —— 整屏也就 CT 蓝 / T 橙 / 灰
                # 三种，没必要每行新建一个再 Dispose。
                $bk = $dot.ToArgb()
                if (-not $gdi.Brushes.ContainsKey($bk)) {
                    $gdi.Brushes[$bk] = [System.Drawing.SolidBrush]::new($dot)
                }
                $g.FillEllipse($gdi.Brushes[$bk], ($xLine - 4), ($cy - 4), 8, 8)

                # 倒计时（1:55 -> 0:00）
                [System.Windows.Forms.TextRenderer]::DrawText($g, [string]$r['t'], $fTime,
                    (New-Object System.Drawing.Point($xTime, ($cy - 9))), $cText)
                # 当时存活人数
                [System.Windows.Forms.TextRenderer]::DrawText($g, ('{0}v{1}' -f $r['alive_a'], $r['alive_b']), $fBold,
                    (New-Object System.Drawing.Point($xAlive, ($cy - 9))), $cText)

                if ($kind -eq 'kill') {
                    $atk = [string]$r['attacker']
                    $vic = [string]$r['victim']
                    $ca = $cText
                    if ([string]$r['attacker_side'] -eq 'CT') { $ca = $cCT } elseif ([string]$r['attacker_side'] -eq 'T') { $ca = $cT }
                    $cv = $cText
                    if ([string]$r['victim_side'] -eq 'CT') { $cv = $cCT } elseif ([string]$r['victim_side'] -eq 'T') { $cv = $cT }

                    # 攻击者 [武器] 受害者，紧凑排布。
                    # 不按固定列对齐：名字长短差得远（有 9 个字符的英文名，也有
                    # 10 个汉字的「春序对弈 豆腐干被问到」），对齐会在短名字后面
                    # 留出上百像素的空白，反而不好读。参考图也是紧挨着排的。
                    # 武器直接用文字，不再画图标：手绘的剪影再像也不是游戏内的
                    # 原图，认错了还不如把名字写出来。
                    [System.Windows.Forms.TextRenderer]::DrawText($g, $atk, $fBold,
                        (New-Object System.Drawing.Point($xBody, ($cy - 9))), $ca)
                    $x = $xBody + [System.Windows.Forms.TextRenderer]::MeasureText($atk, $fBold).Width + 6
                    $wpnTxt = '[{0}]' -f [string]$r['weapon']
                    [System.Windows.Forms.TextRenderer]::DrawText($g, $wpnTxt, $fBody,
                        (New-Object System.Drawing.Point($x, ($cy - 8))), $cDim)
                    $x += [System.Windows.Forms.TextRenderer]::MeasureText($wpnTxt, $fBody).Width + 6

                    [System.Windows.Forms.TextRenderer]::DrawText($g, $vic, $fBold,
                        (New-Object System.Drawing.Point($x, ($cy - 9))), $cv)
                    $x += [System.Windows.Forms.TextRenderer]::MeasureText($vic, $fBold).Width + 10

                    $extra = @()
                    if ($r['headshot']) { $extra += '爆头' }
                    if ($r['penetrated']) { $extra += '穿墙' }
                    if ($r['thrusmoke']) { $extra += '穿烟' }
                    if ($extra.Count -gt 0) {
                        $ex = $extra -join ' '
                        # 名字特别长时这一行会顶到面板右边缘，标记是附加信息，
                        # 放不下就不画，不要让它被切成半截字。
                        $ew = [System.Windows.Forms.TextRenderer]::MeasureText($ex, $fBody).Width
                        if (($x + $ew) -le ($s.ClientSize.Width - 6)) {
                            [System.Windows.Forms.TextRenderer]::DrawText($g, $ex, $fBody,
                                (New-Object System.Drawing.Point($x, ($cy - 8))), $cDim)
                        }
                    }
                }
                elseif ($kind -eq 'start') {
                    [System.Windows.Forms.TextRenderer]::DrawText($g, '回合开始', $fBold,
                        (New-Object System.Drawing.Point($xBody, ($cy - 9))), $cText)
                }
                elseif ($kind -eq 'plant' -or $kind -eq 'defuse') {
                    $u = [string]$r['user']
                    $cu = $cText
                    if ([string]$r['user_side'] -eq 'CT') { $cu = $cCT } elseif ([string]$r['user_side'] -eq 'T') { $cu = $cT }
                    $lab = if ($kind -eq 'plant') { '下包' } else { '拆包' }
                    [System.Windows.Forms.TextRenderer]::DrawText($g, $lab, $fBody,
                        (New-Object System.Drawing.Point($xBody, ($cy - 8))), $cDim)
                    [System.Windows.Forms.TextRenderer]::DrawText($g, $u, $fBold,
                        (New-Object System.Drawing.Point(($xBody + 42), ($cy - 9))), $cu)
                }
                elseif ($kind -eq 'end') {
                    $side = [string]$r['winner_side']
                    $ce = $cText
                    if ($side -eq 'CT') { $ce = $cCT; $sideLab = '反恐精英获胜' }
                    elseif ($side -eq 'T') { $ce = $cT; $sideLab = '恐怖分子获胜' }
                    else { $sideLab = '回合结束' }
                    [System.Windows.Forms.TextRenderer]::DrawText($g, $sideLab, $fBold,
                        (New-Object System.Drawing.Point($xBody, ($cy - 9))), $ce)
                    [System.Windows.Forms.TextRenderer]::DrawText($g, [string]$r['reason'], $fBody,
                        (New-Object System.Drawing.Point(($xBody + 96), ($cy - 8))), $cDim)
                }
            }
        })
    return $p
}

# 把某一回合的详情装进右侧面板。$Round 为 0/空 时回到「点一下卡片」的空状态。
function Render-Detail {
    param($Report, $Round)

    $panel = $script:App.DetailPanel
    if (-not $panel) { return }

    $entry = $null
    if ($Report -and $Round) {
        foreach ($t in @($Report['timeline'])) {
            if ([int]$t['round'] -eq [int]$Round) { $entry = $t; break }
        }
    }

    if (-not $entry) {
        $script:App.DetailInfo = $null
        $script:App.DetailRows = @()
        Set-TlSelected -Round ([int]$script:App.SelectedRound) -On $false
        $script:App.SelectedRound = 0
        $panel.AutoScrollMinSize = New-Object System.Drawing.Size(0, 0)
        $panel.Invalidate()
        return
    }

    $periodNames = @{ first = '上半场'; second = '下半场'; overtime = '加时' }
    $pk = [string]$entry['period']
    $periodLab = if ($periodNames.ContainsKey($pk)) { $periodNames[$pk] } else { $pk }

    $script:App.DetailInfo = @{
        round  = [int]$entry['round']
        period = $periodLab
        scoreA = [int]$entry['score']['A']
        scoreB = [int]$entry['score']['B']
        ctTeam = if ([string]$entry['ct_roster'] -eq 'A') { '1' } else { '2' }
    }
    $rows = @($entry['detail'])
    $script:App.DetailRows = $rows

    # 时间轴上把当前选中的那一列标出来。只动「上一列」和「这一列」，
    # 不重建整条时间轴（重建要几十毫秒，点一下就卡一下）。
    $prev = [int]$script:App.SelectedRound
    $now = [int]$entry['round']
    if ($prev -ne $now) {
        Set-TlSelected -Round $prev -On $false
        Set-TlSelected -Round $now -On $true
        $script:App.SelectedRound = $now
    }
    # 标题区高度和行高都从 $script:DetailGdi 取，和 Paint 里用的是同一组数字，
    # 底部留 14；超出一屏就出滚动条。
    $gdi = $script:DetailGdi
    $headH = if ($gdi) { [int]$gdi.HeadH } else { 62 }
    $rowH = if ($gdi) { [int]$gdi.RowH } else { 26 }
    $panel.AutoScrollMinSize = New-Object System.Drawing.Size(0, ($headH + $rows.Count * $rowH + 14))
    $panel.Invalidate()
}

function Show-Gui {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    # 全局异常兜底：弹中文提示，不再出现 .NET JIT 崩溃对话框
    [System.Windows.Forms.Application]::SetUnhandledExceptionMode('CatchException')
    [System.Windows.Forms.Application]::add_ThreadException({
            param($s, $e)
            Set-Status ("出错：" + $e.Exception.Message) ([System.Drawing.Color]::Red)
            Show-GuiError -Context '出错了' -Detail $e.Exception
        })

    $font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'CS2 Demo 分析器'
    $form.Size = New-Object System.Drawing.Size(1660, 860)
    $form.StartPosition = 'CenterScreen'
    $form.Font = $font
    $form.MinimumSize = New-Object System.Drawing.Size(1240, 640)
    $form.BackColor = (Get-UiBg)

    # 根布局用 TableLayoutPanel，避免 Dock 顺序的歧义
    $uiRoot = New-Object System.Windows.Forms.TableLayoutPanel
    $uiRoot.Dock = 'Fill'
    $uiRoot.ColumnCount = 1
    $uiRoot.RowCount = 4
    $uiRoot.BackColor = (Get-UiBg)
    $uiRoot.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100))) | Out-Null
    $uiRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 122))) | Out-Null
    $uiRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 40))) | Out-Null
    $uiRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 116))) | Out-Null
    $uiRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100))) | Out-Null
    # ---- 主界面：左侧导航 + 右侧功能区 ----
    # 原来的界面整块塞进右侧「Demo 统计」页，其余页是后加的。
    # $uiRoot 仍是原来那个 TableLayoutPanel，只是爹从 $form 换成了 $pageDemo。
    $shell = New-Object System.Windows.Forms.TableLayoutPanel
    $shell.Dock = 'Fill'
    $shell.ColumnCount = 2
    $shell.RowCount = 1
    $shell.BackColor = (Get-UiBg)
    $shell.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute', 176))) | Out-Null
    $shell.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100))) | Out-Null
    $shell.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100))) | Out-Null
    $form.Controls.Add($shell)

    $nav = New-Object System.Windows.Forms.Panel
    $nav.Dock = 'Fill'
    $nav.BackColor = [System.Drawing.Color]::White
    $nav.Margin = New-Object System.Windows.Forms.Padding(4, 4, 2, 4)
    Enable-RoundCard -Control $nav -Radius 12
    $shell.Controls.Add($nav, 0, 0)

    $brand = New-Object System.Windows.Forms.Label
    $brand.Text = 'CS2 工具'
    $brand.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 13, [System.Drawing.FontStyle]::Bold)
    $brand.ForeColor = [System.Drawing.Color]::FromArgb(17, 24, 39)
    $brand.Location = New-Object System.Drawing.Point(18, 16)
    $brand.Size = New-Object System.Drawing.Size(150, 30)
    $nav.Controls.Add($brand)

    $pageHost = New-Object System.Windows.Forms.Panel
    $pageHost.Dock = 'Fill'
    $pageHost.BackColor = (Get-UiBg)
    $pageHost.Margin = New-Object System.Windows.Forms.Padding(2, 4, 4, 4)
    $shell.Controls.Add($pageHost, 1, 0)

    # 导航项：只做「显隐 + 高亮」切换。页面建好一次就一直留着，
    # 这样切回来时报告、时间轴选中状态都还在。
    $script:App.Nav = @{
        Items  = (New-Object System.Collections.ArrayList)
        Pages  = @{}
        Host   = $pageHost
        NavBar = $nav
        Active = $null
    }

    $uiRoot.Dock = 'Fill'
    $uiRoot.Margin = New-Object System.Windows.Forms.Padding(0)
    $pageDemo = New-Object System.Windows.Forms.Panel
    $pageDemo.Dock = 'Fill'
    $pageDemo.BackColor = (Get-UiBg)
    $uiRoot.Parent = $pageDemo
    $pageDemo.Controls.Add($uiRoot)
    $pageHost.Controls.Add($pageDemo)
    $script:App.Nav.Pages['demo'] = $pageDemo

    # ---- 第一行：操作区 ----
    $top = New-Object System.Windows.Forms.Panel
    $top.Dock = 'Fill'
    $top.BackColor = [System.Drawing.Color]::White
    $top.Margin = New-Object System.Windows.Forms.Padding(6, 4, 6, 3)
    Enable-RoundCard -Control $top -Radius 12
    $uiRoot.Controls.Add($top, 0, 0)

    $btnPick = New-RoundButton -Text '选择 demo 文件...' -X 12 -Y 12 -W 150 -H 32 -Back @(255, 255, 255) -Fore @(31, 41, 55) -Hover @(238, 243, 254) -Edge @(211, 217, 230)
    $top.Controls.Add($btnPick)

    $btnRun = New-RoundButton -Text '开始分析' -X 172 -Y 12 -W 110 -H 32 -Back @(37, 99, 235) -Fore @(255, 255, 255) -Hover @(29, 78, 216) -Edge @(37, 99, 235)
    $btnRun.Enabled = $false
    $top.Controls.Add($btnRun)

    $btnCsv = New-RoundButton -Text '导出 CSV' -X 292 -Y 12 -W 110 -H 32 -Back @(255, 255, 255) -Fore @(31, 41, 55) -Hover @(238, 243, 254) -Edge @(211, 217, 230)
    $btnCsv.Enabled = $false
    $top.Controls.Add($btnCsv)

    $lblFile = New-Object System.Windows.Forms.Label
    $lblFile.Location = New-Object System.Drawing.Point(12, 52)
    $lblFile.Size = New-Object System.Drawing.Size(1500, 18)
    $lblFile.Text = '未选择文件'
    $lblFile.AutoEllipsis = $true
    $top.Controls.Add($lblFile)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(12, 72)
    $lblStatus.Size = New-Object System.Drawing.Size(1500, 18)
    $lblStatus.Text = '就绪'
    $top.Controls.Add($lblStatus)

    # ---- 进度条 ----
    # 不用系统 ProgressBar：视觉样式会对 Value 变化做约 0.3 秒的补间动画，状态栏
    # 都报「100%」了条子还在慢慢追，看起来就是「跑到 100 不是满的，要等零点几秒」。
    # 换成自绘 Panel：Value 一变就 Invalidate，当场画满；配色和纹理也能自己定
    # （原来那条系统绿在浅色界面上太扎眼）。
    # 对外仍然暴露 Value / Minimum / Maximum（值存在 Tag 里，用 ScriptProperty
    # 转发到 Panel 上），所以所有调用点、以及 clicktest.ps1 里那句
    # $app.Bar.Value -eq 100 的断言，都不用改。
    $bar = New-Object System.Windows.Forms.Panel
    $bar.Location = New-Object System.Drawing.Point(12, 94)
    $bar.Size = New-Object System.Drawing.Size(1500, 18)
    $bar.Tag = @{ v = 0; min = 0; max = 100 }
    $bar | Add-Member -MemberType ScriptProperty -Name Value `
        -Value { [int]$this.Tag.v } `
        -SecondValue { param($x) $this.Tag.v = [int]$x; $this.Invalidate() }
    $bar | Add-Member -MemberType ScriptProperty -Name Minimum `
        -Value { [int]$this.Tag.min } `
        -SecondValue { param($x) $this.Tag.min = [int]$x; $this.Invalidate() }
    $bar | Add-Member -MemberType ScriptProperty -Name Maximum `
        -Value { [int]$this.Tag.max } `
        -SecondValue { param($x) $this.Tag.max = [int]$x; $this.Invalidate() }

    # ---- 绘制资源只建一次（同 $script:DetailGdi 的做法）----
    # 这些对象整个程序生命周期都用得上，放进 Paint 回调里 New-Object 会每次重绘
    # 漏一批 GDI 句柄（详情栏踩过这个坑）。
    if (-not $script:BarGdi) {
        # 斜条纹「贴图」：8x8 的小图，45 度半透明白条，平铺到填充区当纹理
        $tile = [System.Drawing.Bitmap]::new(8, 8)
        for ($ty = 0; $ty -lt 8; $ty++) {
            for ($tx = 0; $tx -lt 8; $tx++) {
                if ((($tx + $ty) % 8) -lt 3) {
                    $tile.SetPixel($tx, $ty, [System.Drawing.Color]::FromArgb(26, 255, 255, 255))
                }
            }
        }
        $stripe = [System.Drawing.TextureBrush]::new($tile)
        $stripe.WrapMode = [System.Drawing.Drawing2D.WrapMode]::Tile
        $script:BarGdi = @{
            PenEdge     = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(203, 208, 220), 1)
            PenCap      = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(147, 197, 253), 2)
            BrushTrack  = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(238, 240, 245))
            BrushStripe = $stripe
            Track       = $null
            TrackW      = -1
            Fill        = $null
            FillW       = -1
            Gradient    = $null
            Gloss       = $null
            GlossH      = -1
        }
    }

    $bar.Add_Paint({
            param($s, $e)

            # 同详情栏：Paint 回调触发时 Show-Gui 的局部变量早没了，状态只能从
            # 控件自己身上取（$s.Tag）和 $script:BarGdi。
            $gdi = $script:BarGdi
            $st = $s.Tag
            $g = $e.Graphics
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

            $w = $s.ClientSize.Width
            $h = $s.ClientSize.Height
            if ($w -lt 4 -or $h -lt 4) { return }
            $d = $h - 1

            # 轨道：两端半圆的胶囊，浅灰底 + 细边
            if (-not $gdi.Track -or $gdi.TrackW -ne $w) {
                if ($gdi.Track) { $gdi.Track.Dispose() }
                $pth = [System.Drawing.Drawing2D.GraphicsPath]::new()
                $pth.AddArc(0, 0, $d, $d, 90, 180)
                $pth.AddArc($w - $d - 1, 0, $d, $d, 270, 180)
                $pth.CloseFigure()
                $gdi.Track = $pth
                $gdi.TrackW = $w
            }
            $g.FillPath($gdi.BrushTrack, $gdi.Track)
            $g.DrawPath($gdi.PenEdge, $gdi.Track)

            if (-not $st) { return }
            $min = [int]$st.min
            $max = [int]$st.max
            if ($max -le $min) { return }
            $frac = [double](([int]$st.v) - $min) / ($max - $min)
            if ($frac -le 0) { return }
            if ($frac -gt 1) { $frac = 1 }
            $fw = [int][math]::Round($w * $frac)
            if ($fw -lt $h) { $fw = $h }   # 太短也画成一个圆头，别缩成一条竖线

            # 填充：蓝色横向渐变（#1D4ED8 -> #3B82F6），宽度变了才重建并回收旧的
            if (-not $gdi.Fill -or $gdi.FillW -ne $fw) {
                if ($gdi.Fill) { $gdi.Fill.Dispose() }
                if ($gdi.Gradient) { $gdi.Gradient.Dispose() }
                $fp = [System.Drawing.Drawing2D.GraphicsPath]::new()
                $fp.AddArc(0, 0, $d, $d, 90, 180)
                $fp.AddArc($fw - $d - 1, 0, $d, $d, 270, 180)
                $fp.CloseFigure()
                $gdi.Fill = $fp
                $gdi.FillW = $fw
                $gdi.Gradient = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
                    [System.Drawing.Rectangle]::new(0, 0, $fw, $h),
                    [System.Drawing.Color]::FromArgb(29, 78, 216),
                    [System.Drawing.Color]::FromArgb(59, 130, 246),
                    [System.Drawing.Drawing2D.LinearGradientMode]::Horizontal)
            }
            $g.FillPath($gdi.Gradient, $gdi.Fill)
            $g.FillPath($gdi.BrushStripe, $gdi.Fill)

            # 顶部一层高光（上亮下透），做出圆柱感
            if (-not $gdi.Gloss -or $gdi.GlossH -ne $h) {
                if ($gdi.Gloss) { $gdi.Gloss.Dispose() }
                $gdi.Gloss = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
                    [System.Drawing.Rectangle]::new(0, 0, 10, $h),
                    [System.Drawing.Color]::FromArgb(58, 255, 255, 255),
                    [System.Drawing.Color]::FromArgb(0, 255, 255, 255),
                    [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
                $gdi.GlossH = $h
            }
            $g.FillPath($gdi.Gloss, $gdi.Fill)

            # 前沿一道亮边，进度在跑的时候更醒目
            if ($fw -lt $w) { $g.DrawLine($gdi.PenCap, $fw - 2, 3, $fw - 2, $h - 4) }
    })
    $top.Controls.Add($bar)

    # ---- 第二行：半场选项 ----
    $pp = New-Object System.Windows.Forms.Panel
    $pp.Dock = 'Fill'
    $pp.BackColor = [System.Drawing.Color]::White
    $pp.Margin = New-Object System.Windows.Forms.Padding(6, 3, 6, 3)
    Enable-RoundCard -Control $pp -Radius 12
    $uiRoot.Controls.Add($pp, 0, 1)

    $lblHalf = New-Object System.Windows.Forms.Label
    $lblHalf.Text = '半场（可多选）：'
    $lblHalf.Location = New-Object System.Drawing.Point(14, 11)
    $lblHalf.Size = New-Object System.Drawing.Size(104, 20)
    $pp.Controls.Add($lblHalf)

    $cbFirst = New-Object System.Windows.Forms.CheckBox
    $cbFirst.Text = '上半场'
    $cbFirst.Location = New-Object System.Drawing.Point(122, 9)
    $cbFirst.Size = New-Object System.Drawing.Size(88, 22)
    $cbFirst.Checked = $true
    $pp.Controls.Add($cbFirst)

    $cbSecond = New-Object System.Windows.Forms.CheckBox
    $cbSecond.Text = '下半场'
    $cbSecond.Location = New-Object System.Drawing.Point(214, 9)
    $cbSecond.Size = New-Object System.Drawing.Size(88, 22)
    $pp.Controls.Add($cbSecond)

    $cbOvertime = New-Object System.Windows.Forms.CheckBox
    $cbOvertime.Text = '加时'
    $cbOvertime.Location = New-Object System.Drawing.Point(306, 9)
    $cbOvertime.Size = New-Object System.Drawing.Size(88, 22)
    $pp.Controls.Add($cbOvertime)

    $lblPeriodInfo = New-Object System.Windows.Forms.Label
    $lblPeriodInfo.Location = New-Object System.Drawing.Point(404, 12)
    $lblPeriodInfo.Size = New-Object System.Drawing.Size(660, 20)
    $lblPeriodInfo.ForeColor = [System.Drawing.Color]::DimGray
    $lblPeriodInfo.Text = '尚未分析'
    $pp.Controls.Add($lblPeriodInfo)

    $lblNote = New-Object System.Windows.Forms.Label
    $lblNote.Location = New-Object System.Drawing.Point(1070, 12)
    $lblNote.Size = New-Object System.Drawing.Size(440, 20)
    $lblNote.ForeColor = [System.Drawing.Color]::Gray
    $lblNote.Text = '（按开局阵营分队；中间分隔线可拖动，竖线 = 换边）'
    $pp.Controls.Add($lblNote)

    # ---- 第三行：时间轴（根据勾选半场联动） ----
    $tlHost = New-Object System.Windows.Forms.Panel
    $tlHost.Dock = 'Fill'
    $tlHost.BackColor = [System.Drawing.Color]::White
    $tlHost.Padding = New-Object System.Windows.Forms.Padding(6, 4, 6, 4)
    $tlHost.Margin = New-Object System.Windows.Forms.Padding(6, 3, 6, 3)
    Enable-RoundCard -Control $tlHost -Radius 12
    $uiRoot.Controls.Add($tlHost, 0, 2)

    $tlTitle = New-Object System.Windows.Forms.Label
    $tlTitle.Dock = 'Top'
    $tlTitle.Height = 18
    $tlTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5, [System.Drawing.FontStyle]::Bold)
    $tlTitle.Text = '时间轴 — 尚未分析'
    $tlTitle.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 60)

    $tlFlow = New-Object System.Windows.Forms.FlowLayoutPanel
    $tlFlow.Dock = 'Fill'
    $tlFlow.AutoScroll = $true
    $tlFlow.WrapContents = $false
    $tlFlow.FlowDirection = 'LeftToRight'
    $tlFlow.BackColor = [System.Drawing.Color]::White
    $tlFlow.Padding = New-Object System.Windows.Forms.Padding(0, 4, 0, 0)
    # 先加填充控件，后加停靠边控件 —— WinForms 的停靠是按 z 序「反着」处理的
    # （后 Add 的先停靠）。顺序反了 flow 会先占满整块，标题再压在它上面，
    # 结果时间轴最上面 18px 被标题盖住、第一排方块看不见。
    $tlHost.Controls.Add($tlFlow)
    $tlHost.Controls.Add($tlTitle)
    # 时间轴拖动：用「起点记录法」（记下按下时的滚动位置，再按总位移绝对定位），
    # 避免用增量 lastX 造成的"滑"与反向抖动。移动阈值 5 像素。
    #
    # 关键：卡片会盖住 flow，鼠标按在卡片上时 flow 收不到 MouseDown，所以卡片
    # （连同卡片里所有子控件）也挂同一份 $tlStartPan —— 按下后把鼠标捕获交给
    # flow，之后的 MouseMove / MouseUp 就都会送到 flow 上，拖动才真正可用。
    $tlStartPan = {
        param($s, $e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
        $d = $script:App._tlDrag
        $fl = $script:App.TimelineFlow
        if (-not $d -or -not $fl) { return }
        $d.pan = $true
        $d.moved = $false
        # 用「控件坐标 -> 屏幕坐标」而不是全局光标位置：起点可能在卡片上、
        # 移动事件却落在 flow 上，只有屏幕坐标才是同一套参照系。
        try { $d.startX = $s.PointToScreen($e.Location).X }
        catch { $d.startX = [System.Windows.Forms.Control]::MousePosition.X }
        # AutoScrollPosition 的取值是负的，这里统一换算成正的滚动偏移
        try { $d.startScroll = -[int]$fl.AutoScrollPosition.X } catch { $d.startScroll = 0 }
        try { $fl.Capture = $true } catch { }
        try { $fl.Cursor = [System.Windows.Forms.Cursors]::SizeWE } catch { }
    }
    $tlDoPan = {
        param($s, $e)
        $d = $script:App._tlDrag
        $fl = $script:App.TimelineFlow
        if (-not $d -or -not $fl -or -not $d.pan) { return }
        try { $curX = $s.PointToScreen($e.Location).X }
        catch { $curX = [System.Windows.Forms.Control]::MousePosition.X }
        $dx = [int]($d.startX - $curX)
        if (-not $d.moved) {
            if ([Math]::Abs($dx) -lt 5) { return }
            $d.moved = $true
        }
        $nv = [int]$d.startScroll + $dx
        if ($nv -lt 0) { $nv = 0 }
        try {
            $maxX = [int]$fl.HorizontalScroll.Maximum - [int]$fl.HorizontalScroll.LargeChange + 1
            if ($maxX -lt 0) { $maxX = 0 }
            if ($nv -gt $maxX) { $nv = $maxX }
            # AutoScroll 控件必须用 AutoScrollPosition 滚动；直接写
            # HorizontalScroll.Value 在 FlowLayoutPanel 上不会真正移动视图。
            $fl.AutoScrollPosition = New-Object System.Drawing.Point($nv, 0)
        } catch { }
    }
    $tlEndPan = {
        param($s, $e)
        $d = $script:App._tlDrag
        $fl = $script:App.TimelineFlow
        if (-not $d -or -not $fl -or -not $d.pan) { return }

        # 是「单击」还是「拖完松手」，必须在清标志之前判断
        $wasDrag = [bool]$d.moved
        $d.pan = $false
        $d.moved = $false
        try { $fl.Capture = $false } catch { }
        try { $fl.Cursor = [System.Windows.Forms.Cursors]::Default } catch { }
        try { $s.Cursor = [System.Windows.Forms.Cursors]::Default } catch { }

        # 单击（没拖动）-> 右侧「详细信息」面板。
        #
        # 这里必须自己命中测试，**不能**靠卡片自己的 Click 事件：
        # $tlStartPan 里给 flow 设了 $fl.Capture = $true，鼠标被 flow 抓走之后
        # 卡片再也收不到 MouseUp，WinForms 就不会给卡片发 Click ——
        # 表现就是「点时间轴卡片右侧没反应」。
        # MouseUp 一定会到（flow 挂着 $tlEndPan），所以判定放这里最稳。
        if ($wasDrag) { return }
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }

        $card = $null
        try {
            # 统一换成 flow 的客户区坐标：$s 可能是 flow，也可能是外面的 host
            $sp = $s.PointToScreen($e.Location)
            $card = $fl.GetChildAtPoint($fl.PointToClient($sp))
        } catch { }
        if (-not $card) { return }

        $rn = 0
        try { $rn = [int]$card.AccessibleDescription } catch { }
        if ($rn -gt 0) { Render-Detail -Report $script:App.Report -Round $rn }
    }
    $tlHost.Add_MouseDown($tlStartPan)
    $tlHost.Add_MouseMove($tlDoPan)
    $tlHost.Add_MouseUp($tlEndPan)
    $tlHost.Add_MouseLeave({
            param($s, $e)
            $d = $script:App._tlDrag
            if ($d -and -not $d.pan) {
                try { $script:App.TimelineFlow.Cursor = [System.Windows.Forms.Cursors]::Default } catch { }
                $s.Cursor = [System.Windows.Forms.Cursors]::Default
            }
        })
    # flow 本身也挂一套，卡片之外的空白区域直接走 flow 的事件
    $tlFlow.Add_MouseDown($tlStartPan)
    $tlFlow.Add_MouseMove($tlDoPan)
    $tlFlow.Add_MouseUp($tlEndPan)
    $script:App._tlStartPan = $tlStartPan

    $tt = New-Object System.Windows.Forms.ToolTip
    # AutoPopDelay 上限就是 32767（int16），设更大不会生效。
    # 原来是 15000 —— 悬停 15 秒后气泡自动消失，用户反馈「过一会详细信息就没了」。
    $tt.AutoPopDelay = 32767
    $tt.InitialDelay = 400
    $tt.ReshowDelay = 200
    $tt.ShowAlways = $true
    $tt.IsBalloon = $false

    $script:App.TimelineHost = $tlHost
    $script:App.TimelineFlow = $tlFlow
    $script:App.TimelineLbl = $tlTitle
    $script:App.TimelineTip = $tt

    # ---- 第四行：左边三个页签（每页上下两队），右边「详细信息」面板 ----
    $row4 = New-Object System.Windows.Forms.Panel
    $row4.Dock = 'Fill'
    $row4.BackColor = (Get-UiBg)
    $uiRoot.Controls.Add($row4, 0, 3)

    [void]$script:App.Splits.Clear()
    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = 'Fill'
    $tabs.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
    # 页签自绘：上面两角圆。选中页签用页面底色（融进页面），未选中浅一档 + 描边。
    $tabs.DrawMode = [System.Windows.Forms.TabDrawMode]::OwnerDrawFixed
    $tabs.SizeMode = [System.Windows.Forms.TabSizeMode]::Fixed
    $tabs.ItemSize = New-Object System.Drawing.Size(132, 34)
    $tabs.Padding = New-Object System.Drawing.Point(14, 4)
    $tabs.Add_DrawItem({
            param($s, $e)
            $i = [int]$e.Index
            if ($i -lt 0 -or $i -ge $s.TabPages.Count) { return }
            $b = $e.Bounds
            $rect = New-Object System.Drawing.Rectangle($b.X, ($b.Y + 4), ($b.Width - 4), ($b.Height - 4))
            if ($rect.Width -lt 4 -or $rect.Height -lt 4) { return }
            $g = $e.Graphics
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $sel = ($i -eq $s.SelectedIndex)
            $p = Get-RoundTopPath -W $rect.Width -H $rect.Height -R 10
            $br = $null
            $pen = $null
            try {
                if ($sel) {
                    $br = [System.Drawing.SolidBrush]::new((Get-UiBg))
                } else {
                    $br = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(228, 232, 241))
                    $pen = [System.Drawing.Pen]::new((Get-UiEdge), 1)
                }
                $g.FillPath($br, $p)
                if ($pen) { $g.DrawPath($pen, $p) }
                $col = if ($sel) { [System.Drawing.Color]::FromArgb(37, 99, 235) } else { [System.Drawing.Color]::FromArgb(85, 95, 112) }
                [System.Windows.Forms.TextRenderer]::DrawText($g, $s.TabPages[$i].Text, $s.Font, $rect, $col,
                    ([System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter))
            } finally {
                if ($br) { $br.Dispose() }
                if ($pen) { $pen.Dispose() }
                $p.Dispose()
            }
        })
    [void]$tabs.TabPages.Add((New-TeamPage -Title '主要数据' -Key 'main' -Cols $ColsMain -Font $font))
    [void]$tabs.TabPages.Add((New-TeamPage -Title '道具伤害' -Key 'util' -Cols $ColsUtil -Font $font))
    [void]$tabs.TabPages.Add((New-TeamPage -Title '娱乐数据' -Key 'fun' -Cols $ColsFun -Font $font))
    # 停靠顺序：Fill 必须先加，停靠边的后加（WinForms 按 z 序反着处理停靠）
    $row4.Controls.Add($tabs)
    $detail = New-DetailPanel -Font $font
    $row4.Controls.Add($detail)
    $script:App.DetailPanel = $detail

    # 登记到脚本作用域，供回调使用
    $script:App.Form = $form
    $script:App.Tabs = $tabs
    $script:App.Status = $lblStatus
    $script:App.FileLbl = $lblFile
    $script:App.BtnRun = $btnRun
    $script:App.BtnPick = $btnPick
    $script:App.BtnCsv = $btnCsv
    $script:App.Bar = $bar
    $script:App.PeriodInfo = $lblPeriodInfo
    $script:App.Py = Find-Python

    # 半场多选：勾任意一个都重新渲染；加防抖，避免快速连点时反复重建控件卡死
    $viewTimer = New-Object System.Windows.Forms.Timer
    $viewTimer.Interval = 120
    $viewTimer.Add_Tick({
            # 这里绝对不能直接用 $viewTimer：它是 Show-Gui 的局部变量，
            # Show-Gui 返回后作用域就没了，回调里会退化成 $null，
            # 于是每次 tick 都抛「不能对 Null 值表达式调用方法」并无限弹窗。
            # 必须走 $script:App 上的引用。
            $t = $script:App._viewTimer
            if ($t) { $t.Stop() }
            if ($script:App._suspendView) { return }
            Render-View -Report $script:App.Report
        })
    $script:App._viewTimer = $viewTimer
    foreach ($pair in @(@('first', $cbFirst), @('second', $cbSecond), @('overtime', $cbOvertime))) {
        $key = $pair[0]
        $cb = $pair[1]
        $cb.Tag = $key
        $script:App.Checks[$key] = $cb
        $cb.Add_CheckedChanged([System.EventHandler]{
                param($s, $e)
                if ($script:App._suspendView) { return }
                $t = $script:App._viewTimer
                if ($t) { $t.Stop(); $t.Start() }
                else { Render-View -Report $script:App.Report }
            })
    }

    if (-not $script:App.Py) {
        Set-Status '错误：找不到 python.exe，请先安装 Python 3.10+' ([System.Drawing.Color]::Red)
    }

    # SplitterDistance 只能在控件已有真实尺寸之后设置，否则会抛
    # 「SplitterDistance 必须介于 Panel1MinSize 和 Panel2MinSize 之间」。
    # 所以放到 Shown 里，此时布局已经算完。
    # 方向要对：Horizontal 是上下分，按高度对半；Vertical 才是按宽度对半。
    $form.Add_Shown([System.EventHandler]{
            foreach ($sp in $script:App.Splits) {
                try {
                    if ($sp.Orientation -eq 'Horizontal') { $span = [int]$sp.Height }
                    else { $span = [int]$sp.Width }
                    if ($span -gt 400) { $sp.SplitterDistance = [int]($span / 2) }
                }
                catch { }
            }
        })

    $btnPick.Add_Click({
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Filter = 'CS demo (*.dem)|*.dem|所有文件 (*.*)|*.*'
            $dlg.Title = '选择 CS2 demo 文件'
            if ($dlg.ShowDialog() -eq 'OK') {
                $script:App.Demo = $dlg.FileName
                $script:App.FileLbl.Text = $script:App.Demo
                $script:App.BtnRun.Enabled = $true
                Set-Status '已选择文件，点「开始分析」' ([System.Drawing.Color]::Black)
            }
        })

    $btnRun.Add_Click({
            if (-not $script:App.Demo) { return }
            $script:App.BtnRun.Enabled = $false
            $script:App.BtnCsv.Enabled = $false
            $script:App.BtnPick.Enabled = $false
            $script:App.Report = $null
            Render-View -Report $null
            $script:App.Bar.Value = 0
            Set-Status '正在分析…' ([System.Drawing.Color]::DarkOrange)
            [System.Windows.Forms.Application]::DoEvents()

            $progFile = Get-ProgressPath
            $logFile = Get-LogPath

            $proc = $null
            try {
                # 直接起 python（隐藏窗口），主线程泵消息推动进度条
                $proc = Start-AnalysisProcess -Py $script:App.Py -Demo $script:App.Demo `
                    -JsonOut $OutJson -ProgFile $progFile -LogFile $logFile

                $lastPct = -1
                while (-not $proc.HasExited) {
                    [System.Windows.Forms.Application]::DoEvents()
                    $p = Read-Progress -ProgFile $progFile
                    if ($p -and [int]$p.pct -ne $lastPct) {
                        $lastPct = [int]$p.pct
                        if ($lastPct -gt $script:App.Bar.Value -and $lastPct -le 100) {
                            $script:App.Bar.Value = $lastPct
                        }
                        Set-Status ("正在分析… {0}%  {1}" -f $p.pct, $p.stage) `
                            ([System.Drawing.Color]::DarkOrange)
                        [System.Windows.Forms.Application]::DoEvents()
                    }
                    Start-Sleep -Milliseconds 80
                }
                $code = $proc.ExitCode
                # 分析进程常常在写完 100 之后立刻就退出，轮询循环来不及读到那一拍，
                # 条子会停在 98/99。收尾再读一次，把最后一个数补上。
                $p = Read-Progress -ProgFile $progFile
                if ($p -and [int]$p.pct -gt $script:App.Bar.Value -and [int]$p.pct -le 100) {
                    $script:App.Bar.Value = [int]$p.pct
                }
            }
            catch {
                Set-Status ('分析失败：' + $_.Exception.Message) ([System.Drawing.Color]::Red)
                Show-GuiError -Context '分析失败' -Detail $_
                $script:App.Bar.Value = 0
                $script:App.BtnRun.Enabled = $true
                $script:App.BtnPick.Enabled = $true
                return
            }
            finally {
                if ($proc) { $proc.Dispose() }
            }

            try {
                Assert-AnalysisOk -JsonOut $OutJson -LogFile $logFile -Code $code
                # 分析进程已经正常退出，进度就是 100%。必须放在 Load-Report /
                # Render-View 之前设：那两步要花零点几秒，放后面就会出现「状态栏
                # 都报完成、条子还差最后几格」。
                $script:App.Bar.Value = 100
                Set-Status '正在分析… 100%  读取报告' ([System.Drawing.Color]::DarkOrange)
                [System.Windows.Forms.Application]::DoEvents()
                $rep = Load-Report -JsonPath $OutJson
                $script:App.Report = $rep
                # 换了 demo，右侧详情面板回到「点一下卡片」的空状态
                Render-Detail -Report $null

                # 默认落在上半场（暂停事件，避免三次 CheckedChanged 触发三次重绘）
                $script:App._suspendView = $true
                try {
                    foreach ($k in $PeriodOrder) {
                        if ($script:App.Checks[$k]) { $script:App.Checks[$k].Checked = ($k -eq 'first') }
                    }
                } finally { $script:App._suspendView = $false }
                Render-View -Report $rep

                $d = $rep['demo']
                Set-Status ('完成 — 地图 {0}｜回合 {1}｜玩家 {2}｜总击杀 {3}' -f `
                        $d['map'], $d['rounds'], $d['players'], $d['total_kills']) `
                    ([System.Drawing.Color]::ForestGreen)
                $script:App.BtnCsv.Enabled = $true
            }
            catch {
                $script:App.Bar.Value = 0
                Set-Status ('分析失败：' + $_.Exception.Message) ([System.Drawing.Color]::Red)
                Show-GuiError -Context '分析失败' -Detail $_
            }
            finally {
                $script:App.BtnRun.Enabled = $true
                $script:App.BtnPick.Enabled = $true
            }
        })

    # 导出当前「勾选的半场 + 当前页」的上下两队
    $btnCsv.Add_Click({
            if (-not $script:App.Report) { return }
            $pg = $script:App.Tabs.SelectedTab
            if (-not $pg) { return }
            $pk = [string]$pg.Tag
            $cols = $script:App.Cols[$pk]

            $sel = @(Get-CheckedPeriods)
            if ($sel.Count -eq 0) {
                [System.Windows.Forms.MessageBox]::Show('请至少勾选一个半场', '导出',
                    'OK', 'Information') | Out-Null
                return
            }
            $m = Merge-Periods -Report $script:App.Report -Keys $sel
            $names = @()
            foreach ($k in $sel) { $names += $PeriodNames[$k] }
            $plabel = $names -join '+'
            $tag = $sel -join '_'

            $dlg = New-Object System.Windows.Forms.SaveFileDialog
            $dlg.Filter = 'CSV (*.csv)|*.csv'
            $dlg.FileName = ('demo统计_{0}_{1}.csv' -f $tag, $pk)
            if ($dlg.ShowDialog() -ne 'OK') { return }

            $sb = New-Object System.Text.StringBuilder
            $head = @('队伍', '半场') + ($cols | ForEach-Object { $_.H })
            [void]$sb.AppendLine(($head -join ','))

            foreach ($rid in @('A', 'B')) {
                $players = @($m[$rid])
                $tname = $script:App.Report['teams'][$rid]['label']
                foreach ($p in $players) {
                    $row = @($tname, $plabel)
                    foreach ($c in $cols) {
                        $v = [string]$p[$c.K]
                        if ($v -match '[,"]') { $v = '"' + ($v -replace '"', '""') + '"' }
                        $row += $v
                    }
                    [void]$sb.AppendLine(($row -join ','))
                }
            }
            [System.IO.File]::WriteAllText($dlg.FileName, $sb.ToString(),
                (New-Object System.Text.UTF8Encoding($true)))
            Set-Status ('已导出：' + $dlg.FileName)
        })

    if ($DemoPath) {
        $script:App.Demo = $DemoPath
        $script:App.FileLbl.Text = $DemoPath
        $script:App.BtnRun.Enabled = $true
    }

    # ---- 导航项 ----
    # 每项一个页面。demo 页已经建好（就是原界面），其余页在这个函数里现场建。
    Add-NavItem -Key 'demo' -Text 'Demo 统计' -Y 62 -Select | Out-Null

    $pageHltv = New-PickemPage
    $script:App.Nav.Pages['hltv'] = $pageHltv
    $pageHost.Controls.Add($pageHltv)
    Add-NavItem -Key 'hltv' -Text 'Major Pick''em' -Y 104 | Out-Null

    $pageAbout = New-AboutPage
    $script:App.Nav.Pages['about'] = $pageAbout
    $pageHost.Controls.Add($pageAbout)
    Add-NavItem -Key 'about' -Text '关于' -Y 146 | Out-Null

    Render-PickemPage -Page $pageHltv

    Show-Page -Key 'demo'

    # ---- 整棵控件树开双缓冲 ----
    # 放在最后统一开：这时所有控件都建好了，包括两个 DataGridView。
    # 表格是重绘大头（每张约 11ms），拖分隔条时它俩会跟着实时改尺寸，
    # 不开双缓冲就是一边闪一边卡。时间轴那些列是之后动态建的，
    # 已经在 Render-Timeline 里单独开过了。
    Enable-DoubleBufferTree $form

    return $form
}

# ---------------- 入口 ----------------
if ($SelfTest) {
    $f = Show-Gui

    Write-Output ("SelfTest 窗体 OK  控件数={0}" -f $f.Controls.Count)
    # 导航壳：左侧三项，右侧是对应页面
    $nav0 = $script:App.Nav
    Write-Output ("SelfTest 导航栏 OK  项数={0}  当前={1}" -f $nav0.Items.Count, $nav0.Active)
    $navNames = ($nav0.Items | ForEach-Object { $_.Key }) -join '/'
    Write-Output ("SelfTest 导航项 OK  {0}" -f $navNames)

    # Major Pick em 页：四个阶段页签 + 已排好的首轮对阵
    $hpage = $nav0.Pages['hltv']
    $hdata = $hpage.Tag.Data
    $hstages = @($hpage.Tag.Stages)
    $htabs = $hpage.Tag.Tabs
    if ($hdata -and $hstages.Count -eq 3) {
        Write-Output ("SelfTest Pickem页 OK  赛事={0}  页签={1}" -f `
                $hdata.event, (($htabs.TabPages | ForEach-Object { $_.Text }) -join '/' ))
        foreach ($st in $hstages) {
            $alive = @($st.TeamList | Where-Object { $_.Status -eq 'alive'  }).Count
            Write-Output ("SelfTest {0} OK  队伍={1}  对阵={2}  进行中={3}" -f `
                    $st.Name, @($st.TeamList).Count, @($st.Matches).Count, $alive)
        }
        $hlogo = 0
        $alln = @($hstages[0].TeamList | ForEach-Object { $_.Name })
        foreach ($n in $alln) { if (Get-TeamLogo -Name $n) { $hlogo++ } }
        Write-Output ("SelfTest Pickem Logo OK  {0}/{1}" -f $hlogo, $alln.Count)
    } else {
        Write-Output "SelfTest Pickem页 SKIP  没有 data/all-stages.json"
    }
    Write-Output ("SelfTest 分页 OK  页数={0}  页名={1}" -f `
            $script:App.Tabs.TabPages.Count,
        (($script:App.Tabs.TabPages | ForEach-Object { $_.Text }) -join '/'))

    $ngrid = 0
    foreach ($pk in @('main', 'util', 'fun')) { $ngrid += $script:App.Grids[$pk].Count }
    # 这里只断言方向：几何（Panel2 在 Panel1 下方、两表等宽）要等窗体真正
    # 显示、布局算完之后才成立，那部分由 dragtest.ps1 的第 0 节覆盖。
    $sp0 = $script:App.Splits[0]
    $orientOk = ($sp0.Orientation -eq 'Horizontal')
    Write-Output ("SelfTest 上下分栏 {0}  表格数={1}  方向={2}（Horizontal = 队伍1 在上、队伍2 在下）" -f `
            $(if ($orientOk) { 'OK' } else { 'FAIL' }), $ngrid, $sp0.Orientation)

    $ncheck = 0
    $checkedList = @()
    foreach ($k in $PeriodOrder) {
        $ncheck++
        if ($script:App.Checks[$k].Checked) { $checkedList += $k }
    }
    Write-Output ("SelfTest 半场选项 OK  个数={0}  可多选=True  默认勾选={1}" -f `
            $ncheck, ($checkedList -join ','))

    Write-Output ("SelfTest 可拖动分栏 OK  分栏数={0}  可拖动={1}" -f `
            $script:App.Splits.Count,
        (@($script:App.Splits) | Where-Object { -not $_.IsSplitterFixed }).Count)

    # 表头悬浮说明：用户问的「团队伤害是啥 / 占比%是啥」就写在这里
    $tipUtil = @($script:App.Grids['util']['A'].Columns | Where-Object { $_.HeaderText -eq '占比%' })
    $tipFun = @($script:App.Grids['fun']['A'].Columns | Where-Object { $_.HeaderText -eq '团队伤害' })
    $tipRat = @($script:App.Grids['main']['A'].Columns | Where-Object { $_.HeaderText -eq 'Rating' })
    Write-Output ("SelfTest 列提示 OK  占比%={0}字  团队伤害={1}字  Rating={2}字" -f `
            $tipUtil[0].HeaderCell.ToolTipText.Length,
        $tipFun[0].HeaderCell.ToolTipText.Length,
        $tipRat[0].HeaderCell.ToolTipText.Length)

    Write-Output ("SelfTest 进度条 OK  存在={0}  范围={1}-{2}" -f `
            ($null -ne $script:App.Bar), $script:App.Bar.Minimum, $script:App.Bar.Maximum)

    if (Test-Path $OutJson) {
        $rep = Load-Report -JsonPath $OutJson
        $script:App.Report = $rep
        $script:App.Checks['first'].Checked = $true
        $script:App.Checks['second'].Checked = $false
        $script:App.Checks['overtime'].Checked = $false
        Render-View -Report $rep
        $gA = $script:App.Grids['main']['A']
        $gB = $script:App.Grids['main']['B']
        Write-Output ("SelfTest 数据绑定 OK  队伍1行数={0}  队伍2行数={1}" -f `
                $gA.Rows.Count, $gB.Rows.Count)
        if ($gA.Rows.Count -gt 0) {
            Write-Output ("  队伍1首行: " + (($gA.Rows[0].Cells | ForEach-Object { $_.Value }) -join ' | '))
        }
        $sumA = 0
        foreach ($r in $gA.Rows) { $sumA += [int]$r.Cells[2].Value }
        Write-Output ("SelfTest 上半场队伍1合计击杀 = {0}" -f $sumA)

        # 多选：上半场 + 下半场 = 全场，击杀应当是两段之和
        $script:App.Checks['first'].Checked = $true
        $script:App.Checks['second'].Checked = $true
        Render-View -Report $rep
        $both = 0
        foreach ($r in $script:App.Grids['main']['A'].Rows) { $both += [int]$r.Cells[2].Value }
        Write-Output ("SelfTest 上下半场叠加 OK  队伍1行数={0}  合计击杀={1}  说明={2}" -f `
                $script:App.Grids['main']['A'].Rows.Count, $both, $script:App.PeriodInfo.Text)

        # 全不勾：应当清空并提示
        foreach ($k in $PeriodOrder) { $script:App.Checks[$k].Checked = $false }
        Render-View -Report $rep
        Write-Output ("SelfTest 全不勾 OK  队伍1行数={0}  说明={1}" -f `
                $script:App.Grids['main']['A'].Rows.Count, $script:App.PeriodInfo.Text)

        $script:App.Checks['first'].Checked = $true
        $script:App.Checks['overtime'].Checked = $true
        Render-View -Report $rep
        Write-Output ("SelfTest 上半场+加时 OK  队伍1行数={0}  说明={1}" -f `
                $script:App.Grids['main']['A'].Rows.Count, $script:App.PeriodInfo.Text)
    }
    else {
        Write-Output "（没有 $OutJson，跳过数据绑定测试）"
    }
    $f.Dispose()
    exit 0
}

if ($Cli) {
    $py = Find-Python
    if (-not $py) { throw '找不到 python.exe' }
    if (-not $DemoPath) { throw '请用 -DemoPath 指定 demo 文件' }
    Write-Output "python : $py"
    Write-Output "demo   : $DemoPath"
    $t0 = Get-Date
    Invoke-Analysis -Py $py -Demo $DemoPath -JsonOut $OutJson
    $rep = Load-Report -JsonPath $OutJson
    $d = $rep['demo']
    Write-Output ("完成，用时 {0:N1}s" -f ((Get-Date) - $t0).TotalSeconds)
    Write-Output ("地图={0} 回合={1} 玩家={2} 总击杀={3}" -f `
            $d['map'], $d['rounds'], $d['players'], $d['total_kills'])
    Write-Output ("队伍1 = {0}（开局 {1}）  队伍2 = {2}（开局 {3}）" -f `
            $rep['teams']['A']['label'], $rep['teams']['A']['start_side'],
        $rep['teams']['B']['label'], $rep['teams']['B']['start_side'])
    foreach ($k in $PeriodOrder) {
        $p = $rep['periods'][$k]
        $na = @($p['teams']['A']['players']).Count
        $nb = @($p['teams']['B']['players']).Count
        Write-Output ("  {0}: 回合={1} 区间={2}-{3} 有数据={4} 队伍1={5}人 队伍2={6}人" -f `
                $p['label'], $p['rounds'], $p['first_round'], $p['last_round'],
            $p['has_data'], $na, $nb)
    }
    Write-Output "报告: $OutJson"
    exit 0
}

$form = Show-Gui

# 启动时如果已经有上次的分析结果，先渲染出来，窗口不会是空白等着的。
$hasReport = $false
if (Test-Path $OutJson) {
    try {
        $rep0 = Load-Report -JsonPath $OutJson
        $script:App.Report = $rep0
        Render-View -Report $rep0
        $hasReport = $true
    } catch {
        Show-GuiError -Context '启动时加载已有报告失败' -Detail $_.Exception.Message
    }
}

# -AutoRun：启动后自动进入「已识别完 demo」的状态。
# 已经有报告就直接显示；没有报告才自动跑一次分析。跑完窗口留着不关。
if ($AutoRun -and -not $hasReport) {
    $form.Add_Shown({
            param($s, $e)
            try {
                $script:App.BtnRun.Enabled = $true
                $script:App.BtnRun.PerformClick()
            } catch {
                Show-GuiError -Context 'AutoRun 启动分析失败' -Detail $_.Exception.Message
            }
        })
}

[void]$form.ShowDialog()
$form.Dispose()
