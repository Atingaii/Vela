#!/usr/bin/env python3
"""Actual synthetic-helper regression for exclusion gates in MCP, Ask, and workflow consumers."""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_hashes(root):
    sources = root / "Sources"
    return {str(path.relative_to(root)): digest(path) for path in sorted(sources.rglob("*.swift"))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / ".build/arm64-apple-macosx/debug/vela")
    parser.add_argument("--source-root", type=Path, default=ROOT)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--rule-mode", choices=["source", "whole", "both"], default="both",
                        help="Run source and whole-project rules in separate owned fixtures (or one selected mode).")
    args = parser.parse_args()
    binary, source_root, output = args.binary.resolve(strict=True), args.source_root.resolve(strict=True), args.output.resolve()
    raw_output = output.with_suffix(".rpc.json")
    if output.exists() or output.is_symlink() or raw_output.exists() or raw_output.is_symlink():
        parser.error("Choose new JSON and .rpc.json paths; evidence is never overwritten.")
    if not (source_root / "Sources").is_dir():
        parser.error("source root lacks Sources/")
    output.parent.mkdir(parents=True, exist_ok=True)
    (ROOT / ".task-tmp").mkdir(parents=True, exist_ok=True)
    if args.rule_mode == "both":
        aggregate = {
            "format": "vela-ingestion-consumer-guards-rpc-v1",
            "status": "failed",
            "startedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
            "synthetic": True, "providerRuns": 0, "modelDownloads": 0,
            "ruleMode": "both", "fixtureIsolatedPerRuleMode": True,
            "helperSHA256": digest(binary), "helperOriginalSHA256Before": digest(binary), "sourceRoot": str(source_root),
            "sourceBefore": source_hashes(source_root), "consumerSHA256Before": digest(Path(__file__)),
        }
        children = []
        for mode in ("source", "whole"):
            child_output = output.with_name(output.stem + "-" + mode + output.suffix)
            command = [sys.executable, str(Path(__file__).resolve()), "--binary", str(binary), "--source-root", str(source_root), "--output", str(child_output), "--rule-mode", mode]
            stdout_log = child_output.with_suffix(".stdout.log")
            stderr_log = child_output.with_suffix(".stderr.log")
            child_targets = (child_output, child_output.with_suffix(".rpc.json"), stdout_log, stderr_log)
            if any(path.exists() or path.is_symlink() for path in child_targets):
                children.append({
                    "ruleMode": mode, "output": str(child_output), "receiptSHA256": None,
                    "rawTranscript": str(child_output.with_suffix(".rpc.json")), "rawTranscriptSHA256": None,
                    "stdoutLog": str(stdout_log), "stderrLog": str(stderr_log), "exitCode": None,
                    "failure": "child evidence target already exists",
                })
                continue
            child = subprocess.Popen(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            partial_cleanup = False
            try:
                stdout, stderr = child.communicate(timeout=120)
                exit_code = child.returncode
                failure = None if exit_code == 0 else "child exit " + str(exit_code)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    stdout, stderr = child.communicate(timeout=15)
                    exit_code = child.returncode
                    failure = "child deadline exceeded (120s); terminated after cleanup window"
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    stdout, stderr = child.communicate()
                    exit_code = child.returncode
                    partial_cleanup = True
                    failure = "child deadline exceeded (120s); killed after 15s cleanup window"
            if isinstance(stdout, bytes):
                stdout = stdout.decode("utf-8", errors="replace")
            if isinstance(stderr, bytes):
                stderr = stderr.decode("utf-8", errors="replace")
            stdout_log.write_text(stdout)
            stderr_log.write_text(stderr)
            receipt = None
            if child_output.is_file():
                try:
                    receipt = json.loads(child_output.read_text())
                except (OSError, json.JSONDecodeError):
                    partial_cleanup = True
            cleanup_reported = bool(receipt and receipt.get("fixtureRemoved") and receipt.get("rpcStopped") and receipt.get("mcpStopped"))
            if failure is not None and not cleanup_reported:
                partial_cleanup = True
            children.append({
                "ruleMode": mode, "output": str(child_output), "receiptSHA256": digest(child_output) if child_output.is_file() else None,
                "rawTranscript": str(child_output.with_suffix(".rpc.json")), "rawTranscriptSHA256": digest(child_output.with_suffix(".rpc.json")) if child_output.with_suffix(".rpc.json").is_file() else None,
                "stdoutLog": str(stdout_log), "stderrLog": str(stderr_log), "exitCode": exit_code,
                "failure": failure, "cleanupReported": cleanup_reported, "partialCleanupPossible": partial_cleanup,
            })
        aggregate["children"] = children
        aggregate["status"] = "passed" if all(item["exitCode"] == 0 for item in children) else "failed"
        aggregate["sourceAfter"] = source_hashes(source_root)
        aggregate["consumerSHA256After"] = digest(Path(__file__))
        aggregate["helperOriginalSHA256After"] = digest(binary)
        aggregate["sourceUnchanged"] = aggregate["sourceBefore"] == aggregate["sourceAfter"]
        aggregate["consumerUnchanged"] = aggregate["consumerSHA256Before"] == aggregate["consumerSHA256After"]
        aggregate["helperOriginalUnchanged"] = aggregate["helperOriginalSHA256Before"] == aggregate["helperOriginalSHA256After"]
        if not aggregate["sourceUnchanged"] or not aggregate["consumerUnchanged"] or not aggregate["helperOriginalUnchanged"]:
            aggregate["status"] = "failed"
        aggregate["finishedAt"] = dt.datetime.now(dt.timezone.utc).isoformat()
        raw_output.write_text("[]\n")
        output.write_text(json.dumps(aggregate, ensure_ascii=False, indent=2) + "\n")
        print(json.dumps(aggregate, ensure_ascii=False, indent=2))
        return 0 if aggregate["status"] == "passed" else 1
    base = Path(tempfile.mkdtemp(prefix="ingestion-consumer-guards-", dir=ROOT / ".task-tmp")).resolve()
    result = {
        "format": "vela-ingestion-consumer-guards-rpc-v1",
        "status": "failed",
        "startedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "synthetic": True,
        "providerRuns": 0,
        "modelDownloads": 0,
        "helperSHA256": digest(binary),
        "helperOriginalSHA256Before": digest(binary),
        "sourceRoot": str(source_root),
        "sourceBefore": source_hashes(source_root),
        "consumerSHA256Before": digest(Path(__file__)),
        "checks": [],
        "transcript": [],
        "ruleMode": args.rule_mode,
    }
    rpc = None
    mcp = None

    def record(name, passed, **detail):
        result["checks"].append({"name": name, "passed": bool(passed), **detail})
        if not passed:
            result.setdefault("failures", []).append(name + ": " + str(detail.get("actual", detail.get("error", "assertion failed"))))

    def close_proc(proc):
        if proc is None:
            return True
        if proc.poll() is None:
            if proc.stdin and not proc.stdin.closed:
                proc.stdin.close()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)
        return proc.poll() is not None

    def interrupted(signum, _frame):
        raise RuntimeError("interrupted by signal " + str(signum))

    # The both-mode parent terminates this child process group on deadline.  Raising
    # here keeps the owned helper and fixture on the normal finally cleanup path.
    if args.rule_mode != "both":
        signal.signal(signal.SIGTERM, interrupted)

    try:
        helper = base / "vela"
        shutil.copy2(binary, helper)
        project, logs, home = base / "project", base / "logs", base / "home"
        for path in (project, logs / "codex", home):
            path.mkdir(parents=True)
        marker_dir = base / "markers"
        marker_dir.mkdir()
        env = dict(os.environ, HOME=str(base), VELA_HOME=str(home), VELA_SESSION_ROOT=str(logs),
                   VELA_DISABLE_DISCOVERY="1", GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")

        def start_rpc():
            return subprocess.Popen([str(helper), "rpc", "--no-watch", "--no-schedule"], cwd=project, env=env,
                                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

        rpc = start_rpc()
        serial = 0
        def call(method, params=None):
            nonlocal serial
            serial += 1
            request = {"id": serial, "method": method, "params": params or {}}
            rpc.stdin.write(json.dumps(request) + "\n")
            rpc.stdin.flush()
            if not select.select([rpc.stdout], [], [], 30)[0]:
                raise RuntimeError("RPC deadline: " + method)
            response = json.loads(rpc.stdout.readline())
            result["transcript"].append({"transport": "rpc", "request": request, "response": response})
            if response.get("id") != serial or "error" in response:
                raise RuntimeError(method + ": " + json.dumps(response))
            return response["result"]

        call("projects.add", {"path": str(project)})
        stamp = "2026-09-14T00:00:00Z"
        rows = [
            {"type":"session_meta", "timestamp":stamp, "payload":{"id":"consumer-guard-session","cwd":str(project)}},
            {"type":"response_item", "timestamp":stamp, "payload":{"id":"consumer-guard-message","type":"message","role":"user","content":[{"type":"input_text","text":"GUARD_CAPTURE_MARKER Harbor policy"}]}},
        ]
        log = logs / "codex" / "guard.jsonl"
        log.write_text("".join(json.dumps(row) + "\n" for row in rows))
        logSHA256Before = digest(log)
        call("sessions.refresh")
        sessions = call("sessions.list", {"project": str(project)})
        session = next(row for row in sessions if row.get("sourceSessionId") == "consumer-guard-session")
        message_id = call("sessions.get", {"id": session["id"]})["messages"][0]["id"]
        fields = {"project":str(project), "sessionId":session["id"], "messageId":message_id}
        prepared = call("memory.capture.prepare", fields)
        captured = call("memory.capture", dict(fields, sourceIdentity=prepared["sourceIdentity"], expectedSourceHash=prepared["expectedSourceHash"]))
        captured_id = call("memory.transition", {"id":captured["id"], "state":"active"})["id"]
        assetPath = Path(captured["assetPath"])
        assetSHA256Before = digest(assetPath)
        managed = {row["id"] for row in call("memory.list", {"project":str(project)})}
        record("fixture-captures-core-observed-memory", captured_id in managed,
               capturedID=captured_id, source=captured["provenance"].get("ingestionSource"))

        def executable(name, mode):
            path = base / (name + ".sh")
            marker = marker_dir / (name + ".count")
            if mode == "ask":
                output_line = json.dumps({"type":"item.completed","item":{"id":"answer","type":"agent_message","text":json.dumps({"claims":[{"text":"synthetic","citations":[{"sourceId":"memory:" + captured_id,"quote":"GUARD_CAPTURE_MARKER"}]}],"unanswered":[]})}})
            else:
                output_line = json.dumps({"type":"item.completed","item":{"id":"route","type":"agent_message","text":json.dumps({"kind":"knowledge_query","targetId":"memory:" + captured_id,"reason":"synthetic"})}})
            script = "#!/bin/sh\ncount=0\n[ ! -f " + repr(str(marker)) + " ] || count=$(cat " + repr(str(marker)) + ")\ncount=$((count+1))\nprintf '%s' \"$count\" > " + repr(str(marker)) + "\nprintf '%s\\n' '" + json.dumps({"type":"thread.started","thread_id":"synthetic"}) + "'\nprintf '%s\\n' '" + output_line.replace("'", "'\\''") + "'\nprintf '%s\\n' '" + json.dumps({"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}) + "'\n"
            path.write_text(script)
            path.chmod(0o700)
            return path, marker

        ask_bin, ask_marker = executable("ask-agent", "ask")
        route_bin, route_marker = executable("route-agent", "route")
        workflow_marker = marker_dir / "workflow.count"
        workflow_bin = base / "workflow-agent.sh"
        workflow_bin.write_text("#!/bin/sh\ncount=0\n[ ! -f " + repr(str(workflow_marker)) + " ] || count=$(cat " + repr(str(workflow_marker)) + ")\ncount=$((count+1))\nprintf '%s' \"$count\" > " + repr(str(workflow_marker)) + "\nprintf '%s' \"$1\"\n")
        workflow_bin.chmod(0o700)

        def approval_of(item):
            if "approval" in item:
                return item["approval"]
            approval_id = item.get("approvalId")
            if approval_id is None:
                approval_id = next((step.get("approvalId") for step in item.get("steps", []) if step.get("approvalId")), None)
            if approval_id is None:
                raise RuntimeError("pending item has no approval identity")
            approvals = call("dashboard.get", {"project":str(project)}).get("approvals", [])
            return next(row for row in approvals if row.get("id") == approval_id)

        control = call("ask.create", {"project":str(project), "question":"GUARD_CAPTURE_MARKER", "searchQuery":"GUARD_CAPTURE_MARKER",
                                      "executable":str(ask_bin), "model":"synthetic", "effort":"low"})
        control_approval = approval_of(control)
        control_decision = call("approvals.decide", {"id":control_approval["id"], "decision":"approve", "snapshotHash":control_approval["snapshotHash"]})
        record("control-approved-ask-runs-synthetic-agent", control_decision.get("state") == "executed" and ask_marker.read_text() == "1",
               approvalState=control_decision.get("state"), marker=ask_marker.read_text() if ask_marker.exists() else "0")

        frozen_ask = call("ask.create", {"project":str(project), "question":"GUARD_CAPTURE_MARKER", "searchQuery":"GUARD_CAPTURE_MARKER",
                                         "executable":str(ask_bin), "model":"synthetic", "effort":"low"})
        route = call("ask.route", {"project":str(project), "question":"GUARD_CAPTURE_MARKER"})
        proposal = call("ask.route.propose", {"project":str(project), "id":route["id"], "routeHash":route["routeHash"],
                                              "executable":str(route_bin), "model":"synthetic", "effort":"low"})
        control_workflow = call("workflows.save", {"project":str(project), "title":"control guard workflow",
            "context":{"version":1, "template":"GUARD_CAPTURE_MARKER {{memory}}", "memory":{"enabled":True,"budgetTokens":1000}},
            "steps":[{"tool":"agent.run","arguments":{"executable":str(workflow_bin),"args":["{{vela.prompt}}"],"promptMode":"workflow_context"}}]})
        control_run = call("workflows.run", {"id":control_workflow["id"], "dryRun":False})
        control_workflow_approval = approval_of(control_run)
        control_workflow_decision = call("approvals.decide", {"id":control_workflow_approval["id"],"decision":"approve","snapshotHash":control_workflow_approval["snapshotHash"]})
        record("control-approved-workflow-runs-synthetic-agent", control_workflow_decision.get("state") == "executed" and workflow_marker.exists() and workflow_marker.read_text() == "1",
               approvalState=control_workflow_decision.get("state"), marker=workflow_marker.read_text() if workflow_marker.exists() else "0")
        workflow = call("workflows.save", {"project":str(project), "title":"guard workflow",
            "context":{"version":1, "template":"GUARD_CAPTURE_MARKER {{memory}}", "memory":{"enabled":True,"budgetTokens":1000}},
            "steps":[{"tool":"agent.run","arguments":{"executable":str(workflow_bin),"args":["{{vela.prompt}}"],"promptMode":"workflow_context"}}]})
        frozen_workflow = call("workflows.run", {"id":workflow["id"], "dryRun":False})
        record("pre-rule-freezes-ask-route-and-workflow", frozen_ask.get("state") == "pending_approval" and proposal.get("state") == "pending_approval" and frozen_workflow.get("state") == "pending_approval",
               ask=frozen_ask.get("state"), proposal=proposal.get("state"), workflow=frozen_workflow.get("state"))

        class MCP:
            def __init__(self):
                self.proc = subprocess.Popen([str(helper), "mcp", "--home", str(home), "--no-watch"], env=env,
                                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                self.id = 0
            def req(self, method, params):
                self.id += 1
                payload = {"jsonrpc":"2.0", "id":self.id, "method":method, "params":params}
                self.proc.stdin.write((json.dumps(payload) + "\n").encode()); self.proc.stdin.flush()
                if not select.select([self.proc.stdout], [], [], 20)[0]:
                    raise RuntimeError("MCP deadline " + method)
                value = json.loads(self.proc.stdout.readline())
                result["transcript"].append({"transport":"mcp","request":payload,"response":value})
                return value
            def tool(self, name, **arguments):
                args = {"project":str(project), **arguments}
                reply = self.req("tools/call", {"name":name,"arguments":args})
                body = reply.get("result", {})
                if body.get("isError"):
                    return None, body
                return json.loads(body["content"][0]["text"]), body
            def close(self):
                return close_proc(self.proc)

        mcp = MCP()
        init = mcp.req("initialize", {"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"guard-consumer","version":"1"}})
        if "error" in init:
            raise RuntimeError("MCP init " + json.dumps(init))
        mcp.proc.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n'); mcp.proc.stdin.flush()
        control_list, control_list_meta = mcp.tool("vela_memory_list", limit=100)
        control_get, control_get_meta = mcp.tool("vela_memory_get", id=captured_id)
        record("control-mcp-list-and-get-return-eligible-memory", not control_list_meta.get("isError") and isinstance(control_list, list) and captured_id in {row["id"] for row in control_list} and not control_get_meta.get("isError") and control_get is not None,
               listError=control_list_meta.get("isError"), getError=control_get_meta.get("isError"))
        rule_params = {"project":str(project)}
        if args.rule_mode == "source":
            rule_params.update({"provider":"codex", "pathGlob":"guard.jsonl"})
        rule = call("ingestion.exclusions.upsert", rule_params)
        record("management-memory-list-retains-excluded-canonical-record", captured_id in {row["id"] for row in call("memory.list", {"project":str(project)})},
               ruleID=rule["id"], ruleMode=args.rule_mode)
        listed, list_meta = mcp.tool("vela_memory_list", limit=100)
        got, get_meta = mcp.tool("vela_memory_get", id=captured_id)
        searched, search_meta = mcp.tool("vela_search", query="GUARD_CAPTURE_MARKER", limit=100)
        list_ids = {row["id"] for row in listed} if isinstance(listed, list) and not list_meta.get("isError") else {captured_id}
        search_ids = {row["id"] for row in searched} if isinstance(searched, list) and not search_meta.get("isError") else {captured_id}
        record("mcp-list-hides-excluded-memory", not list_meta.get("isError") and captured_id not in list_ids, actual=sorted(list_ids), isError=list_meta.get("isError"))
        record("mcp-get-rejects-excluded-memory", got is None and get_meta.get("isError") is True, actual="returned" if got is not None else "error", isError=get_meta.get("isError"))
        record("mcp-search-hides-excluded-memory", not search_meta.get("isError") and captured_id not in search_ids, actual=sorted(search_ids), isError=search_meta.get("isError"))
        close_proc(mcp.proc); mcp = None

        after_ask = call("ask.create", {"project":str(project), "question":"GUARD_CAPTURE_MARKER", "searchQuery":"GUARD_CAPTURE_MARKER",
                                        "executable":str(ask_bin), "model":"synthetic", "effort":"low"})
        after_route = call("ask.route", {"project":str(project), "question":"GUARD_CAPTURE_MARKER"})
        record("ask-create-after-rule-omits-excluded-memory", after_ask.get("state") == "no_sources",
               actual=after_ask.get("state"), requestSources=len((after_ask.get("request") or {}).get("sources", [])))
        record("ask-route-after-rule-omits-excluded-memory", captured_id not in {row.get("id") for row in after_route.get("candidates", [])},
               actual=after_route.get("candidates", []))

        ask_approval = approval_of(frozen_ask)
        route_approval = approval_of(proposal)
        workflow_approval = approval_of(frozen_workflow)
        ask_decision = call("approvals.decide", {"id":ask_approval["id"],"decision":"approve","snapshotHash":ask_approval["snapshotHash"]})
        route_decision = call("approvals.decide", {"id":route_approval["id"],"decision":"approve","snapshotHash":route_approval["snapshotHash"]})
        workflow_decision = call("approvals.decide", {"id":workflow_approval["id"],"decision":"approve","snapshotHash":workflow_approval["snapshotHash"]})
        record("frozen-ask-rejects-before-synthetic-agent", ask_decision.get("state") == "failed" and (not ask_marker.exists() or ask_marker.read_text() == "1"),
               actual=ask_marker.read_text() if ask_marker.exists() else "0", approvalState=ask_decision.get("state"))
        record("frozen-route-rejects-before-synthetic-agent", route_decision.get("state") == "failed" and not route_marker.exists(),
               actual=route_marker.read_text() if route_marker.exists() else "0", approvalState=route_decision.get("state"))
        record("frozen-workflow-rejects-before-synthetic-agent", workflow_decision.get("state") == "failed" and workflow_marker.exists() and workflow_marker.read_text() == "1",
               actual=workflow_marker.read_text() if workflow_marker.exists() else "0", approvalState=workflow_decision.get("state"))

        result["status"] = "passed" if all(item["passed"] for item in result["checks"]) else "failed"
    except Exception as error:
        result["failure"] = type(error).__name__ + ": " + str(error)
    finally:
        result["rpcStopped"] = close_proc(rpc)
        result["mcpStopped"] = close_proc(mcp.proc if mcp is not None else None)
        result["sourceAfter"] = source_hashes(source_root)
        result["consumerSHA256After"] = digest(Path(__file__))
        result["sourceUnchanged"] = result["sourceBefore"] == result["sourceAfter"]
        result["consumerUnchanged"] = result["consumerSHA256Before"] == result["consumerSHA256After"]
        result["helperCopyUnchanged"] = ("helper" not in locals()) or digest(helper) == result["helperSHA256"]
        result["helperOriginalSHA256After"] = digest(binary)
        result["helperOriginalUnchanged"] = result["helperOriginalSHA256Before"] == result["helperOriginalSHA256After"]
        result["logSHA256Before"] = locals().get("logSHA256Before")
        result["logSHA256After"] = digest(log) if "log" in locals() and log.exists() else None
        result["logUnchanged"] = result["logSHA256Before"] == result["logSHA256After"]
        result["memoryAssetSHA256Before"] = locals().get("assetSHA256Before")
        result["memoryAssetSHA256After"] = digest(assetPath) if "assetPath" in locals() and assetPath.exists() else None
        result["memoryAssetUnchanged"] = result["memoryAssetSHA256Before"] == result["memoryAssetSHA256After"]
        if not all([result["rpcStopped"], result["mcpStopped"], result["sourceUnchanged"], result["consumerUnchanged"], result["helperCopyUnchanged"], result["helperOriginalUnchanged"], result["logUnchanged"], result["memoryAssetUnchanged"]]):
            result["status"] = "failed"
        result["finishedAt"] = dt.datetime.now(dt.timezone.utc).isoformat()
        raw_output.write_text(json.dumps(result.pop("transcript"), ensure_ascii=False, indent=2) + "\n")
        shutil.rmtree(base, ignore_errors=True)
        result["fixtureRemoved"] = not base.exists()
        if not result["fixtureRemoved"]:
            result["status"] = "failed"
        output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["status"] == "passed" else 1

if __name__ == "__main__":
    raise SystemExit(main())
