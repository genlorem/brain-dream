#!/usr/bin/env python3
"""Кривые надёжности гейтов Jev сна v2 против слепых меток (ревизия 22.10, dream-v2.md §4, §11).

Вход: `reconstruct.py --out` (решения журнала + вероятности + дела под ключами C1..C5)
и метки `jev-truth-labeler` (`dream-case.jsonl`, `dream-actor.jsonl`).

  curves.py --recon FILE --labels DIR [--sure-only]
"""
from __future__ import annotations

import argparse
import json
from collections import Counter

BINS = [0.0, 0.5, 0.7, 0.8, 0.9, 0.95, 1.01]


def load(path):
    return [json.loads(x) for x in open(path, encoding="utf-8") if x.strip()]


def wilson_lo(k, n, z=1.96):
    if not n:
        return 0.0
    p = k / n
    return (p + z * z / (2 * n) - z * ((p * (1 - p) + z * z / (4 * n)) / n) ** 0.5) / (1 + z * z / n)


def curve(rows, name):
    """rows: (prob, correct). Таблица по корзинам и порог «точность принятых ≥ 90 %»."""
    print(f"\n## {name}: n={len(rows)}, согласие {sum(c for _, c in rows)}/{len(rows)}")
    print("| корзина p | n | верно | доля |")
    print("|---|---|---|---|")
    for lo, hi in zip(BINS, BINS[1:]):
        b = [c for p, c in rows if lo <= p < hi]
        if b:
            print(f"| {lo:.2f}–{min(hi, 1):.2f} | {len(b)} | {sum(b)} | {sum(b) / len(b):.0%} |")
    print("| порог p ≥ | принято | верно | точность | нижняя граница 95 % |")
    print("|---|---|---|---|---|")
    for t in (0.5, 0.6, 0.7, 0.8, 0.9, 0.95, 0.99):
        acc = [c for p, c in rows if p >= t]
        if acc:
            k = sum(acc)
            print(f"| {t:.2f} | {len(acc)} | {k} | {k / len(acc):.0%} | {wilson_lo(k, len(acc)):.0%} |")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--recon", required=True)
    ap.add_argument("--labels", required=True)
    ap.add_argument("--sure-only", action="store_true")
    a = ap.parse_args()
    recon = {r["insight"]: r for r in load(a.recon)}
    lab = {q: {x["key"]: x for x in load(f"{a.labels}/dream-{q}.jsonl")} for q in ("case", "actor")}

    def ok(q, k):
        x = lab[q].get(k)
        return x is not None and not (a.sure_only and x.get("unsure"))

    # К какому делу: выбор Jev (argmax) против метки; вероятность — case_conf.
    rows, conf = [], Counter()
    for k, r in recon.items():
        if not ok("case", k):
            continue
        truth, choice = lab["case"][k]["label"], r["choice"]
        rows.append((r["p"]["case_conf"], truth == choice))
        conf[(("merge" if r["event"] == "merge" else "open"), "new" if truth == "new" else "same")] += 1
    curve(rows, "case: выбор Jev = метке")
    print("\nРешение журнала × метка:", dict(conf))
    merges = [(recon[k], lab["case"][k]["label"]) for k in recon if ok("case", k) and recon[k]["event"] == "merge"]
    right = sum(r["case"] == next((c["id"] for c in r["open_cases"] if c["key"] == t), None) for r, t in merges)
    print(f"Склейка: верное дело {right}/{len(merges)}")
    repeats = [k for k in recon if ok("case", k) and lab["case"][k]["label"] != "new"]
    caught = sum(recon[k]["event"] == "merge" and recon[k]["choice"] == lab["case"][k]["label"] for k in repeats)
    print(f"Повтор пойман в нужное дело: {caught}/{len(repeats)}")

    # Исполнитель: argmax Jev против метки; отдельно — опасная ошибка «агенту вместо владельца».
    rows, mat = [], Counter()
    for k, r in recon.items():
        if not ok("actor", k):
            continue
        pa = r["p"]["actor"]
        choice = max(pa.items(), key=lambda t: t[1])[0]
        truth = lab["actor"][k]["label"]
        rows.append((pa[choice], truth == choice))
        mat[(choice, truth)] += 1
    curve(rows, "actor: argmax Jev = метке")
    print("\nМатрица (Jev → метка):", {f"{c}→{t}": n for (c, t), n in sorted(mat.items())})
    for cls in ("agent", "owner"):
        prs = [(recon[k]["p"]["actor"][cls], lab["actor"][k]["label"] == cls) for k in recon if ok("actor", k)]
        curve(prs, f"actor={cls}: p({cls}) как порог маршрута")


if __name__ == "__main__":
    main()
