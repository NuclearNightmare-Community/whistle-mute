<#
.SYNOPSIS
  Judges one run of WhistleMute from UE4SS.log (and, for match, the driver's recordings).
.DESCRIPTION
  Prints the mod's, the driver's and UE4SS's relevant lines, then checks the patterns the scenario needs. A pattern
  must match somewhere; "!pattern" must match nowhere; "#N|pattern" must match exactly N lines; "?pattern" is a soft
  check (reported as "warn:", never failing).
  Scenarios:
    match  run.ps1's combined scenario: the mod muted the whistle on the menu and the match map, the driver's checks
           passed, and the recordings (wav-lib.ps1) show the stock whistle and no whistle with the mod's Volume 0.
           -WavDir: where run.ps1 put the recordings (default: <log name without .log>-wav next to the log).
           Also prints what the run says about the SPEC's open questions (is the wave loaded at LoadMap; does a map
           change or a GC reset its Volume).
    hand   a log from a hand session (README): loaded once, at least one MUTED line, no WARN and no script error.
    unit   needs no log: runs test.ps1.
  Exit code 1 when any check fails; otherwise prints "All checks passed."
.EXAMPLE
  ./check.ps1 -Log C:\...\nuclear-nightmare\dumps\v8.2.3-build26601774\whistlemute\match.log -Scenario match
  ./check.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.2.3-build26601774 -Scenario hand
#>
param(
    [string] $Instance,
    [string] $Log,
    [ValidateSet('match', 'hand', 'unit')] [string] $Scenario = 'match',
    [string] $WavDir
)
if ($Scenario -eq 'unit') { & pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'test.ps1'); exit $LASTEXITCODE }
$manifest = Get-Content (Join-Path $PSScriptRoot 'mod.json') -Raw | ConvertFrom-Json
$name = $manifest.name
$C = [regex]::Escape($name); $D = [regex]::Escape("${name}Driver"); $V = [regex]::Escape($manifest.version)
if (-not $Log) {
    if (-not $Instance) { Write-Host 'FAIL: pass -Log <file> or -Instance <copy>'; exit 1 }
    $Log = Join-Path (Resolve-Path $Instance) 'NuclearNightmare\Binaries\Win64\ue4ss\UE4SS.log'
}
if (-not (Test-Path $Log)) { Write-Host "FAIL: no log at $Log"; exit 1 }
if (-not $WavDir) { $WavDir = Join-Path (Split-Path $Log) (([IO.Path]::GetFileNameWithoutExtension($Log)) + '-wav') }

$lines = @(Get-Content $Log)
Write-Host "--- $name lines ($Scenario) ---"
$lines | Where-Object {
    $_ -match "\[$C\]|\[$D\]" -or $_ -match 'Error executing script|threw an exception|removing hook|Unhandled Exception|stack traceback|\[script_hook\]'
} | ForEach-Object { $_ -replace '^\[[^\]]+\]\s*', '' -replace '^\[Lua\]\s*', '' }

$always = @(
    '!Unhandled Exception'
    '!Error executing script'
    '!removing hook'
    '!stack traceback'
    '!\[script_hook\]'
    '!A function requiring userdata as param #1 was called without userdata'
    "#1|\[$C\] loaded $V "
    "!\[$C\] WARN "
)
$expect = @{
    'match' = @(
        "\[$D\] SCENARIO match\s*$"
        "\[$D\] END result=PASS"
        "!\[$D\] FAIL "
        "!\[$D\] .*STEP '.*' threw"
        "\[$C\] MUTED map=NewMainMenu was=\S+ now=0\.00 "
        "\[$C\] MUTED map=(?!NewMainMenu |GraphicsWarmup )\S+ was=\S+ now=0\.00 "
        "\[$D\] OK VOLUME menu1 ", "\[$D\] OK VOLUME match1 ", "\[$D\] OK VOLUME menu2 "
        "#4|\[$D\] OK REC match1 \S+ started ", "#4|\[$D\] OK REC match1 \S+ stopped "
        "#2|\[$D\] WHISTLE match1 (muted|loud) at [\d.]+ s Volume=\S+ ok=true"
        "\[$D\] WHISTLE match1 muted at [\d.]+ s Volume=0\.00 ok=true"
        "\[$D\] OK SETVOL match1 stock ", "\[$D\] OK SETVOL match1 muted Volume=0\.00 "
        # The SPEC's open question "is Whistle01 loaded when LoadMap fires": informational (a MISS is retried).
        "?!\[$C\] MISS "
    )
    'hand' = @(
        "\[$C\] MUTED map=\S+ was=\S+ now=0\.00 "
    )
}

