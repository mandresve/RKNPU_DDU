#!/usr/bin/env bash
# RKNPU_DDU — Device Driver Update Utility for Rockchip NPU
# Updates the NPU kernel driver (RK3588/RK3588S) on Orange Pi boards to v0.9.8.
# Distributed as a one-liner:  curl -fsSL <raw>/update.sh | sudo bash
set -u

readonly SELF_NAME="RKNPU_DDU"
readonly SELF_VERSION="1.0.0"
readonly REPO="mandresve/RKNPU_DDU"
readonly BRANCH="main"
RAW_BASE="${RKNPU_RAW_BASE:-https://raw.githubusercontent.com/${REPO}/${BRANCH}}"
readonly MANIFEST_URL="${RAW_BASE}/manifest.tsv"
readonly TARGET_FALLBACK="0.9.8"

readonly E_OK=0 E_GENERIC=1 E_UNSUPPORTED=2 E_VERSION=3 E_CHECKSUM=4 E_INSTALL=5

# Never let apt/dpkg block on an interactive prompt (would freeze the TUI).
export DEBIAN_FRONTEND=noninteractive

# globals set by parse_args
MODE="interactive"; DO_REBOOT="no"; DRY_RUN="no"

# ---------------------------------------------------------------------------
# Pure functions (testable, no system side effects)
# ---------------------------------------------------------------------------

