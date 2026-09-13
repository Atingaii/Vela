#!/usr/bin/env python3
"""Public CLI/RPC acceptance for a frozen Vela backup helper.

This runner deliberately never opens or mutates SQLite itself.  It creates a
synthetic Git project through public RPC, drives the real daemon and backup
commands, and saves every argv/stdout/stderr/RPC response in the receipt.
"""
from __future__ import annotations

import argparse
import fcntl
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
import time
import traceback
import uuid
from typing import Any, Callable


JSON = dict[str, Any]


def canonical(path: Path) -> Path:
    return path.resolve(strict=False)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def source_tree_manifest(root: Path) -> JSON:
    """Hash explicit build inputs; never enumerate caches, user data or unrelated docs."""
    assert (root / 'Sources/VelaCore/Store.swift').is_file(), 'missing source root'
    paths = sorted(p for p in (root / 'Sources').rglob('*') if p.is_file()) + [root / 'Package.swift']
    entries = []
    for path in paths:
        if path.is_symlink():
            raise AssertionError('source input is a symbolic link')
        entries.append({'path': str(path.relative_to(root)), 'bytes': path.stat().st_size, 'sha256': sha256_file(path)})
    encoded = json.dumps(entries, sort_keys=True, separators=(',', ':')).encode()
    return {'inputs': entries, 'sha256': hashlib.sha256(encoded).hexdigest()}


def tree_manifest(root: Path) -> JSON:
    """Hash regular-file bytes, preserving symlink identity in the receipt."""
    entries: list[JSON] = []
    for path in sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()):
        relative = path.relative_to(root).as_posix()
        stat = path.lstat()
        if path.is_symlink():
            entries.append({"path": relative, "type": "symlink", "target": os.readlink(path)})
        elif path.is_dir():
            entries.append({"path": relative, "type": "directory", "mode": stat.st_mode & 0o777})
        elif path.is_file():
            entries.append({"path": relative, "type": "file", "bytes": stat.st_size,
                            "sha256": sha256_file(path), "mode": stat.st_mode & 0o777})
        else:
            entries.append({"path": relative, "type": "other", "mode": stat.st_mode & 0o777})
    encoded = json.dumps(entries, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    return {"root": str(root), "entries": entries, "sha256": hashlib.sha256(encoded).hexdigest()}


class Harness:
    def __init__(self, binary: Path, output: Path, fixture_parent: Path, timeout: float) -> None:
        self.binary = canonical(binary)
        self.output = output
        self.fixture_parent = canonical(fixture_parent)
        self.timeout = timeout
        self.trace: list[JSON] = []
        self.daemons: list[subprocess.Popen[str]] = []
        self.fixture: Path | None = None
        self.environment = dict(os.environ, VELA_DISABLE_DISCOVERY="1")

    def record(self, name: str, argv: list[str], result: subprocess.CompletedProcess[str]) -> JSON:
        entry: JSON = {
            "name": name,
            "at": time.time(),
            "argv": argv,
            "exit": result.returncode,
            "stdout": result.stdout,
            "stderr": result.stderr,
        }
        self.trace.append(entry)
        return entry

    def command(self, name: str, argv: list[str], *, input_text: str | None = None,
                expect: int | None = 0, timeout: float | None = None) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(argv, input=input_text, text=True, capture_output=True, env=self.environment,
                                timeout=timeout or self.timeout, check=False)
        self.record(name, argv, result)
        if expect is not None and result.returncode != expect:
            raise AssertionError(f"{name} exit {result.returncode}, expected {expect}: {result.stderr}")
        return result

    def rpc(self, home: Path, method: str, params: JSON) -> Any:
        argv = [str(self.binary), "call", method, "--params-stdin", "--home", str(home)]
        result = self.command(f"rpc:{method}", argv, input_text=json.dumps(params, ensure_ascii=False))
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise AssertionError(f"{method} did not return JSON: {result.stdout!r}") from error

    def start_daemon(self, home: Path, label: str) -> subprocess.Popen[str]:
        argv = [str(self.binary), "daemon", "run", "--no-watch", "--home", str(home)]
        process = subprocess.Popen(argv, text=True, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.environment)
        self.daemons.append(process)
        ready = ""
        deadline = time.monotonic() + min(self.timeout, 10)
        assert process.stdout is not None
        while time.monotonic() < deadline:
            readable, _, _ = select.select([process.stdout], [], [], 0.1)
            if readable:
                ready = process.stdout.readline()
                break
            if process.poll() is not None:
                break
        entry: JSON = {"name": f"daemon.start:{label}", "at": time.time(), "argv": argv,
                       "pid": process.pid, "startupStdout": ready, "startupExit": process.poll()}
        self.trace.append(entry)
        if process.poll() is not None:
            assert process.stderr is not None
            raise AssertionError(f"daemon {label} stopped while starting: {process.stderr.read()}")
        return process

    def stop_daemon(self, process: subprocess.Popen[str], label: str) -> None:
        if process.poll() is None:
            process.send_signal(signal.SIGTERM)
        try:
            stdout, stderr = process.communicate(timeout=min(self.timeout, 10))
        except subprocess.TimeoutExpired:
            process.kill()
            stdout, stderr = process.communicate(timeout=3)
            self.trace.append({"name": f"daemon.stop:{label}", "argv": [], "pid": process.pid,
                               "exit": process.returncode, "stdout": stdout, "stderr": stderr, "forced": True})
            raise AssertionError(f"owned daemon {label} exceeded its stop bound")
        self.trace.append({"name": f"daemon.stop:{label}", "argv": [], "pid": process.pid,
                           "exit": process.returncode, "stdout": stdout, "stderr": stderr, "forced": False})
        if process.returncode != 0:
            raise AssertionError(f"owned daemon {label} exited {process.returncode}: {stderr}")
        if process in self.daemons:
            self.daemons.remove(process)

    def wait_for(self, description: str, check: Callable[[], Any], timeout: float) -> Any:
        deadline = time.monotonic() + timeout
        last: Any = None
        while time.monotonic() < deadline:
            last = check()
            if last:
                return last
            time.sleep(0.15)
        raise AssertionError(f"bounded wait timed out: {description}; last={last!r}")


def hold_apply_lock(path: Path) -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        print(json.dumps({"ready": True, "path": str(path), "pid": os.getpid()}), flush=True)
        stopping = False

        def stop(_: int, __: Any) -> None:
            nonlocal stopping
            stopping = True

        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        while not stopping:
            time.sleep(0.1)
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)
    return 0


