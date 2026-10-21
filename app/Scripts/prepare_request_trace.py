"""Trace (PG_TRACE_REQUEST_INDEX=N, GTA-151): which exit of
rage::strStreamingInfoManager::RequestObject turns down streaming object N.

A big add-on car's texture dictionary (cbr1000rrr.ytd, 148 MB of graphics memory) is refused when its model asks for it
("Request failed for ... requesting dependency ... failed") without a message of its own. Each of the function's exits
now reports its number and the answer to pg_trace_request_exit (Source/EngineHost.c).
"""
from pathlib import Path
from engine_names import fn
import re
root = Path(__file__).resolve().parents[1]
function = fn('rage::strStreamingInfoManager::RequestObject(rage::strIndex, int)')
DECLARATION = 'extern void pg_trace_request_exit(u32 index, u32 exit, u32 result);'
path = next(p for p in sorted((root / 'Generated').glob('game_*.c')) if re.search(rf'^u32 w2c_game_f{function}\(w2c_game\* instance', p.read_text(), re.M))
s = path.read_text()
head = re.search(rf'^u32 w2c_game_f{function}\(w2c_game\* instance[^\n]*\{{$', s, re.M)
start = head.start(); end = s.index('\n}\n', start) + 3
body = s[start:end]
if 'pg_trace_request_exit(' in body:
    print(f'request trace: f{function} already patched')
else:
    count = [0]
    def tag(m):
        count[0] += 1
        return '{ pg_trace_request_exit(var_p1, %d, var_l16); goto var_B1; }' % count[0]
    body = re.sub(r'goto var_B1;', tag, body)
    if '  var_B1:;\n' not in body:
        raise RuntimeError(f'Pinned f{function} (RequestObject) changed: exit label not found')
    body = body.replace('  var_B1:;\n', '  pg_trace_request_exit(var_p1, 0, var_l16);\n  var_B1:;\n', 1)
    s = s[:start] + body + s[end:]
    if DECLARATION not in s:
        first = re.search(r'^#include "game-[a-z-]*impl\.h"$', s, re.M)
        s = s[:first.end()] + '\n' + DECLARATION + s[first.end():]
    path.write_text(s)
    print(f'request trace: patched f{function} ({count[0]} exits) in {path.name}')