# Extract X.Y.Z from a line like "RKNPU driver: v0.9.6". Empty + return 1 if none.
parse_driver_version() {
  local v
  v=$(printf '%s\n' "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}

# Read the model from RKNPU_MODEL_FILE (or /proc/device-tree/model), stripped of NUL/edges.
get_model() {
  local f="${RKNPU_MODEL_FILE:-/proc/device-tree/model}"
  [ -r "$f" ] || return 1
  tr -d '\000' < "$f" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# Read the hostname (lowercased, trimmed). On OrangePi images it is usually the
# model id (e.g. "orangepi5pro"), which we use as a detection fallback.
get_hostname() {
  local h
  if [ "${RKNPU_HOSTNAME+set}" = "set" ]; then
    h="$RKNPU_HOSTNAME"                       # explicit override ("" disables detection)
  else
    h=""
    if command -v hostname >/dev/null 2>&1; then h=$(hostname 2>/dev/null); fi
    if [ -z "$h" ] && [ -r /etc/hostname ]; then h=$(cat /etc/hostname 2>/dev/null); fi
    [ -n "$h" ] || h="${HOSTNAME:-}"
  fi
  printf '%s' "$h" | tr '[:upper:]' '[:lower:]' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# Classify the current version vs the target: uptodate | expected | unexpected.
version_state() {  # CURRENT TARGET
  if [ "$1" = "$2" ]; then echo "uptodate"
  elif [ "$1" = "0.9.6" ]; then echo "expected"
  else echo "unexpected"; fi
}

# True if STR is a valid sha256 (64 hex chars).
is_valid_sha256() {
  printf '%s' "$1" | grep -qiE '^[0-9a-f]{64}$'
}

# Find in FILE the first row whose detect_substr (col 2) matches MODEL.
# detect_substr may hold several '|'-separated alternatives (e.g.
# "OPi 5 Pro|Orange Pi 5 Pro"); the row matches if ANY alternative is a
# substring of MODEL. Print the row (tab-sep) and return 0; return 1 if none.
# Skips '#' and blank lines.
manifest_find_by_model() {  # FILE MODEL
  local file="$1" model="$2" line patterns alt
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    patterns=$(printf '%s' "$line" | cut -f2)
    [ -n "$patterns" ] || continue
    while [ -n "$patterns" ]; do
      case "$patterns" in
        *'|'*) alt=${patterns%%'|'*}; patterns=${patterns#*'|'} ;;
        *)     alt=$patterns; patterns='' ;;
      esac
      [ -n "$alt" ] || continue
      case "$model" in
        *"$alt"*) printf '%s\n' "$line"; return 0 ;;
      esac
    done
  done < "$file"
  return 1
}

# Fallback lookup: match HOSTNAME against the model id (col 1) as a substring.
# On OrangePi images the hostname is usually the model id (e.g. "orangepi5pro").
# Relies on the same specific-before-generic row ordering as detect_substr.
manifest_find_by_hostname() {  # FILE HOSTNAME
  local file="$1" host="$2" line mid
  [ -n "$host" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    mid=$(printf '%s' "$line" | cut -f1)
    [ -n "$mid" ] || continue
    case "$host" in
      *"$mid"*) printf '%s\n' "$line"; return 0 ;;
    esac
  done < "$file"
  return 1
}

# Exact lookup by model id (col 1). Used for manual board selection.
manifest_row_by_id() {  # FILE ID
  local file="$1" id="$2" line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    [ "$(printf '%s' "$line" | cut -f1)" = "$id" ] && { printf '%s\n' "$line"; return 0; }
  done < "$file"
  return 1
}

# Split a manifest row into ROW_* globals.
# ROW_DETECT is read positionally but unused (the match already happened in
# manifest_find_by_model); it is kept for column-layout clarity.
parse_row() {  # ROW (tab-separated)
  # shellcheck disable=SC2034  # ROW_DETECT reserved (positional column)
  IFS=$(printf '\t') read -r ROW_MODEL ROW_DETECT ROW_SOC ROW_PURGE \
    ROW_DEBPATH ROW_SHA ROW_TARGET ROW_STATUS <<EOF
$1
EOF
}

# Resolve the .deb download URL: absolute if it starts with http, else RAW_BASE/deb_path.
resolve_deb_url() {  # DEBPATH
  case "$1" in
    http://*|https://*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$RAW_BASE" "$1" ;;
  esac
}

# Compute the sha256 of FILE (sha256sum, or shasum -a 256 if missing).
_sha256_of() {  # FILE -> hash on stdout
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# True if the sha256 of FILE matches EXPECTED (case-insensitive).
verify_sha256() {  # FILE EXPECTED
  local got exp
  got=$(_sha256_of "$1" | tr 'A-F' 'a-f')
  exp=$(printf '%s' "$2" | tr 'A-F' 'a-f')
  [ -n "$got" ] && [ "$got" = "$exp" ]
}

# ---------------------------------------------------------------------------
# UI layer: whiptail -> dialog -> plain text; 'auto' in non-interactive mode.
# All TUI reads/writes /dev/tty because stdin is taken by the curl|bash pipe.
# ---------------------------------------------------------------------------

UI_BACKEND="plain"

detect_ui() {
  if [ "$MODE" = "auto" ]; then UI_BACKEND="auto"; return; fi
  if command -v whiptail >/dev/null 2>&1; then UI_BACKEND="whiptail"
  elif command -v dialog >/dev/null 2>&1; then UI_BACKEND="dialog"
  else UI_BACKEND="plain"; fi
}

ui_info() {  # TITLE MSG
  case "$UI_BACKEND" in
    whiptail) whiptail --title "$1" --msgbox "$2" 20 78 </dev/tty >/dev/tty 2>&1 ;;
    dialog)   dialog --title "$1" --msgbox "$2" 20 78 </dev/tty >/dev/tty 2>&1 ;;
    *)        printf '\n=== %s ===\n%s\n' "$1" "$2" ;;
  esac
}

ui_error() {  # MSG
  case "$UI_BACKEND" in
    whiptail) whiptail --title "Error" --msgbox "$1" 12 78 </dev/tty >/dev/tty 2>&1 ;;
    dialog)   dialog --title "Error" --msgbox "$1" 12 78 </dev/tty >/dev/tty 2>&1 ;;
    *)        printf '\nERROR: %s\n' "$1" >&2 ;;
  esac
}

