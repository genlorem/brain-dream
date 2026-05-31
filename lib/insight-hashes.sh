#!/usr/bin/env bash
# insight-hashes.sh — менеджер registry дедупликации между ночами.
#
# Registry: ~/brain/dreams/.insight-hashes.jsonl (по строке на инсайт).
#   {
#     "hash": "...",
#     "first_seen_epoch": 1780100000,
#     "last_seen_epoch": 1780180000,
#     "hit_count": 3,
#     "confidence": 0.85,
#     "title": "...",
#     "lens": "problem",
#     "domain": "travelmart/task"
#   }
#
# Окно дедупликации: DREAM_DEDUP_WINDOW_DAYS (по умолчанию 14).
# При повторе hash в окне: hit_count += 1, confidence += 0.05 (но <= 0.95
# для свежих повторов; до 1.0 — только через ручную промоушн).
#
# Использование (через source):
#   source "$BRAIN_DREAM_REPO/lib/content-hash.sh"
#   source "$BRAIN_DREAM_REPO/lib/insight-hashes.sh"
#   if registry_has_hash "$h"; then ... ; fi

INSIGHT_REGISTRY="${INSIGHT_REGISTRY:-$HOME/brain/dreams/.insight-hashes.jsonl}"
DREAM_DEDUP_WINDOW_DAYS="${DREAM_DEDUP_WINDOW_DAYS:-14}"

# Returns 0 if hash present and within window, 1 otherwise.
registry_has_hash() {
  local h="$1"
  [[ -f "$INSIGHT_REGISTRY" ]] || return 1
  local cutoff
  cutoff=$(($(date -u +%s) - DREAM_DEDUP_WINDOW_DAYS * 86400))
  jq -e --arg h "$h" --argjson cutoff "$cutoff" '
    select(.hash == $h and .last_seen_epoch >= $cutoff)' "$INSIGHT_REGISTRY" \
    >/dev/null 2>&1
}

# Incrementally bump hit_count and confidence on existing entry.
registry_bump_hit() {
  local h="$1"
  [[ -f "$INSIGHT_REGISTRY" ]] || return 1
  local now tmp
  now=$(date -u +%s)
  tmp="${INSIGHT_REGISTRY}.tmp.$$"
  jq -c --arg h "$h" --argjson now "$now" '
    if .hash == $h then
      .hit_count = ((.hit_count // 1) + 1)
      | .confidence = (
          if (.confidence // 0.7) < 0.95
          then ((.confidence // 0.7) + 0.05)
          else (.confidence // 0.7)
          end
        )
      | .last_seen_epoch = $now
    else . end' "$INSIGHT_REGISTRY" > "$tmp" && mv "$tmp" "$INSIGHT_REGISTRY"
}

# Append a new entry. Args: hash, title, lens, domain, confidence, dream_id.
# dream_id (e.g. "dream:2026-05-31") — связь обратно к ночному прогону,
# где этот инсайт впервые появился. Используется dream-critic'ом для
# провенанса в permanent/, и publisher'ом для sync-scores в Notion.
registry_append() {
  local h="$1" title="$2" lens="$3" domain="$4" confidence="${5:-0.7}" dream_id="${6:-}"
  local now
  now=$(date -u +%s)
  mkdir -p "$(dirname "$INSIGHT_REGISTRY")"
  jq -nc \
    --arg h "$h" \
    --arg t "$title" \
    --arg l "$lens" \
    --arg d "$domain" \
    --arg did "$dream_id" \
    --argjson now "$now" \
    --argjson c "$confidence" \
    '{hash:$h, first_seen_epoch:$now, last_seen_epoch:$now,
      hit_count:1, confidence:$c, title:$t, lens:$l, domain:$d,
      dream_id:(if $did=="" then null else $did end)}' \
    >> "$INSIGHT_REGISTRY"
}

# Compact: keep only entries within window (для размера registry).
registry_compact() {
  [[ -f "$INSIGHT_REGISTRY" ]] || return 0
  local cutoff tmp
  cutoff=$(($(date -u +%s) - DREAM_DEDUP_WINDOW_DAYS * 86400))
  tmp="${INSIGHT_REGISTRY}.tmp.$$"
  jq -c --argjson cutoff "$cutoff" 'select(.last_seen_epoch >= $cutoff)' \
    "$INSIGHT_REGISTRY" > "$tmp" && mv "$tmp" "$INSIGHT_REGISTRY"
}
