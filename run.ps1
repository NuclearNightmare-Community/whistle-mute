<#
.SYNOPSIS
  Runs WhistleMute's combined scenario end to end: deploy (with the test driver), launch, serve key requests, wait,
  close, collect the recordings, check.
.DESCRIPTION
  Launches only through the workspace's tools/launch.ps1 (which passes -userdir). Stops when the driver logs its END
  line, the game exits (crash), or -TimeoutSec runs out (hang); then closes the game, force-killing it (and any crash
  reporter) after 15 s. Only ever stops the Shipping exe under this instance, never the real install or another copy.
  The driver writes "<seq> key ENTER" to its Scripts/request.txt for touchdown; this script posts the key to the
  game window's message queue (PostMessage WM_KEYDOWN/WM_KEYUP: no foreground change, no global input), then writes
  <seq> to done.txt.
  Keeps the log as <workspace>/dumps/<copy>/whistle-mute/<scenario>.log (or <scenario>-<map>.log with -Map; ignored by
  git) and the driver's recordings (whistle-*.wav: next to the driver, or under the copy's _userdir Saved/BouncedWavFiles
  if the engine put them there) in <that name>-wav/, then runs check.ps1 on them.
  Refuses to start while another runner's test or driver mod is enabled in the copy (the workspace's tools/run-guard:
  the refusal names each and the command that clears it); -AllowOtherDrivers runs anyway.
  Host only (the recordings come from this machine's audio output; no -Target vm). Steam must be running. Don't type
  into the game while it runs. Sound must not be muted in the game's settings (the stock whistle must reach the
  recording, or check.ps1 fails the run as inconclusive).
.EXAMPLE
  ./run.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.2.3-build26601774
  ./run.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.2.3-build26601774 -Map Forest
#>
param(
    [Parameter(Mandatory)] [string] $Instance,
    [ValidateSet('match')] [string] $Scenario = 'match',
    [ValidateSet('', 'LowIsland', 'TowerIsland', 'Forest', 'Crevasse', IgnoreCase = $false)] [string] $Map = '', # '': Tower Island
    [int] $TimeoutSec = 480,
    [switch] $AllowOtherDrivers # run even when another runner's test mod is enabled in the copy (tools/run-guard)
)
$ErrorActionPreference = 'Stop'
$here     = $PSScriptRoot
$manifest = Get-Content (Join-Path $here 'mod.json') -Raw | ConvertFrom-Json
$name     = $manifest.name
$driver   = "${name}Driver"
$inst     = (Resolve-Path $Instance).Path
$root     = Split-Path (Split-Path $inst)
. (Join-Path $root 'tools\run-guard\run-guard.ps1')
# The id's mod part (the repo folder): the run-guard group in tools/run-guard/test-mods.json and the dumps folder.
$modPart  = $manifest.id.Substring($manifest.id.LastIndexOf('.') + 1)
$outDir   = Join-Path $root "dumps\$(Split-Path $inst -Leaf)\$modPart"
$logBase  = if ($Map) { "$Scenario-$Map" } else { $Scenario }
$ue4ss    = Join-Path $inst 'NuclearNightmare\Binaries\Win64\ue4ss'
$log      = Join-Path $ue4ss 'UE4SS.log'
$scripts  = Join-Path $ue4ss "Mods\$driver\Scripts"
$exeName  = 'NuclearNightmare-Win64-Shipping'

# A test mod another runner left enabled would fail this run in confusing ways.
$refusal = Get-RunGuardRefusal -Workspace $root -Instance $inst -Owner $modPart -Bypass:$AllowOtherDrivers
if ($refusal) { Write-Host $refusal; exit 1 }
if (Get-Process -Name 'NuclearNightmare*' -ErrorAction SilentlyContinue) { throw 'Nuclear Nightmare is already running (a dev copy or the real game); not launching.' }

New-Item -ItemType Directory -Force $outDir | Out-Null
Add-Type -Namespace WhistleMuteRun -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr h, uint msg, System.IntPtr w, System.IntPtr l);
'@

