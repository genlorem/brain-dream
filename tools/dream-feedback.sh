#!/usr/bin/env bash
set -euo pipefail

# dream-feedback — CLI для ручной оценки инсайтов сна.
#
# Usage:
#   dream-feedback <insight-hash> <useful|noise|known> [note]
#   dream-feedback list                              # последние 20 записей
#   dream-feedback stats                             # useful_rate по lens/domain/model
#   dream-feedback help
#
# Пишет в ~/brain/dreams/.feedback.jsonl. Eженедельный agent читает и
# аггрегирует. Hash можно скопировать из топ-10 в TG или из dream-нодты:
# либо полный 16-сим, либо короткий 8-сим (первые 8). При коллизии 8-сим
# (редко) выбирается самый свежий по first_seen.
#
# verdict:
#   useful — действительно полезный, сработал/применил
#   noise  — мимо, общее место, бесполезно
#   known  — уже знал, не новость (но не вредно)

FEEDBACK="${DREAM_FEEDBACK:-$HOME/brain/dreams/.feedback.jsonl}"
REGISTRY="${INSIGHT_REGISTRY:-$HOME/brain/dreams/.insight-hashes.jsonl}"

usage() {
  sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \?//' >&2
}

resolve_hash() {
  local input="$1"
  if [[ "${#input}" -eq 16 ]]; then
    printf '%s\n' "$input"
    return 0
  fi
  if [[ "${#input}" -ge 8 ]]; then
    # Префикс — берём самый свежий совпадающий.
    if [[ -f "$REGISTRY" ]]; then
      jq -r --arg p "$input" 'select(.hash | startswith($p)) | "\(.last_seen_epoch) \(.hash)"' \
        "$REGISTRY" 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2
    fi
    return 0
  fi
  return 1
}

case "${1:-help}" in
  help|-h|--help)
    usage
    exit 0
    ;;
  list)
    if [[ -f "$FEEDBACK" ]]; then
      tail -20 "$FEEDBACK" | jq -r '"\(.ts)  \(.hash[0:8])  \(.verdict)\(if .note then "  «\(.note)»" else "" end)"'
    else
      echo "(no feedback yet)" >&2
    fi
    ;;
  stats)
    if [[ ! -f "$FEEDBACK" ]]; then echo "(no feedback yet)" >&2; exit 0; fi
    echo "=== Total ==="
    jq -s 'group_by(.verdict) | map({verdict:.[0].verdict, count:length})' "$FEEDBACK"
    echo ""
    echo "=== Last 30 days ==="
    cutoff=$(( $(date -u +%s) - 30 * 86400 ))
    jq -s --argjson c "$cutoff" '
      [.[] | select(.epoch >= $c)]
      | length as $total
      | (group_by(.verdict) | map({verdict:.[0].verdict, count:length})) as $by_v
      | { total: $total, by_verdict: $by_v,
          useful_rate: ( ([.[] | select(.verdict=="useful")] | length) / (if $total>0 then $total else 1 end) ) }
    ' "$FEEDBACK"
    ;;
  *)
    hash_input="$1"
    verdict="${2:-}"
    note="${3:-}"
    if [[ -z "$verdict" ]]; then
      echo "Error: verdict required (useful|noise|known)" >&2
      usage
      exit 1
    fi
    case "$verdict" in useful|noise|known) ;; *)
      echo "Error: verdict must be useful|noise|known" >&2; exit 1
    esac
    resolved=$(resolve_hash "$hash_input")
    if [[ -z "$resolved" ]]; then
      echo "Error: hash «$hash_input» not found in registry" >&2
      exit 1
    fi
    mkdir -p "$(dirname "$FEEDBACK")"
    epoch=$(date -u +%s)
    ts=$(date -u +%FT%TZ)
    jq -nc \
      --arg ts "$ts" \
      --argjson epoch "$epoch" \
      --arg h "$resolved" \
      --arg v "$verdict" \
      --arg n "$note" \
      '{ts:$ts, epoch:$epoch, hash:$h, verdict:$v} + (if $n != "" then {note:$n} else {} end)' \
      >> "$FEEDBACK"
    echo "OK: recorded $verdict for $resolved" >&2

    # useful = триггер промоута: инсайт признан полезным → предложить завести
    # из него ноду Brain (dream-promote). Только в интерактивном терминале —
    # путь TG-бота (не-tty) не трогаем. Адресуем по сну инсайта (дата из реестра).
    if [[ "$verdict" == "useful" && -t 0 && -t 1 ]]; then
      promote="$(dirname "$0")/dream-promote.py"
      dream_id=""
      if [[ -f "$REGISTRY" ]]; then
        dream_id=$(jq -r --arg h "$resolved" \
          'select(.hash==$h) | .dream_id' "$REGISTRY" 2>/dev/null | head -1)
      fi
      dream_date="${dream_id#dream:}"
      if [[ -x "$promote" && -n "$dream_date" ]]; then
        printf 'Промоутнуть инсайт в Brain (сон %s)? [y/N] ' "$dream_date" >&2
        read -r ans || ans=""
        case "${ans,,}" in
          y|yes|д|да) "$promote" "$dream_date" >&2 ;;
          *) printf 'Позже: %s %s <N>\n' "$promote" "$dream_date" >&2 ;;
        esac
      fi
    fi
    ;;
esac
