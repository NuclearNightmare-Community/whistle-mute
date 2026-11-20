<#
.SYNOPSIS
  Offline tests of run.ps1's contamination guard (the workspace's tools/run-guard): run.ps1 against a fake workspace
  and a fake game copy in a temp folder. Nothing can launch: the fake workspace has no tools/launch.ps1 and the copy
  no game, so every run that passes the guard stops right after it (deploy.ps1 refuses: not a game instance).
  This repo's group must be in the workspace's tools/run-guard/test-mods.json; until that change is merged there, the
  check says so as a warning instead of failing (the guard then simply doesn't know this driver).
.EXAMPLE
  pwsh -NoProfile -File test/unit/run_guard_test.ps1
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot)
$manifest = Get-Content (Join-Path $repo 'mod.json') -Raw | ConvertFrom-Json
$Owner = $manifest.id.Substring($manifest.id.LastIndexOf('.') + 1) # the id's mod part, as run.ps1's modPart
$Own = @("$($manifest.name)Driver")
$Foreign = 'WaypointsDriver'; $ForeignRepo = 'waypoints'

$script:passed = 0; $script:failed = 0
function Ok([bool] $cond, [string] $name, $detail) {
    if ($cond) { $script:passed++ } else { $script:failed++; Write-Host "FAIL $name$(if ($null -ne $detail) { " -- $detail" })" }
}

# The workspace (the main checkout or a worktree of it) holds tools/run-guard above this repo.
# CI (NN_CI=1, set by the ci workflow) has no workspace: skip there. Anywhere else a missing workspace still fails.
if ($env:NN_CI -eq '1') { Write-Host "SKIP (CI): needs the workspace's tools/run-guard"; exit 0 }
$wsReal = $repo
while ($wsReal -and -not (Test-Path (Join-Path $wsReal 'tools\run-guard\run-guard.ps1'))) { $wsReal = Split-Path $wsReal }
if (-not $wsReal) { Write-Host "FAIL the workspace's tools/run-guard/run-guard.ps1 was not found above $repo"; exit 1 }

$tmp = Join-Path ([IO.Path]::GetTempPath()) "$Owner-run-guard-$PID"
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
$ws = Join-Path $tmp 'ws'
New-Item -ItemType Directory -Force (Join-Path $ws 'tools\run-guard'), (Join-Path $ws 'mods\Nucleus') | Out-Null
Copy-Item (Join-Path $wsReal 'tools\run-guard\run-guard.ps1'), (Join-Path $wsReal 'tools\run-guard\test-mods.json') (Join-Path $ws 'tools\run-guard')
Set-Content (Join-Path $ws 'mods\Nucleus\mod.json') '{ "name": "Nucleus" }'

