#!/usr/bin/env python3
"""离线核验 Golden 收据关联；绝不调用 helper、provider 或写入 Vela store。"""
import argparse
import copy
import hashlib
import json
import os
import re
import stat
import tempfile
from pathlib import Path
from typing import Any

MAX = 16 * 1024 * 1024
IDENT = re.compile(r"^[A-Za-z0-9_.:-]{1,256}$")
HASH = re.compile(r"^[0-9a-f]{64}$")


def reject_symlink_components(raw: Path, label: str) -> None:
    """Reject any existing symlink before resolution or opening a descendant."""
    current = Path(raw.anchor)
    for component in raw.parts[1:]:
        current /= component
        if current.is_symlink():
            raise ValueError(f"{label} 路径含符号链接：{current.name}")


def regular_path(path: Path, label: str = "收据") -> Path:
    """Reject a symlink at any component; never resolve before the policy check."""
    try:
        raw = Path(os.path.abspath(os.fspath(path)))
        reject_symlink_components(raw, label)
        info = raw.lstat()
        if not stat.S_ISREG(info.st_mode):
            raise ValueError(f"{label} 必须是普通文件：{raw.name}")
        return raw
    except ValueError:
        raise
    except OSError as exc:
        raise ValueError(f"{label} 不可读取：{Path(path).name}") from exc


def output_path(path: Path) -> Path:
    """Validate output before try/except; unsafe targets receive no receipt."""
    try:
        raw = Path(os.path.abspath(os.fspath(path)))
        if raw.suffix != ".json" or raw.exists() or raw.is_symlink():
            raise ValueError("--output 必须是新的普通 .json 文件")
        reject_symlink_components(raw.parent, "--output 父路径")
        parent = raw.parent.lstat()
        if not stat.S_ISDIR(parent.st_mode):
            raise ValueError("--output 父路径必须是既有普通目录")
        return raw
    except ValueError:
        raise
    except OSError as exc:
        raise ValueError("--output 父路径不可用") from exc


def bounded_bytes(path: Path, label: str = "收据") -> tuple[Path, bytes]:
    raw = regular_path(path, label)
    try:
        with raw.open("rb") as handle:
            data = handle.read(MAX + 1)
    except OSError as exc:
        raise ValueError(f"{label} 读取失败：{raw.name}") from exc
    if len(data) > MAX:
        raise ValueError(f"{label} 超过 {MAX} 字节上限：{raw.name}")
    return raw, data


def digest(path: Path) -> str:
    _, data = bounded_bytes(path)
    return hashlib.sha256(data).hexdigest()


def load(path: Path) -> dict[str, Any]:
    raw, data = bounded_bytes(path)
    try:
        result = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"收据不是 UTF-8 JSON：{raw.name}") from exc
    if not isinstance(result, dict):
        raise ValueError(f"收据根必须是对象：{raw.name}")
    return result


def ids(value: Any, label: str) -> set[str]:
    if not isinstance(value, list) or not value or not all(isinstance(x, str) and IDENT.fullmatch(x) for x in value):
        raise ValueError(f"{label} 必须是非空、去重的受限 ID 列表")
    result = set(value)
    if len(result) != len(value):
        raise ValueError(f"{label} 含重复 ID")
    return result


def put(steps: dict[str, Any], name: str, state: str, **detail: Any) -> None:
    steps[name] = {"status": state, **detail}


