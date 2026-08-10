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
PARSED_FILE="$TMP_DIR/parsed.json"

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
 "integrationCost":"S|M|L",
 "target":"конкретный конфиг, компонент или причина отказа",
 "rationale":"краткая оценка impact, integration-cost, risk, reversibility",
 "bestCandidate":{"fullName":"...","url":"..."} или null}.

Правила:
- config-tune: достаточно числовой/конфигурационной ручки Tier-1; код не встраивать.
- Оцени integration-cost и reversibility с ВЫСОКИМ весом. integrationCost:
  S — локальная обратимая правка, M — ограниченная интеграция, L — большая
  миграция или системная замена.
- integrate допустим ТОЛЬКО при integrationCost S или M, реальном совпадении
  кандидата с доменом гипотезы, заметном impact, приемлемых лицензии и риске.
  bestCandidate обязан быть одним из входных кандидатов.
- Смена БД, замена фреймворка и другие L-миграции по умолчанию дают reject или
  config-tune, но не integrate. Высокий impact сам по себе не делает L обратимой.
- Если у гипотезы нет кандидатов после фильтрации, верни reject с причиной
  "нет релевантных готовых решений"; не выдумывай bestCandidate или интеграцию.
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

if ! python3 "$ROOT/tools/improver-json.py" --type array "$RAW_FILE" \
  >"$PARSED_FILE" 2>/dev/null; then
  printf '[]\n'
  exit 0
fi

# LLM-ответ нормализуем fail-open: дорогая или выдуманная интеграция не должна
# пройти только потому, что модель нарушила инструкцию промпта.
python3 - "$HYPOTHESES_FILE" "$CANDIDATES_FILE" "$PARSED_FILE" <<'PY' 2>/dev/null || printf '[]\n'
import json
import sys
from pathlib import Path

hypotheses = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
candidate_rows = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
verdicts = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))
if not all(isinstance(value, list) for value in (hypotheses, candidate_rows, verdicts)):
    raise ValueError("inputs must be arrays")

candidates_by_id = {}
for row in candidate_rows:
    if not isinstance(row, dict) or not row.get("hypothesisId"):
        continue
    values = row.get("candidates", [])
    candidates_by_id[str(row["hypothesisId"])] = (
        values if isinstance(values, list) else []
    )

verdicts_by_id = {
    str(row.get("hypothesisId")): row
    for row in verdicts
    if isinstance(row, dict) and row.get("hypothesisId")
}
normalized = []
for hypothesis in hypotheses:
    if not isinstance(hypothesis, dict) or not hypothesis.get("id"):
        continue
    hypothesis_id = str(hypothesis["id"])
    candidates = candidates_by_id.get(hypothesis_id, [])
    verdict = verdicts_by_id.get(hypothesis_id, {})
    verdict = dict(verdict) if isinstance(verdict, dict) else {}
    verdict["hypothesisId"] = hypothesis_id

    cost = str(verdict.get("integrationCost", "")).upper()
    if cost not in {"S", "M", "L"}:
        cost = "L"
    verdict["integrationCost"] = cost

    if not candidates:
        verdict.update(
            {
                "verdict": "reject",
                "integrationCost": cost,
                "target": "нет релевантных готовых решений",
                "rationale": "нет релевантных готовых решений",
                "bestCandidate": None,
            }
        )
    elif verdict.get("verdict") not in {"config-tune", "integrate", "reject"}:
        verdict.update(
            {
                "verdict": "reject",
                "target": "оценка недоступна",
                "rationale": "LLM не вернула допустимый вердикт",
                "bestCandidate": None,
            }
        )
    elif verdict.get("verdict") == "integrate" and cost == "L":
        verdict.update(
            {
                "verdict": "reject",
                "target": "слишком высокая стоимость интеграции",
                "rationale": (
                    "integrationCost=L: большая миграция недостаточно обратима "
                    "для автоматического integrate"
                ),
                "bestCandidate": None,
            }
        )
    elif verdict.get("verdict") == "integrate":
        selected = verdict.get("bestCandidate")
        selected_url = (
            str(selected.get("url", "")).strip()
            if isinstance(selected, dict)
            else ""
        )
        candidate = next(
            (
                row
                for row in candidates
                if isinstance(row, dict)
                and str(row.get("url", "")).strip() == selected_url
            ),
            None,
        )
        domain_terms = hypothesis.get("domainTerms", [])
        if isinstance(domain_terms, str):
            domain_terms = [domain_terms]
        domain_terms = [
            str(value).strip().lower()
            for value in domain_terms
            if str(value).strip()
        ]
        searchable = ""
        if candidate:
            searchable = (
                f"{candidate.get('fullName', '')} {candidate.get('description', '')}"
            ).lower()
        if not candidate:
            verdict.update(
                {
                    "verdict": "reject",
                    "target": "кандидат отсутствует во входном поиске",
                    "rationale": "bestCandidate не найден среди входных кандидатов",
                    "bestCandidate": None,
                }
            )
        elif domain_terms and not any(term in searchable for term in domain_terms):
            verdict.update(
                {
                    "verdict": "reject",
                    "target": "кандидат не совпадает с доменом гипотезы",
                    "rationale": "bestCandidate не прошёл domainTerms relevance-gate",
                    "bestCandidate": None,
                }
            )
    normalized.append(verdict)

print(json.dumps(normalized, ensure_ascii=False, sort_keys=True))
PY
exit 0
