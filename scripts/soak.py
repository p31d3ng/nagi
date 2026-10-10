#!/usr/bin/env python3
"""Synthetic injection into production enqueue/write/ML paths; no microphone opened."""
import pathlib,subprocess,time,json,uuid,sqlite3,sys
p=pathlib.Path(__file__).resolve().parents[1];out=p/'reports'/('soak-'+str(uuid.uuid4()));out.mkdir(parents=True);data=out/'Data'
duration=float(sys.argv[1]) if len(sys.argv)>1 else 1800
speed=float(sys.argv[2]) if len(sys.argv)>2 else 4
log=(out/'run.log').open('w');start=time.monotonic()
child=subprocess.Popen([str(p/'.build/debug/JournalHarness'),'soak',str(data),str(p/'Fixtures/english.wav'),str(p),str(duration),str(speed)],stdout=log,stderr=subprocess.STDOUT)
samples=[];peak_worker=0
while child.poll() is None:
 rows=subprocess.check_output(['ps','-axo','pid=,ppid=,rss=,%cpu=,comm='],text=True).splitlines();processes={}
 for row in rows:
  fields=row.strip().split(None,4)
  if len(fields)==5:processes[int(fields[0])]=(int(fields[1]),int(fields[2]),float(fields[3]),fields[4])
 owned={child.pid}
 for _ in range(5):owned.update(pid for pid,v in processes.items() if v[0] in owned)
 metrics=[(pid,*processes[pid][1:]) for pid in owned if pid in processes]
 workers=[r for r in metrics if 'ASRWorker' in r[3] or 'SpeakerWorker' in r[3]]
 peak_worker=max([peak_worker]+[r[1] for r in workers]);parent=processes.get(child.pid)
 if len(samples)==0 or time.monotonic()-start-samples[-1]['wall']>=10:
  statuses={}
  try:
   with sqlite3.connect(data/'journal.sqlite',timeout=1) as db:statuses=dict(db.execute('SELECT status,count(*) FROM chunks GROUP BY status'))
  except sqlite3.Error:pass
  sample={'wall':round(time.monotonic()-start,2),'parent_rss_kib':parent[1] if parent else None,'parent_cpu_percent':parent[2] if parent else None,'descendants':metrics,'statuses':statuses};samples.append(sample)
  (out/'samples.json').write_text(json.dumps(samples,indent=2))
 time.sleep(.5)
log.close();result={'exit':child.returncode,'duration':duration,'speed':speed,'wall':time.monotonic()-start,'peak_worker_rss_kib_sampled':peak_worker,'samples':len(samples),'folder':str(out)}
(out/'results.json').write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2));print((out/'run.log').read_text()[-1500:]);sys.exit(child.returncode)
