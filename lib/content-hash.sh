#!/usr/bin/env bash
# content-hash.sh — детерминированный хеш для дедупликации инсайтов.
#
# Алгоритм:
#   1) trim + lowercase + схлопывание whitespace в один пробел
#   2) join title|insight
#   3) sha256, первые 16 символов hex
#
# Использование (через source):
#   source "$BRAIN_DREAM_REPO/lib/content-hash.sh"
#   h=$(content_hash_insight "<title>" "<insight>")

normalize_for_hash() {
  # printf избегает потерь от echo на строках с -e/-n
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -s '[:space:]' ' ' \
    | sed 's/^ //; s/ $//'
}

content_hash_insight() {
  local title="$1" insight="$2"
  local combined
  combined="$(normalize_for_hash "$title")|$(normalize_for_hash "$insight")"
  printf '%s' "$combined" | sha256sum | cut -c1-16
}
