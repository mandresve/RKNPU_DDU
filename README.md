# RKNPU_DDU — Device Driver Update Utility for Rockchip NPU

A single-file, interactive (TUI) utility that updates the **RKNPU kernel driver**
(`v0.9.6 → v0.9.8`) on **Orange Pi** boards based on the Rockchip **RK3588 / RK3588S**
SoCs. It replaces the board's kernel image package with a precompiled one that ships the
newer NPU driver, verifying the download's integrity **before** touching anything.

> ⚠️ **This replaces the kernel image package and requires a reboot to take effect.**
> The update only downloads and installs a `.deb` whose `sha256` matches the value pinned
> in `manifest.tsv`; a mismatch aborts *before* the old kernel is removed.

## Supported devices

| Model | SoC | Status |
|-------|-----|--------|
| `orangepi5pro` | RK3588S | ✅ supported |
| `orangepi5b` | RK3588S | ✅ supported |
| `orangepi5`, `orangepi5plus`, `orangepi5max`, `orangepi5ultra`, `orangepicm5`, `orangepicm5-tablet`, `orangepicm4` | RK3588 / RK3588S / RK3566 | 🕓 planned |

`planned` boards are shown in the tool as *coming soon*. Their support is expected to be
**community-contributed** — see [`how_to_contribute.md`](how_to_contribute.md) for how to
compile the kernel and submit a `.deb` for your board.

## Requirements

- An Orange Pi board with an RK3588/RK3588S SoC running its Debian/Ubuntu image.
- `curl`, `dpkg`/`apt`, `sha256sum` (all present on the stock images).
- `whiptail` or `dialog` for the graphical TUI (optional — falls back to plain text prompts).
- Root privileges (the one-liner already uses `sudo`).

## Usage

### Interactive (default, TUI)

One-liner version, ready to go, just paste it in your terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/mandresve/RKNPU_DDU/main/update.sh -o /tmp/rknpu.sh && sudo bash /tmp/rknpu.sh
```

The tool auto-detects your board (with a menu to correct it if wrong), shows the current
vs. target driver version, downloads and verifies the correct `.deb`, asks for confirmation
before the destructive step, installs it, and offers to reboot.

### Automatic / scripted (non-interactive)

For orchestration from other scripts. Arguments go after `-s --`:

```bash
# Update and stop (caller decides when to reboot)
curl -fsSL https://raw.githubusercontent.com/mandresve/RKNPU_DDU/main/update.sh | sudo bash -s -- --auto

# Update and reboot automatically when done
curl -fsSL https://raw.githubusercontent.com/mandresve/RKNPU_DDU/main/update.sh | sudo bash -s -- --auto --reboot

# See exactly what would happen without touching the system
curl -fsSL https://raw.githubusercontent.com/mandresve/RKNPU_DDU/main/update.sh | sudo bash -s -- --auto --dry-run
```

> `--auto` needs no terminal, so piping into `sudo bash` is fine here (and is the right
> choice on headless hosts). For the interactive TUI, use the two-step download-then-run
> command shown above.

## Flags

| Flag | Effect |
|------|--------|
| `--auto` | Non-interactive: no TUI, assume "yes". Does **not** reboot unless `--reboot`. |
| `--reboot` | Reboot when the install finishes (useful with `--auto`). |
| `--dry-run` | Print what would happen; download nothing, change nothing. |
| `--version` | Print the utility version and exit. |
| `--help` | Print usage and exit. |

## Exit codes (for scripting)

| Code | Meaning |
|------|---------|
| `0` | Success, already up to date, or cancelled by the user |
| `1` | Generic error (preflight, network, manifest/deb download) |
| `2` | Device not supported (`planned` or unrecognized) |
| `3` | Could not read the current driver version |
| `4` | `.deb` checksum did not match — aborted before touching the kernel |
| `5` | Installation failed (`dpkg`) |

## How it works

1. **Preflight** — checks root, `aarch64`, required tools, and network.
2. **Manifest** — downloads `manifest.tsv`, the data-driven map of device → `.deb` →
   `sha256` → status.
3. **Detect** — matches `/proc/device-tree/model` against the manifest. Unsupported or
   unknown devices exit with code `2`.
4. **Version check** — reads `/sys/kernel/debug/rknpu/version`. If already at the target it
   exits doing nothing; if it reads an unexpected version it warns and asks before
   continuing.
5. **Download + verify** — fetches the board's `.deb` and checks its `sha256` against the
   manifest. **A mismatch aborts here, before the running kernel is removed** (code `4`).
6. **Install** — `apt purge -y <kernel-pkg>` then `dpkg -i <deb>`.
7. **Reboot** — prompts to reboot (interactive) or reboots only with `--reboot` (auto).

Manually check your current driver version at any time:

```bash
sudo cat /sys/kernel/debug/rknpu/version    # e.g. "RKNPU driver: v0.9.6"
```

## Contributing a board

Everything is data-driven: adding a board means dropping its `.deb` into `debs/` and adding
one row to `manifest.tsv` — **no script changes**. Build instructions and the submission
flow live in [`how_to_contribute.md`](how_to_contribute.md).

## Development

```bash
shellcheck update.sh            # static analysis
bats tests/unit.bats            # unit + dry-run tests
```

Tests inject fake system paths via `RKNPU_MODEL_FILE`, `RKNPU_VERSION_FILE` and
`RKNPU_MANIFEST_FILE`, so the whole flow (up to the destructive step) runs on any machine
with `--dry-run`.
