"""Attack actual RPC/MCP framing in isolated stores, including unclosed giant input.

Run after swift build. No user stores, agent discovery, or actual agent commands.
RSS samples bound this fixture's observed growth; they are not a full memory budget.
"""
import argparse
import hashlib
import json
import os
import pathlib
import select
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--binary', type=pathlib.Path, default=ROOT / '.build/debug/vela',
                    help='Use an explicitly selected, already built helper')
BINARY = parser.parse_args().binary.resolve()
LIMIT = 2_000_000
RSS_ALLOWANCE_KIB = 32 * 1024
assert BINARY.is_file(), 'Run swift build first'


class Endpoint:
    def __init__(self, home, mode):
        env = dict(os.environ, VELA_DISABLE_DISCOVERY='1')
        env.pop('VELA_SESSION_ROOT', None)
        self.mode = mode
        self.pending = bytearray()
        self.process = subprocess.Popen(
            [str(BINARY), mode, '--home', str(home), '--no-watch', '--no-schedule'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            bufsize=0, env=env)

    def frame(self, identifier, *, note=None, padding=None):
        params = {}
        if note is not None:
            params['note'] = note
        if padding is not None:
            params['padding'] = padding
        value = {'id': identifier, 'method': 'ping' if self.mode == 'mcp' else 'system.version', 'params': params}
        if self.mode == 'mcp':
            value['jsonrpc'] = '2.0'
            # Ping accepts only protocol metadata, which has its own small bound.
            # Use legal JSON whitespace for frame-sized padding, not tool args or
            # oversized metadata. Ping is valid before MCP initialization.
            value['params'] = {'_meta': {'ai.vela/framing': {'note': note}}} if note is not None else {}
        encoded = json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode()
        if self.mode == 'mcp' and padding:
            encoded = encoded[:-1] + b' ' * len(padding.encode()) + encoded[-1:]
        return encoded

    def write(self, data):
        remaining = memoryview(data)
        while remaining:
            written = self.process.stdin.write(remaining)
            assert written, 'Child stopped reading input'
            remaining = remaining[written:]

    def response(self, timeout=5):
        deadline = time.monotonic() + timeout
        while b'\n' not in self.pending:
            available = max(0, deadline - time.monotonic())
            assert available and select.select([self.process.stdout], [], [], available)[0], 'Response timed out'
            chunk = os.read(self.process.stdout.fileno(), 65536)
            assert chunk, 'Child exited before a response'
            self.pending.extend(chunk)
            assert len(self.pending) < 4 * 1024 * 1024, 'Unexpectedly large response'
        line, _, rest = self.pending.partition(b'\n')
        self.pending = bytearray(rest)
        result = json.loads(line)
        if self.mode == 'mcp':
            assert result.get('jsonrpc') == '2.0', result
        return result

    def successful(self, identifier):
        result = self.response()
        assert result.get('id') == identifier and 'result' in result and 'error' not in result, result

    def oversized(self):
        result = self.response()
        assert 'error' in result and '2 MB' in result['error']['message'], result
        if self.mode == 'mcp':
            assert result.get('id') is None and result['error']['code'] == -32600, result

    def rss(self):
        result = subprocess.run(['ps', '-o', 'rss=', '-p', str(self.process.pid)], capture_output=True, text=True, check=True)
        return int(result.stdout.strip())

    def finish(self):
        self.process.stdin.close()
        assert self.process.wait(timeout=10) == 0, self.process.stderr.read().decode(errors='replace')
        assert not self.pending and not self.process.stdout.read(), 'Unexpected extra frame'

    def cleanup(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            stream.close()


measurements = []
with tempfile.TemporaryDirectory(prefix='vela-rpc-limits-') as temporary:
    for mode in ('rpc', 'mcp'):
        endpoint = Endpoint(pathlib.Path(temporary) / mode, mode)
        try:
            # Split multibyte UTF-8 across individual writes.
            for byte in endpoint.frame(1, note='分段帧') + b'\r\n':
                endpoint.write(bytes([byte]))
            endpoint.successful(1)

            # Multiple frames may share a single OS read; replies can be reordered.
            endpoint.write(endpoint.frame(2) + b'\n' + endpoint.frame(3) + b'\n')
            replies = [endpoint.response(), endpoint.response()]
            assert {reply.get('id') for reply in replies} == {2, 3}
            assert all('result' in reply and 'error' not in reply for reply in replies)

            endpoint.write(b'{broken}\n' + endpoint.frame(4) + b'\n')
            replies = [endpoint.response(), endpoint.response()]
            errors = [reply for reply in replies if 'error' in reply]
            assert len(errors) == 1 and any(reply.get('id') == 4 and 'result' in reply for reply in replies)
            if mode == 'mcp':
                assert errors[0].get('id') is None and errors[0]['error']['code'] == -32700, errors

            # Exactly the existing 2,000,000-byte payload limit, with CRLF.
            empty = endpoint.frame(5, padding='')
            near_limit = endpoint.frame(5, padding='x' * (LIMIT - len(empty)))
            assert len(near_limit) == LIMIT
            endpoint.write(near_limit + b'\r\n')
            endpoint.successful(5)

            baseline_rss = endpoint.rss()
            peak_rss = baseline_rss
            # Refusal must happen before a newline or EOF arrives.
            endpoint.write(b'x' * (LIMIT + 1))
            endpoint.oversized()
            peak_rss = max(peak_rss, endpoint.rss())
            # Continue the SAME refused line for 64 MiB, sampling during draining.
            block = b'x' * (64 * 1024)
            for index in range(1024):
                endpoint.write(block)
                if index % 16 == 0:
                    peak_rss = max(peak_rss, endpoint.rss())
            assert not endpoint.pending and not select.select([endpoint.process.stdout], [], [], 0.05)[0], 'Oversized frame must report once'
            endpoint.write(b'\n' + endpoint.frame(6) + b'\n')
            endpoint.successful(6)
            growth = peak_rss - baseline_rss
            assert growth < RSS_ALLOWANCE_KIB, f'{mode}: giant-frame RSS growth {growth} KiB exceeds fixture allowance'
            measurements.append({'mode': mode, 'oversizedContinuationMiB': 64, 'baselineRssKiB': baseline_rss, 'sampledPeakRssKiB': peak_rss, 'sampledGrowthKiB': growth, 'growthAllowanceKiB': RSS_ALLOWANCE_KIB})

            # EOF flushes a final bounded frame even without its trailing newline.
            endpoint.write(endpoint.frame(7))
            endpoint.process.stdin.close()
            endpoint.successful(7)
            endpoint.finish()
        finally:
            endpoint.cleanup()

        # EOF during draining does not emit a second error or turn it into a frame.
        endpoint = Endpoint(pathlib.Path(temporary) / (mode + '-overflow-eof'), mode)
        try:
            endpoint.write(b'x' * (LIMIT + 1))
            endpoint.oversized()
            endpoint.finish()
        finally:
            endpoint.cleanup()

print(json.dumps({
    'status': 'passed', 'byteLimit': LIMIT,
    'binary': str(BINARY), 'binarySHA256': hashlib.sha256(BINARY.read_bytes()).hexdigest(),
    'scriptSHA256': hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),
    'scenariosPerMode': [
        'split UTF-8, coalesced frames, malformed recovery, exact-limit CRLF and bounded EOF',
        'unclosed oversized frame, 64 MiB drain, single rejection, RSS bound and recovery',
        'EOF while draining without a duplicate rejection',
    ],
    'measurements': measurements,
}, indent=2))
