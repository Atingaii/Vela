"""Opt-in real Codex comparison on a new, disposable standard-library project.

This consumes the selected provider's existing allowance. It never alters user
agent configuration, claims a synthetic correction, or promotes a tied result.
Keep the produced receipt as evidence, not as a general quality benchmark.
"""
import argparse, hashlib, json, os, pathlib, subprocess, time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('directory', type=pathlib.Path)
parser.add_argument('--model', required=True)
parser.add_argument('--binary', type=pathlib.Path, default=pathlib.Path('.build/debug/vela'))
parser.add_argument('--live', action='store_true', help='Explicitly execute six real provider turns')
args = parser.parse_args()
if not args.live:
    parser.error('--live is required; this test uses real model allowance')
base = args.directory.resolve()
if base.exists():
    parser.error('A new directory is required; existing data is never overwritten')
base.mkdir(parents=True)
project = base / 'Bounds'
project.mkdir()
store = base / 'store'
binary = args.binary.resolve()
env = dict(os.environ, VELA_HOME=str(store), VELA_DISABLE_DISCOVERY='1')
env.pop('VELA_SESSION_ROOT', None)
task = ('Implement clamp(value, lower, upper) in bounds.py. Accept finite int/float values, '
        'including the endpoints; return the value restricted to the inclusive interval. '
        'Reject booleans and non-numbers with TypeError, non-finite numbers or reversed '
        'bounds with ValueError. Keep the public function signature unchanged. Do not '
        'modify verification files or project configuration. Summarize the result.')
(project / 'bounds.py').write_text('def clamp(value, lower, upper):\n    raise NotImplementedError\n')
(project / 'README.md').write_text('# Bounds\n\nA standard-library Python exercise. Run `/usr/bin/python3 verify.py` to validate.\n')
(project / 'verify.py').write_text('''import math, unittest
from bounds import clamp
class BoundsTests(unittest.TestCase):
    def test_inside(self): self.assertEqual(clamp(5, 0, 10), 5)
    def test_below(self): self.assertEqual(clamp(-1, 0, 10), 0)
    def test_above(self): self.assertEqual(clamp(11, 0, 10), 10)
    def test_equal(self): self.assertEqual(clamp(3, 3, 3), 3)
    def test_fraction(self): self.assertEqual(clamp(0.5, 0.1, 0.7), 0.5)
    def test_reversed(self):
        with self.assertRaises(ValueError): clamp(1, 2, 0)
    def test_nonfinite(self):
        for value in [float('nan'), float('inf'), -float('inf')]:
            for i in range(3):
                inputs = [0, -1, 1]; inputs[i] = value
                with self.assertRaises(ValueError): clamp(*inputs)
    def test_types(self):
        for value in [True, False, '1', None, []]:
            for i in range(3):
                inputs = [0, -1, 1]; inputs[i] = value
                with self.assertRaises(TypeError): clamp(*inputs)
if __name__ == '__main__': unittest.main()
''')
def git(*argv):
    return subprocess.check_output(['/usr/bin/git', '-c', 'core.hooksPath=/dev/null', '-C', str(project), *argv], text=True).strip()
git('init', '-q')
git('add', 'bounds.py', 'README.md', 'verify.py')
git('-c', 'user.name=Vela Acceptance', '-c', 'user.email=acceptance@example.invalid', 'commit', '-qm', 'Frozen independent verification task')
def call(method, params):
    result = subprocess.run([str(binary), 'call', method, json.dumps(params)], env=env, capture_output=True, text=True, timeout=2100)
    if result.returncode:
        raise RuntimeError(f'{method}: {result.stderr[-4000:]}')
    return json.loads(result.stdout)
call('projects.add', {'path': str(project)})
memory = call('memory.save', {'title':'Verification before handoff', 'content':'Before handing off code changes, run /usr/bin/python3 verify.py in this project. Inspect failures, fix the implementation, and report the actual test outcome.', 'scope':'project', 'project':str(project), 'state':'candidate', 'type':'constraint'})
frozen = {'title':'Real Codex verification-context comparison', 'kind':'memory', 'project':str(project), 'agent':{'provider':'codex','model':args.model,'reasoningEffort':'high'}, 'task':task, 'verificationCommand':['/usr/bin/python3','verify.py'], 'verificationFiles':['verify.py','README.md'], 'outputFiles':['bounds.py'], 'timeoutSeconds':240, 'repetitions':3, 'baseline':{'label':'Same task without candidate memory','files':[]}, 'candidate':{'label':'Same task with reviewed verification candidate','memoryIds':[memory['id']],'files':[]}}
evaluation = call('lab.run', frozen)
approval = next(a for a in call('inbox.list', {}) if a['id'] == evaluation['approvalId'])
(base / 'frozen.json').write_text(json.dumps({'task':frozen,'approval':approval}, indent=2))
print(json.dumps({'state':'running','evalId':evaluation['id'],'repetitions':3,'model':args.model,'commit':git('rev-parse','HEAD') }), flush=True)
started = time.time()
decision = call('approvals.decide', {'id':approval['id'],'decision':'approve','snapshotHash':approval['snapshotHash']})
evaluation = call('lab.compare', {'id':evaluation['id']})
(base / 'evaluation.json').write_text(json.dumps(evaluation,indent=2))
receipt = {'fixture':'synthetic-python-clamp-task-v1','realProvider':True,'modelRequested':args.model,'binarySHA256':hashlib.sha256(binary.read_bytes()).hexdigest(),'repoCommit':git('rev-parse','HEAD'),'taskSHA256':hashlib.sha256(task.encode()).hexdigest(),'durationSeconds':round(time.time()-started,2),'approvalState':decision['state'],'evaluationState':evaluation['state'],'agentVersion':evaluation.get('agentVersion'),'summary':evaluation.get('summary'),'originalGitStatusUnchanged':evaluation.get('originalGitStatusUnchanged'), 'originalWorktreeContentEquality':'not_measured','cleanupFailures':evaluation.get('cleanupFailures'),'fullGoldenScenarioPassed':False,'futureCorrectionReduction':'not_measured','autoPromoted':False}
(base / 'receipt.json').write_text(json.dumps(receipt,indent=2))
print(json.dumps(receipt,indent=2),flush=True)
if evaluation['state'] != 'completed': raise SystemExit(1)
