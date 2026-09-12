"""Lightweight public-repository and static-site correctness checks."""
import pathlib, subprocess, re, sys
from html.parser import HTMLParser

root = pathlib.Path(__file__).resolve().parents[1]
required = ['README.md','README.zh-CN.md','LICENSE','CONTRIBUTING.md','SECURITY.md','CODE_OF_CONDUCT.md','CHANGELOG.md','docs/status.md','docs/architecture.md']
required += ['website/dist/index.html','website/dist/docs.html','website/dist/privacy.html','website/dist/releases.html']
errors = [f'Missing {name}' for name in required if not (root/name).is_file()]
for directory in ['Sources/VelaApp/Resources','website/dist']:
    for p in (root/directory).rglob('*.js'):
        result = subprocess.run(['node','--check',str(p)],capture_output=True,text=True)
        if result.returncode:
            errors.append(result.stderr)

class References(HTMLParser):
    def __init__(self):
        super().__init__(); self.refs=[]
    def handle_starttag(self, tag, attrs):
        for key,value in attrs:
            if key in ('src','href') and value:
                self.refs.append(value)

site = root/'website/dist'
for p in site.rglob('*.html'):
    parser=References(); parser.feed(p.read_text())
    for value in parser.refs:
        if re.match(r'^(https?:|data:|mailto:|tel:|#|vela:)',value):
            continue
        path=value.split('#',1)[0].split('?',1)[0]
        if not path:
            continue
        target=(site/path.lstrip('/')) if path.startswith('/') else p.parent/path
        if not target.exists():
            errors.append(f'{p.relative_to(root)}: broken reference {value}')
tracked = subprocess.run(['git','ls-files'],cwd=root,capture_output=True,text=True,check=True).stdout.splitlines()
for name in tracked:
    if any(part in {'.build','node_modules','.task-tmp'} for part in pathlib.PurePosixPath(name).parts) or name.endswith(('.sqlite3','.pem','.key')):
        errors.append(f'Unexpected tracked private/build artifact: {name}')
if errors:
    print('\n'.join(errors),file=sys.stderr);sys.exit(1)
print('Repository and static asset checks passed')