def start_apply_lock(harness: Harness, store: Path) -> subprocess.Popen[str]:
    argv = [sys.executable, str(Path(__file__).resolve()), "--hold-apply-lock", str(store / "apply.lock")]
    process = subprocess.Popen(argv, text=True, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, env=harness.environment)
    assert process.stdout is not None
    deadline = time.monotonic() + min(harness.timeout, 10)
    line = ""
    while time.monotonic() < deadline:
        readable, _, _ = select.select([process.stdout], [], [], 0.1)
        if readable:
            line = process.stdout.readline()
            break
        if process.poll() is not None:
            break
    harness.trace.append({"name": "apply-lock.start", "at": time.time(), "argv": argv, "pid": process.pid,
                          "stdout": line, "exit": process.poll()})
    if process.poll() is not None or json.loads(line).get("ready") is not True:
        raise AssertionError("could not hold the owned SafeApply flock")
    return process


def stop_apply_lock(harness: Harness, process: subprocess.Popen[str]) -> None:
    if process.poll() is None:
        process.terminate()
    stdout, stderr = process.communicate(timeout=min(harness.timeout, 10))
    harness.trace.append({"name": "apply-lock.stop", "at": time.time(), "argv": [], "pid": process.pid,
                          "stdout": stdout, "stderr": stderr, "exit": process.returncode})
    if process.returncode != 0:
        raise AssertionError(f"owned SafeApply lock exited {process.returncode}: {stderr}")


def matching_watch_state(harness: Harness, home: Path, watch: JSON, predicate: Callable[[JSON], bool]) -> JSON | None:
    response = harness.rpc(home, "watches.get", watch)
    state = response.get("state") if isinstance(response, dict) else None
    return state if isinstance(state, dict) and predicate(state) else None


def create_public_watch_fixture(harness: Harness, store: Path, project: Path) -> tuple[JSON, JSON]:
    harness.command("git.init", ["/usr/bin/git", "-c", "core.hooksPath=/dev/null", "init", "-q", str(project)])
    harness.rpc(store, "projects.add", {"path": str(project)})
    workflow = harness.rpc(store, "workflows.save", {
        "title": "Backup runtime acceptance watch",
        "project": str(project), "trigger": "watch", "enabled": True,
        "watch": {"tool": "git.status", "arguments": {}, "everySeconds": 30, "debounceSeconds": 300},
        "steps": [{"tool": "file.write", "arguments": {"path": "must-not-write.txt", "content": "approval required"}}],
    })
    return workflow, {"id": workflow["id"], "project": str(project)}


