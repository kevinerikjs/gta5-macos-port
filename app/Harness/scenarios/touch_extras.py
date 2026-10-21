"""GTA-149 / GTA-150: touch buttons that were missing.

1. On a BMX the touch controls show Jump (bikeJump), and holding it makes the bike hop (INPUT_VEH_JUMP, R1).
2. A help that names the script D-pad ("Use ~INPUT_SCRIPT_PAD_LEFT~ to call.", the elk call in hunting2) brings up a
   D-pad left button in the mission row, and holding it reaches the game as INPUT_SCRIPT_PAD_LEFT (frontend control
   group 2, input 234, which hunting2 reads with IS_CONTROL_JUST_RELEASED).

Needs `gta.py launch sandbox`. Prints PASS/FAIL per check and saves screenshots to /tmp/gta-touch-extras/.
"""
import os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import gta

OUT = "/tmp/gta-touch-extras"
os.makedirs(OUT, exist_ok=True)
results = []
def check(name, ok, detail=""):
    results.append(ok); print("%s %s%s" % ("PASS" if ok else "FAIL", name, " (%s)" % detail if detail else ""))
def visible(name): return any(b["name"] == name for b in gta.call("ui").get("visible", []))
def wait_visible(name, seconds=6):
    end = time.time() + seconds
    while time.time() < end:
        if visible(name): return True
        time.sleep(0.25)
    return False

for _ in range(60):
    s = gta.call("state")
    if s.get("pos") and not s["status"] & 16: break
    gta.dismiss_autosave(); time.sleep(1)
gta.dismiss_autosave()

# 1. BMX jump, on the road next to Legion Square.
gta.teleport(217.8, -936.1, 24.3); time.sleep(4)
gta.batch("REQUEST_MODEL h:bmx")
for _ in range(40):
    if gta.batch("HAS_MODEL_LOADED h:bmx")[0]["r"]["i"] & 1: break
    time.sleep(0.25)
made = gta.batch("PLAYER_PED_ID; GET_ENTITY_COORDS r:0 true; CREATE_VEHICLE h:bmx 217.8 -936.1 24.3 290.0 false false false; SET_PED_INTO_VEHICLE r:0 r:2 -1")
bike = made[2]["r"]["i"]
time.sleep(2.5)
check("Jump shows on a BMX", wait_visible("bikeJump"))
gta.shot(OUT + "/bmx.png")
def height(): return gta.batch("GET_ENTITY_HEIGHT_ABOVE_GROUND %d" % bike)[0]["r"]["f"]
base = height()
gta.call("tap @bikeJump 0.5")
peak = base
for _ in range(16):
    time.sleep(0.1); peak = max(peak, height())
check("Holding Jump makes the bike hop", peak - base > 0.15, "height above ground %.2f m, highest %.2f m" % (base, peak))
gta.batch("PLAYER_PED_ID; TASK_LEAVE_ANY_VEHICLE r:0 0 16"); time.sleep(3)
check("Jump is gone on foot", not visible("bikeJump"))

# 2. A help that names the script D-pad left.
def show_help():
    gta.batch('0x8509B634FBE7DA11 s:STRING; 0x6C188BE134E074AA "s:Use ~INPUT_SCRIPT_PAD_LEFT~ to call."; 0x238FFE5C7B0498A6 0 false true -1')
show_help()
check("D-pad left shows for the help", wait_visible("script_pad_left"))
gta.shot(OUT + "/help-dpad-left.png")
gta.call("tap @script_pad_left 1.0")
pressed = False
for _ in range(8):
    time.sleep(0.1)
    if gta.batch("IS_CONTROL_PRESSED 2 234")[0]["r"]["i"] & 1: pressed = True; break
check("Holding it presses INPUT_SCRIPT_PAD_LEFT", pressed)
time.sleep(1.2)
check("Released again", not gta.batch("IS_CONTROL_PRESSED 2 234")[0]["r"]["i"] & 1)
gta.batch("0x8DFCED7A656F8802 true")	# CLEAR_HELP
time.sleep(2)
check("No D-pad button without the help", not visible("script_pad_left"))
print("ALL PASS" if all(results) else "SOME FAILED")
