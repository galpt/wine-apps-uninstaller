#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Interactive Wine apps uninstaller
# Author: github.com/galpt
# Sources: https://wiki.archlinux.org/title/Wine
#          https://gitlab.winehq.org/wine/wine/-/wikis/home

PROG_NAME=$(basename "$0")

_green() { printf "\033[1;32m%s\033[0m\n" "$*"; }
_yellow() { printf "\033[1;33m%s\033[0m\n" "$*"; }
_red() { printf "\033[1;31m%s\033[0m\n" "$*"; }

print_header() {
  cat <<'HEADER'

┌────────────────────────────────────────────────────────┐
│               Wine Applications Uninstaller            │
│                    Author: github.com/galpt            │
└────────────────────────────────────────────────────────┘

This helper scans common Wine prefixes for installed Windows programs,
offers an interactive selection menu, runs their uninstallers when
available, and safely removes leftover files and desktop entries.

HEADER
}

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "$(_red "ERROR"): required command '$1' not found."; exit 1; } }

ensure_prereqs() {
  require_cmd wine
  require_cmd find
  require_cmd sed
  require_cmd awk
  require_cmd grep
}

check_not_root() {
  if [ "$EUID" -eq 0 ]; then
    _red "Do NOT run this script as root. Exiting."; exit 1
  fi
}

find_prefixes() {
  PREFIXES=()
  # If user set WINEPREFIX, prefer it
  if [ -n "${WINEPREFIX-}" ] && [ -d "${WINEPREFIX}" ]; then
    PREFIXES+=("${WINEPREFIX}")
  fi
  # default prefix
  if [ -d "$HOME/.wine" ]; then
    PREFIXES+=("$HOME/.wine")
  fi
  # common winetricks/wineprefixes dir
  if [ -d "$HOME/.local/share/wineprefixes" ]; then
    while IFS= read -r p; do PREFIXES+=("$p"); done < <(find "$HOME/.local/share/wineprefixes" -maxdepth 1 -mindepth 1 -type d -print 2>/dev/null)
  fi
  # fallback: search for drive_c directories under home (fast, limited depth)
  while IFS= read -r d; do
    p=${d%/drive_c}
    PREFIXES+=("$p")
  done < <(find "$HOME" -maxdepth 4 -type d -name drive_c -print 2>/dev/null | sort -u)

  # unique
  mapfile -t PREFIXES < <(printf "%s\n" "${PREFIXES[@]:-}" | awk '!x[$0]++')
}

show_prefix_menu() {
  echo
  echo "Detected Wine prefixes:"
  i=1
  for p in "${PREFIXES[@]}"; do
    echo "  $i) $p"
    ((i++))
  done
  echo
}

prompt_select_prefix() {
  while true; do
    read -rp "Select prefix number to inspect (or 'q' to quit): " sel
    [[ "$sel" =~ ^[Qq]$ ]] && echo "Aborted." && exit 0
    if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#PREFIXES[@]}" ]; then
      PREFIX="${PREFIXES[$((sel-1))]}"
      echo
      _green "Selected prefix: $PREFIX"
      break
    fi
    echo "Invalid selection — try again."
  done
}

