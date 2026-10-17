"""Exercise real upstream fixtures using the bundled macOS engine; originals stay intact."""
import copy, hashlib, json, os, pathlib, shutil, subprocess
ROOT = pathlib.Path(__file__).resolve().parents[2]
WORK = ROOT / 'workspace' / 'smoke'
WORK.mkdir(parents=True, exist_ok=True)
ENV = dict(os.environ, CHANSORT_HOME=str(ROOT), TMPDIR=str(ROOT/'tmp'), DOTNET_EnableDiagnostics='0')
ENGINE = ROOT/'ChanSort.app/Contents/Resources/Engine/ChanSort.Engine'

class Session:
    def __init__(self):
        self.log=(ROOT/'logs/smoke-engine.log').open('a')
        self.p=subprocess.Popen([str(ENGINE)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=self.log,text=True,env=ENV,cwd=ROOT)
    def ask(self, data):
        self.p.stdin.write(json.dumps(data)+'\n'); self.p.stdin.flush()
        while True:
            line=self.p.stdout.readline()
            if not line: raise RuntimeError('Engine exited; inspect logs/smoke-engine.log')
            reply=json.loads(line)
            if reply.get('type')=='prompt':
                # Preserve conservative defaults in fixture tests, never accept optional conversions.
                options=reply['actions']; action=next((a for a in options if a['text'] in ('No','OK')),options[0])
                self.p.stdin.write(json.dumps({'result':action['result']})+'\n'); self.p.stdin.flush(); continue
            return reply
    def close(self):
        self.p.stdin.close(); self.p.wait(timeout=10); self.log.close()

fixtures=[
 ('m3u','source/Test.Loader.M3u/TestFiles/example.m3u','example.m3u'),
 ('schneider','source/Test.Loader.SatcoDX/TestFiles/silva_schneider.sdx','silva_schneider.sdx'),
 ('lg-binary','source/Test.Loader.LG/Binary/LM/xxLM620S-ZE00001.TLL.in','xxLM620S-ZE00001.TLL'),
 ('lg-xml','source/Test.Loader.LG/GlobalClone.xml','GlobalClone.TLL'),
 ('samsung','source/Test.Loader.Samsung/Zip/TestFiles/Channel_list_T-KTMDEUC-1132.6.zip','samsung.zip'),
]
results=[]
for label,source,name in fixtures:
    folder=WORK/label; folder.mkdir(exist_ok=True); target=folder/name; shutil.copy2(ROOT/source,target)
    s=Session()
    try:
        loaded=s.ask({'command':'load','path':str(target)})
        assert loaded['type']=='loaded',loaded
        lists=loaded['lists']; changed=None
        for li in lists:
            if li['readOnly']: continue
            active=sorted((c for c in li['channels'] if not c['deleted'] and c['oldNumber']>=0),key=lambda c:c['number'])
            if len(active)>1:
                a,b=active[:2]; a['number'],b['number']=b['number'],a['number']; changed=(li['id'],a['id'],a['number']);break
        assert changed,'No editable list'
        original=target.read_bytes()
        invalid=copy.deepcopy(lists)
        writable=next(li for li in invalid if li['id']==changed[0])
        active=[c for c in writable['channels'] if not c['deleted'] and c['oldNumber']>=0]
        active[1]['number']=active[0]['number']
        rejected=s.ask({'command':'save','lists':invalid})
        assert rejected['type']=='error',rejected
        assert target.read_bytes()==original,'Rejected save modified input'
        saved=s.ask({'command':'save','lists':lists});assert saved['type']=='saved',saved
        manifest=json.loads(pathlib.Path(saved['backup'],'manifest.json').read_text())
        backed=next(m for m in manifest if pathlib.Path(m['original'])==target)
        assert pathlib.Path(backed['backup']).read_bytes()==original,'Backup differs from original'
        assert pathlib.Path(saved['backup'],'manifest.json').exists()
        reloaded=s.ask({'command':'load','path':str(target)}); assert reloaded['type']=='loaded',reloaded
        liid,ciid,number=changed
        actual=next(c['number'] for li in reloaded['lists'] if li['id']==liid for c in li['channels'] if c['id']==ciid)
        # Some formats reorder records on write, so channel identities use names for the roundtrip check.
        before=next(c for li in lists if li['id']==liid for c in li['channels'] if c['id']==ciid)
        assert any(c['name']==before['name'] and c['number']==number for li in reloaded['lists'] for c in li['channels']), (before,actual)
        results.append({'format':label,'result':'PASS','channels':sum(len(li['channels']) for li in lists)})
    except Exception as exc: results.append({'format':label,'result':'FAIL','error':str(exc)})
    finally: s.close()
print(json.dumps(results,indent=2)); (ROOT/'logs/smoke-results.json').write_text(json.dumps(results,indent=2))
if any(r['result']=='FAIL' for r in results): raise SystemExit(1)
