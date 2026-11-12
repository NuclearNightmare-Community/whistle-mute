<#
.SYNOPSIS
  Unit tests for check.ps1: synthetic UE4SS.log files (in the format the pinned UE4SS writes) and synthetic recordings
  (wavgen.ps1), each passing as written and failing after one targeted change. Proves the patterns, not the game.
.EXAMPLE
  pwsh -NoProfile -File test/unit/check_test.ps1
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot)
$check = Join-Path $repo 'check.ps1'
. (Join-Path $PSScriptRoot 'wavgen.ps1')
$script:passed = 0; $script:failed = 0
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("wm-check-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $tmp | Out-Null

$script:t = 0
function L([string] $tag, [string] $msg) { $script:t++; "[2026-11-11 01:00:{0:D2}.{1:D7}] [Lua] [$tag] $msg" -f [int]($script:t / 1000 % 60), $script:t }
function U([string] $msg) { $script:t++; "[2026-11-11 01:00:00.{0:D7}] $msg" -f $script:t }
$M = 'WhistleMute'; $D = 'WhistleMuteDriver'

# Recordings: a good set, and variants.
$good = Join-Path $tmp 'good'; New-Item -ItemType Directory $good | Out-Null
New-TestWav (Join-Path $good 'whistle-quiet1.wav') -Seed 1
New-TestWav (Join-Path $good 'whistle-quiet2.wav') -Seed 2
New-TestWav (Join-Path $good 'whistle-muted.wav') -Seed 3
New-TestWav (Join-Path $good 'whistle-loud.wav') -Whistle 0.3 -Seed 4
function Copy-Set([string] $name, [hashtable] $replace = @{}, [string[]] $drop = @()) {
    $d = Join-Path $tmp $name; New-Item -ItemType Directory $d | Out-Null
    Get-ChildItem $good | Where-Object { $drop -notcontains $_.BaseName } | Copy-Item -Destination $d
    foreach ($k in $replace.Keys) { & $replace[$k] (Join-Path $d "$k.wav") }
    $d
}
$heard = Copy-Set 'heard' @{ 'whistle-muted' = { param($p) New-TestWav $p -Whistle 0.3 -Seed 5 } }
$none = Copy-Set 'none' @{ 'whistle-loud' = { param($p) New-TestWav $p -Seed 6 } }
$short = Copy-Set 'short' @{} @('whistle-quiet2')

function Run([string[]] $log, [string] $scenario, [string] $wavDir) {
    $p = Join-Path $tmp "$scenario-$([guid]::NewGuid().ToString('N').Substring(0, 6)).log"
    Set-Content $p $log
    $a = @('-Log', $p, '-Scenario', $scenario)
    if ($wavDir) { $a += @('-WavDir', $wavDir) }
    $out = & pwsh -NoProfile -NonInteractive -File $check @a 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Out = $out }
}
function Expect([string[]] $log, [string] $scenario, [int] $code, [string] $name, [string] $mustSay, [string] $wavDir = $good) {
    $r = Run $log $scenario $wavDir
    $ok = $r.Code -eq $code -and (-not $mustSay -or $r.Out -match $mustSay)
    if ($ok) { $script:passed++ } else { $script:failed++; Write-Host "FAIL $name (exit $($r.Code), want $code)"; Write-Host ($r.Out -split "`n" | Where-Object { $_ -match 'FAIL|warn|open|Volume' } | Out-String) }
}

$match = @(
    (U "Starting Lua mod '$D'"), (L $D 'SCENARIO match'), (L $D 'MAP TowerIsland /Game/Maps/SmallLoweIsland/SmallMap'), (L $D 'LOADED 30 steps')
    (U "Starting Lua mod '$M'"), (L $M 'loaded 0.1.0 (mutes the whistle emote: /Game/Sounds/Whistle01.Whistle01 Volume 0, once per map)')
    (L $D 'PRELOAD n=1 Volume=1.00'), (L $M 'MUTED map=GraphicsWarmup was=1.00 now=0.00 (first try)')
    (L $D 'PRELOAD n=2 Volume=0.00'), (L $M 'MUTED map=NewMainMenu was=0.00 now=0.00 (first try)')
    (L $D 'WORLD menu1 /Game/Maps/NewMainMenu.NewMainMenu'), (L $D 'OK VOLUME menu1 Whistle01 Volume=0.00 (the mod''s 0)')
    (L $D 'TRAVEL match1 OpenLevel /Game/Maps/SmallLoweIsland/SmallMap?listen')
    (L $D 'PRELOAD n=3 Volume=0.00'), (L $M 'MUTED map=SmallMap was=0.00 now=0.00 (first try)')
    (L $D 'WORLD match1 /Game/Maps/SmallLoweIsland/SmallMap.SmallMap'), (L $D 'OK VOLUME match1 Whistle01 Volume=0.00 (the mod''s 0)')
)
foreach ($k in 'quiet1', 'muted', 'loud', 'quiet2') {
    if ($k -eq 'loud') { $match += L $D 'OK SETVOL match1 stock Volume=1.00 (stock seen before the mod: 1.00)' }
    $match += L $D "OK REC match1 $k started (StartRecordingOutput)"
    if ($k -in 'muted', 'loud') { $match += L $D ("WHISTLE match1 $k at 0.50 s Volume={0} ok=true" -f $(if ($k -eq 'loud') { '1.00' } else { '0.00' })) }
    $match += L $D "OK REC match1 $k stopped -> C:\x\Scripts\whistle-$k.wav (StopRecordingOutput)"
    if ($k -eq 'loud') { $match += L $D 'OK SETVOL match1 muted Volume=0.00 (stock seen before the mod: 1.00)' }
}
$match += @(
    (L $D 'GC match1 CollectGarbage ok=true'), (L $D 'AFTERGC match1 Whistle01 loaded Volume=0.00')
    (L $D 'PRELOAD n=4 Volume=0.00'), (L $M 'MUTED map=NewMainMenu was=0.00 now=0.00 (first try)')
    (L $D 'OK VOLUME menu2 Whistle01 Volume=0.00 (the mod''s 0)'), (L $D 'PRELOADS 1.00,0.00,0.00,0.00'), (L $D 'END result=PASS checks=14 failures=0')
)

