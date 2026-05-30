#!/usr/bin/env bash
set -uo pipefail

# dream-critic — agent (plugin contract v1).
#
# Weekly Sunday agent. Reads top-N candidates from insight registry over the
# last 7 days, asks Sonnet to validate each for (a) actionable Y/N, (b) still
# relevant Y/N. Insights that pass both checks are PROMOTED to permanent
# nodes under dreams/permanent/insight:<hash>.md.
#
# Promotion lifecycle:
#   nightly sleep → insight in dreams/<date>.md
#   registry tracks hash recurrence and confidence
#   weekly critic validates top by (hit_count × confidence)
#   passed → dreams/permanent/insight:<hash>.md (separate, durable node)
#
# Like Fabric's Santa-pattern but single-LLM (lightweight) and weekly only —
# subscription session cap concern.

AGENT_NAME="dream-critic"
AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${BRAIN_DREAM_REPO:-$(cd "$AGENT_DIR/.." && pwd)}"
DREAM_NODE_ROOT="${DREAM_NODE_ROOT:-$HOME/brain/dreams}"
INSIGHT_REGISTRY="${INSIGHT_REGISTRY:-$DREAM_NODE_ROOT/.insight-hashes.jsonl}"
PERMANENT_DIR="$DREAM_NODE_ROOT/permanent"

# Guards: dream-critic is heavier (Sonnet ~$0.20+) and weekly only.
GUARD_COST_DAILY_USD="${GUARD_COST_DAILY_USD:-0.50}"
GUARD_RATE_LIMIT_CALLS="${GUARD_RATE_LIMIT_CALLS:-1}"
GUARD_RATE_LIMIT_WINDOW_MIN="${GUARD_RATE_LIMIT_WINDOW_MIN:-720}"
# shellcheck disable=SC1091
source "$REPO/lib/guards.sh"

INPUT="{}"
if [ ! -t 0 ]; then INPUT=$(cat); fi

DRY_RUN=$(printf '%s' "$INPUT" | jq -r '.config.dry_run // false' 2>/dev/null || printf 'false')
INVOKED_BY=$(printf '%s' "$INPUT" | jq -r '.invoked_by // "manual"' 2>/dev/null || printf 'manual')
INPUT_DEPTH=$(printf '%s' "$INPUT" | jq -r '.input.depth // 0' 2>/dev/null || printf '0')
export INVOKED_BY INPUT_DEPTH

TOP_N="${DREAM_CRITIC_TOP_N:-20}"
WINDOW_DAYS="${DREAM_CRITIC_WINDOW_DAYS:-7}"
PROMOTE_THRESHOLD_CONFIDENCE="${DREAM_CRITIC_MIN_CONFIDENCE:-0.7}"
PROMOTE_MIN_HITS="${DREAM_CRITIC_MIN_HITS:-2}"

START_TIME=$(date +%s)
log() {
  local level="$1"; shift
  printf '{"ts":"%s","level":"%s","agent":"%s","msg":"%s"}\n' \
    "$(date -u +%FT%TZ)" "$level" "$AGENT_NAME" "$*" >&2
}
log INFO "start dry_run=$DRY_RUN invoked_by=$INVOKED_BY top_n=$TOP_N window=${WINDOW_DAYS}d"

if ! guards_pass_all; then
  cat <<GUARD
{"version":"1","agent_name":"$AGENT_NAME","status":"skipped","duration_s":$(($(date +%s)-START_TIME)),"result":{"reason":"guard_blocked"},"telemetry":{"llm_calls":[]}}
GUARD
  exit 2
fi

# Select candidates from registry
if [ ! -f "$INSIGHT_REGISTRY" ]; then
  log WARN "no_registry"
  cat <<EMPTY
{"version":"1","agent_name":"$AGENT_NAME","status":"skipped","duration_s":$(($(date +%s)-START_TIME)),"result":{"reason":"no_registry"},"telemetry":{"llm_calls":[]}}
EMPTY
  exit 0
fi

cutoff_epoch=$(( $(date -u +%s) - WINDOW_DAYS * 86400 ))
candidates_file=$(mktemp /tmp/critic-candidates.XXXXXX)
trap 'rm -f "$candidates_file" "$prompt_file" 2>/dev/null' EXIT

