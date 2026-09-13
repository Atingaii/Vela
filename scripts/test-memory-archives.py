"""Exercise the real CLI/RPC archive path with synthetic, disposable stores only."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
binary = root / ".build/debug/vela"
assert binary.is_file(), "Run swift build first"
env = {**os.environ, "VELA_DISABLE_DISCOVERY": "1"}
checks = []

with tempfile.TemporaryDirectory(prefix="vela-archive-rpc-") as temporary:
    fixture = Path(temporary)
    source_project = fixture / "source-project"
    target_project = fixture / "target-project"
    source_project.mkdir()
    target_project.mkdir()
    source = fixture / "source-store"
    target = fixture / "target-store"

    def call(store, method, params):
        result = subprocess.run(
            [str(binary), "call", method, json.dumps(params, ensure_ascii=False), "--home", str(store)],
            env=env, capture_output=True, text=True, timeout=15, check=True,
        )
        assert not result.stderr.strip(), result.stderr
        return json.loads(result.stdout)

    for store, project in [(source, source_project), (target, target_project)]:
        call(store, "projects.add", {"path": str(project)})
    text = "Actual CLI roundtrip: 中文 /tmp/original 'quoted' <reference>."
    original = call(source, "memory.save", {
        "title": "Archive interoperability fixture", "content": text,
        "project": str(source_project), "state": "active", "scope": "project",
    })
    call(source, "memory.save", {
        "title": "Private fixture", "content": "PRIVATE-FIXTURE-DO-NOT-EXPORT",
        "project": str(source_project), "private": True,
    })
    exported = call(source, "memory.archive.export", {"project": str(source_project)})
    assert exported["count"] == 1 and not exported["includesPrivate"]
    archive_path = fixture / "memory.json"
    archive_path.write_text(json.dumps(exported["archive"], ensure_ascii=False), encoding="utf-8")
    restored_archive = json.loads(archive_path.read_text(encoding="utf-8"))
    assert "PRIVATE-FIXTURE-DO-NOT-EXPORT" not in archive_path.read_text(encoding="utf-8")
    validation = call(target, "memory.archive.validate", {"archive": restored_archive})
    assert validation["valid"] and not validation["authenticated"]
    checks.append("real CLI export, disk transfer and validate preserve integrity and privacy")

    # Import through the actual persistent JSONL RPC dispatcher; source is closed.
    request = {"id": 1, "method": "memory.archive.import", "params": {
        "project": str(target_project), "archive": restored_archive,
    }}
    rpc = subprocess.run(
        [str(binary), "rpc", "--no-watch", "--home", str(target)],
        input=json.dumps(request, ensure_ascii=False) + "\n", env=env,
        capture_output=True, text=True, timeout=15, check=True,
    )
    responses = [json.loads(line) for line in rpc.stdout.splitlines()]
    response = next(item for item in responses if item.get("id") == 1)
    assert "error" not in response, response
    imported = response["result"]
    assert imported["imported"] == 1 and imported["state"] == "candidate"
    record = next(item for item in call(target, "memory.list", {"project": str(target_project)}) if item["id"] == imported["ids"][0])
    assert record["content"] == text and record["scope"] == "project"
    assert record["id"] != original["id"]
    assert call(target, "recall", {"project": str(target_project), "query": "roundtrip"})["items"] == []
    repeat = call(target, "memory.archive.import", {"project": str(target_project), "archive": restored_archive})
    assert repeat["imported"] == 0 and repeat["skipped"] == 1
    checks.append("RPC import survives helper exit, creates only candidates and is idempotent")

    # CLI activation is an explicit review action separate from import.
    call(target, "memory.transition", {"id": record["id"], "state": "active"})
    recalled = call(target, "recall", {"project": str(target_project), "query": "roundtrip"})["items"]
    assert len(recalled) == 1 and recalled[0]["content"] == text
    checks.append("explicit review activates the restored original text for recall")

    mcp_request = {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}
    mcp = subprocess.run(
        [str(binary), "mcp", "--home", str(target)],
        input=json.dumps(mcp_request) + "\n", env=env,
        capture_output=True, text=True, timeout=15, check=True,
    )
    tools = json.loads(mcp.stdout)["result"]["tools"]
    assert all("archive" not in tool["name"] for tool in tools)
    checks.append("default MCP gains no archive export or import authority")

print(json.dumps({
    "checks": checks, "passed": len(checks), "failed": 0,
    "binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
    "fixturesRemoved": True,
}, ensure_ascii=False, indent=2))
