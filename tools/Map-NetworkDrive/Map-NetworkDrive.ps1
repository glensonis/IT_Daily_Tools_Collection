<#
.SYNOPSIS
    Map any \\server\share to any drive letter, with a clear credential prompt.

.DESCRIPTION
    Generic Windows network drive mapper with an always-on-top WinForms window.
    Nothing in this script is tied to one server or one drive letter. Server
    names only ever come from a settings file, never from the code.

    Settings are read from, in order (later wins):
      1. <script folder>\settings.sample.json   (checked in, safe defaults)
      2. <script folder>\settings.json          (local, git-ignored)
      3. %APPDATA%\Daily_IT_Tools\Map-NetworkDrive\settings.json

    Recently used UNC paths are cached in
      %APPDATA%\Daily_IT_Tools\Map-NetworkDrive\recent.json

    No password is ever written to disk by this script.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# --------------------------------------------------------------------------
# Paths
# --------------------------------------------------------------------------

$ScriptDir          = Split-Path -Parent $MyInvocation.MyCommand.Definition
$SampleSettingsPath = Join-Path $ScriptDir 'settings.sample.json'
$LocalSettingsPath  = Join-Path $ScriptDir 'settings.json'
$AppDataDir         = Join-Path $env:APPDATA 'Daily_IT_Tools\Map-NetworkDrive'
$UserSettingsPath   = Join-Path $AppDataDir 'settings.json'
$RecentPath         = Join-Path $AppDataDir 'recent.json'
$NetExe             = Join-Path $env:SystemRoot 'System32\net.exe'
$CmdKeyExe          = Join-Path $env:SystemRoot 'System32\cmdkey.exe'

# --------------------------------------------------------------------------
# Settings
# --------------------------------------------------------------------------

function Get-DefaultSettings {
    [pscustomobject]@{
        defaultDriveLetter    = 'Z'
        defaultUsername       = ''
        defaultPersistent     = $true
        openExplorerOnSuccess = $true
        saveCredential        = $true
        presets               = @()
    }
}

function Read-JsonFile {
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not read settings file:`r`n$Path`r`n`r`n$($_.Exception.Message)`r`n`r`nDefaults will be used.",
            'Daily IT Tools',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return $null
    }
}

function Merge-Settings {
    param($Base, $Override)

    if ($null -eq $Override) { return $Base }
    foreach ($prop in $Override.PSObject.Properties) {
        $isEmptyString = ($prop.Value -is [string]) -and [string]::IsNullOrWhiteSpace($prop.Value)
        if ($null -ne $prop.Value -and -not $isEmptyString) {
            $Base | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $prop.Value -Force
        }
    }
    return $Base
}

function Get-Settings {
    $settings = Get-DefaultSettings
    foreach ($path in @($SampleSettingsPath, $LocalSettingsPath, $UserSettingsPath)) {
        $settings = Merge-Settings -Base $settings -Override (Read-JsonFile -Path $path)
    }
    return $settings
}

# --------------------------------------------------------------------------
# Recent paths (per-user, outside the repo)
# --------------------------------------------------------------------------

function Get-RecentPaths {
    $data = Read-JsonFile -Path $RecentPath
    if ($null -eq $data) { return @() }
    return @($data | Where-Object { $_ -is [string] -and $_.Trim() })
}

function Add-RecentPath {
    param([string] $Path)

    try {
        if (-not (Test-Path -LiteralPath $AppDataDir)) {
            New-Item -ItemType Directory -Path $AppDataDir -Force | Out-Null
        }
        $list = @($Path) + @(Get-RecentPaths | Where-Object { $_ -ne $Path })
        $list = @($list | Select-Object -First 10)
        ($list | ConvertTo-Json) | Set-Content -LiteralPath $RecentPath -Encoding UTF8
    } catch {
        # A missing MRU cache is never worth failing the mapping over.
    }
}

# --------------------------------------------------------------------------
# Drive letters
# --------------------------------------------------------------------------

function Get-UsedDriveLetters {
    $used = @{}
    try {
        foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
            $used[$d.Name.Substring(0, 1).ToUpper()] = $d.DriveType.ToString()
        }
    } catch { }
    return $used
}

# The combo box holds plain strings on purpose. ComboBox.DisplayMember resolves
# properties through TypeDescriptor, which cannot see PSCustomObject properties,
# so binding objects here would show type names instead of the drive letters.
# $script:LetterInUse carries the "is it taken" flag alongside, keyed by letter.
$script:LetterInUse = @{}