function Get-OurGame { Get-Process -Name $exeName -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($inst, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1 }
function Stop-Game {
    $p = Get-OurGame
    if ($p) { [void]$p.CloseMainWindow(); if (-not $p.WaitForExit(15000)) { Stop-Process -Id $p.Id -Force } }
    Get-Process -Name 'CrashReportClient*' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($inst, [StringComparison]::OrdinalIgnoreCase) } | Stop-Process -Force
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-OurGame) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
}
function Invoke-Request([string] $cmd) {
    if ($cmd -eq 'key ENTER') {
        $p = Get-OurGame
        $h = if ($p) { $p.MainWindowHandle } else { [IntPtr]::Zero }
        if ($h -eq [IntPtr]::Zero) { Write-Host '  key skipped: no game window'; return }
        $down = [WhistleMuteRun.Win]::PostMessage($h, 0x0100, [IntPtr]0x0D, [IntPtr]0x001C0001)            # WM_KEYDOWN, VK_RETURN, scan 0x1C
        Start-Sleep -Milliseconds 80
        $up = [WhistleMuteRun.Win]::PostMessage($h, 0x0101, [IntPtr]0x0D, [IntPtr]([int64]0xC01C0001))   # WM_KEYUP
        Write-Host ("  posted ENTER to the game window (down={0} up={1})" -f $down, $up)
    } else { Write-Host "  unknown request: $cmd" }
}

$sw = [Diagnostics.Stopwatch]::StartNew()
$result = 'not started'
$started = Get-Date
try {
    # deploy.ps1 ends with exit 1 when it refuses, so it runs in its own pwsh.
    $a = @('-Test', '-Scenario', $Scenario)
    if ($Map) { $a += @('-Map', $Map) }
    $out = & pwsh -NoProfile -NonInteractive -File (Join-Path $here 'deploy.ps1') -Instance $inst @a 2>&1 | Out-String
    Write-Host $out.Trim()
    if ($LASTEXITCODE -ne 0) { throw "deploy.ps1 failed (exit $LASTEXITCODE)" }

    Remove-Item $log -ErrorAction SilentlyContinue
    & (Join-Path $root 'tools\launch.ps1') -Instance $inst
    $req = Join-Path $scripts 'request.txt'
    $done = Join-Path $scripts 'done.txt'
    $lastSeq = 0
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $result = 'timeout (hang?)'
    Start-Sleep -Seconds 5
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-OurGame)) { $result = 'game exited (crash?)'; break }
        if (Test-Path $req) {
            $text = Get-Content $req -Raw -ErrorAction SilentlyContinue
            if ($text -match '^(\d+) (.+)$' -and [int]$Matches[1] -gt $lastSeq) {
                $lastSeq = [int]$Matches[1]
                Write-Host ("[{0,5:N1}s] request {1}: {2}" -f $sw.Elapsed.TotalSeconds, $lastSeq, $Matches[2])
                Invoke-Request $Matches[2]
                Set-Content $done $lastSeq -NoNewline
            }
        }
        if ((Test-Path $log) -and (Select-String -Path $log -Pattern "\[$driver\] END result=" -Quiet)) { $result = 'finished'; break }
        Start-Sleep -Milliseconds 250
    }
} finally {
    Write-Host ("Run {0} after {1:N0} s." -f $result, $sw.Elapsed.TotalSeconds)
    Start-Sleep -Seconds 2
    Stop-Game
}

$kept = Join-Path $outDir "$logBase.log"
if (Test-Path $log) { Copy-Item $log $kept -Force } else { Write-Host "No UE4SS.log at $log" }
# The recordings: written by StopRecordingOutput to the driver's folder (an absolute path), or, if the engine put them
# under the project's Saved folder instead, the copy's _userdir (launch.ps1's -userdir). Only this run's files.
$wavOut = Join-Path $outDir "$logBase-wav"
Remove-Item $wavOut -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $wavOut | Out-Null
$wavDirs = @($scripts, (Join-Path $inst '_userdir\Saved\BouncedWavFiles'), (Join-Path $inst 'NuclearNightmare\Saved\BouncedWavFiles'))
foreach ($d in $wavDirs) {
    if (-not (Test-Path $d)) { continue }
    Get-ChildItem $d -Filter 'whistle-*.wav' -File | Where-Object { $_.LastWriteTime -ge $started } | ForEach-Object {
        Copy-Item $_.FullName (Join-Path $wavOut $_.Name) -Force
        Write-Host "  recording $($_.Name) ($($_.Length) bytes) from $d"
    }
}
& pwsh -NoProfile -NonInteractive -File (Join-Path $here 'check.ps1') -Log $kept -Scenario $Scenario -WavDir $wavOut
exit $LASTEXITCODE
