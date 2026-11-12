-- Unit tests for Scripts/main.lua (the UE4SS glue) with the real mute.lua, over fake UE4SS globals: the load line, no
-- game call at load, the LoadMap post-hook muting the wave found by its path, retries through
-- ExecuteInGameThreadWithDelay, KismetSystemLibrary:IsValid as the liveness check, and faults that must not escape.
-- Run from the repo root:  texlua test/unit/main_test.lua
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."
package.path = ROOT .. "/test/unit/?.lua;" .. package.path
local T = require("harness").new("main_test")
local ok, eq = T.ok, T.eq
local MAIN = ROOT .. "/Scripts/main.lua"
local WAVE = "/Game/Sounds/Whistle01.Whistle01"

local U
local function obj(fields)
    local o = fields or {}
    if o.alive == nil then o.alive = true end
    function o:IsValid() return self.alive end
    return o
end
local function boot(opts)
    opts = opts or {}
    U = { out = {}, finds = {}, delays = {}, loadMap = nil }
    U.wave = obj({ Volume = 1.0 })
    U.kslFn = setmetatable(obj({}), { __call = function(_, cdo, o) return o.garbage ~= true end })
    U.kslCdo = obj({})
    _G.print = function(s) U.out[#U.out + 1] = (tostring(s):gsub("\n$", "")) end
    _G.StaticFindObject = function(path)
        U.finds[#U.finds + 1] = path
        if U.findThrows then error("StaticFindObject: boom") end
        if path == WAVE then return U.waveMissing and obj({ alive = false }) or U.wave end
        if path == "/Script/Engine.KismetSystemLibrary:IsValid" then return U.kslFn end
        if path == "/Script/Engine.Default__KismetSystemLibrary" then return U.kslCdo end
        return obj({ alive = false })
    end
    _G.RegisterLoadMapPostHook = function(fn)
        if opts.noLoadMap then error("no such function") end
        U.loadMap = fn
    end
    _G.ExecuteInGameThreadWithDelay = function(ms, fn) U.delays[#U.delays + 1] = { ms = ms, fn = fn } end
    _G.LoopAsync = function() error("must not use LoopAsync") end
    _G.ExecuteInGameThread = function() error("must not use ExecuteInGameThread") end
    package.loaded.mute = nil
    assert(loadfile(MAIN))()
end
local function world(name) return { get = function() return { GetFullName = function() return "World " .. name end } end } end
local function lines(pat) local n = 0 for _, l in ipairs(U.out) do if l:match(pat) then n = n + 1 end end return n end

-- 1. Load: one line, the hook registered, no game call yet.
boot()
eq(#U.out, 1, "load: one line")
eq(U.out[1], "[WhistleMute] loaded 0.1.0 (mutes the whistle emote: /Game/Sounds/Whistle01.Whistle01 Volume 0, once per map)", "load: the load line")
ok(U.loadMap ~= nil, "load: a LoadMap post-hook")
eq(#U.finds, 0, "load: no lookup at load")

-- 2. LoadMap: the wave muted, one MUTED line naming the map.
U.loadMap(nil, world("/Game/Maps/NewMainMenu.NewMainMenu"))
eq(U.wave.Volume, 0.0, "loadmap: Volume 0")
eq(U.out[2], "[WhistleMute] MUTED map=NewMainMenu was=1.00 now=0.00 (first try)", "loadmap: MUTED line")
U.loadMap(nil, world("/Game/Maps/SmallLoweIsland/SmallMap.SmallMap"))
eq(U.out[3], "[WhistleMute] MUTED map=SmallMap was=0.00 now=0.00 (first try)", "loadmap: next map")
-- A world param that isn't a RemoteUnrealParam (the world itself) works too; one that fails gives "unknown".
U.wave.Volume = 1.0
U.loadMap(nil, { GetFullName = function() return "World /Game/Maps/ForestMap/ForestMap.ForestMap" end })
eq(U.out[4], "[WhistleMute] MUTED map=ForestMap was=1.00 now=0.00 (first try)", "loadmap: a bare world")
U.loadMap(nil, nil)
eq(U.out[5], "[WhistleMute] MUTED map=unknown was=0.00 now=0.00 (first try)", "loadmap: no world -> unknown")

-- 3. A garbage wave (UE4SS's IsValid says yes, Unreal's says no) counts as not loaded: MISS and a retry.
boot()
U.wave.garbage = true
U.loadMap(nil, world("/Game/Maps/SmallLoweIsland/SmallMap.SmallMap"))
eq(U.wave.Volume, 1.0, "garbage: not touched")
eq(lines("^%[WhistleMute%] MISS map=SmallMap "), 1, "garbage: MISS")
eq(#U.delays, 1, "garbage: one retry scheduled")
eq(U.delays[1].ms, 5000, "garbage: in 5 s")
U.wave.garbage = false
U.delays[1].fn()
eq(U.wave.Volume, 0.0, "garbage: the retry mutes the live wave")
eq(lines("^%[WhistleMute%] MUTED map=SmallMap was=1.00 now=0.00 %(retry 1%)$"), 1, "garbage: MUTED (retry 1)")

-- 4. Not found at all: three retries then GIVEUP; an invalid object from StaticFindObject is a miss.
boot()
U.waveMissing = true
U.loadMap(nil, world("/Game/Maps/A.A"))
for i = 1, 3 do U.delays[i].fn() end
eq(#U.delays, 3, "missing: three retries in all")
eq(lines("^%[WhistleMute%] WARN GIVEUP map=A "), 1, "missing: one GIVEUP")

-- 5. Faults never escape: StaticFindObject throws; the property write throws; the delay function throws.
boot()
U.findThrows = true
local okH = pcall(U.loadMap, nil, world("/Game/Maps/A.A"))
ok(okH, "fault: StaticFindObject throwing doesn't escape the hook")
eq(lines("^%[WhistleMute%] MISS map=A "), 1, "fault: a throwing lookup is a miss")
boot()
U.wave.Volume = nil -- a proxy: reads give 1.0, writes throw
setmetatable(U.wave, { __index = function(_, k) if k == "Volume" then return 1.0 end end, __newindex = function() error("read-only") end })
okH = pcall(U.loadMap, nil, world("/Game/Maps/A.A"))
ok(okH, "fault: a failing write doesn't escape")
eq(lines("^%[WhistleMute%] WARN could not set .* on A: "), 1, "fault: the failed write is a WARN")
boot()
_G.ExecuteInGameThreadWithDelay = function() error("no delay") end
U.waveMissing = true
okH = pcall(U.loadMap, nil, world("/Game/Maps/A.A"))
ok(okH, "fault: a failing delay doesn't escape")
eq(lines("^%[WhistleMute%] WARN could not schedule a retry"), 1, "fault: the failed schedule is a WARN")
-- A retry body that throws is caught and logged.
boot()
U.waveMissing = true
U.loadMap(nil, world("/Game/Maps/A.A"))
U.findThrows = true
_G.StaticFindObject = function() error("boom") end
local okR = pcall(U.delays[1].fn)
ok(okR, "fault: a throwing retry is caught")

-- 6. No LoadMap hook: one WARN, the load line still.
boot({ noLoadMap = true })
eq(lines("^%[WhistleMute%] WARN RegisterLoadMapPostHook failed"), 1, "no hook: WARN")
eq(lines("^%[WhistleMute%] loaded "), 1, "no hook: still the load line")

-- 7. The source never keeps the wave: no assignment of a found object to an upvalue outside a function.
local src = assert(io.open(MAIN)):read("*a")
ok(not src:find("LoopAsync", 1, true), "source: no LoopAsync")
ok(not src:find("ExecuteInGameThread%(") , "source: no ExecuteInGameThread (only the WithDelay form)")
ok(src:find('local ME, VERSION = "WhistleMute", "0.1.0"', 1, true) ~= nil, "source: name and version")

T.done()
