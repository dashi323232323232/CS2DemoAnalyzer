# -*- coding: utf-8 -*-
"""fetch-hltv-sim.py — 把 HLTV Major 模拟器的数据转成 data/hltv-major.json。

为什么需要「离线转换」这一步
--------------------------------------------------------------------------
HLTV 前面挂着 Cloudflare 的人机验证。实测过这些通道，全部失败：

    urllib / requests             -> 403 "Just a moment..."
    curl（带全套浏览器头）         -> 403
    Node fetch                    -> 403
    Edge --headless=new -dump-dom -> 返回「请稍候…」挑战页，没有真实内容

也就是说「程序自己去抓」这条路在普通网络环境下走不通，能过验证的只有
真实浏览器会话。所以流程改成两步：

    1) 在浏览器里打开 https://www.hltv.org/major/simulator
       看到表格后 Ctrl+S 存成 .html
    2) 运行本脚本，把 HTML 里的模拟器 JSON 抽出来规范化

    python tools/fetch-hltv-sim.py --html "C:\path\to\simulator.html"

生成的 data/hltv-major.json 会被软件里的「Major Pick'em」页直接读取。
"""
import os
import re
import sys
import json
import argparse
import datetime

SIM_URL = "https://www.hltv.org/major/simulator"


def unescape(s):
    return (s.replace("&quot;", '"').replace("&amp;", "&")
             .replace("&lt;", "<").replace("&gt;", ">")
             .replace("&#x27;", "'").replace("&#39;", "'"))


def extract_json(page):
    m = re.search(r'data-multi-stage-simulator-json="([\s\S]*?)"(?=[\s>])', page)
    if not m:
        raise RuntimeError(
            "页面里找不到 data-multi-stage-simulator-json。\n"
            "常见原因：保存下来的是 Cloudflare 的挑战页，不是真实页面。\n"
            "请先在浏览器里看到模拟器表格，再 Ctrl+S 保存。")
    return json.loads(unescape(m.group(1)))


def build(raw):
    data = {
        "source": SIM_URL,
        "fetchedAt": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
        "event": raw.get("name"),
        "stages": [],
        "playoffs": {"name": ((raw.get("playoffs") or {}).get("bracket") or {}).get("name"),
                     "rounds": []},
    }

    for st in raw.get("swissStages", []):
        g = st["group"]
        teams = []
        for t in g.get("teams", []):
            tid = t.get("teamId") or {}
            teams.append({
                "slot": (tid.get("eventTeamSlotId") or {}).get("eventTeamSlotId"),
                "teamId": (tid.get("teamId") or {}).get("teamId"),
                "name": t.get("teamName"),
                "logo": (t.get("teamLogo") or {}).get("dayLogoURL"),
            })
        by_slot = {t["slot"]: t for t in teams}

        seedings = []
        for s in ((g.get("initialSeedings") or {}).get("orderedSeedings") or []):
            seedings.append({
                "slot": ((s.get("teamId") or {}).get("eventTeamSlotId") or {}).get("eventTeamSlotId"),
                "seed": s.get("seedingOrdinal"),
            })
        seed_by_slot = {s["slot"]: s["seed"] for s in seedings}

        matches = []
        for bucket, arr in (g.get("matches") or {}).items():
            for mt in (arr or []):
                s1 = ((mt.get("team1") or {}).get("eventTeamSlotId") or {}).get("eventTeamSlotId")
                s2 = ((mt.get("team2") or {}).get("eventTeamSlotId") or {}).get("eventTeamSlotId")
                t = None
                if mt.get("timestamp"):
                    t = datetime.datetime.fromtimestamp(
                        mt["timestamp"] / 1000).astimezone().isoformat(timespec="seconds")
                matches.append({
                    "bucket": bucket,
                    "matchId": (mt.get("matchId") or {}).get("matchId"),
                    "time": t,
                    "a": (by_slot.get(s1) or {}).get("name", "TBD"),
                    "aSeed": seed_by_slot.get(s1),
                    "b": (by_slot.get(s2) or {}).get("name", "TBD"),
                    "bSeed": seed_by_slot.get(s2),
                })

        data["stages"].append({
            "name": st.get("name"),
            "teams": teams,
            "seedings": seedings,
            "matches": matches,
            "firstRoundRules": g.get("firstRoundRules"),
            "successorRoundRules": ((g.get("successorRoundRules") or {}).get("type") or "").split(".")[-1],
        })

    for rd in (((raw.get("playoffs") or {}).get("bracket") or {}).get("rounds") or []):
        slots = [{"id": (rd[k].get("slotId") or {}).get("id")}
                 for k in rd if k.startswith("slot") and isinstance(rd[k], dict)]
        data["playoffs"]["rounds"].append({
            "type": rd.get("type"),
            "name": (rd.get("roundName") or {}).get("name"),
            "short": (rd.get("roundName") or {}).get("shortName"),
            "slots": slots,
        })
    return data


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    default_out = os.path.join(os.path.dirname(here), "data", "hltv-major.json")

    ap = argparse.ArgumentParser(description="把 HLTV 模拟器页面 HTML 转成 data/hltv-major.json")
    ap.add_argument("--html", required=True, help="浏览器里 Ctrl+S 存下来的模拟器页面（.html）")
    ap.add_argument("--out", default=default_out, help="输出路径，默认 data/hltv-major.json")
    args = ap.parse_args()

    if not os.path.exists(args.html):
        print("找不到 HTML:", args.html)
        return 1

    page = open(args.html, encoding="utf-8", errors="replace").read()
    raw = extract_json(page)
    data = build(raw)

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)

    print("赛事:", data["event"])
    for st in data["stages"]:
        print("  %-8s 队伍 %2d  对阵 %2d" % (st["name"], len(st["teams"]), len(st["matches"])))
    print("淘汰赛轮次:", len(data["playoffs"]["rounds"]))
    print("已写入:", args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
