#!/usr/bin/env python3
"""Two-hour real-time synthetic production pipeline + read-only SwiftUI observer.
No microphone/voice enrollment. Records process RSS/CPU and bounded periodic heap
snapshots, with idle controls before/after. Only generated fixture/data are used.
"""
import pathlib,subprocess,time,json,uuid,sqlite3,os,sys,plistlib
p=pathlib.Path(__file__).resolve().parents[1]
out=p/'reports'/('memory-soak-'+str(uuid.uuid4()));out.mkdir(parents=True);data=out/'Data'
duration=float(sys.argv[1]) if len(sys.argv)>1 else 7200
idle=float(sys.argv[2]) if len(sys.argv)>2 else 120
budget=2*1024**3
# Distinct test bundle identity: normal Nagi remains independently launchable.
test_app=out/'Nagi Synthetic Test.app'
subprocess.run(['/bin/cp','-cR',str(p/'build/Nagi.app'),str(test_app)],check=True)
plist_path=test_app/'Contents/Info.plist'
with plist_path.open('rb') as f:plist=plistlib.load(f)
plist.update(CFBundleIdentifier='local.nagi.synthetic-test.'+out.name[-12:],CFBundleName='Nagi Synthetic Test',CFBundleDisplayName='Nagi Synthetic Test',NagiSyntheticTest=True,NagiSyntheticData=str(data))
with plist_path.open('wb') as f:plistlib.dump(plist,f)
subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(test_app)],check=True)
app_log=(out/'app.log').open('w');run_log=(out/'run.log').open('w')
env=os.environ|{'STILLPOINT_DATA':str(data),'NAGI_SYNTHETIC_MONITOR':'1'}
app=subprocess.Popen([str(test_app/'Contents/MacOS/Nagi')],env=env,stdout=app_log,stderr=subprocess.STDOUT)
# Prevent idle SYSTEM sleep only during this explicitly requested recording test.
# Screen lock is untouched; no microphone hardware is opened.
wake=None
start=time.monotonic();host=None;end=None;next_sample=0;next_heap=0;peak_worker=0;disk_peak=0
snapshots=[idle+30,idle+600,idle+1800,idle+3600,idle+5400,idle+duration-30]
print(json.dumps({'folder':str(out),'app_pid':app.pid,'duration':duration,'idle_control_seconds':idle}),flush=True)
try:
 with (out/'samples.ndjson').open('w') as samples:
  while True:
   wall=time.monotonic()-start
   if host is None and wall>=idle:
    host=subprocess.Popen([str(p/'.build/debug/JournalHarness'),'soak',str(data),str(p/'Fixtures/english.wav'),str(p),str(duration),'1'],stdout=run_log,stderr=subprocess.STDOUT)
    wake=subprocess.Popen(['/usr/bin/caffeinate','-i','-w',str(host.pid)])
    print('Synthetic producer started pid='+str(host.pid),flush=True)
   if host is not None and host.poll() is not None and end is None:
    end=wall;print('Synthetic producer completed exit='+str(host.returncode),flush=True)
   if app.poll() is not None:raise RuntimeError('SwiftUI observer exited unexpectedly')
   if end is not None and wall-end>=idle:break
   rows=subprocess.check_output(['ps','-axo','pid=,ppid=,rss=,%cpu=,time=,comm='],text=True).splitlines();processes={}
   for row in rows:
    f=row.strip().split(None,5)
    if len(f)==6:processes[int(f[0])]=(int(f[1]),int(f[2]),float(f[3]),f[4],f[5])
   owned={app.pid};
   if host:owned.add(host.pid)
   for _ in range(5):owned.update(pid for pid,v in processes.items() if v[0] in owned)
   metrics=[{'pid':pid,'rss_kib':processes[pid][1],'cpu_percent':processes[pid][2],'cpu_time':processes[pid][3],'command':processes[pid][4],'role':'app' if pid==app.pid else 'host' if host and pid==host.pid else 'worker'} for pid in owned if pid in processes]
   peak_worker=max([peak_worker]+[r['rss_kib'] for r in metrics if 'ASRWorker' in r['command'] or 'SpeakerWorker' in r['command']])
   if wall>=next_sample:
    statuses={};counts={}
    try:
     with sqlite3.connect(data/'journal.sqlite',timeout=1) as db:
      statuses=dict(db.execute('SELECT status,count(*) FROM chunks GROUP BY status'))
      counts={t:db.execute('SELECT count(*) FROM '+t).fetchone()[0] for t in ['segments','speaker_vectors']}
    except sqlite3.Error:pass
    disk=sum(f.stat().st_size for f in data.rglob('*') if f.is_file()) if data.exists() else 0;disk_peak=max(disk_peak,disk)
    if disk>budget:raise RuntimeError('Test exceeded its 2 GiB disk budget')
    samples.write(json.dumps({'wall':round(wall,3),'phase':'idle_before' if host is None else 'idle_after' if end else 'recording','metrics':metrics,'statuses':statuses,'counts':counts,'disk_bytes':disk})+'\n');samples.flush();next_sample=wall+10
    (out/'status.json').write_text(json.dumps({'wall':wall,'app_pid':app.pid,'host_pid':host.pid if host else None,'statuses':statuses,'metrics':metrics,'disk_bytes':disk},indent=2))
   if next_heap<len(snapshots) and wall>=snapshots[next_heap]:
    for role,pid in [('app',app.pid),('host',host.pid if host and host.poll() is None else None)]:
     if pid:
      for tool,args in [('heap',['-s']),('vmmap',['-summary']),('leaks',[])]:
       with (out/f'{role}-{tool}-{int(wall)}.txt').open('w') as f:
        try:subprocess.run(['/usr/bin/'+tool,*args,str(pid)],stdout=f,stderr=subprocess.STDOUT,timeout=20)
        except subprocess.TimeoutExpired:f.write('Profiling tool timed out.\n')
    next_heap+=1
   time.sleep(.5)
 result={'exit':host.returncode,'duration':duration,'speed':1,'wall':time.monotonic()-start,'capture_start_wall':idle,'capture_end_wall':end,'idle_control_seconds':idle,'peak_worker_rss_kib_sampled':peak_worker,'disk_peak_bytes':disk_peak,'disk_budget_bytes':budget,'folder':str(out)}
 (out/'results.json').write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2),flush=True)
finally:
 if host and host.poll() is None:host.terminate();host.wait(timeout=10)
 if app.poll() is None:app.terminate();app.wait(timeout=10)
 if wake and wake.poll() is None:wake.terminate();wake.wait(timeout=5)
 app_log.close();run_log.close()
if host.returncode:sys.exit(host.returncode)
subprocess.run([sys.executable,str(p/'scripts/check-soak-audio.py'),str(data)],check=True)
print((out/'run.log').read_text()[-1500:])
