#!/usr/bin/env python3
"""Focused, process-free regression for the UI bridge displayed-approval gate."""
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("vela_ui_server", ROOT / "scripts/test-ui-server.py")
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
Bridge = module.Bridge

harbor = "/synthetic/Harbor"
bridge = Bridge.__new__(Bridge)
bridge.fixture = {"project": harbor, "projects": [harbor]}
bridge.displayed_approvals = {
    "known": {"id": "known", "project": harbor, "snapshotHash": "a" * 64,
              "tool": "file.write", "arguments": {"path": "docs/check.md", "content": "synthetic"}},
    "foreign": {"id": "foreign", "project": "/synthetic/Foreign", "snapshotHash": "b" * 64,
                "tool": "file.write", "arguments": {"path": "blocked.md", "content": "synthetic"}},
}

def rejected(name, fn):
    try:
        fn()
    except ValueError:
        return {"case": name, "rejected": True}
    raise AssertionError(name + " unexpectedly passed")

approved = bridge.displayed_approval_for_decision({"id": "known", "decision": "approve", "snapshotHash": "a" * 64})
assert approved["tool"] == "file.write" and approved["arguments"]["path"] == "docs/check.md"
checks = [{"case": "known-rendered-exact-snapshot", "accepted": True}]
checks += [
    rejected("unknown-id", lambda: bridge.displayed_approval_for_decision({"id": "missing", "decision": "approve", "snapshotHash": "a" * 64})),
    rejected("foreign-cached-project", lambda: bridge.displayed_approval_for_decision({"id": "foreign", "decision": "approve", "snapshotHash": "b" * 64})),
    rejected("snapshot-mismatch", lambda: bridge.displayed_approval_for_decision({"id": "known", "decision": "approve", "snapshotHash": "b" * 64})),
    rejected("extra-decision-field", lambda: bridge.displayed_approval_for_decision({"id": "known", "decision": "approve", "snapshotHash": "a" * 64, "project": harbor})),
    rejected("shell-tool", lambda: bridge.tool("shell.test", {"executable": "/bin/sh"}, harbor)),
]
print(json.dumps({"passed": True, "checks": checks}, sort_keys=True))
