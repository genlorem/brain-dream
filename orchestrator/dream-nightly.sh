#!/usr/bin/env bash
# Ночной запуск сна с боевыми параметрами — одно место для крона и для повтора
# пустой ночи (dream-night-check.sh). --force пропускает адаптивный триггер.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DREAM_DOMAINS="travelmart personal marquiz skvo indie govori infra"
export DREAM_WRITE_NODE=1
export DREAM_NODE_ROOT="$HOME/brain/dreams" DREAM_TG_MODE=single DREAM_RECENT_WEIGHT_PCT=70
if [ "${1:-}" != "--force" ]; then
  "$DIR/dream-should-run.sh" || exit 0
fi
exec /bin/bash "$DIR/brain-dream.sh"
