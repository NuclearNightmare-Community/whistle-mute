-- Load test for the test driver (test/WhistleMuteDriver/Scripts/main.lua) outside the game: it loads, builds its
-- steps, registers one game-thread loop and a LoadMap pre-hook, and runs a few ticks against an empty fake world (no
-- player controller yet) without a step throwing; map.txt picks only keys of its table; an unknown scenario or map
-- ends at once with a FAIL line. The scenario itself only runs in game (run.ps1).
-- Run from the repo root:  texlua test/unit/driver_test.lua
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."
local DIR = ROOT .. "/test/WhistleMuteDriver/Scripts"
local MAIN = DIR .. "/main.lua"
package.path = ROOT .. "/test/unit/?.lua;" .. package.path
local T = require("harness").new("driver_test")
local ok = T.ok

local printed, loops, pre = {}, {}, {}
local realWrite = io.write
print = function(s) printed[#printed + 1] = (tostring(s):gsub("\n$", "")) end
local INVALID = { IsValid = function() return false end }
function FindFirstOf() return INVALID end
function FindAllOf() return nil end
function StaticFindObject() return INVALID end
function LoopInGameThreadWithDelay(ms, fn) loops[#loops + 1] = { ms = ms, fn = fn } return #loops end
function CancelDelayedAction() return true end
function RegisterLoadMapPreHook(fn) pre[#pre + 1] = fn end
function LoopAsync() error("driver must not use LoopAsync") end
function FName(s) return s end

local function write(file, text) local f = assert(io.open(DIR .. "/" .. file, "w")); f:write(text); f:close() end
local function has(pat) for _, l in ipairs(printed) do if l:find(pat) then return l end end return nil end
local function load(scenario, map)
    printed, loops, pre = {}, {}, {}
    write("scenario.txt", scenario)
    if map then write("map.txt", map) else os.remove(DIR .. "/map.txt") end
    local okL, err = pcall(dofile, MAIN)
    os.remove(DIR .. "/scenario.txt"); os.remove(DIR .. "/map.txt")
    return okL, err
end

local okL, err = load("match")
ok(okL, "match: loads", err)
ok(has("^%[WhistleMuteDriver%] SCENARIO match$"), "match: logs its scenario")
ok(has("^%[WhistleMuteDriver%] MAP TowerIsland /Game/Maps/SmallLoweIsland/SmallMap$"), "match: Tower Island by default")
local loaded = has("^%[WhistleMuteDriver%] LOADED %d+ steps$")
ok(loaded and tonumber(loaded:match("(%d+) steps")) > 15, "match: builds its steps", loaded)
ok(#loops == 1 and loops[1].ms == 250, "match: one 250 ms game-thread loop")
ok(#pre == 1, "match: one LoadMap pre-hook")
for _ = 1, 10 do local okT, e = pcall(loops[1].fn); ok(okT, "match: tick runs", e) end
ok(pcall(pre[1]), "match: the pre-hook runs with nothing loaded")
ok(has("^%[WhistleMuteDriver%] PRELOAD n=1 Volume=none$"), "match: the pre-hook logs the Volume (none here)")
ok(not has("threw"), "match: no step threw")

okL = load("match", "Forest")
ok(okL and has("^%[WhistleMuteDriver%] MAP Forest /Game/Maps/ForestMap/ForestMap$"), "map.txt Forest")
okL = load("match", "  Crevasse\r\n")
ok(okL and has("^%[WhistleMuteDriver%] MAP Crevasse "), "map.txt with spaces and a newline")

okL = load("match", "../../evil")
ok(okL and has("END result=FAIL .*unknown%-map %.%./%.%./evil") and #loops == 0, "unknown map: END FAIL, no loop")
okL = load("bogus")
ok(okL and has("END result=FAIL .*unknown%-scenario bogus") and #loops == 0, "unknown scenario: END FAIL, no loop")

io.write = realWrite
T.done()
