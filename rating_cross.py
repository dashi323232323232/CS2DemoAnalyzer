"""rating_cross.py — ratingtest.ps1 的 Python 侧对账器

由 ratingtest.ps1 调用：
    python rating_cross.py <rating_cases.json> <out.txt>

从 src/analyzer.py 直接导入 calc_rating，不另写一份公式。
这点很关键：如果在这里把公式再抄一遍，这个测试就只能证明「两份抄写
彼此一致」，而证明不了真公式没漂移 —— 抄错一次，两边一起错，照样全绿。
所以这里必须 import 生产代码本身。

输入 rating_cases.json 由 PowerShell 侧导出，每条形如：
    {combo, side, name, rounds, kills, deaths, multi2, assists, ps}
其中 ps 是 DemoAnalyzer.ps1 里 Merge-Periods 重算出的 rating，
multi2 对应 calc_rating 的 multi_rounds 参数（单回合 >=2 杀的回合数）。

输出格式（ratingtest.ps1 按行首匹配解析，不要改）：
    OK <combo>/<side>/<name> ps=.. py=..
    MISMATCH ...            （有不一致时才有）
    合计 比对 N 条，不一致 M 条
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, 'src'))

from analyzer import calc_rating  # noqa: E402

# 两侧最后都 round(...,2)，且 .NET Math.Round 与 Python round 同为
# 银行家舍入，理应完全相等；留极小容差只是挡浮点噪声，不掩盖真实漂移。
TOL = 1e-9


def main():
    if len(sys.argv) < 3:
        sys.stderr.write('用法: rating_cross.py <cases.json> <out.txt>\n')
        return 2

    dump, out = sys.argv[1], sys.argv[2]
    with open(dump, encoding='utf-8') as f:
        cases = json.load(f)

    # ConvertTo-Json 在只有一条时不会输出数组，兜一下
    if isinstance(cases, dict):
        cases = [cases]

    lines = []
    bad = 0
    for c in cases:
        want = float(c['ps'])
        got = calc_rating(
            int(c['rounds']),
            int(c['kills']),
            int(c['deaths']),
            int(c['multi2']),
            int(c['assists']),
        )
        tag = '%s/%s/%s' % (c.get('combo'), c.get('side'), c.get('name'))
        if abs(got - want) <= TOL:
            lines.append('OK %s ps=%.2f py=%.2f' % (tag, want, got))
        else:
            bad += 1
            lines.append(
                'MISMATCH %s ps=%.2f py=%.2f  '
                '(rounds=%s kills=%s deaths=%s multi2=%s assists=%s)'
                % (tag, want, got, c['rounds'], c['kills'], c['deaths'],
                   c['multi2'], c['assists'])
            )

    lines.append('合计 比对 %d 条，不一致 %d 条' % (len(cases), bad))

    # 必须显式 UTF-8：python 在中文 Windows 上默认 stdout/文件走 GBK，
    # 而 PowerShell 侧是按 -Encoding UTF8 读的，名字里带中文会直接读成乱码。
    with open(out, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines) + '\n')

    return 0 if bad == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
