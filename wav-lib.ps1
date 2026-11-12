<#
.SYNOPSIS
  Reads the test driver's recordings (.wav from AudioMixer's StopRecordingOutput) and judges whether the whistle was
  heard. Dot-source it (check.ps1 does); unit-tested on synthetic files (test/unit/wav_test.ps1).
.DESCRIPTION
  Each recording is reduced to one number: its loudest 50 ms frame of high-frequency energy (the mean square of the
  first difference of the mono mix). The first difference weights a sample by its frequency, so the game's wind and
  other low rumble count for little and a whistle (a high tone) for a lot; the loudest frame finds the whistle however
  short it is. Then:
    noise   = the louder of the two quiet windows (nobody whistled)
    audible = loud >= AudibleRatio x noise           (the stock whistle shows in the recording: the check can see it)
    muted   = muted - noise <= MutedShare x (loud - noise)  (with the mod, at most that share of the stock whistle's
                                                            energy above the noise is left; 0.1 = 10 dB quieter)
  Both must hold for a pass; when "audible" fails the run proves nothing (no sound device, game muted, ...).
#>

if (-not ('WhistleWav.Reader' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
namespace WhistleWav {
    public sealed class Wav { public int Rate; public int Channels; public int Bits; public int Format; public float[] Mono; }
    public static class Reader {
        // RIFF/WAVE with PCM 16/24/32-bit integer, 32-bit float, or WAVE_FORMAT_EXTENSIBLE wrapping either.
        public static Wav Read(string path) {
            byte[] b = File.ReadAllBytes(path);
            if (b.Length < 12 || b[0] != 'R' || b[1] != 'I' || b[2] != 'F' || b[3] != 'F' || b[8] != 'W' || b[9] != 'A' || b[10] != 'V' || b[11] != 'E')
                throw new InvalidDataException("not a RIFF/WAVE file");
            var w = new Wav(); int pos = 12, dataAt = -1, dataLen = 0; bool fmt = false;
            while (pos + 8 <= b.Length) {
                string id = System.Text.Encoding.ASCII.GetString(b, pos, 4);
                int len = BitConverter.ToInt32(b, pos + 4);
                if (len < 0) throw new InvalidDataException("bad chunk length");
                int body = pos + 8;
                if (id == "fmt ") {
                    if (len < 16 || body + 16 > b.Length) throw new InvalidDataException("short fmt chunk");
                    w.Format = BitConverter.ToUInt16(b, body); w.Channels = BitConverter.ToUInt16(b, body + 2);
                    w.Rate = BitConverter.ToInt32(b, body + 4); w.Bits = BitConverter.ToUInt16(b, body + 14);
                    if (w.Format == 0xFFFE && len >= 26 && body + 26 <= b.Length) w.Format = BitConverter.ToUInt16(b, body + 24);
                    fmt = true;
                } else if (id == "data") { dataAt = body; dataLen = Math.Min(len, b.Length - body); break; }
                pos = body + len + (len & 1);
            }
            if (!fmt) throw new InvalidDataException("no fmt chunk");
            if (dataAt < 0) throw new InvalidDataException("no data chunk");
            if (w.Channels < 1 || w.Channels > 16 || w.Rate < 1000 || w.Rate > 400000) throw new InvalidDataException("unsupported channels or rate");
            bool ok = (w.Format == 1 && (w.Bits == 16 || w.Bits == 24 || w.Bits == 32)) || (w.Format == 3 && w.Bits == 32);
            if (!ok) throw new InvalidDataException("unsupported sample format " + w.Format + "/" + w.Bits + " bit");
            int bps = w.Bits / 8, frame = bps * w.Channels, n = dataLen / frame;
            w.Mono = new float[n];
            for (int i = 0; i < n; i++) {
                double sum = 0;
                for (int c = 0; c < w.Channels; c++) {
                    int at = dataAt + i * frame + c * bps; double v;
                    if (w.Format == 3) v = BitConverter.ToSingle(b, at);
                    else if (w.Bits == 16) v = BitConverter.ToInt16(b, at) / 32768.0;
                    else if (w.Bits == 24) v = ((b[at] | (b[at + 1] << 8) | ((sbyte)b[at + 2] << 16))) / 8388608.0;
                    else v = BitConverter.ToInt32(b, at) / 2147483648.0;
                    sum += v;
                }
                w.Mono[i] = (float)(sum / w.Channels);
            }
            return w;
        }
        // The loudest frameMs window's mean square of the first difference (and of the signal itself).
        public static double[] LoudestFrame(float[] x, int rate, int frameMs) {
            int f = Math.Max(1, rate * frameMs / 1000); double bestHf = 0, bestRaw = 0;
            for (int s = 0; s < x.Length; s += f) {
                int end = Math.Min(x.Length, s + f); double hf = 0, raw = 0; int k = 0;
                for (int i = Math.Max(s, 1); i < end; i++) { double d = x[i] - x[i - 1]; hf += d * d; raw += x[i] * (double)x[i]; k++; }
                if (k > 0) { hf /= k; raw /= k; }
                if (hf > bestHf) bestHf = hf;
                if (raw > bestRaw) bestRaw = raw;
            }
            return new double[] { bestHf, bestRaw };
        }
    }
}
'@
}

# Get-WavLevel <path> -> @{ Hf; Raw; Seconds; Rate; Channels } (Hf and Raw: the loudest 50 ms frame's mean squares).
function Get-WavLevel {
    param([Parameter(Mandatory)] [string] $Path, [int] $FrameMs = 50)
    $w = [WhistleWav.Reader]::Read((Resolve-Path -LiteralPath $Path).Path)
    $m = [WhistleWav.Reader]::LoudestFrame($w.Mono, $w.Rate, $FrameMs)
    [pscustomobject]@{ Hf = $m[0]; Raw = $m[1]; Seconds = $w.Mono.Length / $w.Rate; Rate = $w.Rate; Channels = $w.Channels }
}

# dB of an energy ratio, for the report; -inf/inf spelled out.
function Format-Db([double] $num, [double] $den) {
    if ($den -le 0 -and $num -le 0) { return 'n/a' }
    if ($den -le 0) { return '+inf dB' }
    if ($num -le 0) { return '-inf dB' }
    return ('{0:+0.0;-0.0} dB' -f (10 * [Math]::Log10($num / $den)))
}

# Test-WhistleMuted -Quiet1 <wav> -Quiet2 <wav> -Muted <wav> -Loud <wav> -> @{ Audible; Muted; Pass; Text }.
function Test-WhistleMuted {
    param(
        [Parameter(Mandatory)] [string] $Quiet1, [Parameter(Mandatory)] [string] $Quiet2,
        [Parameter(Mandatory)] [string] $Muted, [Parameter(Mandatory)] [string] $Loud,
        [double] $AudibleRatio = 4.0, [double] $MutedShare = 0.1, [double] $MinEnergy = 1e-9
    )
    $q1, $q2, $mu, $lo = (Get-WavLevel $Quiet1), (Get-WavLevel $Quiet2), (Get-WavLevel $Muted), (Get-WavLevel $Loud)
    $noise = [Math]::Max($q1.Hf, $q2.Hf)
    $audible = $lo.Hf -ge $AudibleRatio * $noise -and $lo.Hf -gt $MinEnergy
    $loudEx = $lo.Hf - $noise
    $mutedEx = [Math]::Max(0.0, $mu.Hf - $noise)
    $isMuted = $audible -and $mutedEx -le $MutedShare * $loudEx
    $text = ("loud {0} over noise, muted {1} over noise (whistle left: {2} of stock); hf energy quiet1={3:E2} quiet2={4:E2} muted={5:E2} loud={6:E2}" -f
        (Format-Db $lo.Hf $noise), (Format-Db $mu.Hf $noise), (Format-Db $mutedEx $loudEx), $q1.Hf, $q2.Hf, $mu.Hf, $lo.Hf)
    [pscustomobject]@{ Audible = $audible; Muted = $isMuted; Pass = $audible -and $isMuted; Text = $text }
}