def source_chain(receipt: dict[str, Any], steps: dict[str, Any], errors: list[str]) -> dict[str, Any] | None:
    try:
        if receipt.get("format") != "vela-golden-live-postverify-v1" or receipt.get("status") != "passed":
            raise ValueError("source 收据不是已通过的 postverify")
        if receipt.get("newProviderRuns") != 0 or receipt.get("manualRefresh") is not False or receipt.get("manualCandidateWrites") is not False:
            raise ValueError("source 收据允许 provider、refresh 或手工 candidate 写入")
        helper = receipt.get("helperSHA256")
        if not isinstance(helper, str) or not HASH.fullmatch(helper):
            raise ValueError("source helperSHA256 无效")
        prior_path = regular_path(Path(str(receipt.get("priorReceipt", ""))), "原始 observe receipt")
        if receipt.get("priorReceiptSHA256") != digest(prior_path):
            raise ValueError("postverify 未 hash 绑定原始 observe receipt")
        prior = load(prior_path)
        if prior.get("manualProviderHistoryWrites") is not False or prior.get("manualMemoryOrSuggestionWrites") is not False:
            raise ValueError("原始 observe receipt 允许手工 provider history 或 Memory/Suggestion 写入")
        turns = prior.get("providerTurns")
        if not isinstance(turns, list) or len(turns) < 3 or not all(isinstance(row, dict) and row.get("exitCode") == 0 for row in turns):
            raise ValueError("原始 observe receipt 缺少完整 provider turn 记录")
        provenance = receipt.get("steps", {}).get("rawProvenance", {})
        rows = provenance.get("fourTurns") if provenance.get("status") == "passed" else None
        if not isinstance(rows, list) or len(rows) < 3:
            raise ValueError("raw provenance 缺少至少三条观察消息")
        pairs, threads = set(), set()
        for row in rows:
            if not isinstance(row, dict):
                raise ValueError("raw provenance 行无效")
            sid, raw, vela, thread = (row.get(k) for k in ("sessionId", "rawMessageId", "velaMessageId", "providerThread"))
            if not all(isinstance(v, str) and IDENT.fullmatch(v) for v in (sid, raw, vela, thread)):
                raise ValueError("source/session/message ID 无效")
            if raw != vela:
                raise ValueError("raw message ID 与 Vela message ID 不同")
            pairs.add((sid, vela)); threads.add(thread)
        if len(pairs) < 3 or len(threads) < 2:
            raise ValueError("未证明三条来源消息跨两个 provider session")
        analyzed = receipt.get("steps", {}).get("improveAnalyze", {})
        if analyzed.get("status") != "passed":
            raise ValueError("自动 Improve 分析未通过")
        candidates = ids(analyzed.get("candidateIds"), "candidateIds")
        suggestions = ids(analyzed.get("suggestionIds"), "suggestionIds")
        if len(suggestions) != 1:
            raise ValueError("最小 Golden 链要求唯一 suggestion")
        links = analyzed.get("exactEvidenceLinks")
        if not isinstance(links, list) or len(links) < len(candidates):
            raise ValueError("candidate/suggestion evidence link 不完整")
        linked = set()
        for link in links:
            if not isinstance(link, dict) or link.get("suggestionId") not in suggestions:
                raise ValueError("evidence link 指向未知 suggestion")
            pair = (link.get("sessionId"), link.get("messageId"))
            if not all(isinstance(v, str) and IDENT.fullmatch(v) for v in pair) or pair not in pairs:
                raise ValueError("evidence link 不在保留的来源消息中")
            linked.add(pair)
        if len(linked) < len(candidates):
            raise ValueError("自动 candidate 缺少各自的来源 evidence")
        put(steps, "sourceToCandidate", "passed", helperSHA256=helper, sourceMessageCount=len(pairs),
            providerSessionCount=len(threads), candidateCount=len(candidates), suggestionId=next(iter(suggestions)), evidenceLinkCount=len(linked))
        return {"helper": helper, "candidates": candidates, "suggestion": next(iter(suggestions))}
    except (TypeError, ValueError) as exc:
        errors.append("sourceToCandidate: " + str(exc)); put(steps, "sourceToCandidate", "failed"); return None


