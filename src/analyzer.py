"""analyzer.py — CS2 demo 逐玩家统计（demoparser2 后端）

用法:
    python analyzer.py <demo.dem> <out.json> [<progress.json>]

输出结构（关键部分）:
    demo     地图 / 回合数 / 玩家数等
    periods  上半场 / 下半场 / 加时 三段，每段内按「队伍名册」分成左右两队
    players  全场扁平列表（兼容 / 调试用）

关于「队伍为什么不能用 CT / T 标注」:
    半场会换边。实测同一个人的 team_num 在上下半场是互换的，例如
    某人上半场是 3(CT)，下半场就变成 2(T)。所以先按「第一次出现在哪边」
    把玩家固定归入 队伍1 / 队伍2 两个名册，之后无论换到哪边都还属于原名册。

    玩家以「名字」为主键归并。SteamID64 超出 float64 精度（>2^53），
    经 pandas 读取后末位会漂移，因此只用它做展示，不做关联键。

    第三个参数是进度文件的可选路径。给了就按阶段写入
    {"pct": 0-100, "stage": "中文阶段名"}，供客户端画进度条。
"""
import os
import re
import sys
import json
import bisect
import traceback

try:
    import pandas as pd
    from demoparser2 import DemoParser
except Exception:
    # 客户端是隐藏窗口启动 python 的，拿不到 stderr；依赖缺失也要留下痕迹。
    _err = (sys.argv[2] + ".error.txt") if len(sys.argv) > 2 else "error.txt"
    try:
        with open(_err, "w", encoding="utf-8") as _f:
            _f.write("依赖导入失败：\n" + traceback.format_exc())
    except Exception:
        pass
    raise


# ---------- 进度上报 ----------
PROG_PATH = None


def set_progress_path(path):
    global PROG_PATH
    PROG_PATH = path


def report(pct, stage):
    """写进度文件。先写临时文件再替换，避免客户端读到半截 JSON。"""
    if not PROG_PATH:
        return
    try:
        tmp = PROG_PATH + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"pct": int(pct), "stage": str(stage)}, f, ensure_ascii=False)
        os.replace(tmp, PROG_PATH)
    except Exception:
        pass


# ---------- 常量 ----------
HE_WEAPONS = {"hegrenade"}
FIRE_WEAPONS = {"inferno", "molotov", "incendiarygrenade", "firebomb"}
DECOY_WEAPONS = {"decoy"}
ZEUS_WEAPONS = {"taser", "zeus", "zeusx27"}

# CS2 竞技 / 首选模式是 MR12：每半场 12 回合，常规时间 24 回合，之后进加时。
HALF_ROUNDS = 12
REGULATION_ROUNDS = 24

SIDE_NAME = {2: "T", 3: "CT", 0: "未定"}

# 回合结束原因 (CCSGameRulesProxy.CCSGameRules.m_eRoundEndReason)
# 实测常见值: 1=TargetBombed, 7=BombDefused, 8=CTs_Win, 9=Terrorists_Win, 12=TargetSaved
ROUND_END_REASON_MAP = {
    1: "C4爆炸",
    7: "拆包成功",
    8: "歼敌",
    9: "歼敌",
    12: "时间耗尽",
}
ROUND_END_WINNER_HINT = {
    1: "T胜",
    7: "CT胜",
    8: "CT胜",
    9: "T胜",
    12: "CT胜",
}

# demo 里会出现 5e_2023pass3_ak47 这类带活动前缀的武器名，先剥掉。
_VARIANT_RE = re.compile(r"^5e_\d{4}pass\d+_")


# ---------- 小工具 ----------
def clean_name(v):
    """把 NaN / None / 空串统一成 None。"""
    if v is None:
        return None
    try:
        if pd.isna(v):
            return None
    except (TypeError, ValueError):
        pass
    s = str(v).strip()
    if not s or s.lower() in ("nan", "none", "<na>", "null", "nat"):
        return None
    return s


def sid_str(v):
    """SteamID 仅用于展示：转成不带小数点的字符串。"""
    if v is None:
        return ""
    try:
        if pd.isna(v):
            return ""
    except (TypeError, ValueError):
        pass
    try:
        return str(int(v))
    except (TypeError, ValueError):
        return str(v)


def norm_weapon(w):
    """武器名归一化：小写 + 去掉活动前缀。"""
    if not isinstance(w, str):
        return ""
    return _VARIANT_RE.sub("", w.strip().lower())


def is_knife(w):
    # 用包含判断，兼容 knife / knife_t / 带前缀的变体
    return "knife" in w


def is_zeus(w):
    return w in ZEUS_WEAPONS


def weapon_class(w):
    if not w:
        return "other"
    if is_knife(w):
        return "knife"
    if w in HE_WEAPONS:
        return "he"
    if w in FIRE_WEAPONS:
        return "fire"
    if w in DECOY_WEAPONS:
        return "decoy"
    return "gun"


def periods_for(n):
    """按回合数切出 上半场 / 下半场 / 加时。MS12 规则。"""
    first = list(range(1, min(n, HALF_ROUNDS) + 1))
    second = list(range(HALF_ROUNDS + 1, min(n, REGULATION_ROUNDS) + 1))
    overtime = list(range(REGULATION_ROUNDS + 1, n + 1))
    return first, second, overtime


def safe_event(parser, name):
    """parse_event 对空事件可能返回 list，统一成 DataFrame。"""
    try:
        df = parser.parse_event(name)
    except Exception:
        return pd.DataFrame()
    return df if isinstance(df, pd.DataFrame) else pd.DataFrame()


