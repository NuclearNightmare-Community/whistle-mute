<#
.SYNOPSIS
  Unit tests for wav-lib.ps1 on synthetic recordings (wavgen.ps1): the reader's formats and refusals, the level
  measure, and Test-WhistleMuted's verdicts (pass, still heard, nothing audible).
.EXAMPLE
  pwsh -NoProfile -File test/unit/wav_test.ps1
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot)
. (Join-Path $repo 'wav-lib.ps1')
. (Join-Path $PSScriptRoot 'wavgen.ps1')
$script:passed = 0; $script:failed = 0
function Ok([bool] $cond, [string] $name, $detail) {
    if ($cond) { $script:passed++ } else { $script:failed++; Write-Host "FAIL $name$(if ($null -ne $detail) { " -- $detail" })" }
}
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("wm-wav-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $tmp | Out-Null
function P([string] $n) { Join-Path $tmp $n }
try {
    # The reader: every format the engine might write gives the same levels.
    $levels = @{}
    foreach ($k in 'pcm16', 'float32', 'pcm24', 'ext16') {
        New-TestWav (P "$k.wav") -Whistle 0.3 -Kind $k
        $l = Get-WavLevel (P "$k.wav")
        $levels[$k] = $l
        Ok ($l.Rate -eq 16000 -and $l.Channels -eq 2 -and [Math]::Abs($l.Seconds - 1.0) -lt 0.001) "reader $k`: rate, channels, length" "$($l.Rate) $($l.Channels) $($l.Seconds)"
    }
    foreach ($k in 'float32', 'pcm24', 'ext16') {
        Ok ([Math]::Abs($levels[$k].Hf / $levels.pcm16.Hf - 1) -lt 0.01) "reader $k`: same level as pcm16" "$($levels[$k].Hf) vs $($levels.pcm16.Hf)"
    }
    New-TestWav (P 'mono.wav') -Whistle 0.3 -Channels 1
    Ok ([Math]::Abs((Get-WavLevel (P 'mono.wav')).Hf / $levels.pcm16.Hf - 1) -lt 0.01) 'reader mono: same level as stereo'
    # Refusals: not a wave file, truncated, unsupported format.
    Set-Content (P 'text.wav') 'hello'
    try { Get-WavLevel (P 'text.wav') | Out-Null; Ok $false 'refuse: text' } catch { Ok ($_.Exception.Message -match 'not a RIFF/WAVE') 'refuse: text' $_.Exception.Message }
    $b = [IO.File]::ReadAllBytes((P 'pcm16.wav')); [IO.File]::WriteAllBytes((P 'short.wav'), $b[0..30])
    try { Get-WavLevel (P 'short.wav') | Out-Null; Ok $false 'refuse: truncated' } catch { Ok $true 'refuse: truncated' }
    $b = [IO.File]::ReadAllBytes((P 'pcm16.wav')); $b[42] = 8   # bits per sample 16 -> 8 (offset: 12 + JUNK 8 + fmt header 8 + 14)
    [IO.File]::WriteAllBytes((P 'pcm8.wav'), $b)
    try { Get-WavLevel (P 'pcm8.wav') | Out-Null; Ok $false 'refuse: 8-bit' } catch { Ok ($_.Exception.Message -match 'unsupported sample format') 'refuse: 8-bit' $_.Exception.Message }

    # The level: a whistle raises the high-frequency measure far more than a louder hum does.
    New-TestWav (P 'q.wav') -Seed 2
    New-TestWav (P 'qloud.wav') -Hum 0.6 -Seed 3
    $q, $ql, $w = (Get-WavLevel (P 'q.wav')), (Get-WavLevel (P 'qloud.wav')), $levels.pcm16
    Ok ($w.Hf -gt 100 * $q.Hf) 'level: a whistle stands far above the hum' "$($w.Hf) vs $($q.Hf)"
    Ok ($ql.Hf -lt 20 * $q.Hf) 'level: three times the hum is still small' "$($ql.Hf) vs $($q.Hf)"

    # The verdicts.
    New-TestWav (P 'q1.wav') -Seed 4; New-TestWav (P 'q2.wav') -Seed 5
    New-TestWav (P 'muted.wav') -Seed 6; New-TestWav (P 'loud.wav') -Whistle 0.3 -Seed 7
    $r = Test-WhistleMuted -Quiet1 (P 'q1.wav') -Quiet2 (P 'q2.wav') -Muted (P 'muted.wav') -Loud (P 'loud.wav')
    Ok ($r.Pass -and $r.Audible -and $r.Muted) 'verdict: silent with the mod, heard without -> pass' $r.Text
    Ok ($r.Text -match 'loud \+\d+\.\d dB over noise') 'verdict: the text gives the dB figures' $r.Text
    New-TestWav (P 'mutedHeard.wav') -Whistle 0.3 -Seed 8
    $r = Test-WhistleMuted -Quiet1 (P 'q1.wav') -Quiet2 (P 'q2.wav') -Muted (P 'mutedHeard.wav') -Loud (P 'loud.wav')
    Ok ($r.Audible -and -not $r.Muted -and -not $r.Pass) 'verdict: the whistle at full volume with the mod -> fail' $r.Text
    New-TestWav (P 'mutedHalf.wav') -Whistle 0.15 -Seed 9   # a quarter of the energy: -6 dB is not muted
    $r = Test-WhistleMuted -Quiet1 (P 'q1.wav') -Quiet2 (P 'q2.wav') -Muted (P 'mutedHalf.wav') -Loud (P 'loud.wav')
    Ok (-not $r.Pass) 'verdict: half the amplitude is not muted' $r.Text
    New-TestWav (P 'mutedFaint.wav') -Whistle 0.03 -Seed 10 # -20 dB: muted enough
    $r = Test-WhistleMuted -Quiet1 (P 'q1.wav') -Quiet2 (P 'q2.wav') -Muted (P 'mutedFaint.wav') -Loud (P 'loud.wav')
    Ok ($r.Pass) 'verdict: -20 dB counts as muted' $r.Text
    New-TestWav (P 'loudNone.wav') -Seed 11
    $r = Test-WhistleMuted -Quiet1 (P 'q1.wav') -Quiet2 (P 'q2.wav') -Muted (P 'muted.wav') -Loud (P 'loudNone.wav')
    Ok (-not $r.Audible -and -not $r.Pass) 'verdict: no stock whistle in the recording -> not audible, no pass' $r.Text
    New-TestWav (P 'silent.wav') -Hum 0 -Seed 12
    $r = Test-WhistleMuted -Quiet1 (P 'silent.wav') -Quiet2 (P 'silent.wav') -Muted (P 'silent.wav') -Loud (P 'silent.wav')
    Ok (-not $r.Pass) 'verdict: all silence proves nothing' $r.Text
    # A noisy quiet window (a gust in quiet2) raises the noise floor for both.
    New-TestWav (P 'q2loud.wav') -Whistle 0.05 -Seed 13
    $r = Test-WhistleMuted -Quiet1 (P 'q1.wav') -Quiet2 (P 'q2loud.wav') -Muted (P 'mutedFaint.wav') -Loud (P 'loud.wav')
    Ok ($r.Pass) 'verdict: the louder quiet window is the noise floor' $r.Text
} finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host "wav_test: $script:passed passed, $script:failed failed"
if ($script:failed) { exit 1 }
