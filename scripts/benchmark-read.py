"""Reproducible synthetic read benchmark; creates and removes its own database.

Run after `swift build -c release`. This measures local RPC/SQLite substring search,
not ingestion throughput, relevance, memory pressure, or agent quality.
"""
import json, os, pathlib, platform, sqlite3, statistics, subprocess, tempfile, time
root = pathlib.Path(__file__).resolve().parents[1]
binary = root / '.build/release/vela'
env = dict(os.environ, VELA_DISABLE_DISCOVERY='1')
with tempfile.TemporaryDirectory(prefix='vela-benchmark-') as tmp:
    home = pathlib.Path(tmp) / 'store'
    subprocess.run([str(binary),'doctor','--home',str(home)],env=env,check=True,stdout=subprocess.DEVNULL)
    with sqlite3.connect(home/'vela.sqlite3') as db:
        def rows():
            for i in range(100_000):
                item = dict(id=f'fixture-{i:06}',kind='session',project='/synthetic/benchmark',title=f'Verification {i}',content=f'synthetic engineering evidence topic-{i%100} '+('bounded context '*20),updatedAt=f'2026-09-12T00:{i%60:02}:00Z',messages=[])
                yield ('session',item['id'],item['project'],item['title'],item['content'],0,item['updatedAt'],json.dumps(item))
        db.executemany('INSERT INTO objects(kind,id,project,title,content,private,updatedAt,json) VALUES(?,?,?,?,?,?,?,?)',rows())
    proc = subprocess.Popen([str(binary),'rpc','--home',str(home),'--no-watch'],env=env,text=True,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    latencies=[]
    try:
        for i in range(60):
            req = dict(id=i,method='search',params=dict(query=f'topic-{i%100}',project='/synthetic/benchmark'))
            begin=time.perf_counter(); proc.stdin.write(json.dumps(req)+'\n');proc.stdin.flush()
            result=json.loads(proc.stdout.readline());elapsed=(time.perf_counter()-begin)*1000
            assert result.get('id')==i and len(result.get('result',[]))==50, result
            if i>=10: latencies.append(elapsed)
    finally:
        proc.stdin.close();proc.wait(timeout=10)
    assert proc.returncode==0, proc.stderr.read()
    print(json.dumps(dict(records=100_000,warmups=10,samples=50,metric='warm RPC search latency',medianMs=round(statistics.median(latencies),2),p95Ms=round(sorted(latencies)[47],2),maxMs=round(max(latencies),2),platform=platform.machine()),indent=2))
