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

okL, err = load("pair-listen")
ok(okL, "pair-listen: loads", err)
ok(has("^%[WhistleMuteDriver%] SCENARIO pair%-listen$"), "pair-listen: logs its scenario")
loaded = has("^%[WhistleMuteDriver%] LOADED %d+ steps$")
ok(loaded and tonumber(loaded:match("(%d+) steps")) > 15, "pair-listen: builds its steps", loaded)
for _ = 1, 10 do local okT, e = pcall(loops[1].fn); ok(okT, "pair-listen: tick runs", e) end
ok(not has("threw"), "pair-listen: no step threw")

-- pair-listen against a fake match: a local and a remote character, the whistle mapping, the AudioMixer recorder, and
-- a fake request server that answers "vmkey whistle" by running the WhistleALL hook for the REMOTE character (or not).
local function fakePair(opts)
    local calls, hooks = { rec = {}, keys = {} }, {}
    local function v(x, y, z) return { X = x, Y = y, Z = z } end
    local function obj(t) t.IsValid = function() return true end return t end
    local function name(n) return { ToString = function() return n end } end
    local me = obj({ IsLocallyControlled = function() return true end, K2_GetActorLocation = function() return v(0, 0, 0) end,
        GetClass = function() return { GetFName = function() return name("BP_FirstPersonCharacter_C") end } end })
    local other = obj({ IsLocallyControlled = function() return false end, K2_GetActorLocation = function() return v(300, 400, 0) end,
        GetClass = function() return { GetFName = function() return name("BP_FirstPersonCharacter_C") end } end })
    local world = obj({ GetFullName = function() return "World /Game/Maps/SmallLoweIsland/SmallMap.SmallMap" end })
    local pcObj = obj({ GetWorld = function() return world end, K2_GetPawn = function() return me end })
    local wave = obj({ Volume = 0 })
    local amb = obj({ StartRecordingOutput = function() calls.rec[#calls.rec + 1] = "start" end,
        StopRecordingOutput = function(_, _, _, n) calls.rec[#calls.rec + 1] = "stop " .. n end })
    local mapping = { Action = { GetFName = function() return name("IA_Whistle") end }, Key = { KeyName = name("G") } }
    local imc = obj({ GetFName = function() return name("IMC_Default") end,
        Mappings = setmetatable({ GetArrayNum = function() return 1 end }, { __index = function(_, i) if i == 1 then return mapping end end }) })
    FindFirstOf = function() return pcObj end
    FindAllOf = function(n)
        if n == "BP_FirstPersonCharacter_C" then return { me, other } end
        if n == "InputMappingContext" then return { imc } end
        return {}
    end
    StaticFindObject = function(p)
        if p:find("Whistle01", 1, true) then return wave end
        if p:find("AudioMixer", 1, true) then return amb end
        return obj({ CollectGarbage = function() end })
    end
    RegisterHook = function(n, fn) hooks[n] = fn return 1, 2 end
    local served = 0
    local function serve()
        local f = io.open(DIR .. "/request.txt", "r")
        if not f then return end
        local s = f:read("*a"); f:close()
        local seq, cmd = s:match("^(%d+) (.+)$")
        if seq and tonumber(seq) > served then
            served = tonumber(seq)
            calls.keys[#calls.keys + 1] = cmd
            if cmd == "vmkey whistle" and opts.whistles then
                local h = hooks["/Game/FirstPerson/Blueprints/BP_FirstPersonCharacter.BP_FirstPersonCharacter_C:WhistleALL"]
                if h then h({ get = function() return other end }) end
            end
            local d = io.open(DIR .. "/done.txt", "w"); d:write(tostring(served)); d:close()
        end
    end
    return calls, serve
end
local realClock2 = os.clock
local fakeT = 0
os.clock = function() return fakeT end
for _, o in ipairs({ { whistles = true, what = "the client whistles" }, { whistles = false, what = "the client never whistles" } }) do
    local calls, serve = fakePair(o)
    local okF, e = load("pair-listen")
    ok(okF, "fake pair (" .. o.what .. "): loads", e)
    for _ = 1, 2000 do fakeT = fakeT + 0.25; pcall(loops[1].fn); serve(); if has("END result=") then break end end
    if o.whistles then
        ok(has("OK HOOK pair WhistleALL post%-hook"), "fake pair: hooks WhistleALL")
        ok(has("KEYMAP IMC_Default action=IA_Whistle key=G$"), "fake pair: logs the whistle key")
        ok(has("OK REMOTE pair the other player's character is here %(BP_FirstPersonCharacter_C, dist 5%.0 m%)"), "fake pair: finds the remote character")
        for _, l in ipairs({ "muted", "loud", "muted2" }) do
            ok(has("OK CLIENTWHISTLE pair " .. l .. " the client's whistle played here at 0%.%d+ s"), "fake pair: " .. l .. " gets the client's whistle")
            ok(has("HEARD " .. l .. " remote at "), "fake pair: HEARD " .. l .. " remote")
        end
        ok(table.concat(calls.keys, ",") == "key ENTER,vmkey ENTER,vmkey whistle,vmkey whistle,vmkey whistle", "fake pair: requests in order", table.concat(calls.keys, ","))
        local stops = {}
        for _, c in ipairs(calls.rec) do if c:find("^stop ") then stops[#stops + 1] = c:sub(6) end end
        ok(table.concat(stops, ",") == "whistle-quiet1,whistle-muted,whistle-loud,whistle-muted2,whistle-quiet2", "fake pair: five recordings", table.concat(stops, ","))
        ok(has("OK SETVOL pair stock Volume=1%.00") and has("OK SETVOL pair muted Volume=0%.00"), "fake pair: stock Volume for loud, 0 again after")
        ok(has("END result=PASS"), "fake pair: END PASS", has("END result=") or "no END")
    else
        ok(has("MISSED pair muted no client whistle within 15 s %(try 1 of 3%)") and has("try 2 of 3"), "fake pair, no whistle: retries")
        ok(has("FAIL CLIENTWHISTLE pair muted no client whistle in 3 tries"), "fake pair, no whistle: FAIL after 3 tries")
        ok(has("END result=FAIL"), "fake pair, no whistle: END FAIL")
    end
    ok(not has("threw"), "fake pair (" .. o.what .. "): no step threw", has("threw"))
end
os.clock = realClock2
os.remove(DIR .. "/request.txt"); os.remove(DIR .. "/done.txt")

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