ui_yesno() {  # TITLE MSG DEFAULT(yes|no)
  local df
  case "$UI_BACKEND" in
    auto) [ "${3:-yes}" = "yes" ] ;;  # auto assumes the default
    whiptail)
      df=""; [ "${3:-yes}" = "no" ] && df="--defaultno"
      # shellcheck disable=SC2086
      whiptail --title "$1" $df --yesno "$2" 15 78 </dev/tty >/dev/tty 2>&1 ;;
    dialog)
      df=""; [ "${3:-yes}" = "no" ] && df="--defaultno"
      # shellcheck disable=SC2086
      dialog --title "$1" $df --yesno "$2" 15 78 </dev/tty >/dev/tty 2>&1 ;;
    plain)
      local ans hint="[Y/n]"; [ "${3:-yes}" = "no" ] && hint="[y/N]"
      printf '\n%s\n%s %s ' "$1" "$2" "$hint" >/dev/tty
      read -r ans </dev/tty || ans=""
      case "$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')" in
        y|yes) return 0 ;;
        n|no)  return 1 ;;
        '')    [ "${3:-yes}" = "yes" ] ;;
        *)     return 1 ;;
      esac ;;
  esac
}

# Show a menu (whiptail/dialog only) and echo the chosen tag. Non-zero if
# cancelled or unavailable. Args: TITLE TEXT MENUHEIGHT tag item [tag item ...]
_menu() {
  local title="$1" text="$2" mh="$3"; shift 3
  case "$UI_BACKEND" in
    whiptail) whiptail --title "$title" --menu "$text" 20 74 "$mh" "$@" 3>&1 1>&2 2>&3 </dev/tty ;;
    dialog)   dialog   --title "$title" --menu "$text" 20 74 "$mh" "$@" 3>&1 1>&2 2>&3 </dev/tty ;;
    *)        return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Functions with system side effects (covered by dry-run + on-device testing)
# ---------------------------------------------------------------------------

# Read the current NPU driver version. echo version, or empty + return 1.
get_current_version() {
  local f="${RKNPU_VERSION_FILE:-/sys/kernel/debug/rknpu/version}" raw
  if [ ! -r "$f" ] && [ -z "${RKNPU_VERSION_FILE:-}" ]; then
    mount -t debugfs none /sys/kernel/debug >/dev/null 2>&1 || true
  fi
  [ -r "$f" ] || return 1
  raw=$(cat "$f" 2>/dev/null) || return 1
  parse_driver_version "$raw"
}

# Obtain the manifest (local via RKNPU_MANIFEST_FILE, or download to DEST). echo its path.
fetch_manifest() {  # DEST
  if [ -n "${RKNPU_MANIFEST_FILE:-}" ]; then
    printf '%s\n' "$RKNPU_MANIFEST_FILE"; return 0
  fi
  curl -fsSL "$MANIFEST_URL" -o "$1" || return 1
  printf '%s\n' "$1"
}

download_file() {  # URL DEST (low-level worker for the plain/auto path)
  curl -fSL --progress-bar "$1" -o "$2"
}

do_install() {  # PURGE_PKG DEB (low-level worker; caller captures its output)
  echo ">> apt purge -y $1"
  apt purge -y "$1" || return 1
  echo ">> dpkg -i $2"
  dpkg -i "$2" || return 1
}

# Format the device list as text (embedded in a TUI box, or printed plainly).
device_list_text() {  # FILE
  printf 'Supported / planned devices:\n'
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    printf '  - %-18s [%s]\n' "$(printf '%s' "$line" | cut -f1)" \
                              "$(printf '%s' "$line" | cut -f8)"
  done < "$1"
}

maybe_reboot() {
  case "$UI_BACKEND" in
    whiptail) whiptail --infobox "Rebooting now..." 7 44 </dev/tty >/dev/tty 2>&1 ;;
    dialog)   dialog --infobox "Rebooting now..." 7 44 </dev/tty >/dev/tty 2>&1 ;;
    *)        echo "Rebooting..." ;;
  esac
  reboot
}

