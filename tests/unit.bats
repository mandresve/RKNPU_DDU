#!/usr/bin/env bats

setup() { load "test_helper"; }

# --- Task 1: args / usage ---

@test "usage exits 0 with --help" {
  run bash update.sh --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"RKNPU_DDU"* ]]
}

@test "--version prints the version and exits 0" {
  run bash update.sh --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"v1.0.0"* ]]
}

@test "unknown flag exits 1" {
  run bash update.sh --nope
  [ "$status" -eq 1 ]
}

@test "parse_args sets MODE=auto" {
  load_update
  parse_args --auto
  [ "$MODE" = "auto" ]
}

# --- Task 2: version / model ---

@test "parse_driver_version extracts 0.9.6" {
  load_update
  run parse_driver_version "RKNPU driver: v0.9.6"
  [ "$status" -eq 0 ]; [ "$output" = "0.9.6" ]
}

@test "parse_driver_version fails when there is no version" {
  load_update
  run parse_driver_version "no version here"
  [ "$status" -ne 0 ]
}

@test "get_model trims NUL and whitespace" {
  load_update
  RKNPU_MODEL_FILE="$FIXTURES/model_5pro" run get_model
  [ "$output" = "Orange Pi 5 Pro" ]
}

@test "version_state detects uptodate/expected/unexpected" {
  load_update
  [ "$(version_state 0.9.8 0.9.8)" = "uptodate" ]
  [ "$(version_state 0.9.6 0.9.8)" = "expected" ]
  [ "$(version_state 0.9.7 0.9.8)" = "unexpected" ]
}

@test "is_valid_sha256 accepts 64 hex and rejects the rest" {
  load_update
  run is_valid_sha256 "$(printf 'a%.0s' $(seq 1 64))"; [ "$status" -eq 0 ]
  run is_valid_sha256 "-"; [ "$status" -ne 0 ]
}

# --- Task 3: manifest ---

@test "manifest_find_by_model matches 5 Pro" {
  load_update
  run manifest_find_by_model "$FIXTURES/manifest.tsv" "Orange Pi 5 Pro"
  [ "$status" -eq 0 ]
  [[ "$output" == orangepi5pro* ]]
}

@test "manifest_find_by_model returns 1 when no match" {
  load_update
  run manifest_find_by_model "$FIXTURES/manifest.tsv" "Banana Pi M7"
  [ "$status" -ne 0 ]
}

@test "manifest_find_by_model matches any '|'-separated alternative" {
  load_update
  mf="$BATS_TEST_TMPDIR/mf.tsv"
  printf 'foo\tOPi 5 Pro|Orange Pi 5 Pro\tRK3588S\tpkg\t-\t-\t0.9.8\tsupported\n' > "$mf"
  run manifest_find_by_model "$mf" "RK3588S OPi 5 Pro"; [ "$status" -eq 0 ]; [[ "$output" == foo* ]]
  run manifest_find_by_model "$mf" "Some Orange Pi 5 Pro board"; [ "$status" -eq 0 ]
  run manifest_find_by_model "$mf" "RK3588S OPi 5 Max"; [ "$status" -ne 0 ]
}

@test "get_hostname uses RKNPU_HOSTNAME override, lowercased and trimmed" {
  load_update
  RKNPU_HOSTNAME="  OrangePi5Pro  " run get_hostname
  [ "$output" = "orangepi5pro" ]
}

@test "manifest_find_by_hostname matches the model id within the hostname" {
  load_update
  run manifest_find_by_hostname "$FIXTURES/manifest.tsv" "orangepi5pro"
  [ "$status" -eq 0 ]; [[ "$output" == orangepi5pro* ]]
  run manifest_find_by_hostname "$FIXTURES/manifest.tsv" "my-laptop"
  [ "$status" -ne 0 ]
}

@test "manifest_row_by_id finds a row by exact model id" {
  load_update
  run manifest_row_by_id "$FIXTURES/manifest.tsv" "orangepi5b"
  [ "$status" -eq 0 ]; [[ "$output" == orangepi5b* ]]
  run manifest_row_by_id "$FIXTURES/manifest.tsv" "orangepi5"
  [ "$status" -ne 0 ]
}

@test "confirm_action returns proceed in auto mode" {
  load_update
  MODE="auto"
  run confirm_action
  [ "$output" = "proceed" ]
}

@test "parse_row splits the fields" {
  load_update
  row=$(manifest_find_by_model "$FIXTURES/manifest.tsv" "Orange Pi 5 Pro")
  parse_row "$row"
  [ "$ROW_MODEL" = "orangepi5pro" ]
  [ "$ROW_STATUS" = "supported" ]
  [ "$ROW_PURGE" = "linux-image-current-rockchip-rk3588" ]
}

@test "resolve_deb_url relative uses RAW_BASE" {
  load_update
  RAW_BASE="https://x/y" run resolve_deb_url "debs/a.deb"
  [ "$output" = "https://x/y/debs/a.deb" ]
}

@test "resolve_deb_url absolute is kept" {
  load_update
  run resolve_deb_url "https://host/z.deb"
  [ "$output" = "https://host/z.deb" ]
}

# --- Task 4: sha256 verification ---

