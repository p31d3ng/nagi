#!/usr/bin/env python3
"""Deterministic synthetic-only integration checks. All output is Git-ignored."""
import pathlib,subprocess,sqlite3,json,uuid,sys,math,time
p=pathlib.Path(__file__).resolve().parents[1];output=p/'reports'/('verify-'+str(uuid.uuid4()));output.mkdir(parents=True)
h=p/'.build/debug/JournalHarness'
def run(args,name,expected=(0,)):
 start=time.monotonic()
 with (output/(name+'.log')).open('w') as log:r=subprocess.run([str(x) for x in args],stdout=log,stderr=subprocess.STDOUT,timeout=300)
 assert r.returncode in expected,(name,r.returncode,output/(name+'.log'))
 return round(time.monotonic()-start,3)
def connect(data):return sqlite3.connect(data/'journal.sqlite')
result={}
for name in ['english','mandarin','japanese','alternating','overlap','silence','noise']:
 data=output/(name+'Data');result[name]={}
 result[name]['import_wall']=run([h,'import',data,p/'Fixtures'/f'{name}.wav'],name+'-import')
 if name in ('mandarin','japanese'):
  with connect(data) as db:db.execute("UPDATE chunks SET model='whisper'");db.execute("UPDATE sessions SET model='whisper'")
 result[name]['process_wall']=run([h,'process',data,p],name+'-process')
 with connect(data) as db:
  counts=dict(db.execute('SELECT status,count(*) FROM chunks GROUP BY status'));text=' '.join(r[0] for r in db.execute('SELECT raw FROM segments ORDER BY offset'))
  result[name].update(statuses=counts,text=text,speakers=[r[0] for r in db.execute('SELECT DISTINCT speaker FROM segments')])
  assert not any(key in counts for key in ('failed','queued','processing','needs_speakers')),(name,counts)
  if name=='silence':assert counts.get('silence',0)>0 and not text
  if name=='english':assert 'journal' in text.lower()
  if name=='mandarin':assert '會議' in text or '会议' in text
  if name=='japanese':assert '会議' in text
# Force death with an open original-rate CAF tail, then recover.
crash=output/'CrashData';run([h,'crash',crash,p/'Fixtures/english.aiff'],'crash',(-9,));run([h,'recover',crash],'recover')
with connect(crash) as db:
 durations=[r[0] for r in db.execute('SELECT duration FROM chunks WHERE status="queued"')];assert len(durations)>=2 and min(durations)>0;result['crash_recovered_durations']=durations
# Missing models fail explicitly; retry against the actual project succeeds.
failure=output/'FailureData';run([h,'import',failure,p/'Fixtures/english.wav'],'failure-import');run([h,'process',failure,output/'MissingProject'],'failure-process')
with connect(failure) as db:assert dict(db.execute('SELECT status,count(*) FROM chunks GROUP BY status')).get('failed',0)>0
run([h,'process',failure,p],'failure-retry')
with connect(failure) as db:assert set(r[0] for r in db.execute('SELECT status FROM chunks'))=={'done'}
# Same-model synthetic profile discrimination, not a real-person accuracy claim.
worker=p/'.build/debug/SpeakerWorker'
run([worker,p/'Fixtures/english.wav',output/'english-speakers.json',p/'Models/Community1'],'profile-enrollment')
run([worker,p/'Fixtures/alternating.wav',output/'alternating-speakers.json',p/'Models/Community1'],'profile-alternating')
a=json.load(open(output/'english-speakers.json'));b=json.load(open(output/'alternating-speakers.json'))
v=next(iter(a['embeddings'].values()))
def cosine(a,b):return sum(x*y for x,y in zip(a,b))/math.sqrt(sum(x*x for x in a)*sum(x*x for x in b))
scores=sorted([cosine(v,w) for w in b['embeddings'].values()],reverse=True);assert len(scores)==2 and scores[0]>=.8 and scores[0]-scores[1]>=.12
result['synthetic_profile_scores']=scores
if '--stress' in sys.argv:
 data=output/'StressAudioData';run([h,'import',data,p/'Fixtures/stress-10min.wav'],'stress-import');run([h,'process',data,p],'stress-process')
 with connect(data) as db:result['stress_status']=dict(db.execute('SELECT status,count(*) FROM chunks GROUP BY status'));assert set(result['stress_status'])=={'done'}
(output/'results.json').write_text(json.dumps(result,ensure_ascii=False,indent=2));print(json.dumps(result,ensure_ascii=False,indent=2));print('Logs:',output)
