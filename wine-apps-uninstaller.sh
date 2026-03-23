#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

PROG_NAME=$(basename "$0")

DRY_RUN=0
PREFIX_OVERRIDE=""
PREFIX=""

PREFIXES=()
APPS=()
TO_REMOVE=()

declare -A SIZE_CACHE=()

_green() { printf "\033[1;32m%s\033[0m\n" "$*"; }
_yellow() { printf "\033[1;33m%s\033[0m\n" "$*"; }
_red() { printf "\033[1;31m%s\033[0m\n" "$*"; }

print_header() {
  cat <<'HEADER'

┌────────────────────────────────────────────────────────┐
│               Wine Applications Uninstaller            │
│                    Author: github.com/galpt            │
└────────────────────────────────────────────────────────┘

This helper scans Wine prefixes for installed Windows programs,
offers an interactive selection menu, runs uninstallers when
available, and helps clean leftover files and desktop entries.

HEADER
}

usage() {
  cat <<USAGE
Usage: $PROG_NAME [options]

Options:
  --dry-run       Show what would be removed without changing anything
  --prefix PATH   Inspect a specific Wine prefix directly
  --help          Show this help

Examples:
  ./$PROG_NAME
  ./$PROG_NAME --dry-run
  ./$PROG_NAME --prefix "\$HOME/.wine"
USAGE
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    _red "Required command '$1' was not found."
    exit 1
  fi
}

ensure_prereqs() {
  require_cmd wine
  require_cmd awk
  require_cmd find
  require_cmd grep
  require_cmd readlink
  require_cmd sed
  require_cmd sort
}

check_not_root() {
  if [ "$EUID" -eq 0 ]; then
    _red "Do not run this script as root."
    exit 1
  fi
}

parse_flags() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        ;;
      --prefix)
        shift
        if [ "$#" -eq 0 ]; then
          _red "--prefix requires a path."
          exit 1
        fi
        PREFIX_OVERRIDE=$1
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        _red "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
    shift
  done
}

contains_text() {
  local haystack=$1
  local needle=$2

  grep -Fqi -- "$needle" <<< "$haystack"
}

is_valid_prefix() {
  local candidate=$1

  [ -d "$candidate" ] || return 1
  [ -d "$candidate/drive_c" ] || return 1

  if [ -f "$candidate/system.reg" ] || [ -f "$candidate/user.reg" ] || [ -d "$candidate/dosdevices" ]; then
    return 0
  fi

  return 1
}

add_prefix() {
  local candidate=$1
  local existing

  if ! is_valid_prefix "$candidate"; then
    return 0
  fi

  for existing in "${PREFIXES[@]}"; do
    if [ "$existing" = "$candidate" ]; then
      return 0
    fi
  done

  PREFIXES+=("$candidate")
  return 0
}

find_prefixes() {
  PREFIXES=()

  if [ -n "$PREFIX_OVERRIDE" ]; then
    add_prefix "$PREFIX_OVERRIDE"
    return 0
  fi

  if [ -n "${WINEPREFIX:-}" ]; then
    add_prefix "$WINEPREFIX"
  fi

  add_prefix "$HOME/.wine"

  if [ -d "$HOME/.local/share/wineprefixes" ]; then
    while IFS= read -r prefix_path; do
      add_prefix "$prefix_path"
    done < <(find "$HOME/.local/share/wineprefixes" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort -f)
  fi

  while IFS= read -r drive_c_dir; do
    add_prefix "${drive_c_dir%/drive_c}"
  done < <(find "$HOME" -maxdepth 4 -type d -name drive_c -print 2>/dev/null | sort -u)

  return 0
}

show_prefix_menu() {
  local i=1

  echo
  echo "Detected Wine prefixes:"
  for prefix_path in "${PREFIXES[@]}"; do
    echo "  $i) $prefix_path"
    ((i++))
  done
  echo
}

