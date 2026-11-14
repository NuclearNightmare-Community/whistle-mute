<#
.SYNOPSIS
  WhistleMute's two-player scenario for tools/vm/pair.ps1 (the workspace's pair tooling): the HOST has WhistleMute and
  must not hear the OTHER player's whistle.
.DESCRIPTION
  A -ScenarioFile for pair.ps1: dot-sourced after its own pair-scenarios.ps1, in the same shape, and adds wm-listen to
  its $PairScenarios (the last lines of this file).
    wm-listen  A (host, this PC) = WhistleMute + WhistleMuteDriver "pair-listen" (installed for the run only through
               HostModPaths, staged by this repo's deploy.ps1 -Test -Scenario pair-listen -Staged).
               B (VM) = vanilla (UE4SS off): its whistle is the real player path (the whistle key -> WhistleServer, a
               server RPC to the host -> WhistleALL, the multicast every machine plays Whistle01 in). B's own mod
               state can't change what A hears, so a vanilla B also shows the mod is needed only on the listener.
               The host driver hooks WhistleALL (whose whistle it was, when), records five windows of A's audio
               output (quiet1, muted, loud = the stock Volume put back: the control, muted2, quiet2) and asks for B's
               whistle in three of them through request.txt; AfterJoin serves those requests: "key ENTER" (A's
               touchdown, posted to the host game's window), "vmkey ENTER" (B's touchdown) and "vmkey whistle" (B's
               whistle key, through vm-key.ps1). The whistle key is the one the host driver reads from the game's
               input mapping (KEYMAP line), or -ScenarioArgs @{ WhistleKey = '<UE key name>' }.
               When the driver logs END, AfterJoin copies the recordings to dumps\<copy>\pair\<label>-wav\ (pair.ps1
               deletes the host's test mods before Check runs).
  Judging (ScenarioReport.Verdict): check.ps1 -Scenario pair-listen on the host log and those recordings: PASS, FAIL,
  or INCONCLUSIVE when the client's stock whistle isn't audible on the host at all (the two characters too far
  apart, no sound device, the game muted).
  Friends-only lobbies only (AGENTS.md "Networking"): pair.ps1's PairDriver creates them and stops the run if the
  flags ever say otherwise; AfterJoin checks the flags again while it serves requests. Nothing is sent to anyone: B
  whistles with its own key, and the host only reads whose character whistled.
  The request server takes only three fixed commands from the host driver's request.txt (a file in the host copy
  that this run wrote); anything else is ignored. The VM key is a UE key name checked by pair-lib's Get-VirtualKey.
.EXAMPLE
  # from the workspace's main checkout (no game running on the host; no WhistleMute in the host copy; VM lock taken):
  ./tools/vm/pair.ps1 -Scenario wm-listen -ScenarioFile mods/whistle-mute/test/pair/whistle-scenarios.ps1
  ./tools/vm/pair.ps1 -Scenario wm-listen -ScenarioFile mods/whistle-mute/test/pair/whistle-scenarios.ps1 -ScenarioArgs @{ WhistleKey = 'G' }
  # after an aborted run: both games closed, host and VM copies put back
  ./tools/vm/pair.ps1 -Stop -Scenario wm-listen -ScenarioFile mods/whistle-mute/test/pair/whistle-scenarios.ps1
#>

$script:WmRepo = Split-Path (Split-Path $PSScriptRoot)
$script:WmDriver = 'WhistleMuteDriver'
$script:WmCommands = @('key ENTER', 'vmkey ENTER', 'vmkey whistle')

# WhistleMute and its driver (scenario pair-listen) staged by this repo's deploy.ps1 -Staged into a fake copy: exactly
# what a host test deploy installs. Returns @{ Mod; Driver }.
function Get-WmStage {
    $stage = Join-Path ([IO.Path]::GetTempPath()) 'nn-whistle-stage'
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    $win64 = Join-Path $stage 'NuclearNightmare\Binaries\Win64'
    $mods = Join-Path $win64 'ue4ss\Mods'
    New-Item -ItemType Directory -Force $mods | Out-Null
    Set-Content (Join-Path $win64 'NuclearNightmare-Win64-Shipping.exe') 'stage'
    Set-Content (Join-Path $win64 'ue4ss\UE4SS.dll') 'stage'
    [IO.File]::WriteAllText((Join-Path $mods 'mods.txt'), "Keybinds : 1`r`n")
    $out = & pwsh -NoProfile -NonInteractive -File (Join-Path $WmRepo 'deploy.ps1') -Instance $stage -Test -Scenario pair-listen -Staged 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "WhistleMute's deploy.ps1 failed in the stage: $out" }
    @{ Mod = Join-Path $mods 'WhistleMute'; Driver = Join-Path $mods $WmDriver }
}

