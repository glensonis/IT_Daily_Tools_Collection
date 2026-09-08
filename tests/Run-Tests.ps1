<#
.SYNOPSIS
    Syntax check and logic tests for Daily IT Tools. Runs on Windows or Linux.

.DESCRIPTION
    Dot-sources each tool with -Mode FunctionsOnly, so the pure logic is tested
    without opening a window. Exits non-zero on the first failing assertion set,
    which is what CI keys off.

.EXAMPLE
    pwsh -NoProfile -File .\tests\Run-Tests.ps1
#>

# $AppDataDir and $RecentPath below are read by the functions dot-sourced from
# Map-NetworkDrive.ps1, which resolve them through the parent scope at call
# time. PSScriptAnalyzer only tracks reads within this file, so it reports them
# as write-only. Suppressed so any future warning from this file is real.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'AppDataDir',
    Justification = 'Read by the dot-sourced tool functions through scope, not visible to the analyzer.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'RecentPath',
    Justification = 'Read by the dot-sourced tool functions through scope, not visible to the analyzer.')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot  = Split-Path -Parent $PSScriptRoot
$toolPath  = Join-Path $repoRoot 'tools/Map-NetworkDrive/Map-NetworkDrive.ps1'
$installer = Join-Path $repoRoot 'Install-DesktopShortcut.ps1'

$script:Passed = 0
$script:Failed = 0

function Assert-Equal {
    param([string] $Name, $Actual, $Expected)

    if ("$Actual" -eq "$Expected") {
        $script:Passed++
        Write-Host "  PASS  $Name"
    } else {
        $script:Failed++
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        Write-Host "        actual:   [$Actual]" -ForegroundColor Red
        Write-Host "        expected: [$Expected]" -ForegroundColor Red
    }
}

function Test-Section { param([string] $Name) Write-Host "`n$Name" -ForegroundColor Cyan }

# ==========================================================================
Test-Section 'Syntax'
# ==========================================================================

foreach ($file in @($toolPath, $installer, $PSCommandPath)) {
    $errors = $null
    $tokens = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors -and $errors.Count -gt 0) {
        $script:Failed++
        Write-Host "  FAIL  parse $(Split-Path -Leaf $file)" -ForegroundColor Red
        $errors | ForEach-Object { Write-Host "        line $($_.Extent.StartLineNumber): $($_.Message)" -ForegroundColor Red }
    } else {
        $script:Passed++
        Write-Host "  PASS  parse $(Split-Path -Leaf $file)"
    }
}

# Load the tool's functions without touching WinForms.
. $toolPath -Mode FunctionsOnly

# Point per-user state at a throwaway folder so the tests never touch real data.
$sandbox     = Join-Path ([System.IO.Path]::GetTempPath()) ("dit-tests-" + [guid]::NewGuid().ToString('N'))
$AppDataDir  = $sandbox
$RecentPath  = Join-Path $sandbox 'recent.json'

