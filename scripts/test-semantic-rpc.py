"""Verify actual installed Apple models and the real CLI semantic path in disposable stores."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = Path(os.environ.get("VELA_TEST_HELPER", root / ".build/debug/vela"))
checks, models, evidence = [], {}, {}
with tempfile.TemporaryDirectory(prefix="vela-semantic-rpc-") as temporary:
    fixture = Path(temporary)
    helper = fixture / "vela"
    shutil.copy2(source, helper)
    digest = hashlib.sha256(helper.read_bytes()).hexdigest()
    project = fixture / "project"
    project.mkdir()
    home = fixture / "store"
    def call(method, params):
        result = subprocess.run([str(helper), "call", method, json.dumps(params, ensure_ascii=False), "--home", str(home)], env={**os.environ, "VELA_DISABLE_DISCOVERY": "1"}, capture_output=True, text=True, timeout=30, check=True)
        return json.loads(result.stdout)
    call("projects.add", {"path": str(project)})
    def memory(title, text, **extra):
        return call("memory.save", {"project": str(project), "title": title, "content": text, "scope": "project", "state": "active", **extra})
    positive = memory("Transport", "The automobile requires maintenance.")
    unrelated = memory("Dessert", "Bake a chocolate cake for the birthday party.")
    memory("Private transport", "Private automobile fact.", private=True)
    memory("Candidate transport", "Candidate automobile fact.", state="candidate")
    before = call("memory.semantic.status", {"project": str(project), "language": "en"})
    models["en"] = before["model"]
    if before["status"] == "unavailable":
        assert before["model"] is None and before["indexIncomplete"] and not before["downloadRequested"]
        checks.append("English model absence returned explicitly; actual English model case not run")
    else:
        assert before["eligible"] == 2 and before["indexed"] == 0
        cursor = None
        counts = {"indexed": 0, "skipped": 0}
        while True:
            page = call("memory.semantic.index", {"project": str(project), "language": "en", "batchSize": 1, **({"cursor": cursor} if cursor else {})})
            counts["indexed"] += page["indexed"]; counts["skipped"] += page["skipped"]
            assert not page["failed"]
            if not page["hasMore"]:
                break
            cursor = page["nextCursor"]
        assert counts == {"indexed": 2, "skipped": 2}
        after = call("memory.semantic.status", {"project": str(project), "language": "en"})
        assert after["indexed"] == 2 and not after["indexIncomplete"]
        result = call("recall", {"project": str(project), "query": "The vehicle needs repair.", "retrievalMode": "semantic", "language": "en", "minSimilarity": 0, "limit": 2})
        assert result["items"][0]["id"] == positive["id"]
        evidence["englishSynonymCosine"] = result["items"][0]["semanticSimilarity"]
        evidence["returnedAtMinimumSimilarityZero"] = len(result["items"])
        checks.append("real English synonym recalled across separate helper processes with paged persistent index")
        checks.append("private and candidate records excluded before indexing")
        # Each call above closes the helper; change only this fixture's generated Markdown asset.
        asset = Path(positive["assetPath"])
        assert asset.resolve().is_relative_to(home.resolve())
        asset.write_text(asset.read_text().replace("The automobile requires maintenance.", "Newly changed source evidence."))
        stale = call("recall", {"project": str(project), "query": "The vehicle needs repair.", "retrievalMode": "semantic", "minSimilarity": 0})
        assert stale["staleVectorsExcluded"] == 1 and stale["indexIncomplete"]
        assert all(item["id"] != positive["id"] for item in stale["items"])
        assert call("memory.semantic.index", {"project": str(project)})["indexed"] == 1
        assert not call("memory.semantic.status", {"project": str(project)})["indexIncomplete"]
        checks.append("edited source invalidates its vector until explicit reindex")
    chinese = memory("车辆", "这辆汽车需要维修。")
    chinese_index = call("memory.semantic.index", {"project": str(project), "language": "zh-Hans"})
    models["zh-Hans"] = chinese_index["model"]
    if chinese_index["status"] == "unavailable":
        assert chinese_index["model"] is None and not chinese_index["downloadRequested"]
        checks.append("Chinese model absence returned explicitly; actual Chinese model case not run")
    else:
        result = call("recall", {"project": str(project), "language": "zh-Hans", "retrievalMode": "semantic", "query": "车辆需要修理", "minSimilarity": 0})
        assert result["items"][0]["id"] == chinese["id"]
        evidence["chineseSynonymCosine"] = result["items"][0]["semanticSimilarity"]
        checks.append("real Simplified Chinese model ranks the Chinese repair memory first")
    empty = call("recall", {"project": str(project), "retrievalMode": "hybrid", "query": "Dessert", "budget": 0})
    assert not empty["items"] and empty["usedTokens"] == 0
    checks.append("hybrid recall enforces explicit zero token budget")
print(json.dumps({"checks": checks, "passed": len(checks), "failed": 0, "models": models, "evidence": evidence, "helperSHA256": digest, "fixturesRemoved": True}, ensure_ascii=False, indent=2))