def freeze_chain(receipt: dict[str, Any] | None, source_path: Path, source: dict[str, Any] | None,
                 steps: dict[str, Any], errors: list[str]) -> dict[str, Any] | None:
    if receipt is None:
        put(steps, "candidateToApprovalLab", "not_run", reason="未提供 lab-freeze receipt"); return None
    try:
        if source is None:
            raise ValueError("source chain 失败，不能归因 Lab")
        if receipt.get("format") != "vela-golden-agent-lab-freeze-v1" or receipt.get("status") != "pending_approval_created":
            raise ValueError("lab freeze 不是 pending approval")
        if receipt.get("newProviderRuns") != 0 or receipt.get("approvalDecision") != "not_sent" or receipt.get("sameLiveSessionEvidence") is not True:
            raise ValueError("freeze 运行 provider、决定审批或丢失同源绑定")
        linked_source = regular_path(Path(str(receipt.get("postverifyReceipt", ""))), "freeze 关联的 postverify receipt")
        if linked_source != source_path or receipt.get("postverifySHA256") != digest(source_path):
            raise ValueError("freeze 未 hash 绑定提供的 postverify receipt")
        if receipt.get("helperSHA256") != source["helper"]:
            raise ValueError("freeze helper 与 source helper 不同")
        candidates = ids(receipt.get("candidateMemoryIds"), "freeze candidateMemoryIds")
        if candidates != source["candidates"] or receipt.get("suggestionId") != source["suggestion"]:
            raise ValueError("freeze candidate/suggestion 不等于自动 source chain")
        evaluation = receipt.get("evaluation")
        if not isinstance(evaluation, dict):
            raise ValueError("freeze 未保留 evaluation")
        eid, aid = evaluation.get("id"), evaluation.get("approvalId")
        if not all(isinstance(v, str) and IDENT.fullmatch(v) for v in (eid, aid)):
            raise ValueError("evaluation/approval ID 无效")
        frozen = evaluation.get("candidate", {}).get("memories")
        frozen_ids = ids([item.get("id") for item in frozen] if isinstance(frozen, list) else None, "frozen candidate IDs")
        if frozen_ids != candidates or receipt.get("approvalId") != aid or evaluation.get("sourceSuggestionId") != source["suggestion"] or evaluation.get("state") != "pending_approval":
            raise ValueError("frozen evaluation 中 candidate/approval/suggestion/state 不一致")
        put(steps, "candidateToApprovalLab", "passed", evaluationId=eid, approvalId=aid, candidateCount=len(candidates))
        return {"helper": source["helper"], "candidates": candidates, "suggestion": source["suggestion"], "evaluation": eid, "approval": aid}
    except (TypeError, ValueError) as exc:
        errors.append("candidateToApprovalLab: " + str(exc)); put(steps, "candidateToApprovalLab", "failed"); return None


def terminal_chain(receipt: dict[str, Any] | None, receipt_path: Path | None, freeze_path: Path | None,
                   freeze: dict[str, Any] | None, steps: dict[str, Any], errors: list[str]) -> dict[str, Any] | None:
    if receipt is None:
        put(steps, "approvalToTerminalDecision", "not_run", reason="未提供 lab-execution receipt"); return None
    try:
        if freeze is None or freeze_path is None:
            raise ValueError("execution 缺少有效 frozen approval chain")
        if receipt.get("format") != "vela-golden-agent-lab-execution-v2":
            raise ValueError("execution receipt format 不支持")
        linked_freeze = regular_path(Path(str(receipt.get("freezeReceipt", ""))), "execution 关联的 freeze receipt")
        if linked_freeze != freeze_path or receipt.get("freezeReceiptSHA256") != digest(freeze_path):
            raise ValueError("execution 未 hash 绑定 freeze receipt")
        if receipt.get("helperSHA256") != freeze["helper"] or receipt.get("approvalId") != freeze["approval"] or receipt.get("evaluationId") != freeze["evaluation"]:
            raise ValueError("execution helper 或 approval/evaluation ID 与 freeze 不同")
        if receipt.get("approvalDecision") != "approve" or receipt.get("approvalResponseReceived") is not True:
            raise ValueError("execution 没有可审计的批准响应")
        comparison = receipt.get("comparison")
        if not isinstance(comparison, dict) or comparison.get("state") != "completed" or comparison.get("decision") not in {"reject", "ready_for_review"}:
            raise ValueError("execution 没有已完成的 reject/reviewable comparison")
        planned = receipt.get("plannedProviderRuns")
        if not isinstance(planned, int) or planned <= 0 or receipt.get("newProviderRuns") != planned or receipt.get("recordedProviderResults") != planned:
            raise ValueError("execution provider result 与冻结计划不一致")
        decision = comparison["decision"]
        if decision == "reject" and not (receipt.get("promotionAttempted") is True and receipt.get("promotionRejectedForNonReadyDecision") is True):
            raise ValueError("Reject 未保存为拒绝 promotion attempt")
        put(steps, "approvalToTerminalDecision", "passed", evaluationId=freeze["evaluation"], approvalId=freeze["approval"], decision=decision, providerRuns=planned)
        return {**freeze, "decision": decision}
    except (TypeError, ValueError) as exc:
        errors.append("approvalToTerminalDecision: " + str(exc)); put(steps, "approvalToTerminalDecision", "failed"); return None