# Top by (hit_count * confidence) within window, meeting minimums
jq -c --argjson cutoff "$cutoff_epoch" \
   --argjson min_c "$PROMOTE_THRESHOLD_CONFIDENCE" \
   --argjson min_h "$PROMOTE_MIN_HITS" \
   'select(.last_seen_epoch >= $cutoff and .confidence >= $min_c and .hit_count >= $min_h)
    | . + {score: ((.hit_count * .confidence) // 0)}' \
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

# Build prompt
prompt_file=$(mktemp /tmp/critic-prompt.XXXXXX)
{
  echo "Ты — критик инсайтов системы brain-dream. Тебе даны $cand_count кандидатов,"
  echo "которые повторялись в снах за последние ${WINDOW_DAYS} дней и набрали достаточную"
  echo "уверенность. Оцени каждый по двум осям:"
  echo ""
  echo "1. actionable: можно ли по этому инсайту сделать конкретный шаг (Y/N)."
  echo "2. still_relevant: остается ли он применим сейчас или устарел (Y/N)."
  echo ""
  echo "Если оба Y → инсайт промотируется в permanent. Если хоть один N → нет."
  echo ""
  echo "Верни JSONL: одна строка на кандидат, строго:"
  echo '{"hash":"<hash>","actionable":"Y|N","still_relevant":"Y|N","reason":"<краткое объяснение>"}'
  echo ""
  echo "## Кандидаты"
  echo ""
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    hash=$(printf '%s' "$c" | jq -r '.hash')
    title=$(printf '%s' "$c" | jq -r '.title')
    lens=$(printf '%s' "$c" | jq -r '.lens')
    domain=$(printf '%s' "$c" | jq -r '.domain')
    hits=$(printf '%s' "$c" | jq -r '.hit_count')
    conf=$(printf '%s' "$c" | jq -r '.confidence')
    echo "- hash=$hash | $title | lens=$lens domain=$domain hits=$hits confidence=$conf"
  done < "$candidates_file"
} > "$prompt_file"

if [ "$DRY_RUN" = "true" ]; then
  log INFO "dry_run_exit prompt_lines=$(wc -l < "$prompt_file")"
  cat <<DRY
{"version":"1","agent_name":"$AGENT_NAME","status":"skipped","duration_s":$(($(date +%s)-START_TIME)),"result":{"reason":"dry_run","candidates":$cand_count,"prompt_lines":$(wc -l < "$prompt_file")},"telemetry":{"llm_calls":[]}}
DRY
  exit 0
fi

# Call Sonnet
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

# Parse verdicts (JSONL)
verdicts_file=$(mktemp /tmp/critic-verdicts.XXXXXX)
printf '%s\n' "$result_text" \
  | sed -E '/^[[:space:]]*```/d' \
  | jq -c -R 'fromjson? // empty | select(type == "object" and has("hash"))' \
  > "$verdicts_file" 2>/dev/null || true

promoted=0
rejected=0
mkdir -p "$PERMANENT_DIR"

while IFS= read -r v; do
  [ -z "$v" ] && continue
  hash=$(printf '%s' "$v" | jq -r '.hash')
  actionable=$(printf '%s' "$v" | jq -r '.actionable // "N"')
  relevant=$(printf '%s' "$v" | jq -r '.still_relevant // "N"')
  reason=$(printf '%s' "$v" | jq -r '.reason // ""')

  if [ "$actionable" = "Y" ] && [ "$relevant" = "Y" ]; then
    # Promote
    cand_data=$(grep "\"hash\":\"$hash\"" "$candidates_file" | head -1)
    [ -z "$cand_data" ] && continue
    title=$(printf '%s' "$cand_data" | jq -r '.title')
    lens=$(printf '%s' "$cand_data" | jq -r '.lens')
    domain=$(printf '%s' "$cand_data" | jq -r '.domain')
    hits=$(printf '%s' "$cand_data" | jq -r '.hit_count')
    confidence=$(printf '%s' "$cand_data" | jq -r '.confidence')

    title_esc="${title//\'/\'\'}"
    reason_esc="${reason//\'/\'\'}"

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
      printf -- "hits_at_promotion: %s\n" "$hits"
      printf -- "confidence_at_promotion: %s\n" "$confidence"
      printf -- "critic_reason: '%s'\n" "$reason_esc"
      printf -- 'tags: [insight, permanent, weekly_critic]\n'
      printf -- '---\n\n'
      printf '## %s\n\n' "$title_esc"
      printf 'Из критика: %s\n\n' "$reason_esc"
      printf '_lens=%s domain=%s hits=%s confidence=%s_\n' "$lens" "$domain" "$hits" "$confidence"
    } > "$perm_file"
    log INFO "promoted hash=$hash file=$perm_file"
    promoted=$((promoted + 1))
  else
    rejected=$((rejected + 1))
    log INFO "rejected hash=$hash actionable=$actionable relevant=$relevant reason=$reason"
  fi
done < "$verdicts_file"

# Git commit
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

# TG notification
if [ -f "$HOME/.config/digest-bot/env" ]; then
  # shellcheck disable=SC1091
  source "$HOME/.config/digest-bot/env" 2>/dev/null || true
  if [ -n "${DIGEST_BOT_TOKEN:-}" ] && [ -n "${DIGEST_ADMIN_CHAT_ID:-}" ]; then
    tg="🎓 dream-critic: weekly review

📊 Кандидатов: $cand_count
✅ Промотировано в permanent: $promoted
❌ Отклонено: $rejected
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
    "git_sha": "$git_sha"
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
