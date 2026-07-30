#!/usr/bin/env bash
set -uo pipefail

# Превращает детерминированные сигналы в гипотезы. Данные вставляет Python
# напрямую в prompt-файл: shell не интерпретирует кавычки, `$` и бэктики.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIGNALS_FILE="${1:-}"
PROACTIVE_COUNT="${2:-}"
CONFIG_FILE="${3:-$ROOT/config/improver.json}"
CLAUDE="${CLAUDE_BIN:-claude}"

if [[ -z "$SIGNALS_FILE" || ! "$PROACTIVE_COUNT" =~ ^[0-9]+$ ]]; then
  printf '[]\n'
  exit 0
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/brain-improver-hypothesize.XXXXXX")" || {
  printf '[]\n'
  exit 0
}
trap 'rm -rf "$TMP_DIR"' EXIT
PROMPT_FILE="$TMP_DIR/prompt.txt"
RAW_FILE="$TMP_DIR/response.txt"

if ! python3 - "$SIGNALS_FILE" "$PROACTIVE_COUNT" "$CONFIG_FILE" "$PROMPT_FILE" <<'PY'
import json
import sys
from pathlib import Path

signals_path, count_raw, config_path, prompt_path = sys.argv[1:]
signals = json.loads(Path(signals_path).read_text(encoding="utf-8"))
if not isinstance(signals, list):
    raise ValueError("signals must be an array")
config = json.loads(Path(config_path).read_text(encoding="utf-8"))
seeds = config.get("keywordSeeds", [])
count = int(count_raw)

prompt = """Ты — Tier-2 улучшатель системы Brain.

Верни только JSON-массив последней строкой, без пояснений. Каждый элемент:
{"id":"стабильный-короткий-id","kind":"error|idea","signal":"signal-id или null",
 "hypothesis":"проверяемая гипотеза улучшения","keywords":["github search query", "..."]}.

Правила:
1. Для КАЖДОГО болевого сигнала создай одну гипотезу kind=error.
2. Дополнительно создай ровно N проактивных идей kind=idea, не привязанных к
   текущей ошибке: новые механизмы и улучшения второго мозга.
3. Не предлагай прямую правку ручных Brain-нод. Идеи должны быть обратимыми.
4. keywords — 1–3 коротких англоязычных запроса для поиска готового кода.
5. JSON обязан быть валидным; id не должны повторяться.

N:
""" + str(count) + "\n\nСтартовые темы:\n" + json.dumps(
    seeds, ensure_ascii=False, sort_keys=True
) + "\n\nБолевые сигналы:\n" + json.dumps(
    signals, ensure_ascii=False, sort_keys=True
) + "\n"
Path(prompt_path).write_text(prompt, encoding="utf-8")
PY
then
  printf '[]\n'
  exit 0
fi

if ! "$CLAUDE" -p --model claude-haiku-4-5 --no-session-persistence \
  <"$PROMPT_FILE" >"$RAW_FILE" 2>/dev/null; then
  printf '[]\n'
  exit 0
fi

python3 "$ROOT/tools/improver-json.py" --type array "$RAW_FILE" 2>/dev/null || printf '[]\n'
exit 0
