<#
.SYNOPSIS
  Unit tests for test/pair/whistle-scenarios.ps1 without the VM or a game: the file loads on its own and into a
  $PairScenarios table in pair.ps1's shape, the stage holds exactly what deploy.ps1 -Test installs, the request
  whitelist and the whistle key, the request server against a fake host copy (pair.ps1's helpers stubbed), the copy of
  the recordings, and the scenario's Check over synthetic logs and recordings.
.EXAMPLE
  pwsh -NoProfile -File test/unit/pair_test.ps1
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot)
. (Join-Path $PSScriptRoot 'wavgen.ps1')
$script:passed = 0; $script:failed = 0
function Ok([bool] $cond, [string] $name, $detail) {
    if ($cond) { $script:passed++ } else { $script:failed++; Write-Host "FAIL $name$(if ($null -ne $detail) { " -- $detail" })" }
}
function Eq($got, $want, [string] $name) { Ok ($got -eq $want) $name "got '$got', want '$want'" }

# The file parses, and loads into pair.ps1's table without replacing anything there.
$errs = $null
[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'test\pair\whistle-scenarios.ps1'), [ref]$null, [ref]$errs)
Eq @($errs).Count 0 'parse: no syntax errors'
$script:PairScenarios = @{ 'b5' = @{ Summary = 'built-in' } }
. (Join-Path $repo 'test\pair\whistle-scenarios.ps1')
Ok ($PairScenarios.ContainsKey('wm-listen')) 'load: adds wm-listen'
Eq $PairScenarios['b5'].Summary 'built-in' 'load: leaves built-ins alone'
Ok (@($PairScenarios.Keys | Where-Object { $_ -ne 'b5' -and $_ -cnotmatch '^[a-z0-9-]+$' }).Count -eq 0) 'load: names pass pair.ps1''s name rule'
$sc = $PairScenarios['wm-listen']
foreach ($k in 'Summary', 'Prereq', 'HostModPaths', 'VMSetup', 'VMRestore', 'AfterJoin', 'Check') { Ok ($null -ne $sc[$k]) "shape: has $k" }
foreach ($k in 'Prereq', 'HostModPaths', 'VMSetup', 'VMRestore', 'AfterJoin', 'Check') { Ok ($sc[$k] -is [scriptblock]) "shape: $k is a scriptblock" }
Ok (-not $sc.ContainsKey('HostFiles')) 'shape: no host files (PairDriver as for B1)'
Ok ($sc.LobbyMinutes -ge 5) "shape: a lobby long enough for the windows ($($sc.LobbyMinutes) min)"
Ok ($sc.VMSetup.ToString() -match 'Restore-VMBaseline' -and $sc.VMSetup.ToString() -notmatch 'UE4SS On|Invoke-VMDeploy -Path') 'shape: B stays vanilla'

# The stage: what deploy.ps1 -Test -Scenario pair-listen installs, nothing more.
$s = Get-WmStage
Eq (Split-Path $s.Mod -Leaf) 'WhistleMute' 'stage: the mod folder'
Eq (Split-Path $s.Driver -Leaf) 'WhistleMuteDriver' 'stage: the driver folder'
Eq (@(Get-ChildItem $s.Mod -Recurse -File | ForEach-Object { $_.FullName.Substring($s.Mod.Length + 1) } | Sort-Object) -join ',') 'mod.json,Scripts\main.lua,Scripts\mute.lua' 'stage: the mod''s three files'
Eq (@(Get-ChildItem $s.Driver -Recurse -File | ForEach-Object { $_.FullName.Substring($s.Driver.Length + 1) } | Sort-Object) -join ',') 'Scripts\main.lua,Scripts\scenario.txt' 'stage: the driver and its scenario'
Eq ([IO.File]::ReadAllText((Join-Path $s.Driver 'Scripts\scenario.txt'))) 'pair-listen' 'stage: scenario pair-listen'
$hm = @(& $sc.HostModPaths)
Eq (@($hm | ForEach-Object { Split-Path $_ -Leaf }) -join ',') 'WhistleMuteDriver,WhistleMute' 'stage: HostModPaths returns the driver, then the mod'

