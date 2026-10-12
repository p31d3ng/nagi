#!/usr/bin/env python3
"""Read-only macOS process CPU/RSS diagnostic; no audio or subprocess polling."""
import argparse
import ctypes
import json
import pathlib
import struct
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--pid', type=int, required=True)
parser.add_argument('--seconds', type=int, default=65)
parser.add_argument('--output', type=pathlib.Path, required=True)
args = parser.parse_args()
if not 60 <= args.seconds <= 3600:
    parser.error('Use 60–3600 seconds for an idle profile.')

class Timebase(ctypes.Structure):
    _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]

base = Timebase()
system = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
system.mach_timebase_info(ctypes.byref(base))
scale = base.numer / base.denom / 1e9
libproc = ctypes.CDLL('/usr/lib/libproc.dylib')

def read():
    buffer = ctypes.create_string_buffer(1024)
    if libproc.proc_pid_rusage(args.pid, 4, ctypes.byref(buffer)) != 0:
        raise RuntimeError('Process counters unavailable; process may have exited.')
    user, kernel = struct.unpack_from('QQ', buffer, 16)
    rss = struct.unpack_from('Q', buffer, 64)[0]
    identity = struct.unpack_from('Q', buffer, 80)[0]
    return time.monotonic(), (user + kernel) * scale, rss, identity

previous = read()
rows = []
for _ in range(args.seconds):
    time.sleep(1)
    current = read()
    if current[3] != previous[3]:
        raise RuntimeError('PID identity changed; do not combine different processes.')
    elapsed = current[0] - previous[0]
    rows.append({'elapsed_s': elapsed, 'cpu_s': current[1] - previous[1],
                 'cpu_percent': (current[1] - previous[1]) / elapsed * 100,
                 'rss_bytes': current[2]})
    previous = current
result = {'pid': args.pid, 'cpu_convention': '100% = one CPU core',
          'mach_timebase': {'numer': base.numer, 'denom': base.denom},
          'mean_cpu_percent': sum(r['cpu_s'] for r in rows) / sum(r['elapsed_s'] for r in rows) * 100,
          'max_cpu_percent': max(r['cpu_percent'] for r in rows),
          'rss_max_bytes': max(r['rss_bytes'] for r in rows), 'samples': rows}
args.output.write_text(json.dumps(result, indent=2))
print(json.dumps({k: v for k, v in result.items() if k != 'samples'}))
