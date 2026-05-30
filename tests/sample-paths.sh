#!/usr/bin/env bash
# Регресс-тест для orchestrator/brain-dream.sh::sample_paths.
#
# История: 30 мая 2026 коммит 849f0d2f завёл в sample_paths опечатку
# `\$'\t'` вместо `$'\t'`, из-за которой sort -t падал с
# «multi-character tab '$\t'», sample_paths возвращала пустоту,
# launch_iteration всю ночь логировал skip_empty_sample, и production-сон
# не дал ни одного инсайта. Этот тест ловит подобные опечатки в shell-quoting.
#
# Контракт: при наличии минимум 1 .md-ноды в нужной доменной директории
# collect_nodes + sample_paths для iteration=0 ДОЛЖНЫ вернуть как минимум
# один путь. Если возвращают пусто — тест валится.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORCH="$REPO/orchestrator/brain-dream.sh"

# Изолированная среда: ноды в tmp, чтобы тест не зависел от ~/brain.
TMP="$(mktemp -d /tmp/sample-paths-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

BRAIN_ROOT="$TMP/brain"
mkdir -p "$BRAIN_ROOT/personal/nodes/decisions"
mkdir -p "$BRAIN_ROOT/personal/nodes/notes"
for name in alpha beta gamma delta epsilon; do
  cat > "$BRAIN_ROOT/personal/nodes/decisions/$name.md" <<NODE
---
title: $name
type: decision
---
body of $name
NODE
done
for name in one two three; do
  cat > "$BRAIN_ROOT/personal/nodes/notes/$name.md" <<NODE
---
title: $name
type: note
---
body of $name
NODE
done

# Подменяем domain_root через HOME — orchestrator ищет $HOME/brain/<dom>/nodes.
export HOME="$TMP"
export BRAIN_DREAM_FLOCKED=1
export BRAIN_DREAM_REPO="$REPO"
export ORCHESTRATOR_DIR="$REPO/orchestrator"
export DREAM_DOMAINS="personal"
export DREAM_RECENT_WEIGHT_PCT=70
export DREAM_OUT_DIR="$TMP/out"
export DREAM_CONCURRENCY=1
export DREAM_MAX_RUNS=1
export DREAM_SLEEP=0
export DREAM_COST_LIMIT_USD=0
export DREAM_TG_MODE=legacy
export DREAM_DEADLINE_UTC=""
export BRAIN_DREAM_LOG="$TMP/brain-dream.log"

# Source функции orchestrator без запуска main "$@".
SRC="$TMP/orch-source.sh"
head -n "$(($(grep -n '^main "\$@"' "$ORCH" | head -1 | cut -d: -f1) - 1))" "$ORCH" > "$SRC"

# shellcheck disable=SC1090
source "$SRC"

collect_nodes
node_count="$(line_count "$NODES_FILE")"
cluster_count="$(line_count "$CLUSTERS_FILE")"

if (( node_count == 0 )); then
  echo "FAIL: collect_nodes собрал 0 нод (ожидалось >0)" >&2
  exit 1
fi
if (( cluster_count == 0 )); then
  echo "FAIL: collect_nodes построил 0 кластеров" >&2
  exit 1
fi

# Главная проверка: для каждого кластера sample_paths на iteration=0 не пуст.
fail=0
for ((idx = 0; idx < cluster_count; idx += 1)); do
  line="$(cluster_line_at "$idx")"
  IFS=$'\t' read -r d c <<< "$line"
  out="$(sample_paths "$d" "$c" 0 2)"
  if [[ -z "$out" ]]; then
    echo "FAIL: sample_paths('$d','$c',0,2) вернул пусто" >&2
    fail=1
    continue
  fi
  # Каждая возвращённая строка должна быть существующим файлом.
  while IFS= read -r p; do
    if [[ ! -f "$p" ]]; then
      echo "FAIL: sample_paths вернул несуществующий путь: $p" >&2
      fail=1
    fi
  done <<< "$out"
done

if (( fail != 0 )); then
  exit 1
fi

echo "OK: sample_paths возвращает валидные пути для всех $cluster_count кластеров"
