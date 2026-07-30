#!/usr/bin/env bash
set -uo pipefail

# Недельный Tier-2 контур Brain. Источники Brain читает, но ручные ноды не
# меняет: результатом integrate остаются только proposal и draft PR-артефакты.

ORCHESTRATOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${BRAIN_IMPROVER_REPO:-$(cd "$ORCHESTRATOR_DIR/.." && pwd)}"
CONFIG_FILE="${BRAIN_IMPROVER_CONFIG:-$REPO_ROOT/config/improver.json}"
RUN_DATE="${1:-${IMPROVER_RUN_DATE:-}}"
LOCK_FILE="${BRAIN_IMPROVER_LOCK:-/tmp/brain-improver.lock}"

if [[ -z "$RUN_DATE" ]]; then
  printf 'brain-improver: передай дату YYYY-MM-DD аргументом или IMPROVER_RUN_DATE\n' >&2
  exit 0
fi
if ! python3 - "$RUN_DATE" <<'PY' >/dev/null 2>&1
from datetime import date
import sys
value = sys.argv[1]
if date.fromisoformat(value).isoformat() != value:
    raise SystemExit(1)
PY
then
  printf 'brain-improver: дата должна быть валидной ISO-датой YYYY-MM-DD\n' >&2
  exit 0
fi

if [[ "${BRAIN_IMPROVER_FLOCKED:-0}" != "1" ]] && command -v flock >/dev/null 2>&1; then
  if ! env BRAIN_IMPROVER_FLOCKED=1 flock -n "$LOCK_FILE" "$0" "$@"; then
    printf 'brain-improver: другой прогон уже держит lock\n' >&2
  fi
  exit 0
fi

# Kill-switch проверяется до создания рабочих каталогов и вызовов внешних CLI.
ENABLED="$(python3 - "$CONFIG_FILE" <<'PY' 2>/dev/null
import json
import sys
from pathlib import Path
try:
    cfg = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    print("1" if cfg.get("enabled") is True else "0")
except Exception:
    print("0")
PY
)"
if [[ "$ENABLED" != "1" ]]; then
  exit 0
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/brain-improver.XXXXXX")" || exit 0
trap 'rm -rf "$TMP_DIR"' EXIT
SIGNALS_ALL="$TMP_DIR/signals-all.json"
SIGNALS_FILE="$TMP_DIR/signals.json"
HYPOTHESES_RAW="$TMP_DIR/hypotheses-raw.json"
HYPOTHESES_FILE="$TMP_DIR/hypotheses.json"
CANDIDATES_FILE="$TMP_DIR/candidates.json"
VERDICTS_FILE="$TMP_DIR/verdicts.json"
ACTIONS_FILE="$TMP_DIR/actions.json"

python3 "$REPO_ROOT/tools/improver-aggregate.py" --config "$CONFIG_FILE" \
  >"$SIGNALS_ALL" 2>/dev/null || printf '[]\n' >"$SIGNALS_ALL"

# maxHypotheses — общий потолок. Минимум одно место резервируем проактивной идее.
PROACTIVE_COUNT="$(python3 - "$CONFIG_FILE" "$SIGNALS_ALL" "$SIGNALS_FILE" <<'PY' 2>/dev/null
import json
import sys
from pathlib import Path
try:
    cfg = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    signals = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
    maximum = max(0, int(cfg.get("maxHypotheses", 6)))
    error_limit = max(0, maximum - 1)
    selected = signals[:error_limit] if isinstance(signals, list) else []
    Path(sys.argv[3]).write_text(
        json.dumps(selected, ensure_ascii=False, sort_keys=True), encoding="utf-8"
    )
    print(max(0, maximum - len(selected)))
except Exception:
    Path(sys.argv[3]).write_text("[]", encoding="utf-8")
    print(0)
PY
)"