function Get-DriveLetterItems {
    $used = Get-UsedDriveLetters
    $script:LetterInUse = @{}
    $items = @()
    foreach ($c in [char[]]([char]'D'..[char]'Z')) {
        $letter = [string]$c
        if ($used.ContainsKey($letter)) {
            $script:LetterInUse[$letter] = $true
            $items += "$letter`:  (in use - $($used[$letter]))"
        } else {
            $script:LetterInUse[$letter] = $false
            $items += "$letter`:  (available)"
        }
    }
    return $items
}

function Get-SelectedLetter {
    param($ComboBox)
    $text = [string]$ComboBox.SelectedItem
    if ([string]::IsNullOrWhiteSpace($text)) { return '' }
    return $text.Substring(0, 1).ToUpper()
}

function Test-LetterInUse {
    param([string] $Letter)
    return [bool]$script:LetterInUse[$Letter]
}

# --------------------------------------------------------------------------
# UNC validation
# --------------------------------------------------------------------------

function Test-UncPath {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return $Path -match '^\\\\[^\\/:*?"<>|]+\\[^/:*?"<>|]+'
}

function Get-ServerName {
    param([string] $Path)
    if ($Path -match '^\\\\([^\\/:*?"<>|]+)\\') { return $Matches[1] }
    return ''
}

function Test-ServerReachable {
    param([string] $Server, [int] $TimeoutMs = 3000)

    if ([string]::IsNullOrWhiteSpace($Server)) { return $false }
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $async  = $client.BeginConnect($Server, 445, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        if ($client) { $client.Close() }
    }
}

# --------------------------------------------------------------------------
# Running net.exe / cmdkey.exe without going through cmd.exe
# --------------------------------------------------------------------------

function ConvertTo-Argument {
    param([string] $Value)

    if ($null -eq $Value) { $Value = '' }
    # Escape per the Windows command-line parsing rules: backslashes only need
    # doubling when they immediately precede a quote we are adding or escaping.
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Invoke-Console {
    param([string] $FilePath, [string] $Arguments)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $FilePath
    $psi.Arguments              = $Arguments
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $out  = $proc.StandardOutput.ReadToEnd()
    $err  = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    [pscustomobject]@{
        ExitCode = $proc.ExitCode
        Output   = (($out + "`r`n" + $err).Trim())
    }
}

# --------------------------------------------------------------------------
# Plain-English errors
# --------------------------------------------------------------------------

$script:NetErrorMap = @{
    3    = 'The folder was not found on that share. Check the part of the path after the share name.'
    5    = 'Access denied. The sign-in worked but this account is not allowed on that share. Ask IT to grant permission.'
    51   = 'The server is not responding. Check that it is switched on and that you are on the office network or VPN.'
    53   = 'Network path not found. Check the spelling of the server name in \\server\share, and that you are on the office network or VPN.'
    55   = 'That share no longer exists on the server. Check the share name (the part after \\server\).'
    64   = 'The network name is no longer available. The server may have restarted, or the share was removed.'
    65   = 'The server refused network access for this account.'
    67   = 'Share not found. The server answered, but it has no share with that name.'
    71   = 'The server has reached its connection limit. Try again in a few minutes.'
    85   = 'That drive letter is already in use. Pick another letter, or let the tool replace the existing mapping.'
    86   = 'The password is not correct for this share.'
    1203 = 'Windows could not route that path. Check it starts with \\ and that the network is up.'
    1219 = 'You are already connected to this server as a different user. Disconnect the other mapping to this server first (or sign out and back in).'
    1312 = 'The logon session no longer exists. Sign out of Windows and back in, then try again.'
    1326 = 'Wrong username or password. Try DOMAIN\username or username@domain, and retype the password.'
    1327 = 'Account restriction. The password may be blank, expired, or sign-in is not allowed at this time.'
    1330 = 'The password has expired. Change your Windows password, then try again.'
    1331 = 'The account is disabled. Ask IT to enable it.'
    1909 = 'The account is locked out. Wait for the lockout to clear, or ask IT to unlock it.'
    2202 = 'The user name is not valid for this computer.'
    2250 = 'That drive letter is not currently mapped, so there is nothing to disconnect.'
}

function Resolve-NetError {
    param([string] $Output)

    if ($Output -match 'System error (\d+)') {
        $code = [int]$Matches[1]
        if ($script:NetErrorMap.ContainsKey($code)) {
            return "$($script:NetErrorMap[$code])  (Windows error $code)"
        }
        return "Windows error $code. Raw message:`r`n$Output"
    }
    if ($Output -match 'Error (\d+)') {
        $code = [int]$Matches[1]
        if ($script:NetErrorMap.ContainsKey($code)) {
            return "$($script:NetErrorMap[$code])  (Windows error $code)"
        }
    }
    if ($Output -match 'password is invalid|logon failure') {
        return $script:NetErrorMap[1326]
    }
    if ([string]::IsNullOrWhiteSpace($Output)) {
        return 'The command failed but Windows returned no message.'
    }
    return $Output
}

# --------------------------------------------------------------------------
# Mapping actions
# --------------------------------------------------------------------------

function Remove-Mapping {
    param([string] $Letter)
    return Invoke-Console -FilePath $NetExe -Arguments "use $Letter`: /delete /y"
}

function New-Mapping {
    param(
        [string] $Letter,
        [string] $Path,
        [string] $UserName,
        [string] $Password,
        [bool]   $Persistent
    )

    $persistFlag = if ($Persistent) { '/persistent:yes' } else { '/persistent:no' }
    $netArgs = "use $Letter`: $(ConvertTo-Argument $Path)"
    if ($UserName) {
        $netArgs += " /user:$(ConvertTo-Argument $UserName) $(ConvertTo-Argument $Password)"
    }
    $netArgs += " $persistFlag"
    return Invoke-Console -FilePath $NetExe -Arguments $netArgs
}

function Save-ServerCredential {
    param([string] $Server, [string] $UserName, [string] $Password)

    if (-not $Server -or -not $UserName) { return $null }
    $keyArgs = "/add:$(ConvertTo-Argument $Server) /user:$(ConvertTo-Argument $UserName) /pass:$(ConvertTo-Argument $Password)"
    return Invoke-Console -FilePath $CmdKeyExe -Arguments $keyArgs
}

# --------------------------------------------------------------------------
# Build the window
# --------------------------------------------------------------------------

$settings = Get-Settings

$form                 = New-Object System.Windows.Forms.Form
$form.Text            = 'Map Network Drive'
$form.Size            = New-Object System.Drawing.Size(560, 560)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox     = $false
$form.MinimizeBox     = $false
$form.TopMost         = $true
$form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)

