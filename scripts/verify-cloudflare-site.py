#!/usr/bin/env python3
"""Bounded HTTP acceptance check for the deployed static Vela site.

The checker uses the repository's ``website/dist`` pages as an explicit expected
route/metadata inventory.  It does not execute JavaScript or deploy anything.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import html
import json
import re
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from html.parser import HTMLParser
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urljoin, urlsplit, urlunsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

ROOT = Path(__file__).resolve().parents[1]
PRODUCTION_ORIGIN = "https://velo.codes"
LEGACY_ORIGINS = ("vela-engineering.zzzsssaa.chatgpt.site",)
MAX_BYTES = 8 * 1024 * 1024
TIMEOUT_SECONDS = 15
WORKERS = 4
CSS_URL = re.compile(r"url\(\s*(['\"]?)([^'\")\s]+)\1\s*\)", re.I)


@dataclass
class PageSource:
    path: Path
    route: str
    title: str
    lang: str
    canonical: str
    alternates: dict[str, str]
    resources: list[str]
    navigation: list[str]


class SourceHTML(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.lang = ""
        self.title_parts: list[str] = []
        self.in_title = False
        self.canonical = ""
        self.alternates: dict[str, str] = {}
        self.resources: list[str] = []
        self.navigation: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = {key.lower(): value for key, value in attrs}
        if tag == "html":
            self.lang = values.get("lang") or ""
        if tag == "title":
            self.in_title = True
        if tag == "a" and values.get("href"):
            self.navigation.append(values["href"] or "")
        if tag in {"img", "script", "source", "video", "audio"} and values.get("src"):
            self.resources.append(values["src"] or "")
        if tag == "link" and values.get("href"):
            rel = set((values.get("rel") or "").lower().split())
            href = values["href"] or ""
            if "canonical" in rel:
                self.canonical = href
            elif "alternate" in rel and values.get("hreflang"):
                self.alternates[values["hreflang"] or ""] = href
            elif rel & {"stylesheet", "icon", "preload"}:
                self.resources.append(href)

    def handle_endtag(self, tag: str) -> None:
        if tag == "title":
            self.in_title = False

    def handle_data(self, data: str) -> None:
        if self.in_title:
            self.title_parts.append(data)

    @property
    def title(self) -> str:
        return "".join(self.title_parts).strip()


def normal_origin(value: str) -> str:
    parts = urlsplit(value)
    if parts.scheme not in {"http", "https"} or not parts.netloc or parts.path not in {"", "/"} or parts.query or parts.fragment:
        raise ValueError("origin must be an http(s) scheme and host without path, query, or fragment")
    if parts.username or parts.password:
        raise ValueError("origin must not include user credentials")
    if parts.scheme == "http" and (parts.hostname or "").lower() not in {"localhost", "127.0.0.1", "::1"}:
        raise ValueError("http is permitted only for localhost/loopback test origins")
    return urlunsplit((parts.scheme, parts.netloc, "", "", ""))


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def source_inventory(site_root: Path, pages: list[PageSource]) -> dict:
    page_paths = {page.path.resolve() for page in pages}
    page_records = []
    asset_records = []
    for path in sorted(candidate for candidate in site_root.rglob("*") if candidate.is_file()):
        record = {
            "path": path.relative_to(site_root).as_posix(),
            "bytes": path.stat().st_size,
            "sha256": sha256_file(path),
        }
        (page_records if path.resolve() in page_paths else asset_records).append(record)
    all_records = page_records + asset_records
    aggregate = hashlib.sha256(json.dumps(all_records, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()
    return {
        "root": str(site_root),
        "pageCount": len(page_records),
        "assetCount": len(asset_records),
        "expectedPageCount": 32,
        "aggregateSHA256": aggregate,
        "pages": page_records,
        "assets": asset_records,
    }


def is_exact_production_url(value: str) -> bool:
    parts = urlsplit(value)
    return parts.scheme == "https" and parts.netloc == "velo.codes"


def expected_route(site_root: Path, page: Path) -> str:
    relative = page.relative_to(site_root).as_posix()
    if relative == "index.html":
        return "/"
    if relative.endswith("/index.html"):
        return "/" + relative[: -len("index.html")]
    return "/" + relative


def parse_source(site_root: Path) -> tuple[list[PageSource], list[str]]:
    pages: list[PageSource] = []
    errors: list[str] = []
    for path in sorted(site_root.rglob("*.html")):
        parser = SourceHTML()
        parser.feed(path.read_text(encoding="utf-8"))
        route = expected_route(site_root, path)
        missing = []
        if not parser.title:
            missing.append("title")
        if not parser.lang:
            missing.append("html lang")
        if not parser.canonical:
            missing.append("canonical")
        elif not is_exact_production_url(parser.canonical):
            missing.append("canonical production origin")
        for language in ("zh-CN", "en", "x-default"):
            alternate = parser.alternates.get(language)
            if alternate is None:
                missing.append(f"alternate:{language}")
            elif not is_exact_production_url(alternate):
                missing.append(f"alternate:{language} production origin")
        if missing:
            errors.append(f"{path.relative_to(site_root)} missing or invalid {', '.join(missing)}")
        pages.append(PageSource(path, route, parser.title, parser.lang, parser.canonical, parser.alternates, parser.resources, parser.navigation))
    return pages, errors


def is_ignored_reference(value: str) -> bool:
    return not value or value.startswith(("#", "mailto:", "tel:", "javascript:", "data:"))


def reference_url(origin: str, route: str, value: str) -> tuple[str | None, str | None]:
    """Return an active-origin URL or a reason why a nonlocal reference is ignored."""
    if is_ignored_reference(value):
        return None, "ignored"
    parts = urlsplit(value)
    active = urlsplit(origin)
    production = urlsplit(PRODUCTION_ORIGIN)
    if parts.scheme and parts.scheme not in {"http", "https"}:
        return None, "ignored"
    if parts.netloc:
        if (parts.hostname or "").lower() not in {(active.hostname or "").lower(), (production.hostname or "").lower()}:
            return None, "external"
        # Absolute production URLs remain local-site links when the verifier is
        # pointed at a localhost fixture.
        return urlunsplit((active.scheme, active.netloc, parts.path or "/", parts.query, parts.fragment)), None
    base = urljoin(origin + route, ".") if route.endswith("/") else origin + route
    return urljoin(base, value), None


def expected_final_paths(path: str) -> set[str]:
    """Pages may redirect ``foo.html`` to Pages' extensionless ``/foo`` form."""
    result = {path or "/"}
    if path.endswith(".html"):
        result.add(path[: -len(".html")] or "/")
    if path.endswith("/index.html"):
        result.add(path[: -len("index.html")])
    normalized = set()
    for item in result:
        normalized.add(item)
        if item != "/" and item.endswith("/"):
            normalized.add(item[:-1])
        elif item != "/":
            normalized.add(item + "/")
    return normalized