# ---------------------------------------------------------------------------
# TUI progress: in whiptail/dialog everything (download, purge, dpkg, copy
# messages) is shown inside the TUI and nothing leaks to the console. In
# plain/auto mode the console workers are used as before.
# ---------------------------------------------------------------------------

# Render a gauge that reads the gauge protocol (percent + message) on stdin.
_gauge_box() {  # TITLE
  case "$UI_BACKEND" in
    whiptail) whiptail --title "$1" --gauge "Starting..." 9 74 0 2>/dev/tty ;;
    dialog)   dialog --title "$1" --gauge "Starting..." 9 74 0 2>/dev/tty ;;
  esac
}

# Show a scrollable text file in the TUI (used for the install log on failure).
_show_textbox() {  # TITLE FILE
  case "$UI_BACKEND" in
    whiptail) whiptail --title "$1" --scrolltext --textbox "$2" 25 78 </dev/tty >/dev/tty 2>&1 ;;
    dialog)   dialog --title "$1" --textbox "$2" 25 78 </dev/tty >/dev/tty 2>&1 ;;
  esac
}

# Download URL to DEST: real-percentage gauge in TUI, console otherwise.
ui_download() {  # URL DEST
  case "$UI_BACKEND" in
    whiptail|dialog) _download_gauge "$1" "$2" ;;
    *) echo "Downloading ${2##*/}..."; download_file "$1" "$2" ;;
  esac
}

_download_gauge() {  # URL DEST
  local url="$1" dest="$2" total got pct=0
  total=$(curl -fsSLI "$url" 2>/dev/null | tr -d '\r' \
            | awk -F': ' 'tolower($1)=="content-length"{v=$2} END{print v}')
  curl -fsSL "$url" -o "$dest" 2>/dev/null &
  local pid=$!
  {
    while kill -0 "$pid" 2>/dev/null; do
      got=$(wc -c <"$dest" 2>/dev/null); got=$(( ${got:-0} ))
      if [ -n "$total" ] && [ "$total" -gt 0 ] 2>/dev/null; then
        pct=$(( got * 100 / total )); [ "$pct" -gt 100 ] && pct=100
      else
        pct=$(( (pct + 7) % 100 ))
      fi
      printf 'XXX\n%s\nDownloading %s\n%s / %s bytes\nXXX\n' \
             "$pct" "${dest##*/}" "$got" "${total:-?}"
      sleep 0.3
    done
    printf 'XXX\n100\nDownloading %s\nComplete.\nXXX\n' "${dest##*/}"
  } | _gauge_box "Download"
  wait "$pid"
}

# Run the install (purge + dpkg) with all output to a log, showing a live gauge
# whose message follows the latest log line; show the full log if it fails.
ui_install() {  # PURGE_PKG DEB
  case "$UI_BACKEND" in
    whiptail|dialog) : ;;
    *) do_install "$1" "$2"; return "$?" ;;
  esac
  local log pid pct=0 line rc
  log="${2%/*}/install.log"; : > "$log"
  ( do_install "$1" "$2" >>"$log" 2>&1 </dev/null ) &
  pid=$!
  {
    while kill -0 "$pid" 2>/dev/null; do
      line=$(tail -n1 "$log" 2>/dev/null | tr -d '\r' | cut -c1-64)
      printf 'XXX\n%s\nInstalling the new kernel (do not power off)...\n%s\nXXX\n' \
             "$pct" "${line:-working...}"
      pct=$(( (pct + 7) % 100 ))
      sleep 0.4
    done
    printf 'XXX\n100\nInstalling the new kernel...\nFinished.\nXXX\n'
  } | _gauge_box "Installing"
  wait "$pid"; rc=$?
  [ "$rc" -ne 0 ] && [ -s "$log" ] && _show_textbox "Installation log (failed)" "$log"
  return "$rc"
}