# The request whitelist.
Eq (ConvertFrom-WmRequest "3 vmkey whistle").Cmd 'vmkey whistle' 'request: vmkey whistle'
Eq (ConvertFrom-WmRequest "12 key ENTER`r`n").Seq 12 'request: seq with a newline'
Eq (ConvertFrom-WmRequest '1 vmkey ENTER').Cmd 'vmkey ENTER' 'request: vmkey ENTER'
foreach ($bad in @('', $null, '1 vmkey whistle; calc', '1 vmkey Escape', 'x key ENTER', '1 key enter', ('1 ' + 'a' * 80), '1 vmkey whistle extra', '9999999 key ENTER')) {
    Ok ($null -eq (ConvertFrom-WmRequest $bad)) "request: refuses '$bad'"
}

# The whistle key: pair-lib's Get-VirtualKey decides what vm-key can post.
$gitCommon = & git -C $repo rev-parse --path-format=absolute --git-common-dir 2>$null   # <workspace>\mods\whistle-mute\.git
$pairLib = if ($LASTEXITCODE -eq 0 -and $gitCommon) { Join-Path (Split-Path (Split-Path (Split-Path ($gitCommon -replace '/', '\')))) 'tools\vm\pair-lib.ps1' }
if ($pairLib -and (Test-Path $pairLib)) { . $pairLib }
if (-not (Get-Command Get-VirtualKey -ErrorAction SilentlyContinue)) {
    # Outside the workspace: the same contract for letters, digits and a few names.
    function Get-VirtualKey([string] $KeyName) { if ($KeyName -cmatch '^([A-Z]|Enter|Zero|One|Two)$') { [pscustomobject]@{ Name = $KeyName } } else { throw "Key '$KeyName' is not supported" } }
}
function Write-Warning([string] $Message) { $script:warned++ }
$km = @('[x] [Lua] [WhistleMuteDriver] KEYMAPS pair 2 whistle mapping(s)',
    '[x] [Lua] [WhistleMuteDriver] KEYMAP IMC_Default action=IA_Whistle key=Gamepad_FaceButton_Top',
    '[x] [Lua] [WhistleMuteDriver] KEYMAP IMC_Default action=IA_Whistle key=G')
Eq (Get-WmWhistleKey -Lines $km) 'G' 'key: the first postable KEYMAP key'
Eq (Get-WmWhistleKey -Lines $km -Override 'H') 'H' 'key: -ScenarioArgs WhistleKey wins'
$script:warned = 0
Eq (Get-WmWhistleKey -Lines $km -Override 'NotAKey') 'G' 'key: a bad override falls back to the log'
Eq $script:warned 1 'key: ... with a warning'
Ok ($null -eq (Get-WmWhistleKey -Lines @('[x] [Lua] [WhistleMuteDriver] KEYMAP IMC action=IA_TextChat key=T'))) 'key: another action''s key is not the whistle'
Ok ($null -eq (Get-WmWhistleKey -Lines @('[x] [Lua] [Other] KEYMAP IMC action=IA_Whistle key=G'))) 'key: only the driver''s KEYMAP lines'

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("wm-pair-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $tmp | Out-Null
try {
    # The request server and the copy, against a fake host copy; pair.ps1's helpers stubbed.
    $modsDir = Join-Path $tmp 'Mods'; $outDir = Join-Path $tmp 'pair'; $Label = 'wm-test'; $ScenarioArgs = @{}
    $scripts = Join-Path $modsDir 'WhistleMuteDriver\Scripts'
    New-Item -ItemType Directory -Force $scripts, $outDir | Out-Null
    $script:vmKeys = @(); $script:hostEnter = 0; $script:flagChecks = 0; $script:endAfter = 0
    $script:plan = @('1 key ENTER', '2 vmkey ENTER', '2 vmkey ENTER', 'junk', '3 vmkey whistle', '4 vmkey Escape', '5 vmkey whistle')
    function Get-HostCopyProcess { [pscustomobject]@{ ProcessId = 1 } }
    function Send-WmHostEnter { $script:hostEnter++; $true }
    function Send-VMKey([string] $Key) { $script:vmKeys += $Key; $true }
    function Assert-FriendsOnly { $script:flagChecks++ }
    function Get-HostLogLines([switch] $Copy) { $km }
    # The fake driver: the next planned request each time the server looks; END once the plan is done.
    function Find-HostLine([string] $pattern) {
        if ($script:plan.Count) { Set-Content (Join-Path $scripts 'request.txt') $script:plan[0] -NoNewline; $script:plan = @($script:plan | Select-Object -Skip 1); return $null }
        if ($script:endAfter++ -ge 2) { return [pscustomobject]@{ Line = '[WhistleMuteDriver] END result=PASS' } }
        $null
    }
    $served = @(Invoke-WmRequestServer -TimeoutSec 30)
    Eq ($served -join ',') '1 key ENTER,2 vmkey ENTER,3 vmkey whistle,5 vmkey whistle' 'server: serves the whitelist once per seq, in order'
    Eq $script:hostEnter 1 'server: key ENTER -> the host window'
    Eq ($script:vmKeys -join ',') 'Enter,G,G' 'server: vmkey ENTER -> Enter, vmkey whistle -> the KEYMAP key'
    Eq (Get-Content (Join-Path $scripts 'done.txt') -Raw) '5' 'server: done.txt holds the last seq'
    Ok ($script:flagChecks -ge 1) 'server: checks the friends-only flags'
    $script:plan = @('1 vmkey whistle'); $script:endAfter = 0; $script:vmKeys = @(); $ScenarioArgs = @{ WhistleKey = 'H' }
    Remove-Item (Join-Path $scripts 'done.txt')
    [void](Invoke-WmRequestServer -TimeoutSec 30)
    Eq ($script:vmKeys -join ',') 'H' 'server: -ScenarioArgs WhistleKey'
    function Get-HostCopyProcess { $null }
    $script:plan = @(); $script:endAfter = -1000
    $threw = $false; try { [void](Invoke-WmRequestServer -TimeoutSec 5) } catch { $threw = "$_" -match 'host game exited' }
    Ok $threw 'server: stops when the host game is gone'

    foreach ($n in 'whistle-quiet1.wav', 'whistle-muted2.wav', 'whistle-evil name.wav', 'other.wav') { Set-Content (Join-Path $scripts $n) 'x' }
    $dst = Copy-WmRecordings
    Eq $dst (Join-Path $outDir 'wm-test-wav') 'copy: to <label>-wav next to the result'
    Eq (@(Get-ChildItem $dst | ForEach-Object Name | Sort-Object) -join ',') 'whistle-muted2.wav,whistle-quiet1.wav' 'copy: only the driver''s recordings'

    # Verdict rules and the Check block over a synthetic host log and recordings.
    Eq (Get-WmVerdict 0 'All checks passed.') 'PASS' 'verdict: exit 0'
    Eq (Get-WmVerdict 1 "FAIL: INCONCLUSIVE: the client's stock whistle is not audible") 'INCONCLUSIVE' 'verdict: inconclusive'
    Eq (Get-WmVerdict 1 'FAIL: muted ...') 'FAIL' 'verdict: fail'
    $result = @{ Joined = $false; Outcome = 'FAIL' }
    Eq (& $sc.Check).Verdict 'FAIL' 'check: B never joined -> FAIL, not judged'
    $result = @{ Joined = $true; Outcome = 'PASS' }
    Eq (& $sc.Check).Verdict 'FAIL' 'check: no host log -> FAIL'
    Remove-Item $dst -Recurse -Force; New-Item -ItemType Directory $dst | Out-Null
    foreach ($k in 'quiet1', 'quiet2', 'muted', 'muted2') { New-TestWav (Join-Path $dst "whistle-$k.wav") -Seed ([array]::IndexOf(@('quiet1', 'quiet2', 'muted', 'muted2'), $k) + 1) }
    New-TestWav (Join-Path $dst 'whistle-loud.wav') -Whistle 0.3 -Seed 9
    $t = 0
    function L([string] $msg) { $script:t++; "[2026-11-12 01:00:00.{0:D7}] [Lua] $msg" -f $script:t }
    $log = @((L "[WhistleMute] loaded 0.1.0 (x)"), (L '[WhistleMuteDriver] SCENARIO pair-listen'), (L '[WhistleMute] MUTED map=SmallMap was=0.00 now=0.00 (first try)'),
        (L '[WhistleMuteDriver] OK HOOK pair WhistleALL post-hook'), (L '[WhistleMuteDriver] OK REMOTE pair the other player''s character is here (BP_FirstPersonCharacter_C, dist 3.0 m)'),
        (L '[WhistleMuteDriver] OK VOLUME pair Whistle01 Volume=0.00 (the mod''s 0)'), (L '[WhistleMuteDriver] OK VOLUME pair Whistle01 Volume=0.00 (the mod''s 0)'),
        (L '[WhistleMuteDriver] OK SETVOL pair stock Volume=1.00 (stock seen before the mod: 1.00)'), (L '[WhistleMuteDriver] OK SETVOL pair muted Volume=0.00 (stock seen before the mod: 1.00)'))
    foreach ($k in 'quiet1', 'muted', 'loud', 'muted2', 'quiet2') {
        if ($k -match 'muted|loud') {
            $log += L ("[WhistleMuteDriver] VMKEY pair $k requesting the client's whistle (try 1) Volume={0}" -f $(if ($k -eq 'loud') { '1.00' } else { '0.00' }))
            $log += L "[WhistleMuteDriver] HEARD $k remote at 2.00 s dist=3.0 m"
            $log += L "[WhistleMuteDriver] OK CLIENTWHISTLE pair $k the client's whistle played here at 2.00 s into the recording (try 1)"
        }
        $log += L "[WhistleMuteDriver] OK REC pair $k stopped -> C:\x\whistle-$k.wav (StopRecordingOutput)"
    }
    $log += L '[WhistleMuteDriver] END result=PASS checks=20 failures=0'
    Set-Content (Join-Path $outDir 'wm-test.host.UE4SS.log') $log
    $script:WmServed = @('3 vmkey whistle')
    $r = & $sc.Check
    Eq $r.Verdict 'PASS' "check: a good host log and recordings -> PASS ($($r.Failures -join ' | '))"
    Ok (@($r.Audio | Where-Object { $_ -match 'silent' }).Count -eq 2) 'check: reports both muted windows'
    New-TestWav (Join-Path $dst 'whistle-loud.wav') -Seed 10
    Eq (& $sc.Check).Verdict 'INCONCLUSIVE' 'check: the client''s stock whistle not audible -> INCONCLUSIVE'
    New-TestWav (Join-Path $dst 'whistle-loud.wav') -Whistle 0.3 -Seed 9
    New-TestWav (Join-Path $dst 'whistle-muted.wav') -Whistle 0.3 -Seed 11
    Eq (& $sc.Check).Verdict 'FAIL' 'check: the client''s whistle heard with the mod -> FAIL'
} finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue; Remove-Item (Join-Path ([IO.Path]::GetTempPath()) 'nn-whistle-stage') -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host "pair_test: $script:passed passed, $script:failed failed"
if ($script:failed) { exit 1 }