"$REPO_ROOT/tools/improver-hypothesize.sh" \
  "$SIGNALS_FILE" "${PROACTIVE_COUNT:-0}" "$CONFIG_FILE" >"$HYPOTHESES_RAW" \
  2>/dev/null || printf '[]\n' >"$HYPOTHESES_RAW"

# Повторные hypothesisId из ledger не запускаем заново; одновременно
# нормализуем ответ LLM и применяем общий потолок.
python3 - "$CONFIG_FILE" "$HYPOTHESES_RAW" "$HYPOTHESES_FILE" <<'PY' 2>/dev/null || printf '[]\n' >"$HYPOTHESES_FILE"
import json
import os
import sys
from pathlib import Path

try:
    cfg = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    hypotheses = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
    maximum = max(0, int(cfg.get("maxHypotheses", 6)))
    ledger_path = Path(os.path.expanduser(cfg.get("paths", {}).get("ledger", "")))
    old_ids = set()
    try:
        for line in ledger_path.read_text(encoding="utf-8").splitlines():
            row = json.loads(line)
            if isinstance(row, dict) and row.get("hypothesisId"):
                old_ids.add(str(row["hypothesisId"]))
    except (OSError, ValueError):
        pass
    selected = []
    current_ids = set()
    for row in hypotheses if isinstance(hypotheses, list) else []:
        if not isinstance(row, dict):
            continue
        hid = str(row.get("id", "")).strip()
        if not hid or hid in old_ids or hid in current_ids:
            continue
        if row.get("kind") not in ("error", "idea") or not row.get("hypothesis"):
            continue
        keywords = row.get("keywords", [])
        if isinstance(keywords, str):
            keywords = [keywords]
        row["keywords"] = [str(value) for value in keywords if str(value).strip()][:3]
        selected.append(row)
        current_ids.add(hid)
        if len(selected) >= maximum:
            break
    Path(sys.argv[3]).write_text(
        json.dumps(selected, ensure_ascii=False, sort_keys=True), encoding="utf-8"
    )
except Exception:
    Path(sys.argv[3]).write_text("[]", encoding="utf-8")
PY

"$REPO_ROOT/tools/improver-github-search.sh" \
  "$HYPOTHESES_FILE" "$RUN_DATE" "$CONFIG_FILE" >"$CANDIDATES_FILE" \
  2>/dev/null || printf '[]\n' >"$CANDIDATES_FILE"

"$REPO_ROOT/tools/improver-evaluate.sh" \
  "$HYPOTHESES_FILE" "$CANDIDATES_FILE" >"$VERDICTS_FILE" \
  2>/dev/null || printf '[]\n' >"$VERDICTS_FILE"

# Арм применения никогда не меняет Brain-ноды и не делает merge. Для integrate
# он фиксирует имя будущей ветки, vendor pin, patch-plan и draft PR description.
python3 - \
  "$REPO_ROOT" "$RUN_DATE" "$HYPOTHESES_FILE" "$CANDIDATES_FILE" \
  "$VERDICTS_FILE" "$ACTIONS_FILE" <<'PY' 2>/dev/null || printf '[]\n' >"$ACTIONS_FILE"
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

repo = Path(sys.argv[1])
run_date = sys.argv[2]
hypotheses = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))
candidate_rows = json.loads(Path(sys.argv[4]).read_text(encoding="utf-8"))
verdicts = json.loads(Path(sys.argv[5]).read_text(encoding="utf-8"))
actions_path = Path(sys.argv[6])
hyp_by_id = {
    str(row.get("id")): row for row in hypotheses if isinstance(row, dict) and row.get("id")
}
candidate_by_hypothesis = {}
for row in candidate_rows if isinstance(candidate_rows, list) else []:
    if not isinstance(row, dict) or not row.get("hypothesisId"):
        continue
    values = row.get("candidates", [])
    candidate_by_hypothesis[str(row["hypothesisId"])] = {
        str(candidate.get("url")): candidate
        for candidate in values if isinstance(candidate, dict) and candidate.get("url")
    }
