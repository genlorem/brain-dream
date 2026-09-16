#!/usr/bin/env bash
# Cron-обёртка для session-observer (каждые 6ч на vps, flock-guarded).
# Дефолты агента: MAX_PER_RUN=25, MIN_MSGS=8, MAX_AGE_DAYS=30, IDLE_MIN=30.
# nice/ionice: finding-dedup.py (fastembed, ~20 потоков, 440% CPU) в 06:00 UTC давал
# load 22-25 на 7 ядрах и тормозил интерактивные сессии (2026-09-16); фоновая
# работа обязана уступать CPU/IO, наследуется всеми детьми агента.
# Установка crontab:
#   0 */6 * * * flock -n /tmp/session-observer.lock /home/gen/Projects/brain-dream/orchestrator/session-observer-cron.sh
set -euo pipefail

REPO="${REPO:-$HOME/Projects/brain-dream}"
LOG="${LOG:-$HOME/life/state/logs/session-observer.log}"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1

echo "=== $(date -u +%FT%TZ) session-observer cron run ==="
printf '%s\n' '{"task":"observe-sessions","invoked_by":"cron","config":{"dry_run":false},"env":{}}' \
  | BRAIN_DREAM_REPO="$REPO" nice -n 19 ionice -c 3 bash "$REPO/agents/session-observer.sh"
echo "=== exit $? ==="
