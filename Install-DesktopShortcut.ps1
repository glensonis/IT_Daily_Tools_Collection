<#
.SYNOPSIS
    Put a Desktop shortcut on this PC for each Daily IT Tools launcher.

.DESCRIPTION
    Creates one .lnk per tool launcher (*.bat under .\tools) on the current
    user's Desktop, pointing back at this folder. Nothing is copied and
    nothing is installed system-wide, so moving this folder means running
    the script again.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-DesktopShortcut.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-DesktopShortcut.ps1 -Remove
#>

[CmdletBinding()]
param(
    # Remove the shortcuts instead of creating them.
    [switch] $Remove
)

$ErrorActionPreference = 'Stop'

$root      = Split-Path -Parent $MyInvocation.MyCommand.Definition
$toolsDir  = Join-Path $root 'tools'
$desktop   = [Environment]::GetFolderPath('Desktop')

if (-not (Test-Path -LiteralPath $toolsDir)) {
    Write-Error "No tools folder found at $toolsDir"
    return
}

$launchers = @(Get-ChildItem -LiteralPath $toolsDir -Filter '*.bat' -Recurse -File)
if ($launchers.Count -eq 0) {
    Write-Warning "No .bat launchers found under $toolsDir"
    return
}

$shell = New-Object -ComObject WScript.Shell

foreach ($launcher in $launchers) {
    $name         = [System.IO.Path]::GetFileNameWithoutExtension($launcher.Name)
    $shortcutPath = Join-Path $desktop "$name.lnk"

    if ($Remove) {
        if (Test-Path -LiteralPath $shortcutPath) {
            Remove-Item -LiteralPath $shortcutPath -Force
            Write-Host "Removed  $shortcutPath"
        } else {
            Write-Host "Skipped  $shortcutPath (not present)"
        }
        continue
    }

    $shortcut                  = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath       = $launcher.FullName
    $shortcut.WorkingDirectory = $launcher.DirectoryName
    $shortcut.Description      = "Daily IT Tools - $name"
    $shortcut.IconLocation     = "$env:SystemRoot\System32\imageres.dll,28"
    $shortcut.Save()

    Write-Host "Created  $shortcutPath"
}

if (-not $Remove) {
    Write-Host ''
    Write-Host "Done. $($launchers.Count) shortcut(s) on your Desktop."
}
