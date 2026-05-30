#!/usr/bin/env bash
set -uo pipefail

# dream-introspector — agent (plugin contract v1).
#
# Каждое воскресенье читает последние 7 dream-нот и текущий код brain-dream,
# просит Sonnet предложить 1-3 конкретных улучшения. Кладёт результат в
# proposals/<date>.md, делает git commit, шлёт уведомление в Telegram.
#
# НЕ применяет изменения сама. Это минимально-инвазивная форма
# самосовершенствования: предложения + ревью человеком.
#
# Контракт:
#   Вход (stdin JSON) опционально:
#     {"config":{"dry_run":bool,"model_budget_usd":N},"env":{...}}
#   Выход (stdout JSON): plugin-contract v1
#   Логи: stderr JSON-per-line.

AGENT_NAME="dream-introspector"
AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${BRAIN_DREAM_REPO:-$(cd "$AGENT_DIR/.." && pwd)}"
DREAM_DIR="${DREAM_NODE_ROOT:-$HOME/brain/dreams}/nodes"

# Read stdin if not a tty
INPUT="{}"
if [ ! -t 0 ]; then
  INPUT=$(cat)
fi

DRY_RUN=$(printf '%s' "$INPUT" | jq -r '.config.dry_run // false' 2>/dev/null || printf 'false')
BUDGET_USD=$(printf '%s' "$INPUT" | jq -r '.config.model_budget_usd // 0.20' 2>/dev/null || printf '0.20')

START_TIME=$(date +%s)

log() {
  local level="$1"; shift
  printf '{"ts":"%s","level":"%s","agent":"%s","msg":"%s"}\n' \
    "$(date -u +%FT%TZ)" "$level" "$AGENT_NAME" "$*" >&2
}

log INFO "start dry_run=$DRY_RUN budget=$BUDGET_USD repo=$REPO"

# Сбор контекста
recent_dreams=""
if [ -d "$DREAM_DIR" ]; then
  recent_dreams=$(find "$DREAM_DIR" -maxdepth 1 -name 'dream-*.md' -type f -mtime -7 2>/dev/null | sort | tail -7)
fi
dreams_count=$(printf '%s\n' "$recent_dreams" | grep -c . || true)
log INFO "dreams_found=$dreams_count"

# Recent commits (контекст что недавно меняли)
recent_commits=$(git -C "$REPO" log --oneline -10 2>/dev/null || echo "")

# Главные файлы для review
main_files=$(find "$REPO/orchestrator" "$REPO/lib" -maxdepth 2 -name '*.sh' -type f 2>/dev/null)

# Собираем prompt
prompt_file=$(mktemp /tmp/introspector-prompt.XXXXXX)
trap 'rm -f "$prompt_file"' EXIT

{
  echo "Ты — агент-интроспектор системы brain-dream (knowledge graph «сон»)."
  echo "Анализируешь свои собственные сны за последнюю неделю и текущий код"
  echo "системы. Цель — предложить 1-3 конкретных улучшения."
  echo ""
  echo "Правила:"
  echo "- НЕ общие советы. Конкретные изменения: какой файл, какая логика."
  echo "- Каждое предложение — с обоснованием на основе того что ТЫ ВИДИШЬ в снах."
  echo "- Оцени риск и обратимость каждого."
  echo "- Если что-то очевидно ломается в снах (мало кандидатов, повторяются темы,"
  echo "  низкий confidence) — это твой первый кандидат на улучшение."
  echo ""
  echo "## Последние сны (со статистикой):"
  echo ""
  if [ -n "$recent_dreams" ]; then
    while IFS= read -r d; do
      [ -z "$d" ] && continue
      echo "### $(basename "$d")"
      # Frontmatter (15 строк)
      sed -n '1,18p' "$d"
      echo ""
      # Только Топ-10 / Синтез / Сравнение
      awk '/^## / { p=0 } /^## (Синтез|Сравнение|Топ-10|Top)/ { p=1 } p' "$d" | head -150
      echo ""
      echo "---"
    done <<< "$recent_dreams"
  else
    echo "_(нет снов за последние 7 дней)_"
  fi
  echo ""
  echo "## Недавние коммиты brain-dream:"
  echo ""
  echo '```'
  echo "$recent_commits"
  echo '```'
  echo ""
  echo "## Главные файлы кода:"
  echo ""
  for cf in $main_files; do
    echo "### $cf ($(wc -l < "$cf") строк)"
    echo '```bash'
    # Первые 200 строк каждого — для контекста структуры
    head -200 "$cf"
    if [ "$(wc -l < "$cf")" -gt 200 ]; then
      echo ""
      echo "... (файл продолжается)"
    fi
    echo '```'
    echo ""
  done
  echo ""
  echo "## Формат ответа"
  echo ""
  echo "Чистый markdown. Для каждого предложения:"
  echo ""
  echo "## Proposal #N: <короткий заголовок>"
  echo ""
  echo "**Что заметил:** (конкретное наблюдение из снов или кода)"
  echo ""
  echo "**Предложение:** (что менять, в каком файле/функции)"
  echo ""
  echo "**Обоснование:** (зачем — что это улучшит)"
  echo ""
  echo "**Риск:** низкий/средний/высокий. **Обратимость:** легко/средне/сложно."
  echo ""
  echo "**Примерный diff:** (опционально, 5-15 строк или ссылка на функцию)"
  echo ""
  echo "Без предисловий, без эпилогов. Только proposals."
} > "$prompt_file"

