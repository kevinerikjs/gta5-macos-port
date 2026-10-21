"""GTA-148: texture thrash at a small memory limit. Drives fast through the city for SECONDS and sums what the
memory guard did (evictions asked, streaming growth stopped) and how streaming kept up, from the Health lines
written during the drive; saves a screenshot of the ground at the end. Needs `gta.py launch` with the limit and
budget under test, for example:

    gta.py launch sandbox --env PG_MEMORY_GUARD=1 --env PG_STREAM_MEMORY_LIMIT_MB=2098 \\
        --env PG_SIM_MEMORY_LIMIT_MB=2098 --env PG_VIDEO_MEMORY_MB=640 --arg -graphicsPreset --arg -1
    python3 Harness/scenarios/texture_thrash.py [SECONDS] [LABEL]
"""
import json, math, os, re, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import gta

seconds = float(sys.argv[1]) if len(sys.argv) > 1 else 240
label = sys.argv[2] if len(sys.argv) > 2 else "run"
for _ in range(60):
    s = gta.call("state")
    if s.get("pos") and not s["status"] & 16: break
    gta.dismiss_autosave(); time.sleep(1)
gta.dismiss_autosave()
gta.teleport(195.0, -933.0, 30.5)   # Legion Square, then the car wanders the city at speed
time.sleep(4)
gta.batch("REQUEST_MODEL h:buffalo")
for _ in range(40):
    if gta.batch("HAS_MODEL_LOADED h:buffalo")[0]["r"]["i"] & 1: break
    time.sleep(0.25)
# The drive. PG_THRASH_ROUTE=rail (the default once texture_thrash_route.json exists) replays a recorded drive
# from Legion Square to the airport: the car is put where the recorded drive was at each moment, so every run
# covers the same streets at the same speed, even where the ground hasn't loaded (an AI driver stops or gets
# stuck there, which hides the churn). PG_THRASH_ROUTE=record drives that route with the AI driver, without a
# memory limit, and saves the drive for rail. airport and wander are the AI drives alone.
ROUTE_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "texture_thrash_route.json")
route = os.environ.get("PG_THRASH_ROUTE", "rail" if os.path.exists(ROUTE_FILE) else "airport")
drive = ("" if route == "rail" else
         " TASK_VEHICLE_DRIVE_WANDER r:0 r:2 40.0 786603" if route == "wander" else
         " TASK_VEHICLE_DRIVE_TO_COORD_LONGRANGE r:0 r:2 -1034.0 -2733.0 13.8 30.0 786468 10.0")
# The car starts on the road nearest the square (spawned in the park, the AI driver got stuck on its paths).
node = gta.batch("GET_CLOSEST_VEHICLE_NODE_WITH_HEADING 195.0 -933.0 30.5 p:3 p:1 1 3.0 0")[0]["out"]
at, heading = [w["f"] for w in node[0]], node[1][0]["f"]
made = gta.batch("PLAYER_PED_ID; GET_ENTITY_COORDS r:0 true; CREATE_VEHICLE h:buffalo %.2f %.2f %.2f %.1f false false false; SET_PED_INTO_VEHICLE r:0 r:2 -1;"
                 % (at[0], at[1], at[2] + 0.5, heading) + drive)
car = made[2]["r"]["i"]
rail = json.load(open(ROUTE_FILE)) if route == "rail" else None
while rail and len(rail) > 2 and rail[-2][1:4] == rail[-1][1:4]: rail.pop()   # parked at the end: not part of the drive
recorded = []
log = gta.log_path()
start_size = os.path.getsize(log)