def exercise_watch_restore(harness: Harness, store: Path, project: Path, bundle: Path, restored: Path) -> JSON:
    workflow, watch = create_public_watch_fixture(harness, store, project)
    daemon = harness.start_daemon(store, "source-watch-baseline")
    try:
        baseline = harness.wait_for("source watch baseline", lambda: matching_watch_state(
            harness, store, watch, lambda state: state.get("state") == "watching"), 10)
        assert harness.rpc(store, "runs.list", {"project": str(project)}) == []
        (project / "old-pending-change.txt").write_text("generated after public baseline\n")
        pending = harness.wait_for("public watch pending accumulation", lambda: matching_watch_state(
            harness, store, watch, lambda state: state.get("state") == "accumulating" and bool(state.get("pending"))), 42)
        assert harness.rpc(store, "runs.list", {"project": str(project)}) == []
    finally:
        harness.stop_daemon(daemon, "source-watch-baseline")
    before_backup = {"workflowVersion": workflow["version"], "pendingCount": len(pending["pending"]),
                     "baselineFingerprint": baseline["fingerprint"]}
    created = harness.command("backup.create:watch", [str(harness.binary), "backup", "create", "--destination", str(bundle), "--home", str(store)])
    create_reply = json.loads(created.stdout)
    bundle_before_restore = tree_manifest(bundle)
    restored_reply = harness.command("backup.restore:watch", [str(harness.binary), "backup", "restore", "--bundle", str(bundle), "--target", str(restored)])
    restore_reply = json.loads(restored_reply.stdout)
    bundle_after_restore = tree_manifest(bundle)
    assert bundle_after_restore["sha256"] == bundle_before_restore["sha256"], "restore altered the backup bundle"
    restored_state = harness.rpc(restored, "watches.get", watch)["state"]
    assert restored_state["state"] == "needs_review" and restored_state.get("pending"), restored_state
    inspection = harness.rpc(restored, "workflows.get", watch)
    enabled = harness.rpc(restored, "workflows.setEnabled", {
        "id": workflow["id"], "project": str(project), "snapshotHash": inspection["snapshotHash"], "enabled": True,
    })
    assert enabled["version"] == workflow["version"] + 1 and enabled["enabled"] is True, enabled
    daemon = harness.start_daemon(restored, "restored-reenable")
    try:
        reinitialized = harness.wait_for("re-enabled watch discards restored pending", lambda: matching_watch_state(
            harness, restored, watch, lambda state: state.get("state") == "watching" and state.get("pending") == {}
            and state.get("fingerprint") != restored_state.get("fingerprint")), 10)
        assert reinitialized.get("discardedOnDefinitionChange") == before_backup["pendingCount"], reinitialized
        assert harness.rpc(restored, "runs.list", {"project": str(project)}) == []
        assert harness.rpc(restored, "schedules.list", {"project": str(project)})["events"] == []
    finally:
        harness.stop_daemon(daemon, "restored-reenable")
    # The pre-backup debounce deliberately kept the old observation pending for
    # this test. Re-save with a zero debounce, which is itself a public versioned
    # definition change, then establish its fresh baseline before making a new
    # observation. This proves a new event can still reach approval without ever
    # dispatching the restored one.
    enabled = harness.rpc(restored, "workflows.save", {
        "id": workflow["id"], "title": workflow["title"], "project": str(project), "trigger": "watch", "enabled": True,
        "watch": {"tool": "git.status", "arguments": {}, "everySeconds": 30, "debounceSeconds": 0},
        "steps": workflow["steps"],
    })
    daemon = harness.start_daemon(restored, "new-change-baseline")
    try:
        fresh_baseline = harness.wait_for("new definition baseline", lambda: matching_watch_state(
            harness, restored, watch, lambda state: state.get("state") == "watching"
            and state.get("fingerprint") != reinitialized.get("fingerprint")), 10)
        (project / "new-change-after-restore.txt").write_text("new observation after reinitialization\n")
        approved_run = harness.wait_for("new watch change creates approval", lambda: next((run for run in harness.rpc(restored, "runs.list", {"project": str(project)})
                                                                                              if run.get("state") == "pending_approval"), None), 42)
        assert not (project / "must-not-write.txt").exists(), "watch executed a write before approval"
        events = harness.rpc(restored, "schedules.list", {"project": str(project)})["events"]
        assert len(events) == 1 and events[0]["state"] == "dispatched", events
    finally:
        harness.stop_daemon(daemon, "new-change-baseline")
    return {"watchId": workflow["id"], "source": before_backup, "backupCreate": create_reply, "backupRestore": restore_reply,
            "bundleBeforeRestore": bundle_before_restore, "bundleAfterRestore": bundle_after_restore,
            "restoredNeedsReview": {"state": restored_state["state"], "pending": len(restored_state["pending"])},
            "reinitialized": {"version": enabled["version"], "discarded": reinitialized["discardedOnDefinitionChange"],
                                "newDefinitionFingerprint": fresh_baseline["fingerprint"]},
            "newChange": {"runId": approved_run["id"], "state": approved_run["state"], "eventCount": len(events)}}