function New-Label {
    param([string] $Text, [int] $X, [int] $Y, [int] $W = 150)
    $l          = New-Object System.Windows.Forms.Label
    $l.Text     = $Text
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.Size     = New-Object System.Drawing.Size($W, 20)
    return $l
}

$y = 15

$form.Controls.Add((New-Label 'Drive letter' 20 $y))
$y += 22
$cboLetter               = New-Object System.Windows.Forms.ComboBox
$cboLetter.Location      = New-Object System.Drawing.Point(20, $y)
$cboLetter.Size          = New-Object System.Drawing.Size(500, 24)
$cboLetter.DropDownStyle = 'DropDownList'
$form.Controls.Add($cboLetter)
$y += 34

$form.Controls.Add((New-Label 'Network folder  (\\server\share)' 20 $y 300))
$y += 22
$cboPath          = New-Object System.Windows.Forms.ComboBox
$cboPath.Location = New-Object System.Drawing.Point(20, $y)
$cboPath.Size     = New-Object System.Drawing.Size(500, 24)
$cboPath.DropDownStyle = 'DropDown'
$cboPath.AutoCompleteMode = 'SuggestAppend'
$cboPath.AutoCompleteSource = 'ListItems'
$form.Controls.Add($cboPath)
$y += 34

$form.Controls.Add((New-Label 'Username  (DOMAIN\user or user@domain)' 20 $y 320))
$y += 22
$txtUser          = New-Object System.Windows.Forms.TextBox
$txtUser.Location = New-Object System.Drawing.Point(20, $y)
$txtUser.Size     = New-Object System.Drawing.Size(500, 24)
$form.Controls.Add($txtUser)
$y += 34

$form.Controls.Add((New-Label 'Password' 20 $y))
$y += 22
$txtPass              = New-Object System.Windows.Forms.TextBox
$txtPass.Location     = New-Object System.Drawing.Point(20, $y)
$txtPass.Size         = New-Object System.Drawing.Size(500, 24)
$txtPass.UseSystemPasswordChar = $true
$form.Controls.Add($txtPass)
$y += 32

