# WhistleMute

A client mod for Nuclear Nightmare (V8.2.1, build 26512322; UE4SS `v3.0.1-1181-g83330635`): the whistle emote is
silent for the player who has it, from anyone. Other players hear everything as before. Standalone (no Nucleus) and
ships no asset. Spec: `_bmad-output/specs/spec-small-mods-v1/` in the workspace (story 1, CAP-1 and CAP-3).

**Status: offline tests pass; not yet run in game.** The in-game checks below are what remains.

## How it works

Every whistle, yours or another player's, is the game's own `PlaySoundAtLocation` of the sound wave
`/Game/Sounds/Whistle01` on each machine (`BP_FirstPersonCharacter_C:WhistleServer` → `WhistleALL`, a multicast; V8.2
decompile). The mod sets that wave's `Volume` to 0 on this machine once per map, in UE4SS's LoadMap post-hook, and reads
it back. It keeps no reference to the wave (it's looked up by path each time) and reads nothing from other players. If
the wave isn't loaded yet it retries 3 times, 5 s apart, within that map only.

Log lines (`[WhistleMute]` in `UE4SS.log`):

- `loaded 0.1.0 (...)` once at start.
- `MUTED map=<map> was=<volume> now=0.00 (first try | retry N)` per map. `was` is the Volume before the mod set it, so
  it shows whether a map change reset it.
- `MISS map=<map> ... retry N/3 in 5 s`: the wave wasn't loaded at that moment.
- `WARN ...`: something failed (a write, the read-back, or `GIVEUP` after 3 misses). Each is logged once per map.

## Install

```powershell
./deploy.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.2-build26512322           # install
./deploy.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.2-build26512322 -Remove   # uninstall
```

`deploy.ps1` puts `Mods/WhistleMute/{mod.json, Scripts/main.lua, Scripts/mute.lua}` in the copy and the line
`WhistleMute : 1` right above `Keybinds : 1` in `mods.txt`. From a worktree, pass the main checkout's instance path.

## Tests

Offline (no game): `./test.ps1`, or `./check.ps1 -Scenario unit`. It covers `mute.lua` against a fake game,
`main.lua` against fake UE4SS globals, a load test of the driver, `wav-lib.ps1` on synthetic recordings, `deploy.ps1`
against a fake copy, `check.ps1` against synthetic logs and recordings, and `run.ps1`'s run guard. Counts at the
first commit: Lua 40 + 29 + 23, PowerShell 21 + 42 + 22 + 12.

### In game: what remains

One launch, host only, Tower Island (the routine map), and with the game's sound on:

```powershell
./run.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.2-build26512322
```

It deploys with the test driver `WhistleMuteDriver` (its `mods.txt` line just above the mod's), launches through
`tools/launch.ps1`, presses Enter for touchdown, and closes the game when the driver logs `END`. Then it keeps the log
as `dumps/<copy>/whistle-mute/match.log` and the recordings in `match-wav/`, and runs `check.ps1 -Scenario match` on
them. When it's done, `./deploy.ps1 -Instance <copy>` (without `-Test`) takes the driver out again. If another runner's
driver is still enabled, `run.ps1` refuses and prints the command that removes it (`tools/run-guard`).

The scenario (`match`) does this:

1. Menu: `Whistle01.Volume` is 0.
2. `SmallMap?listen`, touchdown: Volume is 0.
3. Four 3 s recordings of the game's audio output (AudioMixer `StartRecordingOutput` / `StopRecordingOutput` to
   `whistle-<name>.wav`): `quiet1` (nobody whistles), `muted` (the local character whistles through the game's own
   `WhistleServer` with the mod's Volume 0), `loud` (the same with Volume put back to its stock value: the "without
   the mod" case in the same run; then 0 again), and `quiet2`.
4. A garbage collection, then the Volume again (informational).
5. Back to the menu: Volume is 0.

`check.ps1` passes when every driver check passed, the mod logged `MUTED` on the menu and the match map with no
`WARN`, and the recordings show the stock whistle (at least 6 dB of high-frequency energy above the louder quiet
window) but not the muted one (at most 10% of the stock whistle's energy above the noise, that is 10 dB quieter).
If the stock whistle isn't in the recording (sound off, no output device), the run fails as inconclusive instead of
passing. It also prints what the run says about the SPEC's open questions.

`-Map LowIsland|Forest|Crevasse` runs the same scenario on another map. Per AGENTS.md "Test runs", use it only to
prove the mod on every map once (the SPEC's "silent on every map tried"), not for routine checks.

A hand check without the driver: play with the mod deployed, then
`./check.ps1 -Instance <copy> -Scenario hand` (loaded once, at least one `MUTED`, no `WARN`, no script error).

## Open questions

These come from the SPEC. The V8.2.1 dumps answer some of them in advance; the run settles the rest.

1. **Is the runtime Volume honoured for every playback?** (the SPEC's main assumption) The recordings answer this for
   this machine's own whistle. A remote player's whistle plays through the same `WhistleALL` → `PlaySoundAtLocation`
   of the same wave, so it should be silent too.
2. **Is `Whistle01` loaded when LoadMap fires, and does a reload reset its Volume?** In both the menu and the match
   object dumps the wave (and its package) sits at an address next to the objects loaded at engine start
   (`0x7FF4...`), not with the map's objects, which suggests the never-collected startup pool: then it would always be
   found and never reload (an inference from addresses, not proven). The run checks this: `check.ps1` prints
   whether any map logged `MISS`, the `was=` values per map, and the Volume after a forced garbage collection.
3. **Does a solo run prove that another player's whistle is silent, or does that need a pair run?** By the code path
   (point 1) a solo run should be enough. A friends-only pair run would confirm it by ear: install the mod only on the
   listening machine, have the other player whistle nearby, and check that the listener hears nothing and the
   whistler hears their own whistle. No pair scenario is scripted. **Your call:** is that hand check needed before
   release?
4. **The game's own Volume.** The test driver reads the wave's stock Volume in a LoadMap pre-hook, before the mod
   sets it, and falls back to 1.0 if it never sees a non-zero value. The `loud` recording uses that value.

## Files

- `mod.json`: the manifest (`scope: client`, no `dependsOn`).
- `Scripts/main.lua`: the UE4SS glue: game adapter and LoadMap post-hook.
- `Scripts/mute.lua`: the logic (once per map, read-back, bounded retries).
- `deploy.ps1`, `deploy-lib.ps1`: install and remove, edit `mods.txt`.
- `run.ps1`, `check.ps1`, `wav-lib.ps1`: the in-game run, its verdict, and reading the recordings.
- `test/WhistleMuteDriver/`: the test driver (never shipped). `test/unit/`: the offline tests. `test.ps1` runs them.

Game symbols this mod and its driver rely on are listed in the workspace's `tools/diff-dumps.watch.json` (mod:
`/Game/Sounds/Whistle01` and `SoundWave.Volume`; driver: `WhistleServer`, AudioMixer recording,
`CollectGarbage`).
