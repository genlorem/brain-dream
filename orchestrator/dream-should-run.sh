#!/usr/bin/env bash
set -euo pipefail

# dream-should-run.sh — adaptive trigger для brain-dream.
#
# Возвращает 0 = «надо запускать сон сейчас», 1 = «пропустить».
# Решение: запускаем, если выполнено ХОТЯ БЫ ОДНО:
#   1) с прошлого фактического сна прошло $DREAM_TRIGGER_HOURS часов (по умолчанию 20),
#   2) среди $DREAM_DOMAINS появилось $DREAM_TRIGGER_NEW_NODES новых/изменённых нод
#      (по умолчанию 20).
#
# Идея — биологическая: «сонливость» растёт по времени И по объёму новой
# информации. Если ничего нового, и времени прошло мало, спать смысла нет.
#
# Состояние хранится в $DREAM_TRIGGER_STATE (по умолчанию
# ~/brain/dreams/.last-run.json) — обновляется ТОЛЬКО при принятии решения
# «запускать». При skip ничего не пишем, чтобы следующий тик cron'а мог
# принять решение «запускать» при росте порога.

ORCHESTRATOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${BRAIN_DREAM_LOG:-$HOME/life/state/logs/brain-dream.log}"
STATE_FILE="${DREAM_TRIGGER_STATE:-$HOME/brain/dreams/.last-run.json}"

DREAM_DOMAINS="${DREAM_DOMAINS:-travelmart personal}"
THRESHOLD_NEW_NODES="${DREAM_TRIGGER_NEW_NODES:-20}"
THRESHOLD_HOURS="${DREAM_TRIGGER_HOURS:-20}"

mkdir -p "$(dirname "$LOG_FILE")"

log() {
  printf '%s stage=trigger %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$LOG_FILE"
}

now_epoch=$(date -u +%s)

if [[ -f "$STATE_FILE" ]] && command -v jq >/dev/null 2>&1; then
  last_epoch=$(jq -r '.last_run_epoch // 0' "$STATE_FILE" 2>/dev/null || printf '0')
else
  last_epoch=0
fi

hours_since=$(( (now_epoch - last_epoch) / 3600 ))

new_count=0
for domain in $DREAM_DOMAINS; do
  root="$HOME/brain/$domain/nodes"
  [[ -d "$root" ]] || continue
  if (( last_epoch > 0 )); then
    count=$(find "$root" -type f -name '*.md' -newermt "@$last_epoch" 2>/dev/null | wc -l)
  else
    # первый запуск: считаем за «новое» всё, что обновлено за последние 24ч
    count=$(find "$root" -type f -name '*.md' -mtime -1 2>/dev/null | wc -l)
  fi
  new_count=$((new_count + count))
done

reason=""
if (( hours_since >= THRESHOLD_HOURS )); then
  if ((last_epoch == 0)); then reason="first_run"; else reason="time_threshold_${hours_since}h"; fi
elif (( new_count >= THRESHOLD_NEW_NODES )); then
  reason="new_nodes_${new_count}"
fi

if [[ -n "$reason" ]]; then
  log "event=run reason=$reason new_nodes=$new_count hours_since=$hours_since"
  mkdir -p "$(dirname "$STATE_FILE")"
  printf '{\"last_run_epoch\":%d,\"trigger_reason\":\"%s\",\"new_nodes_at_trigger\":%d}\n' \
    "$now_epoch" "$reason" "$new_count" > "$STATE_FILE"
  exit 0
else
  log "event=skip new_nodes=$new_count threshold=$THRESHOLD_NEW_NODES hours_since=$hours_since threshold_h=$THRESHOLD_HOURS"
  exit 1
fi
