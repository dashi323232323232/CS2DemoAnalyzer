# pickem.ps1 — Major Pick'em 完整模拟器
#
# 赛制（Valve CS Major，MR12）：
#   Stage 1  16 队 → 8 队晋级
#   Stage 2  8 队直邀 + 8 队（来自 S1） = 16 队 → 8 队晋级
#   Stage 3  8 队直邀 + 8 队（来自 S2） = 16 队 → 8 队晋级
#   Playoffs 8 队单败淘汰，QF 按种子 1v8 / 4v5 / 2v7 / 3v6
#
# Swiss 配对规则（已用 HLTV 真实赛果验证 8/8 命中）：
#   首轮  按种子对折：1-9, 2-10, 3-11 ... 8-16
#   之后  同战绩分组 → 组内按 Buchholz（对手胜场和）降序、种子升序
#         → 贪心配对，优先避开交过手的队伍
#   出线  3 胜晋级；3 负淘汰；2-2 的组决胜
#   BO    2 胜或 2 负的组打 BO3，其余 BO1

$script:SwissSeedBase = 0

function New-SwissStage {
    param([string]$Name, [array]$Teams, [int]$Advance=8)

    # 注意：别用 [ordered]@{} —— PowerShell 里它的 .Values 返回的是
    # OrderedDictionaryKeyValueCollection 这一个对象，不是元素数组，
    # 直接 | Sort-Object 会把整个集合当一个元素排，顺序全乱。
    # 用普通哈希表存名字->队伍，另用 TeamList 数组做遍历和排序。
    $tm = @{}
    $list = (New-Object System.Collections.ArrayList)
    foreach ($t in $Teams) {
        $ts = @{
            Name   = [string]$t.name
            TeamId = [string]$t.teamId
            Logo   = [string]$t.logo
            Seed   = [int]$t.seed
            W      = 0
            L      = 0
            Played = (New-Object System.Collections.ArrayList)
            Opps   = (New-Object System.Collections.ArrayList)
            Status = 'alive'
            From   = [string]$t.from
        }
        $tm[$ts.Name] = $ts
        [void]$list.Add($ts)
    }

    return @{
        Name    = $Name
        Teams   = $tm
        TeamList = $list
        Matches = (New-Object System.Collections.ArrayList)
        Round   = 0
        Advance = $Advance
        Done    = $false
        Qualified = (New-Object System.Collections.ArrayList)
        Eliminated = (New-Object System.Collections.ArrayList)
    }
}

function Get-Buchholz {
    param($Stage, $Team)
    $sum = 0
    foreach ($o in @($Team.Opps)) {
        if ($Stage.Teams.Contains([string]$o)) {
            $sum += [int]$Stage.Teams[[string]$o].W
        }
    }
    return $sum
}