Expect $match 'match' 0 'match: passes' 'All checks passed'
Expect $match 'match' 0 'match: reports the open questions' 'a map change did not reset it'
Expect $match 'match' 0 'match: loaded at LoadMap' 'loaded when LoadMap fires: yes'
Expect ($match | Where-Object { $_ -notmatch 'MUTED map=SmallMap' }) 'match' 1 'match: no MUTED on the match map fails'
Expect ($match | Where-Object { $_ -notmatch 'MUTED map=NewMainMenu' }) 'match' 1 'match: no MUTED on the menu fails'
Expect ($match | Where-Object { $_ -notmatch 'OK VOLUME match1' }) 'match' 1 'match: missing VOLUME match1 fails'
Expect ($match | Where-Object { $_ -notmatch 'WHISTLE match1 loud' }) 'match' 1 'match: no loud whistle fails'
Expect ($match | ForEach-Object { $_ -replace 'WHISTLE match1 muted at 0.50 s Volume=0.00', 'WHISTLE match1 muted at 0.50 s Volume=1.00' }) 'match' 1 'match: the muted whistle at Volume 1 fails'
Expect ($match + (L $M 'WARN could not set /Game/Sounds/Whistle01.Whistle01 Volume on SmallMap: boom')) 'match' 1 'match: a WARN fails'
Expect ($match + (L $D 'FAIL VOLUME match1 Whistle01 Volume=1.00')) 'match' 1 'match: a driver FAIL fails'
Expect ($match | ForEach-Object { $_ -replace 'END result=PASS', 'END result=FAIL' }) 'match' 1 'match: END FAIL fails'
Expect ($match + (U 'stack traceback:')) 'match' 1 'match: a traceback fails'
Expect ($match + (L $M 'loaded 0.1.0 (again)')) 'match' 1 'match: loaded twice fails'
Expect ($match + (L $M 'MISS map=SmallMap /Game/Sounds/Whistle01.Whistle01 is not loaded (first try); retry 1/3 in 5 s')) 'match' 0 'match: a MISS is soft and answers the question' 'loaded when LoadMap fires: no on SmallMap'
Expect (($match | Where-Object { $_ -notmatch 'MUTED map=SmallMap' }) + (L $M 'MUTED map=SmallMap was=1.00 now=0.00 (first try)')) 'match' 0 'match: a reset Volume is reported' 'a map change reset it \(SmallMap:1\.00\)'
# The recordings.
Expect $match 'match' 1 'match: the whistle heard with the mod fails' 'still heard' $heard
Expect $match 'match' 1 'match: no stock whistle in the recording fails as inconclusive' 'proves nothing' $none
Expect $match 'match' 1 'match: a missing recording fails' 'missing: quiet2' $short
Expect $match 'match' 1 'match: no recordings at all fails' 'missing' (Join-Path $tmp 'nowhere')

# hand: a log from playing with the mod (no driver).
$hand = @((U "Starting Lua mod '$M'"), (L $M 'loaded 0.1.0 (mutes the whistle emote: /Game/Sounds/Whistle01.Whistle01 Volume 0, once per map)'),
    (L $M 'MUTED map=NewMainMenu was=1.00 now=0.00 (first try)'))
Expect $hand 'hand' 0 'hand: passes' 'All checks passed'
Expect ($hand | Where-Object { $_ -notmatch 'MUTED' }) 'hand' 1 'hand: no MUTED fails'
Expect ($hand + (L $M 'WARN GIVEUP map=SmallMap')) 'hand' 1 'hand: a WARN fails'

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "check_test: $script:passed passed, $script:failed failed"
if ($script:failed) { exit 1 }
