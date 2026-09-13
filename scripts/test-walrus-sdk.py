"""Install and verify the optional adapter using the real official SDK and local fixtures.

--public-preflight additionally queries /version without any user account or key.
It never writes remote memory, signs account transactions, or reads credentials.
"""
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

root = Path(__file__).resolve().parents[1]
out = Path(os.environ.get("VELA_WALRUS_TEST_OUTPUT", root / "output/parity/walrus-sdk"))
out.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="vela-walrus-installed-") as temporary:
    scratch = Path(temporary)
    env = {**os.environ, "npm_config_cache": str(scratch / "npm-cache")}
    def run(name, cmd, cwd=root, extra_env=None):
        result = subprocess.run(cmd, cwd=cwd, env={**env, **(extra_env or {})}, capture_output=True, text=True, timeout=180)
        (out / (name + ".log")).write_text(result.stdout + result.stderr)
        if result.returncode:
            print(result.stdout + result.stderr)
            result.check_returncode()
        return result
    run("pack", ["npm", "pack", "--json", "--pack-destination", str(scratch)], root / "sdk/walrus")
    tgz = next(scratch.glob("*.tgz"))
    with tarfile.open(tgz) as package:
        members = package.getnames()
    assert set(members) == {"package/package.json", "package/LICENSE", "package/README.md", "package/dist/index.js", "package/dist/index.d.ts", "package/dist/worker.js", "package/dist/worker.d.ts", "package/dist/owner.js", "package/dist/owner.d.ts", "package/dist/manifest.js", "package/dist/manifest.d.ts", "package/dist/manifest-reader.js", "package/dist/manifest-reader.d.ts", "package/dist/metadata.js", "package/dist/metadata.d.ts"}
    consumer = scratch / "consumer"
    consumer.mkdir()
    (consumer / "package.json").write_text('{"private":true,"type":"module"}')
    run("install", ["npm", "install", "--ignore-scripts", "--no-audit", "--no-fund", str(tgz)], consumer)
    installed = consumer / "node_modules/@vela-engineering/walrus/dist/index.js"
    (consumer / "consumer.ts").write_text('''import {WalrusClient, type RemoteProfile, type PreparedRemoteAction, createMemoryManifest} from '@vela-engineering/walrus';
declare const profile: RemoteProfile;
const client = new WalrusClient(profile);
const preview: PreparedRemoteAction = client.prepareRemember('synthetic');
void client.ownerMemories({limit:10}); void client.ownerAgents(); void client.namespaceStats(); void client.rememberBulkStatus(['job']); void client.waitForRememberJobs(['job'],{maxWaitMs:1000}); void client.prepareRememberBulk(['one','two']); void client.prepareForgetNamespace();
void client.compatibility(); void client.deployment(); void client.prepareRestoreIndexRelayer(10); void preview;
void client.prepareOwnerAction({operation:'createAccount',maxGasBudgetMIST:'1000000'});
const manifest=createMemoryManifest({network:profile.network,packageID:profile.packageID,accountID:profile.accountID,owner:profile.expectedOwner,namespace:profile.namespace},[]);
void client.restoreManifestPage(manifest,{limit:1});
''')
    run("consumer-typecheck", [str(root / "sdk/walrus/node_modules/.bin/tsc"), "--strict", "--noEmit", "--target", "ES2022", "--module", "NodeNext", "--moduleResolution", "NodeNext", "consumer.ts"], consumer)
    tests = run("installed-tests", ["node", "--test", str(root / "sdk/walrus/test/adapter.test.mjs")], consumer, {"VELA_WALRUS_TEST_PACKAGE": installed.as_uri()})
    run("dependency-tree", ["npm", "ls", "--all", "--json"], consumer)
    shutil.copy2(tgz, out / tgz.name)
    passed = re.search(r"(?:#|ℹ) pass (\d+)", tests.stdout)
    assert passed and int(passed.group(1)) >= 33, tests.stdout
    evidence = {"testsPassed": int(passed.group(1)), "installedConsumerTypecheck": True, "package": tgz.name, "sha256": hashlib.sha256(tgz.read_bytes()).hexdigest(), "bytes": tgz.stat().st_size, "members": members, "temporaryInstallAndCacheRemovedOnExit": True, "remoteEncryptedRoundtrip": "not_run_free_testnet_faucet_rate_limited_and_no_gas_coin"}
    (out / "package-results.json").write_text(json.dumps(evidence, indent=2))
    if "--public-preflight" in sys.argv:
        preflight = consumer / "preflight.mjs"
        preflight.write_text('''import {WalrusClient} from '@vela-engineering/walrus';
const accountPlaceholder='0x'+'0'.repeat(64);
const results=[];
for(const [network,serverURL] of [['mainnet','https://relayer.memory.walrus.xyz'],['testnet','https://relayer-staging.memory.walrus.xyz']]) {
  const fullnodeURL=`https://fullnode.${network}.sui.io`;
  const profile={version:1,id:'public-compatibility-only',mode:'relayerProcessing',network,serverURL,fullnodeURL,packageID:accountPlaceholder,sealPolicyPackageID:accountPlaceholder,registryID:accountPlaceholder,accountID:accountPlaceholder,expectedOwner:accountPlaceholder,namespace:'compatibility-only',allowedOrigins:[serverURL,fullnodeURL],writeLimits:{maxOperations:0,maxPlaintextBytes:0}};
  const client=new WalrusClient(profile);
  try {results.push({network,serverURL,outcome:'response',result:await client.compatibility({timeoutMs:10000})});}
  catch(error){results.push({network,serverURL,outcome:'error',code:error.code,httpStatus:error.httpStatus,effectsUnknown:error.effectsUnknown});}
  finally{await client.close();}
}
console.log(JSON.stringify({timestamp:new Date().toISOString(),credentialSource:'none; no existing account or private key read',accountIDs:'placeholders unused by public version request',writesAttempted:0,results},null,2));
''')
        result = run("public-preflight", ["node", str(preflight)], consumer)
        (out / "public-preflight.json").write_text(result.stdout)
    print(json.dumps(evidence))
