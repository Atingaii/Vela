#!/usr/bin/env python3
"""Attach content versions to local HTML assets, without duplicate build files."""
from hashlib import sha256
from pathlib import Path
import re
from urllib.parse import urlsplit, urlunsplit, parse_qsl, urlencode

DIST = Path(__file__).resolve().parents[1] / "website" / "dist"
ASSET = re.compile(r'\b(src|href)="([^"\s]+)"')


def version_assets():
    changed = 0
    for page in sorted(DIST.rglob("*.html")):
        def replace(match):
            attribute, url = match.groups()
            parts = urlsplit(url)
            if parts.scheme or parts.netloc or not parts.path:
                return match[0]
            target = ((DIST / parts.path.lstrip("/")) if parts.path.startswith("/") else (page.parent / parts.path)).resolve()
            if not target.is_relative_to(DIST) or target.suffix not in {".css", ".js", ".png", ".svg", ".woff2"}:
                return match[0]
            if not target.is_file():
                raise ValueError(f"Missing local asset in {page}: {parts.path}")
            query = [(k, v) for k, v in parse_qsl(parts.query) if k != "v"]
            query.append(("v", sha256(target.read_bytes()).hexdigest()[:16]))
            return f'{attribute}="{urlunsplit(parts._replace(query=urlencode(query)))}"'

        before = page.read_text()
        after = ASSET.sub(replace, before)
        if before != after:
            page.write_text(after)
            changed += 1
    return changed


if __name__ == "__main__":
    print(f"Updated content versions in {version_assets()} pages")
