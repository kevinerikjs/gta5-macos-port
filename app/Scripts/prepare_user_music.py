"""Self Radio: the player's own songs on the radio station RADIO_19_USER (GTA-5).

The PC game finds songs with Windows Media Foundation and decodes them in rage::audMediaReader.
This build has neither: RebuildFileDatabaseCB never scans and writes an empty song list, and
audRadioTrack::Prepare's reader never opens (it closes and frees it again and logs "Failed to
create radio track user music audMediaReader"). The song list file it reads (usertracks.db/.dbs)
and the station's stream player still work, so Source/NativeUserMusic.c does the missing parts:

- the app writes the song list from Documents/User Music before the engine starts
  (PGUserMusicPrepare); RebuildFileDatabaseCB only reports the scan finished (pg_user_music_scan),
  so the engine loads that list instead of an empty one;
- in Prepare, before the reader is closed, pg_user_music_open decodes the song natively into the
  reader's ring buffer; the reader is kept and Prepare continues as if it had opened;
- where the engine asks the reader's (missing) decoder for the song's length (Prepare) or its sample
  rate (Play, Update), pg_user_music_length and pg_user_music_rate answer;
- this game's audio data has no station settings for RADIO_19_USER, so the station was never made: where
  audMetadataManager::GetObject_Verify finds no object, pg_user_music_station answers for that one;
  its one track list has a reference in a chunk no game data has (0xFE), which GetObject_Verify(audMetadataRef)
  asks pg_user_music_ref about;
- shuffle never plays a song twice in a row: audRadioStation::ComputeRandomTrack picks the next song while the
  current one starts, before that one is in the station's history, so the pick also turns away the song it
  chose last (the current one);
- the radio wheel's movie has no icon for RADIO_19_USER: CRadioWheel::Update hands it another station name for
  Self Radio (pg_radio_wheel_name);
- audMediaReader::Close stops the song's decoding first (pg_user_music_close);
- audStreamPlayer::GenerateFrame tops the ring buffer up from the decoded song before it reads from
  it (pg_user_music_pump), on the thread that reads it.
"""
from pathlib import Path
from engine_names import fn
import re
root = Path(__file__).resolve().parents[1]
SCAN = fn('audUserRadioTrackManager::RebuildFileDatabaseCB(void*)')
HAS_USER_TRACKS = fn('audRadioStation::HasUserTracks()')
PREPARE = fn('audRadioTrack::Prepare(unsigned int)')
PLAY = fn('audRadioTrack::Play()')
UPDATE = fn('audRadioTrack::Update(unsigned int, bool)')
CLOSE = fn('rage::audMediaReader::Close()')
GENERATE = fn('rage::audStreamPlayer::GenerateFrame()')
METADATA = fn('rage::audMetadataManager::GetObject_Verify(unsigned int, unsigned int) const')
RANDOM_TRACK = fn('audRadioStation::ComputeRandomTrack(int&, int&)')
WHEEL = fn('CRadioWheel::Update(bool, bool)')
GET_STATION = fn('audRadioStation::GetStation(unsigned int)')
METADATA_REF = fn('rage::audMetadataManager::GetObject_Verify(rage::audMetadataRef, unsigned int) const')
MARK = 'pg_user_music_'
DECLARATIONS = ('extern u32 pg_user_music_scan(w2c_game *instance, u64 manager);\n'
                'extern u32 pg_user_music_open(w2c_game *instance, u64 track, u64 reader, u64 manager, u32 index, u32 start_ms);\n'
                'extern u32 pg_user_music_length(w2c_game *instance, u64 reader);\n'
                'extern u32 pg_user_music_rate(w2c_game *instance, u64 reader);\n'
                'extern void pg_user_music_close(w2c_game *instance, u64 reader);\n'
                'extern void pg_user_music_pump(w2c_game *instance, u64 player);\n'
                'extern u64 pg_user_music_station(w2c_game *instance, u32 hash, u32 type);\n'
                'extern u64 pg_user_music_ref(w2c_game *instance, u32 ref, u32 type);\n'
                'extern u64 pg_radio_wheel_name(w2c_game *instance, u64 settings, u64 name);')
MEMORY = r'wasm_rt_local_memory_base, wasm_rt_local_memory_size, instance->w2c_env_memory, '
# The reader's decoder (+4112) is null here, so the engine's answer is -1: the host answers instead.
DECODER = re.compile(r'(?:var_j\d = (var_l\d+)|(var_l\d+) = var_j\d);\n\s+var_j\d = i64_load_shared\(' + MEMORY +
                     r'\(u64\)checked_add_u64\(var_j\d, 4112u\)\);\n\s+var_l\d+ = var_j\d;\n\s+var_i\d = !\(var_j\d\);\n'
                     r'\s+if \(var_i\d\) \{\n\s+(var_i\d) = 4294967295u;')