winereg_parse_uninstall() {
  # Parse system.reg and user.reg looking for keys under *\\Uninstall\\*
  local prefix=$1
  declare -A entry_name
  declare -A entry_uninstall
  declare -A entry_location
  local idx=0

  for regfile in "$prefix/system.reg" "$prefix/user.reg"; do
    [ -r "$regfile" ] || continue
    current_key=""
    in_uninstall=0
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ $line =~ ^\[(.*)\]$ ]]; then
        current_key="${BASH_REMATCH[1]}"
        if [[ "$current_key" =~ \\Uninstall\\ ]]; then
          in_uninstall=1
        else
          in_uninstall=0
        fi
        continue
      fi
      if [ "$in_uninstall" -eq 1 ] && [[ $line =~ ^\"([^\"]+)\"= ]]; then
        keyname="${BASH_REMATCH[1]}"
        # extract value after = and strip surrounding quotes
        val=$(echo "$line" | sed -E 's/^"[^"]+"=.?(.+)$/\1/')
        # if value is a quoted string like "Foo" strip quotes and trailing\n
        if [[ $val =~ ^\"(.*)\"$ ]]; then
          val="${BASH_REMATCH[1]}"
        fi
        case "$keyname" in
          DisplayName) entry_name[$idx]="$val" ;;
          UninstallString) entry_uninstall[$idx]="$val" ;;
          InstallLocation) entry_location[$idx]="$val" ;;
        esac
      fi
      # If we've collected a DisplayName for current key and next key begins, store it
      # We'll push when a new key starts or at EOF; simple approach: when we encounter a new key
      if [ "$in_uninstall" -eq 0 ] && [ -n "${entry_name[$idx]-}" ]; then
        ((idx++))
      fi
    done < "$regfile"
    # end file: increment idx to allow further entries
    if [ -n "${entry_name[$idx]-}" ]; then ((idx++)); fi
  done

  # Output consolidated list: index|name|uninstall|location
  for i in "${!entry_name[@]}"; do
    echo "$i|${entry_name[$i]:-}|${entry_uninstall[$i]:-}|${entry_location[$i]:-}"
  done | sort -t'|' -k2,2
}

