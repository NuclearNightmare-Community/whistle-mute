# WhistleMute

A client mod for Nuclear Nightmare (V8.2.3, build 26601774; UE4SS `v3.0.1-1181-g83330635`): the whistle emote is
silent for the player who has it, from anyone. Other players hear everything as before. Standalone (no Nucleus) and
ships no asset. Spec: `_bmad-output/specs/spec-small-mods-v1/` in the workspace (story 1, CAP-1 and CAP-3).

**Status: offline tests pass; in-game check passed on V8.2.3 (2026-11-12, below).** The two-player check of
another player's whistle (open question 3) is scripted (`wm-listen`, below) but not yet run. License: MIT (`LICENSE`);
changes: `CHANGELOG.md`; `build.ps1` stages the release package for the workspace's `tools/release/release.ps1`.

## How it works

Every whistle, yours or another player's, is the game's own `PlaySoundAtLocation` of the sound wave
`/Game/Sounds/Whistle01` on each machine (`BP_FirstPersonCharacter_C:WhistleServer` → `WhistleALL`, a multicast; V8.2
decompile). The mod sets that wave's `Volume` to 0 on this machine once per map, in UE4SS's LoadMap post-hook, and reads
it back. It keeps no reference to the wave (it's looked up by path each time) and reads nothing from other players. If
the wave isn't loaded yet it retries 3 times, 5 s apart, within that map only.

Log lines (`[WhistleMute]` in `UE4SS.log`):

- `loaded 0.2.0 (...)` once at start.
- `MUTED map=<map> was=<volume> now=0.00 (first try | retry N)` per map. `was` is the Volume before the mod set it, so
  it shows whether a map change reset it.
- `MISS map=<map> ... retry N/3 in 5 s`: the wave wasn't loaded at that moment.
- `WARN ...`: something failed (a write, the read-back, or `GIVEUP` after 3 misses). Each is logged once per map.

## Install

```powershell
./deploy.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.2.3-build26601774           # install
./deploy.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.2.3-build26601774 -Remove   # uninstall
```

`deploy.ps1` puts `Mods/WhistleMute/{mod.json, Scripts/main.lua, Scripts/mute.lua}` in the copy and the line
`WhistleMute : 1` right above `Keybinds : 1` in `mods.txt`. From a worktree, pass the main checkout's instance path.

## Tests

Offline (no game): `./test.ps1`, or `./check.ps1 -Scenario unit`. It covers `mute.lua` against a fake game,
`main.lua` against fake UE4SS globals, a load test of the driver, `wav-lib.ps1` on synthetic recordings, `deploy.ps1`
against a fake copy, `check.ps1` against synthetic logs and recordings, the pair scenario file
(`test/unit/pair_test.ps1`: it parses and loads in `pair.ps1`'s shape, its stage, the request whitelist, the whistle
key, the request server against a fake host copy, the recordings' copy and its Check), and `run.ps1`'s run guard.
Counts at the first commit: Lua 40 + 29 + 23, PowerShell 21 + 42 + 22 + 12. With the pair scenario: Lua 40 + 29 + 57,
PowerShell 21 + 45 + 35 + 62 + 13.

### In game

One launch, host only, Tower Island (the routine map), and with the game's sound on:

```powershell
./run.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.2.3-build26601774
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

### Two players: another player's whistle (`wm-listen`)

The solo run proves this machine's own whistle. Every whistle, anyone's, reaches a machine as the same `WhistleALL`
playing the same wave, but the user's priority is other players' whistles, so `test/pair/whistle-scenarios.ps1` adds
the scenario `wm-listen` to the workspace's `tools/vm/pair.ps1` (`tools/vm/README.md`):

- **A, the host (this PC):** WhistleMute and `WhistleMuteDriver` with the scenario `pair-listen`, installed for the run
  only (staged by `deploy.ps1 -Test -Scenario pair-listen -Staged`; `pair.ps1` removes them afterwards).
  PairDriver makes the friends-only lobby as in every pair run.
- **B, the VM:** vanilla (UE4SS off). It whistles with its own whistle key, posted by `vm-key.ps1`: the real player
  path (`IA_Whistle` → `WhistleServer`, a server RPC to A → `WhistleALL` on every machine). B's mods can't change what
  A hears, so a vanilla B also shows the mod is needed only on the listening machine.
- **What A's driver does:** it hooks `WhistleALL` (each call logs `HEARD <window> remote|local at <s> dist=<m>`: whose
  whistle, when, how far), logs the whistle key from the game's input mapping (`KEYMAP`), waits for B's character,
  asks for B's touchdown, then records five windows of A's audio output: `quiet1`, `muted` (B whistles; Volume 0),
  `loud` (B whistles; the stock Volume put back: the control), `muted2` (Volume 0 again), `quiet2`. A whistle window
  asks for B's whistle, waits up to 15 s for B's `WhistleALL` on A, records 3 s more, and tries up to 3 times.
- **What `pair.ps1` does for it:** `AfterJoin` serves the driver's `request.txt` (only `key ENTER` for A's touchdown,
  `vmkey ENTER` for B's, `vmkey whistle` for B's whistle key), re-checks the friends-only flags while it does, and when
  the driver logs `END` copies the recordings to `dumps\<copy>\pair\<label>-wav\`.
- **Verdict** (`ScenarioReport.Verdict` in `dumps\<copy>\pair\<label>.json`): `check.ps1 -Scenario pair-listen` on A's
  log and those recordings. PASS needs B's whistle seen on A in `muted`, `loud` and `muted2` and in no quiet window,
  no whistle of A's own in any window, B's stock whistle audible in `loud` (at least 6 dB over the quiet windows) and
  at most 10% of it left in both `muted` windows. INCONCLUSIVE when B's stock whistle isn't audible on A at all (the
  characters too far apart: the whistle is attenuated with the game's `ATT_Generators`, and `dist=` says how far B
  was; or no sound device); FAIL otherwise.

Before it: no `WhistleMute` or `WhistleMuteDriver` in the host copy (`./deploy.ps1 -Instance <copy> -Remove`; the
scenario refuses otherwise), nobody playing on the host, the VM lock taken (`tools/vm/README.md`, "Memory and the VM
lock"), the host's game sound on with an output device (as for the solo run), and the VM copy on the host's build.
Nucleus isn't needed and doesn't need to be removed (WhistleMute is standalone). From the workspace's main checkout,
about 10 minutes:

```powershell
./tools/vm/pair.ps1 -Scenario wm-listen -ScenarioFile mods/whistle-mute/test/pair/whistle-scenarios.ps1
./tools/vm/pair.ps1 -Scenario wm-listen -ScenarioFile mods/whistle-mute/test/pair/whistle-scenarios.ps1 -ScenarioArgs @{ WhistleKey = 'G' }   # if no KEYMAP line names a postable key
./tools/vm/pair.ps1 -Stop -Scenario wm-listen -ScenarioFile mods/whistle-mute/test/pair/whistle-scenarios.ps1                              # after an aborted run
./check.ps1 -Log <...>\dumps\<copy>\pair\<label>.host.UE4SS.log -Scenario pair-listen -WavDir <...>\dumps\<copy>\pair\<label>-wav   # again, by hand
```

**Run 1 (2026-11-12 night, V8.2.3, host copy `v8.2.3-build26601774`, VM copy on the same build): INCONCLUSIVE, not
run (environment, not the mod).** `pair.ps1` stopped before launching the host game: `ERROR: Only 4.7 GB of memory
available on this PC with the VM running (need 7 GB before launching the host game); not launching.` An Unreal Editor
left open on the host (about 8 GB private) held the memory. B never joined, so nothing was judged (`ScenarioReport`
`Verdict FAIL`, `Note: not judged: B never joined`): no muted/loud dB, no `HEARD` lines. `pair.ps1 -Stop` afterwards;
the host copy had no WhistleMute or driver left and the VM copy was back to UE4SS off. Result:
`dumps\v8.2.3-build26601774\pair\wm-listen-20261112-222724.json`. Not retried: the same memory would fail the same
way. Next: run it again with no editor open on the host.

Untested parts, which the first run settles: whether the game takes the whistle key and Enter (touchdown) posted to
the VM's window (B5 proved posted keys for the chat key only), whether the whistle works in the lobby for a client as
it does for the host, and how far apart the two characters stand there.

A hand check without the driver: play with the mod deployed, then
`./check.ps1 -Instance <copy> -Scenario hand` (loaded once, at least one `MUTED`, no `WARN`, no script error).

### Results

**2026-11-12, V8.2.3 (build 26601774), copy `game-instances/v8.2.3-build26601774`: PASS.** `./run.ps1`, scenario
`match` on Tower Island (`SmallMap?listen`, host only), 70 s; the driver logged `END result=PASS checks=13
failures=0` and `check.ps1` printed "All checks passed." Key lines of its output:

```text
[WhistleMute] MUTED map=GraphicsWarmup was=1.00 now=0.00 (first try)
[WhistleMute] MUTED map=NewMainMenu was=0.00 now=0.00 (first try)
[WhistleMute] MUTED map=SmallMap was=0.00 now=0.00 (first try)
[WhistleMuteDriver] OK VOLUME menu1 Whistle01 Volume=0.00 (the mod's 0)
[WhistleMuteDriver] OK VOLUME match1 Whistle01 Volume=0.00 (the mod's 0)
[WhistleMuteDriver] OK VOLUME menu2 Whistle01 Volume=0.00 (the mod's 0)
[WhistleMuteDriver] WHISTLE match1 muted at 0.51 s Volume=0.00 ok=true
[WhistleMuteDriver] OK SETVOL match1 stock Volume=1.00 (stock seen before the mod: 1.00)
[WhistleMuteDriver] AFTERGC match1 Whistle01 loaded Volume=0.00
[WhistleMuteDriver] END result=PASS checks=13 failures=0
--- checks (match) ---
ok:   !\[WhistleMute\] WARN 
ok:   ?!\[WhistleMute\] MISS 
ok:   the stock whistle is audible in the recording: loud +10.7 dB over noise, muted -12.1 dB over noise (whistle left: -inf dB of stock); hf energy quiet1=8.66E-008 quiet2=4.25E-005 muted=2.65E-006 loud=4.97E-004
ok:   with the mod's Volume 0 the whistle is silent: loud +10.7 dB over noise, muted -12.1 dB over noise (whistle left: -inf dB of stock); hf energy quiet1=8.66E-008 quiet2=4.25E-005 muted=2.65E-006 loud=4.97E-004
```

All 26 `ok:` checks passed (among them no script error, hook removal or traceback).

What it says about the open questions: `Whistle01` was loaded at every LoadMap (no `MISS`); the Volume before the
mod set it was 1.00 at `GraphicsWarmup` and 0.00 at every later map, so a map change did not reset it; after a
forced garbage collection the wave was still loaded with Volume 0.00. Point 3 (a remote player's whistle, by ear in
a pair run) remains open.

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
   whistler hears their own whistle. **Now scripted** as `wm-listen` (above), by recording rather than by ear, with
   the stock-Volume control in the same run; not yet run.
4. **The game's own Volume.** The test driver reads the wave's stock Volume in a LoadMap pre-hook, before the mod
   sets it, and falls back to 1.0 if it never sees a non-zero value. The `loud` recording uses that value.

## Files

- `mod.json`: the manifest (`scope: client`, no `dependsOn`).
- `Scripts/main.lua`: the UE4SS glue: game adapter and LoadMap post-hook.
- `Scripts/mute.lua`: the logic (once per map, read-back, bounded retries).
- `deploy.ps1`, `deploy-lib.ps1`: install and remove, edit `mods.txt`.
- `run.ps1`, `check.ps1`, `wav-lib.ps1`: the in-game run, its verdict, and reading the recordings.
- `test/WhistleMuteDriver/`: the test driver (never shipped). `test/pair/whistle-scenarios.ps1`: the two-player
  scenario for the workspace's `tools/vm/pair.ps1`. `test/unit/`: the offline tests. `test.ps1` runs them.

Game symbols this mod and its driver rely on are listed in the workspace's `tools/diff-dumps.watch.json` (mod:
`/Game/Sounds/Whistle01` and `SoundWave.Volume`; driver: `WhistleServer`, `WhistleALL` (hooked in `pair-listen`),
`IsLocallyControlled`, the `IA_Whistle` input action, AudioMixer recording, `CollectGarbage`).

## Feedback

Bug reports, ideas and questions go to [NuclearNightmare-Community/feedback](https://github.com/NuclearNightmare-Community/feedback). For a security problem, please report it privately: see its [SECURITY.md](https://github.com/NuclearNightmare-Community/feedback/blob/main/SECURITY.md).
