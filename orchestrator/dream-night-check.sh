#!/usr/bin/env bash
# Проверка ночи сна (крон 20:30 и 23:30 UTC), docs/design/dream-v2.md §6.3 и §3.
#   * сон сегодня дописал отчёт → журнал дел (tools/dream-cases.py night, режим
#     DREAM_CASES_MODE, по умолчанию shadow; повторный вызов за ту же дату — no-op);
#   * сон стартовал, а отчёта нет → один повтор (--force) с алертом; повтор тоже
#     пустой → алерт без повтора.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$DIR")"
LOG="${BRAIN_DREAM_LOG:-$HOME/life/state/logs/brain-dream.log}"
D=$(date -u +%F)
MARK="$HOME/.cache/brain-dream/retry-$D"
ALERT="$HOME/bin/brain-act-alert.sh"
PY="${BRAIN_VENV_PY:-$HOME/brain/engine/.venv/bin/python}"

note() { printf '%s stage=night-check %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }

if grep -aq "^$D.*stage=output event=markdown_written" "$LOG" 2>/dev/null; then
  if [ "${DREAM_CASES_MODE:-shadow}" != "off" ]; then
    if out=$("$PY" "$REPO/tools/dream-cases.py" night --date "$D" 2>&1 | grep -v -E 'UserWarning|_MODEL ='); then
      note "event=cases_ok ${out:0:300}"
    else
      note "event=cases_failed ${out:0:300}"
      [ -x "$ALERT" ] && "$ALERT" "dream-cases $D упал: ${out:0:200}"
    fi
  fi
  exit 0
fi

grep -aq "^$D.*stage=start " "$LOG" 2>/dev/null || exit 0   # сегодня сон не запускался
pgrep -f '[b]rain-dream\.sh' >/dev/null && { note "event=still_running"; exit 0; }

mkdir -p "$(dirname "$MARK")"
if [ -e "$MARK" ]; then
  note "event=retry_empty"
  [ -x "$ALERT" ] && "$ALERT" "сон $D пустой и после повтора — смотреть $LOG"
  exit 0
fi
touch "$MARK"
note "event=retry_start"
[ -x "$ALERT" ] && "$ALERT" "сон $D без отчёта — запускаю повтор"
setsid -f "$DIR/dream-nightly.sh" --force >> "$LOG" 2>&1 < /dev/null