win_path_to_unix() {
  # Convert a Windows-style path in a registry value to a UNIX path inside the prefix
  local prefix=$1 value=$2
  # remove surrounding quotes
  value=${value#\"}; value=${value%\"}
  # remove leading C:\ or c:\
  value=${value#C:}
  value=${value#c:}
  # replace backslashes with /
  value=${value//\\/\/}
  # remove leading leading slash if any
  value=${value#/}
  printf "%s/drive_c/%s" "$prefix" "$value"
}

size_for_location() {
  local prefix=$1 loc=$2
  if [ -z "$loc" ]; then
    echo "?"
    return
  fi
  # Convert possible Windows path
  unixp=$(win_path_to_unix "$prefix" "$loc")
  if [ -e "$unixp" ]; then
    du -sh "$unixp" 2>/dev/null | awk '{print $1}' || echo "?"
  else
    echo "?"
  fi
}

collect_apps() {
  APPS=()
  mapfile -t raw < <(winereg_parse_uninstall "$PREFIX")
  for line in "${raw[@]}"; do
    IFS='|' read -r idx name unstr loc <<< "$line"
    [ -z "$name" ] && continue
    # prefer readable name; if contains REG_SZ markers, remove them
    name=$(echo "$name" | sed -E 's/^\s+|\s+$//g')
    APPS+=("$idx|$name|$unstr|$loc")
  done

  # If no apps found via registry, fall back to scanning Program Files
  if [ "${#APPS[@]}" -eq 0 ]; then
    # look for top-level directories in drive_c/Program Files*
    for d in "$PREFIX/drive_c/Program Files" "$PREFIX/drive_c/Program Files (x86)"; do
      if [ -d "$d" ]; then
        while IFS= read -r p; do
          nm=$(basename "$p")
          APPS+=("-1|$nm||$p")
        done < <(find "$d" -maxdepth 1 -mindepth 1 -type d -printf '%p\n' 2>/dev/null)
      fi
    done
  fi
}

show_apps_menu() {
  echo
  echo "Installed applications in prefix: $PREFIX"
  printf "%3s %-40s %-8s %s\n" "#" "Name" "Size" "Method"
  echo "--------------------------------------------------------------------------------"
  i=1
  for e in "${APPS[@]}"; do
    IFS='|' read -r aid name unstr loc <<< "$e"
    if [ -n "$loc" ]; then size=$(size_for_location "$PREFIX" "$loc"); else size="?"; fi
    method="manual"
    if [ -n "$unstr" ]; then method="uninstall"; fi
    printf "%3s %-40s %-8s %s\n" "$i" "${name:0:40}" "$size" "$method"
    ((i++))
  done
  echo
}

prompt_select_apps() {
  read -rp "Enter numbers to remove (space-separated), or 'q' to quit: " sel
  [[ "$sel" =~ ^[Qq]$ ]] && echo "Aborted." && exit 0
  # parse numbers
  TO_REMOVE=()
  for token in $sel; do
    if [[ "$token" =~ ^[0-9]+$ ]] && [ "$token" -ge 1 ] && [ "$token" -le "${#APPS[@]}" ]; then
      TO_REMOVE+=("$((token-1))")
    fi
  done
  if [ "${#TO_REMOVE[@]}" -eq 0 ]; then
    _yellow "No valid selections made. Exiting."; exit 0
  fi
}

remove_desktop_entries() {
  local name="$1"
  # Wine menu desktop entries live under ~/.local/share/applications/wine/Programs
  local wine_apps_dir="$HOME/.local/share/applications/wine/Programs"
  if [ -d "$wine_apps_dir" ]; then
    # remove files matching the program name (case-insensitive)
    shopt -s nullglob
    for f in "$wine_apps_dir"/*; do
      if echo "$(basename "$f")" | grep -iq "${name}"; then
        _yellow "Removing desktop entry: $f"
        rm -f "$f" || true
      fi
    done
    shopt -u nullglob
  fi
}

remove_wine_file_associations() {
  _green "Cleaning Wine file associations and icons (may require sudo for system locations)."
  # Remove wine extension desktop files
  rm -f "$HOME/.local/share/applications/wine-extension*.desktop" || true
  rm -f "$HOME/.local/share/applications/wine-extension*" || true

  # Remove leftover wine menu files
  rm -f "$HOME/.local/share/applications/wine-*.desktop" || true
  rm -f "$HOME/.local/share/applications/wine-*.menu" || true
  rm -f "$HOME/.config/menus/wine-*.menu" || true

  # Remove wine menu dirs
  if [ -d "$HOME/.local/share/applications/wine" ]; then
    # if directory empty after removals, remove it
    rmdir --ignore-fail-on-non-empty "$HOME/.local/share/applications/wine" 2>/dev/null || true
  fi

  # Remove icons and mime packages created by Wine
  rm -f "$HOME/.local/share/icons/hicolor/*/*/application-x-wine-extension*" 2>/dev/null || true
  rm -f "$HOME/.local/share/mime/packages/x-wine*" 2>/dev/null || true
  rm -f "$HOME/.local/share/mime/application/x-wine-extension*" 2>/dev/null || true

  # Remove desktop shortcuts on Desktop that mention the app name
  if [ -d "$HOME/Desktop" ]; then
    shopt -s nullglob
    # remove .desktop wrappers
    for f in "$HOME/Desktop"/*.desktop; do
      if grep -qi "${1}" "$f" 2>/dev/null || echo "$(basename "$f")" | grep -iq "${1}"; then
        _yellow "Removing desktop shortcut: $f"
        rm -f "$f" || true
      fi
    done
    # remove Windows .lnk shortcuts that may appear on the Desktop
    if command -v find >/dev/null 2>&1; then
      find "$HOME/Desktop" -maxdepth 1 -type f \( -iname "*${1}*.lnk" -o -iname "*.lnk" \) -print0 | while IFS= read -r -d '' lf; do
        # only remove .lnk files that contain the program name or look like Wine links
        if echo "$(basename "$lf")" | grep -iq "${1}" || grep -qi "wine" <<< "$(basename "$lf")"; then
          _yellow "Removing Windows .lnk shortcut: $lf"
          rm -f "$lf" || true
        fi
      done
    fi
    shopt -u nullglob
  fi

  # Clear cached desktop/mime info so menus update
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
  fi
  if command -v update-mime-database >/dev/null 2>&1; then
    update-mime-database "$HOME/.local/share/mime" 2>/dev/null || true
  fi

  # Update icon cache if available
  if [ -d "$HOME/.local/share/icons/hicolor" ] && command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
  fi
}

find_system_artifacts() {
  local name="$1"
  SYSTEM_ARTIFACTS=()
  # common system locations to check
  local -a patterns=(
    "/usr/share/applications/wine*"
    "/usr/local/share/applications/wine*"
    "/usr/share/applications/*wine*.desktop"
    "/usr/local/share/applications/*wine*.desktop"
    "/usr/share/icons/hicolor/*/*/application-x-wine-extension*"
    "/usr/local/share/icons/hicolor/*/*/application-x-wine-extension*"
    "/usr/share/mime/packages/x-wine*"
    "/usr/local/share/mime/packages/x-wine*"
  )

  for pat in "${patterns[@]}"; do
    for f in $pat; do
      [ -e "$f" ] || continue
      # if name provided, match it in basename
      if [ -n "$name" ]; then
        if echo "$(basename "$f")" | grep -iq "$name"; then
          SYSTEM_ARTIFACTS+=("$f")
        else
          # also include generic wine artifacts
          if echo "$(basename "$f")" | grep -iq "wine"; then
            SYSTEM_ARTIFACTS+=("$f")
          fi
        fi
      else
        SYSTEM_ARTIFACTS+=("$f")
      fi
    done
  done
  # dedupe
  if [ "${#SYSTEM_ARTIFACTS[@]}" -gt 0 ]; then
    mapfile -t SYSTEM_ARTIFACTS < <(printf "%s\n" "${SYSTEM_ARTIFACTS[@]}" | awk '!x[$0]++')
  fi
}

run_privileged_cleanup() {
  local -a items=("${SYSTEM_ARTIFACTS[@]:-}")
  [ "${#items[@]}" -gt 0 ] || return 0
  echo
  _yellow "The following system-wide files were detected and require root to remove:"
  for p in "${items[@]}"; do echo "  $p"; done
  read -rp "Remove these system files using sudo? [y/N]: " ok
  if ! [[ "$ok" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    _yellow "Skipping system-wide cleanup."; return 0
  fi

  # ask for sudo upfront
  if ! sudo -v; then
    _red "sudo authentication failed or was cancelled. Skipping privileged cleanup."; return 0
  fi

  for p in "${items[@]}"; do
    sudo rm -rf -- "$p" || _yellow "Failed to remove $p (continuing)"
  done

  # refresh system caches if utilities exist
  if command -v update-desktop-database >/dev/null 2>&1 && [ -d "/usr/share/applications" ]; then
    sudo update-desktop-database "/usr/share/applications" 2>/dev/null || true
  fi
  if command -v update-mime-database >/dev/null 2>&1 && [ -d "/usr/share/mime" ]; then
    sudo update-mime-database "/usr/share/mime" 2>/dev/null || true
  fi
  if command -v gtk-update-icon-cache >/dev/null 2>&1 && [ -d "/usr/share/icons/hicolor" ]; then
    sudo gtk-update-icon-cache -f "/usr/share/icons/hicolor" 2>/dev/null || true
  fi
}

tidy_leftovers() {
  local name="$1"
  # Remove any wine program folders under .local/share/applications/wine/Programs matching name
  local wine_apps_dir="$HOME/.local/share/applications/wine/Programs"
  if [ -d "$wine_apps_dir" ]; then
    shopt -s nullglob
    for d in "$wine_apps_dir"/*; do
      if echo "$(basename "$d")" | grep -iq "${name}"; then
        _yellow "Removing wine program menu dir: $d"
        rm -rf "$d" || true
      fi
    done
    shopt -u nullglob
  fi

  # Remove any leftover installer directories under ~/.local/share/icons or package metadata
  remove_wine_file_associations "$name"
}

run_uninstall() {
  local entry="$1" # idx|name|unstr|loc
  IFS='|' read -r id name unstr loc <<< "$entry"
  _green "Processing: $name"
  if [ -n "$unstr" ]; then
    # prefer to run uninstall string via wine with WINEPREFIX
    _yellow "Uninstall command found: $unstr"
    read -rp "Run uninstaller for '$name'? [y/N]: " ans
    if ! [[ "$ans" =~ ^([yY][eE][sS]|[yY])$ ]]; then
      _yellow "Skipping uninstaller for $name"
    else
      # prepare command: if it contains msiexec or starts with a quoted path
      if echo "$unstr" | grep -qi "msiexec"; then
        # pass through to wine msiexec
        _green "Running: wine msiexec $unstr"
        env WINEPREFIX="$PREFIX" wine $unstr || _yellow "Uninstaller exited with non-zero status"
      else
        # often it's a quoted Windows path with optional args
        # extract exe path and args
        exe=$(echo "$unstr" | awk '{print $1}')
        args=$(echo "$unstr" | cut -s -d' ' -f2- || true)
        unix_exe=$(win_path_to_unix "$PREFIX" "$exe")
        if [ -x "$unix_exe" ] || [ -f "$unix_exe" ]; then
          _green "Running: wine '$unix_exe' $args"
          env WINEPREFIX="$PREFIX" wine "$unix_exe" $args || _yellow "Uninstaller exited with non-zero status"
        else
          # try using wine start with the Windows path
          _green "Running: wine start /unix '$exe' $args"
          env WINEPREFIX="$PREFIX" wine start /unix "$exe" $args || _yellow "Uninstaller exited with non-zero status"
        fi
      fi
    fi
  else
    # No uninstall string — attempt manual directory removal
    if [ -n "$loc" ]; then
      unixp=$loc
      # If loc looks like Windows path, convert
      if [[ "$loc" =~ \\ ]]; then
        unixp=$(win_path_to_unix "$PREFIX" "$loc")
      fi
      _yellow "No uninstaller found. Consider removing: $unixp"
      read -rp "Delete directory '$unixp' now? [y/N]: " ans2
      if [[ "$ans2" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        rm -rf "$unixp" || _yellow "Failed to remove $unixp"
      else
        _yellow "Skipped manual removal for $name"
      fi
    else
      _yellow "No uninstall information for $name — nothing to do."
    fi
  fi

  # Attempt to remove desktop entries for this program name
  remove_desktop_entries "$name"
  tidy_leftovers "$name"

  # Try to tidy up wineserver state
  if command -v wineserver >/dev/null 2>&1; then
    env WINEPREFIX="$PREFIX" wineserver -k || true
  fi
}

main() {
  check_not_root
  ensure_prereqs
  print_header

  find_prefixes
  if [ "${#PREFIXES[@]}" -eq 0 ]; then
    _red "No Wine prefixes found under your home directory. Exiting."; exit 1
  fi

  show_prefix_menu
  prompt_select_prefix

  collect_apps
  if [ "${#APPS[@]}" -eq 0 ]; then
    _yellow "No installed applications detected in this prefix. Exiting."; exit 0
  fi

  show_apps_menu
  prompt_select_apps

  # Confirm one more time
  read -rp "Confirm uninstall of ${#TO_REMOVE[@]} selected apps? [y/N]: " final
  if ! [[ "$final" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    _yellow "Aborted by user."; exit 0
  fi

  for idx in "${TO_REMOVE[@]}"; do
    entry="${APPS[$idx]}"
    run_uninstall "$entry"
  done

  _green "Done. If desktop menu items linger, run:"
  _green "  update-desktop-database ~/.local/share/applications || true"
}

if [ "${1-}" = "--help" ] || [ "${1-}" = "-h" ]; then
  print_header
  echo
  echo "Usage: $PROG_NAME"; exit 0
fi

main "$@"
