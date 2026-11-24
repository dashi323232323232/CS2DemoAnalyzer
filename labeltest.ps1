# 检查每个队伍面板里：标签(label) 和 表格(grid) 的位置关系，
# 以及标签的文字是否被表格盖住。
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

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
$form.Show()
for ($i = 0; $i -lt 30; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }

"窗体: $($form.Width) x $($form.Height)"
""
"=== 每个页签 / 每个队伍：标签与表格的几何关系 ==="
foreach ($pk in @('main', 'util', 'fun')) {
    foreach ($rid in @('A', 'B')) {
        $lbl = $app.TeamLbls[$pk][$rid]
        $g = $app.Grids[$pk][$rid]
        $cell = $lbl.Parent
        # 标签相对面板的矩形
        $lb = $lbl.Bounds
        $gb = $g.Bounds
        # 转成相对面板的坐标
        $gTopInCell = $g.Top
        $lblBottom = $lbl.Bottom
        $overlap = $lblBottom - $gTopInCell
        $fontH = [int][Math]::Ceiling($lbl.Font.GetHeight())
        $verdict = if ($overlap -gt 0) { "重叠 $overlap px  <<< 标签被表格盖住" } else { '不重叠 OK' }
        "  [{0}/{1}] 面板={2}x{3}  标签=({4},{5}) {6}x{7}  表格=({8},{9}) {10}x{11}" -f `
            $pk, $rid, $cell.Width, $cell.Height, $lb.X, $lb.Y, $lb.Width, $lb.Height,
            $gb.X, $gb.Y, $gb.Width, $gb.Height
        "        字号高约 {0}px  标签底={1} 表格顶={2}  -> {3}" -f $fontH, $lblBottom, $gTopInCell, $verdict
        "        标签文字: [$($lbl.Text)]"
    }
}
""
"=== 表格行数与实际玩家数 ==="
foreach ($pk in @('main', 'util', 'fun')) {
    foreach ($rid in @('A', 'B')) {
        $g = $app.Grids[$pk][$rid]
        "  [{0}/{1}] 行数={2}  行高={3}  表头高={4}  可视高={5}" -f `
            $pk, $rid, $g.Rows.Count, $g.RowTemplate.Height, $g.ColumnHeadersHeight, $g.ClientSize.Height
    }
}
$form.Close(); $form.Dispose()
"done"
