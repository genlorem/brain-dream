#!/usr/bin/env bash
set -uo pipefail

# dream-critic — agent (plugin contract v1).
#
# Weekly Sunday agent. Reads top-N candidates from insight registry over the
# last 7 days, scores each via a 5-category weighted rubric (dream-insight-v1.0),
# and promotes insights with weighted_score >= pass_threshold into permanent
# nodes under dreams/permanent/insight-<hash>.md.
#
# Promotion lifecycle:
#   nightly sleep → insight in dreams/<date>.md
#   registry tracks hash recurrence and confidence
#   weekly critic scores top by (hit_count × confidence)
#   score >= threshold → dreams/permanent/insight-<hash>.md (durable node)
#
# Like Fabric's Santa-pattern but single-LLM (lightweight) and weekly only —
# subscription session cap concern.
#
# Rubric: configurable via DREAM_CRITIC_RUBRIC env var.
# Self-test: bash agents/dream-critic.sh --self-test

AGENT_NAME="dream-critic"
AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${BRAIN_DREAM_REPO:-$(cd "$AGENT_DIR/.." && pwd)}"
DREAM_NODE_ROOT="${DREAM_NODE_ROOT:-$HOME/brain/dreams}"
INSIGHT_REGISTRY="${INSIGHT_REGISTRY:-$DREAM_NODE_ROOT/.insight-hashes.jsonl}"
PERMANENT_DIR="$DREAM_NODE_ROOT/permanent"
FEEDBACK_FILE="${DREAM_FEEDBACK:-$DREAM_NODE_ROOT/.feedback.jsonl}"
DREAM_CRITIC_RUBRIC="${DREAM_CRITIC_RUBRIC:-$REPO/rubrics/dream-insight-v1.0.yaml}"
VENV_PYTHON="${VENV_PYTHON:-/home/gen/brain/engine/.venv/bin/python3}"

# Guards: dream-critic is heavier (Sonnet ~$0.20+) and weekly only.
GUARD_COST_DAILY_USD="${GUARD_COST_DAILY_USD:-0.50}"
GUARD_RATE_LIMIT_CALLS="${GUARD_RATE_LIMIT_CALLS:-1}"
GUARD_RATE_LIMIT_WINDOW_MIN="${GUARD_RATE_LIMIT_WINDOW_MIN:-720}"
# shellcheck disable=SC1091
source "$REPO/lib/guards.sh"