def assert_rejected_without_partial(harness: Harness, name: str, argv: list[str], destination: Path) -> JSON:
    result = harness.command(name, argv, expect=None)
    assert result.returncode != 0, f"{name} unexpectedly succeeded"
    assert not destination.exists(), f"{name} left a partial backup destination"
    return {"exit": result.returncode, "destinationAbsent": True}


def exercise_backup_leases(harness: Harness, store: Path, base: Path) -> JSON:
    daemon_destination = base / "backup-blocked-daemon"
    daemon = harness.start_daemon(store, "backup-lease")
    try:
        daemon_rejection = assert_rejected_without_partial(
            harness, "backup.create:daemon-held",
            [str(harness.binary), "backup", "create", "--destination", str(daemon_destination), "--home", str(store)], daemon_destination)
    finally:
        harness.stop_daemon(daemon, "backup-lease")
    daemon_success = base / "backup-after-daemon-release"
    result = harness.command("backup.create:daemon-released", [str(harness.binary), "backup", "create", "--destination", str(daemon_success), "--home", str(store)])
    assert daemon_success.exists() and json.loads(result.stdout).get("complete") is True
    lock_destination = base / "backup-blocked-safeapply"
    lock = start_apply_lock(harness, store)
    try:
        lock_rejection = assert_rejected_without_partial(
            harness, "backup.create:safeapply-held",
            [str(harness.binary), "backup", "create", "--destination", str(lock_destination), "--home", str(store)], lock_destination)
    finally:
        stop_apply_lock(harness, lock)
    lock_success = base / "backup-after-safeapply-release"
    result = harness.command("backup.create:safeapply-released", [str(harness.binary), "backup", "create", "--destination", str(lock_success), "--home", str(store)])
    assert lock_success.exists() and json.loads(result.stdout).get("complete") is True
    return {"daemonHeld": daemon_rejection, "safeApplyHeld": lock_rejection,
            "afterDaemonRelease": tree_manifest(daemon_success), "afterSafeApplyRelease": tree_manifest(lock_success)}


def exercise_restore_target_protection(harness: Harness, bundle: Path, base: Path, project: Path, watch_id: str) -> JSON:
    bundle_before = tree_manifest(bundle)
    existing = base / "existing-target"
    existing.mkdir()
    sentinel = existing / "preserve-me.bin"
    sentinel.write_bytes(b"must remain byte-identical\x00\xff")
    target_before = tree_manifest(existing)
    rejected = harness.command("backup.restore:existing-target", [str(harness.binary), "backup", "restore", "--bundle", str(bundle), "--target", str(existing)], expect=None)
    assert rejected.returncode != 0, "restore into existing target unexpectedly succeeded"
    assert tree_manifest(existing)["sha256"] == target_before["sha256"], "existing target changed"
    assert tree_manifest(bundle)["sha256"] == bundle_before["sha256"], "bundle changed after rejected restore"
    race_target = base / "restore-race-target"
    argv = [str(harness.binary), "backup", "restore", "--bundle", str(bundle), "--target", str(race_target)]
    processes = [subprocess.Popen(argv, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=harness.environment) for _ in range(2)]
    race: list[JSON] = []
    for index, process in enumerate(processes):
        stdout, stderr = process.communicate(timeout=harness.timeout)
        entry = {"name": f"backup.restore:race:{index}", "at": time.time(), "argv": argv,
                 "exit": process.returncode, "stdout": stdout, "stderr": stderr}
        harness.trace.append(entry)
        race.append(entry)
    successes = [item for item in race if item["exit"] == 0]
    assert len(successes) == 1, race
    assert race_target.exists() and tree_manifest(bundle)["sha256"] == bundle_before["sha256"]
    restored_watch = harness.rpc(race_target, "watches.get", {"id": watch_id, "project": str(project)})["state"]
    assert restored_watch["state"] == "needs_review", restored_watch
    return {"existingTargetRejected": {"exit": rejected.returncode, "bytesPreserved": True},
            "concurrentRestores": {"successes": len(successes), "failures": len(race) - len(successes),
                                   "targetState": restored_watch["state"]}, "bundleUnchanged": True}