def blank_stats(name, steamid, roster):
    return {
        "name": name,
        "steamid": steamid,
        "roster": roster,
        "rounds": 0,
        # 第一页：主要数据
        "kills": 0, "deaths": 0, "assists": 0,
        "headshots": 0, "damage": 0,
        "opening_kills": 0, "opening_deaths": 0,
        "multi2": 0, "multi3": 0, "multi4": 0, "multi5": 0,
        "rating": 0.0,
        # 第二页：道具伤害
        "he_damage": 0, "fire_damage": 0, "decoy_damage": 0,
        "he_kills": 0, "fire_kills": 0,
        # 第三页：娱乐数据
        "chicken_kills": 0, "knife_kills": 0, "zeus_kills": 0,
        "plants": 0, "defuses": 0,
        "teamkills": 0, "suicides": 0, "team_damage": 0,
        "flash_assists": 0,
        # 明细
        "weapon_kills": {},
    }


# ---------- Rating ----------
# 近似 HLTV Rating 2.0：四个分项各自除以基准值，再加权平均。
#   击杀/回合   基准 0.679   ← K/D 的主要来源
#   存活率      基准 0.317
#   多杀回合率  基准 0.158   （单回合 >=2 杀的回合占比）
#   助攻/回合   基准 0.106
# 权重见下面的 RATING_W_*；除数取四项权重之和 —— 这样「四项都等于基准」的
# 球员正好是 1.00。改权重时除数会自动跟着变，不会把整体均值推歪。
# 击杀项 0.7 -> 1.2 -> 1.5、助攻项 0.7 -> 0.4：实测 Rating 与 K/D 的排名
# 相关性 0.52 -> 0.64 -> 0.73，助攻在 raw 分里的占比 38% -> 21%。
# 注意：这个权重同时也写在 DemoAnalyzer.ps1 里（多选合并要前端重算），两边必须一致。
# 为了解决“高的过高、低的过低”：先算原始线性分，再向 1.0 压缩
# （高于 1 的压 15% *0.85，低于 1 的压 35% *0.65），并裁到 [0.50, 1.95]。
# ※ 爆头率(headshots/hs_rate) 完全不参与 rating 计算，仅作展示列。
# 校验方式：一局里所有人的平均 rating 应当落在 1.0 附近。
RATING_BASE_KP = 0.679
RATING_BASE_SP = 0.317
RATING_BASE_MKP = 0.158
RATING_BASE_AP = 0.106
# 四项权重。击杀项 = K/D 的主要来源；助攻项基准 0.106 偏低、实际容易超标，
# 权重调低才不会喧宾夺主。
RATING_W_KP = 1.5
RATING_W_SP = 0.7
RATING_W_MKP = 1.0
RATING_W_AP = 0.4
# 除数 = 权重之和，保证「四项都等于基准」的球员正好是 1.00
RATING_DIVISOR = RATING_W_KP + RATING_W_SP + RATING_W_MKP + RATING_W_AP
RATING_COMPRESS_HIGH = 0.85
RATING_COMPRESS_LOW = 0.65
RATING_MIN = 0.50
RATING_MAX = 1.95


def calc_rating(rounds, kills, deaths, multi_rounds, assists):
    if rounds <= 0:
        return 0.0
    kp = kills / rounds
    # 存活率夹到 [0,1]：回合重启等情况会让死亡数大于回合数，
    # 不夹的话存活项变负，rating 会算出负数。
    sp = max(0.0, min(1.0, (rounds - deaths) / rounds))
    mkp = multi_rounds / rounds
    ap = assists / rounds
    raw = (RATING_W_KP * (kp / RATING_BASE_KP)
           + RATING_W_SP * (sp / RATING_BASE_SP)
           + RATING_W_MKP * (mkp / RATING_BASE_MKP)
           + RATING_W_AP * (ap / RATING_BASE_AP)) / RATING_DIVISOR
    # 向 1.0 压缩：高于1的压15%，低于1的压35%（低分更往1靠）
    comp = RATING_COMPRESS_HIGH if raw >= 1.0 else RATING_COMPRESS_LOW
    val = 1.0 + (raw - 1.0) * comp
    if val < RATING_MIN:
        val = RATING_MIN
    elif val > RATING_MAX:
        val = RATING_MAX
    return round(val, 2)



