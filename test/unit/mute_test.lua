-- Unit tests for Scripts/mute.lua against a fake game adapter: the per-map mute, the read-back, the bounded retries
-- of a miss, a newer map cancelling an older map's retries, and every failure path logging once.
-- Run from the repo root:  texlua test/unit/mute_test.lua
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."
package.path = ROOT .. "/Scripts/?.lua;" .. ROOT .. "/test/unit/?.lua;" .. package.path
local T = require("harness").new("mute_test")
local ok, eq = T.ok, T.eq
local mute = require("mute")

local function fake(opts)
    opts = opts or {}
    local G = { wave = opts.wave, finds = 0, sets = {}, laters = {}, lines = {}, laterFails = opts.laterFails }
    if G.wave == nil and not opts.missing then G.wave = { Volume = 1.0 } end
    local game = {}
    function game.find() G.finds = G.finds + 1 return G.wave end
    function game.volume(w) if G.readFails then return nil end return w.Volume end
    function game.setVolume(w, v)
        G.sets[#G.sets + 1] = v
        if G.setFails then return false, "boom" end
        if not G.setIgnored then w.Volume = v end
        return true
    end
    function game.later(ms, fn)
        if G.laterFails then return false end
        G.laters[#G.laters + 1] = { ms = ms, fn = fn }
        return true
    end
    local log = {
        info = function(fmt, ...) G.lines[#G.lines + 1] = string.format(fmt, ...) end,
        warn = function(fmt, ...) G.lines[#G.lines + 1] = "WARN " .. string.format(fmt, ...) end,
    }
    G.m = mute.new(game, log)
    function G.runLater() local l = table.remove(G.laters, 1) if l then l.fn() end return l end
    function G.count(pat) local n = 0 for _, l in ipairs(G.lines) do if l:find(pat) then n = n + 1 end end return n end
    return G
end

-- shortMap: the map's short name, word characters only, bounded.
eq(mute.shortMap("World /Game/Maps/SmallLoweIsland/SmallMap.SmallMap"), "SmallMap", "shortMap: world full name")
eq(mute.shortMap("/Game/Maps/NewMainMenu.NewMainMenu"), "NewMainMenu", "shortMap: path")
eq(mute.shortMap("unknown"), "unknown", "shortMap: plain word")
eq(mute.shortMap(nil), "?", "shortMap: nil")
eq(mute.shortMap(42), "?", "shortMap: a number")
eq(mute.shortMap("World /Game/Maps/A.B<script>%n"), "Bscriptn", "shortMap: odd characters dropped")
eq(#mute.shortMap("World /Game/X." .. string.rep("a", 500)), mute.MAX_MAP, "shortMap: bounded")
eq(mute.shortMap("..."), "?", "shortMap: nothing left")
eq(mute.WAVE, "/Game/Sounds/Whistle01.Whistle01", "the wave's path")

-- 1. A hit: Volume 0, read back, one MUTED line with the old value.
local G = fake()
G.m.onMap("World /Game/Maps/NewMainMenu.NewMainMenu")
eq(G.wave.Volume, 0.0, "hit: Volume 0")
eq(#G.sets, 1, "hit: one set")
eq(G.lines[1], "MUTED map=NewMainMenu was=1.00 now=0.00 (first try)", "hit: the MUTED line")
eq(#G.lines, 1, "hit: one line")
eq(#G.laters, 0, "hit: no retry")
-- The next map: looked up again (no reference kept), was=0.00 when nothing reset it.
G.m.onMap("World /Game/Maps/SmallLoweIsland/SmallMap.SmallMap")
eq(G.finds, 2, "next map: found again")
eq(G.lines[2], "MUTED map=SmallMap was=0.00 now=0.00 (first try)", "next map: was=0.00")
-- A reload that reset it shows in was=.
G.wave = { Volume = 0.8 }
G.m.onMap("World /Game/Maps/ForestMap/ForestMap.ForestMap")
eq(G.lines[3], "MUTED map=ForestMap was=0.80 now=0.00 (first try)", "reset: was shows the reloaded value")

-- 2. A miss: MISS, a retry in 5 s; the retry hits.
G = fake({ missing = true })
G.m.onMap("World /Game/Maps/SmallLoweIsland/SmallMap.SmallMap")
eq(G.lines[1], "MISS map=SmallMap /Game/Sounds/Whistle01.Whistle01 is not loaded (first try); retry 1/3 in 5 s", "miss: MISS line")
eq(#G.laters, 1, "miss: one retry scheduled")
eq(G.laters[1].ms, 5000, "miss: in 5 s")
G.wave = { Volume = 1.0 }
G.runLater()
eq(G.wave.Volume, 0.0, "retry: muted")
eq(G.lines[2], "MUTED map=SmallMap was=1.00 now=0.00 (retry 1)", "retry: MUTED (retry 1)")
eq(#G.laters, 0, "retry: no further retry")

-- 3. Never loaded: three retries, then one GIVEUP warning; nothing more.
G = fake({ missing = true })
G.m.onMap("World /Game/Maps/SmallLoweIsland/SmallMap.SmallMap")
for _ = 1, 3 do ok(G.runLater() ~= nil, "never: a retry ran") end
eq(#G.laters, 0, "never: no retry after the third")
eq(G.count("^MISS "), 3, "never: three MISS lines")
eq(G.count("^WARN GIVEUP map=SmallMap "), 1, "never: one GIVEUP warning")
eq(G.finds, 4, "never: four lookups in all (bounded)")
ok(G.lines[2]:find("(retry 1); retry 2/3", 1, true) ~= nil, "never: the retries count up", G.lines[2])

-- 4. A newer map cancels an older map's pending retry.
G = fake({ missing = true })
G.m.onMap("World /Game/Maps/SmallLoweIsland/SmallMap.SmallMap")
G.wave = { Volume = 1.0 }
G.m.onMap("World /Game/Maps/NewMainMenu.NewMainMenu")
eq(G.count("^MUTED map=NewMainMenu"), 1, "newer map: muted at once")
local finds = G.finds
G.runLater() -- SmallMap's old retry
eq(G.finds, finds, "newer map: the old retry does nothing")
eq(G.count("SmallMap"), 1, "newer map: no line for the old map's retry")

-- 5. Failures: the set fails -> one WARN per map, no MUTED; the read-back differs -> WARN; can't schedule -> WARN.
G = fake()
G.setFails = true
G.m.onMap("World /Game/Maps/A.A")
G.m.onMap("World /Game/Maps/A.A")
eq(G.count("^WARN could not set .* on A: boom"), 2, "set fails: one WARN per map (two maps)")
eq(G.count("^MUTED"), 0, "set fails: no MUTED")
G = fake()
G.setIgnored = true
G.m.onMap("World /Game/Maps/A.A")
eq(G.count("^WARN MUTED map=A was=1.00 now=1.00 %(first try%): the read%-back is not 0.00"), 1, "read-back differs: WARN")
G = fake()
G.readFails = true
G.m.onMap("World /Game/Maps/A.A")
eq(G.count("^WARN MUTED map=A was=%? now=%?"), 1, "read fails: WARN with ? values")
G = fake({ missing = true, laterFails = true })
G.m.onMap("World /Game/Maps/A.A")
eq(G.count("^WARN could not schedule a retry"), 1, "later fails: WARN")
eq(G.count("^MISS "), 1, "later fails: the MISS line still says what happened")

T.done()
