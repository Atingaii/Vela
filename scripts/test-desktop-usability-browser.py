#!/usr/bin/env python3
"""Real-bridge browser regression for the desktop usability refactor.

This runner creates a new synthetic Harbor/Beacon store through the real CLI,
freezes the supplied UI/helper into it, and drives only the local test bridge.
It does not execute a provider or native UI. One exact-wire check approves a
synthetic fixture-only ``file.write`` and verifies its exact output; no external
provider, account, or user project is used. The UI must implement the selector
contract in ``output/parity/desktop-usability-...json``;
missing selectors are a deliberate failing acceptance result, never a mock pass.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import importlib.util
import json
import os
from pathlib import Path
from release_resources import DEVELOPMENT_UI_RESOURCES, UI_RESOURCES, copy_ui_resources
import select
import shutil
import signal
import subprocess
import sys
import time
import traceback
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
UI_FILES = UI_RESOURCES + DEVELOPMENT_UI_RESOURCES
CHECKS = (
    "selector-contract",
    "asset-path-does-not-overflow",
    "approval-disclosure-and-frozen-wire",
    "expired-decision-refreshes-authoritative-list",
    "late-project-response-cannot-cross-scope",
    "locale-large-type-narrow-window",
)
SELECTORS = {
    "assetList": "#asset-list",
    "assetRow": '[data-testid="asset-row"]',
    "assetLocation": '[data-testid="asset-location"]',
    "approvalList": "#approval-list",
    "approvalCard": '[data-testid="approval-card"]',
    "approvalImpact": '[data-testid="approval-impact"]',
    "approvalTechnicalDetails": '[data-testid="approval-technical-details"]',
    "approvalRaw": '[data-testid="approval-raw-json"]',
    "approvalProjectPath": '[data-testid="approval-full-project-path"]',
    "approvalSnapshotHash": '[data-testid="approval-snapshot-hash"]',
    "approvalApprove": '[data-testid="approval-approve"]',
    "toast": '[data-testid="toast"]',
}


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def stop(process: subprocess.Popen | None) -> None:
    if process is None or process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=5)
    except (ProcessLookupError, subprocess.TimeoutExpired):
        try:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)
        except ProcessLookupError:
            pass


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ui-directory", type=Path, required=True, help="Frozen AGY UI directory")
    parser.add_argument("--binary", type=Path, required=True, help="Trusted existing vela helper")
    parser.add_argument("--fixture", type=Path, required=True, help="New immediate .task-tmp child")
    parser.add_argument("--output", type=Path, required=True, help="New immediate output/playwright child")
    parser.add_argument("--browser-executable", type=Path, required=True)
    parser.add_argument("--playwright-module", type=Path,
                        default=ROOT / ".task-tmp/ui-browser-tools/node_modules/playwright/index.js")
    parser.add_argument("--checks", help="Comma-separated diagnostic subset; omit for all checks")
    parser.add_argument("--keep-fixture", action="store_true")
    args = parser.parse_args()
    selected = set(args.checks.split(",")) if args.checks else set(CHECKS)
    if not selected or not selected <= set(CHECKS):
        parser.error("Unknown or empty --checks.")
    fixture, output = args.fixture.absolute(), args.output.absolute()
    ui_source, binary = args.ui_directory.resolve(strict=True), args.binary.resolve(strict=True)
    if fixture.exists() or fixture.is_symlink() or fixture.parent.resolve() != (ROOT / ".task-tmp").resolve():
        parser.error("--fixture must be a new immediate .task-tmp child.")
    if output.exists() or output.is_symlink() or output.parent.resolve() != (ROOT / "output/playwright").resolve():
        parser.error("--output must be a new immediate output/playwright child.")
    if not args.browser_executable.is_file() or not args.playwright_module.is_file():
        parser.error("Chrome and the preinstalled local Playwright module must be ordinary files.")
    for name in UI_FILES:
        source = ui_source / name
        if not source.is_file() or source.is_symlink():
            parser.error("Missing ordinary UI file: " + str(source))

    output.mkdir(parents=True)
    evidence = {
        "format": "vela-desktop-usability-browser-v1",
        "synthetic": True,
        "realProviderExecuted": False,
        "workflowToolExecuted": "not_started",
        "nativeIntegrationTested": False,
        "completeSuite": False,
        "selectedChecks": [item for item in CHECKS if item in selected],
        "requiredSelectors": SELECTORS,
        "checks": [],
    }
    server = driver = None
    fixture_created = False

    def save() -> None:
        (output / "results.json").write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + "\n")

    def browser(*command: str) -> str:
        assert driver and driver.stdin and driver.stdout
        driver.stdin.write(json.dumps(command) + "\n")
        driver.stdin.flush()
        if not select.select([driver.stdout], [], [], 20)[0]:
            raise TimeoutError("isolated Playwright driver did not respond")
        response = json.loads(driver.stdout.readline())
        if "error" in response:
            raise AssertionError(response["error"])
        return response.get("output", "")

    def value(expression: str):
        return json.loads(json.loads(browser("eval", "JSON.stringify(" + expression + ")")))

    def wait(expression: str, reason: str, seconds: float = 10) -> None:
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if value(expression):
                return
            time.sleep(.08)
        raise AssertionError(reason)

    def rpc(method: str, params: dict | None = None):
        request = urllib.request.Request(
            url + "__rpc", json.dumps({"method": method, "params": params or {}}).encode(),
            {"Content-Type": "application/json", "Origin": "http://" + url.split("/", 3)[2]},
        )
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                answer = json.load(response)
        except urllib.error.HTTPError as error:
            raise AssertionError(json.load(error).get("error", "bridge http error")) from error
        if "error" in answer:
            raise AssertionError(answer["error"])
        return answer["result"]

    def click(selector: str) -> None:
        browser("click", selector)

    def page(name: str, project: str) -> None:
        browser("press", "Escape")
        before = value("window.__usability.dashboardResolved")
        if value("document.querySelector('#project-selector').value") != project:
            browser("select", "#project-selector", project)
            wait("window.__usability.dashboardResolved>" + str(before) + "&&window.__usability.dashboardProject===" + json.dumps(project),
                 "project dashboard did not settle")
        click('.nav-link[data-page=' + json.dumps(name) + "]")
        wait("document.querySelector('.nav-link.active')?.dataset.page===" + json.dumps(name), "wrong visible page")

    def cards() -> list[dict]:
        return value("Array.from(document.querySelectorAll('[data-testid=\"approval-card\"]')).map(card=>({id:card.dataset.approvalId,project:card.dataset.project,visible:!!(card.offsetWidth||card.offsetHeight||card.getClientRects().length)}))")

    def capture(name: str) -> None:
        try:
            browser("screenshot", str(output / (name + ".png")))
            (output / (name + ".txt")).write_text(browser("snapshot", "-i"))
        except Exception as error:
            evidence["checks"][-1]["captureError"] = str(error)
        source = fixture / "harness-rpc.jsonl"
        if source.is_file():
            shutil.copyfile(source, output / (name + "-rpc.jsonl"))

    def check(name: str, action) -> None:
        if name not in selected:
            return
        result = {"check": name, "passed": False}
        start = len(value("window.__usability.calls")) if driver else 0
        try:
            result.update(action() or {})
            result["passed"] = True
        except Exception as error:
            result["error"] = str(error)
            result["traceback"] = traceback.format_exc(limit=5)
        finally:
            try:
                calls = value("window.__usability.calls")
                result["bridgeCalls"] = calls[start:]
                result["pageErrors"] = value("window.__usability.pageErrors")
                result["consoleErrors"] = value("window.__usability.consoleErrors")
            except Exception as error:
                result["telemetryError"] = str(error)
            evidence["checks"].append(result)
            capture(name)
            save()
            print(json.dumps(result, ensure_ascii=False), flush=True)

    try:
        evidence["uiSourceBefore"] = {name: sha(ui_source / name) for name in UI_FILES}
        evidence["helperBefore"] = sha(binary)
        created = subprocess.run(["python3", str(ROOT / "scripts/create-ui-fixture.py"), str(fixture), "--binary", str(binary), "--with-routing-project"],
                                 text=True, capture_output=True, timeout=120)
        (output / "fixture-creation.log").write_text(created.stdout + created.stderr)
        created.check_returncode()
        fixture_created = (fixture / "store/.vela-ui-fixture.json").is_file()
        manifest = json.loads((fixture / "fixture.json").read_text())
        harbor, beacon = manifest["project"], manifest["routingProject"]

        frozen_ui, frozen_helper = fixture / "ui-snapshot", fixture / "vela-frozen"
        frozen_ui.mkdir()
        copy_ui_resources(ui_source, frozen_ui, allow_development=True)
        shutil.copy2(binary, frozen_helper)
        evidence["frozenUI"] = {name: sha(frozen_ui / name) for name in UI_FILES}
        evidence["frozenHelper"] = sha(frozen_helper)
        assert evidence["uiSourceBefore"] == evidence["frozenUI"]
        assert evidence["helperBefore"] == evidence["frozenHelper"]
        server = subprocess.Popen(["python3", str(ROOT / "scripts/test-ui-server.py"), str(fixture / "fixture.json"), "--binary", str(frozen_helper), "--ui-directory", str(frozen_ui)],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        if not select.select([server.stdout], [], [], 15)[0]:
            raise RuntimeError("fixture bridge did not start")
        url = json.loads(server.stdout.readline())["url"]

        # A long, catalog-recognized project artifact exercises renderer truncation.
        # Importing an arbitrary local document is deliberately not used: that would
        # cross the bridge's file-source boundary and does not populate Setup assets.
        long_relative = ".agents/skills/" + "/".join(["very-long-synthetic-directory-name-" + str(i).zfill(2) for i in range(8)] + ["SKILL.md"])
        long_file = Path(harbor) / long_relative
        long_file.parent.mkdir(parents=True)
        long_file.write_text("# Synthetic overflow fixture\n\nThis file is catalog-recognized only for the UI width check.\n")
        scanned = rpc("setup.scan", {"project": harbor})
        artifact = next(item for item in scanned["artifacts"] if item.get("path") == str(long_file))

        inbox = rpc("inbox.list", {})
        normal = next(item for item in inbox if item.get("project") == harbor and item.get("tool") == "file.write")
        evidence["fixture"] = {"harbor": harbor, "beacon": beacon, "longAssetId": artifact["id"], "longRelativePath": long_relative,
                               "normalApprovalId": normal["id"], "normalSnapshotHash": normal["snapshotHash"]}

        spec = importlib.util.spec_from_file_location("vela_ui_transport", ROOT / "scripts/test-ui-browser.py")
        transport = importlib.util.module_from_spec(spec)
        assert spec.loader
        sys.modules[spec.name] = transport
        spec.loader.exec_module(transport)
        driver_source = transport.PLAYWRIGHT_DRIVER.replace(
            "const page=await browser.newPage({viewport:{width:1280,height:720}});page.setDefaultTimeout(5000);",
            "const page=await browser.newPage({viewport:{width:1280,height:720}});await page.addInitScript(()=>{window.__usabilityEarlyErrors=[];addEventListener('error',e=>window.__usabilityEarlyErrors.push(e.message||String(e.error)));addEventListener('unhandledrejection',e=>window.__usabilityEarlyErrors.push(String(e.reason)));const old=console.error.bind(console);console.error=(...v)=>{window.__usabilityEarlyErrors.push(v.map(String).join(' '));old(...v);};});page.setDefaultTimeout(5000);",
        ).replace(
            "else if(command==='press')await page.keyboard.press(args[0]);",
            "else if(command==='press')await page.keyboard.press(args[0]);else if(command==='resize')await page.setViewportSize({width:Number(args[0]),height:Number(args[1])});",
        )
        driver = subprocess.Popen(["node", "-e", driver_source, str(args.playwright_module.resolve()), str(args.browser_executable.resolve())],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        browser("open", url)
        browser("wait", "#project-selector")
        value("""(()=>{window.__usability={calls:[],pageErrors:window.__usabilityEarlyErrors||[],consoleErrors:window.__usabilityEarlyErrors||[],hold:null,release:null,dashboardResolved:0,dashboardProject:null};const orig=window.vela.call;window.vela.call=async(method,params={})=>{let result,error;try{result=await orig(method,params);window.__usability.calls.push({method,params,result,real:true});}catch(e){error=String(e?.message||e);window.__usability.calls.push({method,params,error,real:true});}if(method==='dashboard.get'){window.__usability.dashboardResolved++;window.__usability.dashboardProject=(params&&params.project)||'';}const hold=window.__usability.hold;if(hold&&hold.method===method&&(!hold.project||hold.project===((params&&params.project)||''))){window.__usability.hold=null;window.__usability.held={method,params,realError:!!error};await new Promise(resolve=>window.__usability.release=resolve);window.__usability.held=null;}if(error)throw Error(error);return result;};return true})()""")

        def setup_tab(tab: str) -> None:
            page("setup", harbor)
            click('[data-setuptab=' + json.dumps(tab) + ']')
            wait("document.querySelector(" + json.dumps('[data-setuptab="' + tab + '"]') + ")?.classList.contains('active')", "Setup tab did not activate: " + tab)

        def settings_category(category: str) -> None:
            page("settings", harbor)
            selector = '[data-settings-category=' + json.dumps(category) + ']'
            wait("!!document.querySelector(" + json.dumps(selector) + ")", "Settings category is absent: " + category)
            click(selector)
            wait("document.querySelector(" + json.dumps(selector) + ")?.classList.contains('active')", "Settings category did not activate: " + category)
            panel = '[data-settings-panel="' + category + '"]'
            wait("document.querySelector(" + json.dumps(panel) + ")?.hidden===false", "Settings panel did not become visible: " + category)

        def selector_contract():
            setup_tab("skills")
            asset_missing = {name: selector for name, selector in SELECTORS.items() if name in {"assetList", "assetRow", "assetLocation"} and not value("!!document.querySelector(" + json.dumps(selector) + ")")}
            page("inbox", harbor)
            approval_missing = {name: selector for name, selector in SELECTORS.items() if name not in {"assetList", "assetRow", "assetLocation", "toast"} and not value("!!document.querySelector(" + json.dumps(selector) + ")")}
            assert value("!!document.querySelector('#toast-container')"), "missing stable toast container"
            missing = asset_missing | approval_missing
            assert not missing, "missing required stable selectors: " + json.dumps(missing, ensure_ascii=False)
            return {"selectors": len(SELECTORS), "toastContainer": "#toast-container"}

        check("selector-contract", selector_contract)

        def asset_path():
            browser("resize", "1280", "720")
            setup_tab("skills")
            row = SELECTORS["assetRow"] + '[data-asset-id=' + json.dumps(artifact["id"]) + "]"
            wait("!!document.querySelector(" + json.dumps(row) + ")", "long asset row did not render")
            location = row + " " + SELECTORS["assetLocation"]
            visible = value("document.querySelector(" + json.dumps(location) + ").innerText")
            browser("screenshot", str(output / "assets-zh-default.png"))
            assert visible != str(long_file), "absolute long path is default-visible"
            assert value("(()=>{const e=document.querySelector(" + json.dumps(location) + ");return e.scrollWidth>e.clientWidth})()"), "long asset location is not clipped within its assigned row"
            geometry = value("""(()=>{
              const row=document.querySelector(%s), wrapper=row?.closest('.workspace-list'), title=row?.querySelector('.btn-setup-view'), menu=row?.querySelector('details.action-menu'), summary=menu?.querySelector('summary'), path=row?.querySelector(%s);
              const rect=e=>{const r=e?.getBoundingClientRect();return r&&{left:r.left,right:r.right,top:r.top,bottom:r.bottom,width:r.width,height:r.height};};
              const inside=(r,b)=>!!r&&!!b&&r.left>=b.left&&r.right<=b.right&&r.top>=b.top&&r.bottom<=b.bottom;
              const boundary=rect(wrapper), viewport={left:0,right:window.innerWidth,top:0,bottom:window.innerHeight};
              return {title:rect(title),menu:rect(summary),path:rect(path),boundary,viewport,
                titleInside:inside(rect(title),boundary)&&inside(rect(title),viewport),
                menuInside:inside(rect(summary),boundary)&&inside(rect(summary),viewport),
                titlePathSeparate:!!title&&!!path&&rect(path).top>=rect(title).bottom-1,
                menuClosed:menu?.open===false};
            })()""" % (json.dumps(row), json.dumps(SELECTORS["assetLocation"])))
            assert geometry["titleInside"], "asset title action is outside the visible list or viewport"
            assert geometry["menuInside"], "asset secondary action menu is outside the visible list or viewport"
            assert geometry["titlePathSeparate"], "asset title and location are not rendered on separate lines"
            assert geometry["menuClosed"], "asset secondary actions must start collapsed"
            click(row + " details.action-menu > summary")
            wait("document.querySelector(" + json.dumps(row + " details.action-menu") + ")?.open===true", "asset secondary menu did not open")
            assert value("!!document.querySelector(" + json.dumps(row + " .btn-setup-action-history") + ")"), "history action is absent from the opened asset menu"
            click(row + " details.action-menu > summary")
            wait("document.querySelector(" + json.dumps(row + " details.action-menu") + ")?.open===false", "asset secondary menu did not close")
            # The visible title is the primary read-only preview action. The
            # same semantic class also appears inside the collapsed overflow
            # menu, which must not be clicked while hidden.
            click(row + " .row-title.btn-setup-view")
            wait("!document.querySelector('#detail-drawer')?.classList.contains('hidden')", "asset title did not open its read-only drawer")
            click("#btn-close-drawer")
            return {"assetId": artifact["id"], "relativePath": long_relative, "viewport": [1280, 720], "geometry": geometry,
                    "rowMenuOpened": True, "titleOpenedReadOnlyDrawer": True}

        check("asset-path-does-not-overflow", asset_path)

        def approval_disclosure_wire():
            page("inbox", harbor)
            card = SELECTORS["approvalCard"] + '[data-approval-id=' + json.dumps(normal["id"]) + "]"
            wait("!!document.querySelector(" + json.dumps(card) + ")", "fixture approval card absent")
            assert value("!!document.querySelector(" + json.dumps(card + " " + SELECTORS["approvalImpact"]) + ")"), "reviewable impact is absent"
            assert not value("document.querySelector(" + json.dumps(card + " " + SELECTORS["approvalTechnicalDetails"]) + ").open"), "technical details must start collapsed"
            default_text = value("document.querySelector(" + json.dumps(card) + ").innerText")
            browser("screenshot", str(output / "inbox-zh-default.png"))
            assert normal["snapshotHash"] not in default_text and harbor not in default_text, "hash or absolute project path is default-visible"
            click(card + " " + SELECTORS["approvalTechnicalDetails"] + " > summary")
            wait("document.querySelector(" + json.dumps(card + " " + SELECTORS["approvalTechnicalDetails"]) + ").open", "technical disclosure did not open")
            assert value("document.querySelector(" + json.dumps(card + " " + SELECTORS["approvalSnapshotHash"]) + ").textContent.includes(" + json.dumps(normal["snapshotHash"]) + ")"), "full snapshot hash unavailable after disclosure"
            assert value("document.querySelector(" + json.dumps(card + " " + SELECTORS["approvalRaw"]) + ").textContent.length>2"), "raw frozen payload unavailable after disclosure"
            click(card + " " + SELECTORS["approvalApprove"])
            wait("window.__usability.calls.some(x=>x.method==='approvals.decide'&&x.params.id===" + json.dumps(normal["id"]) + ")", "approval did not reach real bridge")
            sent = value("window.__usability.calls.filter(x=>x.method==='approvals.decide').at(-1).params")
            assert sent == {"id": normal["id"], "decision": "approve", "snapshotHash": normal["snapshotHash"]}, "renderer changed frozen approval wire data"
            expected_body = "# Verification\n\nThe focused parser checks passed.\n"
            assert (Path(harbor) / "docs/verification.md").read_text() == expected_body, "exact frozen synthetic file.write body was not persisted"
            evidence["workflowToolExecuted"] = "synthetic fixture file.write only"
            return {"approvalId": normal["id"], "snapshotHashExact": True, "syntheticFileWriteExecuted": True, "exactOutputVerified": True}

        check("approval-disclosure-and-frozen-wire", approval_disclosure_wire)

        def expired_refresh():
            # Create after the UI is loaded, then render before its deadline. No
            # dashboard/get/list call is allowed between the final render and the
            # click; the terminal state must originate at the real decide claim.
            page("inbox", harbor)
            rpc("settings.save", {"approvalExpirySeconds": 5})
            expired_workflow = rpc("workflows.save", {"project": harbor, "title": "Expired UI refresh check", "trigger": "manual", "steps": [{"tool": "file.write", "arguments": {"path": "expired-ui-must-not-exist.txt", "content": "synthetic expiry check"}}]})
            expired_run = rpc("workflows.run", {"id": expired_workflow["id"], "dryRun": False})
            assert expired_run["state"] == "pending_approval"
            expired = next(item for item in rpc("inbox.list", {}) if item.get("runId") == expired_run["id"])
            rpc("settings.save", {"approvalExpirySeconds": 604800})
            # Force an authoritative dashboard render while still before expiry.
            browser("select", "#project-selector", beacon)
            wait("window.__usability.dashboardProject===" + json.dumps(beacon), "Beacon refresh did not settle")
            browser("select", "#project-selector", harbor)
            wait("window.__usability.dashboardProject===" + json.dumps(harbor), "Harbor pre-expiry refresh did not settle")
            card = SELECTORS["approvalCard"] + '[data-approval-id=' + json.dumps(expired["id"]) + "]"
            wait("!!document.querySelector(" + json.dumps(card) + ")", "unexpired fixture card was not rendered")
            before_wait = len(value("window.__usability.calls"))
            expires = dt.datetime.fromisoformat(expired["expiresAt"].replace("Z", "+00:00")).timestamp()
            delay = expires + .25 - time.time()
            assert 0 < delay < 6.5, "unexpected expiry deadline"
            time.sleep(delay)
            between = value("window.__usability.calls.slice(" + str(before_wait) + ")")
            assert not any(call.get("method") in {"inbox.list", "approvals.get", "approvals.decide"} for call in between), "approval was pre-read or decided between final pre-expiry render and click"
            before = len(value("window.__usability.calls"))
            before_toasts = value("Array.from(document.querySelectorAll(" + json.dumps(SELECTORS["toast"]) + ")).map(e=>e.innerText)")
            click(card + " " + SELECTORS["approvalApprove"])
            wait("window.__usability.calls.slice(" + str(before) + ").some(x=>x.method==='approvals.decide'&&x.params.id===" + json.dumps(expired["id"]) + "&&x.error)", "expired core error not observed")
            wait("window.__usability.calls.slice(" + str(before) + ").some(x=>x.method==='dashboard.get'&&x.params.project===" + json.dumps(harbor) + ")", "terminal error did not refresh authoritative dashboard")
            wait("!document.querySelector(" + json.dumps(card) + ")", "expired card remained actionable after refresh")
            toasts = value("Array.from(document.querySelectorAll(" + json.dumps(SELECTORS["toast"]) + ")).map(e=>e.innerText)")
            new_toasts = toasts[len(before_toasts):]
            assert new_toasts and "Approval expired" in new_toasts[-1], "expired-decision toast was not the new terminal toast"
            assert not any("Approved and triggered execution" in text or "已批准并触发执行" in text for text in new_toasts), "expired decision emitted a new success toast"
            assert not (Path(harbor) / "expired-ui-must-not-exist.txt").exists(), "expired approval wrote its target"
            evidence["fixture"].update(expiredApprovalId=expired["id"], expiredSnapshotHash=expired["snapshotHash"], expiredRunId=expired_run["id"])
            return {"approvalId": expired["id"], "authoritativeRefresh": True, "noPreClickPageRead": True}

        check("expired-decision-refreshes-authoritative-list", expired_refresh)

        def scope_guard():
            page("inbox", beacon)
            value("(()=>{window.__usability.hold={method:'dashboard.get',project:" + json.dumps(harbor) + "};return true})()")
            browser("select", "#project-selector", harbor)
            wait("!!window.__usability.held", "Harbor dashboard response was not held after real bridge completion")
            browser("select", "#project-selector", beacon)
            assert value("document.querySelector('#project-selector').value") == beacon, "project switch did not take effect while older response was held"
            browser("eval", "window.__usability.release();true")
            wait("!window.__usability.held", "held Harbor response did not release")
            wait("window.__usability.dashboardProject===" + json.dumps(beacon), "queued Beacon dashboard did not settle after stale Harbor release")
            assert value("document.querySelector('#project-selector').value") == beacon, "late response changed selected project"
            assert all(card["project"] == beacon for card in cards()), "late Harbor cards leaked into Beacon scope"
            return {"heldProject": "Harbor", "finalProject": "Beacon"}

        check("late-project-response-cannot-cross-scope", scope_guard)

        def locale_narrow():
            browser("resize", "720", "760")
            for locale, expected in (("en", "Approvals"), ("zh-CN", "待办审批")):
                settings_category("general")
                wait("!!document.querySelector('#setting-locale')", "locale setting control is absent")
                browser("select", "#setting-locale", locale)
                wait("window.VelaI18n.getLocale()===" + json.dumps(locale) + "&&document.querySelector('#setting-locale').disabled===false", "locale save did not settle: " + locale)
                value("(()=>{document.documentElement.style.fontSize='20px';return true})()")
                page("inbox", harbor)
                wait("window.VelaI18n.getLocale()===" + json.dumps(locale) + "&&document.body.innerText.includes(" + json.dumps(expected) + ")", "locale did not update visible Inbox text: " + locale)
                if locale == "zh-CN":
                    browser("screenshot", str(output / "inbox-zh-large-720.png"))
                assert value("document.documentElement.scrollWidth<=window.innerWidth"), "narrow large-type layout overflows for " + locale
                assert value("Array.from(document.querySelectorAll(" + json.dumps(SELECTORS["approvalApprove"]) + ")).every(e=>!!(e.offsetWidth||e.offsetHeight||e.getClientRects().length))"), "approval action hidden for " + locale
            return {"viewport": [720, 760], "rootFontPx": 20, "locales": ["en", "zh-CN"], "persistedThroughSettings": True}

        check("locale-large-type-narrow-window", locale_narrow)
    except Exception as error:
        evidence["setupFailure"] = type(error).__name__ + ": " + str(error)
        evidence["setupTraceback"] = traceback.format_exc(limit=6)
    finally:
        stop(driver)
        stop(server)
        try:
            evidence["helperAfter"] = sha(binary)
            evidence["uiSourceAfter"] = {name: sha(ui_source / name) for name in UI_FILES}
            evidence["inputsUnchanged"] = evidence.get("helperBefore") == evidence["helperAfter"] and evidence.get("uiSourceBefore") == evidence["uiSourceAfter"]
        except Exception as error:
            evidence["integrityError"] = str(error)
            evidence["inputsUnchanged"] = False
        if fixture_created and not args.keep_fixture:
            try:
                shutil.rmtree(fixture)
            except Exception as error:
                evidence["fixtureCleanupError"] = str(error)
        evidence["fixtureRemoved"] = not fixture.exists()
        evidence["selectedChecksPassed"] = (not evidence.get("setupFailure") and evidence["inputsUnchanged"] and evidence["fixtureRemoved"] and
                                             len(evidence["checks"]) == len(selected) and all(item.get("passed") for item in evidence["checks"]))
        evidence["completeSuite"] = selected == set(CHECKS) and evidence["selectedChecksPassed"]
        evidence["passed"] = evidence["selectedChecksPassed"]
        save()
    return 0 if evidence["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
