-- settings.txt: a 1.x file (what Resource Markers 1.0 wrote) keeps its layer choices and shared keys, and what 2.x
-- writes reads back the same. Usage: lua5.4 tests/test-settings.lua (writes only in a temp folder).
local here = arg[0]:match("^(.*)/tests/") or "."
package.path = here .. "/ResourceMarkers/Scripts/?.lua;" .. package.path
local dir = os.tmpname()
os.remove(dir)
os.execute("mkdir -p '" .. dir .. "'")
local Util = require("Modules.util")
Util.mod_dir = function() return dir end
local Settings = require("Modules.settings")

local fails = 0
local function check(ok, what)
    if not ok then
        fails = fails + 1
        print("  FAIL: " .. what)
    end
end
local function write(text)
    local f = assert(io.open(dir .. "/settings.txt", "w"))
    f:write(text)
    f:close()
end

-- As 1.0's Settings.save wrote it: its own keys first, then cat.<id> per category (branches is gone in 2.x).
write("enabled=1\nhide_depleted=0\nrange_m=500\nicon_size=32\nmenu_key=F8\n" ..
      "cat.copper=0\ncat.tin=1\ncat.flax=1\ncat.stone=1\ncat.branches=1\n")
Settings.load()
check(Settings.layers.copper == false and Settings.layers.tin == true and Settings.layers.flax == true
    and Settings.layers.stone == true, "1.x layer choices carry over")
check(Settings.icon_size == 32 and Settings.menu_key == "F8" and Settings.enabled == true,
    "1.x shared keys carry over")
check(Settings.layers.branches == nil and Settings.range_m == nil and Settings.hide_depleted == nil,
    "1.x keys that 2.x doesn't have are ignored")
check(Settings.layers.items == true and Settings.layers.iron == false,
    "layers the file doesn't name keep their defaults")

-- What 2.x writes: cat.<id> for every layer, read back the same.
Settings.layers.iron = true
Settings.group_m = 200
Settings.save()
local text = io.open(dir .. "/settings.txt"):read("a")
check(text:find("\ncat%.iron=1\n") and text:find("\ncat%.copper=0\n") and not text:find("layer%."), "saved as cat.<id>")
Settings.layers.iron, Settings.group_m = false, 150
Settings.load()
check(Settings.layers.iron == true and Settings.group_m == 200 and Settings.icon_size == 32, "saved settings read back")

os.execute("rm -rf '" .. dir .. "'")
print(fails == 0 and "  OK" or string.format("  %d check(s) failed", fails))
os.exit(fails == 0 and 0 or 1)
