<#
.SYNOPSIS
  Unit tests for deploy-lib.ps1 (mods.txt editing) and deploy.ps1 end to end against a fake game instance in a temp
  folder (never a real copy: no game, no UE4SS, only the files deploy.ps1 looks at), plus the manifest's fields.
.EXAMPLE
  pwsh -NoProfile -File test/unit/deploy_test.ps1
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot)
. (Join-Path $repo 'deploy-lib.ps1')
$script:passed = 0; $script:failed = 0
function Ok([bool] $cond, [string] $name, $detail) {
    if ($cond) { $script:passed++ } else { $script:failed++; Write-Host "FAIL $name$(if ($null -ne $detail) { " -- $detail" })" }
}
function Eq($got, $want, [string] $name) { Ok ($got -eq $want) $name "got '$got', want '$want'" }
$N = 'WhistleMute'; $Dr = 'WhistleMuteDriver'

# ---------------------------------------------------------------- mods.txt editing
$stock = @('CheatManagerEnablerMod : 1', 'ActorDumperMod : 0', 'BPModLoaderMod : 1', 'Keybinds : 1', '', '; comment')
$r = Edit-ModsTxt -Lines $stock -Add @($N)
Eq ($r -join '|') (@('CheatManagerEnablerMod : 1', 'ActorDumperMod : 0', 'BPModLoaderMod : 1', "$N : 1", 'Keybinds : 1', '', '; comment') -join '|') 'mods.txt: right above Keybinds'
$r = Edit-ModsTxt -Lines (@("$N : 0") + $stock + @("  ${N}:1")) -Add @($Dr, $N)
Eq ($r -join '|') (@('CheatManagerEnablerMod : 1', 'ActorDumperMod : 0', 'BPModLoaderMod : 1', "$Dr : 1", "$N : 1", 'Keybinds : 1', '', '; comment') -join '|') 'mods.txt: old lines replaced; driver above the mod'
$r = Edit-ModsTxt -Lines @("$N : 1", "${N}Extra : 1", 'Keybinds : 1') -Remove @($N)
Eq ($r -join '|') "${N}Extra : 1|Keybinds : 1" 'mods.txt: remove only this name (not a longer one)'
$r = Edit-ModsTxt -Lines @('A : 1') -Add @($N)
Eq ($r -join '|') "A : 1|$N : 1" 'mods.txt: no Keybinds line -> at the end'

