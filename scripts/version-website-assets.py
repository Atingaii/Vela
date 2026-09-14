#!/usr/bin/env python3
"""Attach content versions to local HTML assets, without duplicate build files."""
from hashlib import sha256
from pathlib import Path
import re
from urllib.parse import urlsplit, urlunsplit, parse_qsl, urlencode

DIST = Path(__file__).resolve().parents[1] / "website" / "dist"
ASSET = re.compile(r'\b(src|href)="([^"\s]+)"')
CSS_ASSET = re.compile(r'url\(\s*([\'\"]?)([^\'\"\)\s]+)\1\s*\)')


def version_url(source, url, extensions):
    parts = urlsplit(url)
    if parts.scheme or parts.netloc or not parts.path:
        return url
    target = ((DIST / parts.path.lstrip("/")) if parts.path.startswith("/") else (source.parent / parts.path)).resolve()
    if not target.is_relative_to(DIST) or target.suffix not in extensions:
        return url
    if not target.is_file():
        raise ValueError(f"Missing local asset in {source}: {parts.path}")
    query = [(k, v) for k, v in parse_qsl(parts.query) if k != "v"]
    query.append(("v", sha256(target.read_bytes()).hexdigest()[:16]))
    return urlunsplit(parts._replace(query=urlencode(query)))


def version_assets():
    changed = 0
    # Font preloads and @font-face must share a URL to avoid downloading twice.
    # Only leaf assets are versioned here, so stylesheet digests cannot cycle.
    for stylesheet in sorted(DIST.rglob("*.css")):
        before = stylesheet.read_text()
        after = CSS_ASSET.sub(lambda m: 'url("' + version_url(stylesheet, m[2], {".woff2", ".png", ".svg"}) + '")', before)
        if before != after:
            stylesheet.write_text(after)
            changed += 1
    for page in sorted(DIST.rglob("*.html")):
        def replace(match):
            attribute, url = match.groups()
            return f'{attribute}="{version_url(page, url, {".css", ".js", ".png", ".svg", ".woff2"})}"'

        before = page.read_text()
        after = ASSET.sub(replace, before)
        if before != after:
            page.write_text(after)
            changed += 1
    return changed


if __name__ == "__main__":
    print(f"Updated content versions in {version_assets()} files")
