#!/usr/bin/env python3
"""Verify a real Lab child gets an empty signal mask from the RPC Dispatch worker."""
import argparse
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path


def invoke(binary, home, method, params):
    frame = json.dumps({'id': method, 'method': method, 'params': params}) + '\n'
    completed = subprocess.run([str(binary), 'rpc', '--home', str(home), '--no-watch', '--no-schedule'], input=frame, text=True, capture_output=True, timeout=30)
    if completed.returncode != 0:
        raise RuntimeError(completed.stderr.strip() or completed.stdout.strip())
    response = json.loads(completed.stdout)
    if 'error' in response:
        raise RuntimeError(response['error'].get('message', str(response['error'])))
    return response['result']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix='vela-lab-sigmask-') as raw:
        base = Path(raw); project = base / 'project'; home = base / 'store'; project.mkdir()
        env = os.environ | {'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_TEMPLATE_DIR': str(base / 'empty-template')}
        (base / 'empty-template').mkdir()
        (project / 'bounds.py').write_text('value = "original"\n')
        (project / 'verify.py').write_text('assert True\n')
        for command in (['git', '-c', 'core.hooksPath=/dev/null', 'init', '-q'], ['git', '-c', 'core.hooksPath=/dev/null', 'add', '.'], ['git', '-c', 'core.hooksPath=/dev/null', '-c', 'user.name=fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture']):
            subprocess.run(command, cwd=project, env=env, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        source = base / 'signal-mask-agent.c'; agent = base / 'signal-mask-agent'
        source.write_text(r'''#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
static volatile sig_atomic_t saw_sigchld = 0;
static void on_sigchld(int ignored) { (void)ignored; saw_sigchld = 1; }
int main(int argc, char **argv) {
  if (argc > 1 && strcmp(argv[1], "--version") == 0) { puts("signal-mask-agent 1"); return 0; }
  struct sigaction action; memset(&action, 0, sizeof(action)); action.sa_handler = on_sigchld; sigemptyset(&action.sa_mask);
  if (sigaction(SIGCHLD, &action, NULL) != 0) return 2;
  pid_t child = fork(); if (child < 0) return 3; if (child == 0) _exit(0);
  int status = 0, reaped = 0;
  for (int i = 0; i < 100; ++i) {
    pid_t value = waitpid(child, &status, WNOHANG);
    if (value == child) { reaped = 1; break; }
    struct timespec delay = {0, 10000000}; nanosleep(&delay, NULL);
  }
  if (!reaped && waitpid(child, &status, 0) == child) reaped = 1;
  sigset_t mask; sigprocmask(SIG_SETMASK, NULL, &mask);
  printf("SIGCHLD_blocked=%d SIGINT_blocked=%d SIGTERM_blocked=%d handler=%d waitpid=%d\n", sigismember(&mask,SIGCHLD), sigismember(&mask,SIGINT), sigismember(&mask,SIGTERM), saw_sigchld ? 1 : 0, reaped);
  return (saw_sigchld && reaped) ? 0 : 4;
}''')
        subprocess.run(['/usr/bin/clang', str(source), '-o', str(agent)], check=True, capture_output=True, text=True)
        direct = subprocess.run([str(agent)], check=True, capture_output=True, text=True).stdout.strip()
        expected = 'SIGCHLD_blocked=0 SIGINT_blocked=0 SIGTERM_blocked=0 handler=1 waitpid=1'
        assert direct == expected, direct
        invoke(binary, home, 'projects.add', {'path': str(project)})
        evaluation = invoke(binary, home, 'lab.run', {
            'title': 'signal mask fixture', 'project': str(project), 'kind': 'context',
            'agent': {'provider': 'codex', 'executable': str(agent), 'model': 'synthetic', 'reasoningEffort': 'high'},
            'task': 'fixed local task', 'verificationCommand': ['/usr/bin/python3', 'verify.py'],
            'verificationFiles': ['verify.py'], 'outputFiles': ['bounds.py'], 'timeoutSeconds': 20,
            'repetitions': 1, 'baseline': {'files': []}, 'candidate': {'files': []}})
        inbox = invoke(binary, home, 'inbox.list', {'project': str(project)})
        approval = next(item for item in inbox if item['id'] == evaluation['approvalId'])
        invoke(binary, home, 'approvals.decide', {'id': approval['id'], 'decision': 'approve', 'snapshotHash': approval['snapshotHash']})
        observed = invoke(binary, home, 'lab.compare', {'id': evaluation['id']})
        assert observed['state'] == 'completed', observed
        outputs = [row['output'].strip() for row in observed['results']]
        assert outputs == [expected, expected], outputs
        receipt = {'format': 'vela-automation-sigmask-rpc-v1', 'providerRuns': 0, 'directMask': direct, 'labMasks': outputs, 'dispatchWorkerLab': True, 'helperSHA256': __import__('hashlib').sha256(binary.read_bytes()).hexdigest(), 'temporaryFixturesRemoved': True}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({'passed': 1, 'output': str(args.output)}))

if __name__ == '__main__': main()
