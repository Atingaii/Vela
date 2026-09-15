#!/usr/bin/env python3
"""Actual synthetic workflow-context loop regression for ingestion exclusion gates."""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import tempfile
import threading
import time


ROOT = Path(__file__).resolve().parents[1]


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_hashes(root):
    return {str(path.relative_to(root)): sha256(path) for path in sorted((root / "Sources").rglob("*.swift"))}


def close(proc):
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / ".build/arm64-apple-macosx/debug/vela")
    parser.add_argument("--source-root", type=Path, default=ROOT)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    source_root = args.source_root.resolve(strict=True)
    output = args.output.resolve()
    raw_output = output.with_suffix(".rpc.json")
    if output.exists() or output.is_symlink() or raw_output.exists() or raw_output.is_symlink():
        parser.error("Choose new JSON and .rpc.json paths; evidence is never overwritten.")
    if not (source_root / "Sources").is_dir():
        parser.error("source root lacks Sources/")
    output.parent.mkdir(parents=True, exist_ok=True)
    (ROOT / ".task-tmp").mkdir(parents=True, exist_ok=True)
    result = {
        "format": "vela-ingestion-loop-guard-rpc-v1", "status": "failed",
        "startedAt": dt.datetime.now(dt.timezone.utc).isoformat(), "synthetic": True,
        "providerRuns": 0, "modelDownloads": 0, "helperSHA256": sha256(binary),
        "helperOriginalSHA256Before": sha256(binary), "sourceRoot": str(source_root),
        "sourceBefore": source_hashes(source_root), "consumerSHA256Before": sha256(Path(__file__)),
        "cases": [], "transcript": [],
        "secondRoundRevocation": {"tested": False, "reason": "This bounded receipt only proves the initial frozen workflow-context loop gate."},
    }

    def run_case(mode):
        base = Path(tempfile.mkdtemp(prefix="ingestion-loop-guard-", dir=ROOT / ".task-tmp")).resolve()
        rpc = None
        case = {"ruleMode": mode, "fixture": str(base), "checks": [], "status": "failed"}

        def check(name, passed, **detail):
            case["checks"].append({"name": name, "passed": bool(passed), **detail})

        try:
            helper = base / "vela"
            shutil.copy2(binary, helper)
            project, logs, home = base / "project", base / "logs", base / "home"
            for directory in (project, logs / "codex", home):
                directory.mkdir(parents=True)
            env = dict(os.environ, HOME=str(base), VELA_HOME=str(home), VELA_SESSION_ROOT=str(logs),
                       VELA_DISABLE_DISCOVERY="1", GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
            rpc = subprocess.Popen([str(helper), "rpc", "--no-watch", "--no-schedule"], cwd=project, env=env,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
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
                result["transcript"].append({"ruleMode": mode, "request": request, "response": response})
                if response.get("id") != serial or "error" in response:
                    raise RuntimeError(method + ": " + json.dumps(response))
                return response["result"]

            call("projects.add", {"path": str(project)})
            stamp = "2026-09-14T00:00:00Z"
            log = logs / "codex" / "loop-guard.jsonl"
            log.write_text("\n".join(json.dumps(row) for row in [
                {"type": "session_meta", "timestamp": stamp, "payload": {"id": "loop-guard", "cwd": str(project)}},
                {"type": "response_item", "timestamp": stamp, "payload": {"id": "loop-guard-message", "type": "message", "role": "user", "content": [{"type": "input_text", "text": "LOOP_GUARD_MEMORY_MARKER"}]}},
            ]) + "\n")
            log_before = sha256(log)
            call("sessions.refresh")
            session = next(item for item in call("sessions.list", {"project": str(project)}) if item.get("sourceSessionId") == "loop-guard")
            message_id = call("sessions.get", {"id": session["id"]})["messages"][0]["id"]
            capture_fields = {"project": str(project), "sessionId": session["id"], "messageId": message_id}
            prepared = call("memory.capture.prepare", capture_fields)
            memory = call("memory.capture", dict(capture_fields, sourceIdentity=prepared["sourceIdentity"], expectedSourceHash=prepared["expectedSourceHash"]))
            memory_id = call("memory.transition", {"id": memory["id"], "state": "active"})["id"]
            asset = Path(memory["assetPath"])
            asset_before = sha256(asset)
            check("active-capture-is-managed-before-rule", memory_id in {row["id"] for row in call("memory.list", {"project": str(project)})}, memoryID=memory_id)

            def loop_agent(name):
                marker = base / (name + ".count")
                program = base / (name + ".sh")
                event = json.dumps({"type": "item.completed", "item": {"id": "final", "type": "agent_message", "text": json.dumps({"decision": {"kind": "final", "answer": "synthetic loop completed"}})}})
                program.write_text("#!/bin/sh\ncount=0\n[ ! -f " + repr(str(marker)) + " ] || count=$(cat " + repr(str(marker)) + ")\ncount=$((count+1))\nprintf '%s' \"$count\" > " + repr(str(marker)) + "\nprintf '%s\\n' '" + json.dumps({"type": "thread.started", "thread_id": "synthetic-loop"}) + "'\nprintf '%s\\n' '" + event.replace("'", "'\\''") + "'\nprintf '%s\\n' '" + json.dumps({"type": "turn.completed", "usage": {"input_tokens": 1, "output_tokens": 1}}) + "'\n")
                program.chmod(0o700)
                return program, marker

            def make_workflow(name, agent):
                arguments = {"prompt": "{{vela.prompt}}", "promptMode": "workflow_context",
                             "agent": {"executable": str(agent), "model": "synthetic", "reasoningEffort": "low"},
                             "tools": ["memory.recall"], "limits": {"maxModelCalls": 1, "timeoutSeconds": 10, "totalTimeoutSeconds": 20}}
                return call("workflows.save", {"project": str(project), "title": name,
                    "context": {"version": 1, "template": "LOOP_GUARD_MEMORY_MARKER {{memory}}", "memory": {"enabled": True, "budgetTokens": 1000}},
                    "steps": [{"tool": "agent.loop", "arguments": arguments}]})

            def approval_of(run):
                approval_id = next(step.get("approvalId") for step in run.get("steps", []) if step.get("approvalId"))
                return next(item for item in call("dashboard.get", {"project": str(project)}).get("approvals", []) if item["id"] == approval_id)

            control_agent, control_marker = loop_agent("control-loop")
            control_workflow = make_workflow("control loop", control_agent)
            control_run = call("workflows.run", {"id": control_workflow["id"], "dryRun": False})
            control_approval = approval_of(control_run)
            control_decision = call("approvals.decide", {"id": control_approval["id"], "decision": "approve", "snapshotHash": control_approval["snapshotHash"]})
            loops = call("loops.list", {"project": str(project)})
            control_loop = call("loops.get", {"project": str(project), "id": loops[-1]["id"]})
            check("control-workflow-context-loop-executes", control_decision.get("state") == "executed" and control_marker.exists() and control_marker.read_text() == "1" and control_loop.get("state") == "completed" and control_loop.get("output") == "synthetic loop completed",
                  approvalState=control_decision.get("state"), marker=control_marker.read_text() if control_marker.exists() else "0", loopState=control_loop.get("state"))

            frozen_agent, frozen_marker = loop_agent("frozen-loop")
            frozen_workflow = make_workflow("frozen loop", frozen_agent)
            frozen_run = call("workflows.run", {"id": frozen_workflow["id"], "dryRun": False})
            frozen_approval = approval_of(frozen_run)
            check("workflow-context-memory-is-frozen-before-rule", frozen_run.get("state") == "pending_approval", runState=frozen_run.get("state"))
            rule_params = {"project": str(project)}
            if mode == "source":
                rule_params.update({"provider": "codex", "pathGlob": "loop-guard.jsonl"})
            rule = call("ingestion.exclusions.upsert", rule_params)
            frozen_decision = call("approvals.decide", {"id": frozen_approval["id"], "decision": "approve", "snapshotHash": frozen_approval["snapshotHash"]})
            check("frozen-workflow-context-loop-gate-rejects-before-agent", frozen_decision.get("state") == "failed" and not frozen_marker.exists(),
                  approvalState=frozen_decision.get("state"), marker=frozen_marker.read_text() if frozen_marker.exists() else "0", ruleID=rule["id"])
            check("management-memory-remains-after-consumer-rule", memory_id in {row["id"] for row in call("memory.list", {"project": str(project)})}, memoryID=memory_id)
            case["status"] = "passed" if all(item["passed"] for item in case["checks"]) else "failed"
        except Exception as error:
            case["failure"] = type(error).__name__ + ": " + str(error)
        finally:
            case["rpcStopped"] = close(rpc)
            case["helperCopyUnchanged"] = "helper" not in locals() or sha256(helper) == sha256(binary)
            case["logUnchanged"] = "log" in locals() and log.exists() and sha256(log) == log_before
            case["memoryAssetUnchanged"] = "asset" in locals() and asset.exists() and sha256(asset) == asset_before
            if not all([case["rpcStopped"], case["helperCopyUnchanged"], case["logUnchanged"], case["memoryAssetUnchanged"]]):
                case["status"] = "failed"
            shutil.rmtree(base, ignore_errors=True)
            case["fixtureRemoved"] = not base.exists()
            if not case["fixtureRemoved"]:
                case["status"] = "failed"
        return case

    def run_revocation_case(control):
        """Barrier the second model process, then mutate policy from another helper."""
        base = Path(tempfile.mkdtemp(prefix="ingestion-loop-revoke-", dir=ROOT / ".task-tmp")).resolve()
        case = {"name": "multiround-control" if control else "multiround-source-revocation", "checks": [], "status": "failed"}
        def check(name, passed, **detail): case["checks"].append({"name": name, "passed": bool(passed), **detail})
        try:
            helper, project, logs, home = base / "vela", base / "project", base / "logs", base / "home"
            shutil.copy2(binary, helper)
            for directory in (project, logs / "codex", home): directory.mkdir(parents=True)
            env = dict(os.environ, HOME=str(base), VELA_HOME=str(home), VELA_SESSION_ROOT=str(logs), VELA_DISABLE_DISCOVERY="1", GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
            def call(method, params, timeout=35):
                completed = subprocess.run([str(helper), "call", method, "--params-stdin", "--home", str(home)], input=json.dumps(params), cwd=project, env=env, text=True, capture_output=True, timeout=timeout)
                if completed.returncode: raise RuntimeError(method + ": " + completed.stderr)
                return json.loads(completed.stdout)
            call("projects.add", {"path": str(project)})
            log = logs / "codex" / "revoke.jsonl"; stamp = "2026-09-14T00:00:00Z"
            log.write_text(json.dumps({"type":"session_meta","timestamp":stamp,"payload":{"id":"revoke","cwd":str(project)}}) + "\n" + json.dumps({"type":"response_item","timestamp":stamp,"payload":{"id":"msg","type":"message","role":"user","content":[{"type":"input_text","text":"LOOP_REVOKE_SENTINEL"}]}}) + "\n")
            call("sessions.refresh", {}); session = next(x for x in call("sessions.list", {"project":str(project)}) if x.get("sourceSessionId") == "revoke")
            mid = call("sessions.get", {"id":session["id"]})["messages"][0]["id"]; fields={"project":str(project),"sessionId":session["id"],"messageId":mid}
            prep=call("memory.capture.prepare",fields); memory=call("memory.capture",dict(fields,sourceIdentity=prep["sourceIdentity"],expectedSourceHash=prep["expectedSourceHash"])); memory_id=call("memory.transition", {"id":memory["id"],"state":"active"})["id"]
            ready, release, marker = base / "ready", base / "release", base / "calls"
            agent = base / "agent.sh"
            event = lambda decision: json.dumps({"type":"item.completed","item":{"id":"answer","type":"agent_message","text":json.dumps({"decision":decision})}})
            started = json.dumps({"type":"thread.started","thread_id":"multiround"})
            agent.write_text("#!/bin/sh\ncount=0\n[ ! -f " + repr(str(marker)) + " ] || count=$(cat " + repr(str(marker)) + ")\ncount=$((count+1)); printf '%s' \"$count\" > " + repr(str(marker)) + "\nprintf '%s\\0' \"$@\" > " + repr(str(base / "argv.")) + "\"$count\"\nprintf '%s\\n' '" + started + "'\ncase $count in\n1) printf '%s\\n' '" + event({"kind":"tool","toolId":"memory.recall","arguments":{"query":"LOOP_REVOKE_SENTINEL","budgetTokens":1000}}).replace("'","'\\''") + "' ;;\n2) touch " + repr(str(ready)) + "; deadline=$(( $(date +%s) + 30 )); while [ ! -f " + repr(str(release)) + " ] && [ $(date +%s) -lt $deadline ]; do sleep 1; done; printf '%s\\n' '" + event({"kind":"tool","toolId":"git.status","arguments":{}}).replace("'","'\\''") + "' ;;\n3) printf '%s\\n' '" + event({"kind":"final","answer":"multiround complete"}).replace("'","'\\''") + "' ;;\nesac\nprintf '%s\\n' '" + json.dumps({"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}) + "'\n")
            agent.chmod(0o700)
            planned=call("loops.plan", {"project":str(project),"prompt":"LOOP_REVOKE_SENTINEL","agent":{"executable":str(agent),"model":"synthetic","reasoningEffort":"low"},"tools":["memory.recall","git.status"],"limits":{"maxModelCalls":3,"timeoutSeconds":30,"totalTimeoutSeconds":90}})
            approval=planned["approval"]; decision={}
            def approve():
                try: decision["value"]=call("approvals.decide", {"id":approval["id"],"decision":"approve","snapshotHash":approval["snapshotHash"]}, timeout=100)
                except Exception as error: decision["error"]=str(error)
            worker=threading.Thread(target=approve); worker.start(); deadline=time.monotonic()+15
            while not ready.exists() and time.monotonic()<deadline: time.sleep(.02)
            check("second-provider-reached-deterministic-barrier", ready.exists(), marker=marker.read_text() if marker.exists() else "0")
            if not control and ready.exists(): call("ingestion.exclusions.upsert", {"project":str(project),"provider":"codex","pathGlob":"revoke.jsonl"})
            release.touch(); worker.join(40)
            loop=call("loops.get", {"project":str(project),"id":planned["id"]})
            calls=marker.read_text() if marker.exists() else "0"; first=(base / "argv.1").read_text(errors="replace") if (base / "argv.1").exists() else ""; second=(base / "argv.2").read_text(errors="replace") if (base / "argv.2").exists() else ""
            check("recalled-memory-reaches-history-before-policy-change", "LOOP_REVOKE_SENTINEL" in first and "LOOP_REVOKE_SENTINEL" in second, firstPrompt=first, secondPrompt=second)
            expected_calls, expected_state = ("3", "completed") if control else ("2", "needs_review")
            check("control-completes-or-revocation-stops-third-provider", calls == expected_calls and loop.get("state") == expected_state, marker=calls, loopState=loop.get("state"), approvalState=decision.get("value",{}).get("state"), approvalError=decision.get("error"))
            case["status"]="passed" if all(x["passed"] for x in case["checks"]) else "failed"
        except Exception as error: case["failure"]=type(error).__name__+": "+str(error)
        finally:
            shutil.rmtree(base, ignore_errors=True); case["fixtureRemoved"]=not base.exists()
            if not case["fixtureRemoved"]: case["status"]="failed"
        return case

    for mode in ("source", "whole"):
        result["cases"].append(run_case(mode))
    result["cases"].extend([run_revocation_case(True), run_revocation_case(False)])
    result["secondRoundRevocation"] = {
        "tested": True,
        "method": "The second synthetic provider blocks on an owned release file; a separate same-env helper writes the source rule before release.",
    }
    result["sourceAfter"] = source_hashes(source_root)
    result["consumerSHA256After"] = sha256(Path(__file__))
    result["helperOriginalSHA256After"] = sha256(binary)
    result["sourceUnchanged"] = result["sourceBefore"] == result["sourceAfter"]
    result["consumerUnchanged"] = result["consumerSHA256Before"] == result["consumerSHA256After"]
    result["helperOriginalUnchanged"] = result["helperOriginalSHA256Before"] == result["helperOriginalSHA256After"]
    result["status"] = "passed" if all(case["status"] == "passed" for case in result["cases"]) and result["sourceUnchanged"] and result["consumerUnchanged"] and result["helperOriginalUnchanged"] else "failed"
    result["finishedAt"] = dt.datetime.now(dt.timezone.utc).isoformat()
    raw_output.write_text(json.dumps(result.pop("transcript"), ensure_ascii=False, indent=2) + "\n")
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