try {

# ==========================================================================
Test-Section 'Test-UncPath'
# ==========================================================================

Assert-Equal 'valid share'         (Test-UncPath '\\fileserver\accounts')  $true
Assert-Equal 'valid nested path'   (Test-UncPath '\\srv\share\sub folder') $true
Assert-Equal 'valid fqdn'          (Test-UncPath '\\srv.corp.local\data')  $true
Assert-Equal 'server with no share'(Test-UncPath '\\fileserver')           $false
Assert-Equal 'local drive path'    (Test-UncPath 'C:\temp')                $false
Assert-Equal 'single backslash'    (Test-UncPath '\fileserver\share')      $false
Assert-Equal 'empty string'        (Test-UncPath '')                       $false
Assert-Equal 'forward slashes'     (Test-UncPath '//srv/share')            $false

# ==========================================================================
Test-Section 'Get-ServerName'
# ==========================================================================

Assert-Equal 'plain host'  (Get-ServerName '\\fileserver\accounts')   'fileserver'
Assert-Equal 'fqdn host'   (Get-ServerName '\\srv.corp.local\data\x') 'srv.corp.local'
Assert-Equal 'no match'    (Get-ServerName 'C:\temp')                 ''

# ==========================================================================
Test-Section 'ConvertTo-Argument (Windows command-line quoting)'
# ==========================================================================

Assert-Equal 'plain word'        (ConvertTo-Argument 'hello')          '"hello"'
Assert-Equal 'path with space'   (ConvertTo-Argument '\\srv\my share') '"\\srv\my share"'
Assert-Equal 'embedded quote'    (ConvertTo-Argument 'pa"ss')          '"pa\"ss"'
Assert-Equal 'trailing backslash'(ConvertTo-Argument 'pass\')          '"pass\\"'
Assert-Equal 'empty value'       (ConvertTo-Argument '')               '""'

# ==========================================================================
Test-Section 'Resolve-NetError'
# ==========================================================================

Assert-Equal 'bad password (1326)'  ((Resolve-NetError 'System error 1326 has occurred.') -like 'Wrong username or password*1326)') $true
Assert-Equal 'path not found (53)'  ((Resolve-NetError 'System error 53 has occurred.')   -like 'Network path not found*')          $true
Assert-Equal 'access denied (5)'    ((Resolve-NetError 'System error 5 has occurred.')    -like 'Access denied*')                   $true
Assert-Equal 'share not found (67)' ((Resolve-NetError 'System error 67 has occurred.')   -like 'Share not found*')                 $true
Assert-Equal 'unmapped code kept'   ((Resolve-NetError 'System error 9999 has occurred.') -like 'Windows error 9999*')              $true
Assert-Equal 'raw text passthrough' (Resolve-NetError 'Something odd')                    'Something odd'
Assert-Equal 'no output at all'     (Resolve-NetError '')                                 'The command failed but Windows returned no message.'

# ==========================================================================
Test-Section 'settings.sample.json'
# ==========================================================================

$settings = Get-Settings
Assert-Equal 'sample parses'          ($null -ne $settings)                  $true
Assert-Equal 'default drive letter'   $settings.defaultDriveLetter           'Z'
Assert-Equal 'preset count'           $settings.presets.Count                2
Assert-Equal 'preset path unescaped'  $settings.presets[0].path              '\\fileserver\accounts'
Assert-Equal 'preset path is valid'   (Test-UncPath $settings.presets[0].path) $true
Assert-Equal 'sample holds no password' ($settings.PSObject.Properties.Name -contains 'password') $false

# ==========================================================================
Test-Section 'Merge-Settings'
# ==========================================================================

# Regression: a plain "-ne ''" test treats $false as empty, which silently
# dropped "defaultPersistent": false from a user's settings file.
$merged = Merge-Settings -Base (Get-DefaultSettings) -Override ([pscustomobject]@{
    defaultPersistent     = $false
    openExplorerOnSuccess = $false
})
Assert-Equal 'false persistent honoured' $merged.defaultPersistent     $false
Assert-Equal 'false explorer honoured'   $merged.openExplorerOnSuccess $false

$blank = Merge-Settings -Base (Get-DefaultSettings) -Override ([pscustomobject]@{ defaultUsername = '   ' })
Assert-Equal 'whitespace override ignored' $blank.defaultUsername ''

$over = Merge-Settings -Base (Get-DefaultSettings) -Override ([pscustomobject]@{ defaultDriveLetter = 'S' })
Assert-Equal 'real override applied'       $over.defaultDriveLetter 'S'
Assert-Equal 'untouched key survives'      $over.saveCredential     $true

# ==========================================================================
Test-Section 'Recent paths cache'
# ==========================================================================

Add-RecentPath -Path '\\srv1\a'
Add-RecentPath -Path '\\srv2\b'
Add-RecentPath -Path '\\srv1\a'
$recent = @(Get-RecentPaths)
Assert-Equal 'most recent first' $recent[0]     '\\srv1\a'
Assert-Equal 'deduplicated'      $recent.Count  2

1..15 | ForEach-Object { Add-RecentPath -Path "\\srv\s$_" }
Assert-Equal 'capped at 10' (@(Get-RecentPaths)).Count 10

# ==========================================================================
Test-Section 'net.exe / cmdkey.exe argument construction'
# ==========================================================================

# Stub the process launcher so the arguments can be inspected without running
# anything. This is the whole point of routing through Invoke-Console.
function Invoke-Console {
    param($FilePath, $Arguments)
    # $FilePath is captured so the stub matches the real signature; only the
    # argument string is under test here.
    [pscustomobject]@{ ExitCode = 0; Output = $Arguments; FilePath = $FilePath }
}

Assert-Equal 'map with credentials' `
    (New-Mapping -Letter 'Z' -Path '\\srv\my share' -UserName 'CORP\js' -Password 'p@ss w' -Persistent $true).Output `
    'use Z: "\\srv\my share" /user:"CORP\js" "p@ss w" /persistent:yes'

Assert-Equal 'map without credentials' `
    (New-Mapping -Letter 'S' -Path '\\srv\pub' -UserName '' -Password '' -Persistent $false).Output `
    'use S: "\\srv\pub" /persistent:no'

Assert-Equal 'disconnect' (Remove-Mapping -Letter 'Z').Output 'use Z: /delete /y'

Assert-Equal 'save credential' `
    (Save-ServerCredential -Server 'srv' -UserName 'CORP\js' -Password 'pw').Output `
    '/add:"srv" /user:"CORP\js" /pass:"pw"'

Assert-Equal 'credential skipped with no user' (Save-ServerCredential -Server 'srv' -UserName '' -Password 'pw') ''

# ==========================================================================
Test-Section 'Drive letter list'
# ==========================================================================

# Stub the drive enumeration so the result is identical on every OS.
function Get-UsedDriveLetters { @{ 'C' = 'Fixed'; 'Z' = 'Network' } }

$items = Get-DriveLetterItems
Assert-Equal 'covers D through Z'   $items.Count 23
Assert-Equal 'items are strings'    (@($items | Where-Object { $_ -isnot [string] }).Count) 0
Assert-Equal 'first entry is D'     $items[0]  'D:  (available)'
Assert-Equal 'Z shown as in use'    $items[-1] 'Z:  (in use - Network)'
Assert-Equal 'C never offered'      (@($items | Where-Object { $_ -like 'C:*' }).Count) 0
Assert-Equal 'Z flagged in use'     (Test-LetterInUse 'Z') $true
Assert-Equal 'D not flagged'        (Test-LetterInUse 'D') $false

Assert-Equal 'letter parsed back' (Get-SelectedLetter ([pscustomobject]@{ SelectedItem = 'Z:  (in use - Network)' })) 'Z'
Assert-Equal 'empty selection safe' (Get-SelectedLetter ([pscustomobject]@{ SelectedItem = $null }))                  ''

} finally {
    if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }
}

# ==========================================================================
Write-Host ''
if ($script:Failed -gt 0) {
    Write-Host "FAILED: $($script:Failed) failed, $($script:Passed) passed" -ForegroundColor Red
    exit 1
}
Write-Host "OK: all $($script:Passed) checks passed" -ForegroundColor Green
exit 0
