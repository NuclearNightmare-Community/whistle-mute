<#
.SYNOPSIS
  Installs WhistleMute into a dev copy of Nuclear Nightmare, or removes it.
.DESCRIPTION
  Installs ue4ss/Mods/WhistleMute/{mod.json, Scripts/main.lua, Scripts/mute.lua} and writes "WhistleMute : 1" into
  mods.txt right above "Keybinds : 1" (moving it there if it was elsewhere). Standalone: needs UE4SS only, no other
  mod, and ships no asset. Never writes outside Mods/WhistleMute, Mods/WhistleMuteDriver and their mods.txt lines.
  -Test also installs the test driver (test/WhistleMuteDriver as Mods/WhistleMuteDriver, its line right above the
  mod's) and writes the scenario to its Scripts/scenario.txt; -Map (with -Test) writes the match map's key to its
  Scripts/map.txt (only a key of the driver's fixed table; without -Map: Tower Island). Every test deploy removes the
  driver's old scenario, request, done, map and .wav files first.
  -Remove deletes Mods/WhistleMute and Mods/WhistleMuteDriver and their mods.txt lines; nothing else changes (mods.txt
  keeps its bytes when it had no such line).
  -Staged: $Instance is a host-side staging folder (a fake copy), not a game copy; only the running-game check is
  skipped.
  Pass the main checkout's instance path when running from a worktree.
.EXAMPLE
  ./deploy.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.2.3-build26601774
  ./deploy.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.2.3-build26601774 -Test -Scenario match
  ./deploy.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.2.3-build26601774 -Remove
#>
param(
    [Parameter(Mandatory)] [string] $Instance,
    [switch] $Test,
    [ValidateSet('match', 'pair-listen')] [string] $Scenario = 'match',
    [ValidateSet('', 'LowIsland', 'TowerIsland', 'Forest', 'Crevasse', IgnoreCase = $false)] [string] $Map = '',
    [switch] $Remove,
    [switch] $Staged
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'deploy-lib.ps1')

$here     = $PSScriptRoot
$manifest = Get-Content (Join-Path $here 'mod.json') -Raw | ConvertFrom-Json
$name     = $manifest.name
$driver   = "${name}Driver"
$inst     = (Resolve-Path $Instance).Path
$win64    = Join-Path $inst 'NuclearNightmare\Binaries\Win64'
$ue4ss    = Join-Path $win64 'ue4ss'
$modsDir  = Join-Path $ue4ss 'Mods'
$modsTxt  = Join-Path $modsDir 'mods.txt'
$files    = $ModScripts

function Stop-Deploy([string] $why) { Write-Host "$name not deployed: $why"; exit 1 }

if (-not (Test-Path (Join-Path $win64 'NuclearNightmare-Win64-Shipping.exe'))) { Stop-Deploy "not a game instance: $inst" }
if (-not (Test-Path (Join-Path $ue4ss 'UE4SS.dll'))) { Stop-Deploy "UE4SS is not installed in $win64" }
if (-not (Test-Path $modsTxt)) { Stop-Deploy "no mods.txt in $modsDir" }
if (-not $Staged -and (Get-Process -Name 'NuclearNightmare*' -ErrorAction SilentlyContinue)) { Stop-Deploy 'Nuclear Nightmare is running; close it first.' }

$file  = Read-ModsTxt $modsTxt
$mine  = @($name, $driver)
$clean = Edit-ModsTxt -Lines $file.Lines -Remove $mine

if ($Remove) {
    foreach ($d in $mine) { Remove-Item (Join-Path $modsDir $d) -Recurse -Force -ErrorAction SilentlyContinue }
    if ($clean.Count -ne $file.Lines.Count) { Write-ModsTxt $modsTxt $file $clean }
    Write-Host "$name removed (and $driver, if it was installed)."
    return
}
if ($Map -and -not $Test) { Write-Warning "-Map $Map needs -Test (it picks the test driver's map); ignored." }

foreach ($d in $mine) { Remove-Item (Join-Path $modsDir $d) -Recurse -Force -ErrorAction SilentlyContinue }
$dir = Join-Path $modsDir $name
New-Item -ItemType Directory -Force (Join-Path $dir 'Scripts') | Out-Null
Copy-Item (Join-Path $here 'mod.json') $dir -Force
foreach ($f in $files) { Copy-Item (Join-Path $here "Scripts\$f") (Join-Path $dir 'Scripts') -Force }

$add = @($name)
if ($Test) {
    $ds = Join-Path $modsDir "$driver\Scripts"
    New-Item -ItemType Directory -Force $ds | Out-Null
    Copy-Item (Join-Path $here "test\$driver\Scripts\main.lua") $ds -Force
    [IO.File]::WriteAllText((Join-Path $ds 'scenario.txt'), $Scenario)
    if ($Map) { [IO.File]::WriteAllText((Join-Path $ds 'map.txt'), $Map) }
    $add = @($driver, $name) # the driver's LoadMap pre-hook reads the Volume before the mod's post-hook sets it
}
$lines = Edit-ModsTxt -Lines $clean -Add $add
Write-ModsTxt $modsTxt $file $lines

Write-Host "$name $($manifest.version) deployed$(if ($Test) { " with $driver (scenario $Scenario$(if ($Map) { ", map $Map" }))" }):"
foreach ($d in $mine) {
    $p = Join-Path $modsDir $d
    if (Test-Path $p) { Get-ChildItem $p -Recurse -File | ForEach-Object { Write-Host "  Mods/$d/$($_.FullName.Substring($p.Length + 1)) ($($_.Length) bytes)" } }
}
Write-Host "mods.txt: $(($lines | Where-Object { $_ -match '^\s*[\w-]+\s*:\s*1' }) -join ', ')"
