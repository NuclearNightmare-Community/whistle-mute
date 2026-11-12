<#
.SYNOPSIS
  Test helper (dot-source it): writes synthetic .wav files like the driver's recordings, for wav_test.ps1 and
  check_test.ps1. A low hum plus a little noise ("the game's wind"), and optionally a whistle (a high tone).
#>
function New-TestWav {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [double] $Whistle = 0.0,          # the whistle tone's amplitude (0: none)
        [double] $Hum = 0.2,              # the low hum's amplitude
        [int] $Rate = 16000, [double] $Seconds = 1.0, [int] $Channels = 2,
        [ValidateSet('pcm16', 'float32', 'pcm24', 'ext16')] [string] $Kind = 'pcm16',
        [int] $Seed = 1
    )
    $rng = [Random]::new($Seed)
    $n = [int]($Rate * $Seconds)
    $bits = switch ($Kind) { 'float32' { 32 } 'pcm24' { 24 } default { 16 } }
    $fmt = switch ($Kind) { 'float32' { 3 } 'ext16' { 0xFFFE } default { 1 } }
    $bps = $bits / 8
    $ms = [IO.MemoryStream]::new(); $bw = [IO.BinaryWriter]::new($ms)
    for ($i = 0; $i -lt $n; $i++) {
        $t = $i / $Rate
        $v = $Hum * [Math]::Sin(2 * [Math]::PI * 60 * $t) + 0.002 * ($rng.NextDouble() - 0.5)
        if ($Whistle -gt 0 -and $t -ge 0.3 -and $t -lt 0.6) { $v += $Whistle * [Math]::Sin(2 * [Math]::PI * 2000 * $t) }
        for ($c = 0; $c -lt $Channels; $c++) {
            switch ($bits) {
                32 { $bw.Write([single]$v) }
                24 { $x = [int][Math]::Round($v * 8388607); $bw.Write([byte]($x -band 0xFF)); $bw.Write([byte](($x -shr 8) -band 0xFF)); $bw.Write([byte](($x -shr 16) -band 0xFF)) }
                default { $bw.Write([int16][Math]::Round($v * 32767)) }
            }
        }
    }
    $data = $ms.ToArray()
    $out = [IO.MemoryStream]::new(); $w = [IO.BinaryWriter]::new($out)
    $fmtLen = if ($fmt -eq 0xFFFE) { 40 } else { 16 }
    $w.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $w.Write([int](4 + 8 + $fmtLen + 8 + 8 + $data.Length))
    $w.Write([Text.Encoding]::ASCII.GetBytes('WAVE'))
    # A chunk before fmt that a reader must skip.
    $w.Write([Text.Encoding]::ASCII.GetBytes('JUNK')); $w.Write([int]0)
    $w.Write([Text.Encoding]::ASCII.GetBytes('fmt ')); $w.Write([int]$fmtLen)
    $w.Write([uint16]$fmt); $w.Write([uint16]$Channels); $w.Write([int]$Rate); $w.Write([int]($Rate * $Channels * $bps))
    $w.Write([uint16]($Channels * $bps)); $w.Write([uint16]$bits)
    if ($fmt -eq 0xFFFE) { $w.Write([uint16]22); $w.Write([uint16]$bits); $w.Write([int]3); $w.Write([uint16]1); $w.Write([byte[]]::new(14)) }
    $w.Write([Text.Encoding]::ASCII.GetBytes('data')); $w.Write([int]$data.Length); $w.Write($data)
    [IO.File]::WriteAllBytes($Path, $out.ToArray())
}
