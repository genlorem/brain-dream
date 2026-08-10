#!/usr/bin/env python3
"""Тесты моста «наблюдения → сон» (tools/observations-bridge.py).

Гоняются на реальном HTTP-сервере на 127.0.0.1 и реальном временном корпусе
Brain — так проверяются именно те пути, которые ночью и работают: живой digest,
падение соседнего хоста, кэш, протухший кэш, леджер.

Запуск: python3 tests/observations-bridge.py
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from tempfile import TemporaryDirectory

REPO = Path(__file__).resolve().parent.parent
BRIDGE = REPO / "tools" / "observations-bridge.py"

spec = importlib.util.spec_from_file_location("observations_bridge", BRIDGE)
assert spec and spec.loader
bridge = importlib.util.module_from_spec(spec)
sys.modules["observations_bridge"] = bridge
spec.loader.exec_module(bridge)


def item(**kw):
    base = {
        "id": "obs_bash:0000",
        "title": "заглушка",
        "kind": "script",
        "summary": "",
        "proposal": "",
        "status": "pending",
        "occurrences": 100,
        "sessions": 10,
        "projects": 5,
        "score": 100,
        "artifact": None,
        "coverage": "missing",
        "firstSeenTs": 1785093620619,
        "lastSeenTs": 1786286005464,
    }
    base.update(kw)
    return base


class DigestServer:
    """Мини-сервер digest: отдаёт что положили, умеет отвечать 500."""

    def __init__(self, payload):
        self.payload = payload
        self.fail = False
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):  # noqa: N802
                if outer.fail:
                    self.send_error(500, "nope")
                    return
                body = json.dumps(outer.payload).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_args):
                pass

        self.httpd = HTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_exc):
        self.httpd.shutdown()
        self.httpd.server_close()

    @property
    def url(self):
        host, port = self.httpd.server_address[:2]
        return f"http://{host}:{port}/api/observations/digest"


class BridgeCase(unittest.TestCase):
    def setUp(self):
        self._tmp = TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.corpus = self.tmp / "brain" / "personal" / "nodes"
        self.corpus.mkdir(parents=True)
        self.cache = self.tmp / "cache.json"
        self.ledger = self.tmp / "seen.jsonl"
        self.selection = self.tmp / "sel.json"

    def tearDown(self):
        self._tmp.cleanup()

    def node(self, name: str, node_id: str, title: str, body: str, stale: bool = False):
        fm = [f"id: {node_id}", f"title: {title}", "type: note"]
        if stale:
            fm.append("superseded_by: procedure:something-newer")
        (self.corpus / f"{name}.md").write_text(
            "---\n" + "\n".join(fm) + "\n---\n" + body + "\n", encoding="utf-8"
        )

    def run_bridge(self, url, *extra, expect=0):
        cmd = [
            sys.executable,
            str(BRIDGE),
            "--url", url,
            "--cache", str(self.cache),
            "--ledger", str(self.ledger),
            "--brain-root", str(self.tmp / "brain"),
            "--domains", "personal",
            "--json-out", str(self.selection),
            "--timeout", "3",
            *extra,
        ]
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        self.assertEqual(proc.returncode, expect, msg=f"stderr:\n{proc.stderr}")
        sel = json.loads(self.selection.read_text(encoding="utf-8"))
        return proc.stdout, sel

    # ── выборка ──────────────────────────────────────────────────────────────

    def test_classification_and_noise_filtering(self):
        self.node(
            "svc-proposed",
            "note:svc-logs-proposed",
            "Предложен svc logs",
            "Паттерн journalctl предложено закрыть скриптом `svc-toolkit` logs.sh, "
            "артефакта пока нет.",
        )
        payload = {
            "ok": True,
            "generatedTs": int(time.time() * 1000),
            "host": "test",
            "items": [
                # построено на диске + в графе есть нода → conformance
                item(
                    id="obs:built",
                    title="svc logs — journalctl обёртка",
                    summary="Паттерн повторяется, нужна нога svc-toolkit.",
                    status="materialized",
                    coverage="verified",
                    artifact="~/Projects/infra/svc-toolkit/libexec/logs.sh",
                    occurrences=132,
                ),
                # построено, но граф молчит → undocumented-reality
                item(
                    id="obs:silent",
                    title="Построен ~/bin/quokka-inspector",
                    summary="Есть на диске, в графе про него ничего.",
                    status="materialized",
                    coverage="verified",
                    artifact="~/bin/quokka-inspector",
                    occurrences=60,
                ),
                # много повторов, в графе ничего → unwritten-practice
                item(
                    id="obs:gap",
                    title="Обёртка `wombat-deploy.sh` для выкатки",
                    summary="Руками гоняют 90 раз.",
                    occurrences=90,
                    sessions=12,
                ),
                # практика уже описана в графе → не расхождение, режем
                item(
                    id="obs:covered",
                    title="svc logs через `svc-toolkit`",
                    summary="journalctl рутина.",
                    occurrences=80,
                    sessions=12,
                ),
                # шум нормализатора → режем до всякого сопоставления
                item(
                    id="obs:noise",
                    title="Automate recurring workflow: cd ~/x && git log --oneline -15",
                    occurrences=784,
                    sessions=64,
                ),
                # мало повторов → режем
                item(
                    id="obs:weak",
                    title="Редкий хелпер `numbat-check.sh`",
                    occurrences=3,
                    sessions=1,
                ),
            ],
        }
        with DigestServer(payload) as srv:
            out, sel = self.run_bridge(srv.url)

        classes = {i["id"]: i["class"] for i in sel["items"]}
        self.assertEqual(classes.get("obs:built"), "conformance")
        self.assertEqual(classes.get("obs:silent"), "undocumented-reality")
        self.assertEqual(classes.get("obs:gap"), "unwritten-practice")
        self.assertNotIn("obs:covered", classes, "практика, описанная в графе, не расхождение")
        self.assertNotIn("obs:noise", classes)
        self.assertNotIn("obs:weak", classes)
        self.assertEqual(sel["stats"]["generic_noise"], 1)
        self.assertEqual(sel["stats"]["already_in_graph"], 1)
        self.assertEqual(sel["stats"]["below_threshold"], 1)

        # conformance идёт первым — это самый ценный класс
        self.assertEqual(sel["items"][0]["id"], "obs:built")
        # источник — живой, в контексте есть и наблюдение, и id ноды графа
        self.assertEqual(sel["source"], "live")
        self.assertIn("obs:built", out)
        self.assertIn("note:svc-logs-proposed", out)
        self.assertIn("artifact_on_disk", out)
        self.assertIn("note:svc-logs-proposed", sel["allowed_ids"])

    def test_stale_node_is_flagged(self):
        self.node(
            "old",
            "note:pgrep-proposed",
            "Предложен svc-proc",
            "Паттерн `pgrep -fa` предложено закрыть `svc-toolkit`.",
            stale=True,
        )
        payload = {
            "ok": True,
            "generatedTs": int(time.time() * 1000),
            "items": [
                item(
                    id="obs:proc",
                    title="svc proc построен",
                    summary="Обёртка над `pgrep -fa` в `svc-toolkit`.",
                    status="materialized",
                    coverage="verified",
                    artifact="~/Projects/infra/svc-toolkit/libexec/proc.sh",
                )
            ],
        }
        with DigestServer(payload) as srv:
            out, _ = self.run_bridge(srv.url)
        self.assertIn("[помечена устаревшей]", out)

    def test_nonspecific_tokens_are_dropped_and_item_is_not_a_false_gap(self):
        # Токен, встречающийся в половине корпуса, ничего не различает. Если он
        # у наблюдения единственный — про такое наблюдение НЕЛЬЗЯ сказать, есть
        # ли о нём нода, и кормить его как «в графе ничего нет» нельзя.
        for i in range(60):
            self.node(f"n{i}", f"note:n{i}", f"нода {i}", "везде есть слово wombat-deploy")
        payload = {
            "ok": True,
            "generatedTs": int(time.time() * 1000),
            "items": [
                item(id="obs:vague", title="Рутина вокруг `wombat-deploy`", occurrences=90),
                item(id="obs:sharp", title="Обёртка `numbat-release.sh`", occurrences=90),
            ],
        }
        with DigestServer(payload) as srv:
            _, sel = self.run_bridge(srv.url, "--token-df-max-pct", "1.0")
        fed = {i["id"]: i for i in sel["items"]}
        self.assertNotIn("obs:vague", fed, "неразличающий ключ не даёт судить о покрытии")
        self.assertEqual(sel["stats"]["no_strong_key"], 1)
        self.assertEqual(fed["obs:sharp"]["class"], "unwritten-practice")
        self.assertEqual(fed["obs:sharp"]["nodes"], [])

    def test_secrets_are_scrubbed(self):
        payload = {
            "ok": True,
            "generatedTs": int(time.time() * 1000),
            "items": [
                item(
                    id="obs:leak",
                    title="Скрипт `deploy-quokka.sh` дергают руками",
                    summary="curl -H 'Authorization: Bearer "
                    + "ghp_" + "A" * 36
                    + "' https://api",
                    occurrences=90,
                )
            ],
        }
        with DigestServer(payload) as srv:
            out, _ = self.run_bridge(srv.url)
        self.assertIn("[REDACTED-github]", out)
        self.assertNotIn("ghp_" + "A" * 36, out)

    def test_max_chars_truncates(self):
        items = [
            item(
                id=f"obs:{i}",
                title=f"Обёртка `helper-{i}.sh` вокруг рутины",
                summary="x" * 500,
                occurrences=90,
            )
            for i in range(10)
        ]
        payload = {"ok": True, "generatedTs": int(time.time() * 1000), "items": items}
        with DigestServer(payload) as srv:
            out, sel = self.run_bridge(srv.url, "--max-chars", "2000")
        self.assertLessEqual(len(out), 2000)
        self.assertLess(sel["stats"]["fed"], 10)

    # ── устойчивость к недоступности соседнего хоста ─────────────────────────

    def test_cache_used_when_host_down(self):
        payload = {
            "ok": True,
            "generatedTs": int(time.time() * 1000),
            "items": [item(id="obs:gap", title="Обёртка `wombat-deploy.sh`", occurrences=90)],
        }
        with DigestServer(payload) as srv:
            url = srv.url
            self.run_bridge(url)
        self.assertTrue(self.cache.exists(), "успешный ответ обязан лечь в кэш")

        # Хост исчез (порт больше никто не слушает) + чистим леджер, чтобы
        # проверялся именно фолбэк на кэш, а не подавление повтора.
        self.ledger.unlink(missing_ok=True)
        out, sel = self.run_bridge(url)
        self.assertTrue(sel["source"].startswith("cache"))
        self.assertIn("obs:gap", out)

    def test_stale_cache_is_refused(self):
        payload = {
            "ok": True,
            "generatedTs": int(time.time() * 1000),
            "items": [item(id="obs:gap", title="Обёртка `wombat-deploy.sh`", occurrences=90)],
        }
        with DigestServer(payload) as srv:
            url = srv.url
            self.run_bridge(url)
        blob = json.loads(self.cache.read_text(encoding="utf-8"))
        blob["fetchedAt"] = time.time() - 400 * 3600
        self.cache.write_text(json.dumps(blob), encoding="utf-8")
        self.ledger.unlink(missing_ok=True)
        # exit 3 = кормить нечем, но это не ошибка: сон идёт как раньше
        out, sel = self.run_bridge(url, expect=3)
        self.assertEqual(out, "")
        self.assertEqual(sel["items"], [])

    def test_no_host_no_cache_is_not_an_error(self):
        out, sel = self.run_bridge("http://127.0.0.1:1/api/observations/digest", expect=3)
        self.assertEqual(out, "")
        self.assertEqual(sel["items"], [])

    def test_broken_payload_is_not_an_error(self):
        with DigestServer({"ok": False, "items": []}) as srv:
            out, _ = self.run_bridge(srv.url, expect=3)
        self.assertEqual(out, "")

    # ── леджер: не кормить сон одним и тем же каждую ночь ────────────────────

    def test_ledger_suppresses_repeat_and_releases_on_growth(self):
        payload = {
            "ok": True,
            "generatedTs": int(time.time() * 1000),
            "items": [item(id="obs:gap", title="Обёртка `wombat-deploy.sh`", occurrences=90)],
        }
        with DigestServer(payload) as srv:
            _, sel = self.run_bridge(srv.url)
            self.assertEqual(sel["stats"]["fed"], 1)

            # Вторая ночь, наблюдение то же — молчим.
            _, sel = self.run_bridge(srv.url, expect=3)
            self.assertEqual(sel["stats"]["ledger_suppressed"], 1)

            # Повторы заметно выросли — сигнал снова живой.
            payload["items"][0]["occurrences"] = 200
            _, sel = self.run_bridge(srv.url)
            self.assertEqual(sel["stats"]["fed"], 1)

            # Смена статуса тоже размыкает подавление (построили артефакт).
            payload["items"][0]["status"] = "materialized"
            payload["items"][0]["coverage"] = "verified"
            payload["items"][0]["artifact"] = "~/bin/wombat-deploy.sh"
            _, sel = self.run_bridge(srv.url)
            self.assertEqual(sel["items"][0]["class"], "undocumented-reality")

    # ── юнит-уровень: извлечение ключей ──────────────────────────────────────

    def test_strong_tokens_skip_generic_words(self):
        obs = bridge.as_obs(
            item(
                title="`view KEY` печатает всё — агенты дописывают `| head -N`",
                summary="Чинить в `~/life/scripts/yandex-tracker.sh`, флаг `--brief`.",
            )
        )
        tokens = [t.lower() for t in bridge.strong_tokens(obs)]
        self.assertIn("yandex-tracker.sh", tokens)
        self.assertNotIn("view", tokens)
        self.assertNotIn("--brief", tokens, "голый флаг ничего не идентифицирует")
        # путь ранжируется выше фразы
        self.assertLess(
            tokens.index("~/life/scripts/yandex-tracker.sh")
            if "~/life/scripts/yandex-tracker.sh" in tokens
            else tokens.index("yandex-tracker.sh"),
            tokens.index("view key") if "view key" in tokens else len(tokens),
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
