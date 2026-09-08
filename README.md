# Daily IT Tools

Small Windows tools for everyday office IT tasks. No installer, no dependencies beyond what ships with Windows - double-click a `.bat` and it runs.

## Tools

| Tool | What it does | How to run |
| --- | --- | --- |
| [Map Network Drive](tools/Map-NetworkDrive/README.md) | Map **any** `\\server\share` to **any** drive letter, with a password prompt, plain-English errors, and a disconnect button | `tools\Map-NetworkDrive\Map-NetworkDrive.bat` |

## Quick start

```
git clone https://github.com/glensonis/IT_Daily_Tools_Collection.git
cd IT_Daily_Tools_Collection
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-DesktopShortcut.ps1
```

That puts a shortcut for every tool on your Desktop. To take them off again:

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-DesktopShortcut.ps1 -Remove
```

Or skip the shortcuts entirely and double-click the `.bat` under `tools\`.

## Why this exists

Z: vanished from File Explorer even though the file server was online. The stored password had gone stale, and the Windows credential prompt kept opening behind other windows. So: an always-on-top mapper that clears the broken mapping, asks for the password once, and says clearly what went wrong when it fails.

It is now generic. Pick the letter, pick the folder, sign in. Server names live only in a local `settings.json` that is never committed.

## Layout

```
Daily_IT_Tools\
  Install-DesktopShortcut.ps1        creates / removes Desktop shortcuts
  README.md
  LICENSE
  .gitignore
  tools\
    Map-NetworkDrive\
      Map-NetworkDrive.bat           launcher (double-click this)
      Map-NetworkDrive.ps1           the tool
      settings.sample.json           copy to settings.json and edit
      README.md
```

Per-user state (recent paths, optional user settings) lives in
`%APPDATA%\Daily_IT_Tools\` and is deliberately outside the repo.

## Adding a tool

1. `tools\<Tool-Name>\<Tool-Name>.ps1` - the tool
2. `tools\<Tool-Name>\<Tool-Name>.bat` - a launcher matching the pattern in Map-NetworkDrive
3. `tools\<Tool-Name>\README.md` - how to run it
4. Add a row to the table above

`Install-DesktopShortcut.ps1` picks up any new `.bat` automatically.

Ideas not built yet: reinstall a network printer, rebuild an Outlook profile, disk cleanup / temp purge, flush DNS + winsock reset.

## Safety

- Never commit passwords, `.rdp` files with saved credentials, or `cmdkey /list` output
- Keep this repository **private** - `settings.json` can hold internal server names, and it is git-ignored for that reason
- The tools store no password on disk; the optional "save credential" tick box hands it to Windows Credential Manager instead

## Licence

See [LICENSE](LICENSE) (GNU GPL v3, carried over from the original repository).