prompt_select_prefix() {
  if [ "${#PREFIXES[@]}" -eq 1 ]; then
    PREFIX=${PREFIXES[0]}
    _green "Using prefix: $PREFIX"
    return 0
  fi

  while true; do
    read -rp "Select prefix number to inspect (or 'q' to quit): " sel
    if [[ "$sel" =~ ^[Qq]$ ]]; then
      echo "Aborted."
      exit 0
    fi
    if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#PREFIXES[@]}" ]; then
      PREFIX="${PREFIXES[$((sel-1))]}"
      _green "Selected prefix: $PREFIX"
      return 0
    fi
    _yellow "Invalid selection. Try again."
  done
}

parse_registry_value() {
  local line=$1
  local value=${line#*=}

  if [[ $value =~ ^\"(.*)\"$ ]]; then
    value=${BASH_REMATCH[1]}
  fi

  value=${value//\\\\/\\}
  value=${value//\\\"/\"}
  value=${value//\\r/}
  value=${value//\\n/ }

  printf '%s\n' "$value"
}

winereg_parse_uninstall() {
  local prefix_path=$1
  local regfile
  local line
  local current_key=""
  local in_uninstall=0
  local display_name=""
  local uninstall_string=""
  local install_location=""
  local -a entries=()

  for regfile in "$prefix_path/system.reg" "$prefix_path/user.reg"; do
    [ -r "$regfile" ] || continue

    current_key=""
    in_uninstall=0
    display_name=""
    uninstall_string=""
    install_location=""

    while IFS= read -r line || [ -n "$line" ]; do
      if [[ $line =~ ^\[(.*)\]$ ]]; then
        if [ "$in_uninstall" -eq 1 ] && [ -n "$display_name" ]; then
          entries+=("$display_name|$uninstall_string|$install_location")
        fi

        current_key=${BASH_REMATCH[1]}
        display_name=""
        uninstall_string=""
        install_location=""

        if [[ "$current_key" == *\\Uninstall\\* ]]; then
          in_uninstall=1
        else
          in_uninstall=0
        fi
        continue
      fi

      [ "$in_uninstall" -eq 1 ] || continue

      case "$line" in
        \"DisplayName\"=*)
          display_name=$(parse_registry_value "$line")
          ;;
        \"UninstallString\"=*)
          uninstall_string=$(parse_registry_value "$line")
          ;;
        \"InstallLocation\"=*)
          install_location=$(parse_registry_value "$line")
          ;;
      esac
    done < "$regfile"

    if [ "$in_uninstall" -eq 1 ] && [ -n "$display_name" ]; then
      entries+=("$display_name|$uninstall_string|$install_location")
    fi
  done

  if [ "${#entries[@]}" -eq 0 ]; then
    return 0
  fi

  printf '%s\n' "${entries[@]}" \
    | awk -F'|' 'NF && !seen[tolower($1 FS $2 FS $3)]++' \
    | sort -t'|' -f -k1,1

  return 0
}

win_path_to_unix() {
  local prefix_path=$1
  local value=$2
  local drive_letter
  local rest
  local dosdevice
  local target

  value=${value#\"}
  value=${value%\"}

  if [[ $value =~ ^([A-Za-z]):\\(.*)$ ]]; then
    drive_letter=${BASH_REMATCH[1],,}
    rest=${BASH_REMATCH[2]//\\/\/}
    dosdevice="$prefix_path/dosdevices/${drive_letter}:"

    if [ -e "$dosdevice" ]; then
      target=$(readlink -f "$dosdevice" 2>/dev/null || true)
      if [ -n "$target" ]; then
        printf '%s/%s\n' "$target" "$rest"
        return 0
      fi
    fi

    printf '%s/drive_c/%s\n' "$prefix_path" "$rest"
    return 0
  fi

  if [[ $value = /* ]]; then
    printf '%s\n' "$value"
    return 0
  fi

  return 1
}

resolve_install_path() {
  local prefix_path=$1
  local loc=$2

  if [ -z "$loc" ]; then
    return 1
  fi

  if [ -e "$loc" ]; then
    printf '%s\n' "$loc"
    return 0
  fi

  if win_path_to_unix "$prefix_path" "$loc" >/dev/null 2>&1; then
    win_path_to_unix "$prefix_path" "$loc"
    return 0
  fi

  return 1
}

size_for_location() {
  local prefix_path=$1
  local loc=$2
  local resolved

  if ! resolved=$(resolve_install_path "$prefix_path" "$loc"); then
    printf '?\n'
    return 0
  fi

  if [ -n "${SIZE_CACHE[$resolved]:-}" ]; then
    printf '%s\n' "${SIZE_CACHE[$resolved]}"
    return 0
  fi

  if [ -e "$resolved" ]; then
    SIZE_CACHE[$resolved]=$(du -sh "$resolved" 2>/dev/null | awk '{print $1}')
  else
    SIZE_CACHE[$resolved]="?"
  fi

  printf '%s\n' "${SIZE_CACHE[$resolved]}"
}

collect_apps() {
  local line
  local name
  local uninstall_string
  local install_location
  local fallback_entry
  local -a fallback_entries=()

  APPS=()

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    IFS='|' read -r name uninstall_string install_location <<< "$line"
    name=$(sed -E 's/^[[:space:]]+|[[:space:]]+$//g' <<< "$name")
    [ -n "$name" ] || continue
    APPS+=("$name|$uninstall_string|$install_location")
  done < <(winereg_parse_uninstall "$PREFIX")

  if [ "${#APPS[@]}" -gt 0 ]; then
    return 0
  fi

  for program_dir in "$PREFIX/drive_c/Program Files" "$PREFIX/drive_c/Program Files (x86)"; do
    [ -d "$program_dir" ] || continue
    while IFS= read -r child_dir; do
      fallback_entries+=("$(basename "$child_dir")||$child_dir")
    done < <(find "$program_dir" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort -f)
  done

  if [ "${#fallback_entries[@]}" -eq 0 ]; then
    return 0
  fi

  while IFS= read -r fallback_entry; do
    [ -n "$fallback_entry" ] || continue
    APPS+=("$fallback_entry")
  done < <(printf '%s\n' "${fallback_entries[@]}" | awk -F'|' 'NF && !seen[tolower($1 FS $3)]++' | sort -t'|' -f -k1,1)

  return 0
}

show_apps_menu() {
  local i=1
  local entry
  local name
  local uninstall_string
  local install_location
  local size
  local method

  echo
  echo "Installed applications in prefix: $PREFIX"
  printf "%3s %-42s %-8s %s\n" "#" "Name" "Size" "Method"
  printf '%s\n' "--------------------------------------------------------------------------------"

  for entry in "${APPS[@]}"; do
    IFS='|' read -r name uninstall_string install_location <<< "$entry"
    size=$(size_for_location "$PREFIX" "$install_location")
    if [ -n "$uninstall_string" ]; then
      method="uninstaller"
    elif [ -n "$install_location" ]; then
      method="folder"
    else
      method="unknown"
    fi
    printf "%3s %-42s %-8s %s\n" "$i" "${name:0:42}" "$size" "$method"
    ((i++))
  done

  echo
}

prompt_select_apps() {
  local token
  local -a parsed_tokens=()
  local -A seen=()

  read -rp "Enter numbers to remove (space- or comma-separated), or 'q' to quit: " sel
  if [[ "$sel" =~ ^[Qq]$ ]]; then
    echo "Aborted."
    exit 0
  fi

  sel=${sel//,/ }
  TO_REMOVE=()
  IFS=' ' read -r -a parsed_tokens <<< "$sel"

  for token in "${parsed_tokens[@]}"; do
    if [[ "$token" =~ ^[0-9]+$ ]] && [ "$token" -ge 1 ] && [ "$token" -le "${#APPS[@]}" ]; then
      if [ -z "${seen[$token]:-}" ]; then
        TO_REMOVE+=("$((token-1))")
        seen[$token]=1
      fi
    fi
  done

  if [ "${#TO_REMOVE[@]}" -eq 0 ]; then
    _yellow "No valid selections were made."
    exit 0
  fi
}

run_command() {
  local description=$1
  shift

  if [ "$DRY_RUN" -eq 1 ]; then
    _yellow "(dry-run) $description"
    return 0
  fi

  if ! "$@"; then
    _yellow "Command failed: $description"
  fi
}

safe_remove_path() {
  local target=$1
  local resolved_target
  local resolved_prefix

  if [ ! -e "$target" ]; then
    return 0
  fi

  resolved_target=$(readlink -f "$target" 2>/dev/null || true)
  resolved_prefix=$(readlink -f "$PREFIX" 2>/dev/null || true)

  if [ -z "$resolved_target" ] || [ -z "$resolved_prefix" ]; then
    _yellow "Skipping unresolved path: $target"
    return 0
  fi

  if [[ "$resolved_target" != "$resolved_prefix"/* ]] || [ "$resolved_target" = "$resolved_prefix" ]; then
    _yellow "Skipping path outside the selected prefix: $resolved_target"
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    _yellow "(dry-run) rm -rf -- $resolved_target"
    return 0
  fi

  rm -rf -- "$resolved_target"
}

remove_desktop_entries() {
  local app_name=$1
  local wine_apps_root="$HOME/.local/share/applications/wine/Programs"
  local desktop_root="$HOME/Desktop"
  local desktop_file
  local shortcut

  if [ -d "$wine_apps_root" ]; then
    while IFS= read -r -d '' desktop_file; do
      if contains_text "$(basename "$desktop_file")" "$app_name" || contains_text "$(cat "$desktop_file" 2>/dev/null || true)" "$app_name"; then
        _yellow "Removing desktop entry: $desktop_file"
        if [ "$DRY_RUN" -eq 0 ]; then
          rm -f -- "$desktop_file"
        fi
      fi
    done < <(find "$wine_apps_root" -type f -name '*.desktop' -print0 2>/dev/null)
  fi

  if [ -d "$desktop_root" ]; then
    while IFS= read -r -d '' shortcut; do
      if contains_text "$(basename "$shortcut")" "$app_name" || contains_text "$(cat "$shortcut" 2>/dev/null || true)" "$app_name"; then
        _yellow "Removing desktop shortcut: $shortcut"
        if [ "$DRY_RUN" -eq 0 ]; then
          rm -f -- "$shortcut"
        fi
      fi
    done < <(find "$desktop_root" -maxdepth 1 -type f \( -name '*.desktop' -o -name '*.lnk' \) -print0 2>/dev/null)
  fi

  return 0
}

remove_menu_dirs() {
  local app_name=$1
  local wine_apps_root="$HOME/.local/share/applications/wine/Programs"
  local dir_path

  [ -d "$wine_apps_root" ] || return 0

  while IFS= read -r -d '' dir_path; do
    if contains_text "$(basename "$dir_path")" "$app_name"; then
      _yellow "Removing menu directory: $dir_path"
      if [ "$DRY_RUN" -eq 0 ]; then
        rm -rf -- "$dir_path"
      fi
    fi
  done < <(find "$wine_apps_root" -mindepth 1 -type d -print0 2>/dev/null)

  return 0
}

prune_empty_wine_dirs() {
  local apps_root="$HOME/.local/share/applications/wine"

  if [ -d "$apps_root" ] && [ "$DRY_RUN" -eq 0 ]; then
    find "$apps_root" -depth -type d -empty -delete 2>/dev/null || true
  fi

  return 0
}

refresh_local_caches() {
  if [ -d "$HOME/.local/share/applications" ] && command -v update-desktop-database >/dev/null 2>&1; then
    run_command "update-desktop-database ~/.local/share/applications" update-desktop-database "$HOME/.local/share/applications"
  fi

  if [ -d "$HOME/.local/share/mime" ] && command -v update-mime-database >/dev/null 2>&1; then
    run_command "update-mime-database ~/.local/share/mime" update-mime-database "$HOME/.local/share/mime"
  fi

  if [ -d "$HOME/.local/share/icons/hicolor" ] && command -v gtk-update-icon-cache >/dev/null 2>&1; then
    run_command "gtk-update-icon-cache -f ~/.local/share/icons/hicolor" gtk-update-icon-cache -f "$HOME/.local/share/icons/hicolor"
  fi

  return 0
}

wait_for_wine() {
  if command -v wineserver >/dev/null 2>&1; then
    if [ "$DRY_RUN" -eq 1 ]; then
      _yellow "(dry-run) wineserver -w"
      return 0
    fi
    env WINEPREFIX="$PREFIX" wineserver -w || true
  fi

  return 0
}

maybe_remove_leftover_install_dir() {
  local app_name=$1
  local install_location=$2
  local resolved_path

  if ! resolved_path=$(resolve_install_path "$PREFIX" "$install_location"); then
    return 0
  fi

  if [ ! -e "$resolved_path" ]; then
    return 0
  fi

  read -rp "Remove leftover install directory '$resolved_path' for '$app_name'? [y/N]: " answer
  if [[ "$answer" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    safe_remove_path "$resolved_path" || _yellow "Failed to remove $resolved_path"
  fi

  return 0
}

run_uninstaller() {
  local app_name=$1
  local uninstall_string=$2

  _yellow "Uninstall command found: $uninstall_string"
  read -rp "Run uninstaller for '$app_name'? [y/N]: " answer
  if ! [[ "$answer" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    _yellow "Skipped uninstaller for $app_name"
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    _yellow "(dry-run) WINEPREFIX=\"$PREFIX\" wine cmd /c \"$uninstall_string\""
    return 0
  fi

  if ! env WINEPREFIX="$PREFIX" wine cmd /c "$uninstall_string"; then
    _yellow "Uninstaller exited with a non-zero status."
  fi

  return 0
}

run_uninstall() {
  local entry=$1
  local app_name
  local uninstall_string
  local install_location
  local resolved_path

  IFS='|' read -r app_name uninstall_string install_location <<< "$entry"
  _green "Processing: $app_name"

  if [ -n "$uninstall_string" ]; then
    run_uninstaller "$app_name" "$uninstall_string"
    wait_for_wine
    maybe_remove_leftover_install_dir "$app_name" "$install_location"
  elif [ -n "$install_location" ]; then
    if resolved_path=$(resolve_install_path "$PREFIX" "$install_location"); then
      _yellow "No uninstaller was found. Candidate directory: $resolved_path"
      read -rp "Delete this directory now? [y/N]: " answer
      if [[ "$answer" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        safe_remove_path "$resolved_path" || _yellow "Failed to remove $resolved_path"
      else
        _yellow "Skipped manual removal for $app_name"
      fi
    else
      _yellow "No usable uninstall information for $app_name."
    fi
  else
    _yellow "No uninstall information for $app_name."
  fi

  remove_desktop_entries "$app_name"
  remove_menu_dirs "$app_name"
  prune_empty_wine_dirs
  return 0
}

main() {
  parse_flags "$@"
  check_not_root
  ensure_prereqs
  print_header

  if [ "$DRY_RUN" -eq 1 ]; then
    _yellow "Running in dry-run mode. No files or prefixes will be modified."
  fi

  find_prefixes
  if [ -n "$PREFIX_OVERRIDE" ] && [ "${#PREFIXES[@]}" -eq 0 ]; then
    _red "The path given to --prefix is not a valid Wine prefix: $PREFIX_OVERRIDE"
    exit 1
  fi
  if [ "${#PREFIXES[@]}" -eq 0 ]; then
    _red "No Wine prefixes were found."
    exit 1
  fi

  show_prefix_menu
  prompt_select_prefix

  collect_apps
  if [ "${#APPS[@]}" -eq 0 ]; then
    _yellow "No installed applications were detected in this prefix."
    exit 0
  fi

  show_apps_menu
  prompt_select_apps

  read -rp "Confirm uninstall of ${#TO_REMOVE[@]} selected app(s)? [y/N]: " final_answer
  if ! [[ "$final_answer" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    _yellow "Aborted by user."
    exit 0
  fi

  for app_index in "${TO_REMOVE[@]}"; do
    run_uninstall "${APPS[$app_index]}"
  done

  refresh_local_caches
  _green "Done."
}

main "$@"
