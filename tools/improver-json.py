#!/usr/bin/env python3
"""Извлекает последний JSON-документ из ответа CLI-модели.

Claude по контракту должен вернуть JSON последней строкой. Разбор также
принимает fenced-блок: это сохраняет fail-open при случайной markdown-обёртке.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


def candidates(text: str) -> list[str]:
    result = [line.strip() for line in text.splitlines() if line.strip()]
    result.extend(
        match.strip()
        for match in re.findall(r"```(?:json)?\s*(.*?)```", text, flags=re.I | re.S)
        if match.strip()
    )
    result.append(text.strip())
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("input")
    parser.add_argument("--type", choices=("array", "object"), required=True)
    args = parser.parse_args()

    try:
        text = Path(args.input).read_text(encoding="utf-8")
    except OSError:
        print("[]" if args.type == "array" else "{}")
        return 0

    expected = list if args.type == "array" else dict
    for raw in reversed(candidates(text)):
        try:
            value = json.loads(raw)
        except (TypeError, ValueError):
            continue
        if isinstance(value, expected):
            print(json.dumps(value, ensure_ascii=False, sort_keys=True))
            return 0

    print("[]" if args.type == "array" else "{}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
