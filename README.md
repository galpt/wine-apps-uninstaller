# Wine Apps Uninstaller

Interactive helper to detect and remove Windows applications installed inside Wine prefixes.
It parses Wine registry files for uninstall strings, presents an easy interactive menu, runs
uninstallers via Wine when available, and helps safely clean leftover files and desktop entries.

<p align="center">
	<img src="https://github.com/galpt/wine-apps-uninstaller/blob/main/img/how-it-looks-like.png" alt="Web UI preview" style="max-width:100%;height:auto;" />
	<br/>
	<em>How it looks like</em>
</p>

---

## Table of Contents
- [Status](#status)
- [Features](#features)
- [Requirements](#requirements)
- [Usage](#usage)
- [Examples](#examples)
- [Design Notes](#design-notes)
- [Limitations & Next Steps](#limitations--next-steps)
- [Contributing](#contributing)
- [License](#license)

## Status
- Beta: interactive, robust for typical prefixes; please test on your prefixes and open issues for edge cases.

## Features
- Detects common Wine prefixes: `$WINEPREFIX`, `~/.wine`, `~/.local/share/wineprefixes`, and a limited-depth search for `drive_c` directories.
- Parses `system.reg` and `user.reg` to enumerate installed applications and their `UninstallString`/`InstallLocation` values.
- Presents a numbered interactive menu for selecting multiple applications to remove.
- Runs uninstallers via `wine` (supports msiexec and standard uninstall executables), or offers safe manual directory removal when no uninstaller is available.
- Removes Wine-created `.desktop` entries under `~/.local/share/applications/wine/Programs` when matching names are found.
- Attempts a clean shutdown of Wine services (`wineserver -k`) after removals to avoid stale state.

## Requirements
- Linux (Arch / Arch-based recommended but not required)
- `wine` (the script uses `wine` to run uninstallers)
- Standard POSIX utilities: `find`, `sed`, `awk`, `grep`, `du`

The script must be run as a normal user (do NOT run as root). It operates on files inside your home directory.

## Usage

Make the script executable and run it from your shell:

```bash
chmod +x "Wine Apps Uinstaller/wine-apps-uninstaller.sh"
./"Wine Apps Uploader/wine-apps-uninstaller.sh"  # or the full path
```

Basic flow:
- The script locates Wine prefixes and shows a numbered list.
- Select a prefix to inspect.
- It enumerates installed applications found in registry and/or `Program Files` directories, shows approximate size and removal method.
- Enter numbers (space-separated) for the apps you want to remove.
- Confirm, then the script will run each app's uninstaller (if available) or offer to delete the install folder.

Important safety notes:
- Do not run as `root`. The script is designed to operate on user prefixes.
- The script asks for confirmation before running uninstallers or deleting directories.

## Examples

- Inspect default prefix and remove apps:

```bash
./"Wine Apps Uinstaller/wine-apps-uninstaller.sh"
# choose the prefix number
# view the app list and enter: 1 3 5
# confirm removal
```

- If a program has an `UninstallString` that references `msiexec`, the script will invoke it via `wine msiexec`.

## Design Notes

- Registry parsing: the script reads `system.reg` and `user.reg` inside a prefix and searches for keys under `...\\Uninstall\\...`. This is a robust approach that mirrors how Windows stores uninstall information and is used by Wine.
- Path conversion: uninstall strings often include Windows-style paths (e.g. `C:\Program Files\Foo\uninstall.exe`). The script converts those to the corresponding Unix path inside the selected Wine prefix before attempting to execute the binary.
- Desktop entries: Wine creates menu items under `~/.local/share/applications/wine/Programs/`. The script attempts to remove matching `.desktop` files to clean up menus.
- Safety: the script prompts before destructive actions and will not run silently unless modified.

## Limitations & Next Steps

- The script performs a limited-depth search for prefixes — extremely exotic prefix locations may not be discovered automatically.
- Parsing is intentionally conservative; some complex registry encodings or unusual installer strings may not be handled perfectly.
- Improvements to consider:
	- Add a `--dry-run` mode to preview changes without executing uninstallers or deletions.
	- Provide a non-interactive mode with explicit flags for automation.
	- Better cleanup of registry remnants or shell integration entries.
	- Add more robust detection for `UninstallString` argument quoting and MSI parameters.

## Contributing

- Suggestions, bug reports, and pull requests welcome. Please include a small sample of the `system.reg`/`user.reg` section (redact personal data) if reporting missing detections.
- Run the script locally and add reproducible steps to demonstrate issues.

## License

MIT

## Sources
- ArchWiki — Wine: https://wiki.archlinux.org/title/Wine
- Wine Wiki: https://gitlab.winehq.org/wine/wine/-/wikis/home
