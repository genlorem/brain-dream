#!/usr/bin/env bash
set -uo pipefail

# Оценка — второй и последний LLM-шаг. Исходные JSON читаются Python-ом и
# записываются в prompt-файл без shell-интерполяции.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HYPOTHESES_FILE="${1:-}"
CANDIDATES_FILE="${2:-}"
CLAUDE="${CLAUDE_BIN:-claude}"

if [[ -z "$HYPOTHESES_FILE" || -z "$CANDIDATES_FILE" ]]; then
  printf '[]\n'
  exit 0
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/brain-improver-evaluate.XXXXXX")" || {
  printf '[]\n'
  exit 0
}
trap 'rm -rf "$TMP_DIR"' EXIT
PROMPT_FILE="$TMP_DIR/prompt.txt"
RAW_FILE="$TMP_DIR/response.txt"

if ! python3 - "$HYPOTHESES_FILE" "$CANDIDATES_FILE" "$PROMPT_FILE" <<'PY'
import json
import sys
from pathlib import Path

hypotheses_path, candidates_path, prompt_path = sys.argv[1:]
hypotheses = json.loads(Path(hypotheses_path).read_text(encoding="utf-8"))
candidates = json.loads(Path(candidates_path).read_text(encoding="utf-8"))
if not isinstance(hypotheses, list) or not isinstance(candidates, list):
    raise ValueError("inputs must be arrays")

prompt = """Ты оцениваешь гипотезы улучшения Brain и найденные реализации.

Верни только валидный JSON-массив последней строкой. Ровно один элемент на
гипотезу:
{"hypothesisId":"id","verdict":"config-tune|integrate|reject",
 "target":"конкретный конфиг, компонент или причина отказа",
 "rationale":"краткая оценка impact, integration-cost, risk, reversibility",
 "bestCandidate":{"fullName":"...","url":"..."} или null}.

Правила:
- config-tune: достаточно числовой/конфигурационной ручки Tier-1; код не встраивать.
- integrate: готовая реализация даёт заметный impact, лицензия и риск приемлемы,
  интеграция обратима. bestCandidate обязан быть одним из входных кандидатов.
- reject: слабый сигнал, нет пригодного кандидата или риск выше пользы.
- Не предлагай auto-merge и прямые изменения ручных Brain-нод.

Гипотезы:
""" + json.dumps(hypotheses, ensure_ascii=False, sort_keys=True) + \
"\n\nGitHub-кандидаты:\n" + json.dumps(candidates, ensure_ascii=False, sort_keys=True) + "\n"
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
