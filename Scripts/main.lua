-- WhistleMute 0.2.0: the whistle emote is silent for this player, from anyone (scope client; ships no asset).
-- Standalone UE4SS Lua mod. The logic is in mute.lua; this file is the UE4SS glue: the game adapter and the LoadMap
-- post-hook.
--
-- How: every whistle (yours or another player's) is the game's own PlaySoundAtLocation of /Game/Sounds/Whistle01 on
-- each machine (BP_FirstPersonCharacter_C:WhistleALL, a multicast), so setting that USoundWave's Volume to 0 on this
-- machine silences every whistle here and nowhere else. Once per map; no UObject is kept between calls (the wave is
-- looked up again each time), and nothing from another player is read.
-- Safety (AGENTS.md): every game call is in pcall, so is the hook body; a failure is logged once per map.
local ME, VERSION = "WhistleMute", "0.2.0"
local KSL_CDO = "/Script/Engine.Default__KismetSystemLibrary"
local KSL_ISVALID = "/Script/Engine.KismetSystemLibrary:IsValid"

local scriptDir = (debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") or "."
package.path = scriptDir .. "/?.lua;" .. package.path
local mute = require("mute")

local function say(level, fmt, ...)
    local ok, s = pcall(string.format, fmt, ...)
    print(string.format("[%s] %s%s\n", ME, level, ok and s or ("(format error) " .. tostring(fmt))))
end
local log = {
    info = function(fmt, ...) say("", fmt, ...) end,
    warn = function(fmt, ...) say("WARN ", fmt, ...) end,
}

-- ---------------------------------------------------------------- game adapter (each call is guarded)
-- Unreal's IsValid as a UFunction (it checks the garbage flag too), never UE4SS's obj:IsValid() alone (AGENTS.md).
local function alive(o)
    if o == nil then return false end
    local ok, r = pcall(function()
        if not o:IsValid() then return false end
        local fn, cdo = StaticFindObject(KSL_ISVALID), StaticFindObject(KSL_CDO)
        if not (fn and fn:IsValid() and cdo and cdo:IsValid()) then return true end -- no KSL: the engine check passed
        return fn(cdo, o) == true
    end)
    return ok and r == true
end

local game = {}
function game.find()
    local ok, w = pcall(StaticFindObject, mute.WAVE)
    if ok and alive(w) then return w end
    return nil
end
function game.volume(w)
    local ok, v = pcall(function() return w.Volume end)
    if ok and type(v) == "number" then return v end
    return nil
end
function game.setVolume(w, v)
    local ok, err = pcall(function() w.Volume = v end)
    if ok then return true end
    return false, tostring(err)
end
function game.later(ms, fn)
    local ok = pcall(ExecuteInGameThreadWithDelay, ms, function()
        local okF, err = pcall(fn)
        if not okF then log.warn("retry failed: %s", tostring(err)) end
    end)
    return ok
end

local whistle = mute.new(game, log)

local function worldName(world)
    local ok, name = pcall(function()
        local w = world
        local okG, inner = pcall(function() return world:get() end) -- a LoadMap hook's RemoteUnrealParam
        if okG and inner ~= nil then w = inner end
        return w:GetFullName()
    end)
    if ok and type(name) == "string" then return name end
    return nil
end

-- ---------------------------------------------------------------- hooks
local okM, errM = pcall(RegisterLoadMapPostHook, function(_, world)
    local ok, err = pcall(whistle.onMap, worldName(world) or "unknown")
    if not ok then log.warn("LoadMap: %s", tostring(err)) end
end)
if not okM then log.warn("RegisterLoadMapPostHook failed (%s); the whistle is not muted", tostring(errM)) end

-- No try at load: UE4SS starts Lua mods before the first world (GraphicsWarmup), so the first LoadMap is ours too, and
-- main.lua may not run on the game thread.
log.info("loaded %s (mutes the whistle emote: %s Volume %.0f, once per map)", VERSION, mute.WAVE, mute.MUTED)
