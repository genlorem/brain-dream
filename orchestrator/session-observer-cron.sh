#!/usr/bin/env bash
# Cron-обёртка для session-observer (каждые 6ч на vps, flock-guarded).
# Дефолты агента: MAX_PER_RUN=25, MIN_MSGS=8, MAX_AGE_DAYS=30, IDLE_MIN=30.
# Установка crontab:
#   0 */6 * * * flock -n /tmp/session-observer.lock /home/gen/Projects/brain-dream/orchestrator/session-observer-cron.sh
set -euo pipefail

REPO="/home/gen/Projects/brain-dream"
LOG="/home/gen/life/state/logs/session-observer.log"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1

echo "=== $(date -u +%FT%TZ) session-observer cron run ==="
printf '%s\n' '{"task":"observe-sessions","invoked_by":"cron","config":{"dry_run":false},"env":{}}' \
  | BRAIN_DREAM_REPO="$REPO" bash "$REPO/agents/session-observer.sh"
echo "=== exit $? ==="
