"""Diagnose the real FSEvents restart race with frozen Core and synthetic files."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


PROGRAM = r'''
import Foundation
import CoreServices

let base = Date(timeIntervalSince1970:1_789_257_600)
let expectedReason = "A newer file event arrived during capture; waiting for the next coherent observation"
var attempts: [JSON] = [], reproduced = 0
for attempt in 0..<64 {
    let result: JSON = try autoreleasepool {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("vela-watch-restart-probe-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temporary) }
        let raw = temporary.appendingPathComponent("project")
        try FileManager.default.createDirectory(at:raw,withIntermediateDirectories:true)
        let project = URL(fileURLWithPath:canonicalProject(raw.path)), store = try VelaStore(root:temporary.appendingPathComponent("store"))
        _ = try store.put("project",["project":project.path,"path":project.path])
        _ = try AutomationProcess.git(["init","-q"],cwd:project.path)
        let original = AutomationService(store:store); defer { original.fileWatchEvents.stop() }
        let policy = try WorkflowWatch.validate(["source":"files","paths":["offline.txt"],"recursive":true,"ignore":[],"debounceSeconds":0])
        guard let workflow = try original.handle("workflows.save",["title":"Synthetic restart probe","project":project.path,"trigger":"watch","enabled":true,"watch":policy,"steps":[["tool":"git.status","arguments":JSON()]]]) as? JSON else { throw VelaError("Workflow fixture unavailable") }
        let id = string(workflow,"id"), target = project.appendingPathComponent("offline.txt")
        try Data("before".utf8).write(to:target); try original.tick(at:base)
        original.fileWatchEvents.stop()
        try Data("middle".utf8).write(to:target); try Data("after".utf8).write(to:target)
        let reopened = AutomationService(store:try VelaStore(root:store.root)); defer { reopened.fileWatchEvents.stop() }
        try reopened.tick(at:base.addingTimeInterval(30))
        let firstCount = try store.list("run").count, firstSchedule = try store.get("schedule",id) ?? [:], firstState = try store.get("watch_state",id) ?? [:]
        let signal = try reopened.fileWatchEvents.signal(id)
        var observed: JSON = ["attempt":attempt,"initialRunCount":firstCount,"initialScheduleState":string(firstSchedule,"state"),"initialReason":string(firstSchedule,"reason"),
                              "capturedSerial":firstState["fileEventSerial"] ?? NSNull(),"currentSerial":signal["serial"] ?? NSNull(),"pendingItems":(firstState["pending"] as? JSON ?? [:]).count]
        if firstCount == 0, string(firstSchedule,"reason") != expectedReason { throw VelaError("Unexpected zero-run cause: " + (try jsonString(observed))) }
        let started = Date(), deadline = started.addingTimeInterval(4)
        var polls = 0
        while try store.list("run").isEmpty, Date() < deadline {
            // Each retry is conditional on the production guard's exact reason.
            let schedule = try store.get("schedule",id) ?? [:]
            guard string(schedule,"reason") == expectedReason else { throw VelaError("A different watch error or deferral appeared") }
            Thread.sleep(forTimeInterval:0.01)
            try reopened.tick(at:base.addingTimeInterval(30)); polls += 1
        }
        let runs = try store.list("run"), events = try store.list("schedule_event")
        guard runs.count == 1, events.count == 1, let input = events.first?["watchInput"] as? JSON,
              let changes = input["changes"] as? [JSON], changes.count == 1,
              let after = changes[0]["after"] as? JSON, let value = after["value"] as? JSON,
              string(value,"contentHash") == stableHash("after") else { throw VelaError("Restart did not reconcile exactly one net source change") }
        let second = AutomationService(store:try VelaStore(root:store.root)); defer { second.fileWatchEvents.stop() }
        try second.tick(at:base.addingTimeInterval(60))
        guard try store.list("run").count == 1, string(try store.get("watch_state",id) ?? [:],"state") == "watching" else { throw VelaError("Second restart repeated or failed reconciliation") }
        observed["retryPolls"] = polls; observed["reconcileSeconds"] = Date().timeIntervalSince(started); observed["finalRunCount"] = 1
        return observed
    }
    attempts.append(result)
    print(try jsonString(result))
    if intValue(result,"initialRunCount") == 0 { reproduced += 1 }
    if reproduced >= 3 { break }
}
print(try jsonString(["attempts":attempts.count,"guardReproduced":reproduced,"netStateExactlyOnce":true,"syntheticOnly":true,"providerCalls":0]))
if reproduced == 0 { exit(2) }
'''


def main():
    repo = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, required=True)
    args = parser.parse_args()
    if args.output_dir.exists() or args.output_dir.is_symlink():
        parser.error('Choose a new output directory.')
    args.output_dir.mkdir(parents=True)
    paths = sorted((repo / 'Sources/VelaCore').glob('*.swift'))
    snapshot = {path: path.read_bytes() for path in paths}
    hashes = {str(path.relative_to(repo)): hashlib.sha256(value).hexdigest() for path, value in snapshot.items()}
    receipt = dict(sourceSHA256=hashes, coreSnapshotSHA256=hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest(),
                   programSHA256=hashlib.sha256(PROGRAM.encode()).hexdigest(), sourceData='synthetic only', providerCalls=0)
    (args.output_dir / 'main.swift').write_text(PROGRAM)
    try:
        with tempfile.TemporaryDirectory(prefix='vela-watch-restart-compiler-') as temporary:
            base = Path(temporary).resolve()
            for path, value in snapshot.items(): (base / path.name).write_bytes(value)
            (base / 'main.swift').write_text(PROGRAM)
            command = ['swiftc', '-swift-version', '5', '-I', str(repo / 'Sources/CSQLite'),
                       *[str(base / path.name) for path in paths], str(base / 'main.swift'), '-o', str(base / 'probe')]
            compile_result = subprocess.run(command, capture_output=True, text=True, timeout=180)
            (args.output_dir / 'compile.log').write_text(compile_result.stdout + compile_result.stderr)
            compile_result.check_returncode()
            receipt['probeSHA256'] = hashlib.sha256((base / 'probe').read_bytes()).hexdigest()
            env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
            completed = subprocess.run([str(base / 'probe')], capture_output=True, text=True, timeout=120, env=env)
            (args.output_dir / 'probe.log').write_text(completed.stdout + completed.stderr)
            receipt['exitCode'] = completed.returncode
            receipt['observations'] = [json.loads(line) for line in completed.stdout.splitlines() if line.startswith('{')]
            receipt['guardReproduced'] = bool(receipt['observations'] and receipt['observations'][-1].get('guardReproduced', 0))
        receipt['temporaryDirectoryRemoved'] = not base.exists()
        if completed.returncode:
            raise SystemExit(completed.returncode)
    finally:
        receipt['matchesWorkingTreeAtEnd'] = all(path.read_bytes() == value for path, value in snapshot.items())
        (args.output_dir / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
        print(json.dumps({key: receipt.get(key) for key in ['coreSnapshotSHA256', 'probeSHA256', 'guardReproduced', 'exitCode', 'temporaryDirectoryRemoved', 'matchesWorkingTreeAtEnd']}))


if __name__ == '__main__':
    main()
