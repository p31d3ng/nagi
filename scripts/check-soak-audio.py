#!/usr/bin/env python3
"""Verify every original CAF sample against the repeated synthetic source, bounded per chunk."""
import pathlib,sqlite3,gzip,struct,wave,array,hashlib,json,sys
root=pathlib.Path(sys.argv[1]);source=pathlib.Path(__file__).resolve().parents[1]/'Fixtures/english.wav'
with wave.open(str(source)) as f:rate=f.getframerate();raw=f.readframes(f.getnframes())
i16=array.array('h');i16.frombytes(raw);expected_source=array.array('f',(x/32768 for x in i16));cursor=0;digest=hashlib.sha256();durations=[]
with sqlite3.connect(root/'journal.sqlite') as db:chunks=list(db.execute('SELECT path,duration,offset FROM chunks ORDER BY offset'))
for path,duration,offset in chunks:
 data=gzip.decompress((root/path).read_bytes()) if path.endswith('.gz') else (root/path).read_bytes();assert data[:4]==b'caff';pos=8;audio=None
 while pos+12<=len(data):
  kind=data[pos:pos+4];size=struct.unpack('>q',data[pos+4:pos+12])[0];pos+=12
  payload=data[pos:pos+size] if size>=0 else data[pos:]
  if kind==b'desc':
   hz,fmt,flags,packet,frames,channels,bits=struct.unpack('>d4sIIIII',payload);assert (hz,fmt,channels,bits)==(rate,b'lpcm',1,32);assert flags&1
  if kind==b'data':audio=payload[4:];break
  pos+=size
 assert audio is not None
 count=len(audio)//4;assert count==round(duration*rate),(path,count,duration)
 expected=array.array('f');left=count
 while left:
  n=min(left,len(expected_source)-cursor);expected.extend(expected_source[cursor:cursor+n]);cursor=(cursor+n)%len(expected_source);left-=n
 if not flags&2:expected.byteswap()
 assert audio==expected.tobytes(),('sample mismatch',path,offset)
 digest.update(audio);durations.append(duration)
result={'chunks':len(chunks),'seconds':sum(durations),'samples':round(sum(durations)*rate),'sha256_continuous_float32_audio':digest.hexdigest(),'exact_sample_continuity':True}
(root.parent/'audio-continuity.json').write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2))
