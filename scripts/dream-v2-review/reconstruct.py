#!/usr/bin/env python3
"""Восстановить пять ближайших открытых дел (C1..C5) на момент каждого решения журнала.

Журнал (`events.jsonl`) хранит вероятности Jev по ключам C1..C5, но не сами дела под
ключами. Скрипт повторяет свёртку `Ledger` и обновление векторов из `process_night`
по событиям журнала (решения берутся из журнала, Jev не зовётся) и пишет для каждой
находки окна список дел под ключами. Самопроверка: у `merge` дело под выбранным
ключом должно совпасть с `case` события.

  reconstruct.py --from 2026-10-08 --to 2026-10-21 --out FILE
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("dc", os.path.join(HERE, "../../tools/dream-cases.py"))
dc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dc)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--from", dest="d0", required=True)
    ap.add_argument("--to", dest="d1", required=True)
    ap.add_argument("--state", default=dc.STATE)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    events = [json.loads(x) for x in open(f"{a.state}/events.jsonl", encoding="utf-8")]
    led = dc.Ledger.__new__(dc.Ledger)
    led.cases, led.vecs = {}, {}
    night_vecs, out, bad = {}, [], 0
    for e in events:
        ins = e.get("insight")
        if ins:
            d = e["date"]
            if d not in night_vecs:
                items = dc.parse_top10(d)
                vs = dc.embed([f"{x['title']}. {x['body'][:400]} {x['action'][:200]}" for x in items])
                night_vecs[d] = {x["id"]: v for x, v in zip(items, vs)}
            v = night_vecs[d][ins]
            opened = led.open_cases()
            sims = sorted(((float(led.vecs[c["id"]] @ v), c) for c in opened if c["id"] in led.vecs),
                          key=lambda t: -t[0])[:5]
            keys = {f"C{i + 1}": (round(s, 3), c) for i, (s, c) in enumerate(sims)}
            if a.d0 <= d <= a.d1:
                p = e.get("p") or {}
                choice = max((p.get("case") or {"new": 1}).items(), key=lambda t: t[1])[0]
                ok = None
                if e["event"] == "merge":
                    ok = choice in keys and keys[choice][1]["id"] == e["case"]
                    bad += not ok
                out.append({"date": d, "insight": ins, "event": e["event"], "case": e.get("case"),
                            "choice": choice, "self_check": ok, "text": e["text"], "title": e["title"],
                            "p": p, "actor": e.get("actor"),
                            "open_cases": [{"key": k, "cos": s, "id": c["id"], "title": c["title"],
                                            "since": c["opened"], "latest_fact": c["facts"][-1][:300]}
                                           for k, (s, c) in keys.items()]})
            led._fold(e)
            if e["event"] == "merge" and e["case"] in led.vecs:
                w = led.vecs[e["case"]] * 0.7 + v * 0.3
                led.vecs[e["case"]] = w / np.linalg.norm(w)
            elif e["event"] == "open":
                led.vecs[e["case"]] = v
        else:
            led._fold(e)
    with open(a.out, "w", encoding="utf-8") as f:
        for r in out:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    merges = sum(r["event"] == "merge" for r in out)
    print(f"rows={len(out)} merges={merges} self_check_fail={bad}", file=sys.stderr)


if __name__ == "__main__":
    main()
