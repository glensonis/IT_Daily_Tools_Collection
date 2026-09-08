<#
.SYNOPSIS
    Windows-only smoke test: build the Map Network Drive window without showing it.

.DESCRIPTION
    The logic tests in Run-Tests.ps1 deliberately skip the WinForms code so they
    can run anywhere. This covers the gap by constructing every control for real,
    which is where typos in property names and bad enum values surface. The window
    is never shown, so it works on a headless CI runner.

.EXAMPLE
    pwsh -NoProfile -File .\tests\Test-UiBuild.ps1
#>

[CmdletBinding()]
param(
    # Fail instead of skipping when not on Windows. CI passes this so a runner
    # that somehow reports the wrong OS cannot turn a skipped test into a pass.
    [switch] $RequireWindows
)

$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    if ($RequireWindows) {
        Write-Host 'FAIL  -RequireWindows was set but this is not Windows' -ForegroundColor Red
        exit 1
    }
    Write-Host 'SKIP  not Windows, WinForms unavailable'
    exit 0
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$toolPath = Join-Path $repoRoot 'tools/Map-NetworkDrive/Map-NetworkDrive.ps1'

Write-Host 'Building the Map Network Drive window (not shown) ...'

try {
    $output = & $toolPath -Mode BuildOnly
} catch {
    Write-Host "FAIL  the window could not be built: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    exit 1
}

$text = ($output | Out-String).Trim()
Write-Host "  tool reported: $text"

if ($text -notmatch 'Built (\d+) controls') {
    Write-Host 'FAIL  the tool did not report a built window' -ForegroundColor Red
    exit 1
}

$count = [int]$Matches[1]
if ($count -lt 10) {
    Write-Host "FAIL  only $count controls were built, expected the full form" -ForegroundColor Red
    exit 1
}

Write-Host "OK: window built with $count controls" -ForegroundColor Green
exit 0