def body_of(s, number):
    found = re.search(r'^\S.* w2c_game_f' + str(number) + r'\(w2c_game\* instance[^;\n]*\{$', s, re.M)
    if not found: return None
    return found.start(), s.index('\n}\n', found.start())

def at_entry(body, number, call):
    if body.count('  FUNC_PROLOGUE;\n') != 1: raise RuntimeError(f'Pinned f{number} changed')
    return body.replace('  FUNC_PROLOGUE;\n', call + '  FUNC_PROLOGUE;\n', 1)

def decoder_answer(body, number, host):
    found = list(DECODER.finditer(body))
    if len(found) != 1: raise RuntimeError(f'Pinned f{number} (decoder query) changed')
    m = found[0]
    reader, result = m[1] or m[2], m[3]
    return body[:m.start()] + m[0].replace(f'{result} = 4294967295u;', f'{result} = {host}(instance, {reader});') + body[m.end():]

def patch_prepare(body):
    # The reader just made: "...; var_j1 = <reader>; Close(reader); ..." then freed.
    close = re.findall(r'\n(\s+)var_j1 = (var_l\d+);\n\s+w2c_game_f' + str(CLOSE) + r'\(instance, var_j1\);\n', body)
    # The song's index in the list (track +2200) and, where the reader is given up, the restore of
    # the heap selector the function saved, then "track +2224 = 0; if (reader) goto <opened>".
    index = re.findall(r'checked_add_u64\(var_j1, 2200u\)\);\n\s+(var_l\d+) = var_i1;', body)
    give_up = re.findall(r'\n(\s+var_j1 = var_l\d+;\n\s+var_i2 = var_l\d+;\n\s+i32_store_shared\(' + MEMORY +
                         r'\(u64\)\(var_j1\), var_i2\);\n)\s+var_j1 = 0ull;\n\s+var_l\d+ = var_j1;\n\s+i64_store_shared\(' + MEMORY +
                         r'\(u64\)checked_add_u64\(var_j0, 2224u\), var_j1\);\n(?:\s+var_[jil]\d+ = [^\n]+;\n)+\s+if \(var_i1\) \{goto (var_B\d+);\}', body)
    if len(close) != 1 or len(index) != 1 or len(give_up) != 1: raise RuntimeError(f'Pinned f{PREPARE} (Prepare) changed')
    indent, reader = close[0]
    restore, opened = give_up[0]
    hook = (f'{indent}if (pg_user_music_open(instance, var_p0, {reader}, {MANAGER}ull, {index[0]}, var_p1)) {{\n'
            + ''.join(f'  {line}\n' for line in restore.rstrip('\n').split('\n'))
            + f'{indent}  var_i0 = 0u;\n{indent}  goto {opened};\n{indent}}}')
    anchor = f'\n{indent}var_j1 = {reader};\n{indent}w2c_game_f{CLOSE}(instance, var_j1);\n'
    body = body.replace(anchor, '\n' + hook + anchor, 1)
    return decoder_answer(body, PREPARE, 'pg_user_music_length')

# The song list's manager: the address HasUserTracks loads the list from.
MANAGER = None
for path in sorted((root / 'Generated').glob('game_*.c')):
    s = path.read_text()
    span = body_of(s, HAS_USER_TRACKS)
    if not span: continue
    addresses = re.findall(r'var_j0 = (\d+)ull;', s[span[0]:span[1]])
    if len(addresses) != 1: raise RuntimeError(f'Pinned f{HAS_USER_TRACKS} (HasUserTracks) changed')
    MANAGER = addresses[0]
    break
if not MANAGER: raise RuntimeError(f'Pinned function f{HAS_USER_TRACKS} not found')

def patch_metadata(body):
    # "object = GetObjectMetadataPtr(hash); if (!object) return 0;": the host answers instead of the 0.
    missing = '  if (var_i0) {\n    var_j0 = 0ull;\n    goto var_Bfunc;\n  }\n'
    if body.count(missing) != 1 or 'var_p1' not in body: raise RuntimeError(f'Pinned f{METADATA} (GetObject_Verify) changed')
    return body.replace(missing, missing.replace('var_j0 = 0ull;', 'var_j0 = pg_user_music_station(instance, var_p1, var_p2);'), 1)