$chkPersist          = New-Object System.Windows.Forms.CheckBox
$chkPersist.Text     = 'Reconnect at sign-in (persistent mapping)'
$chkPersist.Location = New-Object System.Drawing.Point(20, $y)
$chkPersist.Size     = New-Object System.Drawing.Size(300, 22)
$chkPersist.Checked  = [bool]$settings.defaultPersistent
$form.Controls.Add($chkPersist)

$chkSaveCred          = New-Object System.Windows.Forms.CheckBox
$chkSaveCred.Text     = 'Save credential for this server'
$chkSaveCred.Location = New-Object System.Drawing.Point(320, $y)
$chkSaveCred.Size     = New-Object System.Drawing.Size(220, 22)
$chkSaveCred.Checked  = [bool]$settings.saveCredential
$form.Controls.Add($chkSaveCred)
$y += 34

$btnMap          = New-Object System.Windows.Forms.Button
$btnMap.Text     = 'Map Drive'
$btnMap.Location = New-Object System.Drawing.Point(20, $y)
$btnMap.Size     = New-Object System.Drawing.Size(150, 34)
$form.Controls.Add($btnMap)
$form.AcceptButton = $btnMap

$btnDisconnect          = New-Object System.Windows.Forms.Button
$btnDisconnect.Text     = 'Disconnect'
$btnDisconnect.Location = New-Object System.Drawing.Point(180, $y)
$btnDisconnect.Size     = New-Object System.Drawing.Size(120, 34)
$form.Controls.Add($btnDisconnect)

$btnRefresh          = New-Object System.Windows.Forms.Button
$btnRefresh.Text     = 'Refresh letters'
$btnRefresh.Location = New-Object System.Drawing.Point(310, $y)
$btnRefresh.Size     = New-Object System.Drawing.Size(120, 34)
$form.Controls.Add($btnRefresh)

$btnClose          = New-Object System.Windows.Forms.Button
$btnClose.Text     = 'Close'
$btnClose.Location = New-Object System.Drawing.Point(440, $y)
$btnClose.Size     = New-Object System.Drawing.Size(80, 34)
$form.Controls.Add($btnClose)
$form.CancelButton = $btnClose
$y += 44

$txtLog            = New-Object System.Windows.Forms.TextBox
$txtLog.Location   = New-Object System.Drawing.Point(20, $y)
$txtLog.Size       = New-Object System.Drawing.Size(500, 190)
$txtLog.Multiline  = $true
$txtLog.ReadOnly   = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.BackColor  = [System.Drawing.Color]::White
$form.Controls.Add($txtLog)