def main():
    demo_path = sys.argv[1]
    out_path = sys.argv[2]
    if len(sys.argv) > 3:
        set_progress_path(sys.argv[3])

    report(2, "打开 demo 文件")
    parser = DemoParser(demo_path)

    report(7, "读取 demo 头部")
    header = parser.parse_header()

    report(12, "读取玩家名单")
    info = parser.parse_player_info()
    if not isinstance(info, pd.DataFrame):
        info = pd.DataFrame(columns=["steamid", "name", "team_number"])

    report(18, "解析回合与换边")
    r_start = safe_event(parser, "round_start")
    raw_ticks = []
    if not r_start.empty and "tick" in r_start.columns:
        raw_ticks = sorted(set(int(t) for t in r_start["tick"].dropna()))
    # 去掉赛前死斗 / 热身回合。
    #
    # 只用 is_warmup_period 判断，**不要**再要求 m_bHasMatchStarted==True：
    # 很多平台（G161 等）赛前有一段死斗，它的 round_start 会进 demo；而正赛
    # 第 1 回合开始时 m_bHasMatchStarted 仍然是 False（要到第 2 回合才翻成
    # True）。用「已开赛」当过滤条件会把真正的第 1 回合整个丢掉 —— 表现为
    # 20 回合的比赛只统计 19 回合，并且上下半场分界整体错位一格，
    # 时间轴上「CT=A/B」也会在第 12 回合就提前换边。
    round_ticks = raw_ticks
    if raw_ticks:
        try:
            qp = parser.parse_ticks(
                ["is_warmup_period",
                 "CCSGameRulesProxy.CCSGameRules.m_bHasMatchStarted"],
                ticks=raw_ticks)
            if isinstance(qp, pd.DataFrame) and not qp.empty:
                qp2 = qp.drop_duplicates(subset=["tick"]).sort_values("tick")
                _warm = {}
                _has = {}
                _have_warm = "is_warmup_period" in qp2.columns
                _have_has = "CCSGameRulesProxy.CCSGameRules.m_bHasMatchStarted" in qp2.columns
                for _, rr in qp2.iterrows():
                    try:
                        _t = int(rr["tick"])
                    except Exception:
                        continue
                    _warm[_t] = bool(rr["is_warmup_period"]) if _have_warm else False
                    _has[_t] = bool(rr["CCSGameRulesProxy.CCSGameRules.m_bHasMatchStarted"]) if _have_has else True
                if _have_warm:
                    filt = [t for t in raw_ticks if not _warm.get(t, False)]
                else:
                    # 取不到热身标志时才退回「已开赛」判断
                    filt = [t for t in raw_ticks
                            if _has.get(t, True) and not _warm.get(t, False)]
                if filt:
                    round_ticks = filt
        except Exception:
            pass
    n_rounds = len(round_ticks)

    # 回合时间基准。
    #
    # round_start 是「冻结时间开始」那一刻，所以 round_start→round_start 包含
    # 「冻结时间 + 115 秒回合 + 回合间延迟」，实测约 141 秒 —— 拿它当回合计时
    # 起点会让详情里的时间一路跑到 2:21，超过一回合的 1:55。
    # 详情面板要的是「回合内已过时间」（0:00 = 冻结结束、开始能行动），
    # 所以取 round_freeze_end 当起点、round_end 当终点。
    # 这两个事件的数量可能和过滤后的 round_ticks 不一致（赛前死斗也会产生），
    # 因此按「落在本回合区间内的第一个」来配对，而不是按下标硬套。
    def _ticks_of(ev_name):
        try:
            df = safe_event(parser, ev_name)
            if df is None or df.empty or "tick" not in df.columns:
                return []
            return sorted(set(int(t) for t in df["tick"].dropna()))
        except Exception:
            return []

    freeze_ticks = _ticks_of("round_freeze_end")
    end_ticks = _ticks_of("round_end")

    def _first_in(ticks, lo, hi):
        """ticks 里第一个落在 (lo, hi) 区间内的值；没有就返回 None。"""
        for t in ticks:
            if t > lo and (hi is None or t < hi):
                return t
        return None

    round_freeze = {}
    round_end_tick = {}
    for _i, _st in enumerate(round_ticks):
        _nx = round_ticks[_i + 1] if _i + 1 < len(round_ticks) else None
        round_freeze[_i + 1] = _first_in(freeze_ticks, _st, _nx)
        round_end_tick[_i + 1] = _first_in(end_ticks, _st, _nx)

    # 玩家名册（以名字为主键）
    names = []
    sids = {}
    for _, row in info.iterrows():
        nm = clean_name(row.get("name"))
        if nm is None or nm in sids:
            continue
        names.append(nm)
        sids[nm] = sid_str(row.get("steamid"))

    # 每个回合开始时，每个人在哪一边。用来解决「换边」问题。
    round_team = {}          # (name, 回合号) -> team_num
    if round_ticks:
        try:
            tdf = parser.parse_ticks(["team_num"], ticks=round_ticks)
        except Exception:
            tdf = pd.DataFrame()
        if isinstance(tdf, pd.DataFrame) and not tdf.empty:
            for _, row in tdf.iterrows():
                nm = clean_name(row.get("name"))
                if nm is None:
                    continue
                try:
                    t = int(row.get("tick"))
                except (TypeError, ValueError):
                    continue
                rnd = bisect.bisect_left(round_ticks, t) + 1
                try:
                    tn = int(row.get("team_num"))
                except (TypeError, ValueError):
                    tn = 0
                round_team[(nm, rnd)] = tn

    def round_of(tick):
        """tick -> 1 起的回合号；0 表示还没进第一回合（热身）。"""
        if not round_ticks:
            return 0
        return bisect.bisect_right(round_ticks, int(tick))

    def in_match(tick):
        """该 tick 是否落在正赛回合内（排除赛前死斗与赛后）。"""
        return 1 <= round_of(tick) <= n_rounds

    def count_match(df):
        """统计落在正赛回合内的事件数（用于 demo.total_* 这类汇总）。"""
        if df is None or getattr(df, "empty", True) or "tick" not in df.columns:
            return 0
        c = 0
        for t in df["tick"].dropna():
            try:
                if in_match(int(t)):
                    c += 1
            except Exception:
                pass
        return c

    # 补齐采样空档：回合刚开始那一帧少数人还取不到 team_num（值为 0 或缺失）。
    # 队伍归属除了换边之外是稳定的，所以向前 / 向后取最近的有效值就是对的。
    # 不补的话「参与回合数」会偏少，ADR 就会偏高。
    for nm in names:
        known = [r for r in range(1, n_rounds + 1)
                 if round_team.get((nm, r), 0) in (2, 3)]
        if not known:
            continue
        last = None
        for r in range(1, n_rounds + 1):
            tn = round_team.get((nm, r), 0)
            if tn in (2, 3):
                last = tn
            elif last is not None:
                round_team[(nm, r)] = last
        head = round_team.get((nm, known[0]), 0)
        for r in range(1, known[0]):
            round_team[(nm, r)] = head

    # 名册归属：第一次出现在 2/3 边时在哪边，就固定算哪队。
    roster_of = {}
    for nm in names:
        for r in range(1, n_rounds + 1):
            tn = round_team.get((nm, r), 0)
            if tn in (2, 3):
                roster_of[nm] = "A" if tn == 3 else "B"
                break

    start_side = {}
    for rid in ("A", "B"):
        side = "?"
        for nm in names:
            if roster_of.get(nm) != rid:
                continue
            for r in range(1, n_rounds + 1):
                tn = round_team.get((nm, r), 0)
                if tn in (2, 3):
                    side = SIDE_NAME.get(tn, "?")
                    break
            break
        start_side[rid] = side

    report(26, "读取击杀事件")
    deaths = safe_event(parser, "player_death")

    report(34, "解析击杀事件")
    hurts = safe_event(parser, "player_hurt")

    report(44, "解析实体死亡事件")
    others = safe_event(parser, "other_death")

    report(52, "解析下包 / 拆包事件")
    bombs = safe_event(parser, "bomb_planted")
    defuses = safe_event(parser, "bomb_defused")

    # ---------- 时间轴（每回合简要 + 详细） ----------
    # 在解析完所有事件后、生成统计之前，先构造每回合的时间轴数据。
    # 需要：回合结束方式（用击杀/下包/拆包事件推断，辅以游戏规则的胜负字段）、
    # 胜者名册、比分、击杀简述等，供前端根据勾选的半场过滤后横向展示。
    timeline = []
    # 预采样每回合开始时的阵营与比分，方便推断胜者名册
    round_ct_roster = {}  # 回合号 -> 哪支名册是 CT
    try:
        for rnd in range(1, n_rounds + 1):
            t = round_ticks[rnd - 1] if rnd - 1 < len(round_ticks) else 0
            # 找该回合开始时哪队是 CT（team_num==3）
            ct = None
            for nm in names:
                tn = round_team.get((nm, rnd), 0)
                if tn == 3:
                    ct = roster_of.get(nm)
                    break
            if ct in ("A", "B"):
                round_ct_roster[rnd] = ct
            else:
                # 回退：用第一回合的 CT 推断换边
                if rnd <= HALF_ROUNDS:
                    round_ct_roster[rnd] = "A" if start_side.get("A") == "CT" else "B"
                else:
                    # 下半场换边
                    round_ct_roster[rnd] = "B" if start_side.get("A") == "CT" else "A"
                if rnd > REGULATION_ROUNDS:
                    # 加时每 6 局换一次，简化：用奇偶判断
                    # MR3 加时：每 3 轮换边，但比分层面不影响时间轴展示
                    pass
    except Exception:
        pass

    # 采样胜负/原因（优先用游戏规则字段，失败则回退到事件推断）
    round_win_team = {}  # rnd -> 2/3
    round_reason = {}
    if n_rounds:
        try:
            # 在每回合区间末尾附近采样（结束前 64 tick），此时游戏已写入当回合结果
            probe_ticks = []
            tick_to_rnd = {}
            for idx, st in enumerate(round_ticks):
                rnd = idx + 1
                nxt = round_ticks[idx + 1] if idx + 1 < len(round_ticks) else st + 4096
                pt = nxt - 64
                if pt <= st:
                    pt = st + 64
                # 保证唯一
                probe_ticks.append(pt)
                tick_to_rnd[pt] = rnd
            # 去重排序
            probe_ticks = sorted(set(probe_ticks))
            gdf = parser.parse_ticks([
                "CCSGameRulesProxy.CCSGameRules.m_eRoundEndReason",
                "CCSGameRulesProxy.CCSGameRules.m_iRoundEndWinnerTeam",
            ], ticks=probe_ticks)
            if isinstance(gdf, pd.DataFrame) and not gdf.empty:
                gdf2 = gdf.drop_duplicates(subset=["tick"]).sort_values("tick")
                for _, row in gdf2.iterrows():
                    try:
                        pt = int(row["tick"])
                    except Exception:
                        continue
                    rnd = tick_to_rnd.get(pt)
                    if not rnd:
                        # 容错：用最近的回合号
                        rnd = bisect.bisect_right(round_ticks, pt)
                        if rnd < 1 or rnd > n_rounds:
                            continue
                    try:
                        rs = int(row["CCSGameRulesProxy.CCSGameRules.m_eRoundEndReason"])
                    except Exception:
                        rs = 0
                    try:
                        wt = int(row["CCSGameRulesProxy.CCSGameRules.m_iRoundEndWinnerTeam"])
                    except Exception:
                        wt = 0
                    # 只有当 wt 为 2/3 时才可信（0 表示尚未写入）
                    if wt in (2, 3):
                        round_win_team[rnd] = wt
                    if rs in ROUND_END_REASON_MAP:
                        round_reason[rnd] = rs
        except Exception:
            pass

    # ---------- 单段统计 ----------
    def compute(period_rounds):
        """period_rounds=None 表示全场；否则是回合号集合。"""
        stats = {nm: blank_stats(nm, sids.get(nm, ""), roster_of.get(nm, "?"))
                 for nm in names}

        def keep(tick):
            # 先排掉赛前死斗 / 赛后：它们的回合号不在 1..n_rounds 里。
            # 不排的话「全场」口径会把死斗里的击杀 / 死亡也算进来，
            # 于是 全场 ≠ 上半场 + 下半场 + 加时，两套数字互相打架。
            r = round_of(tick)
            if r < 1 or r > n_rounds:
                return False
            if period_rounds is None:
                return True
            return r in period_rounds

        def P(nm):
            return stats.get(nm)

        # 该段内实际参与的回合数（按换边采样算，比一律按总回合数准确）
        for nm in names:
            c = 0
            for r in range(1, n_rounds + 1):
                if period_rounds is not None and r not in period_rounds:
                    continue
                if round_team.get((nm, r), 0) in (2, 3):
                    c += 1
            stats[nm]["rounds"] = c

        # --- 击杀 / 死亡 / 助攻 / 多杀 / 首杀首死 ---
        per_round_kills = {}
        round_first_kill = {}

        if not deaths.empty:
            for _, r in deaths.iterrows():
                tick = int(r["tick"]) if pd.notna(r.get("tick")) else 0
                if not keep(tick):
                    continue
                rnd = round_of(tick)
                atk = clean_name(r.get("attacker_name"))
                vic = clean_name(r.get("user_name"))
                ast = clean_name(r.get("assister_name"))
                wpn = norm_weapon(r.get("weapon"))

                v = P(vic)
                if v is not None:
                    v["deaths"] += 1

                # 自杀 / 世界伤害（掉下地图、被自己的雷炸死等）
                if atk is None or atk == vic:
                    if v is not None:
                        v["suicides"] += 1
                    continue

                a = P(atk)
                if a is None:
                    continue

                # 队友击杀：算团队击杀，不算普通击杀。
                if (v is not None and a["roster"] == v["roster"]
                        and a["roster"] in ("A", "B")):
                    a["teamkills"] += 1
                    continue

                a["kills"] += 1
                a["weapon_kills"][wpn] = a["weapon_kills"].get(wpn, 0) + 1
                if bool(r.get("headshot")):
                    a["headshots"] += 1
                if is_knife(wpn):
                    a["knife_kills"] += 1
                if is_zeus(wpn):
                    a["zeus_kills"] += 1
                if wpn in HE_WEAPONS:
                    a["he_kills"] += 1
                if wpn in FIRE_WEAPONS:
                    a["fire_kills"] += 1
                per_round_kills.setdefault((atk, rnd), []).append(tick)

                if ast is not None:
                    ab = P(ast)
                    if ab is not None:
                        ab["assists"] += 1
                        if bool(r.get("assistedflash")):
                            ab["flash_assists"] += 1

                if rnd not in round_first_kill:
                    round_first_kill[rnd] = (vic, atk)

        for (nm, _rnd), ticks in per_round_kills.items():
            p = P(nm)
            if p is None:
                continue
            n = len(ticks)
            for k in (2, 3, 4, 5):
                if n >= k:
                    p["multi%d" % k] += 1

        for _rnd, (vic, atk) in round_first_kill.items():
            a = P(atk)
            if a is not None:
                a["opening_kills"] += 1
            v = P(vic)
            if v is not None:
                v["opening_deaths"] += 1

        # --- 伤害 ---
        if not hurts.empty:
            # player_hurt 的 dmg_health 是**没有截断的原始伤害**：AWP 爆头一枪就是
            # 438，可满血只有 100。直接累加等于把溢出伤害（overkill）也算进 ADR，
            # 实测总量多算 26%。真实掉血 = min(dmg_health, 打之前剩的血)。
            # 「打之前剩的血」从 health 字段反推 —— 它是打完之后的值，所以同一个人
            # 上一次的 health 就是这一次的「打之前」；每回合重置为 100。
            # 这一步必须遍历**全部**事件（不受 keep() 影响），否则跨回合血量接不上。
            hh = hurts.sort_values("tick").copy()
            _hp, _rnd, _before = {}, {}, []
            for _, r in hh.iterrows():
                t = int(r["tick"]) if pd.notna(r.get("tick")) else 0
                vk = r.get("user_steamid")
                rn = round_of(t)
                if _rnd.get(vk) != rn:
                    _rnd[vk] = rn
                    _hp[vk] = 100
                b = _hp.get(vk, 100)
                _before.append(b)
                after = r.get("health")
                if pd.notna(after):
                    _hp[vk] = max(0, int(after))
                else:
                    d0 = int(r["dmg_health"]) if pd.notna(r.get("dmg_health")) else 0
                    _hp[vk] = max(0, b - d0)
            hh["hp_before"] = _before

            for _, r in hh.iterrows():
                tick = int(r["tick"]) if pd.notna(r.get("tick")) else 0
                if not keep(tick):
                    continue
                atk = clean_name(r.get("attacker_name"))
                vic = clean_name(r.get("user_name"))
                dmg = int(r["dmg_health"]) if pd.notna(r.get("dmg_health")) else 0
                # 溢出伤害不算：打之前只剩 18 血，这一枪 141 也只能算 18
                hpb = int(r["hp_before"])
                if hpb <= 0:
                    dmg = 0
                elif dmg > hpb:
                    dmg = hpb
                wpn = norm_weapon(r.get("weapon"))

                if atk is None or atk == vic or dmg <= 0:
                    continue
                a = P(atk)
                if a is None:
                    continue
                v = P(vic)
                if (v is not None and a["roster"] == v["roster"]
                        and a["roster"] in ("A", "B")):
                    a["team_damage"] += dmg
                    continue

                a["damage"] += dmg
                cls = weapon_class(wpn)
                if cls == "he":
                    a["he_damage"] += dmg
                elif cls == "fire":
                    a["fire_damage"] += dmg
                elif cls == "decoy":
                    a["decoy_damage"] += dmg

        # --- 小鸡等实体 ---
        if not others.empty:
            for _, r in others.iterrows():
                tick = int(r["tick"]) if pd.notna(r.get("tick")) else 0
                if not keep(tick):
                    continue
                if "chicken" in str(r.get("othertype", "")).lower():
                    a = P(clean_name(r.get("attacker_name")))
                    if a is not None:
                        a["chicken_kills"] += 1

        # --- 下包 / 拆包 ---
        for df, field in ((bombs, "plants"), (defuses, "defuses")):
            if df is None or df.empty:
                continue
            for _, r in df.iterrows():
                tick = int(r["tick"]) if pd.notna(r.get("tick")) else 0
                if not keep(tick):
                    continue
                a = P(clean_name(r.get("user_name")))
                if a is not None:
                    a[field] += 1

        # --- 收尾派生指标 ---
        out = []
        for nm in names:
            p = stats[nm]
            rd = p["rounds"]
            if (rd == 0 and p["kills"] == 0 and p["deaths"] == 0
                    and p["damage"] == 0 and p["assists"] == 0):
                continue

            p["adr"] = round(p["damage"] / rd, 1) if rd else 0.0
            p["kd"] = (round(p["kills"] / p["deaths"], 2)
                       if p["deaths"] else float(p["kills"]))
            p["hs_rate"] = (round(100.0 * p["headshots"] / p["kills"], 1)
                            if p["kills"] else 0.0)

            p["utility_damage"] = p["he_damage"] + p["fire_damage"] + p["decoy_damage"]
            total = p["damage"] + p["team_damage"]
            p["utility_rate"] = (round(100.0 * p["utility_damage"] / total, 1)
                                 if total else 0.0)
            p["utility_per_round"] = (round(p["utility_damage"] / rd, 1)
                                      if rd else 0.0)

            # 近似 HLTV Rating 2.0。多杀回合数直接用 multi2 —— 它统计的正是
            # 「单回合 >=2 杀」的回合数，与公式里 RoundsWithMultipleKills 一致。
            p["rating"] = calc_rating(rd, p["kills"], p["deaths"],
                                      p["multi2"], p["assists"])
            out.append(p)
        return out

    report(64, "统计击杀 / 死亡 / 助攻")
    first_r, second_r, ot_r = periods_for(n_rounds)

    def pack(round_list, label):
        players = compute(set(round_list)) if round_list else []
        teams = {"A": {"players": []}, "B": {"players": []}}
        for p in players:
            rid = p["roster"] if p["roster"] in ("A", "B") else "A"
            teams[rid]["players"].append(p)
        for rid in ("A", "B"):
            teams[rid]["players"].sort(
                key=lambda x: (-x["kills"], -x["damage"], x["deaths"]))
        return {
            "label": label,
            "rounds": len(round_list),
            "first_round": round_list[0] if round_list else 0,
            "last_round": round_list[-1] if round_list else 0,
            "has_data": bool(round_list),
            "teams": teams,
        }

    report(74, "统计道具与娱乐数据")
    periods = {
        "first": pack(first_r, "上半场"),
        "second": pack(second_r, "下半场"),
        "overtime": pack(ot_r, "加时"),
    }

    report(90, "计算汇总指标")
    all_players = compute(None)

    # 全局武器统计（诊断用）
    weapons_death = {}
    if not deaths.empty and "weapon" in deaths.columns:
        for w in deaths["weapon"].dropna():
            k = norm_weapon(w)
            weapons_death[k] = weapons_death.get(k, 0) + 1

    othertype_counts = {}
    if not others.empty and "othertype" in others.columns:
        for v in others["othertype"].dropna():
            othertype_counts[str(v)] = othertype_counts.get(str(v), 0) + 1

    # ---------- 构造时间轴 ----------
    # 在统计之后细化每个回合的简要/详细：比分、结束方式、逐条击杀（按 tick 顺序）
    # 事件归属：tick 在 [start, next_start) 内的都算该回合
    per_round_deaths = {i: [] for i in range(1, n_rounds + 1)}
    per_round_plants = {i: [] for i in range(1, n_rounds + 1)}
    per_round_defuses = {i: [] for i in range(1, n_rounds + 1)}
    if not deaths.empty:
        for _, r in deaths.iterrows():
            try:
                tk = int(r["tick"]) if pd.notna(r.get("tick")) else -1
            except Exception:
                continue
            rnd = round_of(tk)
            if 1 <= rnd <= n_rounds:
                # 跳过热身击杀（round_of 会为 0）
                per_round_deaths[rnd].append(r)
    if not bombs.empty:
        for _, r in bombs.iterrows():
            try:
                tk = int(r["tick"]) if pd.notna(r.get("tick")) else -1
            except Exception:
                continue
            rnd = round_of(tk)
            if 1 <= rnd <= n_rounds:
                per_round_plants[rnd].append(r)
    if not defuses.empty:
        for _, r in defuses.iterrows():
            try:
                tk = int(r["tick"]) if pd.notna(r.get("tick")) else -1
            except Exception:
                continue
            rnd = round_of(tk)
            if 1 <= rnd <= n_rounds:
                per_round_defuses[rnd].append(r)

    # 预计算比分增量：用 CCSTeam.m_iScore 的阶段差值也可在前端动态算，
    # 这里直接用胜者倒推累计比分，保证时间轴上可直接展示
    cum_A = 0
    cum_B = 0
    win_roster_map = {}  # rnd -> "A"/"B"
    for rnd in range(1, n_rounds + 1):
        wt = round_win_team.get(rnd, 0)
        ct = round_ct_roster.get(rnd)
        if wt in (2, 3) and ct in ("A", "B"):
            winner_is_ct = (wt == 3)
            win_roster = ct if winner_is_ct else ("B" if ct == "A" else "A")
            win_roster_map[rnd] = win_roster
        else:
            win_roster_map[rnd] = None

    # 名册总人数（用于算剩余存活）
    total_A = len([nm for nm in names if roster_of.get(nm) == "A"])
    total_B = len([nm for nm in names if roster_of.get(nm) == "B"])
    if total_A == 0:
        total_A = 5
    if total_B == 0:
        total_B = 5

    # 构造每条
    for rnd in range(1, n_rounds + 1):
        kills = per_round_deaths[rnd]
        try:
            kills_sorted = sorted(kills, key=lambda r: int(r.get("tick", 0)) if pd.notna(r.get("tick")) else 0)
        except Exception:
            kills_sorted = kills
        rs = round_reason.get(rnd)
        end_label = ROUND_END_REASON_MAP.get(rs, "")
        if not end_label:
            if per_round_defuses[rnd]:
                end_label = "拆包成功"
            elif per_round_plants[rnd]:
                end_label = ""
            else:
                end_label = "歼敌" if kills_sorted else ""
        win_roster = win_roster_map.get(rnd)
        if win_roster == "A":
            cum_A += 1
        elif win_roster == "B":
            cum_B += 1

        # 剩余人数：总人数 - 该回合内该队死亡数（含自杀/团队击杀）
        deaths_A = 0
        deaths_B = 0
        for r in kills_sorted:
            vic = clean_name(r.get("user_name"))
            ro = roster_of.get(vic)
            if ro == "A":
                deaths_A += 1
            elif ro == "B":
                deaths_B += 1
        alive_A = max(0, total_A - deaths_A)
        alive_B = max(0, total_B - deaths_B)
        # 若出现团队击杀导致重复计算，存活不为负即可

        first_kill = None
        if kills_sorted:
            r0 = kills_sorted[0]
            first_kill = {
                "attacker": clean_name(r0.get("attacker_name")) or "",
                "victim": clean_name(r0.get("user_name")) or "",
                "weapon": norm_weapon(r0.get("weapon")),
                "headshot": bool(r0.get("headshot")),
            }
        cnt_by_attacker = {}
        for r in kills_sorted:
            a = clean_name(r.get("attacker_name"))
            if a and a in roster_of:
                cnt_by_attacker[a] = cnt_by_attacker.get(a, 0) + 1
        multi = []
        for nm, c in cnt_by_attacker.items():
            if c >= 2:
                multi.append({"name": nm, "kills": c})
        multi.sort(key=lambda x: -x["kills"])

        kill_rows = []
        for r in kills_sorted:
            kill_rows.append({
                "tick": int(r.get("tick")) if pd.notna(r.get("tick")) else 0,
                "attacker": clean_name(r.get("attacker_name")) or "",
                "victim": clean_name(r.get("user_name")) or "",
                "weapon": norm_weapon(r.get("weapon")),
                "headshot": bool(r.get("headshot")),
                "penetrated": bool(r.get("penetrated")) if "penetrated" in r else False,
                "thrusmoke": bool(r.get("thrusmoke")) if "thrusmoke" in r else False,
            })
        plant = None
        if per_round_plants[rnd]:
            rr = per_round_plants[rnd][0]
            plant = {"user": clean_name(rr.get("user_name")) or "", "site": str(rr.get("site", "")), "tick": int(rr.get("tick")) if pd.notna(rr.get("tick")) else 0}
        defuse = None
        if per_round_defuses[rnd]:
            rr = per_round_defuses[rnd][0]
            defuse = {"user": clean_name(rr.get("user_name")) or "", "tick": int(rr.get("tick")) if pd.notna(rr.get("tick")) else 0}

        if rnd <= HALF_ROUNDS:
            period = "first"
        elif rnd <= REGULATION_ROUNDS:
            period = "second"
        else:
            period = "overtime"

        winner_label = ""
        if win_roster in ("A", "B"):
            winner_label = win_roster
        # 概要只保留：获胜方式 + 剩余人数
        alive_text = "{}v{}".format(alive_A, alive_B)
        if end_label:
            brief = "{}  {}".format(end_label, alive_text)
        else:
            brief = alive_text

        # 详情按时间顺序：合并击杀/下包/拆包，按 tick 排序，纯文字
        # 时间以 1:55 倒计时显示（剩余时间），而不是从 0:00 正计时
        # CS2 常规回合 115 秒：用 tick_start/next_start 估算该回合的实际时长
        tick_start = int(round_ticks[rnd - 1]) if rnd - 1 < len(round_ticks) else 0
        if rnd < n_rounds:
            tick_end_est = int(round_ticks[rnd])
        else:
            # 最后一回合没有下一回合起点：用本回合最后事件 + 2 秒估算
            last_tick = tick_start
            for kr in kill_rows:
                if kr["tick"] > last_tick:
                    last_tick = kr["tick"]
            if plant and plant["tick"] > last_tick:
                last_tick = plant["tick"]
            if defuse and defuse["tick"] > last_tick:
                last_tick = defuse["tick"]
            tick_end_est = last_tick + 128
        dur_ticks = tick_end_est - tick_start
        # 常规 115 秒 = 7360 tick（64 tick/秒）；过短或过长都夹紧到 95~125 秒，避免异常 demo 显示错乱
        dur_sec = dur_ticks / 64.0
        if dur_sec < 95 or dur_sec > 125:
            dur_sec = 115.0
            dur_ticks = int(dur_sec * 64)
        def _remain_label(ev_tick):
            remain = (tick_end_est - ev_tick) / 64.0
            # 夹到 [0, dur_sec]
            if remain < 0:
                remain = 0
            if remain > dur_sec:
                remain = dur_sec
            mm = int(remain // 60)
            ss = int(remain % 60)
            return "{:01d}:{:02d}".format(mm, ss)
        events = []
        for kr in kill_rows:
            tlabel = _remain_label(kr["tick"])
            extra = ""
            if kr["headshot"]:
                extra += " 爆头"
            if kr["penetrated"]:
                extra += " 穿墙"
            if kr["thrusmoke"]:
                extra += " 穿烟"
            events.append({"tick": kr["tick"], "t": tlabel, "text": "{} → {}  {}{}".format(kr["attacker"], kr["victim"], kr["weapon"], extra)})
        if plant:
            tlabel = _remain_label(plant["tick"])
            site_map = {"326": "A", "327": "B"}
            site_lab = site_map.get(str(plant["site"]), str(plant["site"])) if plant["site"] else ""
            events.append({"tick": plant["tick"], "t": tlabel, "text": "下包  {}  {}".format(plant["user"], ("点位" + site_lab) if site_lab else "")})
        if defuse:
            tlabel = _remain_label(defuse["tick"])
            events.append({"tick": defuse["tick"], "t": tlabel, "text": "拆包  {}".format(defuse["user"])})
        events.sort(key=lambda x: x["tick"])

        # ---- 右侧「详细信息」面板用的事件行 ----
        # 和上面的 events 有三点不同：
        #   1. 时间是从回合开始「正计时」（0:00 起），不是剩余时间倒计时；
        #   2. 每行都带当时的存活人数（击杀按顺序递减，用于显示 5v5 / 4v5 ...）；
        #   3. 标出每个名字当时属于 CT 还是 T（半场会交换，界面按这个上色）。
        ct_r = round_ct_roster.get(rnd, "")

        def _side_of(name):
            r = roster_of.get(name)
            if r == "A":
                return "CT" if ct_r == "A" else ("T" if ct_r == "B" else "")
            if r == "B":
                return "CT" if ct_r == "B" else ("T" if ct_r == "A" else "")
            return ""

        # 计时起点 = 冻结结束（拿不到就退回 round_start）；终点 = 真正的 round_end
        t_origin = round_freeze.get(rnd) or tick_start
        t_end_real = round_end_tick.get(rnd) or tick_end_est

        # 显示的是「回合计时器」：从 1:55 倒着走到 0:00，和游戏 HUD 一致。
        # 提前结束的回合（团灭）停在剩余时间上；下包后拖过 1:55 的回合夹到 0:00。
        ROUND_TIME = 115.0

        def _remain(tick):
            sec = ROUND_TIME - (tick - t_origin) / 64.0
            if sec < 0:
                sec = 0.0
            elif sec > ROUND_TIME:
                sec = ROUND_TIME
            return "{:01d}:{:02d}".format(int(sec // 60), int(sec % 60))

        live = {"A": total_A, "B": total_B}
        detail = [{
            "t": _remain(t_origin), "tick": t_origin, "kind": "start",
            "alive_a": live["A"], "alive_b": live["B"], "text": "回合开始",
        }]
        merged = [("kill", kr["tick"], kr) for kr in kill_rows]
        if plant:
            merged.append(("plant", plant["tick"], plant))
        if defuse:
            merged.append(("defuse", defuse["tick"], defuse))
        merged.sort(key=lambda x: x[1])
        # 回合判定结束后（下包/拆包/团灭已定）仍可能有击杀入账，tick 会比 round_end 还大。
        # 终点至少取到最后一个事件的 tick，否则详情里时间会倒着走。
        if merged and merged[-1][1] > t_end_real:
            t_end_real = merged[-1][1]
        for kind, tk, obj in merged:
            if kind == "kill":
                vic_team = roster_of.get(obj["victim"])
                if vic_team in live:
                    live[vic_team] = max(0, live[vic_team] - 1)
                detail.append({
                    "t": _remain(tk), "tick": tk, "kind": "kill",
                    "alive_a": live["A"], "alive_b": live["B"],
                    "attacker": obj["attacker"], "victim": obj["victim"],
                    "attacker_side": _side_of(obj["attacker"]),
                    "victim_side": _side_of(obj["victim"]),
                    "weapon": obj["weapon"],
                    "headshot": obj["headshot"],
                    "penetrated": obj["penetrated"],
                    "thrusmoke": obj["thrusmoke"],
                })
            elif kind == "plant":
                detail.append({
                    "t": _remain(tk), "tick": tk, "kind": "plant",
                    "alive_a": live["A"], "alive_b": live["B"],
                    "user": obj["user"], "user_side": _side_of(obj["user"]),
                    "site": obj["site"],
                })
            else:
                detail.append({
                    "t": _remain(tk), "tick": tk, "kind": "defuse",
                    "alive_a": live["A"], "alive_b": live["B"],
                    "user": obj["user"], "user_side": _side_of(obj["user"]),
                })
        if winner_label == "A":
            winner_side = "CT" if ct_r == "A" else ("T" if ct_r == "B" else "")
        elif winner_label == "B":
            winner_side = "CT" if ct_r == "B" else ("T" if ct_r == "A" else "")
        else:
            winner_side = ""
        detail.append({
            "t": _remain(t_end_real), "tick": t_end_real, "kind": "end",
            "alive_a": live["A"], "alive_b": live["B"],
            "winner": winner_label, "winner_side": winner_side, "reason": end_label,
        })

        timeline.append({
            "round": rnd,
            "period": period,
            "winner": winner_label,
            "end_reason": end_label,
            "end_reason_code": int(rs) if rs is not None else 0,
            "ct_roster": round_ct_roster.get(rnd, ""),
            "score": {"A": int(cum_A), "B": int(cum_B)},
            "alive": {"A": int(alive_A), "B": int(alive_B)},
            "alive_text": alive_text,
            "brief": brief,
            "first_kill": first_kill,
            "multi": multi,
            "kills": kill_rows,
            "events": events,
            "detail": detail,
            "plant": plant,
            "defuse": defuse,
            "tick_start": tick_start,
        })

    result = {
        "demo": {
            "map": header.get("map_name"),
            "server": header.get("server_name"),
            "client": header.get("client_name"),
            "demo_version": header.get("demo_version_name"),
            "patch_version": header.get("patch_version"),
            "rounds": n_rounds,
            "players": len(all_players),
            "total_kills": count_match(deaths),
            "total_hurts": count_match(hurts),
            "other_deaths": count_match(others),
            "bombs_planted": count_match(bombs),
            "bombs_defused": count_match(defuses),
            "half_rounds": HALF_ROUNDS,
            "regulation_rounds": REGULATION_ROUNDS,
        },
        "teams": {
            "A": {"label": "队伍 1", "start_side": start_side.get("A", "?")},
            "B": {"label": "队伍 2", "start_side": start_side.get("B", "?")},
        },
        "periods": periods,
        "timeline": timeline,
        "players": all_players,
        "diagnostics": {
            "weapons_in_death": dict(sorted(weapons_death.items(),
                                            key=lambda kv: -kv[1])),
            "other_death_types": othertype_counts,
        },
    }

    report(96, "写入报告")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)

    report(100, "完成")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        err = (sys.argv[2] + ".error.txt") if len(sys.argv) > 2 else "error.txt"
        with open(err, "w", encoding="utf-8") as f:
            f.write(traceback.format_exc())
        raise
