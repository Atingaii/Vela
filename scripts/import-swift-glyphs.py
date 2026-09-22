#!/usr/bin/env python3
"""Reproduce the pinned Swift marks without tracing or redrawing vendor artwork.

Usage: python3 scripts/import-swift-glyphs.py /path/to/codenotch
Asset bytes are copied unchanged. Swift CGPoint loops become equivalent SVG paths.
"""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

PIN = "117a38b8edae2ebd0944bc86b8760c6381685345"
source = Path(sys.argv[1]).resolve()
revision = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
if revision != PIN:
    raise SystemExit(f"Expected upstream {PIN}, got {revision}")
dest = Path(__file__).resolve().parents[1] / "src-tauri/glyphs/swift"
dest.mkdir(exist_ok=True)
outline_file = source / "Sources/Providers/GlyphOutline.swift"
outlines = outline_file.read_text()
records = {}
names = {"claude": "claude", "codex": "openai", "third": "third", "cursor": "cursor",
         "gemini": "antigravity", "gemini-api": "gemini", "grok": "grok", "kiro": "kiro", "copilot": "copilot"}
for identifier, name in names.items():
    match = re.search(r"static let " + name + r": \[\[CGPoint\]\] = \[(.*?)(?=\n    (?:static|///)|\n})", outlines, re.S)
    if not match:
        raise SystemExit(f"Missing outline: {name}")
    paths = []
    for loop in re.findall(r"\[([^\[\]]*CGPoint[^\[\]]*)\]", match[1]):
        points = re.findall(r"CGPoint\(x: ([\d.-]+), y: ([\d.-]+)\)", loop)
        if points:
            paths.append("M" + " L".join(f"{x} {y}" for x, y in points) + "Z")
    if not paths:
        raise SystemExit(f"Empty outline: {name}")
    output = dest / f"{identifier}.svg"
    output.write_text('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1" fill="currentColor" fill-rule="evenodd"><path d="' + " ".join(paths) + '"/></svg>\n')
    records[output.name] = {"source": str(outline_file.relative_to(source)), "outline": name}
for asset in sorted((source / "Sources/Assets.xcassets").glob("glyph-*.imageset/*")):
    if asset.suffix not in (".svg", ".png"):
        continue
    output = dest / (asset.parent.name.removeprefix("glyph-").removesuffix(".imageset") + asset.suffix)
    output.write_bytes(asset.read_bytes())
    records[output.name] = {"source": str(asset.relative_to(source))}
for filename, record in records.items():
    record["sha256"] = hashlib.sha256((dest / filename).read_bytes()).hexdigest()
(dest / "manifest.json").write_text(json.dumps({"repository": "https://github.com/vinzdg/codenotch", "revision": PIN, "files": records}, indent=2) + "\n")