# ── Self-test mode ────────────────────────────────────────────────────────────
if [ "${1:-}" = "--self-test" ]; then
  if [ ! -f "$DREAM_CRITIC_RUBRIC" ]; then
    printf 'ERROR: rubric not found: %s\n' "$DREAM_CRITIC_RUBRIC" >&2
    exit 1
  fi
  if [ ! -x "$VENV_PYTHON" ]; then
    printf 'ERROR: venv python not found: %s\n' "$VENV_PYTHON" >&2
    exit 1
  fi
  rubric_json=$("$VENV_PYTHON" - "$DREAM_CRITIC_RUBRIC" <<'PYEOF'
import sys, yaml, json
with open(sys.argv[1]) as f:
    r = yaml.safe_load(f)
cats = r.get('categories', {})
weights = {k: v['weight'] for k, v in cats.items()}
total = sum(weights.values())
print(json.dumps({
    "version": r.get("version",""),
    "pass_threshold": r.get("pass_threshold"),
    "weights": weights,
    "weight_sum": round(total, 4)
}))
PYEOF
)
  threshold=$(printf '%s' "$rubric_json" | jq -r '.pass_threshold')
  weight_sum=$(printf '%s' "$rubric_json" | jq -r '.weight_sum')
  # Validate weights sum
  ok=$(python3 -c "print('ok' if abs($weight_sum - 1.0) < 0.001 else 'fail')")
  if [ "$ok" != "ok" ]; then
    printf 'FAIL: weights sum = %s (expected 1.0)\n' "$weight_sum"
    exit 1
  fi
  # Test weighted score formula
  test_score=$(python3 -c "
weights = $(printf '%s' "$rubric_json" | jq -r '.weights')
scores = {k: 7 for k in weights}  # all 7s
ws = sum(scores[k]*weights[k]/10 for k in weights)
print(round(ws,4))
")
  printf 'rubric ok, weights sum 1.0, threshold %s\n' "$threshold"
  printf 'self-test weighted_score(all=7) = %s\n' "$test_score"
  exit 0
fi

# ── Input parsing ─────────────────────────────────────────────────────────────
INPUT="{}"
if [ ! -t 0 ]; then INPUT=$(cat); fi
# Пустой stdin (cron зовёт `< /dev/null`) → пустая строка ломает jq-парсинг
# (jq на пустом входе молча отдаёт пусто, `// default` не срабатывает). → "{}".
[ -z "${INPUT//[[:space:]]/}" ] && INPUT="{}"

DRY_RUN=$(printf '%s' "$INPUT" | jq -r '.config.dry_run // false' 2>/dev/null || printf 'false')
INVOKED_BY=$(printf '%s' "$INPUT" | jq -r '.invoked_by // "manual"' 2>/dev/null || printf 'manual')
INPUT_DEPTH=$(printf '%s' "$INPUT" | jq -r '.input.depth // 0' 2>/dev/null || printf '0')
export INVOKED_BY INPUT_DEPTH

TOP_N="${DREAM_CRITIC_TOP_N:-20}"
WINDOW_DAYS="${DREAM_CRITIC_WINDOW_DAYS:-7}"
PROMOTE_THRESHOLD_CONFIDENCE="${DREAM_CRITIC_MIN_CONFIDENCE:-0.7}"
# hit_count — повторяемость инсайта между ночами. БЫЛ дефолт 2, но реестр
# дедуплицируется по ТОЧНОМУ content_hash, а LLM каждую ночь формулирует инсайт
# иначе → точных повторов не бывает: все 1943 записи имели hit_count=1, поэтому
# critic не промоутил НИКОГДА (permanent/ пуст). Дефолт →1: реальный фильтр
# качества — confidence + feedback + LLM-рубрика (pass_threshold), а не повтор.
# Глубокий фикс (семантический повтор, как finding-dedup.py) — отдельно.
PROMOTE_MIN_HITS="${DREAM_CRITIC_MIN_HITS:-1}"

START_TIME=$(date +%s)
log() {
  local level="$1"; shift
  printf '{"ts":"%s","level":"%s","agent":"%s","msg":"%s"}\n' \
    "$(date -u +%FT%TZ)" "$level" "$AGENT_NAME" "$*" >&2
}
log INFO "start dry_run=$DRY_RUN invoked_by=$INVOKED_BY top_n=$TOP_N window=${WINDOW_DAYS}d"

# ── Rubric loading ─────────────────────────────────────────────────────────────
if [ ! -f "$DREAM_CRITIC_RUBRIC" ]; then
  log ERROR "rubric_not_found path=$DREAM_CRITIC_RUBRIC"
  cat <<ERR
{"version":"1","agent_name":"$AGENT_NAME","status":"failed","duration_s":$(($(date +%s)-START_TIME)),"errors":["rubric_not_found"]}
ERR
  exit 1
fi

if [ ! -x "$VENV_PYTHON" ]; then
  log ERROR "venv_python_not_found path=$VENV_PYTHON"
  cat <<ERR
{"version":"1","agent_name":"$AGENT_NAME","status":"failed","duration_s":$(($(date +%s)-START_TIME)),"errors":["venv_python_not_found: $VENV_PYTHON — install PyYAML in /home/gen/brain/engine/.venv"]}
ERR
  exit 1
fi

rubric_json=$("$VENV_PYTHON" - "$DREAM_CRITIC_RUBRIC" <<'PYEOF'
import sys, yaml, json
with open(sys.argv[1]) as f:
    r = yaml.safe_load(f)
cats = r.get('categories', {})
out = {
    "id": r.get("id", ""),
    "version": r.get("version", ""),
    "pass_threshold": r.get("pass_threshold"),
    "categories": {}
}
total_w = 0.0
for cat_name, cat in cats.items():
    w = float(cat['weight'])
    total_w += w
    scale = {str(k): str(v).strip() for k, v in cat.get('scale', {}).items()}
    out["categories"][cat_name] = {
        "weight": w,
        "question": str(cat.get('question', '')).strip(),
        "scale": scale
    }
out["weight_sum"] = round(total_w, 6)
print(json.dumps(out))
PYEOF
) || { log ERROR "rubric_parse_failed"; cat <<ERR
{"version":"1","agent_name":"$AGENT_NAME","status":"failed","duration_s":$(($(date +%s)-START_TIME)),"errors":["rubric_parse_failed"]}
ERR
exit 1; }

# Validate weights sum
rubric_id=$(printf '%s' "$rubric_json" | jq -r '.id')
rubric_version=$(printf '%s' "$rubric_json" | jq -r '.version')
pass_threshold=$(printf '%s' "$rubric_json" | jq -r '.pass_threshold')
weight_sum=$(printf '%s' "$rubric_json" | jq -r '.weight_sum')

weights_ok=$(python3 -c "print('ok' if abs($weight_sum - 1.0) < 0.001 else 'fail')")
if [ "$weights_ok" != "ok" ]; then
  log ERROR "rubric_weights_invalid sum=$weight_sum (expected 1.0)"
  cat <<ERR
{"version":"1","agent_name":"$AGENT_NAME","status":"failed","duration_s":$(($(date +%s)-START_TIME)),"errors":["rubric_weights_invalid: sum=$weight_sum"]}
ERR
  exit 1
fi
log INFO "rubric_loaded id=$rubric_id version=$rubric_version threshold=$pass_threshold"

# ── Guards ─────────────────────────────────────────────────────────────────────
if ! guards_pass_all; then
  cat <<GUARD
{"version":"1","agent_name":"$AGENT_NAME","status":"skipped","duration_s":$(($(date +%s)-START_TIME)),"result":{"reason":"guard_blocked"},"telemetry":{"llm_calls":[]}}
GUARD
  exit 2
fi

# ── Select candidates from registry ───────────────────────────────────────────
if [ ! -f "$INSIGHT_REGISTRY" ]; then
  log WARN "no_registry"
  cat <<EMPTY
{"version":"1","agent_name":"$AGENT_NAME","status":"skipped","duration_s":$(($(date +%s)-START_TIME)),"result":{"reason":"no_registry"},"telemetry":{"llm_calls":[]}}
EMPTY
  exit 0
fi

cutoff_epoch=$(( $(date -u +%s) - WINDOW_DAYS * 86400 ))
candidates_file=$(mktemp /tmp/critic-candidates.XXXXXX)
prompt_file=$(mktemp /tmp/critic-prompt.XXXXXX)
trap 'rm -f "$candidates_file" "$prompt_file" 2>/dev/null' EXIT

# Карта последних вердиктов по хэшу из .feedback.jsonl (петля фидбэка).
# noise → кандидат исключается из промоушна; useful → бонус к score; known →
# лёгкий штраф (не новость). Нет файла/оценки → нейтрально (множитель 1.0).
fb_map='{}'
if [ -f "$FEEDBACK_FILE" ]; then
  fb_map=$(jq -s 'sort_by(.epoch) | reduce .[] as $x ({}; .[$x.hash] = $x.verdict)' "$FEEDBACK_FILE" 2>/dev/null || printf '{}')
fi

# Top by (hit_count * confidence * feedback_multiplier) within window, meeting minimums
jq -c --argjson cutoff "$cutoff_epoch" \
   --argjson min_c "$PROMOTE_THRESHOLD_CONFIDENCE" \
   --argjson min_h "$PROMOTE_MIN_HITS" \
   --argjson fb "$fb_map" \
   'select(.last_seen_epoch >= $cutoff and .confidence >= $min_c and .hit_count >= $min_h)
    | (($fb[.hash]) // "") as $v
    | select($v != "noise")
    | . + {fb_verdict: $v,
           score: (((.hit_count * .confidence) // 0)
                   * (if $v == "useful" then 1.5 elif $v == "known" then 0.85 else 1.0 end))}' \
   "$INSIGHT_REGISTRY" \
  | jq -s -c --argjson n "$TOP_N" 'sort_by(-.score) | .[:$n] | .[]' \
  > "$candidates_file"

cand_count=$(wc -l < "$candidates_file")
log INFO "selected_candidates count=$cand_count from_registry=$(wc -l < "$INSIGHT_REGISTRY")"

if [ "$cand_count" -eq 0 ]; then
  log INFO "no_candidates_to_critique"
  cat <<NONE
{"version":"1","agent_name":"$AGENT_NAME","status":"ok","duration_s":$(($(date +%s)-START_TIME)),"result":{"candidates":0,"promoted":0,"reason":"no_eligible_candidates"},"telemetry":{"llm_calls":[]}}
NONE
  exit 0
fi

# ── Build prompt ──────────────────────────────────────────────────────────────
{
  printf 'Ты — критик инсайтов системы brain-dream. Тебе даны %s кандидатов из ночных\n' "$cand_count"
  printf 'снов за последние %s дней. Оцени каждый по рубрике %s.\n\n' "$WINDOW_DAYS" "$rubric_id"
  printf 'Рубрика — 5 категорий, шкала 0..10 на каждой:\n\n'

  idx=1
  for cat_name in confidence actionability cross_domain relevance surprise; do
    weight=$(printf '%s' "$rubric_json" | jq -r --arg c "$cat_name" '.categories[$c].weight')
    question=$(printf '%s' "$rubric_json" | jq -r --arg c "$cat_name" '.categories[$c].question')
    s0=$(printf '%s' "$rubric_json" | jq -r --arg c "$cat_name" '.categories[$c].scale["0"]')
    s5=$(printf '%s' "$rubric_json" | jq -r --arg c "$cat_name" '.categories[$c].scale["5"]')
    s10=$(printf '%s' "$rubric_json" | jq -r --arg c "$cat_name" '.categories[$c].scale["10"]')
    printf '%s. %s (вес %s) — %s\n' "$idx" "$cat_name" "$weight" "$question"
    printf '   - 0: %s\n' "$s0"
    printf '   - 5: %s\n' "$s5"
    printf '   - 10: %s\n\n' "$s10"
    idx=$((idx + 1))
  done

  printf 'После оценки: промоушн = да, если weighted_score >= %s\n' "$pass_threshold"
  printf 'где weighted_score = sum(score[cat] * weight[cat] / 10) по всем 5 категориям.\n\n'
  printf 'Верни JSONL: одна строка на кандидат, СТРОГО:\n'
  printf '{"hash":"<hash>","scores":{"confidence":<0-10>,"actionability":<0-10>,"cross_domain":<0-10>,"relevance":<0-10>,"surprise":<0-10>},"notes":"<краткое объяснение 1-2 предложения>"}\n\n'
  printf '## Кандидаты\n\n'

  while IFS= read -r c; do
    [ -z "$c" ] && continue
    hash=$(printf '%s' "$c" | jq -r '.hash')
    title=$(printf '%s' "$c" | jq -r '.title')
    lens=$(printf '%s' "$c" | jq -r '.lens')
    domain=$(printf '%s' "$c" | jq -r '.domain')
    hits=$(printf '%s' "$c" | jq -r '.hit_count')
    conf=$(printf '%s' "$c" | jq -r '.confidence')
    printf -- '- hash=%s | %s | lens=%s domain=%s hits=%s confidence=%s\n' \
      "$hash" "$title" "$lens" "$domain" "$hits" "$conf"
  done < "$candidates_file"
} > "$prompt_file"

if [ "$DRY_RUN" = "true" ]; then
  log INFO "dry_run_exit prompt_lines=$(wc -l < "$prompt_file") rubric=$rubric_id"
  cat <<DRY
{"version":"1","agent_name":"$AGENT_NAME","status":"skipped","duration_s":$(($(date +%s)-START_TIME)),"result":{"reason":"dry_run","candidates":$cand_count,"prompt_lines":$(wc -l < "$prompt_file"),"rubric":"$rubric_id"},"telemetry":{"llm_calls":[]}}
DRY
  exit 0
fi

# ── Call Sonnet ───────────────────────────────────────────────────────────────
log INFO "calling_sonnet"
claude_response=""
if ! claude_response=$(claude -p --model sonnet --output-format json "$(cat "$prompt_file")" 2>/dev/null); then
  log ERROR "claude_failed"
  cat <<FAIL
{"version":"1","agent_name":"$AGENT_NAME","status":"failed","duration_s":$(($(date +%s)-START_TIME)),"errors":["claude_call_failed"]}
FAIL
  exit 1
fi

result_text=$(printf '%s' "$claude_response" | jq -r '.result // empty')
cost_usd=$(printf '%s' "$claude_response" | jq -r '.total_cost_usd // 0')
input_tokens=$(printf '%s' "$claude_response" | jq -r '.usage.input_tokens // 0')
output_tokens=$(printf '%s' "$claude_response" | jq -r '.usage.output_tokens // 0')
guard_record_cost "$cost_usd"

if [ -z "$result_text" ]; then
  log ERROR "empty_result"
  cat <<EMPTY
{"version":"1","agent_name":"$AGENT_NAME","status":"failed","duration_s":$(($(date +%s)-START_TIME)),"errors":["empty_result"]}
EMPTY
  exit 1
fi

# ── Parse verdicts (JSONL) and compute scores ─────────────────────────────────
verdicts_file=$(mktemp /tmp/critic-verdicts.XXXXXX)
trap 'rm -f "$candidates_file" "$prompt_file" "$verdicts_file" 2>/dev/null' EXIT
# Робастный парсинг ответа Sonnet: python-сканер выдёргивает JSON-объекты с ключом
# "hash" из произвольного текста — держит ```fence (вкл. ```jsonl), JSONL,
# pretty-print (многострочные объекты), обёртку в массив и прозаичную преамбулу.
# Прежний `jq -R fromjson` парсил построчно и давал 0 вердиктов на pretty-ответе
# (реальная причина promoted=0 при 20 кандидатах).
printf '%s' "$result_text" | python3 -c '
import sys, json
text = sys.stdin.read()
dec = json.JSONDecoder()
i, n = 0, len(text)
while i < n:
    while i < n and text[i] not in "{[":
        i += 1
    if i >= n:
        break
    try:
        obj, end = dec.raw_decode(text, i)
    except json.JSONDecodeError:
        i += 1
        continue
    i = end
    for it in (obj if isinstance(obj, list) else [obj]):
        if isinstance(it, dict) and "hash" in it:
            print(json.dumps(it, ensure_ascii=False))
' > "$verdicts_file" 2>/dev/null || true

# Load weights for scoring
w_confidence=$(printf '%s' "$rubric_json" | jq -r '.categories.confidence.weight')
w_actionability=$(printf '%s' "$rubric_json" | jq -r '.categories.actionability.weight')
w_cross_domain=$(printf '%s' "$rubric_json" | jq -r '.categories.cross_domain.weight')
w_relevance=$(printf '%s' "$rubric_json" | jq -r '.categories.relevance.weight')
w_surprise=$(printf '%s' "$rubric_json" | jq -r '.categories.surprise.weight')

promoted=0
rejected=0
skipped_malformed=0
mkdir -p "$PERMANENT_DIR"

# Track scores for distribution
all_scores_file=$(mktemp /tmp/critic-scores.XXXXXX)
trap 'rm -f "$candidates_file" "$prompt_file" "$verdicts_file" "$all_scores_file" 2>/dev/null' EXIT

while IFS= read -r v; do
  [ -z "$v" ] && continue

  hash=$(printf '%s' "$v" | jq -r '.hash // ""')
  if [ -z "$hash" ]; then
    log WARN "malformed_verdict missing_hash line=$(printf '%s' "$v" | head -c 200)"
    skipped_malformed=$((skipped_malformed + 1))
    continue
  fi

  # Validate all 5 score keys exist and are numeric [0..10]
  scores_valid=$(printf '%s' "$v" | jq -r '
    .scores |
    if type != "object" then "invalid"
    elif ([.confidence, .actionability, .cross_domain, .relevance, .surprise] |
          all(. != null and (type == "number") and . >= 0 and . <= 10))
    then "ok" else "invalid" end
  ' 2>/dev/null || printf 'invalid')

  if [ "$scores_valid" != "ok" ]; then
    log WARN "malformed_verdict invalid_scores hash=$hash"
    skipped_malformed=$((skipped_malformed + 1))
    continue
  fi

  sc=$(printf '%s' "$v" | jq -r '.scores.confidence')
  sa=$(printf '%s' "$v" | jq -r '.scores.actionability')
  scd=$(printf '%s' "$v" | jq -r '.scores.cross_domain')
  sr=$(printf '%s' "$v" | jq -r '.scores.relevance')
  ss=$(printf '%s' "$v" | jq -r '.scores.surprise')
  notes=$(printf '%s' "$v" | jq -r '.notes // ""')

  # weighted_score = sum(score[cat] * weight[cat] / 10)
  weighted_score=$(python3 -c "
ws = ($sc * $w_confidence + $sa * $w_actionability + $scd * $w_cross_domain + $sr * $w_relevance + $ss * $w_surprise) / 10
print(round(ws, 4))
")

  # Save score for distribution
  printf '%s\n' "$weighted_score" >> "$all_scores_file"

  # Determine verdict
  verdict=$(python3 -c "print('promote' if $weighted_score >= $pass_threshold else 'reject')")

  # Log per-candidate verdict
  printf '{"ts":"%s","level":"INFO","agent":"%s","msg":"verdict","hash":"%s","weighted_score":%s,"verdict":"%s","breakdown":{"confidence":%s,"actionability":%s,"cross_domain":%s,"relevance":%s,"surprise":%s}}\n' \
    "$(date -u +%FT%TZ)" "$AGENT_NAME" "$hash" "$weighted_score" "$verdict" \
    "$sc" "$sa" "$scd" "$sr" "$ss" >&2

  if [ "$verdict" = "promote" ]; then
    cand_data=$(grep "\"hash\":\"$hash\"" "$candidates_file" | head -1)
    [ -z "$cand_data" ] && { log WARN "candidate_not_found hash=$hash"; continue; }
    title=$(printf '%s' "$cand_data" | jq -r '.title')
    lens=$(printf '%s' "$cand_data" | jq -r '.lens')
    domain=$(printf '%s' "$cand_data" | jq -r '.domain')
    hits=$(printf '%s' "$cand_data" | jq -r '.hit_count')
    confidence=$(printf '%s' "$cand_data" | jq -r '.confidence')
    dream_id=$(printf '%s' "$cand_data" | jq -r '.dream_id // ""')

    title_esc="${title//\'/\'\'}"
    notes_esc="${notes//\'/\'\'}"

    perm_file="$PERMANENT_DIR/insight-$hash.md"
    {
      printf -- '---\n'
      printf -- 'id: insight:%s\n' "$hash"
      printf -- 'type: permanent_insight\n'
      printf -- "title: '%s'\n" "$title_esc"
      printf -- "promoted_at: '%s'\n" "$(date -u +%FT%TZ)"
      printf -- 'promoted_from: dream-critic\n'
      printf -- "lens: %s\n" "$lens"
      printf -- "domain: %s\n" "$domain"
      [ -n "$dream_id" ] && printf -- "dream_id: '%s'\n" "$dream_id"
      printf -- "hits_at_promotion: %s\n" "$hits"
      printf -- "confidence_at_promotion: %s\n" "$confidence"
      printf -- "critic_rubric: %s\n" "$rubric_id"
      printf -- "critic_score: %s\n" "$weighted_score"
      printf -- "critic_score_breakdown:\n"
      printf -- "  confidence: %s\n" "$sc"
      printf -- "  actionability: %s\n" "$sa"
      printf -- "  cross_domain: %s\n" "$scd"
      printf -- "  relevance: %s\n" "$sr"
      printf -- "  surprise: %s\n" "$ss"
      printf -- "critic_notes: '%s'\n" "$notes_esc"
      printf -- 'tags: [insight, permanent, weekly_critic]\n'
      printf -- '---\n\n'
      printf '## %s\n\n' "$title_esc"
      printf 'Из критика: %s\n\n' "$notes_esc"
      printf '_lens=%s domain=%s hits=%s confidence=%s score=%s_\n' \
        "$lens" "$domain" "$hits" "$confidence" "$weighted_score"
    } > "$perm_file"
    log INFO "promoted hash=$hash file=$perm_file score=$weighted_score"
    promoted=$((promoted + 1))
  else
    rejected=$((rejected + 1))
    log INFO "rejected hash=$hash score=$weighted_score"
  fi
done < "$verdicts_file"

# ── Score distribution ─────────────────────────────────────────────────────────
dist_json='{"min":0,"max":0,"median":0,"above_threshold":0}'
if [ -s "$all_scores_file" ]; then
  dist_json=$(python3 - <<PYEOF
import sys
scores = []
with open("$all_scores_file") as f:
    for line in f:
        line = line.strip()
        if line:
            try: scores.append(float(line))
            except: pass
if not scores:
    print('{"min":0,"max":0,"median":0,"above_threshold":0}')
    sys.exit(0)
scores.sort()
n = len(scores)
mid = n // 2
median = scores[mid] if n % 2 else round((scores[mid-1]+scores[mid])/2, 4)
above = sum(1 for s in scores if s >= $pass_threshold)
import json
print(json.dumps({"min": round(min(scores),4), "max": round(max(scores),4),
                  "median": round(median,4), "above_threshold": above}))
PYEOF
)
fi

score_min=$(printf '%s' "$dist_json" | jq -r '.min')
score_max=$(printf '%s' "$dist_json" | jq -r '.max')
score_median=$(printf '%s' "$dist_json" | jq -r '.median')

# ── Git commit ────────────────────────────────────────────────────────────────
git_sha=""
if [ "$promoted" -gt 0 ]; then
  if git -C "$DREAM_NODE_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$DREAM_NODE_ROOT" add "$PERMANENT_DIR/" 2>/dev/null || true
    git -C "$DREAM_NODE_ROOT" -c user.name='dream-critic' -c user.email='dream-critic@local' \
      commit -q -m "critic: promote $promoted insights (week of $(date -u +%F))" 2>/dev/null && \
      git_sha=$(git -C "$DREAM_NODE_ROOT" rev-parse --short HEAD)
    log INFO "committed sha=$git_sha"
  fi
fi

# ── TG notification ────────────────────────────────────────────────────────────
if [ -f "$HOME/.config/digest-bot/env" ]; then
  # shellcheck disable=SC1091
  source "$HOME/.config/digest-bot/env" 2>/dev/null || true
  if [ -n "${DIGEST_BOT_TOKEN:-}" ] && [ -n "${DIGEST_ADMIN_CHAT_ID:-}" ]; then
    tg="🎓 dream-critic: weekly review (rubric $rubric_version)

📊 Кандидатов: $cand_count
✅ Промотировано (score≥${pass_threshold}): $promoted
❌ Отклонено: $rejected
📈 Score distribution: min=${score_min} median=${score_median} max=${score_max}
💰 Sonnet: \$$cost_usd (расчётно, через подписку)
📈 Tokens: $input_tokens / $output_tokens"
    curl -fs -X POST "https://api.telegram.org/bot${DIGEST_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${DIGEST_ADMIN_CHAT_ID}" \
      --data-urlencode "text=$tg" -o /dev/null 2>/dev/null && log INFO "tg_sent"
  fi
fi

DURATION=$(($(date +%s) - START_TIME))

cat <<OUTPUT
{
  "version": "1",
  "agent_name": "$AGENT_NAME",
  "status": "ok",
  "duration_s": $DURATION,
  "result": {
    "candidates": $cand_count,
    "promoted": $promoted,
    "rejected": $rejected,
    "skipped_malformed": $skipped_malformed,
    "git_sha": "$git_sha",
    "rubric": "$rubric_id",
    "score_distribution": $dist_json
  },
  "side_effects": [
    {"type":"git_commit","sha":"$git_sha","repo":"dreams"}
  ],
  "telemetry": {
    "llm_calls": [
      {"model":"sonnet","input_tokens":$input_tokens,"output_tokens":$output_tokens,"cost_usd":$cost_usd,"via":"subscription"}
    ]
  },
  "errors": []
}
OUTPUT
