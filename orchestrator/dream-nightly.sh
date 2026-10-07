#!/usr/bin/env bash
# Ночной запуск сна с боевыми параметрами — одно место для крона и для повтора
# пустой ночи (dream-night-check.sh). --force пропускает адаптивный триггер.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DREAM_DOMAINS="travelmart personal marquiz skvo indie govori infra"
export DREAM_COST_LIMIT_USD=0.50 DREAM_CONCURRENCY=3 DREAM_SLEEP=1 DREAM_GEMINI_BACKEND=cli
export DREAM_MAX_RUNS=200 DREAM_GEMINI_MODEL=gemini-2.5-flash DREAM_WRITE_NODE=1
export DREAM_NODE_ROOT="$HOME/brain/dreams" DREAM_TG_MODE=single DREAM_RECENT_WEIGHT_PCT=70
if [ "${1:-}" != "--force" ]; then
  "$DIR/dream-should-run.sh" || exit 0
fi
exec /bin/bash "$DIR/brain-dream.sh"
