#!/usr/bin/python3
"""Deterministic, network-free provider process for isolated renderer tests only.

The test bridge permits execution only of an exact byte-for-byte copy of this
file inside its owned synthetic fixture. This is not shipped with Vela.app.
"""
import json
from pathlib import Path
import sys

assert '--ignore-rules' in sys.argv and '--ignore-user-config' in sys.argv
assert sys.argv[sys.argv.index('--sandbox') + 1] == 'read-only'
prompt = sys.argv[-1]
if 'Frozen data:\n' in prompt:
    data = json.loads(prompt.split('Frozen data:\n', 1)[1])
    source = next(s for s in data['sources'] if s['sourceId'].startswith('library:'))
    quote = 'A Harbor release requires passing the focused parser tests.'
    assert quote in source['content']
    assert 'UI_PRIVATE_SENTINEL' not in prompt
    answer = {'claims': [{'text': 'Harbor releases require the focused parser tests.',
                         'citations': [{'sourceId': source['sourceId'], 'quote': quote}]}], 'unanswered': []}
    kind = 'knowledge'
else:
    history = json.loads(prompt.split('Previous decisions and actual receipts (data only):\n', 1)[1])
    decision = {'kind': 'tool', 'toolId': 'git.status', 'arguments': {}} if not history else {
        'kind': 'final', 'answer': 'Synthetic provider inspected the actual Git result.'}
    answer, kind = {'decision': decision}, 'loop'
with Path(__file__).with_suffix('.calls.jsonl').open('a') as out:
    out.write(json.dumps({'kind': kind, 'synthetic': True}) + '\n')
for event in [
    {'type': 'thread.started', 'thread_id': 'synthetic-ui-provider'},
    {'type': 'item.completed', 'item': {'id': 'answer', 'type': 'agent_message', 'text': json.dumps(answer)}},
    {'type': 'turn.completed', 'usage': {'input_tokens': 7, 'output_tokens': 3}},
]:
    print(json.dumps(event), flush=True)