proposal_dir = Path(
    os.environ.get("IMPROVER_PROPOSALS_DIR", str(repo / "proposals" / "improver"))
).expanduser()
branch_prefix = os.environ.get("IMPROVER_BRANCH_PREFIX", "brain-improver")
gh_bin = os.environ.get("GH_BIN", "gh")
git_bin = os.environ.get("GIT_BIN", "git")
actions = []
records = []

for verdict in verdicts if isinstance(verdicts, list) else []:
    if not isinstance(verdict, dict):
        continue
    hid = str(verdict.get("hypothesisId", "")).strip()
    hypothesis = hyp_by_id.get(hid)
    if not hypothesis:
        continue
    kind = verdict.get("verdict")
    if kind == "config-tune":
        actions.append(
            {
                "hypothesisId": hid,
                "action": "recommend",
                "summary": "рекомендация передана Tier-1; конфиг здесь не менялся",
            }
        )
        continue
    if kind == "reject":
        actions.append(
            {
                "hypothesisId": hid,
                "action": "reject",
                "summary": f"отклонено: {verdict.get('rationale', 'без причины')}",
            }
        )
        continue
    if kind != "integrate":
        continue

    selected = verdict.get("bestCandidate")
    selected = selected if isinstance(selected, dict) else {}
    selected_url = str(selected.get("url", "")).strip()
    candidate = candidate_by_hypothesis.get(hid, {}).get(selected_url)
    if not candidate:
        actions.append(
            {
                "hypothesisId": hid,
                "action": "reject",
                "summary": "integrate отклонён: bestCandidate отсутствует во входном поиске",
            }
        )
        continue
    full_name = str(candidate.get("fullName", "")).strip()
    url = str(candidate.get("url", "")).strip()
    if not full_name or not url:
        actions.append(
            {
                "hypothesisId": hid,
                "action": "reject",
                "summary": "integrate отклонён: у кандидата нет fullName или URL",
            }
        )
        continue
    sha = str(candidate.get("commitSha") or candidate.get("sha") or "").strip()
    if full_name and not re.fullmatch(r"[0-9a-fA-F]{40}", sha):
        try:
            result = subprocess.run(
                [gh_bin, "api", f"repos/{full_name}/commits/HEAD", "--jq", ".sha"],
                check=False,
                capture_output=True,
                text=True,
                timeout=60,
            )
            resolved = result.stdout.strip().splitlines()[-1] if result.stdout.strip() else ""
            if result.returncode == 0 and re.fullmatch(r"[0-9a-fA-F]{40}", resolved):
                sha = resolved.lower()
        except (OSError, subprocess.TimeoutExpired):
            pass
    pinned = sha if re.fullmatch(r"[0-9a-fA-F]{40}", sha) else "UNRESOLVED"
    safe_id = re.sub(r"[^a-zA-Z0-9._-]+", "-", hid).strip("-") or "proposal"
    branch = f"{branch_prefix}/{run_date}-{safe_id}"
    proposal_path = proposal_dir / f"{safe_id}.md"
    draft_path = proposal_dir / f"{safe_id}-draft-pr.md"
    pin_status = "готов" if pinned != "UNRESOLVED" else "требует повторного gh api"
    branch_status = "не создана"
    if os.environ.get("IMPROVER_CREATE_BRANCH", "1") == "1":
        try:
            branch_result = subprocess.run(
                [git_bin, "branch", branch],
                cwd=repo,
                check=False,
                capture_output=True,
                text=True,
                timeout=30,
            )
            branch_status = "создана" if branch_result.returncode == 0 else "не создана"
        except (OSError, subprocess.TimeoutExpired):
            pass
    proposal_dir.mkdir(parents=True, exist_ok=True)

    proposal = f"""# Improver proposal: {hid}

- Дата прогона: `{run_date}`
- Ветка: `{branch}` ({branch_status})
- Гипотеза: {hypothesis.get("hypothesis", "")}
- Цель: `{verdict.get("target", "")}`
- Vendor pin: {url or "URL_UNRESOLVED"} @ `{pinned}`
- Статус pin: {pin_status}

## Обоснование

{verdict.get("rationale", "")}

## Patch-plan

1. Проверить лицензию и минимальную применимую часть `{full_name or "candidate"}`.
2. Вендорить только нужный код с сохранением URL и commit SHA.
3. Подключить через отдельный обратимый adapter/feature flag.
4. Добавить unit/integration-тесты и метрики outcome.
5. После CI и ручной проверки отдельно решить вопрос о merge.

Автоматический merge запрещён. Ручные Brain-ноды не изменяются.
"""
    draft = f"""# Draft PR: {hid}

## Что меняется

{hypothesis.get("hypothesis", "")}

## Источник

- `{full_name}`
- {url}
- commit: `{pinned}`

## Проверка

- [ ] Лицензия совместима
- [ ] Тесты проходят
- [ ] Feature flag выключает интеграцию
- [ ] Outcome-метрика и rollback описаны

Draft only. Auto-merge запрещён.
"""
    proposal_path.write_text(proposal, encoding="utf-8")
    draft_path.write_text(draft, encoding="utf-8")
    action = {
        "hypothesisId": hid,
        "action": "prepare-integration",
        "summary": f"подготовлены proposal и draft PR; vendor pin {pin_status}",
        "branch": branch,
        "branchStatus": branch_status,
        "proposal": str(proposal_path),
        "draftPr": str(draft_path),
        "vendorPin": {"url": url, "commitSha": pinned},
    }

    # Создание draft PR — только явный runtime-флаг. Ветка и коммиты должны быть
    # заранее подготовлены вызывающей стороной; gh pr merge здесь отсутствует.
    if os.environ.get("IMPROVER_CREATE_DRAFT_PR") == "1":
        try:
            created = subprocess.run(
                [
                    gh_bin,
                    "pr",
                    "create",
                    "--draft",
                    "--head",
                    branch,
                    "--title",
                    f"brain-improver: {hid}",
                    "--body-file",
                    str(draft_path),
                ],
                check=False,
                capture_output=True,
                text=True,
                timeout=60,
            )
            action["draftPrUrl"] = created.stdout.strip() if created.returncode == 0 else ""
        except (OSError, subprocess.TimeoutExpired):
            action["draftPrUrl"] = ""
    actions.append(action)
    records.append({"date": run_date, **action})

records_path = proposal_dir / "_proposals.ndjson"
old_records = {}
try:
    for line in records_path.read_text(encoding="utf-8").splitlines():
        row = json.loads(line)
        if isinstance(row, dict) and row.get("hypothesisId"):
            old_records[str(row["hypothesisId"])] = row
except (OSError, ValueError):
    pass
for row in records:
    old_records.setdefault(str(row["hypothesisId"]), row)
if old_records:
    records_path.write_text(
        "".join(
            json.dumps(old_records[key], ensure_ascii=False, sort_keys=True) + "\n"
            for key in sorted(old_records)
        ),
        encoding="utf-8",
    )
actions_path.write_text(
    json.dumps(actions, ensure_ascii=False, sort_keys=True), encoding="utf-8"
)
PY

python3 "$REPO_ROOT/tools/improver-report.py" \
  --date "$RUN_DATE" \
  --config "$CONFIG_FILE" \
  --signals "$SIGNALS_ALL" \
  --hypotheses "$HYPOTHESES_FILE" \
  --candidates "$CANDIDATES_FILE" \
  --verdicts "$VERDICTS_FILE" \
  --actions "$ACTIONS_FILE" || true

# autoMerge намеренно не читается: даже ошибочное true в конфиге не включает merge.
exit 0
