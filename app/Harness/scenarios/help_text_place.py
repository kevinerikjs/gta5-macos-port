"""Help message place: shows a help message (the box with "Press ... to ...") and saves a screenshot, for checking
where the box lands with PG_HELP_TEXT="x,y,scale" (and PG_MINIMAP for the map).

    gta.py launch sandbox --env PG_HELP_TEXT=0.797,0,1 ; python3 Harness/scenarios/help_text_place.py out.png
"""
import os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import gta

out = sys.argv[1] if len(sys.argv) > 1 else "/tmp/help-text.png"
for _ in range(60):
    s = gta.call("state")
    if s.get("pos") and not s["status"] & 16: break
    gta.dismiss_autosave(); time.sleep(1)
gta.dismiss_autosave()
time.sleep(3)
text = "s:Press ~INPUT_CONTEXT~ to test where help messages show. A second line of text, and a third, as missions often have."
gta.batch("BEGIN_TEXT_COMMAND_DISPLAY_HELP STRING; ADD_TEXT_COMPONENT_SUBSTRING_PLAYER_NAME '%s'; END_TEXT_COMMAND_DISPLAY_HELP 0 false true -1" % text)
time.sleep(1.5)
gta.shot(out)
print("saved %s" % out)