def run(args: argparse.Namespace) -> JSON:
    binary = canonical(args.binary)
    assert binary.is_file(), f"frozen helper is missing: {binary}"
    assert args.output.parent.is_dir() and not args.output.exists(), f"choose a new receipt path: {args.output}"
    fixture_parent = canonical(args.fixture_parent)
    assert fixture_parent.is_dir() and not fixture_parent.is_symlink(), f"fixture parent must be a real directory: {fixture_parent}"
    source_root = canonical(args.source_root)
    assert source_root.is_dir() and not source_root.is_symlink(), f"source root must be a real directory: {source_root}"
    source_before = source_tree_manifest(source_root)
    harness = Harness(binary, args.output, fixture_parent, args.timeout)
    receipt: JSON = {"format": "vela-backup-runtime-acceptance-v1", "passed": False,
                     "harness": {"path": str(Path(__file__).resolve()), "sha256": sha256_file(Path(__file__).resolve())},
                     "helper": {"path": str(binary), "sha256Before": sha256_file(binary)},
                     "source": {"root": str(source_root), "treeBefore": source_before},
                     "publicOnly": True, "directDatabaseMutation": False, "providerCalls": 0,
                     "fixtureParent": str(fixture_parent), "checks": {}}
    completed_checks = False
    try:
        base = Path(tempfile.mkdtemp(prefix="vela-backup-runtime-", dir=fixture_parent)).resolve()
        harness.fixture = base
        store, project = base / "store", base / "project"
        project.mkdir()
        bundle, restored = base / "watch-backup", base / "restored-watch-store"
        receipt["fixture"] = str(base)
        watch_result = exercise_watch_restore(harness, store, project, bundle, restored)
        receipt["checks"]["watchRestoreReenable"] = watch_result
        receipt["checks"]["backupLeases"] = exercise_backup_leases(harness, store, base)
        receipt["checks"]["restoreTargetProtection"] = exercise_restore_target_protection(
            harness, bundle, base, project, watch_result["watchId"])
        completed_checks = True
    except Exception as error:
        receipt["error"] = repr(error)
        receipt["traceback"] = traceback.format_exc()
    finally:
        finalization_errors: list[str] = []
        for daemon in list(harness.daemons):
            try:
                harness.stop_daemon(daemon, "finally")
            except Exception as error:
                finalization_errors.append(f"daemon cleanup: {error!r}")
        if harness.fixture is not None:
            try:
                shutil.rmtree(harness.fixture)
            except Exception as error:
                finalization_errors.append(f"fixture cleanup: {error!r}")
            receipt["fixtureRemoved"] = not harness.fixture.exists()
            if not receipt["fixtureRemoved"]:
                finalization_errors.append("fixture cleanup left the owned fixture behind")
        else:
            receipt["fixtureRemoved"] = None
        try:
            helper_after = sha256_file(binary)
            receipt["helper"]["sha256After"] = helper_after
            if helper_after != receipt["helper"]["sha256Before"]:
                finalization_errors.append("frozen helper changed during acceptance")
        except Exception as error:
            finalization_errors.append(f"helper hash after acceptance: {error!r}")
        try:
            source_after = source_tree_manifest(source_root)
            receipt["source"]["treeAfter"] = source_after
            receipt["source"]["unchanged"] = source_after["sha256"] == source_before["sha256"]
            if not receipt["source"]["unchanged"]:
                finalization_errors.append("source root changed during acceptance")
        except Exception as error:
            finalization_errors.append(f"source hash after acceptance: {error!r}")
        if finalization_errors:
            receipt["cleanupErrors"] = finalization_errors
            if "error" not in receipt:
                receipt["error"] = "Acceptance finalization failed"
        receipt["passed"] = completed_checks and not finalization_errors
        receipt["trace"] = harness.trace
        args.output.write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
    return receipt


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hold-apply-lock", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--binary", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--fixture-parent", type=Path)
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[1],
                        help="Git worktree whose current source bytes must remain unchanged; defaults to this repository")
    parser.add_argument("--timeout", type=float, default=55)
    args = parser.parse_args()
    if args.hold_apply_lock:
        return hold_apply_lock(args.hold_apply_lock)
    for name in ("binary", "output", "fixture_parent"):
        if getattr(args, name) is None:
            parser.error(f"--{name.replace('_', '-')} is required")
    receipt = run(args)
    print(json.dumps({"passed": receipt["passed"], "output": str(args.output)}, ensure_ascii=False))
    return 0 if receipt["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
