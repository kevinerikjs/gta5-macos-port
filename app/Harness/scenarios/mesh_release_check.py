"""GTA-152: mesh release (on by default below a 2,600 MB app limit) against the game's own CPU reads of mesh data.
Spawns cars, waits until their meshes are handed back, smashes every window (vehicle glass builds its shards from
the window's mesh), shoots a windscreen, then changes the back-buffer size live (the graphics device restore).
Screenshots to /tmp/gta-mesh-release/; the game must still answer at the end, and the log's mesh release line
shows how many pages came back because the game read them.

Needs `gta.py launch sandbox --env PG_SIM_MEMORY_LIMIT_MB=2098 ...` (or PG_MESH_RELEASE=2).
"""
import os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import gta

OUT = "/tmp/gta-mesh-release"
os.makedirs(OUT, exist_ok=True)
for _ in range(60):
    s = gta.call("state")
    if s.get("pos") and not s["status"] & 16: break
    gta.dismiss_autosave(); time.sleep(1)
gta.dismiss_autosave()
gta.teleport(217.8, -936.1, 24.3); time.sleep(4)
cars = []
for i, model in enumerate(["buffalo", "sultan", "bison"]):
    gta.batch("REQUEST_MODEL h:%s" % model)
    for _ in range(40):
        if gta.batch("HAS_MODEL_LOADED h:%s" % model)[0]["r"]["i"] & 1: break
        time.sleep(0.25)
    r = gta.batch("CREATE_VEHICLE h:%s %.1f -930.0 24.5 200.0 false false false" % (model, 212.0 + 5 * i))
    cars.append(r[0]["r"]["i"])
time.sleep(8)		# the renderer has had their uploads; their engine copies are handed back
gta.shot(OUT + "/cars.png")
for car in cars:
    gta.batch("; ".join("SMASH_VEHICLE_WINDOW %d %d" % (car, w) for w in range(8)))
time.sleep(1)
gta.batch("PLAYER_PED_ID; GIVE_WEAPON_TO_PED r:0 h:weapon_pistol 100 false true")
car = cars[0]
at = gta.batch("GET_OFFSET_FROM_ENTITY_IN_WORLD_COORDS %d 0.0 1.0 1.0" % car)[0]["v"]
gta.batch("SHOOT_SINGLE_BULLET_BETWEEN_COORDS %.2f %.2f %.2f %.2f %.2f %.2f 10 true h:weapon_pistol 0 true false 1000.0" % (at[0] + 6, at[1], at[2] + 1, at[0], at[1], at[2]))
time.sleep(2)
gta.shot(OUT + "/smashed.png")
for w, h in ((1400, 640), (938, 432)):
    gta.call("resize %d %d" % (w, h)); time.sleep(4)
gta.shot(OUT + "/after-resize.png")
alive = gta.call("state").get("pos") is not None
log = open(gta.log_path(), errors="replace").read()
lines = [l for l in log.splitlines() if "[metal] mesh release" in l]
print("game answers: %s" % alive)
print(lines[-1][:400] if lines else "no mesh release line (is it on?)")
print("Native trap" in log and "STOPPED" or "no trap")
