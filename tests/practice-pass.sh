#!/usr/bin/env bash
# Интеграционный тест стадии `practice` в orchestrator/brain-dream.sh.
#
# Проверяет проводку моста «наблюдения → сон» целиком, без обращения к реальным
# моделям и реальному ~/brain: поднимает локальный digest-сервер, подсовывает
# стабы gemini.sh и claude-pool, гоняет ночь на временном HOME.
#
# Контракт:
#   1. Есть свежие наблюдения → ровно ОДИН дополнительный вызов модели, кандидат
#      с lens=practice попадает в общий пул, source_ids ограничены выборкой.
#   2. Соседний хост недоступен и кэша нет → ночь идёт как раньше, стадия
#      practice логирует skip, exit-код не меняется.
#   3. DREAM_OBSERVATIONS=0 → мост не дёргается вообще.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORCH="$REPO/orchestrator/brain-dream.sh"

TMP="$(mktemp -d /tmp/practice-pass-test.XXXXXX)"
SERVER_PID=""
cleanup() {
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
  # PRACTICE_TEST_KEEP=1 — оставить рабочий каталог для разбора упавшего теста.
  if [[ "${PRACTICE_TEST_KEEP:-0}" == "1" ]]; then
    printf 'рабочий каталог оставлен: %s\n' "$TMP" >&2
  else
    rm -rf "$TMP"
  fi
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok() { printf 'ok — %s\n' "$1"; }

# ── окружение ────────────────────────────────────────────────────────────────
export HOME="$TMP/home"
mkdir -p "$HOME/brain/personal/nodes/notes" "$HOME/life/state/logs" "$TMP/bin"

cat > "$HOME/brain/personal/nodes/notes/svc-proposed.md" <<'NODE'
---
id: note:svc-logs-proposed
title: Предложен svc logs (четвёртая нога svc-toolkit)
type: note
---
Паттерн journalctl предложено закрыть обёрткой `svc-toolkit`, артефакта нет.
NODE

# Стаб Gemini: отдаёт один валидный инсайт JSONL. Ссылается на id ноды, который
# мост обязан положить в allowed_ids.
cat > "$TMP/gemini-stub.sh" <<'STUB'
#!/usr/bin/env bash
context="$(cat)"
printf '%s' "$context" > "${STUB_CONTEXT_SINK:-/dev/null}"
printf '{"title":"Нода про svc logs устарела","insight":"note:svc-logs-proposed говорит про предложение, а артефакт на диске уже есть","why":"граф расходится с практикой","novelty":"non-obvious","confidence":0.8,"source_ids":["note:svc-logs-proposed","obs:built"],"domain":"practice","lens":"practice"}\n'
STUB
chmod +x "$TMP/gemini-stub.sh"
export GEMINI_SH="$TMP/gemini-stub.sh"
export STUB_CONTEXT_SINK="$TMP/context-seen.txt"

# check_dependencies требует claude-pool; синтез тоже идёт через него.
cat > "$TMP/bin/claude-pool" <<'STUB'
#!/usr/bin/env bash
printf '{"result":"1. Нода note:svc-logs-proposed устарела относительно построенного артефакта."}\n'
STUB
chmod +x "$TMP/bin/claude-pool"
export PATH="$TMP/bin:$PATH"

# ── локальный digest ─────────────────────────────────────────────────────────
cat > "$TMP/digest.json" <<'JSON'
{"ok":true,"generatedTs":1786371421494,"host":"test","version":1,"items":[
 {"id":"obs:built","title":"svc logs — journalctl+grep обёртка","kind":"script",
  "summary":"Паттерн journalctl повторяется, нужна нога `svc-toolkit`.",
  "proposal":"Добавить libexec/logs.sh","status":"materialized",
  "occurrences":132,"sessions":27,"projects":26,"score":209,
  "artifact":"~/Projects/infra/svc-toolkit/libexec/logs.sh","coverage":"verified",
  "firstSeenTs":1785093620619,"lastSeenTs":1786286005464}]}
JSON

PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
(cd "$TMP" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >"$TMP/http.log" 2>&1) &
SERVER_PID=$!
for _ in $(seq 1 50); do
  if curl -fsS -o /dev/null "http://127.0.0.1:$PORT/digest.json" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
curl -fsS -o /dev/null "http://127.0.0.1:$PORT/digest.json" \
  || fail "локальный http-сервер не поднялся (порт $PORT)"

run_night() {
  env BRAIN_DREAM_FLOCKED=1 \
    HOME="$HOME" PATH="$PATH" GEMINI_SH="$GEMINI_SH" STUB_CONTEXT_SINK="$STUB_CONTEXT_SINK" \
    DREAM_DOMAINS="personal" \
    DREAM_MAX_RUNS=0 \
    DREAM_OUT_DIR="$HOME/brain/dreams" \
    DREAM_SONNET_FALLBACK=0 \
    DREAM_DIGEST_DEDUP=0 \
    DREAM_TG_DIGEST=0 \
    DREAM_WRITE_NODE=0 \
    DREAM_FEEDBACK_BIAS=0 \
    DREAM_COST_LIMIT_USD=0 \
    "$@" \
    bash "$ORCH" >/dev/null 2>&1
}

LOG="$HOME/life/state/logs/brain-dream.log"

# ── 1. живой digest ──────────────────────────────────────────────────────────
run_night DREAM_OBSERVATIONS=1 \
  DREAM_OBSERVATIONS_URL="http://127.0.0.1:$PORT/digest.json" \
  || fail "прогон с живым digest завершился ненулевым кодом"

grep -q 'stage=practice event=done' "$LOG" || fail "стадия practice не отработала (нет event=done)"
ok "стадия practice отработала на живом digest"

grep -q 'PRACTICE DIGEST' "$STUB_CONTEXT_SINK" \
  || fail "в модель ушёл контекст без блока PRACTICE DIGEST"
grep -q 'artifact_on_disk: ~/Projects/infra/svc-toolkit/libexec/logs.sh' "$STUB_CONTEXT_SINK" \
  || fail "в контексте нет подтверждённого на диске артефакта"
grep -q 'note:svc-logs-proposed' "$STUB_CONTEXT_SINK" \
  || fail "мост не подтянул ноду графа, которая про это же наблюдение"
ok "контекст содержит и практику, и сопоставленную ноду графа"

# CANDIDATES_FILE — временный файл прогона, к концу ночи его уже нет; смотрим
# на то, что переживает прогон: реестр инсайтов и отчёт.
REGISTRY="$HOME/brain/dreams/.insight-hashes.jsonl"
[[ -s "$REGISTRY" ]] || fail "реестр инсайтов пуст — кандидат practice не дошёл до конца ночи"
practice_count="$(jq -s '[.[] | select(.lens == "practice")] | length' "$REGISTRY")"
[[ "$practice_count" == "1" ]] || fail "ожидался ровно 1 кандидат practice, получено $practice_count"
grep -q -- '- practice: 1' "$HOME/brain/dreams/dream-$(date -u +%F).md" \
  || fail "кандидат practice не виден в разбивке по линзам"
ok "кандидат practice прошёл общий дедуп, реестр и синтез"

SEL="$HOME/brain/dreams/.observations-selection.json"
jq -e '.allowed_ids | index("note:svc-logs-proposed")' "$SEL" >/dev/null \
  || fail "id сопоставленной ноды не попал в allowed_ids — модель не сможет на него сослаться"
jq -e '.items[0].class == "conformance"' "$SEL" >/dev/null \
  || fail "наблюдение с подтверждённым артефактом должно быть classed conformance"
ok "выборка моста: класс conformance, id ноды разрешён как source_id"

gemini_calls="$(grep -c 'stage=generation event=gemini_ok' "$LOG" || true)"
[[ "$gemini_calls" == "1" ]] || fail "мост должен стоить ровно один вызов модели, было $gemini_calls"
ok "стоимость моста — ровно один вызов модели"

grep -q 'Practice bridge: fed' "$HOME/brain/dreams/dream-$(date -u +%F).md" \
  || fail "в отчёт ночи не попал статус моста"
ok "статус моста виден в отчёте ночи"

# ── 2. соседний хост недоступен, кэша нет ────────────────────────────────────
rm -rf "$HOME/brain/dreams"
: > "$LOG"
run_night DREAM_OBSERVATIONS=1 \
  DREAM_OBSERVATIONS_URL="http://127.0.0.1:1/api/observations/digest" \
  DREAM_OBSERVATIONS_TIMEOUT=2 \
  || fail "недоступный digest уронил ночь"
grep -q 'stage=practice event=skip reason=no_new_observations' "$LOG" \
  || fail "нет ожидаемого fail-open лога при недоступном хосте"
[[ ! -s "$HOME/brain/dreams/.candidates.jsonl" ]] \
  || fail "при недоступном digest не должно появиться practice-кандидатов"
ok "недоступный соседний хост: ночь идёт как раньше"

# ── 3. выключенный мост ──────────────────────────────────────────────────────
rm -rf "$HOME/brain/dreams"
: > "$LOG"
run_night DREAM_OBSERVATIONS=0 \
  DREAM_OBSERVATIONS_URL="http://127.0.0.1:$PORT/digest.json" \
  || fail "прогон с выключенным мостом завершился ненулевым кодом"
grep -q 'stage=practice event=skip reason=disabled' "$LOG" \
  || fail "DREAM_OBSERVATIONS=0 не выключает мост"
ok "DREAM_OBSERVATIONS=0 полностью выключает мост"

printf '\nВсе проверки practice-pass прошли.\n'
