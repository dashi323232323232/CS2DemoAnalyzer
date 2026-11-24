# ratingtest.ps1 — Rating 公式「双份实现」一致性回归
#
# Rating 公式在两边各写了一份：
#   src/analyzer.py      分析时算每个阶段的 rating
#   DemoAnalyzer.ps1     多选半场合并时按叠加后数据重算 rating
# 这两份一旦漂移，单段显示的 rating 和合并后的 rating 就会对不上。
# 本测试把 PowerShell 侧算出的输入+结果导出，交给 Python 用 analyzer.py
# 的公式重算一遍，逐条比对。
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$here = $PSScriptRoot
$src = [System.IO.File]::ReadAllText((Join-Path $here 'DemoAnalyzer.ps1'), [System.Text.Encoding]::UTF8)
$idx = $src.IndexOf('# ---------------- 入口 ----------------')
$src = $src.Substring(0, $idx)
$src = $src -replace '(?s)^\s*param\s*\(.*?\)\s*\r?\n', ''
$src = $src -replace '(?m)^\$Root\s*=.*$', ('$Root = ' + "'" + $here + "'")
Invoke-Expression $src

"PowerShell 侧常数: KB=$RatingKB SP=$RatingSP MKP=$RatingMKP AP=$RatingAP"
"                   WKP=$RatingWKP WSP=$RatingWSP WMKP=$RatingWMKP WAP=$RatingWAP  除数=$RatingDiv"

# 除数必须正好等于四项权重之和，否则「四项都等于基准 => 1.00」就不成立
$wantDiv = $RatingWKP + $RatingWSP + $RatingWMKP + $RatingWAP
$okDiv = ([Math]::Abs($RatingDiv - $wantDiv) -lt 1e-9)
"==> 除数 = 权重之和 : $(if ($okDiv) { 'OK' } else { "FAIL ($RatingDiv vs $wantDiv)" })"

$rep = Load-Report -JsonPath $OutJson
if (-not $rep) { throw "读不到 $OutJson" }

$combos = @(
    @{ name = 'first'; keys = @('first') },
    @{ name = 'second'; keys = @('second') },
    @{ name = 'first+second'; keys = @('first', 'second') },
    @{ name = 'first+overtime'; keys = @('first', 'overtime') },
    @{ name = 'all'; keys = @('first', 'second', 'overtime') }
)

$cases = New-Object System.Collections.ArrayList
foreach ($c in $combos) {
    $m = Merge-Periods -Report $rep -Keys $c.keys
    foreach ($side in @('A', 'B')) {
        foreach ($p in @($m[$side])) {
            [void]$cases.Add(@{
                    combo   = $c.name
                    side    = $side
                    name    = [string]$p['name']
                    rounds  = [int]$p['rounds']
                    kills   = [int]$p['kills']
                    deaths  = [int]$p['deaths']
                    multi2  = [int]$p['multi2']
                    assists = [int]$p['assists']
                    ps      = [double]$p['rating']
                })
        }
    }
}
"导出待核对条目: $($cases.Count)"

$dump = Join-Path $here 'out\rating_cases.json'
$json = $cases | ConvertTo-Json -Depth 4
[System.IO.File]::WriteAllText($dump, $json, (New-Object System.Text.UTF8Encoding $false))

$py = Find-Python
if (-not $py) { throw '找不到 python.exe' }
# 对账器放在项目根，不放 out\ —— out\ 是分析产出目录，会被重新分析/清理覆盖，
# 之前它就是因此消失，导致这个测试长期只跑完第一句断言就静默失败。
$script = Join-Path $here 'rating_cross.py'
if (-not (Test-Path $script)) { throw "缺少对账器 $script（应随仓库一起提交，不要放进 out\）" }
$outFile = Join-Path $here 'out\rating_cross.txt'
# 注意：python 自己会把结果写成 UTF-8 的 $outFile；stdout 必须重定向到别的文件，
# 否则两个流写同一个路径会互相覆盖，读出来就是乱码。
$stdout = Join-Path $here 'out\rating_cross.stdout.txt'
$errFile = Join-Path $here 'out\rating_cross.stderr.txt'
Remove-Item $outFile, $stdout, $errFile -Force -ErrorAction SilentlyContinue
$pr = Start-Process -FilePath $py -ArgumentList @($script, $dump, $outFile) -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $stdout -RedirectStandardError $errFile
[void]$pr.WaitForExit(120000)
if (-not $pr.HasExited) { $pr.Kill(); throw 'python 超时' }

if (-not (Test-Path $outFile)) { throw "python 没有输出（stderr: $(Get-Content $errFile -Raw -ErrorAction SilentlyContinue)）" }
$lines = @(Get-Content $outFile -Encoding UTF8)
$bad = @($lines | Where-Object { $_ -match '^MISMATCH' })
$checked = @($lines | Where-Object { $_ -match '^OK ' })
$summary = @($lines | Where-Object { $_ -match '^合计' })

foreach ($s in $summary) { Write-Output "python 侧: $s" }
"逐条比对: 一致 $($checked.Count) 条，不一致 $($bad.Count) 条"
foreach ($b in $bad) { Write-Output "  $b" }

$ok = $okDiv -and ($bad.Count -eq 0) -and ($checked.Count -eq $cases.Count)
if (-not $ok) { Write-Output "  条目数核对: 一致 $($checked.Count) / 导出 $($cases.Count)" }
if ($ok) { "RATINGTEST OK" } else { "RATINGTEST FAILED"; exit 1 }