function Write-Log {
    param([string] $Message)
    $stamp = (Get-Date).ToString('HH:mm:ss')
    $txtLog.AppendText("[$stamp] $Message`r`n")
    $txtLog.SelectionStart = $txtLog.TextLength
    $txtLog.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

# --------------------------------------------------------------------------
# Populate
# --------------------------------------------------------------------------

function Update-LetterList {
    param([string] $Select)

    $current = if ($Select) {
        $Select
    } elseif ($cboLetter.SelectedItem) {
        Get-SelectedLetter $cboLetter
    } else {
        ([string]$settings.defaultDriveLetter).Substring(0, 1).ToUpper()
    }

    $cboLetter.Items.Clear()
    foreach ($item in Get-DriveLetterItems) { $cboLetter.Items.Add($item) | Out-Null }

    $index = 0
    for ($i = 0; $i -lt $cboLetter.Items.Count; $i++) {
        if (([string]$cboLetter.Items[$i]).Substring(0, 1) -eq $current) { $index = $i; break }
    }
    $cboLetter.SelectedIndex = $index
}

$presets = @()
if ($settings.presets) { $presets = @($settings.presets) }

function Update-PathList {
    $cboPath.Items.Clear()
    $seen = @{}
    foreach ($p in $presets) {
        if ($p.path -and -not $seen.ContainsKey($p.path)) {
            $cboPath.Items.Add($p.path) | Out-Null
            $seen[$p.path] = $true
        }
    }
    foreach ($r in Get-RecentPaths) {
        if (-not $seen.ContainsKey($r)) {
            $cboPath.Items.Add($r) | Out-Null
            $seen[$r] = $true
        }
    }
}

Update-LetterList
Update-PathList
$txtUser.Text = [string]$settings.defaultUsername

# When the typed/selected path matches a preset, adopt that preset's letter and user.
$cboPath.Add_SelectedIndexChanged({
    $chosen = [string]$cboPath.SelectedItem
    $preset = $presets | Where-Object { $_.path -eq $chosen } | Select-Object -First 1
    if ($preset) {
        if ($preset.letter)   { Update-LetterList -Select ([string]$preset.letter).Substring(0,1).ToUpper() }
        if ($preset.username) { $txtUser.Text = [string]$preset.username }
    }
})

Write-Log 'Ready. Pick a drive letter and a network folder, then click Map Drive.'
if ($presets.Count -gt 0) {
    Write-Log "Loaded $($presets.Count) preset path(s) from settings."
}

# --------------------------------------------------------------------------
# Actions
# --------------------------------------------------------------------------

$btnRefresh.Add_Click({
    Update-LetterList
    Update-PathList
    Write-Log 'Drive letter list refreshed.'
})

$btnClose.Add_Click({ $form.Close() })

$btnDisconnect.Add_Click({
    $letter = Get-SelectedLetter $cboLetter
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Disconnect drive $letter`: ?",
        'Confirm disconnect',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    Write-Log "Disconnecting $letter`: ..."
    $result = Remove-Mapping -Letter $letter
    if ($result.ExitCode -eq 0) {
        Write-Log "Drive $letter`: disconnected."
    } else {
        Write-Log "Could not disconnect $letter`: $(Resolve-NetError $result.Output)"
    }
    Update-LetterList -Select $letter
})

$btnMap.Add_Click({
    $letter     = Get-SelectedLetter $cboLetter
    $path       = ([string]$cboPath.Text).Trim().TrimEnd('\')
    $user       = ([string]$txtUser.Text).Trim()
    $pass       = [string]$txtPass.Text

    if (-not (Test-UncPath $path)) {
        [System.Windows.Forms.MessageBox]::Show(
            "The network folder must look like \\server\share`r`n`r`nFor example:  \\fileserver\accounts",
            'Check the path',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        $cboPath.Focus()
        return
    }

    if (Test-LetterInUse $letter) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "Drive $letter`: is already in use.`r`n`r`nReplace it with $path ?",
            'Drive letter in use',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            Write-Log 'Cancelled. Nothing was changed.'
            return
        }
    }

    $btnMap.Enabled = $false
    $form.Cursor    = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $server = Get-ServerName $path
        Write-Log "Checking that $server is reachable ..."
        if (-not (Test-ServerReachable -Server $server)) {
            Write-Log "WARNING: no answer from $server on port 445 (file sharing)."
            Write-Log 'The server may be off, or you may be off the office network / VPN. Trying anyway.'
        } else {
            Write-Log "$server answered."
        }

        Write-Log "Clearing any old mapping on $letter`: ..."
        Remove-Mapping -Letter $letter | Out-Null

        Write-Log "Mapping $letter`: to $path ..."
        $result = New-Mapping -Letter $letter -Path $path -UserName $user -Password $pass -Persistent $chkPersist.Checked

        if ($result.ExitCode -eq 0) {
            Write-Log "SUCCESS. $letter`: is now $path"
            Add-RecentPath -Path $path

            if ($chkSaveCred.Checked -and $user) {
                $cred = Save-ServerCredential -Server $server -UserName $user -Password $pass
                if ($cred -and $cred.ExitCode -eq 0) {
                    Write-Log "Credential saved in Windows Credential Manager for $server."
                } else {
                    Write-Log 'Drive mapped, but the credential could not be saved. That is not fatal.'
                }
            }

            $txtPass.Clear()
            Update-LetterList -Select $letter
            Update-PathList

            if ($settings.openExplorerOnSuccess) {
                Start-Process -FilePath 'explorer.exe' -ArgumentList "$letter`:\"
            }
        } else {
            $msg = Resolve-NetError $result.Output
            Write-Log "FAILED: $msg"
            [System.Windows.Forms.MessageBox]::Show(
                $msg,
                'Could not map the drive',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            $txtPass.Focus()
            $txtPass.SelectAll()
        }
    } catch {
        Write-Log "Unexpected error: $($_.Exception.Message)"
    } finally {
        $form.Cursor    = [System.Windows.Forms.Cursors]::Default
        $btnMap.Enabled = $true
    }
})

$form.Add_Shown({
    $form.Activate()
    if ([string]::IsNullOrWhiteSpace($cboPath.Text) -and $cboPath.Items.Count -gt 0) {
        $cboPath.SelectedIndex = 0
    }
    if ([string]::IsNullOrWhiteSpace($txtUser.Text)) { $txtUser.Focus() } else { $txtPass.Focus() }
})

[void]$form.ShowDialog()
$form.Dispose()