# ---------------------------------------------------------------- deploy.ps1 against a fake instance
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("wm-deploy-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
function New-FakeInstance([string] $modsTxt = "CheatManagerEnablerMod : 1`r`nBPModLoaderMod : 1`r`nKeybinds : 1`r`n", [switch] $NoUE4SS) {
    $i = Join-Path $tmp ([guid]::NewGuid().ToString('N').Substring(0, 6))
    $w = Join-Path $i 'NuclearNightmare\Binaries\Win64'
    New-Item -ItemType Directory -Force (Join-Path $w 'ue4ss\Mods') | Out-Null
    Set-Content (Join-Path $w 'NuclearNightmare-Win64-Shipping.exe') 'fake'
    if (-not $NoUE4SS) { Set-Content (Join-Path $w 'ue4ss\UE4SS.dll') 'fake' }
    [IO.File]::WriteAllText((Join-Path $w 'ue4ss\Mods\mods.txt'), $modsTxt)
    $i
}
function Deploy([string] $inst, [string[]] $more = @()) {
    $out = & pwsh -NoProfile -NonInteractive -File (Join-Path $repo 'deploy.ps1') -Instance $inst -Staged @more 2>&1 | Out-String
    @{ Code = $LASTEXITCODE; Out = $out }
}
try {
    $i = New-FakeInstance
    $mods = Join-Path $i 'NuclearNightmare\Binaries\Win64\ue4ss\Mods'
    $orig = [IO.File]::ReadAllBytes((Join-Path $mods 'mods.txt'))
    $r = Deploy $i
    Eq $r.Code 0 'deploy: exit 0'
    foreach ($f in 'mod.json', 'Scripts\main.lua', 'Scripts\mute.lua') { Ok (Test-Path (Join-Path $mods "$N\$f")) "deploy: installs $f" }
    Eq @(Get-ChildItem (Join-Path $mods $N) -Recurse -File).Count 3 'deploy: exactly 3 files (no tests, no docs, no asset)'
    Ok (-not (Test-Path (Join-Path $mods $Dr))) 'deploy: no driver without -Test'
    Eq ([IO.File]::ReadAllText((Join-Path $mods 'mods.txt'))) "CheatManagerEnablerMod : 1`r`nBPModLoaderMod : 1`r`n$N : 1`r`nKeybinds : 1`r`n" 'deploy: mods.txt line above Keybinds, CRLF kept'

    # -Test: the driver, its scenario, above the mod; -Map writes only the key.
    New-Item -ItemType Directory -Force (Join-Path $mods "$Dr\Scripts") | Out-Null
    foreach ($s in 'request.txt', 'done.txt', 'whistle-loud.wav', 'map.txt') { Set-Content (Join-Path $mods "$Dr\Scripts\$s") 'stale' }
    $r = Deploy $i @('-Test', '-Scenario', 'match', '-Map', 'Forest')
    Eq $r.Code 0 'deploy -Test: exit 0'
    Eq ([IO.File]::ReadAllText((Join-Path $mods "$Dr\Scripts\scenario.txt"))) 'match' 'deploy -Test: scenario.txt'
    Eq ([IO.File]::ReadAllText((Join-Path $mods "$Dr\Scripts\map.txt"))) 'Forest' 'deploy -Test -Map: map.txt holds the key'
    Eq (@(Get-ChildItem (Join-Path $mods "$Dr\Scripts") -File | ForEach-Object Name | Sort-Object) -join ',') 'main.lua,map.txt,scenario.txt' 'deploy -Test: stale request/done/wav files gone'
    Eq ([IO.File]::ReadAllText((Join-Path $mods 'mods.txt'))) "CheatManagerEnablerMod : 1`r`nBPModLoaderMod : 1`r`n$Dr : 1`r`n$N : 1`r`nKeybinds : 1`r`n" 'deploy -Test: driver line right above the mod'
    $r = Deploy $i @('-Test')
    Ok (-not (Test-Path (Join-Path $mods "$Dr\Scripts\map.txt"))) 'deploy -Test without -Map: no map.txt'
    $r = Deploy $i @('-Test', '-Map', '..\evil')
    Ok ($r.Code -ne 0) 'deploy -Map: only the table keys' $r.Out
    # Back to a plain deploy: the driver goes.
    $r = Deploy $i
    Ok (-not (Test-Path (Join-Path $mods $Dr))) 'deploy again without -Test: driver removed'
    Eq ([IO.File]::ReadAllText((Join-Path $mods 'mods.txt'))) "CheatManagerEnablerMod : 1`r`nBPModLoaderMod : 1`r`n$N : 1`r`nKeybinds : 1`r`n" 'deploy again: one line'

    $r = Deploy $i @('-Remove')
    Eq $r.Code 0 'remove: exit 0'
    Ok (-not (Test-Path (Join-Path $mods $N))) 'remove: folder gone'
    Ok ([Linq.Enumerable]::SequenceEqual([byte[]]$orig, [IO.File]::ReadAllBytes((Join-Path $mods 'mods.txt')))) 'remove: mods.txt byte-identical to before'
    $r = Deploy $i @('-Remove')
    Ok ([Linq.Enumerable]::SequenceEqual([byte[]]$orig, [IO.File]::ReadAllBytes((Join-Path $mods 'mods.txt')))) 'remove: again, still byte-identical'

    $i = New-FakeInstance -NoUE4SS
    $r = Deploy $i
    Eq $r.Code 1 'refuse: no UE4SS -> exit 1'
    Ok ($r.Out -match 'UE4SS is not installed') 'refuse: says why' $r.Out
    $r = Deploy $tmp
    Eq $r.Code 1 'refuse: not a game instance -> exit 1'

    # The manifest: every field AGENTS.md requires, the SPEC's scope, no dependency, the naming convention.
    $m = Get-Content (Join-Path $repo 'mod.json') -Raw | ConvertFrom-Json
    foreach ($k in 'id', 'name', 'version', 'scope', 'game', 'ue4ss', 'dependsOn') { Ok ($null -ne $m.$k) "mod.json: has $k" }
    Eq $m.id 'whistle-mute' 'mod.json: id (lowercase, the repo folder)'
    Eq $m.name $N 'mod.json: name (capitalized)'
    Ok ($m.version -match '^\d+\.\d+\.\d+$') 'mod.json: semver'
    Eq $m.scope 'client' 'mod.json: scope client'
    Eq @($m.dependsOn).Count 0 'mod.json: standalone (no dependsOn)'
    Eq $m.game.build '26512322' 'mod.json: game build'
    Eq $m.ue4ss 'v3.0.1-1181-g83330635' 'mod.json: the pinned UE4SS'
    $main = Get-Content (Join-Path $repo 'Scripts\main.lua') -Raw
    Ok ($main -match "local ME, VERSION = `"$([regex]::Escape($m.name))`", `"$([regex]::Escape($m.version))`"") 'main.lua: name and version match mod.json'
} finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host "deploy_test: $script:passed passed, $script:failed failed"
if ($script:failed) { exit 1 }