# "<seq> <command>" from the driver's request.txt -> @{ Seq; Cmd }, or $null for anything not on the whitelist.
function ConvertFrom-WmRequest([AllowNull()] [string] $Text) {
    if (-not $Text) { return $null }
    $t = $Text.Trim()
    if ($t.Length -gt 64 -or $t -notmatch '^(?<seq>\d{1,6}) (?<cmd>[a-z]+ [A-Za-z]+)$') { return $null }
    if ($WmCommands -cnotcontains $Matches.cmd) { return $null }
    [pscustomobject]@{ Seq = [int]$Matches.seq; Cmd = $Matches.cmd }
}

# The VM key for the whistle: -ScenarioArgs WhistleKey, else the first KEYMAP line of the host driver whose key
# vm-key.ps1 can post (pair-lib's Get-VirtualKey). $null when there is none.
function Get-WmWhistleKey([string[]] $Lines = @(), [AllowNull()] [string] $Override) {
    $cands = @()
    if ($Override) { $cands += $Override }
    foreach ($l in $Lines) {
        if ($l -match "\[$WmDriver\] KEYMAP \S+ action=\S*Whistle\S* key=(?<k>[A-Za-z0-9_]+)\s*$") { $cands += $Matches.k }
    }
    foreach ($k in $cands) {
        try { [void](Get-VirtualKey -KeyName $k); return $k } catch { if ($k -eq $Override) { Write-Warning "WhistleKey '$k': $_" } }
    }
    $null
}

# Enter to the host game's window (posted to its message queue, like run.ps1: no focus change, no global input).
function Send-WmHostEnter {
    if (-not ('WmPair.Win' -as [type])) {
        Add-Type -Namespace WmPair -Name Win -MemberDefinition '[DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr h, uint msg, System.IntPtr w, System.IntPtr l);'
    }
    $g = Get-HostCopyProcess | Select-Object -First 1
    $p = if ($g) { Get-Process -Id $g.ProcessId -ErrorAction SilentlyContinue }
    if (-not $p -or $p.MainWindowHandle -eq [IntPtr]::Zero) { Write-Warning 'Host Enter: no game window'; return $false }
    $down = [WmPair.Win]::PostMessage($p.MainWindowHandle, 0x0100, [IntPtr]0x0D, [IntPtr]0x001C0001)
    Start-Sleep -Milliseconds 80
    $up = [WmPair.Win]::PostMessage($p.MainWindowHandle, 0x0101, [IntPtr]0x0D, [IntPtr]([int64]0xC01C0001))
    $down -and $up
}

# Serves the host driver's requests until it logs END (or -TimeoutSec). Returns the served commands.
function Invoke-WmRequestServer([int] $TimeoutSec = 1200) {
    $scripts = Join-Path $modsDir "$WmDriver\Scripts"
    $req, $done = (Join-Path $scripts 'request.txt'), (Join-Path $scripts 'done.txt')
    $last, $served, $key, $nextFlags = 0, @(), $null, (Get-Date)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Find-HostLine "\[$WmDriver\] END result=") { break }
        if (-not (Get-HostCopyProcess)) { throw 'The host game exited.' }
        if ((Get-Date) -ge $nextFlags) { Assert-FriendsOnly; $nextFlags = (Get-Date).AddSeconds(2) }
        $text = if (Test-Path $req) { Get-Content $req -Raw -ErrorAction SilentlyContinue }
        $r = ConvertFrom-WmRequest $text
        if ($r -and $r.Seq -gt $last) {
            $last = $r.Seq
            switch ($r.Cmd) {
                'key ENTER' { [void](Send-WmHostEnter) }
                'vmkey ENTER' { [void](Send-VMKey 'Enter') }
                'vmkey whistle' {
                    if (-not $key) { $key = Get-WmWhistleKey -Lines (Get-HostLogLines) -Override $ScenarioArgs.WhistleKey }
                    if ($key) { [void](Send-VMKey $key) } else { Write-Warning 'No whistle key (no KEYMAP line from the host driver; pass -ScenarioArgs @{ WhistleKey = ''<key>'' }).' }
                }
            }
            $served += "$($r.Seq) $($r.Cmd)"
            Write-Host ("[{0:HH:mm:ss}] served {1} {2}{3}" -f (Get-Date), $r.Seq, $r.Cmd, $(if ($r.Cmd -eq 'vmkey whistle') { " ($key)" }))
            Set-Content $done $last -NoNewline
        }
        Start-Sleep -Milliseconds 250
    }
    $served
}

