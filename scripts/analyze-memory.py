#!/usr/bin/env python3
"""Summarize local-only RSS/CPU samples; emits no audio, embeddings or text."""
import pathlib,json,statistics,sys,re
root=pathlib.Path(sys.argv[1]);samples=[json.loads(s) for s in (root/'samples.ndjson').read_text().splitlines()]
def slope(rows):
 if len(rows)<2:return None
 x=[r[0]/60 for r in rows];y=[r[1]/1024 for r in rows];mx=statistics.mean(x);my=statistics.mean(y)
 denom=sum((v-mx)**2 for v in x)
 return sum((a-mx)*(b-my) for a,b in zip(x,y))/denom if denom else 0
def summary(rows):
 if not rows:return {}
 n=min(6,len(rows));return {'samples':len(rows),'first_median_mib':statistics.median(r[1] for r in rows[:n])/1024,'last_median_mib':statistics.median(r[1] for r in rows[-n:])/1024,'min_mib':min(r[1] for r in rows)/1024,'max_mib':max(r[1] for r in rows)/1024,'rss_ols_mib_per_minute':slope(rows),'cpu_percent_median':statistics.median(r[2] for r in rows),'cpu_percent_max_sampled':max(r[2] for r in rows)}
recording=[s for s in samples if s['phase']=='recording'];origin=recording[0]['wall'] if recording else 0;last=recording[-1]['wall'] if recording else 0
result={'roles':{},'queue_max_sampled':max([0]+[s['statuses'].get('queued',0) for s in recording]),'disk_peak_mib':max(s['disk_bytes'] for s in samples)/1024**2,'last_statuses':samples[-1]['statuses'],'last_counts':samples[-1]['counts']}
for role in ['app','host']:
 result['roles'][role]={}
 for phase in ['idle_before','recording','idle_after']:
  rows=[(s['wall'],m['rss_kib'],m['cpu_percent']) for s in samples if s['phase']==phase for m in s['metrics'] if m['role']==role]
  result['roles'][role][phase]=summary(rows)
  if phase=='recording':
   result['roles'][role]['after_first_5_min']=summary([r for r in rows if r[0]>=origin+300])
   result['roles'][role]['last_30_min']=summary([r for r in rows if r[0]>=last-1800])
   result['roles'][role]['ten_minute_windows']=[{'minute':i,**summary([r for r in rows if origin+i*60<=r[0]<origin+(i+10)*60])} for i in range(0,int((last-origin)/60)+1,10)]
# Native heap summaries are physical footprint + live allocations, not model caches.
result['heap_snapshots']={}
for file in sorted(root.glob('*-heap-*.txt')):
 text=file.read_text();total=re.search(r'All zones: (\d+) nodes \((\d+) bytes\)',text)
 classes={name:re.findall(r'^\s*(\d+)\s+(\d+)\s+[^\n]*?'+re.escape(name)+r'\s',text,re.M)[:1] for name in ['NSConcreteData','CFString','Swift.StringStorage','AVAudioPCMBuffer','NSConcreteTask']}
 result['heap_snapshots'][file.name]={'nodes':int(total[1]) if total else None,'bytes':int(total[2]) if total else None,'selected_classes':classes}
result['leak_scans']={file.name:re.findall(r'\d+ leaks for \d+ total leaked bytes',file.read_text()) for file in root.glob('*-leaks-*.txt')}
(root/'analysis.json').write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2))
