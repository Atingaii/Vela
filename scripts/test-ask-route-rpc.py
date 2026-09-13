#!/usr/bin/env python3
"""Actual JSON-RPC acceptance for bounded, reviewed Ask routes on one synthetic helper."""
import argparse
import hashlib
import json
import os
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]


class RPC:
    def __init__(self, binary, home):
        env = {**os.environ, "VELA_DISABLE_DISCOVERY": "1"}
        self.process = subprocess.Popen([str(binary), "rpc", "--home", str(home), "--no-watch", "--no-schedule"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
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

    def close(self):
        self.process.stdin.close()
        assert self.process.wait(timeout=15) == 0, self.process.stderr.read()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=pathlib.Path, default=ROOT / ".build/debug/vela")
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="vela-ask-route-rpc-") as temporary:
        base = pathlib.Path(temporary)
        home, project = base / "store", base / "project"
        project.mkdir()
        rpc = RPC(binary, home)
        try:
            rpc.call("projects.add", {"path": str(project)})
            question = "界" * 1333 + "a"
            assert len(question.encode()) == 4000
            long_route = rpc.call("ask.route", {"project": str(project), "question": question})
            assert long_route["question"] == question and len(long_route["title"].encode()) <= 240 and long_route["title"].endswith("…"), long_route

            visible = rpc.call("memory.save", {"project": str(project), "title": "Release policy", "content": "Harbor release requires focused tests.", "type": "Constraint", "scope": "Project", "state": "Active"})
            rpc.call("memory.save", {"project": str(project), "title": "Private release policy", "content": "PRIVATE_ASK_ROUTE_SENTINEL", "type": "Fact", "scope": "Project", "state": "Active", "private": True})
            route = rpc.call("ask.route", {"project": str(project), "question": "What is the Harbor release policy?"})
            assert len(route["candidates"]) == 1 and route["candidates"][0]["id"] == visible["id"] and "PRIVATE_ASK_ROUTE_SENTINEL" not in json.dumps(route), route

            count = base / "provider-count"
            provider = base / "fixture-provider.py"
            answer = {"kind": "knowledge_query", "targetId": "memory:" + visible["id"], "reason": "the frozen public release-policy candidate matches"}
            events = [{"type": "thread.started", "thread_id": "ask-route-rpc-fixture"}, {"type": "item.completed", "item": {"id": "answer", "type": "agent_message", "text": json.dumps(answer, separators=(",", ":"))}}, {"type": "turn.completed", "usage": {"input_tokens": 7, "output_tokens": 5}}]
            provider.write_text("#!/usr/bin/env python3\nimport pathlib\npathlib.Path(" + repr(str(count)) + ").write_text('1')\nfor line in " + repr([json.dumps(event, separators=(",", ":")) for event in events]) + ": print(line)\n")
            provider.chmod(0o700)
            proposal = rpc.call("ask.route.propose", {"project": str(project), "id": route["id"], "routeHash": route["routeHash"], "executable": str(provider), "model": "fixture-model", "timeoutSeconds": 30})
            assert proposal["state"] == "pending_approval" and not count.exists(), proposal
            approval = proposal["approval"]
            approved = rpc.call("approvals.decide", {"id": approval["id"], "snapshotHash": approval["snapshotHash"], "decision": "approve"})
            assert approved["state"] == "executed" and count.read_text() == "1", approved

            revocable = rpc.call("memory.save", {"project": str(project), "id": "revocable", "title": "Revocable candidate", "content": "revocable needle", "state": "active", "scope": "project"})
            stale_route = rpc.call("ask.route", {"project": str(project), "question": "revocable needle"})
            rpc.call("memory.save", {"project": str(project), "id": revocable["id"], "title": "private replacement", "content": "revocable needle", "state": "active", "scope": "project", "private": True})
            before = rpc.call("inbox.list", {"project": str(project)})
            stale = rpc.request("ask.route.propose", {"project": str(project), "id": stale_route["id"], "routeHash": stale_route["routeHash"], "executable": str(provider), "model": "fixture-model"})
            after = rpc.call("inbox.list", {"project": str(project)})
            assert stale.get("error", {}).get("code") == -32602 and len(before) == len(after), stale

            rpc.call("memory.save", {"project": str(project), "id": "memory-needle", "title": "Memory needle", "content": "needle", "state": "active", "scope": "project"})
            workflow = rpc.call("workflows.save", {"project": str(project), "title": "Workflow needle", "description": "needle", "enabled": True, "steps": [{"tool": "git.status"}]})
            for number in range(500):
                rpc.call("memory.save", {"project": str(project), "id": f"memory-noise-{number:03d}", "title": "noise", "content": "unrelated", "state": "active", "scope": "project"})
                rpc.call("workflows.save", {"project": str(project), "title": f"workflow noise {number}", "description": "unrelated", "enabled": True, "steps": [{"tool": "git.status"}]})
            bounded = rpc.call("ask.route", {"project": str(project), "question": "needle"})
            assert any(item["id"] == "memory-needle" for item in bounded["candidates"]), bounded
            assert any(item["id"] == workflow["id"] for item in bounded["workflowCandidates"]), bounded

            page = rpc.call("ask.route.list", {"project": str(project), "limit": 1})
            assert page["items"]
            assert not (project / "approved.txt").exists()
        finally:
            rpc.close()
    print(json.dumps({"status": "passed", "helperSHA256": hashlib.sha256(binary.read_bytes()).hexdigest(), "checks": ["4000-byte question with bounded character-safe title", "private candidate rejected before proposal ledger writes", "memory and workflow matches beyond 500 newer rows", "reviewed proposal remains approval-gated"], "providerCalls": 1, "temporaryFixturesRemoved": True}, ensure_ascii=False))


if __name__ == "__main__":
    main()
