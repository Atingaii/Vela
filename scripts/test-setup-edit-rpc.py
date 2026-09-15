#!/usr/bin/env python3
"""Actual zero-provider Setup edit contract against an isolated, immutable Vela helper."""
import argparse, datetime as dt, hashlib, json, os, shutil, subprocess, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True, help='immutable frozen vela helper')
    parser.add_argument('--output', type=Path, required=True, help='new receipt JSON')
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    if args.output.exists(): parser.error('output must be new; evidence is never overwritten')
    scratch = ROOT / '.task-tmp'; scratch.mkdir(exist_ok=True)
    base = Path(tempfile.mkdtemp(prefix='setup-edit-rpc-', dir=scratch)).resolve()
    project, other, home, store, sessions = (base / name for name in ('Harbor','Beacon','home','store','sources'))
    helper = base / 'vela'
    ev = {'format':'vela-setup-edit-rpc-v1','passed':False,'synthetic':True,'providerRuns':0,
          'sourceBefore':None,'sourceAfter':None,'helperBefore':digest(binary),'helperAfter':None,
          'checks':[],'errors':[],'transcript':[], 'fixtureRemoved':False, 'helperCopyUnchanged':False,
          'startedAt':dt.datetime.now(dt.timezone.utc).isoformat()}
    def check(name, condition, **detail):
        row = {'name':name, 'passed':bool(condition), **detail}; ev['checks'].append(row)
        if not condition: raise AssertionError(name + ': ' + json.dumps(detail, ensure_ascii=False))
    def source_hashes():
        return {str(p.relative_to(project)):digest(p) for p in sorted(project.rglob('*')) if p.is_file() and not p.is_symlink()}
    def call(method, params, fail=False):
        q = subprocess.run([str(helper),'call',method,json.dumps(params,separators=(',',':')),'--home',str(store)],
                           cwd=project, env=env, text=True, capture_output=True, timeout=30)
        record = {'method':method,'params':params,'exitCode':q.returncode,
                  'stdout':q.stdout[-4000:],'stderr':q.stderr[-4000:]}
        ev['transcript'].append(record)
        if fail:
            check('rejected-'+method+'-'+str(len(ev['transcript'])), q.returncode != 0, error=record['stderr'] or record['stdout'])
            return None
        if q.returncode:
            raise RuntimeError(method + ': ' + (q.stderr or q.stdout))
        return json.loads(q.stdout)
    try:
        for directory in (project, other, home, store, sessions): directory.mkdir(parents=True)
        shutil.copy2(binary, helper); os.chmod(helper, 0o700)
        env = {'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','LANG':'en_US.UTF-8','VELA_HOME':str(home),
               'VELA_SESSION_ROOT':str(sessions),'VELA_DISABLE_DISCOVERY':'1',
               'GIT_CONFIG_NOSYSTEM':'1','GIT_CONFIG_GLOBAL':os.devnull}
        subprocess.run(['git','init'],cwd=project,env=env,check=True,capture_output=True)
        skill = project / '.agents/skills/review/SKILL.md'; skill.parent.mkdir(parents=True)
        original = '---\nname: review\n---\n\nReview the synthetic diff.\n'; skill.write_text(original)
        agents = project / 'AGENTS.md'; agents.write_text('# Synthetic instructions\n')
        redacted = project / '.agents/skills/secret/SKILL.md'; redacted.parent.mkdir(parents=True); redacted.write_text('api_key = synthetic-secret\n')
        unsupported = project / '.claude/settings.json'; unsupported.parent.mkdir(parents=True); unsupported.write_text('{}\n')
        # The helper's explicit --home is the isolated global catalog root.
        global_file = sessions / '.claude/CLAUDE.md'; global_file.parent.mkdir(parents=True); global_file.write_text('Global synthetic instruction\n')
        call('projects.add', {'path':str(project)}); call('projects.add', {'path':str(other)})
        scan = call('setup.scan', {'project':str(project)})
        call('setup.scan', {'scope':'global'})
        def artifact(path):
            found = [x for x in scan['artifacts'] if x.get('path') == str(path)]
            if len(found) != 1: raise AssertionError('missing synthetic artifact '+str(path))
            return found[0]
        skill_art, secret_art, unsupported_art = artifact(skill), artifact(redacted), artifact(unsupported)
        global_scan = call('setup.scan', {'scope':'global'})
        global_art = next(x for x in global_scan['artifacts'] if x.get('path') == str(global_file))
        opened = call('setup.edit.get', {'project':str(project),'artifactId':skill_art['id']})
        check('editable-project-skill', opened.get('editable') is True and opened.get('content') == original and isinstance(opened.get('sourceIdentity'),dict))
        before = source_hashes(); ev['sourceBefore'] = before
        request = {'project':str(project),'artifactId':skill_art['id'],'baseHash':opened['baseHash'],
                   'sourceIdentity':opened['sourceIdentity'],'content':original.replace('synthetic diff','reviewed synthetic diff')}
        preview = call('setup.edit.preview', request)
        check('preview-exact-and-zero-write', preview.get('before') == original and preview.get('after') == request['content'] and source_hashes() == before)
        prepared = call('setup.edit.prepare', request)
        approval = prepared['approval']; expected_keys = {'editId','artifactId','relativePath','baseHash','sourceIdentity','before','content','afterHash'}
        check('prepare-freezes-exact-arguments-and-zero-write', approval.get('tool') == 'setup.file.edit' and set(approval.get('arguments',{})) == expected_keys and approval['arguments']['content'] == request['content'] and approval['arguments']['before'] == original and source_hashes() == before)
        # Same bytes under a new inode must fail descriptor identity revalidation.
        replacement = skill.with_name('same-bytes-replacement'); replacement.write_text(original); os.replace(replacement, skill)
        stale = call('approvals.decide', {'id':approval['id'],'snapshotHash':approval['snapshotHash'],'decision':'approve'})
        check('same-byte-identity-replacement-fails-no-write', stale.get('state') == 'failed' and skill.read_text() == original)
        fresh = call('setup.edit.get', {'project':str(project),'artifactId':skill_art['id']})
        request.update({'baseHash':fresh['baseHash'],'sourceIdentity':fresh['sourceIdentity']})
        prepared = call('setup.edit.prepare', request); approval = prepared['approval']
        executed = call('approvals.decide', {'id':approval['id'],'snapshotHash':approval['snapshotHash'],'decision':'approve'})
        execution = executed.get('result') if isinstance(executed.get('result'), dict) else executed
        check('approved-exact-edit-writes-once', executed.get('state') == 'executed' and skill.read_text() == request['content'] and isinstance(execution.get('journalId'),str))
        call('approvals.decide', {'id':approval['id'],'snapshotHash':approval['snapshotHash'],'decision':'approve'}, fail=True)
        check('duplicate-decision-does-not-replay', skill.read_text() == request['content'])
        reopened = call('setup.edit.get', {'project':str(project),'artifactId':skill_art['id']})
        change = next(x for x in reopened.get('changes',[]) if x.get('journalId') == execution['journalId'])
        undone = call('setup.edit.undo', {'project':str(project),'artifactId':skill_art['id'],'journalId':change['journalId']})
        check('restart-safe-journal-undo', undone.get('state') == 'undone' and skill.read_text() == original)
        # Non-editable categories never return editable source text or approval capability.
        for name, art, reason in [('global',global_art,'global'),('redacted',secret_art,'redacted'),('unsupported',unsupported_art,'unsupported_type')]:
            row = call('setup.edit.get', {'project':str(project),'artifactId':art['id']})
            check('noneditable-'+name, row.get('editable') is False and row.get('reason') == reason and row.get('content') == '')
        call('setup.edit.get', {'project':str(other),'artifactId':skill_art['id']}, fail=True)
        call('setup.edit.get', {'project':str(project),'artifactId':'not-a-fixture-artifact'}, fail=True)
        # Replacing a known file with a hard link must never make it editable or writable.
        outside = base / 'outside.md'; outside.write_text('outside synthetic bytes\n'); skill.unlink(); os.link(outside, skill)
        linked = call('setup.edit.get', {'project':str(project),'artifactId':skill_art['id']})
        check('hardlink-is-not-editable', linked.get('editable') is False and outside.read_text() == 'outside synthetic bytes\n')
        ev['sourceAfter'] = source_hashes()
        ev['helperAfter'] = digest(helper); ev['helperCopyUnchanged'] = ev['helperAfter'] == ev['helperBefore']
        ev['passed'] = all(row['passed'] for row in ev['checks']) and ev['helperCopyUnchanged']
    except Exception as exc:
        ev['errors'].append({'type':type(exc).__name__,'message':str(exc)})
    finally:
        ev['finishedAt'] = dt.datetime.now(dt.timezone.utc).isoformat()
        try:
            if helper.exists(): ev['helperAfter'] = digest(helper); ev['helperCopyUnchanged'] = ev['helperAfter'] == ev['helperBefore']
            shutil.rmtree(base)
            ev['fixtureRemoved'] = not base.exists()
        except Exception as exc: ev['errors'].append({'type':'cleanup','message':str(exc)})
        ev['passed'] = bool(ev['passed'] and ev['fixtureRemoved'] and not ev['errors'])
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(ev,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({'passed':ev['passed'],'checks':len(ev['checks']),'errors':ev['errors'],'output':str(args.output)},ensure_ascii=False))
    raise SystemExit(0 if ev['passed'] else 1)
if __name__ == '__main__': main()
