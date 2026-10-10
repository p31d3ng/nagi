#!/usr/bin/env python3
"""Synthetic-only fixtures using installed macOS TTS. Never reads microphone/private files."""
import pathlib, subprocess, wave, struct, random, json
root=pathlib.Path(__file__).resolve().parents[1]; out=root/'Fixtures';out.mkdir(exist_ok=True)
passages={
 'english':('Samantha','Today we planned the Stillpoint journal. The microphone receiver must never switch silently. Meet Alex on Tuesday at three. Boundary words: parakeet, Kyoto, SQLite, DJI.'),
 'english2':('Daniel','I agree. Let us review the budget and check every recovery path. The meeting ends tomorrow.'),
 'mandarin':('Tingting','今天我们讨论会议计划。请保存原始录音，并且不要自动切换麦克风。明天下午三点见。'),
 'japanese':('Kyoko','今日は会議の計画を話します。録音を保存してください。明日の午後三時に会いましょう。')}
audio={}
for name,(voice,text) in passages.items():
 subprocess.run(['say','-v',voice,'-r','155','-o',str(out/(name+'.aiff')),text],check=True)
 subprocess.run(['afconvert',str(out/(name+'.aiff')),str(out/(name+'.wav')),'-f','WAVE','-d','LEI16@16000','-c','1'],check=True)
 with wave.open(str(out/(name+'.wav')),'rb') as f:
  assert f.getnframes()>0, 'TTS produced empty fixture; run setup outside restricted sandbox'
  data=f.readframes(f.getnframes());audio[name]=list(struct.unpack('<'+'h'*(len(data)//2),data))
def write(name,values):
 with wave.open(str(out/(name+'.wav')),'wb') as f:f.setparams((1,2,16000,len(values),'NONE',''));f.writeframes(struct.pack('<'+'h'*len(values),*values))
silence=[0]*16000
write('alternating',audio['english']+silence+audio['english2']+silence+audio['english']+silence+audio['english2'])
a,b=audio['english'],audio['english2'];overlap=[int((a[i] if i<len(a) else 0)*.5+(b[i] if i<len(b) else 0)*.5) for i in range(max(len(a),len(b)))];write('overlap',overlap)
write('multilingual',audio['english']+silence+audio['mandarin']+silence+audio['japanese'])
write('silence',[0]*16000*22)
r=random.Random(20261010);write('noise',[r.randint(-150,150) for _ in range(16000*22)])
write('stress-10min',(audio['english']+silence)*int(600/(len(audio['english'])/16000+1)))
(out/'ground-truth.json').write_text(json.dumps({'voices':{k:{'voice':v,'text':t,'duration':len(audio[k])/16000} for k,(v,t) in passages.items()},'synthetic':True,'seed':20261010,'notes':'Alternating speaker order Samantha, Daniel, Samantha, Daniel. Overlap mixes both from t=0. Synthetic embeddings are not evidence of real-person accuracy.'},ensure_ascii=False,indent=2))
print('Synthetic fixtures created',out)