def place(t):
    """Rail: the car where the recorded drive was t seconds in, moving at its speed; at the end it drives the
    route back, so the whole run is driving."""
    end = rail[-1][0]
    back = int(t // end) % 2 == 1
    t = end - t % end if back else t % end
    i = next((k for k in range(len(rail) - 1) if rail[k + 1][0] > t), len(rail) - 2)
    (t0, *a), (t1, *b) = rail[i], rail[i + 1]
    f = min(max((t - t0) / (t1 - t0), 0.0), 1.0)
    at = [a[k] + (b[k] - a[k]) * f for k in range(3)]
    v = [(b[k] - a[k]) / (t1 - t0) * (-1 if back else 1) for k in range(3)]
    gta.batch("SET_ENTITY_COORDS_NO_OFFSET %d %.2f %.2f %.2f false false false; SET_ENTITY_HEADING %d %.2f; "
              "SET_ENTITY_VELOCITY %d %.2f %.2f %.2f" % (car, *at, car, (a[3] + (180 if back else 0)) % 360, car, *v))

# PG_THRASH_SHOTS=N: a screenshot every N seconds during the drive (label-1.png, label-2.png, ...).
# PG_THRASH_DISARM_AT=N: take every weapon from the player N seconds in (does the inventory keep weapons streaming?).
every = float(os.environ.get("PG_THRASH_SHOTS", "0"))
disarm = float(os.environ.get("PG_THRASH_DISARM_AT", "0"))
os.makedirs("/tmp/gta-texture-thrash", exist_ok=True)
began, shots, last, travelled = time.monotonic(), 0, None, 0.0
while (t := time.monotonic() - began) < seconds:
    if rail: place(t)
    r = gta.batch("GET_ENTITY_COORDS %d true; GET_ENTITY_HEADING %d" % (car, car))
    at = r[0]["v"]
    if last: travelled += math.dist(at[:2], last[:2])
    last = at
    if route == "record" and (not recorded or t - recorded[-1][0] >= 0.5):
        recorded.append([round(t, 2)] + [round(c, 2) for c in at] + [round(r[1]["r"]["f"], 1)])
    if every and t >= every * (shots + 1):
        shots += 1
        gta.shot("/tmp/gta-texture-thrash/%s-%d.png" % (label, shots))
    if 0 < disarm <= t:
        disarm = 0
        gta.batch("PLAYER_PED_ID; REMOVE_ALL_PED_WEAPONS r:0 true")
        # The moment, on the clock the app's read trace uses (mach uptime, as time.monotonic on macOS).
        with open("/tmp/gta-texture-thrash/disarm-at-ms.txt", "w") as f: f.write("%.3f\n" % (time.monotonic() * 1000))
    time.sleep(0.25)
if route == "record":
    json.dump(recorded, open(ROUTE_FILE, "w"))
text = open(log, errors="replace").read()[start_size:]
health = re.findall(r"Health: memory (\d+) MB used, (\d+) MB free · guard stopped streaming growth (\d+)×, asked to evict (\d+)×"
                    r" · reads \d+ \(([\d.]+) MB.*?· ([\d.]+) FPS.*?streaming (\d+) waiting \((\d+) over 10 s\), loaded (\d+).*?unloaded (\d+)", text)
stopped = "Native trap" in text or "stopped:" in text
health = health[3:]		# the first ~30 s are the teleport's initial load, not churn
if not health:
    print("FAILED: no Health lines during the drive" + (" (the game stopped)" if stopped else "")); sys.exit(1)
n = len(health)
evict = sum(int(h[3]) for h in health); grow = sum(int(h[2]) for h in health)
thrash = sum(1 for h in health if int(h[3]) > 500 or int(h[2]) > 100)
reread = sum(float(h[4]) for h in health) / n; unloaded = sum(int(h[9]) for h in health) / n
waiting = sum(int(h[7]) for h in health) / n; loaded = sum(int(h[8]) for h in health)
free = sorted(int(h[1]) for h in health)[n // 2]; low = min(int(h[1]) for h in health); fps = sum(float(h[5]) for h in health) / n
os.makedirs("/tmp/gta-texture-thrash", exist_ok=True)
shot = "/tmp/gta-texture-thrash/%s.png" % label
gta.shot(shot)
def void(path):
    """Percent of the ground side of a screenshot that is the untextured void (flat grey 147): no map loaded there."""
    from PIL import Image
    im = Image.open(path).convert("RGB"); w, h = im.size
    im = im.crop((0, 0, w // 2, h)).resize((126, 274))		# a landscape game in a portrait capture: ground on the left
    px = getattr(im, "get_flattened_data", im.getdata)()
    return 100 * sum(1 for r, g, b in px if 140 <= r <= 155 and abs(r - g) <= 2 and abs(g - b) <= 2) / len(px)
try:
    voids = [void("/tmp/gta-texture-thrash/%s-%d.png" % (label, k)) for k in range(1, shots + 1)]
    ground = " · void ground %.0f%% (in %d of %d screenshots over 20%%)" % (sum(voids) / len(voids), sum(v > 20 for v in voids), len(voids)) if voids else ""
except ImportError:
    ground = ""
print("%s: drove %.1f km · %d intervals · evictions asked %.0f per interval · growth stopped %.0f per interval · thrashing %d%% of intervals · "
      "re-read %.0f MB and unloaded %.0f objects per interval · free median %d MB, lowest %d MB · %.1f requests over 10 s · %.0f FPS%s%s · %s"
      % (label, travelled / 1000, n, evict / n, grow / n, 100 * thrash // n, reread, unloaded, free, low, waiting, fps, ground, " · STOPPED" if stopped else "", shot))
