#!/usr/bin/env bash
# RKNPU_DDU — Device Driver Update Utility for Rockchip NPU
# Updates the NPU kernel driver (RK3588/RK3588S) on Orange Pi boards to v0.9.8.
# Distributed as a one-liner:  curl -fsSL <raw>/update.sh | sudo bash
set -u

readonly SELF_NAME="RKNPU_DDU"
readonly SELF_VERSION="1.0.0"
readonly REPO="mandresve/RKNPU_DDU"
readonly BRANCH="master"
RAW_BASE="${RKNPU_RAW_BASE:-https://raw.githubusercontent.com/${REPO}/${BRANCH}}"
readonly MANIFEST_URL="${RAW_BASE}/manifest.tsv"
readonly TARGET_FALLBACK="0.9.8"

readonly E_OK=0 E_GENERIC=1 E_UNSUPPORTED=2 E_VERSION=3 E_CHECKSUM=4 E_INSTALL=5

# globals set by parse_args
MODE="interactive"; DO_REBOOT="no"; DRY_RUN="no"
SELF_TMP=""   # temp copy of ourselves when re-exec'd for the TUI (see maybe_reexec_for_tui)

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

download_file() {  # URL DEST
  curl -fSL --progress-bar "$1" -o "$2"
}

# List the manifest devices with their status.
show_device_list() {  # FILE
  printf '\nDevices:\n'
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    printf '  - %-16s [%s]\n' "$(printf '%s' "$line" | cut -f1)" \
                              "$(printf '%s' "$line" | cut -f8)"
  done < "$1"
}

do_install() {  # PURGE_PKG DEB
  echo ">> apt purge -y $1"
  apt purge -y "$1" || return 1
  echo ">> dpkg -i $2"
  dpkg -i "$2" || return 1
}

maybe_reboot() {
  echo "Rebooting..."
  reboot
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

Usage (one-liner):
  curl -fsSL ${RAW_BASE}/update.sh | sudo bash                 # interactive (TUI)
  curl -fsSL ${RAW_BASE}/update.sh | sudo bash -s -- --auto    # automatic

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

# Under `curl | sudo bash`, this script's stdin is the pipe carrying the script
# itself. whiptail/dialog can show the first dialog (via </dev/tty) but the next
# ones hang. For a reliable TUI, re-download ourselves to a temp file and re-exec
# with stdin attached to the terminal (running as a plain file works fine).
# Skipped for --auto, when already re-exec'd, or when stdin is already a terminal.
maybe_reexec_for_tui() {  # "$@" = original args
  [ "$MODE" = "auto" ] && return 0
  [ -n "${RKNPU_REEXEC:-}" ] && return 0
  [ -t 0 ] && return 0
  [ -e /dev/tty ] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  local self
  self=$(mktemp "${TMPDIR:-/tmp}/rknpu-self.XXXXXX") || return 0
  if curl -fsSL "${RAW_BASE}/update.sh" -o "$self" 2>/dev/null && [ -s "$self" ]; then
    export RKNPU_REEXEC=1
    exec bash "$self" "$@" </dev/tty
  fi
  rm -f "$self"
  ui_error \
"The interactive TUI needs a real terminal, but the script is being piped
(curl | bash) and I could not re-download myself. Run it in two steps:

  curl -fsSL ${RAW_BASE}/update.sh -o /tmp/rknpu.sh
  sudo bash /tmp/rknpu.sh

Or run non-interactively:  ... | sudo bash -s -- --auto"
  exit "$E_GENERIC"
}

main() {
  parse_args "$@"
  maybe_reexec_for_tui "$@"
  [ -n "${RKNPU_REEXEC:-}" ] && SELF_TMP="$0"
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
  trap 'rm -rf "$tmp"; [ -n "$SELF_TMP" ] && rm -f "$SELF_TMP"' EXIT

  local manifest
  manifest=$(fetch_manifest "$tmp/manifest.tsv") \
    || { ui_error "Could not fetch the manifest."; exit "$E_GENERIC"; }

  # Identify the board: device-tree model first (hardware truth), hostname as fallback.
  local model host row detect_source detect_value
  model=$(get_model) || model=""
  host=$(get_hostname) || host=""
  if [ -n "$model" ] && row=$(manifest_find_by_model "$manifest" "$model"); then
    detect_source="device-tree model"; detect_value="$model"
  elif [ -n "$host" ] && row=$(manifest_find_by_hostname "$manifest" "$host"); then
    detect_source="hostname"; detect_value="$host"
  else
    ui_info "$SELF_NAME" \
"Could not identify this board as a supported model.
  device-tree model: ${model:-<unreadable>}
  hostname         : ${host:-<unknown>}

Supported boards are listed below."
    show_device_list "$manifest"
    exit "$E_UNSUPPORTED"
  fi

  parse_row "$row"
  if [ "$ROW_STATUS" != "supported" ]; then
    ui_info "$SELF_NAME" \
"Detected '$ROW_MODEL' (via $detect_source), but it is not supported yet
(status: $ROW_STATUS). No package is available for it in this release."
    show_device_list "$manifest"
    exit "$E_UNSUPPORTED"
  fi

  local target="${ROW_TARGET:-$TARGET_FALLBACK}" current state
  current=$(get_current_version) \
    || { ui_error \
"Could not read the current driver version from
/sys/kernel/debug/rknpu/version (is the NPU present? are you root?)."; exit "$E_VERSION"; }
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

  is_valid_sha256 "$ROW_SHA" \
    || { ui_error "Incomplete manifest for $ROW_MODEL (invalid sha256)."; exit "$E_GENERIC"; }

  local url deb debname
  url=$(resolve_deb_url "$ROW_DEBPATH")
  deb="$tmp/update.deb"
  debname=${ROW_DEBPATH##*/}

  # Explicit plan summary (shown as a dialog interactively; logged in --auto).
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

  ui_yesno "$SELF_NAME" "Continue with this update?" "yes" \
    || { ui_info "$SELF_NAME" "Cancelled. Nothing was changed."; exit "$E_OK"; }

  if [ "$DRY_RUN" = "yes" ]; then
    echo "[dry-run] Would download: $url"
    echo "[dry-run] Would verify sha256: $ROW_SHA"
    echo "[dry-run] apt purge -y $ROW_PURGE && dpkg -i <deb>"
    echo "[dry-run] Reboot: $DO_REBOOT"
    exit "$E_OK"
  fi

  echo "Downloading $ROW_MODEL ($debname)..."
  download_file "$url" "$deb" \
    || { ui_error "Failed to download the package."; exit "$E_GENERIC"; }
  verify_sha256 "$deb" "$ROW_SHA" \
    || { ui_error "The package checksum does NOT match. Aborting without touching the kernel."; exit "$E_CHECKSUM"; }

  ui_yesno "Ready to install" \
"The package was downloaded and its checksum verified.

This is the point of no return: RKNPU_DDU will now remove
'$ROW_PURGE' and install the new kernel. A reboot will be required afterwards.

Proceed with the installation?" "yes" \
    || { ui_info "$SELF_NAME" "Cancelled before installing. Nothing was changed."; exit "$E_OK"; }

  if ! do_install "$ROW_PURGE" "$deb"; then
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
