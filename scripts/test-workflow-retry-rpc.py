#!/usr/bin/env python3
"""Actual JSON-RPC acceptance for bounded workflow retries, using local Git only."""
import json
import os
import pathlib
import subprocess
import tempfile

os.environ["VELA_DISABLE_DISCOVERY"] = "1"
ROOT = pathlib.Path(__file__).resolve().parents[1]
BINARY = (ROOT / ".build/debug/vela").resolve(strict=True)


def call(home, method, params):
    frame = {"id": 1, "method": method, "params": params}
    result = subprocess.run([str(BINARY), "rpc", "--home", str(home), "--no-watch", "--no-schedule"], input=json.dumps(frame) + "\n", text=True, capture_output=True, timeout=30)
    assert result.returncode == 0, result.stderr
    answer = json.loads(result.stdout)
    return answer


with tempfile.TemporaryDirectory(prefix="vela-workflow-retry-rpc-") as temporary:
    base = pathlib.Path(temporary)
    home, project = base / "store", base / "not-a-git-repository"
    project.mkdir()
    assert "result" in call(home, "projects.add", {"path": str(project)})
    retry = {"maxAttempts": 2, "initialBackoffMs": 50, "maxBackoffMs": 50}
    saved = call(home, "workflows.save", {"title": "Retry local status", "project": str(project), "steps": [{"tool": "git.status", "retry": retry}]})
    assert "result" in saved, saved
    run = call(home, "workflows.run", {"id": saved["result"]["id"], "dryRun": False})
    assert "result" in run, run
    step = run["result"]["steps"][0]
    assert run["result"]["state"] == "failed" and len(step["attempts"]) == 2, run
    assert step["retryPolicy"] == retry and step["attempts"][0]["backoffMs"] == 50, step
    forbidden = call(home, "workflows.save", {"title": "Never replay write", "project": str(project), "steps": [{"tool": "file.write", "arguments": {"path": "must-not-write", "content": "x"}, "retry": retry}]})
    assert "error" in forbidden and not (project / "must-not-write").exists(), forbidden
print("Workflow retry JSON-RPC passed: fixed local read attempts are bounded and write retry is rejected")