def next_session(receipt: dict[str, Any] | None, terminal: dict[str, Any] | None, steps: dict[str, Any], errors: list[str]) -> None:
    if receipt is None:
        put(steps, "nextSessionReceipt", "not_run", reason="无 next-session receipt；不得由 Lab 输出推导 delivery 或 adoption"); return
    try:
        if terminal is None:
            raise ValueError("next-session receipt 没有有效 terminal Lab chain")
        if receipt.get("format") != "vela-golden-next-session-reuse-v1" or receipt.get("status") != "passed":
            raise ValueError("next-session receipt schema/status 无效")
        if receipt.get("sourceEvaluationId") != terminal["evaluation"] or receipt.get("sourceSuggestionId") != terminal["suggestion"]:
            raise ValueError("next-session receipt 未绑定 evaluation/suggestion")
        if ids(receipt.get("candidateMemoryIds"), "next-session candidate IDs") != terminal["candidates"]:
            raise ValueError("next-session candidate set 不同")
        sid, context = receipt.get("providerSessionId"), receipt.get("contextHash")
        if not isinstance(sid, str) or not IDENT.fullmatch(sid) or not isinstance(context, str) or not HASH.fullmatch(context):
            raise ValueError("next-session session/context hash 无效")
        if receipt.get("delivery") != "provided_to_provider_input" or receipt.get("agentAdoption") not in {"observed", "not_measured"}:
            raise ValueError("next-session 必须区分输入 delivery 和 adoption")
        # This only proves self-reported receipt consistency.  A JSON file cannot
        # authenticate provider delivery, model behavior, or Golden completion.
        put(steps, "nextSessionReceipt", "declared_consistent_not_authenticated", providerSessionId=sid,
            agentAdoption=receipt["agentAdoption"], limitation="离线收据校验不能认证 provider 输入交付或模型采纳")
    except (TypeError, ValueError) as exc:
        errors.append("nextSessionReceipt: " + str(exc)); put(steps, "nextSessionReceipt", "failed")


def check(source_path: Path, freeze_path: Path | None, execution_path: Path | None, next_path: Path | None) -> dict[str, Any]:
    source_receipt = load(source_path)
    freeze_receipt = load(freeze_path) if freeze_path else None
    execution_receipt = load(execution_path) if execution_path else None
    next_receipt = load(next_path) if next_path else None
    steps: dict[str, Any] = {}; errors: list[str] = []
    source = source_chain(source_receipt, steps, errors)
    freeze = freeze_chain(freeze_receipt, source_path, source, steps, errors)
    terminal = terminal_chain(execution_receipt, execution_path, freeze_path, freeze, steps, errors)
    next_session(next_receipt, terminal, steps, errors)
    states = [value["status"] for value in steps.values()]
    overall = "failed" if errors else "complete" if states and all(state == "passed" for state in states) else "incomplete"
    return {"format": "vela-golden-source-chain-verification-v1", "overallStatus": overall,
            "completeGoldenScenario": False, "goldenCompletionLimitation": "离线收据关联只能验证声明一致，不能认证 provider/模型行为或完整 Golden Scenario", "providerCalls": 0,
            "steps": steps, "errors": errors,
            "inputs": {"sourceReceiptSHA256": digest(source_path), "labFreezeReceiptSHA256": digest(freeze_path) if freeze_path else None,
                       "labExecutionReceiptSHA256": digest(execution_path) if execution_path else None, "nextSessionReceiptSHA256": digest(next_path) if next_path else None},
            "nextSessionReceiptSchema": {"format": "vela-golden-next-session-reuse-v1", "required": ["sourceEvaluationId", "sourceSuggestionId", "candidateMemoryIds", "providerSessionId", "contextHash", "delivery", "agentAdoption"], "delivery": "provided_to_provider_input", "agentAdoption": ["observed", "not_measured"]}}