@test "verify_sha256 accepts the correct hash and rejects the wrong one" {
  load_update
  tmp="$BATS_TEST_TMPDIR/x"; printf 'hola' > "$tmp"
  good=$(sha256sum "$tmp" | cut -d' ' -f1)
  run verify_sha256 "$tmp" "$good"; [ "$status" -eq 0 ]
  run verify_sha256 "$tmp" "deadbeef"; [ "$status" -ne 0 ]
}

# --- Task 5: UI ---

@test "detect_ui in auto mode = auto" {
  load_update
  MODE="auto" detect_ui
  [ "$UI_BACKEND" = "auto" ]
}

@test "require_local_run is a no-op in --auto mode" {
  load_update
  MODE="auto"
  run require_local_run
  [ "$status" -eq 0 ]
}

@test "require_local_run proceeds when run from a real file" {
  load_update
  MODE="interactive"
  # In the test harness the function's BASH_SOURCE is update.sh (a real file),
  # so it must proceed (return 0), never exit.
  run require_local_run
  [ "$status" -eq 0 ]
}

@test "ui_yesno in auto returns 0 (yes) with default yes" {
  load_update
  UI_BACKEND="auto" run ui_yesno "t" "m" "yes"
  [ "$status" -eq 0 ]
}

@test "ui_yesno in auto returns 1 (no) with default no" {
  load_update
  UI_BACKEND="auto" run ui_yesno "t" "m" "no"
  [ "$status" -ne 0 ]
}

@test "ui_info in auto prints the message" {
  load_update
  UI_BACKEND="auto" run ui_info "Title" "Body"
  [[ "$output" == *"Body"* ]]
}

# --- Task 6: end-to-end flow (dry-run, with overrides, no root) ---

@test "dry-run reaches the destructive step without touching anything" {
  export RKNPU_MANIFEST_FILE="$FIXTURES/manifest.tsv"
  export RKNPU_MODEL_FILE="$FIXTURES/model_5pro"
  export RKNPU_VERSION_FILE="$FIXTURES/version_096"
  run bash update.sh --auto --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
  [[ "$output" == *"apt purge -y linux-image-current-rockchip-rk3588"* ]]
}

@test "unknown device exits 2" {
  export RKNPU_MANIFEST_FILE="$FIXTURES/manifest.tsv"
  export RKNPU_MODEL_FILE="$FIXTURES/model_unknown"
  export RKNPU_HOSTNAME=""   # disable hostname fallback for a deterministic result
  run bash update.sh --auto --dry-run
  [ "$status" -eq 2 ]
}

@test "already at 0.9.8 exits 0 without installing" {
  export RKNPU_MANIFEST_FILE="$FIXTURES/manifest.tsv"
  export RKNPU_MODEL_FILE="$FIXTURES/model_5pro"
  printf 'RKNPU driver: v0.9.8\n' > "$BATS_TEST_TMPDIR/v098"
  export RKNPU_VERSION_FILE="$BATS_TEST_TMPDIR/v098"
  run bash update.sh --auto --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to do"* ]]
}

@test "planned model (5 plus) exits 2" {
  export RKNPU_MANIFEST_FILE="$FIXTURES/manifest.tsv"
  printf 'Orange Pi 5 Plus\0' > "$BATS_TEST_TMPDIR/m5plus"
  export RKNPU_MODEL_FILE="$BATS_TEST_TMPDIR/m5plus"
  export RKNPU_VERSION_FILE="$FIXTURES/version_096"
  run bash update.sh --auto --dry-run
  [ "$status" -eq 2 ]
}

# --- Regression: real on-device model strings (the real manifest.tsv) ---

@test "regression: real orangepi5pro model 'RK3588S OPi 5 Pro' is recognized" {
  export RKNPU_MANIFEST_FILE="./manifest.tsv"
  printf 'RK3588S OPi 5 Pro\0' > "$BATS_TEST_TMPDIR/m5pro_real"
  export RKNPU_MODEL_FILE="$BATS_TEST_TMPDIR/m5pro_real"
  export RKNPU_VERSION_FILE="$FIXTURES/version_096"
  run bash update.sh --auto --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
}

@test "hostname fallback identifies the board when the model string is unknown" {
  export RKNPU_MANIFEST_FILE="./manifest.tsv"
  printf 'Totally Unknown Board\0' > "$BATS_TEST_TMPDIR/m_unknown"
  export RKNPU_MODEL_FILE="$BATS_TEST_TMPDIR/m_unknown"
  export RKNPU_HOSTNAME="orangepi5pro"
  export RKNPU_VERSION_FILE="$FIXTURES/version_096"
  run bash update.sh --auto --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
  [[ "$output" == *"hostname"* ]]
}

@test "auto/dry-run prints an explicit update summary" {
  export RKNPU_MANIFEST_FILE="./manifest.tsv"
  printf 'RK3588S OPi 5 Pro\0' > "$BATS_TEST_TMPDIR/m5pro_sum"
  export RKNPU_MODEL_FILE="$BATS_TEST_TMPDIR/m5pro_sum"
  export RKNPU_VERSION_FILE="$FIXTURES/version_096"
  run bash update.sh --auto --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Update summary"* ]]
  [[ "$output" == *"Target driver"* ]]
  [[ "$output" == *"NOT touch your files"* ]]
}