# Menu of the supported boards; echo the chosen model id. Non-zero if cancelled
# or no menu backend. Used to correct a wrong auto-detection (interactive only).
board_menu() {  # FILE
  local line mid soc st
  set --
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    st=$(printf '%s' "$line" | cut -f8)
    [ "$st" = "supported" ] || continue
    mid=$(printf '%s' "$line" | cut -f1)
    soc=$(printf '%s' "$line" | cut -f3)
    set -- "$@" "$mid" "$soc"
  done < "$1"
  [ "$#" -gt 0 ] || return 1
  _menu "Select your board" "Pick the board that matches your hardware:" 8 "$@"
}

# Ask what to do next; echo one of: proceed | choose | cancel.
# --auto always proceeds; plain mode offers only proceed/cancel.
confirm_action() {
  [ "$MODE" = "auto" ] && { echo proceed; return 0; }
  case "$UI_BACKEND" in
    whiptail|dialog)
      local c
      if c=$(_menu "$SELF_NAME" "What would you like to do?" 3 \
               proceed "Update this board: $ROW_MODEL" \
               choose  "Choose a different board (wrong detection?)" \
               cancel  "Cancel -- make no changes"); then
        echo "${c:-cancel}"
      else
        echo cancel
      fi ;;
    *)
      if ui_yesno "$SELF_NAME" "Continue with this update?" "yes"; then
        echo proceed
      else
        echo cancel
      fi ;;
  esac
}

preflight() {
  if [ "$MODE" != "auto" ] && [ ! -e /dev/tty ]; then
    echo "No TTY available: use --auto for non-interactive mode." >&2; exit "$E_GENERIC"
  fi
  if [ "$DRY_RUN" != "yes" ]; then
    [ "$(id -u)" -eq 0 ] || { echo "Root required (use sudo)." >&2; exit "$E_GENERIC"; }
    case "$(uname -m)" in
      aarch64|arm64) ;;
      *) echo "Unsupported architecture (aarch64 expected)." >&2; exit "$E_GENERIC" ;;
    esac
  fi
  command -v curl >/dev/null 2>&1 || { echo "curl is missing." >&2; exit "$E_GENERIC"; }
}

usage() {
  cat <<EOF
${SELF_NAME} v${SELF_VERSION} — updates the NPU driver (RK3588/RK3588S) to v0.9.8

Usage:
  # Interactive (TUI): download, then run locally (piping can't reach the TUI)
  curl -fsSL ${RAW_BASE}/update.sh -o /tmp/rknpu.sh && sudo bash /tmp/rknpu.sh

  # Automatic (scripted): piping is fine, no terminal needed
  curl -fsSL ${RAW_BASE}/update.sh | sudo bash -s -- --auto

Flags:
  --auto       Non-interactive: no TUI, assume "yes". Does not reboot unless --reboot.
  --reboot     Reboot when finished (useful with --auto).
  --dry-run    Show what would happen; download nothing, change nothing.
  --version    Print the version and exit.
  --help       Show this help and exit.
EOF
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --auto)    MODE="auto" ;;
      --reboot)  DO_REBOOT="yes" ;;
      --dry-run) DRY_RUN="yes" ;;
      --version) echo "${SELF_NAME} v${SELF_VERSION}"; exit "$E_OK" ;;
      --help|-h) usage; exit "$E_OK" ;;
      *) echo "Unknown flag: $1" >&2; usage >&2; exit "$E_GENERIC" ;;
    esac
    shift
  done
}

# The interactive TUI must run from a LOCAL FILE. A piped `curl | sudo bash`
# gives sudo a pseudo-terminal fed by the pipe (sudo's stdin), not by the
# keyboard, so /dev/tty cannot receive input and the TUI hangs. Running from a
# downloaded file makes sudo's stdin the real terminal, so the keyboard works.
# Detect file-vs-pipe with BASH_SOURCE (empty when piped) -- NOT `[ -t 0 ]`,
# which is fooled by sudo's use_pty. If piped and interactive, print the
# two-step command and exit instead of hanging. (--auto needs no terminal.)
require_local_run() {
  [ "$MODE" = "auto" ] && return 0
  local src="${BASH_SOURCE[0]:-}"
  [ -n "$src" ] && [ -f "$src" ] && return 0
  printf '%s\n' \
"RKNPU_DDU: interactive mode must run from a local file. A piped
'curl | sudo bash' cannot reach the keyboard for the TUI, so please
download first and then run it:

  curl -fsSL ${RAW_BASE}/update.sh -o /tmp/rknpu.sh
  sudo bash /tmp/rknpu.sh

For non-interactive/scripted use, piping is fine:
  curl -fsSL ${RAW_BASE}/update.sh | sudo bash -s -- --auto" >&2
  exit "$E_GENERIC"
}

