# Wine Apps Uninstaller

Interactive helper to detect and remove Windows applications installed inside Wine prefixes.
It scans common Wine prefixes, parses uninstall information from Wine registry files, lets you
select apps from a terminal menu, runs uninstallers when available, and helps clean leftover
desktop entries or install directories safely.

<p align="center">
  <img src="https://github.com/galpt/wine-apps-uninstaller/blob/main/img/how-it-looks-like.png" alt="Terminal preview of the Wine Apps Uninstaller" style="max-width:100%;height:auto;" />
  <br/>
  <em>How it looks</em>
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
- Beta, but hardened for common real-world Wine prefix layouts and uninstall strings.

## Features
- Detects common Wine prefixes from `$WINEPREFIX`, `~/.wine`, `~/.local/share/wineprefixes`, and a limited home-directory scan.
- Supports `--prefix PATH` to inspect a specific prefix directly.
- Parses `system.reg` and `user.reg` for `DisplayName`, `UninstallString`, and `InstallLocation`.
- Falls back to scanning `Program Files` and `Program Files (x86)` when registry uninstall data is missing.
- Deduplicates detected applications and caches size lookups for faster menus.
- Supports `--dry-run` to preview uninstall and cleanup actions safely.
- Runs uninstallers through `wine cmd /c` for better compatibility with Windows-style command lines.
- Cleans matching Wine desktop entries, desktop shortcuts, and empty menu directories after removal.

## Requirements
- Linux
- `wine`
- Common base tools already present on most systems: `awk`, `find`, `grep`, `readlink`, `sed`, `sort`

The script must be run as a normal user. Do not run it as `root`.

## Usage

Make the script executable and run it from the repo directory:

```bash
chmod +x wine-apps-uninstaller.sh
./wine-apps-uninstaller.sh
```

Options:
- `--dry-run` shows what would happen without executing uninstallers or deleting files.
- `--prefix PATH` skips prefix discovery and inspects one specific Wine prefix.
- `--help` prints usage.

Basic flow:
- The script locates valid Wine prefixes and lets you pick one.
- It lists detected applications, their approximate size, and whether they have an uninstaller or only a removable folder.
- You choose one or more apps.
- The script confirms before running uninstallers or deleting leftover directories.

## Examples

Interactive run:

```bash
./wine-apps-uninstaller.sh
```

Preview actions without changing anything:

```bash
./wine-apps-uninstaller.sh --dry-run
```

Inspect a specific prefix directly:

```bash
./wine-apps-uninstaller.sh --prefix "$HOME/.wine"
```

## Design Notes

- Prefix detection is conservative: a directory must look like a real Wine prefix before it is listed.
- Uninstall entries are parsed section by section so multiple registry keys do not get merged together.
- Path cleanup is limited to the selected prefix, which helps avoid deleting unrelated files if a registry path is odd or malformed.
- After removals, the script refreshes local desktop, MIME, and icon caches when the relevant tools are available.

## Limitations & Next Steps

- Windows uninstall strings vary a lot, so some rare installers may still need manual cleanup.
- Some apps do not register uninstall information at all, so the fallback mode can only offer directory removal.
- Registry remnants inside the prefix are not removed yet.
- A future improvement could add a non-interactive mode for automation.

## Contributing

- Issues and pull requests are welcome.
- If app detection fails for a prefix, include a small redacted snippet from the relevant `system.reg` or `user.reg` uninstall section when possible.

## License

MIT

## Sources
- ArchWiki: https://wiki.archlinux.org/title/Wine
- Wine Wiki: https://gitlab.winehq.org/wine/wine/-/wikis/home
