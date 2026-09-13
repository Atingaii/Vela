import asyncio
import base64
import hashlib
import json
import os
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest

from vela import AsyncVelaClient, LocalTransport, VelaBulkError, VelaCancelledError, VelaClient, VelaError

BINARY = os.environ.get("VELA_TEST_HELPER", str(Path(__file__).resolve().parents[3] / ".build/debug/vela"))


class SDKTests(unittest.TestCase):
    def test_session_capture_validates_identity_references_before_transport_dispatch(self):
        client = self.client()
        with self.assertRaises(VelaError) as error:
            client.prepare_session_capture("bad\x00", "message")
        self.assertEqual(error.exception.code, "invalid_input")
        with self.assertRaises(VelaError) as error:
            client.capture_session_candidate("session", "message", "codex:thread", "bad")
        self.assertEqual(error.exception.code, "invalid_input")
        with self.assertRaises(VelaError) as error:
            client.capture_session_candidate("session", "message", "bad\nidentity", "0" * 64)
        self.assertEqual(error.exception.code, "invalid_input")

    def test_installed_sdk_prepares_and_captures_a_real_indexed_session_message(self):
        sources = self.root / "sources"
        (sources / "codex").mkdir(parents=True)
        rows = [
            {"type": "session_meta", "payload": {"id": "python-capture-thread", "cwd": str(self.project)}},
            {"type": "response_item", "payload": {"type": "message", "id": "python-source-message", "role": "assistant", "content": [{"type": "output_text", "text": "Verify capture through the installed Python package."}]}},
        ]
        (sources / "codex" / "capture.jsonl").write_text("".join(json.dumps(row) + "\n" for row in rows))
        prior = os.environ.get("VELA_SESSION_ROOT")
        os.environ["VELA_SESSION_ROOT"] = str(sources)
        try:
            client = self.client()
            client.register_project(str(self.project))
            subprocess.run([BINARY, "call", "sessions.refresh", "--home", str(self.root / "store")], env={**os.environ, "VELA_DISABLE_DISCOVERY": "1", "VELA_SESSION_ROOT": str(sources)}, check=True, capture_output=True, timeout=15)
            sessions = json.loads(subprocess.run([BINARY, "call", "sessions.list", json.dumps({"project": str(self.project)}), "--home", str(self.root / "store")], env={**os.environ, "VELA_DISABLE_DISCOVERY": "1", "VELA_SESSION_ROOT": str(sources)}, check=True, capture_output=True, text=True, timeout=15).stdout)
            self.assertEqual(len(sessions), 1)
            prepared = client.prepare_session_capture(sessions[0]["id"], "python-source-message")
            self.assertEqual(prepared["content"], "Verify capture through the installed Python package.")
            captured = client.capture_session_candidate(prepared["sessionId"], prepared["messageId"], prepared["sourceIdentity"], prepared["expectedSourceHash"])
            self.assertEqual(captured["state"], "candidate")
            self.assertTrue(captured["requiresReview"])
            self.assertEqual(client.capture_session_candidate(prepared["sessionId"], prepared["messageId"], prepared["sourceIdentity"], prepared["expectedSourceHash"])["id"], captured["id"])
        finally:
            if prior is None:
                os.environ.pop("VELA_SESSION_ROOT", None)
            else:
                os.environ["VELA_SESSION_ROOT"] = prior

    def test_integration_namespace_reopen_remains_candidate(self):
        client = self.client()
        client.register_project(str(self.project))
        records = [{"id": "message-1", "role": "user", "content": "SQLite namespaces keep independent project agents separated."}]
        self.assertEqual(client.capture_integration("researcher", "run-1", records)["created"], 1)
        client.close()
        reopened = self.client()
        self.assertEqual(reopened.capture_integration("researcher", "run-1", records)["skipped"], 1)
        self.assertEqual(reopened.integration_stats("researcher")["observedRecords"], 1)
        self.assertEqual(reopened.integration_stats("main")["observedRecords"], 0)
        self.assertEqual(reopened.recall_integration("researcher", "SQLite")["items"], [])

    def test_responses_source_is_explicit_and_unknown_source_has_zero_writes(self):
        client = self.client()
        client.register_project(str(self.project))
        records = [{"id": "user", "role": "user", "content": "SQLite Responses captures remain reviewable observations."}]
        with self.assertRaises(VelaError) as error:
            client.capture_integration("main", "turn", records, integration="invented")
        self.assertEqual(error.exception.code, "invalid_input")
        self.assertEqual(client.list_memories(), [])
        client.capture_integration("main", "turn", records, integration="openai-responses")
        item = client.list_memories()[0]
        self.assertEqual(item["state"], "candidate")
        self.assertEqual(item["provenance"]["integrationIdentity"]["integration"], "openai-responses")

    def test_langchain_source_is_explicit_and_unknown_source_has_zero_writes(self):
        client = self.client()
        client.register_project(str(self.project))
        records = [{"id": "user", "role": "user", "content": "SQLite LangChain captures remain reviewable observations."}]
        with self.assertRaises(VelaError) as error:
            client.capture_integration("main", "turn", records, integration="invented")
        self.assertEqual(error.exception.code, "invalid_input")
        self.assertEqual(client.list_memories(), [])
        client.capture_integration("main", "turn", records, integration="langchain")
        item = client.list_memories()[0]
        self.assertEqual(item["state"], "candidate")
        self.assertEqual(item["provenance"]["integrationIdentity"]["integration"], "langchain")

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="vela-python-sdk-")
        self.root = Path(self.temporary.name)
        self.project = self.root / "project"
        self.project.mkdir()
        self.clients = []

    def tearDown(self):
        for client in self.clients:
            client.close()
        self.temporary.cleanup()

    def client(self, helper=BINARY, home=None):
        client = VelaClient(LocalTransport(helper, str(home or self.root / "store")), project=str(self.project))
        self.clients.append(client)
        return client

    def fake(self, body):
        path = self.root / "fake-helper"
        path.write_text(f"#!{sys.executable}\nimport sys,json,time,os\nfrom pathlib import Path\nhome=Path(sys.argv[sys.argv.index('--home')+1]);home.mkdir(parents=True,exist_ok=True)\nassert '--no-watch' in sys.argv and '--no-schedule' in sys.argv\n{body}\n")
        path.chmod(0o700)
        return str(path)

    def test_real_sync_roundtrip_and_bulk(self):
        client = self.client()
        client.register_project(str(self.project))
        items = client.save_candidates([{"title": "One", "content": "Original 中文 <reference>."}, {"title": "Two", "content": "Second original."}])
        self.assertEqual(len(items), 2)
        self.assertTrue(all(item["state"] == "candidate" for item in items))
        self.assertEqual(client.recall("Original")["items"], [])
        archive = client.export_archive()["archive"]
        self.assertTrue(client.validate_archive(archive)["valid"])
        client.close()
        with self.assertRaises(VelaError) as caught:
            client.list_projects()
        self.assertEqual(caught.exception.code, "closed")
        reopened = self.client()
        self.assertEqual(len(reopened.list_memories()), 2)
        restored = self.client(home=self.root / "restored")
        restored.register_project(str(self.project))
        self.assertEqual(restored.import_archive(archive)["imported"], 2)
        self.assertEqual(restored.import_archive(archive)["skipped"], 2)
        self.assertEqual({item["content"] for item in restored.list_memories()}, {item["content"] for item in items})

    def test_real_async_roundtrip(self):
        async def scenario():
            async with AsyncVelaClient(LocalTransport(BINARY, str(self.root / "async-store")), project=str(self.project)) as client:
                await client.register_project(str(self.project))
                item = await client.save_candidate({"title": "Async", "content": "Async preserved 中文."})
                self.assertEqual(item["state"], "candidate")
                rows, projects = await asyncio.gather(client.list_memories(), client.list_projects())
                self.assertEqual(rows[0]["content"], item["content"])
                self.assertEqual(len(projects), 1)
                self.assertEqual((await client.recall("preserved"))["items"], [])
        asyncio.run(scenario())

    def test_walrus_original_records_sync_convert_async_import_and_reopen(self):
        source = {"network": "testnet", "packageID": "0x" + "1" * 64, "accountID": "0x" + "2" * 64, "owner": "0x" + "3" * 64, "namespace": "isolated"}
        content = "Original remote 中文 café"
        record = {"blobID": base64.urlsafe_b64encode(bytes([3]) * 32).decode().rstrip("="), "title": "Original", "content": content, "sha256": hashlib.sha256(content.encode()).hexdigest(), "private": False}
        client = self.client()
        client.register_project(str(self.project))
        converted = client.archive_from_walrus_records(source, [record])
        self.assertFalse(converted["authenticated"])
        self.assertFalse(converted["writesPerformed"])
        self.assertEqual(client.list_memories(), [])
        client.close()
        async def scenario():
            async with AsyncVelaClient(LocalTransport(BINARY, str(self.root / "store")), project=str(self.project)) as api:
                again = await api.archive_from_walrus_records(source, [record])
                self.assertEqual(again["archive"], converted["archive"])
                self.assertEqual((await api.import_archive(converted["archive"]))["imported"], 1)
        asyncio.run(scenario())
        reopened = self.client()
        self.assertEqual(reopened.import_archive(converted["archive"])["skipped"], 1)
        self.assertEqual(reopened.list_memories()[0]["content"], content)
        self.assertEqual(reopened.recall("remote")["items"], [])

    def test_real_semantic_pages_reopen_and_async_recall(self):
        client = self.client()
        client.register_project(str(self.project))
        rows = client.save_candidates([{"title": "Transport", "content": "The automobile requires maintenance."}, {"title": "Dessert", "content": "Bake a chocolate cake for the birthday party."}])
        client.close()
        for row in rows:
            subprocess.run([BINARY, "call", "memory.transition", json.dumps({"id": row["id"], "state": "active"}), "--home", str(self.root / "store")], env={**os.environ, "VELA_DISABLE_DISCOVERY": "1"}, check=True, capture_output=True, timeout=15)
        client = self.client()
        status = client.semantic_status(language="en")
        if status["status"] == "unavailable":
            self.assertIsNone(status["model"])
            self.assertEqual(client.recall("automobile", retrieval_mode="hybrid")["retrievalMode"], "lexical")
            return
        self.assertEqual(status["indexed"], 0)
        page = client.semantic_index(language="en", batch_size=1)
        self.assertTrue(page["hasMore"])
        self.assertFalse(client.semantic_index(language="en", batch_size=1, cursor=page["nextCursor"])["hasMore"])
        client.close()
        async def scenario():
            async with AsyncVelaClient(LocalTransport(BINARY, str(self.root / "store")), project=str(self.project)) as api:
                self.assertFalse((await api.semantic_status())["indexIncomplete"])
                self.assertEqual((await api.semantic_index())["unchanged"], 2)
                result = await api.recall("The vehicle needs repair.", retrieval_mode="semantic", language="en", min_similarity=0, limit=2, scoring_weights={"semantic": 1, "recency": 0, "importance": 0, "recency_half_life_days": 30})
                self.assertEqual(result["items"][0]["id"], rows[0]["id"])
                self.assertGreaterEqual(result["items"][0]["semanticSimilarity"], 0)
                if len(result["items"]) > 1:
                    self.assertGreater(result["items"][0]["semanticSimilarity"], result["items"][1]["semanticSimilarity"])
                self.assertEqual((await api.recall("automobile", retrieval_mode="hybrid"))["retrievalMode"], "hybrid")
                with self.assertRaises(VelaError):
                    await api.semantic_index(batch_size=True)
                with self.assertRaises(VelaError):
                    await api.recall("query", min_similarity=float("nan"))
        asyncio.run(scenario())

    def test_installed_explicit_embed_query_recent_boundaries(self):
        client = self.client()
        client.register_project(str(self.project))
        rows = client.save_candidates([{"title": "Older transport", "content": "The automobile requires maintenance."}, {"title": "Newer transport", "content": "The vehicle needs a repair."}])
        client.close()
        for index, row in enumerate(rows):
            subprocess.run([BINARY, "call", "memory.transition", json.dumps({"id": row["id"], "state": "active"}), "--home", str(self.root / "store")], env={**os.environ, "VELA_DISABLE_DISCOVERY": "1"}, check=True, capture_output=True, timeout=15)
            asset = Path(row["assetPath"])
            asset.write_text(asset.read_text().replace("createdAt: ", f"createdAt: 2026-09-1{1 + index}T00:00:00Z"))
        namespace = subprocess.run([BINARY, "call", "memory.save", json.dumps({"project": str(self.project), "title": "Isolated transport", "content": "The namespace automobile requires maintenance.", "scope": "namespace", "namespace": "consumer", "state": "active"}), "--home", str(self.root / "store")], env={**os.environ, "VELA_DISABLE_DISCOVERY": "1"}, check=True, capture_output=True, text=True, timeout=15)
        namespace_id = json.loads(namespace.stdout)["id"]
        private = subprocess.run([BINARY, "call", "memory.save", json.dumps({"project": str(self.project), "title": "Private transport", "content": "Private automobile maintenance.", "scope": "project", "state": "active", "private": True}), "--home", str(self.root / "store")], env={**os.environ, "VELA_DISABLE_DISCOVERY": "1"}, check=True, capture_output=True, text=True, timeout=15)
        private_id = json.loads(private.stdout)["id"]
        client = self.client()
        status = client.semantic_status()
        if status["status"] == "unavailable":
            self.assertIsNone(client.semantic_embed("The vehicle needs repair.")["model"])
            return
        before = client.semantic_status()["indexed"]
        embedded = client.semantic_embed("The vehicle needs repair.")
        self.assertEqual(embedded["status"], "ok")
        self.assertFalse(embedded["persisted"])
        self.assertEqual(client.semantic_status()["indexed"], before)
        with self.assertRaises(VelaError):
            client.semantic_embed("x" * (64 * 1024 + 1))
        cursor = None
        while True:
            page = client.semantic_index(batch_size=1, cursor=cursor)
            if not page["hasMore"]:
                break
            cursor = page["nextCursor"]
        queried = client.semantic_query(embedded, min_similarity=0, limit=10)
        self.assertEqual(queried["querySource"], "precomputed-vector")
        self.assertNotIn(namespace_id, {item["id"] for item in queried["items"]})
        self.assertNotIn(private_id, {item["id"] for item in queried["items"]})
        newest = client.semantic_recent("The vehicle needs repair.", min_similarity=0, limit=2)
        self.assertEqual(newest["sort"], "recent")
        self.assertEqual(newest["items"][0]["id"], rows[1]["id"])
        isolated = client.semantic_recent("The vehicle needs repair.", namespace="consumer", min_similarity=0)
        self.assertEqual([item["id"] for item in isolated["items"]], [namespace_id])
        with self.assertRaises(VelaError):
            client.semantic_recent("query", namespace="consumer", branch="main")
        with self.assertRaises(VelaError):
            client.semantic_query(embedded, sort="recent", scoring_weights={"semantic": 1})
        stale_asset = Path(rows[1]["assetPath"])
        stale_asset.write_text(stale_asset.read_text().replace("The vehicle needs a repair.", "Changed source evidence."))
        stale = client.semantic_query(embedded, min_similarity=0)
        self.assertNotIn(rows[1]["id"], {item["id"] for item in stale["items"]})
        self.assertGreaterEqual(stale["staleVectorsExcluded"], 1)

    def test_prevalidation_rejects_activation_and_invalid_bulk(self):
        client = self.client()
        client.register_project(str(self.project))
        with self.assertRaises(VelaError):
            client.save_candidate({"title": "No", "content": "No activation", "state": "active"})
        with self.assertRaises(VelaError):
            client.save_candidates([{"title": "Valid", "content": "Never sent"}, {"title": "", "content": "Invalid"}])
        self.assertEqual(client.list_memories(), [])

    def test_protocol_errors_and_output_limits_are_sanitized(self):
        for code, body in [
            ("protocol_error", "sys.stdin.readline()\nprint('SECRET_PRIVATE_CONTENT',flush=True)\ntime.sleep(30)"),
            ("output_limit", "sys.stdin.readline()\nsys.stdout.write('S'*(2*1024*1024+1));sys.stdout.flush()\ntime.sleep(30)"),
            ("output_limit", "sys.stdin.readline()\nsys.stderr.write('SECRET'*12000);sys.stderr.flush()\ntime.sleep(30)"),
        ]:
            client = self.client(self.fake(body))
            with self.assertRaises(VelaError) as caught:
                client.list_projects()
            self.assertEqual(caught.exception.code, code)
            self.assertFalse(caught.exception.effects_unknown)
            self.assertNotIn("SECRET", str(caught.exception))
            self.assertIsNotNone(client._process.poll())

    def test_write_timeout_is_uncertain(self):
        client = self.client(self.fake("ready=json.loads(sys.stdin.readline())\nprint(json.dumps({'id':ready['id'],'result':[]}),flush=True)\nr=json.loads(sys.stdin.readline())\n(home/'received').write_text(str(r['id']))\ntime.sleep(30)"), self.root)
        client.list_projects()
        with self.assertRaises(VelaError) as caught:
            client.save_candidate({"title": "Timeout", "content": "May have saved"}, timeout=0.2)
        self.assertEqual(caught.exception.code, "timeout")
        self.assertTrue(caught.exception.effects_unknown)
        self.assertEqual((self.root / "received").read_text(), "2")
        self.assertIsNotNone(client._process.poll())

    def test_async_cancellation_closes_helper_and_preserves_uncertainty(self):
        helper = self.fake("r=json.loads(sys.stdin.readline())\n(home/'received').write_text(str(r['id']))\ntime.sleep(30)")
        async def scenario():
            client = AsyncVelaClient(LocalTransport(helper, str(self.root)), project=str(self.project))
            try:
                task = asyncio.create_task(client.save_candidate({"title": "Abort", "content": "May have saved"}))
                for _ in range(200):
                    if (self.root / "received").exists():
                        break
                    await asyncio.sleep(0.005)
                self.assertTrue((self.root / "received").exists())
                task.cancel()
                with self.assertRaises(VelaCancelledError) as caught:
                    await task
                self.assertTrue(caught.exception.effects_unknown)
                self.assertEqual(caught.exception.request_id, 1)
                self.assertIsNotNone(client._client._process.poll())
            finally:
                await client.close()
        asyncio.run(scenario())

    def test_cancelling_queued_call_does_not_claim_neighbouring_request(self):
        helper = self.fake("r=json.loads(sys.stdin.readline())\n(home/'received').write_text(json.dumps(r))\ntime.sleep(30)")
        async def scenario(active_write):
            (self.root / "received").unlink(missing_ok=True)
            client = AsyncVelaClient(LocalTransport(helper, str(self.root)), project=str(self.project))
            active = asyncio.create_task(client.save_candidate({"title": "Active", "content": "Potentially saved"}) if active_write else client.list_projects())
            try:
                for _ in range(200):
                    if (self.root / "received").exists():
                        break
                    await asyncio.sleep(0.005)
                self.assertTrue((self.root / "received").exists())
                queued = asyncio.create_task(client.list_projects() if active_write else client.save_candidate({"title": "Queued", "content": "Never sent"}))
                await asyncio.sleep(0.05)
                queued.cancel()
                with self.assertRaises(VelaCancelledError) as caught:
                    await queued
                self.assertIsNone(caught.exception.request_id)
                self.assertFalse(caught.exception.effects_unknown)
                with self.assertRaises(VelaError) as active_error:
                    await active
                self.assertEqual(active_error.exception.request_id, 1)
                self.assertEqual(active_error.exception.effects_unknown, active_write)
                self.assertEqual(json.loads((self.root / "received").read_text())["method"], "memory.save" if active_write else "projects.list")
                self.assertIsNotNone(client._client._process.poll())
            finally:
                await client.close()
        for active_write in (True, False):
            asyncio.run(scenario(active_write))

    def test_bulk_failure_reports_completed_and_unattempted(self):
        helper = self.fake("a=json.loads(sys.stdin.readline())\nprint(json.dumps({'id':a['id'],'result':{'id':'one','title':'One','content':'Saved','state':'candidate','project':'/example'}}),flush=True)\nb=json.loads(sys.stdin.readline());(home/'received').write_text(str(b['id']))\nprint(json.dumps({'id':b['id'],'error':{'message':'SECRET_PRIVATE_CONTENT'}}),flush=True)\ntime.sleep(30)")
        client = self.client(helper, self.root)
        with self.assertRaises(VelaBulkError) as caught:
            client.save_candidates([{"title": "One", "content": "Saved"}, {"title": "Two", "content": "Uncertain"}, {"title": "Three", "content": "Never sent"}])
        error = caught.exception
        self.assertEqual((len(error.completed), error.failed_index, error.unattempted), (1, 1, 1))
        self.assertTrue(error.effects_unknown)
        self.assertNotIn("SECRET", str(error))
        self.assertEqual((self.root / "received").read_text(), "2")


if __name__ == "__main__":
    unittest.main(verbosity=2)
