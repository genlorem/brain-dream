#!/usr/bin/env bash
# guards.sh — 5-layer защита для агентов brain-dream.
#
# Из Fabric autoDream MEM-05. AND-цепочка: failure of any one blocks.
#
# Использование из агента:
#   source "$BRAIN_DREAM_REPO/lib/guards.sh"
#   if ! guards_pass_all; then
#     # output skipped result, exit 2
#   fi
#   # ... agent does work ...
#   guard_record_cost "$cost_usd"   # после LLM-вызова
#
# Контекст:
#   - $AGENT_NAME      — обязательно, имя агента (для state dirs)
#   - $INVOKED_BY      — кто/что запустил агента (orchestrator/cron/mailbox/manual)
#   - $INPUT_DEPTH     — depth=0 для исходных, depth=1 для observer-of-observation
#
# State: $GUARD_STATE_DIR/$AGENT_NAME/{rate,cost}.jsonl + kill-switch файлы.

GUARD_STATE_DIR="${GUARD_STATE_DIR:-$HOME/.brain-dream}"

guard_init() {
  mkdir -p "$GUARD_STATE_DIR/$AGENT_NAME"
}

# Логи блокировок — структурированный JSON в stderr (как формат агентов).
log_block() {
  local guard="$1" reason="$2"
  printf '{"ts":"%s","level":"WARN","agent":"%s","msg":"guard_blocked","guard":"%s","reason":"%s"}\n' \
    "$(date -u +%FT%TZ)" "${AGENT_NAME:-unknown}" "$guard" "$reason" >&2
}

# 1. source-filter: запрещаем вход от агента того же типа (observer of observer).
guard_source_filter() {
  local source_agent="${INVOKED_BY:-unknown}"
  if [[ "$source_agent" == "$AGENT_NAME" ]]; then
    log_block source-filter "self-invocation by $source_agent"
    return 1
  fi
  return 0
}

# 2. rate-limit: sliding window. Не более N вызовов за W минут.
GUARD_RATE_LIMIT_CALLS="${GUARD_RATE_LIMIT_CALLS:-3}"
GUARD_RATE_LIMIT_WINDOW_MIN="${GUARD_RATE_LIMIT_WINDOW_MIN:-60}"
guard_rate_limit() {
  local rate_file="$GUARD_STATE_DIR/$AGENT_NAME/rate.jsonl"
  local now window_start count
  now=$(date +%s)
  window_start=$((now - GUARD_RATE_LIMIT_WINDOW_MIN * 60))
  count=0
  if [[ -f "$rate_file" ]]; then
    count=$(awk -v ws="$window_start" '$1 >= ws {c++} END {print c+0}' "$rate_file")
  fi
  if (( count >= GUARD_RATE_LIMIT_CALLS )); then
    log_block rate-limit "$count calls in last ${GUARD_RATE_LIMIT_WINDOW_MIN}min (limit $GUARD_RATE_LIMIT_CALLS)"
    return 1
  fi
  printf '%s\n' "$now" >> "$rate_file"
  # housekeeping: компактим если > 100 строк
  if (( $(wc -l < "$rate_file" 2>/dev/null || echo 0) > 100 )); then
    awk -v ws="$window_start" '$1 >= ws' "$rate_file" > "$rate_file.tmp" && mv "$rate_file.tmp" "$rate_file"
  fi
  return 0
}

# 3. cost-circuit-breaker: дневной USD-cap, расход накапливается через
# guard_record_cost после LLM-вызовов.
GUARD_COST_DAILY_USD="${GUARD_COST_DAILY_USD:-0.10}"
guard_cost_cb() {
  local cost_file="$GUARD_STATE_DIR/$AGENT_NAME/cost.jsonl"
  local today total
  today=$(date -u +%F)
  total=0
  if [[ -f "$cost_file" ]]; then
    total=$(awk -F'\t' -v d="$today" '$1 == d {s+=$2} END {printf "%.4f", s+0}' "$cost_file")
  fi
  if awk -v t="$total" -v c="$GUARD_COST_DAILY_USD" 'BEGIN{exit !(t >= c)}'; then
    log_block cost-circuit-breaker "spent \$$total today (limit \$$GUARD_COST_DAILY_USD)"
    return 1
  fi
  return 0
}

# Записать расход в журнал после успешного LLM-вызова.
guard_record_cost() {
  local cost="$1"
  local cost_file="$GUARD_STATE_DIR/$AGENT_NAME/cost.jsonl"
  local today
  today=$(date -u +%F)
  printf '%s\t%s\n' "$today" "$cost" >> "$cost_file"
}

# 4. depth-counter: глубина рекурсии. agent-of-agent выход дальше 1 — нельзя.
GUARD_MAX_DEPTH="${GUARD_MAX_DEPTH:-1}"
guard_depth() {
  local depth="${INPUT_DEPTH:-0}"
  if (( depth > GUARD_MAX_DEPTH )); then
    log_block depth-counter "input depth $depth > max $GUARD_MAX_DEPTH"
    return 1
  fi
  return 0
}

# 5. kill-switch: ручная отмена через файл.
guard_kill_switch() {
  local kill_file="$GUARD_STATE_DIR/${AGENT_NAME}-disabled"
  if [[ -f "$kill_file" ]]; then
    log_block kill-switch "found $kill_file"
    return 1
  fi
  return 0
}

# Combined AND check — главная точка входа для агентов.
guards_pass_all() {
  guard_init
  guard_source_filter && \
  guard_rate_limit && \
  guard_cost_cb && \
  guard_depth && \
  guard_kill_switch
}