def self_test(source_path: Path, freeze_path: Path, execution_path: Path) -> dict[str, Any]:
    source, freeze, execution = load(source_path), load(freeze_path), load(execution_path)
    mutations = [
        ("manual-candidate-write-is-rejected", lambda s, f, e: s.__setitem__("manualCandidateWrites", True), "sourceToCandidate"),
        ("missing-prior-receipt-is-rejected", lambda s, f, e: s.__setitem__("priorReceipt", "/missing/golden-prior.json"), "sourceToCandidate"),
        ("freeze-candidate-substitution-is-rejected", lambda s, f, e: f.__setitem__("candidateMemoryIds", ["hand-written-candidate"]), "candidateToApprovalLab"),
        ("execution-evaluation-substitution-is-rejected", lambda s, f, e: e.__setitem__("evaluationId", "hand-written-evaluation"), "approvalToTerminalDecision"),
    ]
    checks = []
    for name, mutate, expected in mutations:
        s, f, e = copy.deepcopy(source), copy.deepcopy(freeze), copy.deepcopy(execution); mutate(s, f, e)
        steps: dict[str, Any] = {}; errors: list[str] = []
        a = source_chain(s, steps, errors); b = freeze_chain(f, source_path, a, steps, errors); terminal_chain(e, execution_path, freeze_path, b, steps, errors)
        checks.append({"name": name, "passed": steps.get(expected, {}).get("status") == "failed"})
    # File boundaries are tested in a disposable directory: no retained receipt is altered.
    with tempfile.TemporaryDirectory(prefix="golden-linkage-") as directory:
        root = Path(directory); ordinary = root / "ordinary.json"; ordinary.write_text("{}")
        linked = root / "linked.json"; linked.symlink_to(ordinary)
        oversized = root / "oversized.json"; oversized.write_bytes(b"x" * (MAX + 1))
        for name, path in [("missing-receipt-is-reported", root / "missing.json"),
                           ("symlink-receipt-is-rejected-before-resolve", linked),
                           ("oversized-receipt-is-rejected-by-bounded-read", oversized)]:
            try:
                load(path); passed = False
            except ValueError:
                passed = True
            checks.append({"name": name, "passed": passed})
    # A syntactically self-authored reuse receipt remains untrusted, even when its IDs agree.
    steps = {}; errors = []; a = source_chain(source, steps, errors); b = freeze_chain(freeze, source_path, a, steps, errors)
    terminal = terminal_chain(execution, execution_path, freeze_path, b, steps, errors)
    fake = {"format": "vela-golden-next-session-reuse-v1", "status": "passed", "sourceEvaluationId": terminal["evaluation"],
            "sourceSuggestionId": terminal["suggestion"], "candidateMemoryIds": sorted(terminal["candidates"]),
            "providerSessionId": "self-authored-next-session", "contextHash": "0" * 64,
            "delivery": "provided_to_provider_input", "agentAdoption": "not_measured"}
    next_session(fake, terminal, steps, errors)
    checks.append({"name": "self-authored-next-session-never-completes-golden", "passed": steps.get("nextSessionReceipt", {}).get("status") == "declared_consistent_not_authenticated"})
    return {"passed": all(item["passed"] for item in checks), "checks": checks}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-receipt", type=Path, required=True, help="Passed postverify receipt: raw source → automatic candidate")
    parser.add_argument("--lab-freeze-receipt", type=Path)
    parser.add_argument("--lab-execution-receipt", type=Path)
    parser.add_argument("--next-session-receipt", type=Path)
    parser.add_argument("--output", type=Path, required=True, help="New JSON receipt")
    parser.add_argument("--require-complete", action="store_true", help="离线校验器不能认证完整 Golden，始终非零退出")
    parser.add_argument("--self-test", action="store_true", help="执行内存负例关联自检，需要 freeze/execution")
    args = parser.parse_args()
    try:
        output = output_path(args.output)
    except ValueError as exc:
        parser.error(str(exc))
    try:
        source = regular_path(args.source_receipt, "source receipt")
        freeze = regular_path(args.lab_freeze_receipt, "lab-freeze receipt") if args.lab_freeze_receipt else None
        execution = regular_path(args.lab_execution_receipt, "lab-execution receipt") if args.lab_execution_receipt else None
        next_path = regular_path(args.next_session_receipt, "next-session receipt") if args.next_session_receipt else None
        result = check(source, freeze, execution, next_path)
        if args.self_test:
            if not freeze or not execution: raise ValueError("--self-test 需要 freeze/execution")
            result["selfTest"] = self_test(source, freeze, execution)
            if not result["selfTest"]["passed"]:
                result["overallStatus"] = "failed"; result["errors"].append("负例自检失败")
    except Exception as exc:
        result = {"format": "vela-golden-source-chain-verification-v1", "overallStatus": "failed", "completeGoldenScenario": False, "providerCalls": 0, "errors": [str(exc)[:2000]]}
    # Preflight above made the parent safe; exclusive creation prevents a race from overwriting a receipt.
    with output.open("x", encoding="utf-8") as handle:
        handle.write(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"receipt": str(output), "overallStatus": result["overallStatus"], "providerCalls": 0}, ensure_ascii=False))
    # `--require-complete` cannot be satisfied by a self-authored reuse receipt:
    # this offline verifier never authenticates a provider, a model, or all GS steps.
    return 0 if result["overallStatus"] != "failed" and not args.require_complete else 1

if __name__ == "__main__":
    raise SystemExit(main())