$n = 0
function New-Copy([string[]] $lines, [string[]] $enabledTxt = @()) {
    $script:n++
    $inst = Join-Path $ws "game-instances\v9.9-build$script:n"
    $mods = Join-Path $inst 'NuclearNightmare\Binaries\Win64\ue4ss\Mods'
    New-Item -ItemType Directory -Force $mods | Out-Null
    [IO.File]::WriteAllText((Join-Path $mods 'mods.txt'), (($lines + @('BPModLoaderMod : 1', 'Keybinds : 1')) -join "`r`n") + "`r`n")
    foreach ($e in $enabledTxt) { New-Item -ItemType Directory -Force (Join-Path $mods $e) | Out-Null; Set-Content (Join-Path $mods "$e\enabled.txt") '' }
    $inst
}
function Get-State([string] $inst) {
    $mods = Join-Path $inst 'NuclearNightmare\Binaries\Win64\ue4ss\Mods'
    (Get-ChildItem $mods -Recurse -Force | ForEach-Object { $_.FullName.Substring($mods.Length) }) -join '|'
    [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $mods 'mods.txt')))
}
function Invoke-Run([string] $inst, [string[]] $extra = @()) {
    $out = & pwsh -NoProfile -NonInteractive -File (Join-Path $repo 'run.ps1') -Instance $inst @extra 2>&1 | Out-String
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

try {
    # A foreign driver in mods.txt: refused, one command per leftover, nothing touched.
    $inst = New-Copy @("$Foreign : 1")
    $before = Get-State $inst
    $r = Invoke-Run $inst
    Ok ($r.Code -eq 1) 'foreign driver: exit 1' "exit $($r.Code)"
    Ok ($r.Out -match "(?m)^refused: other test mods are enabled in $([regex]::Escape($inst)): $Foreign\. ") 'foreign driver: refused, named' $r.Out
    $cmd = "& '$(Join-Path $ws "mods\$ForeignRepo\deploy.ps1")' -Instance '$inst' -Remove"
    Ok ($r.Out.Contains($cmd)) "foreign driver: names $ForeignRepo's deploy.ps1 -Remove" $r.Out
    Ok ($r.Out -match '(?m)^Or pass -AllowOtherDrivers to run anyway\.') 'foreign driver: names the bypass' $r.Out
    Ok ((Get-State $inst) -join "`n" -eq ($before -join "`n")) 'foreign driver: the copy is left as it was'

    # Enabled by enabled.txt in its folder (no mods.txt line): refused too.
    $inst = New-Copy @() -enabledTxt $Foreign
    $r = Invoke-Run $inst
    Ok ($r.Code -eq 1 -and $r.Out -match "(?m)^refused: .*: $Foreign\. " -and $r.Out -match 'enabled by enabled\.txt') 'enabled.txt: refused' $r.Out

    # Its own driver (and disabled foreign ones, shipped mods, unknown mods) pass the guard; the run then stops on the
    # fake copy (not a game) before anything could launch.
    $inst = New-Copy (@('Clock : 1', 'Waypoints : 1', 'SomeoneElsesMod : 1', "$Foreign : 0", "; $Foreign : 1") + @($Own | ForEach-Object { "$_ : 1" }))
    $r = Invoke-Run $inst
    Ok ($r.Out -notmatch 'refused: other test mods' -and $r.Out -notmatch 'warning: other test mods') 'own driver: no refusal' $r.Out
    Ok ($r.Code -ne 0) 'own driver: the fake copy still stops the run' "exit $($r.Code)"
    Ok ($r.Out -match 'not a game instance|already running') 'own driver: stopped by deploy.ps1, or by a game already running (nothing launched)' $r.Out

    # -AllowOtherDrivers: a warning, no refusal.
    $inst = New-Copy @("$Foreign : 1")
    $r = Invoke-Run $inst @('-AllowOtherDrivers')
    Ok ($r.Out -notmatch 'refused: other test mods' -and $r.Out -match "warning: other test mods are enabled \($Foreign\); running anyway \(-AllowOtherDrivers\)") '-AllowOtherDrivers: warning, no refusal' $r.Out

    # Static: the guard uses this repo's group (its id) and comes before the running-game check, the deploy and the launch.
    $text = Get-Content (Join-Path $repo 'run.ps1') -Raw
    $hostAt = $text.IndexOf("Get-RunGuardRefusal -Workspace `$root -Instance `$inst ")
    $running = $text.IndexOf("if (Get-Process -Name 'NuclearNightmare*'")
    $deploy = $text.IndexOf("'deploy.ps1')")
    Ok ($hostAt -gt 0 -and $running -gt $hostAt -and $deploy -gt $running -and $text.LastIndexOf("tools\launch.ps1')") -gt $deploy) 'guard before the running-game check, deploy and launch'
    Ok ($text -match '-Owner \$modPart ') "guard: this repo's group (mod.json id's mod part '$Owner')"
    $real = Get-Content (Join-Path $wsReal 'tools\run-guard\test-mods.json') -Raw | ConvertFrom-Json
    $group = @($real.groups | Where-Object { $_.id -eq $Owner })
    if ($group) {
        Ok ($group[0].repo -eq "mods/$Owner" -and $group[0].clear -eq 'remove' -and (@($group[0].mods) -join ',') -eq ($Own -join ',')) "'$Owner' group: repo mods/$Owner, clear remove, mods $($Own -join ',')" ($group | ConvertTo-Json -Compress)
    } else {
        Write-Host "warn: '$Owner' is not a group in $(Join-Path $wsReal 'tools\run-guard\test-mods.json') yet (merge the workspace branch that adds it; README)"
    }
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "run_guard_test: $script:passed passed, $script:failed failed"
if ($script:failed) { exit 1 }
