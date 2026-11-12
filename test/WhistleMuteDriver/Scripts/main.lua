-- WhistleMuteDriver: WhistleMute's test driver. Installed only by deploy.ps1 -Test, never shipped; the mod itself
-- carries no test code. Plain UE4SS Lua: it can't reach the mod's Lua state, so it judges the mod by the wave's
-- Volume and by what the game's audio output records while the local character whistles.
--
-- mods.txt order (deploy.ps1): WhistleMuteDriver, WhistleMute (above Keybinds). The driver's LoadMap pre-hook reads the
-- wave's Volume before the mod's post-hook sets it: that is the Volume each map starts with (stock, or what an earlier
-- map left), which settles the SPEC's "does a reload reset Volume?".
--
-- Scenario (Scripts/scenario.txt, written by deploy.ps1; one combined scenario, one match map):
--   match: menu (Volume 0) -> <map>?listen -> touchdown -> Volume 0 -> four recordings of the game's audio output
--          (StartRecordingOutput / StopRecordingOutput to a .wav next to this file), each REC_S seconds:
--            quiet1  nobody whistles
--            muted   the local character whistles through the game's own WhistleServer -> WhistleALL, with the mod's
--                    Volume 0 (the "with the mod" case)
--            loud    the same whistle with the wave's Volume put back to its stock value (the "without the mod" case,
--                    in the same run); the driver then sets 0 again
--            quiet2  nobody whistles
--          check.ps1 compares them (the whistle's energy over the quiet windows' noise). Then a garbage collection
--          and the Volume again (does the wave survive a GC with its Volume?), menu -> Volume 0 there too.
-- Scripts/map.txt (deploy.ps1 -Map) holds only a key of the MAPS table; no file content ever becomes a path.
-- Keys it can't press itself (Enter for touchdown) go to run.ps1 through request.txt / done.txt next to this file.
-- Never keeps a UObject across steps: only paths, re-found each time.
local ME = "WhistleMuteDriver"
local WAVE = "/Game/Sounds/Whistle01.Whistle01"
local AMB = "/Script/AudioMixer.Default__AudioMixerBlueprintLibrary"
local KSL = "/Script/Engine.Default__KismetSystemLibrary"
local GSL = "/Script/Engine.Default__GameplayStatics"
local REC_S = 3.0     -- each recording's length (s); the whistle starts WHISTLE_AT s into it
local WHISTLE_AT = 0.5
local GAP_S = 1.5     -- between recordings, so one whistle's tail doesn't reach the next window
local WAV_EXPORT = 1  -- EAudioRecordingExportType::WavFile
local scriptDir = (debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") or "."

local function say(fmt, ...) print("[" .. ME .. "] " .. string.format(fmt, ...) .. "\n") end

local SCENARIO = "match"
do
    local f = io.open(scriptDir .. "\\scenario.txt", "r")
    if f then SCENARIO = (f:read("*a") or ""):match("^%s*([%w%-]+)") or SCENARIO; f:close() end
end
say("SCENARIO %s", SCENARIO)

local MENU_MAP = "/Game/Maps/NewMainMenu"
local MAPS = {
    LowIsland   = "/Game/Maps/Gameplay",
    TowerIsland = "/Game/Maps/SmallLoweIsland/SmallMap",
    Forest      = "/Game/Maps/ForestMap/ForestMap",
    Crevasse    = "/Game/Maps/CravasseMapV2/CravasseMap",
}
local MAP_KEY, MAP_BAD = "TowerIsland", nil
do
    local f = io.open(scriptDir .. "\\map.txt", "r")
    if f then
        local raw = f:read("*a") or ""
        f:close()
        local key = raw:match("^%s*(.-)%s*$")
        if MAPS[key] then MAP_KEY = key else MAP_BAD = key:gsub("[^%w%p ]", "?"):sub(1, 40) end
    end
end
local MATCH_MAP = MAPS[MAP_KEY]
say("MAP %s %s", MAP_KEY, MATCH_MAP)

local REQ, DONE = scriptDir .. "\\request.txt", scriptDir .. "\\done.txt"
os.remove(REQ); os.remove(DONE)

local S = { failures = 0, checks = 0, stock = nil, pre = {} }

local function valid(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end
local function found(path) local ok, o = pcall(StaticFindObject, path) return ok and valid(o) and o or nil end
local function check(cond, fmt, ...)
    S.checks = S.checks + 1
    if not cond then S.failures = S.failures + 1 end
    say("%s " .. fmt, cond and "OK" or "FAIL", ...)
    return cond
end
local function pc() local p = FindFirstOf("PlayerController") return valid(p) and p or nil end
local function world() local p = pc() return p and p:GetWorld() or nil end
local function worldName() local w = world() return w and w:GetFullName() or "" end
local function pawn()
    local p = pc()
    if not p then return nil end
    local ok, c = pcall(function() return p:K2_GetPawn() end)
    return ok and valid(c) and c or nil
end
local function volume()
    local w = found(WAVE)
    if not w then return nil end
    local ok, v = pcall(function() return w.Volume end)
    return ok and type(v) == "number" and v or nil
end
local function fmtVol(v) return v and string.format("%.2f", v) or "none" end

-- The Volume each map starts with: read before the mod's LoadMap post-hook (pre-hooks run first).
pcall(RegisterLoadMapPreHook, function()
    local v = volume()
    S.npre = (S.npre or 0) + 1
    S.pre[S.npre] = fmtVol(v)
    if v and v > 0 and not S.stock then S.stock = v end
    say("PRELOAD n=%d Volume=%s", S.npre, fmtVol(v))
end)

-- ---------------------------------------------------------------- steps and key requests
local seq = 0
local function request(cmd)
    seq = seq + 1
    local f = io.open(REQ, "w"); f:write(seq .. " " .. cmd); f:close()
    local mine = seq
    return function()
        local d = io.open(DONE, "r")
        if not d then return false end
        local s = d:read("*a"); d:close()
        return tonumber(s) == mine
    end
end
local function after(sec) local t = os.clock() + sec return function() return os.clock() >= t end end

local steps = {}
local function step(name, fn) steps[#steps + 1] = { name = name, fn = fn } end

local function waitWorld(phase, mapPath, timeout)
    step(phase .. ": world", function()
        return function()
            if worldName():find(mapPath .. ".", 1, true) then say("WORLD %s %s", phase, worldName():match("/Game/[^ ]+") or "?") return true end
            return false
        end, timeout, phase .. " world " .. mapPath
    end)
end
local function travel(phase, map, options)
    step(phase .. ": travel", function()
        say("TRAVEL %s OpenLevel %s%s", phase, map, options ~= "" and ("?" .. options) or "")
        found(GSL):OpenLevel(pc(), FName(map), true, options)
        return after(3), 5, "travel start"
    end)
end
local function touchdown(phase)
    step(phase .. ": touchdown", function()
        say("TOUCHDOWN %s requesting Enter", phase)
        return request("key ENTER"), 20, "touchdown key"
    end)
end
local function waitPawn(phase, timeout)
    step(phase .. ": pawn", function()
        local since
        return function()
            if pawn() then
                since = since or os.clock()
                return os.clock() - since >= 3
            end
            return false
        end, timeout, phase .. " local character"
    end)
end
local function settle(phase, sec) step(phase .. ": settle", function() return after(sec), sec + 2, "settle" end) end

local function checkVolume(phase)
    step(phase .. ": volume", function()
        local v = volume()
        check(v == 0, "VOLUME %s Whistle01 Volume=%s (the mod's 0)", phase, fmtVol(v))
    end)
end

-- ---------------------------------------------------------------- recordings
local function amb() return found(AMB) end
-- One recording: start, optionally whistle WHISTLE_AT s in, stop at REC_S to <scriptDir>\whistle-<label>.wav.
local function record(phase, label, whistle)
    step(phase .. ": record " .. label, function()
        local w, a = world(), amb()
        if not (w and a) then check(false, "REC %s %s no world or AudioMixerBlueprintLibrary", phase, label) return end
        local okS, errS = pcall(function() a:StartRecordingOutput(w, REC_S + 1.0, nil) end)
        if not check(okS, "REC %s %s started (%s)", phase, label, okS and "StartRecordingOutput" or tostring(errS)) then return end
        local t0, whistled = os.clock(), not whistle
        return function()
            local t = os.clock() - t0
            if not whistled and t >= WHISTLE_AT then
                whistled = true
                local c = pawn()
                local okW, errW = pcall(function() c:WhistleServer() end)
                say("WHISTLE %s %s at %.2f s Volume=%s ok=%s%s", phase, label, t, fmtVol(volume()), tostring(okW), okW and "" or (" " .. tostring(errW)))
                if not okW then S.failures = S.failures + 1 end
            end
            return t >= REC_S
        end, REC_S + 5, phase .. " recording " .. label
    end)
    step(phase .. ": stop " .. label, function()
        local w, a = world(), amb()
        local name = "whistle-" .. label
        local okT, errT = pcall(function() a:StopRecordingOutput(w, WAV_EXPORT, name, scriptDir, nil, nil) end)
        check(okT, "REC %s %s stopped -> %s\\%s.wav (%s)", phase, label, scriptDir, name, okT and "StopRecordingOutput" or tostring(errT))
        return after(GAP_S), GAP_S + 2, "gap"
    end)
end
local function setVolume(phase, what)
    step(phase .. ": volume " .. what, function()
        local w = found(WAVE)
        local v = what == "stock" and (S.stock or 1.0) or 0.0
        local ok = w and pcall(function() w.Volume = v end)
        check(ok and volume() == v, "SETVOL %s %s Volume=%s (stock seen before the mod: %s)", phase, what, fmtVol(volume()), fmtVol(S.stock))
    end)
end
local function gc(phase)
    step(phase .. ": gc", function()
        local ok, err = pcall(function() found(KSL):CollectGarbage() end)
        say("GC %s CollectGarbage ok=%s%s", phase, tostring(ok), ok and "" or (" " .. tostring(err)))
        return after(3), 5, "after gc"
    end)
    step(phase .. ": volume after gc", function()
        local v = volume()
        -- Informational (the SPEC's reload question): the mod sets Volume per map, not after a GC.
        say("AFTERGC %s Whistle01 %s Volume=%s", phase, found(WAVE) and "loaded" or "not loaded", fmtVol(v))
    end)
end

-- ---------------------------------------------------------------- runner (game thread, every 250 ms)
local idx, waiting, busy, finished = 0, nil, false, false
local function finish()
    finished = true
    say("PRELOADS %s", table.concat(S.pre, ","))
    say("END result=%s checks=%d failures=%d", (S.failures == 0 and S.checks > 0) and "PASS" or "FAIL", S.checks, S.failures)
end
local function tick()
    if busy or finished then return end
    busy = true
    local ok, err = pcall(function()
        if waiting then
            if not waiting.pred() then
                if os.clock() <= waiting.deadline then return end
                check(false, "TIMEOUT %s", waiting.what)
            end
            waiting = nil
        end
        idx = idx + 1
        local s = steps[idx]
        if not s then finish() return end
        local pred, timeout, what = s.fn()
        if pred then waiting = { pred = pred, deadline = os.clock() + (timeout or 10), what = what or s.name } end
    end)
    if not ok then
        check(false, "STEP '%s' threw: %s", steps[idx] and steps[idx].name or "?", tostring(err))
        waiting = nil
    end
    busy = false
end

local function buildMatch()
    waitWorld("menu1", MENU_MAP, 120)
    settle("menu1", 3)
    checkVolume("menu1")
    travel("match1", MATCH_MAP, "listen")
    waitWorld("match1", MATCH_MAP, 150)
    touchdown("match1")
    waitPawn("match1", 90)
    settle("match1", 5)
    checkVolume("match1")
    record("match1", "quiet1", false)
    record("match1", "muted", true)
    setVolume("match1", "stock")
    record("match1", "loud", true)
    setVolume("match1", "muted")
    record("match1", "quiet2", false)
    gc("match1")
    travel("menu2", MENU_MAP, "")
    waitWorld("menu2", MENU_MAP, 150)
    settle("menu2", 3)
    checkVolume("menu2")
end

if MAP_BAD then
    say("END result=FAIL checks=0 failures=1 reason=unknown-map %s", MAP_BAD)
    return
end
local build = ({ match = buildMatch })[SCENARIO]
if not build then
    say("END result=FAIL checks=0 failures=1 reason=unknown-scenario %s", SCENARIO)
    return
end
build()
-- A game-thread loop (never LoopAsync + ExecuteInGameThread: the pinned UE4SS can lose those callbacks).
local runner
local okL, res = pcall(LoopInGameThreadWithDelay, 250, function()
    tick()
    if finished and runner then pcall(CancelDelayedAction, runner); runner = nil end
end)
if okL then runner = res else say("END result=FAIL checks=0 failures=1 reason=loop %s", tostring(res)) end
say("LOADED %d steps", #steps)