# The driver's recordings, copied out before pair.ps1 deletes the host's test mods. Returns the folder.
function Copy-WmRecordings {
    $src = Join-Path $modsDir "$WmDriver\Scripts"
    $dst = Join-Path $outDir "$Label-wav"
    New-Item -ItemType Directory -Force $dst | Out-Null
    Get-ChildItem $src -Filter 'whistle-*.wav' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^whistle-[a-z0-9]+\.wav$' } | Copy-Item -Destination $dst -Force
    $dst
}

# check.ps1's exit code and output -> PASS / FAIL / INCONCLUSIVE.
function Get-WmVerdict([int] $Code, [string] $Output) {
    if ($Code -eq 0) { return 'PASS' }
    if ($Output -match 'FAIL: INCONCLUSIVE') { return 'INCONCLUSIVE' }
    'FAIL'
}

$script:WmPairScenarios = @{
    'wm-listen' = @{
        Summary = 'WhistleMute: A (host) has WhistleMute, B (VM, vanilla) whistles with its own key; A records its audio output across B''s whistles: silent with the mod''s Volume 0, audible with the stock Volume (the control)'
        Prereq = {
            $own = @('WhistleMute', $WmDriver | Where-Object { Test-Path (Join-Path $modsDir $_) })
            if ($own.Count) { throw "wm-listen installs WhistleMute itself; the host copy already has $($own -join ', '). Remove it first: mods/whistle-mute/deploy.ps1 -Instance $inst -Remove" }
        }
        HostModPaths = { $s = Get-WmStage; @($s.Driver, $s.Mod) }
        VMSetup = { Restore-VMBaseline }
        VMRestore = { Restore-VMBaseline }
        AfterJoin = {
            $served = Invoke-WmRequestServer
            $script:WmServed = $served
            $script:LastAction = @{ Name = 'host driver END'; Time = Get-Date }
            $script:WmWavDir = Copy-WmRecordings
            Save-ShotAt -Seconds 1 -Name 'after' -Expect 'B in the lobby next to A, nothing unusual'
        }
        LobbyOnly = $true; LobbyMinutes = 6   # the whistle test happens in the lobby; pair.ps1 then passes without a match start
        Check = {
            if ($result -and -not $result.Joined) { return [ordered]@{ Verdict = 'FAIL'; Note = "not judged: B never joined (pair outcome: $($result.Outcome))" } }
            $log = Join-Path $outDir "$Label.host.UE4SS.log"
            $wavDir = Join-Path $outDir "$Label-wav"
            if (-not (Test-Path $log)) { return [ordered]@{ Verdict = 'FAIL'; Note = "no host log ($log)" } }
            $out = & pwsh -NoProfile -NonInteractive -File (Join-Path $WmRepo 'check.ps1') -Log $log -Scenario pair-listen -WavDir $wavDir 2>&1 | Out-String
            $lines = @($out -split "`r?`n")
            [ordered]@{
                Verdict = Get-WmVerdict $LASTEXITCODE $out
                Served = @($script:WmServed)
                Recordings = $wavDir
                Audio = @($lines | Where-Object { $_ -match 'audible|silent|still heard|INCONCLUSIVE|distance to the client' })
                Failures = @($lines | Where-Object { $_ -match '^FAIL' })
            }
        }
    }
}

# Into pair.ps1's table (it checks that no built-in scenario is replaced); a test may dot-source this file without it.
if ($script:PairScenarios -is [hashtable]) { foreach ($k in $WmPairScenarios.Keys) { $script:PairScenarios[$k] = $WmPairScenarios[$k] } }
