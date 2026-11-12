-- WhistleMute's logic, free of UE4SS globals so it can be unit-tested (test/unit/mute_test.lua). main.lua hands it a
-- game adapter:
--   game.find()           -> the Whistle01 USoundWave, or nil when it isn't loaded (a fresh lookup every time)
--   game.volume(wave)     -> its Volume (a number), or nil when the read failed
--   game.setVolume(wave, v) -> true, or false and a reason
--   game.later(ms, fn)    -> runs fn on the game thread after ms (ExecuteInGameThreadWithDelay); false if it can't
-- and a log { info, warn } taking format strings.
--
-- What it does: once per map (LoadMap post-hook, and once at load for the world already there), find the wave and set
-- its Volume to 0, then read it back. Nothing is kept between calls: no UObject, only the map's name and a counter.
-- A miss (the wave isn't loaded) is retried a few times, a few seconds apart, within the same map only; a later map
-- cancels the retries of an earlier one.
local M = {}

M.WAVE = "/Game/Sounds/Whistle01.Whistle01"
M.MUTED = 0.0
M.RETRY_MS = 5000
M.MAX_RETRIES = 3
M.MAX_MAP = 64 -- a map name in the log is cut to this many characters

local function fmtVol(v) return type(v) == "number" and string.format("%.2f", v) or "?" end

-- "World /Game/Maps/SmallLoweIsland/SmallMap.SmallMap" -> "SmallMap"; word characters and '-' only.
function M.shortMap(name)
    if type(name) ~= "string" then return "?" end
    local s = name:match("([^%./:%s]+)%s*$") or name
    s = s:gsub("[^%w_%-]", ""):sub(1, M.MAX_MAP)
    return s ~= "" and s or "?"
end

function M.new(game, log)
    local self = { gen = 0, warned = {} }

    -- One log line per distinct problem per map (a broken read would otherwise repeat on every retry).
    local function warnOnce(key, fmt, ...)
        if self.warned[key] then return end
        self.warned[key] = true
        log.warn(fmt, ...)
    end

    local attempt -- forward
    local function retry(gen, map, n)
        if n > M.MAX_RETRIES then
            log.warn("GIVEUP map=%s %s still not loaded after %d retries; the whistle plays at full volume until the next map",
                map, M.WAVE, M.MAX_RETRIES)
            return
        end
        log.info("MISS map=%s %s is not loaded (%s); retry %d/%d in %d s", map, M.WAVE, n == 1 and "first try" or "retry " .. (n - 1),
            n, M.MAX_RETRIES, M.RETRY_MS // 1000)
        local ok = game.later(M.RETRY_MS, function()
            if gen ~= self.gen then return end -- a newer map took over
            attempt(gen, map, n)
        end)
        if not ok then warnOnce("later", "could not schedule a retry; %s stays unmuted on %s", M.WAVE, map) end
    end

    -- n: 0 at LoadMap, k for the k-th retry.
    attempt = function(gen, map, n)
        local wave = game.find()
        if wave == nil then return retry(gen, map, n + 1) end
        local was = game.volume(wave)
        local okSet, why = game.setVolume(wave, M.MUTED)
        if not okSet then
            warnOnce("set:" .. map, "could not set %s Volume on %s: %s", M.WAVE, map, tostring(why))
            return
        end
        local now = game.volume(wave)
        local where = n == 0 and "first try" or ("retry " .. n)
        if now ~= M.MUTED then
            warnOnce("readback:" .. map, "MUTED map=%s was=%s now=%s (%s): the read-back is not %s", map, fmtVol(was), fmtVol(now),
                where, fmtVol(M.MUTED))
            return
        end
        log.info("MUTED map=%s was=%s now=%s (%s)", map, fmtVol(was), fmtVol(now), where)
    end

    -- A new map (or the world already loaded when the mod starts): mute the whistle for it.
    function self.onMap(worldName)
        self.gen = self.gen + 1
        self.warned = {}
        attempt(self.gen, M.shortMap(worldName), 0)
    end

    return self
end

return M
