"""Trace (PG_TRACE_STREAM_ALLOC, GTA-151): the streaming allocator's answers for big blocks.

rage::strStreamingAllocator::Allocate and TryAllocate return the block or 0. Big add-on cars have texture
dictionaries with 32 MB pages (cbr1000rrr.ytd: 4 x 32 MB + 16 MB + 4 MB of graphics memory), and their spawn never
finished, with nothing in the log. Both functions now report each request of 1 MB or more and its answer to
pg_trace_stream_alloc (Source/EngineHost.c), which logs them when the switch is on.
"""
from pathlib import Path
from engine_names import fn
import re
root = Path(__file__).resolve().parents[1]
DECLARATION = 'extern void pg_trace_stream_alloc(u32 kind, u64 size, u64 align, u32 type, u64 result);'
for kind, name in ((0, 'rage::strStreamingAllocator::Allocate(unsigned long, unsigned long, int)'),
                   (1, 'rage::strStreamingAllocator::TryAllocate(unsigned long, unsigned long, int)')):
    function = fn(name)
    path = next(p for p in sorted((root / 'Generated').glob('game_*.c')) if re.search(rf'^u64 w2c_game_f{function}\(w2c_game\* instance', p.read_text(), re.M))
    s = path.read_text()
    head = re.search(rf'^u64 w2c_game_f{function}\(w2c_game\* instance, u64 var_p0, u64 var_p1, u64 var_p2, u32 var_p3\) {{\n', s, re.M)
    if not head:
        raise RuntimeError(f'Pinned f{function} ({name}) changed: signature not found')
    start = head.start(); end = s.index('\n}\n', start) + 3
    body = s[start:end]
    if 'pg_trace_stream_alloc(' in body:
        print(f'stream alloc trace: f{function} already patched'); continue
    body = body.replace(head.group(0), head.group(0) + '  const u64 pg_size = var_p1, pg_align = var_p2; const u32 pg_type = var_p3;\n', 1)
    tail = '  FUNC_EPILOGUE;\n  return var_j0;\n}\n'
    if body.count(tail) != 1:
        raise RuntimeError(f'Pinned f{function} ({name}) changed: single return not found')
    body = body.replace(tail, f'  pg_trace_stream_alloc({kind}, pg_size, pg_align, pg_type, var_j0);\n' + tail, 1)
    s = s[:start] + body + s[end:]
    if DECLARATION not in s:
        first = re.search(r'^#include "game-[a-z-]*impl\.h"$', s, re.M)
        s = s[:first.end()] + '\n' + DECLARATION + s[first.end():]
    path.write_text(s)
    print(f'stream alloc trace: patched f{function} in {path.name}')