main() {
  parse_args "$@"
  require_local_run
  detect_ui
  preflight

  # Welcome / expectations (interactive only; scripts don't need the banner).
  if [ "$MODE" = "interactive" ]; then
    ui_info "$SELF_NAME" \
"RKNPU_DDU updates the Rockchip NPU (RK3588/RK3588S) kernel driver on Orange Pi
boards to v0.9.8, which newer RKLLM models require.

How it works:
 - It REPLACES the kernel image package with a prebuilt one that ships the
   updated driver. A reboot is needed afterwards to load it.
 - It first downloads the correct package for your board and verifies its
   checksum. If the checksum does not match, it aborts and leaves the system
   untouched.
 - Nothing is changed until you confirm.

Your files, applications and settings are NOT modified -- only the kernel image
package is replaced."
  fi

  local tmp; tmp=$(mktemp -d "${TMPDIR:-/tmp}/rknpu.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT

  local manifest
  manifest=$(fetch_manifest "$tmp/manifest.tsv") \
    || { ui_error "Could not fetch the manifest."; exit "$E_GENERIC"; }

  # Identify the board: device-tree model first (hardware truth), hostname fallback.
  local model host row detect_source detect_value
  model=$(get_model) || model=""
  host=$(get_hostname) || host=""
  if [ -n "$model" ] && row=$(manifest_find_by_model "$manifest" "$model"); then
    detect_source="device-tree model"; detect_value="$model"
  elif [ -n "$host" ] && row=$(manifest_find_by_hostname "$manifest" "$host"); then
    detect_source="hostname"; detect_value="$host"
  else
    row=""
  fi
  [ -n "$row" ] && parse_row "$row"

  # If detection failed or landed on an unsupported row, offer a manual pick
  # (whiptail/dialog only); otherwise report it and exit.
  if [ -z "$row" ] || [ "$ROW_STATUS" != "supported" ]; then
    local why
    if [ -z "$row" ]; then
      why="Could not identify this board automatically.
  device-tree model: ${model:-<unreadable>}
  hostname         : ${host:-<unknown>}"
    else
      why="Detected '$ROW_MODEL' (via $detect_source), but it is not supported yet
(status: $ROW_STATUS). No package is available for it in this release."
    fi
    case "$UI_BACKEND" in
      whiptail|dialog)
        ui_info "$SELF_NAME" "$why

You can pick your board manually on the next screen."
        local pick
        if pick=$(board_menu "$manifest") && [ -n "$pick" ] && row=$(manifest_row_by_id "$manifest" "$pick"); then
          parse_row "$row"; detect_source="manual selection"; detect_value="$pick"
        else
          ui_info "$SELF_NAME" "No board selected. Nothing was changed."
          exit "$E_UNSUPPORTED"
        fi ;;
      *)
        ui_info "$SELF_NAME" "$why

$(device_list_text "$manifest")"
        exit "$E_UNSUPPORTED" ;;
    esac
  fi

  # Current driver version (board-independent).
  local target current state
  current=$(get_current_version) \
    || { ui_error \
"Could not read the current driver version from
/sys/kernel/debug/rknpu/version (is the NPU present? are you root?)."; exit "$E_VERSION"; }
  target="${ROW_TARGET:-$TARGET_FALLBACK}"
  state=$(version_state "$current" "$target")
  case "$state" in
    uptodate)
      ui_info "$SELF_NAME" "Your NPU driver is already at v$current. Nothing to do."
      exit "$E_OK" ;;
    unexpected)
      ui_yesno "Unexpected version" \
