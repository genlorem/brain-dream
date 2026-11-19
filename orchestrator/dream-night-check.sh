#!/usr/bin/env bash
# Проверка ночи сна (крон 23:20 и 23:55 UTC + поздний слот 00:40 за вчера), docs/design/dream-v2.md §6.3 и §3.
#   * сон сегодня дописал отчёт → журнал дел (tools/dream-cases.py night, режим
#     DREAM_CASES_MODE, по умолчанию shadow; повторный вызов за ту же дату — no-op);
#   * сон стартовал, а отчёта нет → один повтор (--force) с алертом; повтор тоже
#     пустой → алерт без повтора;
#   * DREAM_NIGHT_DATE=<вчера> (поздний слот) — только журнал дел за ту дату, без повтора сна:
#     06.11.2026 сон кончил в 23:58 UTC, обе проверки увидели still_running, ночь в журнал не попала.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$DIR")"
LOG="${BRAIN_DREAM_LOG:-$HOME/life/state/logs/brain-dream.log}"
D="${DREAM_NIGHT_DATE:-$(date -u +%F)}"
MARK="$HOME/.cache/brain-dream/retry-$D"
ALERT="$HOME/bin/brain-act-alert.sh"
PY="${BRAIN_VENV_PY:-$HOME/brain/engine/.venv/bin/python}"

note() { printf '%s stage=night-check %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }

if grep -aq "^$D.*stage=output event=markdown_written" "$LOG" 2>/dev/null; then
  if [ "${DREAM_CASES_MODE:-shadow}" != "off" ]; then
    # код выхода — от dream-cases.py, не от фильтра (05–18.11 Traceback уходил в cases_ok без алерта)
    raw=$("$PY" "$REPO/tools/dream-cases.py" night --date "$D" 2>&1); rc=$?
    out=$(printf '%s\n' "$raw" | grep -v -E 'UserWarning|_MODEL =|Fetching [0-9]+ files|HF_TOKEN')
    if [ "$rc" -eq 0 ]; then
      note "event=cases_ok ${out:0:300}"
      # отчёт есть, а находок 0 — новый формат синтеза (11.11.2026 «1. **…**» прошёл мимо парсера)
      if printf '%s' "$out" | grep -q '"insights": 0,'; then
        [ -x "$ALERT" ] && "$ALERT" "dream-cases $D: отчёт есть, находок 0 — формат синтеза?"
      fi
    else
      out=$(printf '%s\n' "$out" | tail -n 3 | tr '\n' ' ')
      note "event=cases_failed rc=$rc ${out:0:300}"
      [ -x "$ALERT" ] && "$ALERT" "dream-cases $D упал: ${out:0:200}"
    fi
  fi
  exit 0
fi

grep -aq "^$D.*stage=start " "$LOG" 2>/dev/null || exit 0   # сегодня сон не запускался
if [ -n "${DREAM_NIGHT_DATE:-}" ]; then   # поздний слот: повтор сна за прошлую дату не запускаем
  note "event=late_no_report date=$D"
  [ -x "$ALERT" ] && "$ALERT" "сон $D без отчёта и к позднему слоту — смотреть $LOG"
  exit 0
fi
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
