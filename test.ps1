<#
.SYNOPSIS
  Runs WhistleMute's unit tests, no game needed: the Lua tests (mute.lua's logic against a fake game, main.lua's glue
  against fake UE4SS globals, the test driver's load test) and the PowerShell tests (wav-lib.ps1 on synthetic
  recordings, deploy-lib.ps1 and deploy.ps1 against a fake instance, check.ps1 against synthetic logs and recordings,
  run.ps1's run guard). check.ps1 -Scenario unit runs this too.
  Lua: the first of lua, lua5.4, lua54, lua5.3, texlua (MiKTeX's texlua.exe is Lua 5.3) found on PATH; -Lua picks one.
.EXAMPLE
  ./test.ps1
  ./test.ps1 -Only lua
#>
param([string] $Lua, [ValidateSet('all', 'lua', 'ps')] [string] $Only = 'all')
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
if (-not $Lua) { $Lua = @('lua', 'lua5.4', 'lua54', 'lua5.3', 'texlua') | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1 }
$failed = @()
Push-Location $here
try {
    if ($Only -in 'all', 'lua') {
        if (-not $Lua) { Write-Host 'FAIL: no Lua 5.3/5.4 interpreter on PATH (lua, texlua, ...); pass -Lua'; $failed += 'lua' }
        else {
            foreach ($t in 'mute_test', 'main_test', 'driver_test') {
                # texlua prints a MiKTeX update reminder on stderr; only the test's own output matters.
                $out = & $Lua "test/unit/$t.lua" 2>$null
                $code = $LASTEXITCODE
                $out | ForEach-Object { Write-Host $_ }
                if ($code -ne 0) { $failed += $t }
            }
        }
    }
    if ($Only -in 'all', 'ps') {
        foreach ($t in 'wav_test', 'deploy_test', 'check_test', 'run_guard_test') {
            & pwsh -NoProfile -NonInteractive -File "test/unit/$t.ps1"
            if ($LASTEXITCODE -ne 0) { $failed += $t }
        }
    }
} finally { Pop-Location }
if ($failed) { Write-Host "Unit tests failed: $($failed -join ', ')"; exit 1 }
Write-Host 'All unit tests passed.'
