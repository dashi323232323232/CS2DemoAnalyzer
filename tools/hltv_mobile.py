# -*- coding: utf-8 -*-
"""hltv_mobile.py — 通过 HLTV 移动端 API 取 Major 数据。

为什么用移动端 API
------------------
HLTV 网页版挂了 Cloudflare，普通 HTTP 客户端一律 403（实测 urllib / curl /
Node fetch / 无头 Edge 全部被拦）。但官方 Android 客户端走的是另一套接口：

    https://www.hltv.org/mobile/...

这套接口只认移动端 User-Agent（org.hltv.android/3.x），不需要任何 cookie、
不需要 Cloudflare 挑战、也不需要代理。实测直接 GET 就返回 200 和完整 JSON：

    /mobile/startupCheck      200
    /mobile/MatchesV4         200   （1.5MB，全部比赛 + 队伍 + logo）
    /mobile/MatchScreen?id=…  200   （单场详情，208KB）

只有少数端点要求完整性签名（例如 /FrontpageV2 返回 integrity_required），
但比赛相关的接口都能用，足够本项目使用。

用法：
    python tools/hltv_mobile.py --probe
    python tools/hltv_mobile.py --event 9303 --out data/major-live.json
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from urllib.parse import urlencode

BASE = "https://www.hltv.org/mobile"
UA = "org.hltv.android/3.0.34;release(Android; SM-S918B; Android 14)"
HEADERS = {
    "User-Agent": UA,
    "Referer": "https://www.hltv.org/",
    "Accept": "application/json, text/plain, */*",
    "Accept-Language": "en-US,en;q=0.9",
}


def get(path, params=None, timeout=40):
    url = BASE + path
    if params:
        url += "?" + urlencode(params)
    req = urllib.request.Request(url, headers=HEADERS)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def swiss_record(team_count, wins, losses):
    return "%d-%d" % (wins, losses)


def build_event(event_id):
    """把一个事件的所有比赛整理成 Pick'em 需要的样子。"""
    data = get("/MatchesV4")
    all_matches = data.get("matches", [])
    ev = [m for m in all_matches if str(m.get("eventId")) == str(event_id)]

    if not ev:
        return None

    # 队伍表（用出现顺序 + teamId 去重）
    teams = {}
    for m in ev:
        for side in ("team1", "team2"):
            t = m.get(side) or {}
            tid = t.get("teamId")
            if tid and tid not in teams:
                avatar = t.get("avatar") or {}
                teams[tid] = {
                    "teamId": tid,
                    "name": t.get("name"),
                    "color": t.get("teamColor"),
                    "logo": avatar.get("pngUrl") or avatar.get("svgOrPngUrl"),
                    "logo500": (avatar.get("pngUrl") or "").replace("w=50", "w=500"),
                }

    matches = []
    for m in ev:
        res = m.get("matchResult") or {}
        matches.append({
            "matchId": m.get("matchId"),
            "start": m.get("startDateTime"),
            "mapShort": m.get("mapShort"),
            "stars": m.get("stars"),
            "live": bool(m.get("live")),
            "finished": bool(m.get("postMatch")),
            "a": (m.get("team1") or {}).get("name"),
            "b": (m.get("team2") or {}).get("name"),
            "aId": (m.get("team1") or {}).get("teamId"),
            "bId": (m.get("team2") or {}).get("teamId"),
            "scoreA": res.get("team1Score"),
            "scoreB": res.get("team2Score"),
            "winnerId": res.get("winnerTeamId"),
        })
    matches.sort(key=lambda x: (x["start"] or "", x["matchId"] or ""))

    return {
        "eventId": str(event_id),
        "eventName": ev[0].get("eventName"),
        "eventLogo": ev[0].get("eventLogo"),
        "teams": list(teams.values()),
        "matches": matches,
    }


def probe():
    checks = [
        ("/startupCheck", None),
        ("/MatchesV4", None),
    ]
    for path, params in checks:
        try:
            d = get(path, params)
            kind = list(d.keys())[:6] if isinstance(d, dict) else type(d).__name__
            print("  OK   %-18s %s" % (path, kind))
        except urllib.error.HTTPError as e:
            print("  HTTP %-4s %-18s %s" % (e.code, path, e.read()[:80]))
        except Exception as e:
            print("  ERR       %-18s %s" % (path, e))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--probe", action="store_true", help="只检查接口是否可用")
    ap.add_argument("--event", default=None, help="事件 ID（9303 = Stage 1）")
    ap.add_argument("--out", default=None, help="输出 JSON 路径")
    ap.add_argument("--majors", action="store_true", help="列出所有 Major 相关事件")
    args = ap.parse_args()

    if args.probe:
        print("HLTV mobile API 探测:")
        probe()
        return 0

    if args.majors:
        d = get("/MatchesV4")
        seen = {}
        for m in d.get("matches", []):
            if m.get("isMajor"):
                seen[str(m.get("eventId"))] = m.get("eventName")
        for k, v in sorted(seen.items()):
            print("  eventId=%s  %s" % (k, v))
        return 0

    if not args.event:
        print("需要 --event / --probe / --majors")
        return 2

    here = os.path.dirname(os.path.abspath(__file__))
    out = args.out or os.path.join(os.path.dirname(here), "data", "major-live.json")

    data = build_event(args.event)
    if not data:
        print("该事件没有比赛数据:", args.event)
        return 1

    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)

    print("赛事:", data["eventName"])
    print("队伍:", len(data["teams"]), " 比赛:", len(data["matches"]))
    done = sum(1 for m in data["matches"] if m["finished"])
    print("已结束:", done, "/", len(data["matches"]))
    print("已写入:", out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
