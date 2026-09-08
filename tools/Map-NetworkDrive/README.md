# Map Network Drive

Generic Windows tool that maps **any** network folder (`\\server\share`) to **any** drive letter you choose.

Built from a one-off "Z: disappeared" fix, then generalised so it is not locked to a single letter or a single server. No server name appears in the code; presets live in a settings file you control.

---

## How to use

1. Double-click `Map-NetworkDrive.bat`
2. **Drive letter** - pick from D-Z. Each letter is marked `(available)` or `(in use - Fixed/Network/...)`
3. **Network folder** - type a UNC path such as `\\fileserver\accounts`, or pick one from the dropdown (your presets first, then paths you used recently)
4. **Username** - `DOMAIN\user` or `user@domain`
5. **Password** - typed each time, never stored by this tool
6. Leave **Reconnect at sign-in** ticked if you want the drive back after a reboot
7. Click **Map Drive**

```
+--------------------------------------------------+
|  Map Network Drive                          [x]  |
+--------------------------------------------------+
|  Drive letter                                    |
|  [ Z:  (in use - Network)                    v ] |
|                                                  |
|  Network folder  (\\server\share)                |
|  [ \\fileserver\accounts                     v ] |
|                                                  |
|  Username  (DOMAIN\user or user@domain)          |
|  [ CONTOSO\jsmith                             ]  |
|                                                  |
|  Password                                        |
|  [ ************                               ]  |
|                                                  |
|  [x] Reconnect at sign-in   [x] Save credential  |
|                                                  |
|  [ Map Drive ] [Disconnect] [Refresh ] [ Close ] |
|                                                  |
|  [09:14:02] Checking that fileserver is reach... |
|  [09:14:02] fileserver answered.                 |
|  [09:14:03] Clearing any old mapping on Z: ...   |
|  [09:14:04] SUCCESS. Z: is now \\fileserver\...  |
+--------------------------------------------------+
```

On success File Explorer opens the new drive. If the letter is already in use, the tool asks before replacing it.

To remove a mapping: pick the letter, click **Disconnect**, confirm.

---

## What it does, step by step

1. Checks the path looks like `\\server\share`
2. Tests TCP 445 on the server (3s) so an offline server or an off-VPN laptop is reported as such, instead of a raw Windows error code
3. Clears any stale mapping on the chosen letter (`net use <L>: /delete /y`)
4. Maps the drive with the credentials you typed, persistent or not
5. Optionally saves the credential for that server in Windows Credential Manager (`cmdkey`)
6. Adds the path to your recent list and opens Explorer

Every step is written to the log box at the bottom of the window.

---

## Settings (optional)

Copy `settings.sample.json` to `settings.json` in this folder and edit it. `settings.json` is git-ignored so your internal server names never leave the PC.

```json
{
  "defaultDriveLetter": "Z",
  "defaultUsername": "CONTOSO\\jsmith",
  "defaultPersistent": true,
  "openExplorerOnSuccess": true,
  "saveCredential": true,
  "presets": [
    { "name": "Accounts", "path": "\\\\fileserver\\accounts", "letter": "S", "username": "" }
  ]
}
```

Note that JSON needs each backslash doubled, so `\\fileserver\accounts` is written `\\\\fileserver\\accounts`.

Picking a preset from the dropdown also sets its drive letter and username.

Settings are read in this order, later files winning:

| Order | File | Purpose |
| --- | --- | --- |
| 1 | `settings.sample.json` (this folder) | safe defaults, in git |
| 2 | `settings.json` (this folder) | this PC / this copy, **not** in git |
| 3 | `%APPDATA%\Daily_IT_Tools\Map-NetworkDrive\settings.json` | per-user, follows the roaming profile |

Recently used paths are cached at `%APPDATA%\Daily_IT_Tools\Map-NetworkDrive\recent.json` - outside the repo, so it is never committed.

**No password is written to any of these files.**

---

## Errors in plain English

Raw `net use` failures are translated before they reach you:

| Windows error | What you see |
| --- | --- |
| 1326 | Wrong username or password. Try `DOMAIN\username` or `username@domain` |
| 1330 | The password has expired. Change your Windows password, then try again |
| 1331 / 1909 | The account is disabled / locked out |
| 5 | Access denied - sign-in worked, but this account is not allowed on that share |
| 53 | Network path not found - check the server name spelling, and the VPN |
| 67 | Share not found - the server answered but has no share by that name |
| 85 | That drive letter is already in use |
| 1219 | Already connected to this server as a different user |
| 51 / no answer on 445 | The server is not responding - off, or you are off the network |

Anything unmapped is shown with its Windows error number and the raw text, so it can still be searched.

---

## Testing

The script takes a `-Mode` switch so it can be checked automatically:

| Mode | Effect |
| --- | --- |
| `Normal` (default) | Opens the window. What the `.bat` launcher uses. |
| `FunctionsOnly` | Defines the functions and returns without loading WinForms. Dot-source it to test the logic on any OS. |
| `BuildOnly` | Builds every control but never shows the window. Used by the CI smoke test. |

Run the suite from the repository root with `pwsh -NoProfile -File .\tests\Run-Tests.ps1`.

## Requirements

- Windows 10/11 with PowerShell 5.1 (built in)
- Network access to the file server (office LAN or VPN)
- Permission on the share

No install step. No admin rights needed for a normal user mapping.

---

## Security notes

- The password lives in memory and in the `net use` argument list for the moment the command runs; it is never written to disk by this tool
- The **Save credential** tick box hands it to Windows Credential Manager, which is the same store Explorer uses
- Untick **Save credential** if you are on a shared PC
- Do not commit `settings.json`, `recent.json`, or anything from `cmdkey /list`
