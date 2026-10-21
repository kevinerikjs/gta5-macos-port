"""GTA-5: Self Radio plays the player's own songs in a car.

Needs at least three songs in the app's Documents/Self Radio before the launch, each a steady tone of its
own pitch (for example made with ffmpeg: sine=frequency=523, 659, 784, 1047). Puts the player in a car,
tunes it to Self Radio (RADIO_19_USER), saves 12 s of the game's sound (debug channel "audiodump") and
finds which test tone is the loudest; then skips to the next song and does it again. Screenshots and the
sound go to /tmp/gta-self-radio/.

    gta.py launch sandbox   (with the songs in place), then: python3 Harness/scenarios/self_radio.py
"""
import math, os, struct, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import gta

OUT = "/tmp/gta-self-radio"
TONES = {523: "C5", 659: "E5", 784: "G5", 1047: "C6"}
os.makedirs(OUT, exist_ok=True)

def level(samples, rate, frequency):
    """Goertzel: the strength of one frequency in the samples."""
    k = 2 * math.cos(2 * math.pi * frequency / rate)
    s1 = s2 = 0.0
    for x in samples:
        s1, s2 = x + k * s1 - s2, s1
    return math.sqrt(max(0.0, s1 * s1 + s2 * s2 - k * s1 * s2)) / len(samples)

def listen(name, seconds=12):
    path = os.path.join(gta.container(), "Documents", name + ".f32")
    reply = gta.call("audiodump %s %d" % (path, seconds))
    if not reply.get("ok"): raise SystemExit("audiodump: %s" % reply)
    time.sleep(seconds + 1.5)
    data = open(path, "rb").read()
    frames = len(data) // 8
    values = struct.unpack("<%df" % (frames * 2), data[:frames * 8])
    mono = [(values[2 * i] + values[2 * i + 1]) / 2 for i in range(frames)]
    rms = math.sqrt(sum(v * v for v in mono) / max(1, len(mono)))
    window = mono[len(mono) // 3: len(mono) // 3 + 48000]   # one second from the middle
    levels = {f: level(window, 48000, f) for f in TONES}
    best = max(levels, key=levels.get)
    others = sorted(levels.values())[-2]
    print("%s: %.1f s of sound, RMS %.4f; tone levels %s -> %s (%.0fx the next)" % (
        name, frames / 48000, rms, ", ".join("%s %.4f" % (TONES[f], levels[f]) for f in TONES), TONES[best], levels[best] / max(others, 1e-9)))
    return TONES[best] if levels[best] > 4 * others and levels[best] > 0.001 else None

for _ in range(60):
    s = gta.call("state")
    if s.get("pos") and not s["status"] & 16: break
    gta.dismiss_autosave(); time.sleep(1)
gta.dismiss_autosave()
gta.teleport(217.8, -936.1, 24.3); time.sleep(4)
gta.batch("REQUEST_MODEL h:buffalo")
for _ in range(40):
    if gta.batch("HAS_MODEL_LOADED h:buffalo")[0]["r"]["i"] & 1: break
    time.sleep(0.25)
car = gta.batch("CREATE_VEHICLE h:buffalo 214.0 -930.0 24.5 200.0 false false false")[0]["r"]["i"]
gta.batch("PLAYER_PED_ID; SET_PED_INTO_VEHICLE r:0 %d -1" % car)
time.sleep(2)
gta.batch("SET_VEHICLE_ENGINE_ON %d true true false; SET_VEHICLE_RADIO_ENABLED %d true; SET_VEH_RADIO_STATION %d RADIO_19_USER" % (car, car, car))
time.sleep(3)
def text(address):
    """A C string in the game's memory."""
    if not address: return ""
    raw = bytes.fromhex(gta.call("peek %d 64" % address).get("hex", ""))
    return raw.split(b"\0")[0].decode("latin1")
station = text(gta.batch("GET_PLAYER_RADIO_STATION_NAME")[0]["r"]["i"])
print("station: %s" % station)
gta.shot(OUT + "/tuned.png")
# Shuffle (the app's default play order) starts songs at the beginning; the touch Next song button skips one;
# a song that ends gives way to the next by itself (the test songs are 25 s long).
first = listen("self-radio-1", 8)
tapped = gta.call("tap @nextSong")
print("Next song button: %s" % ("tapped" if tapped.get("ok") else "not shown (%s)" % tapped.get("error")))
time.sleep(3)
gta.shot(OUT + "/next.png")
second = listen("self-radio-2", 8)
time.sleep(18)		# the second song ends: the station moves on by itself
third = listen("self-radio-3", 8)
# Shuffle never plays a song twice in a row: six more Next song taps, then the order the songs started in.
for _ in range(6):
    gta.call("tap @nextSong"); time.sleep(4)
# The radio wheel, held open with the touch Radio button: Self Radio should be on it.
if gta.call("touch 9 down @radio").get("ok"):
    time.sleep(2); gta.shot(OUT + "/wheel.png"); gta.call("touch 9 up")
log = open(gta.log_path(), errors="replace").read()
for line in log.splitlines():
    if line.startswith("Self Radio") or "user music" in line.lower(): print("log: " + line[:200])
print("game answers: %s" % (gta.call("state").get("pos") is not None))
print("Native trap" in log and "STOPPED" or "no trap")
plays = [l for l in log.splitlines() if l.startswith("Self Radio: playing")]
order = [l.split()[3] for l in plays]
repeats = sum(1 for a, b in zip(order, order[1:]) if a == b)
print("song order: %s (%d back to back)" % (" ".join(order), repeats))
print("RESULT: first song %s, after Next song %s, after it ended %s; %d songs started -> %s" % (first, second, third, len(plays),
      "PASS" if first and second and third and first != second and second != third and tapped.get("ok") and not repeats else "FAIL"))
