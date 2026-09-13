#!/usr/bin/env python3
"""Actual local RPC acceptance for verified candidate-only session Memory capture."""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class RPC:
    def __init__(self, binary: Path, home: Path, sources: Path):
        self.process = subprocess.Popen(
            [str(binary), "rpc", "--home", str(home), "--no-watch", "--no-schedule"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            env={**os.environ, "VELA_DISABLE_DISCOVERY": "1", "VELA_SESSION_ROOT": str(sources)},
        )
        self.next_id = 0

    def request(self, method, params):
        self.next_id += 1
        self.process.stdin.write(json.dumps({"id": self.next_id, "method": method, "params": params}) + "\n")
        self.process.stdin.flush()
        while True:
            line = self.process.stdout.readline()
            assert line, self.process.stderr.read()
            response = json.loads(line)
            if response.get("id") == self.next_id:
                return response

    def call(self, method, params):
        response = self.request(method, params)
        assert "error" not in response, (method, response)
        return response["result"]

    def rejected(self, method, params):
        response = self.request(method, params)
        assert response.get("error", {}).get("code") == -32602, (method, response)

    def close(self):
        self.process.stdin.close()
        assert self.process.wait(timeout=15) == 0, self.process.stderr.read()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / ".build/debug/vela")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists() or args.output.is_symlink():
        parser.error("choose a new receipt path; existing evidence is immutable")
    receipt = {"status": "failed", "startedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
               "checks": [], "providerCalls": 0, "sourceData": "synthetic Codex JSONL only"}
    try:
        with tempfile.TemporaryDirectory(prefix="vela-session-memory-capture-rpc-") as temporary:
            base = Path(temporary); frozen = base / "vela"
            shutil.copy2(args.binary.resolve(strict=True), frozen)
            frozen.chmod(0o700); helper_hash = digest(frozen)
            receipt["frozenHelperSHA256"] = helper_hash
            project, other, store, sources = base / "project", base / "other", base / "store", base / "sources"
            project.mkdir(); other.mkdir(); (sources / "codex").mkdir(parents=True)
            rows = [
                {"timestamp": "2026-09-13T00:00:00Z", "type": "session_meta", "payload": {"id": "capture-thread", "cwd": str(project)}},
                {"timestamp": "2026-09-13T00:00:01Z", "type": "response_item", "payload": {"type": "message", "id": "source-message", "role": "assistant", "content": [{"type": "output_text", "text": "Use a focused regression test before shipping the release."}]}},
            ]
            (sources / "codex" / "capture.jsonl").write_text("".join(json.dumps(row) + "\n" for row in rows))
            rpc = RPC(frozen, store, sources)
            try:
                rpc.call("projects.add", {"path": str(project)})
                rpc.call("projects.add", {"path": str(other)})
                rpc.call("sessions.refresh", {})
                sessions = rpc.call("sessions.list", {"project": str(project)})
                assert len(sessions) == 1, sessions
                session_id = sessions[0]["id"]
                prepared = rpc.call("memory.capture.prepare", {"project": str(project), "sessionId": session_id, "messageId": "source-message"})
                assert prepared["content"] == "Use a focused regression test before shipping the release."
                assert prepared["state"] == "candidate" and prepared["sourceObservation"] == "observed" and prepared["modelCalls"] == 0
                receipt["checks"].append("prepare_returns_core_resolved_observed_source_and_fresh_hash")
                request = {"project": str(project), "sessionId": session_id, "messageId": "source-message", "sourceIdentity": prepared["sourceIdentity"], "expectedSourceHash": prepared["expectedSourceHash"]}
                created = rpc.call("memory.capture", request)
                assert created["created"] and created["state"] == "candidate" and created["requiresReview"] and created["modelCalls"] == 0
                provenance = created["provenance"]
                assert provenance["origin"] == "observed_session_capture" and provenance["contentEqualsObservedSource"]
                # The selected message is unchanged; a later unrelated message must not
                # invalidate its prepared hash. Refresh keeps the current session CAS basis.
                with (sources / "codex" / "capture.jsonl").open("a") as source:
                    source.write(json.dumps({"timestamp": "2026-09-13T00:00:02Z", "type": "response_item", "payload": {"type": "message", "id": "later-message", "role": "assistant", "content": [{"type": "output_text", "text": "Unrelated later message."}]}}) + "\n")
                rpc.call("sessions.refresh", {})
                replay = rpc.call("memory.capture", request)
                assert not replay["created"] and replay["idempotent"] and replay["id"] == created["id"]
                rpc.call("memory.transition", {"id": created["id"], "state": "active"})
                replay_active = rpc.call("memory.capture", request)
                assert replay_active["state"] == "active" and replay_active["requiresReview"] is True
                receipt["checks"].append("capture_creates_candidate_then_unchanged_message_survives_unrelated_session_append_and_replay_preserves_active_lifecycle")
                rpc.rejected("memory.capture.prepare", {"project": str(other), "sessionId": session_id, "messageId": "source-message"})
                rpc.rejected("memory.capture", {**request, "expectedSourceHash": "0" * 64})
                rpc.rejected("memory.capture", {**request, "content": "caller supplied"})
                receipt["checks"].append("cross_project_stale_and_caller_content_requests_write_nothing")
                rpc.rejected("memory.save", {"id": created["id"], "project": str(project), "title": "forged", "content": prepared["content"], "provenance": {"origin": "user"}})
                rpc.rejected("memory.save", {"id": created["id"], "project": str(project), "title": "forged", "content": prepared["content"], "sourceSession": "forged"})
                edited = rpc.call("memory.save", {"id": created["id"], "project": str(project), "title": "Edited observation", "content": "A reviewer changed this wording."})
                assert edited["provenance"]["origin"] == "observed_session_capture"
                assert not edited["provenance"]["contentEqualsObservedSource"] and edited["provenance"]["derivedBy"] == "user_edit"
                replay_edited = rpc.call("memory.capture", request)
                assert replay_edited["content"] == edited["content"] and replay_edited["state"] == "active"
                receipt["checks"].append("generic_save_cannot_forge_source_and_marks_user_derived_content")
                assert digest(frozen) == helper_hash
                receipt["status"] = "pass"
            finally:
                rpc.close()
        receipt["temporarySourcesAndStoreRemoved"] = not base.exists()
    except Exception as error:
        receipt["error"] = str(error)
        raise
    finally:
        receipt["finishedAt"] = dt.datetime.now(dt.timezone.utc).isoformat()
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
        print(json.dumps(receipt, ensure_ascii=False, indent=2))

if __name__ == "__main__":
    main()
