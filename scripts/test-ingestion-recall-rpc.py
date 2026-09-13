#!/usr/bin/env python3
"""Verify exclusion against Memory captured by an older, real helper and a new helper."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_hashes(source_root):
    return {str(p.relative_to(source_root)): sha(p) for p in sorted((source_root / "Sources").rglob("*.swift"))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, default=ROOT)
    parser.add_argument("--legacy-binary", type=Path, required=True,
                        help="A retained pre-recall-suppression helper, e.g. the b16 development package.")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    legacy = args.legacy_binary.resolve(strict=True)
    out = args.output.resolve()
    source_root = args.source_root.resolve(strict=True)
    assert (source_root / "Sources/VelaCore/MemoryService.swift").is_file()
    if out.exists():
        parser.error("Choose a new evidence path")
    out.parent.mkdir(parents=True, exist_ok=True)
    (ROOT / ".task-tmp").mkdir(exist_ok=True)
    base = Path(tempfile.mkdtemp(prefix="ingestion-recall-rpc-", dir=ROOT / ".task-tmp")).resolve()
    copies = {}
    for name, path in [("legacy", legacy), ("candidate", binary)]:
        copies[name] = base / ("vela-" + name)
        shutil.copy2(path, copies[name])
    project, other, logs, home = [base / name for name in ("project", "other", "logs", "home")]
    for path in [project, other, logs / "claude", home]:
        path.mkdir(parents=True)
    env = dict(os.environ, HOME=str(base), VELA_HOME=str(home), VELA_SESSION_ROOT=str(logs),
               VELA_DISABLE_DISCOVERY="1", GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
    result = {"format": "vela-ingestion-recall-real-legacy-rpc-v1", "status": "failed",
              "startedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "providerRuns": 0, "modelDownloads": 0, "synthetic": True,
              "legacyHelperSHA256": sha(legacy), "candidateHelperSHA256": sha(binary),
              "candidateSourceRoot": str(source_root), "sourceBefore": source_hashes(source_root), "testSHA256Before": sha(Path(__file__)), "checks": []}
    proc = None
    transcript = []
    phase = "legacy"

    def stop():
        if proc is not None and proc.poll() is None:
            proc.stdin.close()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)

    def start(name, source_root_override=None):
        process_env = dict(env)
        if source_root_override is not None:
            process_env['VELA_SESSION_ROOT'] = str(source_root_override)
        return subprocess.Popen([str(copies[name]), "rpc", "--no-watch", "--no-schedule"],
                                env=process_env, cwd=project, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True)

    def call(method, params=None):
        request = {"id": len(transcript) + 1, "method": method, "params": params or {}}
        proc.stdin.write(json.dumps(request) + "\n")
        proc.stdin.flush()
        assert select.select([proc.stdout], [], [], 30)[0], "RPC deadline: " + method
        response = json.loads(proc.stdout.readline())
        transcript.append({"phase": phase, "request": request, "response": response})
        assert response.get("id") == request["id"] and "error" not in response, (method, response)
        return response["result"]

    def check(name, **details):
        result["checks"].append({"name": name, "passed": True, **details})

    try:
        for name in ("excluded", "allowed"):
            row = {"type": "user", "uuid": name, "sessionId": name, "cwd": str(project),
                   "message": {"role": "user", "content": "Privacy policy boundary: " + name + " source evidence."}}
            (logs / "claude" / (name + ".jsonl")).write_text(json.dumps(row) + "\n")
        log_hashes = {p.name: sha(p) for p in (logs / "claude").iterdir()}
        proc = start("legacy")
        for path in (project, other):
            call("projects.add", {"path": str(path)})
        call("sessions.refresh")
        captured = {}
        for session in call("sessions.list", {"project": str(project)}):
            detail = call("sessions.get", {"id": session["id"]})
            message = next(x for x in detail["messages"] if x.get("role") == "user")
            name = "excluded" if "excluded source" in message["content"] else "allowed"
            fields = {"project": str(project), "sessionId": session["id"], "messageId": message["id"]}
            prepared = call("memory.capture.prepare", fields)
            memory = call("memory.capture", dict(fields, sourceIdentity=prepared["sourceIdentity"],
                                                expectedSourceHash=prepared["expectedSourceHash"]))
            captured[name] = call("memory.transition", {"id": memory["id"], "state": "active"})["id"]
            assert memory["provenance"]["origin"] == "observed_session_capture"
            assert memory["provenance"]["sourcePath"].endswith(name + ".jsonl")
        assert set(captured) == {"excluded", "allowed"}
        manual = call("memory.save", {"project": str(project), "scope": "project", "state": "active",
                                     "title": "Privacy policy boundary", "content": "Privacy policy boundary: manually authored knowledge."})
        global_memory = call("memory.save", {"scope": "global", "state": "active",
                                            "title": "Privacy policy boundary", "content": "Privacy policy boundary: global knowledge."})
        memory_hashes = {p.name: sha(p) for p in (home / "assets/memory").iterdir() if p.is_file()}
        stop()
        phase = "candidate"
        proc = start("candidate")
        indexed = call("memory.semantic.index", {"project": str(project), "language": "en"})
        assert indexed.get("status") == "ok", "Installed semantic model unavailable; semantic checks cannot pass"
        embedded = call("memory.semantic.embed", {"project": str(project), "language": "en", "text": "Privacy policy boundary"})
        assert embedded["status"] == "ok" and embedded["downloadRequested"] is False
        result["installedSemanticModel"] = embedded["model"]

        def retrieved(target=project):
            common = {"project": str(target), "budget": 4000}
            found = {}
            for mode in ("lexical", "semantic", "hybrid"):
                response = call("recall", dict(common, query="Privacy policy boundary", retrievalMode=mode))
                found[mode] = {x["id"] for x in response["items"]}
            response = call("memory.semantic.recent", dict(common, query="Privacy policy boundary", language="en", minSimilarity=0))
            found["recent"] = {x["id"] for x in response["items"]}
            response = call("memory.semantic.query", dict(common, model=embedded["model"], vector=embedded["vector"], minSimilarity=0))
            found["vector"] = {x["id"] for x in response["items"]}
            return found

        for route, ids in retrieved().items():
            assert set(captured.values()).issubset(ids), ("baseline", route, ids)
        check("legacy-real-capture-visible-before-exclusion", capturedIDs=captured)
        source = call("ingestion.exclusions.upsert", {"project": str(project), "provider": "claude", "pathGlob": "excluded.jsonl"})
        for route, ids in retrieved().items():
            assert captured["excluded"] not in ids and captured["allowed"] in ids, ("source", route, ids)
        assert manual["id"] in retrieved()["lexical"]
        check("source-rule-suppresses-legacy-capture-across-five-retrieval-routes")
        stop()
        proc = start("candidate")
        for route, ids in retrieved().items():
            assert captured["excluded"] not in ids and captured["allowed"] in ids, ("restart", route, ids)
        check("legacy-source-binding-survives-helper-restart")
        # Unresolved protected legacy provenance must not become user-authored
        # provenance simply because the provider root configuration changed.
        stop()
        phase = "candidate-changed-source-root"
        moved_logs = base / "changed-roots"
        (moved_logs / "claude").mkdir(parents=True)
        proc = start("candidate", moved_logs)
        for route, found in retrieved().items():
            assert not set(captured.values()).intersection(found), (route, "unresolved legacy provenance bypassed source exclusion")
        unchanged_manual = call("recall", {"project": str(project), "query": "Privacy policy boundary", "budget": 4000})
        assert {manual['id'], global_memory['id']}.issubset({x['id'] for x in unchanged_manual['items']})
        stop()
        phase = "candidate-restored-source-root"
        proc = start("candidate")
        for route, found in retrieved().items():
            assert captured['excluded'] not in found and captured['allowed'] in found, route
        check("changed-source-root-fails-closed-for-legacy-capture-without-hiding-manual-assets")
        whole = call("ingestion.exclusions.upsert", {"project": str(project)})
        for route, ids in retrieved().items():
            assert not ids, ("excluded-project", route, ids)
        other_recall = call("recall", {"project": str(other), "query": "Privacy policy boundary", "budget": 4000})
        assert {x["id"] for x in other_recall["items"]} == {global_memory["id"]}
        check("whole-project-blocks-global-injection-without-affecting-other-project")
        assert set(captured.values()).issubset({x["id"] for x in call("memory.list", {"project": str(project)})})
        assert memory_hashes == {p.name: sha(p) for p in (home / "assets/memory").iterdir() if p.is_file()}
        check("canonical-memory-management-and-file-bytes-preserved")
        for rule in (whole, source):
            call("ingestion.exclusions.remove", {"project": str(project), "id": rule["id"]})
        call("memory.semantic.index", {"project": str(project), "language": "en"})
        for route, ids in retrieved().items():
            assert set(captured.values()).issubset(ids), ("restored", route, ids)
        assert log_hashes == {p.name: sha(p) for p in (logs / "claude").iterdir()}
        check("explicit-removal-restores-retrieval-and-original-logs-stay-unchanged")
        result["status"] = "passed"
    except Exception as error:
        result["failure"] = type(error).__name__ + ": " + str(error)
    finally:
        stop()
        result["helperStopped"] = proc is None or proc.poll() is not None
        result["sourceAfter"] = source_hashes(source_root)
        result["testSHA256After"] = sha(Path(__file__))
        result["sourcesUnchanged"] = result["sourceBefore"] == result["sourceAfter"] and result["testSHA256Before"] == result["testSHA256After"]
        result["helpersUnchanged"] = sha(binary) == sha(copies["candidate"]) == result["candidateHelperSHA256"] and sha(legacy) == sha(copies["legacy"]) == result["legacyHelperSHA256"]
        if not result["sourcesUnchanged"] or not result["helpersUnchanged"]:
            result["status"] = "failed"
        out.with_suffix(".rpc.json").write_text(json.dumps(transcript, ensure_ascii=False, indent=2) + "\n")
        shutil.rmtree(base)
        result["fixtureRemoved"] = not base.exists()
        result["finishedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({k: v for k, v in result.items() if k not in ("sourceBefore", "sourceAfter")}, ensure_ascii=False))
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
