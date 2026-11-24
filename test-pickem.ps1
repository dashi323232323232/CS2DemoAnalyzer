# test-pickem.ps1 — 用 HLTV 真实赛果验证 Swiss 规则实现
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
. (Join-Path $here 'src\pickem.ps1')

$script:fail = 0
function Chk($name, $cond, $detail) {
    if ($cond) { "  OK   $name  $detail" } else { "  FAIL $name  $detail"; $script:fail++ }
}

function PairKey($a, $b) {
    return ((@($a, $b) | Sort-Object { $_.ToLowerInvariant() }) -join '|').ToLower()
}

$data = Get-Content (Join-Path $here 'data\all-stages.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$s1 = $data.stages[0]

"==== Swiss 规则验证（Stage 1，HLTV 真实数据）===="

$teams = @()
foreach ($t in $s1.teams) { $teams += @{ name=$t.name; teamId=$t.teamId; logo=$t.logo; seed=$t.seed } }
$st = New-SwissStage -Name 'Stage 1' -Teams $teams
Add-SwissRound -Stage $st

Chk '首轮场次' (@($st.Matches).Count -eq 8) ("count=" + @($st.Matches).Count)

$diffs = @()
foreach ($m in @($st.Matches)) {
    $diffs += [Math]::Abs([int]$st.Teams[$m.A].Seed - [int]$st.Teams[$m.B].Seed)
}
Chk '首轮种子差=8' (($diffs | Where-Object { $_ -ne 8 }).Count -eq 0) ("diffs=" + ($diffs -join ','))

$res1 = @(
    @('HEROIC', 'Imperial', 'Imperial'),
    @('9z', 'Lynn Vision', 'Lynn Vision'),
    @('Ninjas in Pyjamas', 'M80', 'Ninjas in Pyjamas'),
    @('100 Thieves', 'Chinggis Warriors', '100 Thieves'),
    @('Liquid', 'BC.Game', 'Liquid'),
    @('PARIVISION', 'DENDELE', 'PARIVISION'),
    @('FaZe', 'Wildcard', 'Wildcard'),
    @('Eternal Fire', 'FlyQuest', 'FlyQuest')
)

$real1 = @{}
foreach ($r in $res1) { $real1[(PairKey $r[0] $r[1])] = $true }

$mine1 = 0
foreach ($m in @($st.Matches)) {
    $k = PairKey $m.A $m.B
    if ($real1.ContainsKey($k)) { $mine1++ }
    $hits = @($res1 | Where-Object { (PairKey $_[0] $_[1]) -eq $k })
    if ($hits.Count -gt 0) {
        # 注意：PowerShell 会把单元素数组摊平，$hits[0] 已经是内层数组，
        # 不要再写 $hits[0][2]（那是取字符串第 3 个字符）。
        $w = $hits[0][2]
        $side = if ($m.A -eq $w) { 'A' } else { 'B' }
        Set-SwissWinner -Stage $st -Match $m -Side $side | Out-Null
    } else {
        "  WARN 未找到赛果: $k"
    }
}
Chk '首轮对阵' ($mine1 -eq 8) ("命中=$mine1/8")

Update-SwissStage -Stage $st | Out-Null

# 第 2 轮：打了 1 场的队伍，战绩只能是 1-0 或 0-1。
# （2-0 / 1-1 / 0-2 是第 3 轮的事，别混。）
$r2m = @($st.Matches | Where-Object { -not $_.Winner })
$r2buckets = @($r2m | ForEach-Object { '{0}-{1}' -f $_.W, $_.L } | Sort-Object -Unique)
Chk '第2轮分 1-0 / 0-1' ((($r2buckets -contains '1-0') -and ($r2buckets -contains '0-1')) -and $r2buckets.Count -eq 2) ("buckets=" + ($r2buckets -join ','))
Chk '第2轮场次' (@($st.Matches).Count -eq 16) ("total=" + @($st.Matches).Count)
Chk '第2轮每组 4 场' ((@($r2m | Where-Object { $_.W -eq 1 }).Count -eq 4) -and (@($r2m | Where-Object { $_.W -eq 0 }).Count -eq 4)) ("1-0组=" + @($r2m | Where-Object { $_.W -eq 1 }).Count + "  0-1组=" + @($r2m | Where-Object { $_.W -eq 0 }).Count)

# 第 2 轮真实对阵 = 一胜组 + 零胜组（HLTV 的 OneZero / ZeroOne）
$real2 = @{}
foreach ($m in @($s1.matches | Where-Object { $_.bucket -eq 'OneZero' -or $_.bucket -eq 'ZeroOne' })) {
    $real2[(PairKey $m.a $m.b)] = $true
}
$round2 = @($st.Matches | Where-Object { -not $_.Winner })
$mine2 = 0
foreach ($m in $round2) {
    if ($real2.ContainsKey((PairKey $m.A $m.B))) { $mine2++ }
}
Chk '第2轮对阵' ($mine2 -eq 8) ("命中=$mine2/8 (共 $($round2.Count) 场)")

if ($script:fail -eq 0) { "" ; "TEST-PICKEM OK" } else { "" ; "TEST-PICKEM FAILED ($script:fail)" }
exit $script:fail