class SameOriginRedirect(HTTPRedirectHandler):
    def __init__(self, origin: str) -> None:
        super().__init__()
        self.origin = urlsplit(origin)
        self.chain: list[str] = []

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # type: ignore[no-untyped-def]
        absolute = urljoin(req.full_url, newurl)
        candidate = urlsplit(absolute)
        if (candidate.scheme, candidate.netloc) != (self.origin.scheme, self.origin.netloc):
            raise URLError(f"redirect leaves requested origin: {absolute}")
        self.chain.append(absolute)
        return super().redirect_request(req, fp, code, msg, headers, absolute)


def content_type_ok(kind: str, content_type: str) -> bool:
    mime = content_type.split(";", 1)[0].lower().strip()
    if kind == "html":
        return mime in {"text/html", "application/xhtml+xml"}
    if kind == "css":
        return mime == "text/css"
    if kind == "js":
        return mime in {"application/javascript", "text/javascript", "application/ecmascript", "text/ecmascript"}
    if kind == "image":
        return mime.startswith("image/")
    if kind == "font":
        return mime.startswith("font/") or mime in {"application/font-woff", "application/font-sfnt", "application/octet-stream"}
    return bool(mime)


def resource_kind(path: str) -> str:
    suffix = Path(urlsplit(path).path).suffix.lower()
    if suffix == ".css":
        return "css"
    if suffix in {".js", ".mjs"}:
        return "js"
    if suffix in {".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".avif", ".ico"}:
        return "image"
    if suffix in {".woff", ".woff2", ".ttf", ".otf", ".eot"}:
        return "font"
    return "resource"


def read_response(url: str, origin: str, kind: str) -> dict:
    started = time.monotonic()
    redirect = SameOriginRedirect(origin)
    opener = build_opener(redirect)
    request = Request(url, headers={"User-Agent": "Vela-Cloudflare-Verification/1"})
    result: dict = {"url": url, "kind": kind}
    try:
        with opener.open(request, timeout=TIMEOUT_SECONDS) as response:
            content_length = response.headers.get("Content-Length")
            if content_length is not None and int(content_length) > MAX_BYTES:
                raise ValueError(f"content-length exceeds {MAX_BYTES} bytes")
            body = bytearray()
            while True:
                part = response.read(min(65536, MAX_BYTES + 1 - len(body)))
                if not part:
                    break
                body.extend(part)
                if len(body) > MAX_BYTES:
                    raise ValueError(f"response exceeds {MAX_BYTES} bytes")
            final_url = response.geturl()
            final = urlsplit(final_url)
            requested = urlsplit(origin)
            if (final.scheme, final.netloc) != (requested.scheme, requested.netloc):
                raise ValueError(f"final URL leaves requested origin: {final_url}")
            content_type = response.headers.get("Content-Type", "")
            result.update({
                "status": response.status,
                "finalURL": final_url,
                "redirects": redirect.chain,
                "contentType": content_type,
                "contentTypeValid": content_type_ok(kind, content_type),
                "bytes": len(body),
                "bodySHA256": hashlib.sha256(body).hexdigest(),
                "responseHeaders": dict(response.headers.items()),
                "body": bytes(body) if kind in {"html", "css"} else b"",
            })
    except (HTTPError, URLError, OSError, TimeoutError, ValueError) as error:
        result["error"] = f"{type(error).__name__}: {error}"
    finally:
        result["elapsedMs"] = round((time.monotonic() - started) * 1000, 2)
    return result


def check_page(response: dict, expected: PageSource) -> dict:
    checks: dict[str, object] = {
        "status200": response.get("status") == 200,
        "contentType": response.get("contentTypeValid") is True,
    }
    if "body" not in response:
        checks.update({"title": False, "lang": False, "canonical": False, "alternates": False, "noLegacyOrigin": False, "finalRoute": False})
        return checks
    parser = SourceHTML()
    body_text = response["body"].decode("utf-8", "replace")
    parser.feed(body_text)
    checks["title"] = parser.title == expected.title
    checks["lang"] = parser.lang == expected.lang
    checks["canonical"] = parser.canonical == expected.canonical and is_exact_production_url(parser.canonical)
    checks["alternates"] = parser.alternates == expected.alternates and all(is_exact_production_url(value) for value in parser.alternates.values())
    checks["noLegacyOrigin"] = not any(old in body_text.lower() for old in LEGACY_ORIGINS)
    final_path = urlsplit(response.get("finalURL", "")).path or "/"
    checks["finalRoute"] = final_path in expected_final_paths(urlsplit(expected.canonical).path)
    checks["observed"] = {"title": parser.title, "lang": parser.lang, "canonical": parser.canonical, "alternates": parser.alternates}
    return checks


def local_path(site_root: Path, source_page: PageSource, ref: str) -> Path | None:
    parts = urlsplit(ref)
    if parts.scheme or parts.netloc or not parts.path:
        return None
    candidate = (site_root / parts.path.lstrip("/")) if parts.path.startswith("/") else (source_page.path.parent / parts.path)
    candidate = candidate.resolve()
    try:
        candidate.relative_to(site_root.resolve())
    except ValueError:
        return None
    if candidate.is_dir():
        candidate = candidate / "index.html"
    return candidate


def build_targets(site_root: Path, origin: str, pages: list[PageSource]) -> tuple[list[tuple[str, str, str]], list[str]]:
    targets: dict[tuple[str, str], tuple[str, str, str]] = {}
    errors: list[str] = []
    css_files: list[tuple[PageSource, str]] = []
    for page in pages:
        page_url = urljoin(origin + "/", page.route.lstrip("/"))
        targets[(page_url, "html")] = (page_url, "html", f"page:{page.path.relative_to(site_root)}")
        for ref in page.resources:
            local = local_path(site_root, page, ref)
            if local is None:
                continue
            if not local.is_file():
                errors.append(f"missing local resource {ref} from {page.path.relative_to(site_root)}")
                continue
            url, reason = reference_url(origin, page.route, ref)
            if reason is None and url:
                kind = resource_kind(url)
                targets[(urlsplit(url)._replace(fragment="").geturl(), kind)] = (urlsplit(url)._replace(fragment="").geturl(), kind, f"resource:{page.path.relative_to(site_root)}")
                if kind == "css":
                    css_files.append((page, ref))
        for ref in page.navigation:
            url, reason = reference_url(origin, page.route, ref)
            if reason in {"ignored", "external"}:
                continue
            if url is None:
                errors.append(f"invalid navigation {ref} from {page.path.relative_to(site_root)}")
                continue
            url = urlsplit(url)._replace(fragment="").geturl()
            targets[(url, "navigation")] = (url, "navigation", f"navigation:{page.path.relative_to(site_root)}")
    # CSS references are verified from source files, recursively one level at a
    # time; CSS assets can themselves import another CSS file.
    seen_css: set[Path] = set()
    pending = css_files
    while pending:
        page, ref = pending.pop()
        css_path = local_path(site_root, page, ref)
        if css_path is None or css_path in seen_css:
            continue
        seen_css.add(css_path)
        text = css_path.read_text(encoding="utf-8")
        pseudo = PageSource(css_path, expected_route(site_root, css_path), "", "", "", {}, [], [])
        for match in CSS_URL.finditer(text):
            css_ref = html.unescape(match.group(2))
            if is_ignored_reference(css_ref):
                continue
            local = local_path(site_root, pseudo, css_ref)
            if local is None:
                continue
            if not local.is_file():
                errors.append(f"missing CSS resource {css_ref} from {css_path.relative_to(site_root)}")
                continue
            url, reason = reference_url(origin, pseudo.route, css_ref)
            if reason is None and url:
                url = urlsplit(url)._replace(fragment="").geturl()
                kind = resource_kind(url)
                targets[(url, kind)] = (url, kind, f"css:{css_path.relative_to(site_root)}")
                if kind == "css":
                    pending.append((pseudo, css_ref))
    return sorted(targets.values(), key=lambda item: (item[1], item[0])), errors


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify deployed Vela static-site routes and local assets over HTTP.")
    parser.add_argument("--origin", default=PRODUCTION_ORIGIN, help="Production HTTPS origin, or localhost HTTP origin for an isolated test")
    parser.add_argument("--output", type=Path, required=True, help="New JSON receipt path")
    parser.add_argument("--site-root", type=Path, default=ROOT / "website/dist", help="Local static source inventory (default: website/dist)")
    args = parser.parse_args()
    try:
        origin = normal_origin(args.origin)
    except ValueError as error:
        parser.error(str(error))
    output = args.output.resolve()
    if output.exists():
        parser.error("--output must be a new path; refusing to overwrite evidence")
    site_root = args.site_root.resolve()
    if not site_root.is_dir():
        parser.error(f"site root does not exist: {site_root}")
    pages, source_errors = parse_source(site_root)
    source_before = source_inventory(site_root, pages)
    targets, target_errors = build_targets(site_root, origin, pages)
    evidence: dict = {
        "format": "vela-cloudflare-site-verification-v1",
        "startedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "origin": origin,
        "productionCanonicalOrigin": PRODUCTION_ORIGIN,
        "limits": {"timeoutSeconds": TIMEOUT_SECONDS, "maxBytes": MAX_BYTES, "maxConcurrency": WORKERS},
        "sourceInventory": source_before,
        "sourceErrors": source_errors + target_errors,
        "pages": [],
        "resources": [],
        "navigation": [],
        "errors": [],
    }
    page_by_url = {urljoin(origin + "/", page.route.lstrip("/")): page for page in pages}
    def fetch(target: tuple[str, str, str]) -> tuple[tuple[str, str, str], dict]:
        return target, read_response(target[0], origin, "html" if target[1] in {"html", "navigation"} else target[1])

    with concurrent.futures.ThreadPoolExecutor(max_workers=WORKERS) as executor:
        futures = [executor.submit(fetch, target) for target in targets]
        for future in concurrent.futures.as_completed(futures):
            target, response = future.result()
            url, kind, _source = target
            if kind == "html":
                expected = page_by_url[url]
                checks = check_page(response, expected)
                response.pop("body", None)
                response["checks"] = checks
                response["expected"] = {"route": expected.route, "title": expected.title, "lang": expected.lang, "canonical": expected.canonical, "alternates": expected.alternates}
                evidence["pages"].append(response)
            elif kind == "navigation":
                response.pop("body", None)
                response["checks"] = {"status200": response.get("status") == 200, "contentType": response.get("contentTypeValid") is True}
                evidence["navigation"].append(response)
            else:
                response.pop("body", None)
                response["checks"] = {"status200": response.get("status") == 200, "contentType": response.get("contentTypeValid") is True}
                evidence["resources"].append(response)
    for group in ("pages", "resources", "navigation"):
        evidence[group].sort(key=lambda item: item["url"])
    records = [record for group in ("pages", "resources", "navigation") for record in evidence[group]]
    bad = []
    for record in records:
        failed = [name for name, value in record.get("checks", {}).items() if name != "observed" and value is not True]
        if failed:
            bad.append({"url": record["url"], "failedChecks": failed, "error": record.get("error")})
    source_after = source_inventory(site_root, pages)
    evidence["sourceInventoryAfter"] = source_after
    source_unchanged = source_before["aggregateSHA256"] == source_after["aggregateSHA256"]
    if not source_unchanged:
        bad.append({"sourceInventory": "changed while HTTP verification ran"})
    evidence["errors"] = evidence["sourceErrors"] + bad
    evidence["summary"] = {"pageCount": len(evidence["pages"]), "resourceCount": len(evidence["resources"]), "navigationCount": len(evidence["navigation"]), "failedRecordCount": len(bad), "sourceUnchanged": source_unchanged, "transport": "HTTP only; no browser executed", "passed": len(pages) == 32 and not evidence["sourceErrors"] and not bad}
    evidence["finishedAt"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return 0 if evidence["summary"]["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