$failed = 0
$warned = 0
function Fail([string] $label) { Write-Host "FAIL: $label"; $script:failed++ }
function Pass([string] $label) { Write-Host "ok:   $label" }
Write-Host "--- checks ($Scenario) ---"
foreach ($pattern in ($always + $expect[$Scenario])) {
    if ($pattern.StartsWith('#')) {
        $count, $p = $pattern.Substring(1) -split '\|', 2
        $hits = @($lines | Where-Object { $_ -match $p }).Count
        if ($hits -eq [int]$count) { Pass "$pattern (found $hits)" } else { Fail "$pattern (found $hits)" }
    } elseif ($pattern.StartsWith('?!')) {
        if ($lines | Where-Object { $_ -match $pattern.Substring(2) }) { Write-Host "warn: $pattern"; $warned++ } else { Pass $pattern }
    } elseif ($pattern.StartsWith('?')) {
        if ($lines | Where-Object { $_ -match $pattern.Substring(1) }) { Pass $pattern } else { Write-Host "warn: $pattern"; $warned++ }
    } elseif ($pattern.StartsWith('!')) {
        if ($lines | Where-Object { $_ -match $pattern.Substring(1) }) { Fail $pattern } else { Pass $pattern }
    } else {
        if ($lines | Where-Object { $_ -match $pattern }) { Pass $pattern } else { Fail $pattern }
    }
}

if ($Scenario -eq 'match') {
    # CAP-1: the runtime Volume is honoured. The stock whistle shows in the recording; with Volume 0 it doesn't.
    . (Join-Path $PSScriptRoot 'wav-lib.ps1')
    $wav = @{}
    foreach ($k in 'quiet1', 'muted', 'loud', 'quiet2') { $wav[$k] = Join-Path $WavDir "whistle-$k.wav" }
    $missing = @($wav.Keys | Where-Object { -not (Test-Path $wav[$_]) } | Sort-Object)
    if ($missing) { Fail "recordings in $WavDir (missing: $($missing -join ', '))" }
    else {
        try {
            $r = Test-WhistleMuted -Quiet1 $wav.quiet1 -Quiet2 $wav.quiet2 -Muted $wav.muted -Loud $wav.loud
            if ($r.Audible) { Pass "the stock whistle is audible in the recording: $($r.Text)" }
            else { Fail "the stock whistle is not audible in the recording, so the run proves nothing (sound device? game volume?): $($r.Text)" }
            if ($r.Audible) { if ($r.Muted) { Pass "with the mod's Volume 0 the whistle is silent: $($r.Text)" } else { Fail "with the mod's Volume 0 the whistle is still heard: $($r.Text)" } }
        } catch { Fail "reading the recordings: $($_.Exception.Message)" }
    }

    # The SPEC's open questions, as this run answers them (informational).
    Write-Host '--- open questions (this run) ---'
    $miss = @($lines | Where-Object { $_ -match "\[$C\] MISS map=(\S+)" } | ForEach-Object { [void]($_ -match 'MISS map=(\S+)'); $Matches[1] } | Select-Object -Unique)
    Write-Host ("Whistle01 loaded when LoadMap fires: {0}" -f $(if ($miss) { "no on $($miss -join ', ') (retried)" } else { 'yes, on every map of this run' }))
    $was = @($lines | Where-Object { $_ -match "\[$C\] MUTED map=(\S+) was=(\S+) " } | ForEach-Object { [void]($_ -match 'MUTED map=(\S+) was=(\S+) '); "$($Matches[1]):$($Matches[2])" })
    $reset = @($was | Select-Object -Skip 1 | Where-Object { $_ -notmatch ':0\.00$' })
    Write-Host ("Volume at each LoadMap before the mod set it: {0} -> {1}" -f ($was -join ', '),
        $(if (-not $was) { 'unknown' } elseif ($reset) { "a map change reset it ($($reset -join ', '))" } else { 'a map change did not reset it' }))
    $gc = @($lines | Where-Object { $_ -match "\[$D\] AFTERGC " } | ForEach-Object { $_ -replace '^.*AFTERGC ', '' })
    if ($gc) { Write-Host "After a garbage collection in the match: $($gc -join '; ')" }
}

if ($failed) { Write-Host "$failed check(s) failed."; exit 1 }
Write-Host ("All checks passed{0}." -f $(if ($warned) { " ($warned soft check(s) not met)" } else { '' }))