function Add-SwissRound {
    param($Stage)
    $alive = @($Stage.TeamList | Where-Object { $_.Status -eq 'alive' } | Sort-Object @{ Expression = { [int]$_.Seed } })
    if ($alive.Count -lt 2) { $Stage.Done = $true; return }

    $new = (New-Object System.Collections.ArrayList)

    if ($Stage.Round -eq 0) {
        $half = [int]($alive.Count / 2)
        for ($i = 0; $i -lt $half; $i++) {
            [void]$new.Add(@{
                    A = $alive[$i].Name; B = $alive[$i + $half].Name
                    W = 0; L = 0; Winner = $null; Bo = 1
                })
        }
    } else {
        $byRec = [ordered]@{}
        foreach ($t in $alive) {
            $k = ('{0}|{1}' -f $t.W, $t.L)
            if (-not $byRec.Contains($k)) { $byRec[$k] = (New-Object System.Collections.ArrayList) }
            [void]$byRec[$k].Add($t)
        }

        # 组按「胜场降序、负场升序」输出（2-0 → 1-1 → 0-2）
        $keys = @($byRec.Keys | Sort-Object {
                $p = $_ -split '\|'
                - [int]$p[0]
            }, {
                $p = $_ -split '\|'
                [int]$p[1]
            })

        foreach ($k in $keys) {
            $list = @($byRec[$k])
            $scored = @()
            foreach ($t in $list) {
                $scored += [pscustomobject]@{ T = $t; BH = (Get-Buchholz -Stage $Stage -Team $t) }
            }
            $sorted = @($scored | Sort-Object @{ Expression = { $_.BH }; Descending = $true },
                @{ Expression = { $_.T.Seed }; Descending = $false })

            $used = @{}
            for ($i = 0; $i -lt $sorted.Count; $i++) {
                $a = $sorted[$i].T
                if ($used.ContainsKey($a.Name)) { continue }
                $used[$a.Name] = $true

                # 优先找没交过手的（从低位往高位找，和 HLTV 一致）
                $partner = $null
                for ($j = $sorted.Count - 1; $j -gt $i; $j--) {
                    $b = $sorted[$j].T
                    if ($used.ContainsKey($b.Name)) { continue }
                    if (@($a.Played) -contains $b.Name) { continue }
                    $partner = $b; break
                }
                if (-not $partner) {
                    for ($j = $i + 1; $j -lt $sorted.Count; $j++) {
                        $b = $sorted[$j].T
                        if (-not $used.ContainsKey($b.Name)) { $partner = $b; break }
                    }
                }
                if ($partner) {
                    $used[$partner.Name] = $true
                    $bo = if ($a.W -eq 2 -or $a.L -eq 2) { 3 } else { 1 }
                    [void]$new.Add(@{
                            A = $a.Name; B = $partner.Name
                            W = $a.W; L = $a.L; Winner = $null; Bo = $bo
                        })
                }
            }
        }
    }

    foreach ($mt in $new) { [void]$Stage.Matches.Add($mt) }
    $Stage.Round++
}

function Set-SwissWinner {
    param($Stage, $Match, [string]$Side)
    if ($Match.Winner) { return $false }
    $Match.Winner = $Side

    $wn = if ($Side -eq 'A') { $Match.A } else { $Match.B }
    $ln = if ($Side -eq 'A') { $Match.B } else { $Match.A }
    $wt = $Stage.Teams[$wn]
    $lt = $Stage.Teams[$ln]

    $wt.W = [int]$wt.W + 1
    $lt.L = [int]$lt.L + 1
    [void]$wt.Played.Add($ln); [void]$lt.Played.Add($wn)
    [void]$wt.Opps.Add($ln);   [void]$lt.Opps.Add($wn)

    if ([int]$wt.W -ge 3) {
        $wt.Status = 'qualified'
        [void]$Stage.Qualified.Add($wt)
    }
    if ([int]$lt.L -ge 3) {
        $lt.Status = 'eliminated'
        [void]$Stage.Eliminated.Add($lt)
    }
    return $true
}

function Update-SwissStage {
    param($Stage)
    $pending = @($Stage.Matches | Where-Object { -not $_.Winner })
    if ($pending.Count -gt 0) { return $false }

    $alive = @($Stage.TeamList | Where-Object { $_.Status -eq 'alive' })
    if ($alive.Count -ge 2 -and $Stage.Round -lt 5) {
        Add-SwissRound -Stage $Stage
        return $true
    }
    if ($alive.Count -lt 2) { $Stage.Done = $true }
    return $false
}

function Get-SwissGroups {
    param($Stage)
    $g = [ordered]@{}
    foreach ($mt in @($Stage.Matches)) {
        $k = ('{0}-{1}' -f $mt.W, $mt.L)
        if (-not $g.Contains($k)) {
            $g[$k] = @{ Key = $k; W = [int]$mt.W; L = [int]$mt.L
                Items = (New-Object System.Collections.ArrayList) }
        }
        [void]$g[$k].Items.Add($mt)
    }
    # 按胜降负升排序
    $ordered = [ordered]@{}
    foreach ($k in @($g.Keys | Sort-Object {
                $p = $_ -split '-'
                - [int]$p[0]
            }, {
                $p = $_ -split '-'
                [int]$p[1]
            })) { $ordered[$k] = $g[$k] }
    return $ordered
}

# 晋级名单排序：3-0 → 3-1 → 3-2
function Get-SwissQualified {
    param($Stage)
    return @($Stage.Qualified | Sort-Object @{ Expression = { [int]$_.L } }, @{ Expression = { [int]$_.Seed } })
}
