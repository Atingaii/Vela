"""Compile a test-only native entrypoint with an embedded synthetic Python body.

The generated program execs the caller's Python interpreter with embedded code;
only test files import this helper. No runtime bypass or product allowlist exists.
"""
import json
from pathlib import Path
import subprocess
import sys


def compile_provider(target: Path, body: str):
    target = target.resolve()
    source = target.with_name(target.name + '.fixture.c')
    source.write_text('''#include <unistd.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    char **args = calloc((size_t)argc + 3, sizeof(char *));
    if (!args) return 120;
    args[0] = ''' + json.dumps(sys.executable) + ''';
    args[1] = "-c";
    args[2] = ''' + json.dumps(body, ensure_ascii=False) + ''';
    for (int i = 1; i < argc; i++) args[i + 2] = argv[i];
    execv(args[0], args);
    return 121;
}
''')
    try:
        subprocess.run(['/usr/bin/clang', '-Os', str(source), '-o', str(target)], check=True, capture_output=True)
        target.chmod(0o700)
    finally:
        source.unlink(missing_ok=True)