prompt_lines=$(wc -l < "$prompt_file")
log INFO "prompt_built lines=$prompt_lines"

# Dry-run
if [ "$DRY_RUN" = "true" ]; then
  log INFO "dry_run_exit"
  cat <<DRY
{"version":"1","agent_name":"$AGENT_NAME","status":"skipped","duration_s":$(($(date +%s)-START_TIME)),"result":{"reason":"dry_run","prompt_lines":$prompt_lines},"telemetry":{"llm_calls":[]}}
DRY
  exit 0
fi

# Real call
log INFO "calling_sonnet"
claude_response=""
if ! claude_response=$(claude -p --model sonnet --max-budget-usd "$BUDGET_USD" --output-format json "$(cat "$prompt_file")" 2>/dev/null); then
  log ERROR "claude_failed"
  cat <<FAIL
{"version":"1","agent_name":"$AGENT_NAME","status":"failed","duration_s":$(($(date +%s)-START_TIME)),"errors":["claude_call_failed"],"telemetry":{"llm_calls":[]}}
FAIL
  exit 1
fi

result_text=$(printf '%s' "$claude_response" | jq -r '.result // empty')
cost_usd=$(printf '%s' "$claude_response" | jq -r '.total_cost_usd // 0')
input_tokens=$(printf '%s' "$claude_response" | jq -r '.usage.input_tokens // 0')
output_tokens=$(printf '%s' "$claude_response" | jq -r '.usage.output_tokens // 0')

if [ -z "$result_text" ]; then
  log ERROR "empty_result"
  cat <<EMPTY
{"version":"1","agent_name":"$AGENT_NAME","status":"failed","duration_s":$(($(date +%s)-START_TIME)),"errors":["empty_result"],"telemetry":{"llm_calls":[{"model":"sonnet","cost_usd":$cost_usd,"via":"subscription"}]}}
EMPTY
  exit 1
fi

# Записать предложение
proposal_date=$(date -u +%F)
proposal_file="$REPO/proposals/${proposal_date}.md"
mkdir -p "$(dirname "$proposal_file")"
{
  echo "# Proposals from dream-introspector"
  echo ""
  echo "**Date:** $proposal_date"
  echo "**Cost (subscription, reference):** \$$cost_usd"
  echo "**Tokens:** $input_tokens in / $output_tokens out"
  echo "**Dreams analyzed:** $dreams_count"
  echo "**Generated:** $(date -u +%FT%TZ)"
  echo ""
  echo "Это предложения ИИ-агента для улучшения brain-dream. **НЕ применяются автоматически.**"
  echo "Просмотри, оцени, мёржи руками что годится: \`git apply\`, ручная правка или просто инсайты."
  echo ""
  echo "---"
  echo ""
  echo "$result_text"
} > "$proposal_file"

log INFO "proposal_written file=$proposal_file"

# Git commit
git_sha=""
if git -C "$REPO" add "$proposal_file" 2>/dev/null && \
   git -C "$REPO" -c user.name='dream-introspector' -c user.email='dream-introspector@local' \
     commit -q -m "introspector: proposal $proposal_date" 2>/dev/null; then
  git_sha=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo "")
  # Push (best-effort)
  git -C "$REPO" push origin main >/dev/null 2>&1 || log WARN "push_failed"
  log INFO "committed sha=$git_sha"
fi

# Telegram notification (best-effort)
if [ -f "$HOME/.config/digest-bot/env" ]; then
  # shellcheck disable=SC1091
  source "$HOME/.config/digest-bot/env" 2>/dev/null || true
  if [ -n "${DIGEST_BOT_TOKEN:-}" ] && [ -n "${DIGEST_ADMIN_CHAT_ID:-}" ]; then
    tg_text="🔧 dream-introspector: новые предложения за неделю.

📄 \`$proposal_file\`
💰 Sonnet: \$$cost_usd (расчётно, через подписку)
🧠 Снов проанализировано: $dreams_count
📊 Токены: $input_tokens / $output_tokens

GitHub: https://github.com/genlorem/brain-dream/blob/main/proposals/${proposal_date}.md"
    curl -fs -X POST "https://api.telegram.org/bot${DIGEST_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${DIGEST_ADMIN_CHAT_ID}" \
      --data-urlencode "text=$tg_text" \
      -o /dev/null 2>/dev/null && log INFO "tg_sent" || log WARN "tg_failed"
  fi
fi

DURATION=$(($(date +%s) - START_TIME))

# Plugin-contract output
cat <<OUTPUT
{
  "version": "1",
  "agent_name": "$AGENT_NAME",
  "status": "ok",
  "duration_s": $DURATION,
  "result": {
    "proposal_file": "$proposal_file",
    "dreams_analyzed": $dreams_count,
    "git_sha": "$git_sha"
  },
  "side_effects": [
    {"type":"file_written","path":"$proposal_file"},
    {"type":"git_commit","sha":"$git_sha","repo":"brain-dream"}
  ],
  "telemetry": {
    "llm_calls": [
      {"model":"sonnet","input_tokens":$input_tokens,"output_tokens":$output_tokens,"cost_usd":$cost_usd,"via":"subscription"}
    ]
  },
  "errors": []
}
OUTPUT