def patch_random_track(body):
    # The song the pick chose last ("if 50 tries fail: last + 1"), and the history comparison in the tries.
    last = re.findall(r'\n  var_j1 = (\d+)ull;\n  var_i1 = i32_load_shared\(' + MEMORY + r'\(u64\)\(var_j1\)\);\n  var_i2 = 1u;\n  var_i1 \+= var_i2;\n'
                      r'  var_i2 = (var_l\d+);\n  var_i1 = I32_REM_S\(var_i1, var_i2\);\n  (var_l\d+) = var_i1;\n  goto var_B\d+;', body)
    compare = re.findall(r'\n(\s+)var_i1 = (var_l\d+);\n\s+var_i2 = var_l\d+;\n\s+var_j2 = \(u64\)\(var_i2\);\n\s+var_j3 = 2ull;\n\s+var_j2 <<= \(var_j3 & 63\);\n'
                         r'\s+var_j3 = \d+ull;\n\s+var_j2 \+= var_j3;\n\s+var_i2 = i32_load_shared\(' + MEMORY + r'\(u64\)\(var_j2\)\);\n(\s+var_i1 = var_i1 != var_i2;)\n', body)
    if len(last) != 1 or len(compare) != 1 or last[0][2] != compare[0][1]: raise RuntimeError(f'Pinned f{RANDOM_TRACK} (ComputeRandomTrack) changed')
    address, _, chosen = last[0]
    line = compare[0][2]
    return body.replace(line, line.replace('var_i1 = var_i1 != var_i2;', f'var_i1 = var_i1 != var_i2 && {chosen} != i32_load_shared(' + MEMORY.replace('\\', '') + f'(u64)({address}ull)); /* pg_user_music_: not the song it chose last */'), 1)

def patch_wheel(body):
    if 'pg_radio_wheel_name(' in body: return body
    # "name = GetStation(i)->settings (+6024) + 18; push name" for SET_RADIO_STATIONS and SET_ADDITIONAL_RADIO_STATIONS.
    pattern = re.compile(r'(var_j0 = w2c_game_f' + str(GET_STATION) + r'\(instance, var_i0\);\n\s+var_j0 = i64_load_shared\(' + MEMORY +
                         r'\(u64\)checked_add_u64\(var_j0, 6024u\)\);\n\s+var_j1 = 18ull;\n\s+)var_j0 \+= var_j1;')
    if len(pattern.findall(body)) != 2: raise RuntimeError(f'Pinned f{WHEEL} (CRadioWheel::Update) changed')
    return pattern.sub(lambda m: m[1] + 'var_j0 = pg_radio_wheel_name(instance, var_j0, var_j0 + var_j1);', body)

PATCHES = {
    SCAN: lambda body: at_entry(body, SCAN, '  { if (pg_user_music_scan(instance, var_p0)) return; }\n'),
    PREPARE: patch_prepare,
    PLAY: lambda body: decoder_answer(body, PLAY, 'pg_user_music_rate'),
    UPDATE: lambda body: decoder_answer(body, UPDATE, 'pg_user_music_rate'),
    CLOSE: lambda body: at_entry(body, CLOSE, '  pg_user_music_close(instance, var_p0);\n'),
    GENERATE: lambda body: at_entry(body, GENERATE, '  pg_user_music_pump(instance, var_p0);\n'),
    METADATA: patch_metadata,
    RANDOM_TRACK: patch_random_track,
    WHEEL: patch_wheel,
    METADATA_REF: lambda body: at_entry(body, METADATA_REF, '  if ((var_p1 >> 24) == 254u) return pg_user_music_ref(instance, var_p1, var_p2);\n'),
}
found, patched = set(), 0
for path in sorted((root / 'Generated').glob('game_*.c')):
    s = original = path.read_text()
    for number, patch in PATCHES.items():
        span = body_of(s, number)
        if not span: continue
        found.add(number)
        start, end = span
        if MARK in s[start:end]: continue
        s = s[:start] + patch(s[start:end]) + s[end:]
    if s == original: continue
    if 'extern u64 pg_radio_wheel_name(' not in s:
        first = re.search(r'^#include "game-[a-z-]*impl\.h"$', s, re.M)
        s = s[:first.end()] + '\n' + DECLARATIONS + s[first.end():]
    path.write_text(s)
    patched += 1
    print(f'Self Radio: patched {path.name}')
missing = set(PATCHES) - found
if missing: raise RuntimeError(f'Self Radio: f{", f".join(map(str, sorted(missing)))} not found')
if not patched: print('Self Radio: already patched')
