#!/usr/bin/env bash
# Cron-обёртка для session-observer (каждые 6ч на vps, flock-guarded).
# Дефолты агента: MAX_PER_RUN=25, MIN_MSGS=8, MAX_AGE_DAYS=30, IDLE_MIN=30.
# nice/ionice: finding-dedup.py (fastembed, ~20 потоков, 440% CPU) в 06:00 UTC давал
# load 22-25 на 7 ядрах и тормозил интерактивные сессии (2026-09-16); фоновая
# работа обязана уступать CPU/IO, наследуется всеми детьми агента.
# nice одного не хватило (PSI cpu 40-77% в часы прогона, телеметрия 15-17.09): прогон
# идёт transient-юнитом в ccwork.slice с жёстким CPUQuota=200%. Корень длительности
# (перезакладка всего корпуса эмбеддингов на каждый вызов) закрыт кэшем в finding-dedup.py.
# Установка crontab (XDG_RUNTIME_DIR нужен systemd-run --user из cron-окружения):
#   0 */6 * * * XDG_RUNTIME_DIR=/run/user/1000 flock -n /tmp/session-observer.lock systemd-run --user --quiet --wait --collect --slice=ccwork.slice --unit=session-observer-cron -p CPUQuota=200% /home/genlorem/Projects/brain-dream/orchestrator/session-observer-cron.sh
set -euo pipefail

REPO="${REPO:-$HOME/Projects/brain-dream}"
LOG="${LOG:-$HOME/life/state/logs/session-observer.log}"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1

echo "=== $(date -u +%FT%TZ) session-observer cron run ==="
printf '%s\n' '{"task":"observe-sessions","invoked_by":"cron","config":{"dry_run":false},"env":{}}' \
  | BRAIN_DREAM_REPO="$REPO" nice -n 19 ionice -c 3 bash "$REPO/agents/session-observer.sh"
echo "=== exit $? ==="
