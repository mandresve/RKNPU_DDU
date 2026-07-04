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

# Find in FILE the first row whose detect_substr (col 2) is a substring of MODEL.
# Print the row (tab-sep) and return 0; return 1 if none. Skips '#' and blank lines.
manifest_find_by_model() {  # FILE MODEL
  local file="$1" model="$2" line substr
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    substr=$(printf '%s' "$line" | cut -f2)
    [ -n "$substr" ] || continue
    case "$model" in
      *"$substr"*) printf '%s\n' "$line"; return 0 ;;
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
    whiptail) whiptail --title "$1" --msgbox "$2" 15 78 </dev/tty >/dev/tty 2>&1 ;;
    dialog)   dialog --title "$1" --msgbox "$2" 15 78 </dev/tty >/dev/tty 2>&1 ;;
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
      whiptail --title "$1" $df --yesno "$2" 12 78 </dev/tty >/dev/tty 2>&1 ;;
    dialog)
      df=""; [ "${3:-yes}" = "no" ] && df="--defaultno"
      # shellcheck disable=SC2086
      dialog --title "$1" $df --yesno "$2" 12 78 </dev/tty >/dev/tty 2>&1 ;;
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

main() {
  parse_args "$@"
  detect_ui
  preflight

  local tmp; tmp=$(mktemp -d "${TMPDIR:-/tmp}/rknpu.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT

  local manifest
  manifest=$(fetch_manifest "$tmp/manifest.tsv") \
    || { ui_error "Could not fetch the manifest."; exit "$E_GENERIC"; }

  local model
  model=$(get_model) \
    || { ui_error "Could not read /proc/device-tree/model."; exit "$E_UNSUPPORTED"; }

  local row
  if ! row=$(manifest_find_by_model "$manifest" "$model"); then
    ui_info "$SELF_NAME" "Unrecognized device: $model"
    show_device_list "$manifest"
    exit "$E_UNSUPPORTED"
  fi
  parse_row "$row"
  if [ "$ROW_STATUS" != "supported" ]; then
    ui_info "$SELF_NAME" "Detected '$ROW_MODEL' but it is not supported yet (status: $ROW_STATUS)."
    show_device_list "$manifest"
    exit "$E_UNSUPPORTED"
  fi

  ui_yesno "$SELF_NAME" "Detected device: $ROW_MODEL ($ROW_SOC). Continue?" "yes" \
    || exit "$E_OK"

  local target="${ROW_TARGET:-$TARGET_FALLBACK}" current state
  current=$(get_current_version) \
    || { ui_error "Could not read the driver version (NPU present? root?)."; exit "$E_VERSION"; }
  state=$(version_state "$current" "$target")
  case "$state" in
    uptodate)
      ui_info "$SELF_NAME" "Already at v$current. Nothing to do."
      exit "$E_OK" ;;
    unexpected)
      ui_yesno "Unexpected version" \
        "Current version v$current (0.9.6 expected). Update to v$target anyway?" "no" \
        || exit "$E_OK" ;;
    expected) : ;;
  esac

  is_valid_sha256 "$ROW_SHA" \
    || { ui_error "Incomplete manifest for $ROW_MODEL (invalid sha256)."; exit "$E_GENERIC"; }

  local url deb
  url=$(resolve_deb_url "$ROW_DEBPATH")
  deb="$tmp/update.deb"

  if [ "$DRY_RUN" = "yes" ]; then
    echo "[dry-run] Would download: $url"
    echo "[dry-run] Would verify sha256: $ROW_SHA"
    echo "[dry-run] apt purge -y $ROW_PURGE && dpkg -i <deb>"
    echo "[dry-run] Reboot: $DO_REBOOT"
    exit "$E_OK"
  fi

  echo "Downloading $ROW_MODEL (v$current -> v$target)..."
  download_file "$url" "$deb" \
    || { ui_error "Failed to download the .deb."; exit "$E_GENERIC"; }
  verify_sha256 "$deb" "$ROW_SHA" \
    || { ui_error "The .deb checksum does NOT match. Aborting without touching the kernel."; exit "$E_CHECKSUM"; }

  ui_yesno "Destructive action" \
    "About to purge '$ROW_PURGE' and install the new kernel. A reboot is required. Proceed?" "yes" \
    || exit "$E_OK"

  if ! do_install "$ROW_PURGE" "$deb"; then
    ui_error "Installation failed. Recover with: sudo apt-get install -y $ROW_PURGE"
    exit "$E_INSTALL"
  fi

  ui_info "$SELF_NAME" "Installed. Reboot to apply; on the next run you will see v$target."
  if [ "$MODE" = "auto" ]; then
    [ "$DO_REBOOT" = "yes" ] && maybe_reboot
  else
    ui_yesno "Reboot" "Reboot now?" "yes" && maybe_reboot
  fi
  exit "$E_OK"
}

if [ -z "${RKNPU_SOURCE_ONLY:-}" ]; then
  main "$@"
fi