"The current driver is v$current, but this updater expects v0.9.6.
It can still install v$target, but this path is untested for your version.

Continue anyway?" "no" \
        || { ui_info "$SELF_NAME" "Cancelled. Nothing was changed."; exit "$E_OK"; } ;;
    expected) : ;;
  esac

  # Plan summary + confirmation, with an option to correct a wrong detection.
  local url deb debname action
  deb="$tmp/update.deb"
  while :; do
    parse_row "$row"
    target="${ROW_TARGET:-$TARGET_FALLBACK}"
    is_valid_sha256 "$ROW_SHA" \
      || { ui_error "Incomplete manifest for $ROW_MODEL (invalid sha256)."; exit "$E_GENERIC"; }
    url=$(resolve_deb_url "$ROW_DEBPATH")
    debname=${ROW_DEBPATH##*/}

    ui_info "$SELF_NAME" \
"Update summary
--------------
Board             : $ROW_MODEL ($ROW_SOC)
Identified by     : $detect_source ($detect_value)
Current driver    : v$current
Target driver     : v$target
Package to remove : $ROW_PURGE
New package       : $debname

When you continue, RKNPU_DDU will:
 1. Download the package and verify its checksum.
 2. Remove the current kernel package and install the new one.
 3. Ask you to reboot (required to load v$target).

It will NOT touch your files, home directory or configuration."

    action=$(confirm_action)
    case "$action" in
      proceed) break ;;
      choose)
        local pick2 nr
        if pick2=$(board_menu "$manifest") && [ -n "$pick2" ] && nr=$(manifest_row_by_id "$manifest" "$pick2"); then
          row="$nr"; detect_source="manual selection"; detect_value="$pick2"
        fi
        continue ;;
      *) ui_info "$SELF_NAME" "Cancelled. Nothing was changed."; exit "$E_OK" ;;
    esac
  done

  if [ "$DRY_RUN" = "yes" ]; then
    ui_info "$SELF_NAME" \
"[dry-run] No changes will be made.
Would download : $url
Would verify   : sha256 $ROW_SHA
Would run      : apt purge -y $ROW_PURGE && dpkg -i <deb>
Reboot         : $DO_REBOOT"
    exit "$E_OK"
  fi

  ui_download "$url" "$deb" \
    || { ui_error "Failed to download the package."; exit "$E_GENERIC"; }
  verify_sha256 "$deb" "$ROW_SHA" \
    || { ui_error "The package checksum does NOT match. Aborting without touching the kernel."; exit "$E_CHECKSUM"; }

  ui_yesno "Ready to install" \
"The package was downloaded and its checksum verified.

This is the point of no return: RKNPU_DDU will now remove
'$ROW_PURGE' and install the new kernel. A reboot will be required afterwards.

Proceed with the installation?" "yes" \
    || { ui_info "$SELF_NAME" "Cancelled before installing. Nothing was changed."; exit "$E_OK"; }

  if ! ui_install "$ROW_PURGE" "$deb"; then
    ui_error \
"Installation failed. Recover the previous kernel with:
  sudo apt-get install -y $ROW_PURGE"
    exit "$E_INSTALL"
  fi

  ui_info "$SELF_NAME" \
"Done. The new kernel for $ROW_MODEL (driver v$target) is installed.

Reboot to load it. After rebooting you can re-run RKNPU_DDU, or check:
  sudo cat /sys/kernel/debug/rknpu/version
It should report v$target."

  if [ "$MODE" = "auto" ]; then
    [ "$DO_REBOOT" = "yes" ] && maybe_reboot
  else
    ui_yesno "Reboot" "Reboot now to load the new driver?" "yes" && maybe_reboot
  fi
  exit "$E_OK"
}

if [ -z "${RKNPU_SOURCE_ONLY:-}" ]; then
  main "$@"
fi
