<#
.SYNOPSIS
  Pure helpers for deploy.ps1 (dot-source it), testable on their own (test/unit/deploy_test.ps1): mods.txt editing
  that keeps the file's bytes when nothing changes. Same rules as ImposterPanelFix's deploy-lib.ps1.
#>

# Edit-ModsTxt -Lines <mods.txt lines> -Remove <names> -Add <names in order> -> new lines.
# Drops every line of each name in -Remove and -Add (enabled or not), then inserts "<name> : 1" for each of -Add, in
# order, right above "Keybinds : 1" (AGENTS.md: never appended at the end), or at the end only when there is no
# Keybinds line at all. Other lines keep their order.
function Edit-ModsTxt {
    param(
        [AllowEmptyCollection()] [string[]] $Lines = @(),
        [string[]] $Remove = @(),
        [string[]] $Add = @()
    )
    $names = @($Remove) + @($Add) | Where-Object { $_ }
    $kept = [Collections.Generic.List[string]]::new()
    foreach ($l in $Lines) {
        $drop = $false
        foreach ($n in $names) { if ($l -match ('^\s*' + [regex]::Escape($n) + '\s*:')) { $drop = $true; break } }
        if (-not $drop) { $kept.Add($l) }
    }
    if (-not $Add) { return , $kept.ToArray() }
    $k = -1
    for ($i = 0; $i -lt $kept.Count; $i++) { if ($kept[$i] -match '^\s*Keybinds\s*:') { $k = $i; break } }
    $at = if ($k -ge 0) { $k } else { $kept.Count }
    $kept.InsertRange($at, [string[]]@($Add | ForEach-Object { "$_ : 1" }))
    return , $kept.ToArray()
}

# Read-ModsTxt <path> -> @{ Lines; Newline; Trailing; Bom }: the lines plus how the file ends them, so
# Write-ModsTxt writes back byte-identical text when the lines are unchanged.
function Read-ModsTxt {
    param([Parameter(Mandatory)] [string] $Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text = [Text.Encoding]::UTF8.GetString($bytes, $(if ($bom) { 3 } else { 0 }), $bytes.Length - $(if ($bom) { 3 } else { 0 }))
    $nl = if ($text -match "`r`n") { "`r`n" } else { "`n" }
    $trailing = $text.EndsWith("`n")
    $body = if ($trailing) { $text.Substring(0, $text.Length - $(if ($text.EndsWith("`r`n")) { 2 } else { 1 })) } else { $text }
    $lines = if ($body.Length) { [string[]]($body -split "`r?`n") } else { [string[]]@() }
    return @{ Lines = $lines; Newline = $nl; Trailing = $trailing; Bom = $bom }
}
function Write-ModsTxt {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] $File, [AllowEmptyCollection()] [string[]] $Lines = @())
    $text = ($Lines -join $File.Newline) + $(if ($File.Trailing -and $Lines.Count) { $File.Newline } else { '' })
    [IO.File]::WriteAllText($Path, $text, [Text.UTF8Encoding]::new([bool]$File.Bom))
}
