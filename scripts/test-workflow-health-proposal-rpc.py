#!/usr/bin/env python3
"""Frozen-helper RPC regression for one disabled workflow-health timeout candidate.

The fixture owns its store and project. It never calls a provider or a model.
"""
import argparse
import copy
import datetime
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=pathlib.Path, default=ROOT / ".build/debug/vela")
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    output = args.output
    if output.exists() or output.is_symlink():
        parser.error("output must be new; prior evidence is retained")

    receipt = {
        "format": "vela-workflow-health-proposal-rpc-v2", "status": "failed",
        "startedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "providerRuns": 0, "modelRuns": 0,
        "fixtureData": "synthetic workflow, shell timeout, isolated store", "checks": [],
        "allowedCandidateDifferences": [
            "new identity", "title suffix", "enabled=false", "candidate version",
            "regenerated derived content metadata",
            "only timeout-step.arguments.timeoutSeconds changes from 1 to 2",
        ],
        "readOperationsExpectedToMutate": [],
    }
    tmp_root = ROOT / ".task-tmp"
    tmp_root.mkdir(exist_ok=True)
    base = pathlib.Path(tempfile.mkdtemp(prefix="vela-health-proposal-", dir=tmp_root))
    project, home, frozen_helper = base / "project", base / "store", base / "vela"
    try:
        project.mkdir(); home.mkdir()
        source_before = digest(binary)
        shutil.copy2(binary, frozen_helper)
        frozen_before = digest(frozen_helper)
        assert source_before == frozen_before, "Frozen helper does not match the requested helper"
        receipt.update(helperSource=str(binary), helperSourceSHA256Before=source_before,
                       frozenHelperSHA256Before=frozen_before, frozenHelperPath=str(frozen_helper))
        environment = dict(os.environ, VELA_HOME=str(home), VELA_SESSION_ROOT=str(base / "sources"),
                           VELA_DISABLE_DISCOVERY="1", GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)

        def call(method, params):
            result = subprocess.run([str(frozen_helper), "call", method, json.dumps(params), "--home", str(home)],
                                    cwd=project, env=environment, text=True, capture_output=True, timeout=20)
            if result.returncode:
                raise RuntimeError(f"{method}: {result.stderr or result.stdout}")
            return json.loads(result.stdout)

        call("projects.add", {"path": str(project)})
        workflow = call("workflows.save", {
            "id": "timeout-source", "title": "Synthetic timeout source", "project": str(project),
            "enabled": True, "description": "Preserve this source definition exactly.",
            "context": {"version": 1, "template": "Synthetic context: {{fixture}}", "memory": {"enabled": False, "budgetTokens": 0},
                        "inputs": [{"id": "fixture", "value": "literal context must survive clone"}]},
            "steps": [
                {"id": "timeout-step", "title": "Bounded local timeout", "tool": "shell.test",
                 "arguments": {"executable": "/bin/sh", "args": ["-c", "sleep 2"], "timeoutSeconds": 1}},
                {"id": "contextual-agent", "title": "Unreached contextual argv", "tool": "agent.run",
                 "arguments": {"executable": "/usr/bin/true", "args": ["{{vela.prompt}}"], "promptMode": "workflow_context", "timeoutSeconds": 5}},
                {"id": "retry-read", "title": "Unreached retry policy", "tool": "git.status", "arguments": {},
                 "retry": {"maxAttempts": 2, "initialBackoffMs": 50, "maxBackoffMs": 50}},
            ],
        })
        started = call("workflows.run", {"id": workflow["id"], "dryRun": False})
        approval = next(item for item in call("inbox.list", {"project": str(project)}) if item["runId"] == started["id"])
        call("approvals.decide", {"id": approval["id"], "snapshotHash": approval["snapshotHash"], "decision": "approve"})
        run = call("runs.get", {"id": started["id"]})
        assert run["state"] == "needs_review", run
        health = call("workflows.health", {"project": str(project), "id": workflow["id"]})
        finding = next(item for item in health["findings"] if item["code"] == "timeout_observed" and item["runId"] == run["id"])

        # Baseline is after the explicit approval and timeout. Proposal operations
        # must not rewrite these records; all following get/list calls are read-only.
        source_before = call("workflows.get", {"project": str(project), "id": workflow["id"]})
        run_before = call("runs.get", {"id": run["id"]})
        approval_before = next(item for item in call("inbox.list", {"project": str(project)}) if item["id"] == approval["id"])
        source_definition = copy.deepcopy(source_before["definition"])
        before_run_count = len(call("runs.list", {"project": str(project)}))
        before_approval_count = len(call("inbox.list", {"project": str(project)}))

        proposal = call("workflows.health.proposeTimeout", {
            "project": str(project), "workflowId": workflow["id"], "workflowVersion": workflow["version"],
            "snapshotHash": source_before["snapshotHash"], "runId": run["id"], "stepId": finding["stepId"],
            "findingId": finding["id"], "newTimeoutSeconds": 2,
        })
        assert proposal["sourceOutcomeUnknown"] is True
        assert [item["id"] for item in call("workflows.list", {"project": str(project)})] == [workflow["id"]]
        receipt["checks"].append("proposal_only_persists_pending_review_record_before_explicit_accept")

        missing_ack_error = None
        try:
            call("workflows.health.proposal.decide", {
                "project": str(project), "id": proposal["id"], "proposalHash": proposal["proposalHash"],
                "decision": "accept", "acknowledgeUncertainSource": False,
            })
        except RuntimeError as error:
            missing_ack_error = str(error)
        assert missing_ack_error is not None, "Acceptance without acknowledgeUncertainSource=true was not rejected"
        assert "acknowledgeUncertainSource=true" in missing_ack_error, missing_ack_error
        rejected_view = call("workflows.health.proposal.get", {"project": str(project), "id": proposal["id"]})
        assert rejected_view["state"] == "pending_review", rejected_view
        receipt["missingAcknowledgementRejection"] = missing_ack_error
        receipt["checks"].append("uncertain_timeout_acceptance_without_explicit_acknowledgement_is_rejected_and_remains_pending")

        accepted = call("workflows.health.proposal.decide", {
            "project": str(project), "id": proposal["id"], "proposalHash": proposal["proposalHash"],
            "decision": "accept", "acknowledgeUncertainSource": True,
        })
        candidate_view = call("workflows.get", {"project": str(project), "id": accepted["acceptedWorkflowId"]})
        candidate = candidate_view["definition"]
        assert accepted["state"] == "accepted"
        assert candidate["id"] != source_definition["id"]
        assert candidate["title"] == source_definition["title"] + " timeout candidate"
        assert candidate["enabled"] is False and candidate["version"] == 1

        # Compare the complete normalized step list. The only permitted mutation
        # is the named timeout; argv and any retry field participate verbatim.
        expected_steps = copy.deepcopy(source_definition["steps"])
        expected_steps[0]["arguments"]["timeoutSeconds"] = 2
        assert canonical(candidate["steps"]) == canonical(expected_steps), {"expectedSteps": expected_steps, "candidateSteps": candidate["steps"]}
        assert canonical(candidate.get("context")) == canonical(source_definition.get("context"))
        assert canonical(candidate.get("guidelines", [])) == canonical(source_definition.get("guidelines", []))
        for key in ("project", "description", "trigger", "cron", "state", "watch", "pipeline", "output", "markdownBody"):
            assert canonical(candidate.get(key)) == canonical(source_definition.get(key)), key
        receipt["checks"].append("candidate_preserves_full_steps_argv_context_retry_and_definition_fields_except_explicit_identity_title_disabled_version_and_timeout")

        source_after = call("workflows.get", {"project": str(project), "id": workflow["id"]})
        run_after = call("runs.get", {"id": run["id"]})
        approval_after = next(item for item in call("inbox.list", {"project": str(project)}) if item["id"] == approval["id"])
        assert canonical(source_after) == canonical(source_before), "Proposal altered the original workflow view"
        assert canonical(run_after) == canonical(run_before), "Proposal altered the historical run"
        assert canonical(approval_after) == canonical(approval_before), "Proposal altered the original approval"
        assert len(call("runs.list", {"project": str(project)})) == before_run_count
        assert len(call("inbox.list", {"project": str(project)})) == before_approval_count
        receipt["checks"].append("original_workflow_definition_run_and_approval_are_byte_for_byte_unchanged_after_proposal_acceptance")

        source_hash_after, frozen_hash_after = digest(binary), digest(frozen_helper)
        assert source_hash_after == receipt["helperSourceSHA256Before"], "Requested helper changed during the test"
        assert frozen_hash_after == receipt["frozenHelperSHA256Before"], "Frozen helper changed during the test"
        receipt.update(sourceOutcomeUnknown=True, originalWorkflowUnchanged=True, originalRunUnchanged=True,
                       originalApprovalUnchanged=True, candidateDisabled=True, candidateTimeoutSeconds=2,
                       runCountUnchanged=True, approvalCountUnchanged=True, helperSourceSHA256After=source_hash_after,
                       frozenHelperSHA256After=frozen_hash_after, helperSourceUnchanged=True,
                       frozenHelperUnchanged=True, status="passed")
    except Exception as error:
        receipt["error"] = str(error)
    finally:
        shutil.rmtree(base, ignore_errors=True)
        receipt["ownedFixtureRemoved"] = not base.exists()
        receipt["finishedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        output.mkdir(parents=True)
        (output / "results.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
        print(json.dumps(receipt, ensure_ascii=False))
    if receipt["status"] != "passed":
        raise SystemExit(1)

if __name__ == "__main__":
    main()
