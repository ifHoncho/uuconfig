# uuconfig (unattended-upgrades config)

A user friendly bash tool that configures [`unattended-upgrades`](https://wiki.debian.org/UnattendedUpgrades) on Debian, Ubuntu, and other apt-based systems — so you don't have to hand-edit `/etc/apt/apt.conf.d/*` or systemd timer drop-ins.


![uuconfig demo](demo.gif)

## Quick start

Run it directly from GitHub, no cloning required (fish shell not supported, run ``bash`` first):

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/ifHoncho/uuconfig/main/uuconfig.sh)" uuconfig.sh
```


## Features

- **Guided interactive setup** — walks through what to upgrade, scheduling, reboots, cleanup, exclusions, and mail reports, each with a sensible default. Ends on a plain-English review screen before anything is written.
- **Live, fuzzy package search for exclusions** — start typing a package name and matches appear instantly from your system's actual package index, typo-tolerant (e.g. `arp-s` finds `arp-scan`, `myqsl` finds `mysql-shell`). Navigate with `↑`/`↓`, `Tab` to add or remove, `Enter` when done.
- **Non-interactive "express" mode** — bundle short flags for one-line, script-friendly setup: `uuconfig.sh -srkdc`.
- **Dry-run preview** — see exactly what would be written, with no root privileges required and nothing touched: `uuconfig.sh -n ...`.
- **Distro-aware** — automatically detects Ubuntu vs. Debian and writes the correct upgrade-origins syntax for each.
- **Safe by default** — backs up any existing config before replacing it, and validates the result with `apt-config dump` after applying.

## Requirements

- A Debian/Ubuntu-family system with `apt` and `systemd`
- `bash`, and `sudo` (or the ability to run as root)

## Usage

```bash
chmod +x uuconfig.sh

# Guided interactive setup
./uuconfig.sh

# Show help
./uuconfig.sh -h

# Non-interactive, one-line setup
./uuconfig.sh -srkdc

# Preview any configuration without changing anything
./uuconfig.sh -n -a -r -R 02:30
```

### Flags

| Flag | Description |
|---|---|
| `-s` | Security updates only *(default)* |
| `-a` | All updates (security + regular) |
| `-t HH:MM` | Time of day to install upgrades *(default `04:00`)* |
| `-r` | Reboot automatically if required *(default time `02:00`)* |
| `-R HH:MM` | Reboot automatically at this time *(implies `-r`)* |
| `-u` | Reboot even if users are logged in |
| `-k` | Remove old / unused kernel packages |
| `-d` | Remove unused dependencies (autoremove) |
| `-c` | Autoclean the package cache weekly |
| `-x LIST` | Never auto-upgrade these packages (comma/space separated), e.g. `-x "docker-ce,mysql-server"` |
| `-m ADDR` | Email address for upgrade reports |
| `-M WHEN` | When to mail: `on-change` \| `only-on-error` \| `always` *(default `on-change`)* |
| `-p` | Only run while on AC power (recommended for laptops) |
| `-n` | Dry run — show exactly what would change, modify nothing |
| `-h` | Show help and exit |
| `-V` | Show version and exit |

Flags can be bundled — `uuconfig.sh -srkdc` means security-only updates, auto-reboot, kernel + dependency cleanup, and weekly autoclean. When bundling, put any flag that takes a value last: `uuconfig.sh -srk -R 03:00`.

### Examples

```bash
./uuconfig.sh                         # Guided interactive setup
./uuconfig.sh -a -t 03:00 -r -kdc     # All updates at 03:00, auto-reboot, full cleanup
./uuconfig.sh -s -x "docker-ce"       # Security only, never touch docker-ce
./uuconfig.sh -n -a -r -R 02:30       # Preview an "all + reboot at 02:30" setup
```

## What it writes

- `/etc/apt/apt.conf.d/20auto-upgrades` — enables the periodic update/download/upgrade cycle
- `/etc/apt/apt.conf.d/50unattended-upgrades` — origins, exclusions, reboot behavior, cleanup, mail reporting (existing file is backed up first)
- `/etc/systemd/system/apt-daily-upgrade.timer.d/override.conf` — sets the daily run time

Applying only writes configuration and enables the relevant systemd timers — it does not trigger an immediate upgrade or reboot.

## Notes

- This tool needs root; it re-runs itself with `sudo` automatically when required.
- Dry-run mode (`-n`) needs no privileges and writes nothing.
