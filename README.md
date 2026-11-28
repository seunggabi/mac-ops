# mac-ops

**Safe, zero-dependency macOS system optimizer with 72-hour recovery.**

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](https://opensource.org/licenses/MIT)
[![GitHub Stars](https://img.shields.io/github/stars/seunggabi/mac-ops?style=social)](https://github.com/seunggabi/mac-ops/stargazers)
[![macOS](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)](https://github.com/seunggabi/mac-ops)
[![Latest Release](https://img.shields.io/github/v/release/seunggabi/mac-ops?color=blue)](https://github.com/seunggabi/mac-ops/releases)
[![Zero Dependencies](https://img.shields.io/badge/dependencies-0-brightgreen)](https://github.com/seunggabi/mac-ops)
[![Tests](https://img.shields.io/badge/tests-108%2B%20passed-brightgreen)](https://github.com/seunggabi/mac-ops)

---

## Demo

<!-- Record with: cd mac-ops && vhs demo/demo.tape -->

<p align="center"><img src="demo/demo.gif" alt="mac-ops demo" width="720"></p>

## Quick Start

```bash
# Install via Homebrew
brew install seunggabi/tap/mac-ops
```

Or clone from source:

```bash
git clone https://github.com/seunggabi/mac-ops.git
cd mac-ops
chmod +x bin/mac-ops
export PATH="$PWD/bin:$PATH"  # or use ./bin/mac-ops instead of mac-ops
```

First run:

```bash
mac-ops run --dry-run   # Preview what will be cleaned
mac-ops analyze          # Disk space report
mac-ops run              # Execute cleanup
```

## Why mac-ops

### 72-Hour Safety Net

Every file mac-ops cleans is moved to `~/.mac-ops/.trash/` instead of being permanently deleted. You have **72 hours** to restore anything with a single command. No other CLI cleanup tool offers this level of protection.

```bash
mac-ops restore ~/Library/Caches/com.important.app   # Undo a mistake instantly
```

### Zero Dependencies

Pure zsh. No Python, no Ruby, no Node.js. Only macOS built-in tools (`zsh`, `plutil`, `launchd`). Install and run anywhere with no setup overhead.

### 6-Layer Safety System

| Layer | Protection |
|-------|-----------|
| Whitelist | Only touches known-safe cleanup targets |
| Blacklist | System paths, keychains, and user documents are never touched |
| Size Guard | Files over 2 GB are automatically skipped |
| Process Protection | Critical system processes (`kernel_task`, `WindowServer`, `launchd`, ...) are never killed |
| User Ignore Rules | `~/.mac-ops/ignore` lets you exempt specific apps, processes, or paths |
| Lock | Prevents concurrent execution to avoid race conditions |

### 10 Cleanup Modules

Enabled by default: `cache`, `tmp`, `log`, `orphan-app`. The others are off until enabled in config.plist (see [Settings](#settings-and-configplist)).

| Module | Description |
|--------|-------------|
| `cache` | Clean `~/Library/Caches` (Apple system caches excluded) |
| `tmp` | Clean `/tmp`, `/private/var/folders`, CrashReporter |
| `log` | Clean `~/Library/Logs`, system diagnostic reports |
| `zombie` | Report zombie processes (opt-in: send SIGCHLD to eligible parents; never SIGTERM/SIGKILL) |
| `orphan` | Report orphan process candidates (sends SIGTERM only with `MAC_OPS_ORPHAN_ACTION=term`, never SIGKILL) |
| `orphan-app` | Clean residual files from deleted applications |
| `brew` | Clean Homebrew caches and outdated downloads (skipped while a running process uses an old keg) |
| `dev` | Clean Xcode DerivedData and simulator caches, npm, yarn, pnpm, pip, Gradle and CocoaPods caches; DerivedData, CocoaPods and package-manager items used within 30 days are kept; Xcode Archives are only reported |
| `docker` | Report Docker disk usage (opt-in: prune old unused images and build cache; never containers or volumes) |
| `browser` | Clean Safari, Chrome, Firefox caches |

### Parallel Execution

File-based modules run concurrently to minimize cleanup time. Process modules execute sequentially for safety.

### Scheduled Automation

Native `launchd` integration runs cleanup every hour, catching up on missed runs after sleep/wake. One command to install:

```bash
mac-ops install
```

## Comparison

| Feature | mac-ops | CleanMyMac | OnyX | Manual `rm` |
|---------|:-------:|:----------:|:----:|:-----------:|
| Price | Free | $39.95/yr | Free | Free |
| Safe deletion (72h recovery) | ✅ | ⚠️ | ❌ | ❌ |
| CLI support | ✅ | ❌ | ❌ | ✅ |
| Automation (launchd/cron) | ✅ | ❌ | ❌ | Manual |
| Open source | ✅ | ❌ | ❌ | N/A |
| Zero dependencies | ✅ | ❌ | ❌ | N/A |
| Process cleanup | ✅ | ❌ | ❌ | Manual |
| Disk analysis | ✅ | ✅ | ✅ | Manual |

## Usage

### Basic Commands

```bash
# Preview (dry-run) - Check cleanup targets without actual deletion
mac-ops run --dry-run

# Execute cleanup
mac-ops run

# Run specific module only
mac-ops run --module=cache
mac-ops run --module=browser
mac-ops run --module=docker

# Disk space analysis report
mac-ops analyze

# Verbose logging
mac-ops run --verbose
```

> Available modules: `cache`, `tmp`, `log`, `zombie`, `orphan`, `orphan-app`, `brew`, `dev`, `docker`, `browser`

### Monitor

```bash
# Memory & CPU dashboard with 7-day history
mac-ops monitor

# Hourly sparkline view (24h breakdown per day)
mac-ops monitor --hours

# Show top N processes by memory usage (default: 10)
mac-ops monitor top 20

# Kill processes using more than M MB (default: 500)
mac-ops monitor kill 1000

# Record a memory/CPU snapshot manually
mac-ops monitor collect
```

History is stored as CSV in `~/.mac-ops/monitor/YYYY-MM-DD.csv` and auto-purged after 7 days.

### Trash Management

```bash
# List trash contents
mac-ops list-trash

# Restore accidentally deleted files
mac-ops restore ~/Library/Caches/com.important.app

# List recent runs (time, exit status, items moved, data items moved)
mac-ops runs

# Undo a whole run: restore every item of it that is still in the trash
mac-ops restore --run 20261128T101500-12345 --dry-run
mac-ops restore --run 20261128T101500-12345

# Immediately purge expired items
mac-ops purge

# Check current status (health, trash, disk usage, launchd status)
mac-ops status
```

`mac-ops status` starts with a health section read from the newest run manifest: last run time, its exit status, how many ERROR and WARN lines it logged, how many settings/app-data items it moved, and whether the `com.mac-ops.cleanup` and `com.mac-ops.monitor` agents are loaded (`launchctl list <label>`). When the last scheduled run failed, the cleanup agent is installed but not loaded, or it has not run for more than three intervals (`StartInterval` of the installed plist; for `StartCalendarInterval` the period of its coarsest field: Month a year, Day 31 days, Weekday a week, Hour a day, Minute an hour), the **first line** of the output is an `[ALERT] ...` line saying so. `status` is read-only.

Every run gets a run ID (`<local start time>-<pid>`, for example `20261128T101500-12345`) and a manifest at `~/.mac-ops/runs/<run-id>.json`: start and end time, exit status, ERROR/WARN counts, per-module counts, every moved path with its trash path and reason, and free space (`df -k`) before and after. A run that fails or is interrupted (ERR_EXIT, INT/TERM/HUP) still writes its manifest with its exit status. The newest 200 manifests are kept (independent of log rotation); `--dry-run` writes none. Each trash index record of a run carries its `run_id`. `mac-ops restore --run <run-id>` restores every item of that run that is still in the trash, one by one through the single-item restore: an item whose original location exists again is refused and left alone, items already restored or purged are reported as no longer in the trash, and the command exits non-zero if anything was refused or failed. It honours `--dry-run`.

`mac-ops status` shows two trash figures: the indexed total (moved to trash, **pending purge** - that space is not reclaimed until the items are purged) and what the trash directory really occupies on disk. `mac-ops purge` logs the measured change in free space (`df`) next to the indexed size, because a `du` figure is not always reclaimable space (APFS clones share blocks).

Before every purge the trash is reconciled with its index. An item that is on disk but missing from the index is re-indexed with the **current** time as its trashed time, so it gets the full 72 hours from the moment it is found; it is marked `"source": "reconcile"` in the index (its change time is kept as `original_time`, for information only) and it is never deleted in the purge pass that found it. Each re-indexed item is logged with its path, size, original time and new expiry. Leftover `.index.json.tmp.*` files (older than one hour, from an interrupted index write) are first searched for entries the index lost: an entry still on disk keeps its recorded trashed time only if that leaves at least 24 hours before it expires, otherwise it is stamped now. The processed files are then moved to `.index-recovery/` inside the trash and are never deleted. Nothing unindexed is deleted on sight.

`--dry-run` changes nothing on disk for `purge`, `restore`, `install`, `uninstall` and `monitor setup` / `unsetup`: no deletion, no index write, no plist migration, no lock file, no `lsof` cache. Every skipped action is logged as `[DRY_RUN] Will ...`. `list-trash` and `status` never write (they do not migrate legacy metadata or create a missing index). The index is serialized with an fcntl lock (`zsh/system` `zsystem flock` on `.index.flock`), which the kernel releases when its owner exits, so a live owner can never lose it to another process.

Moves into the trash are all-or-nothing: a same-volume move is a single atomic rename; if a rename is not possible the copy is verified (entry count and total size) before the source is removed, and on any failure the source stays untouched and the partial copy is removed. Right before the source is removed it is checked again; if it changed after the copy, the source is kept and the trashed copy is removed. A file, or a directory with anything inside it, that a running process has open is not moved (for example a sqlite database in use). If that cannot be determined because `lsof` is missing or fails, nothing is moved and an error is logged. The check uses one cached `lsof` list per run; set `MAC_OPS_TRASH_SKIP_OPEN_DIRS=false` to disable it.

### Miscellaneous

```bash
# Check current configuration
mac-ops config

# Check version
mac-ops version

# Show help
mac-ops help
```

## Configuration

### Settings and config.plist

Every setting can be set three ways. The first one found wins:

1. an environment variable (`MAC_OPS_...`)
2. `~/.mac-ops/config.plist` (or the file named by `MAC_OPS_CONFIG_FILE`), using the key path below
3. the built-in default

Command-line flags (`--dry-run`, `--verbose`, `--force`) override all three, so `--dry-run` holds even when config.plist says `DryRun` is false.
The scheduled launchd job passes no `MAC_OPS_*` variables, so use config.plist for settings that should apply to scheduled runs.
Start from [`config/default.plist`](config/default.plist), which lists every key with its default: `cp config/default.plist ~/.mac-ops/config.plist`.

- A missing key, or no config file, means the default.
- A config file that cannot be parsed stops every command with an error (on stderr and in the log); mac-ops never runs on defaults you did not choose.
- A value of the wrong type (not an integer, below the minimum, not an allowed word) logs a WARN and uses the default.
- `Modules.<name>.Enabled` accepts only `<true/>` / `<false/>` (or the exact strings `true` / `false`; the same for `MAC_OPS_MODULE_<NAME>_ENABLED`). `yes`, `1` or `TRUE` never enable a module: they log a WARN and keep the default. An inexact off value (`no`, `0`, `FALSE`, `off`) logs a WARN and disables the module.
- `mac-ops config` prints every setting with its effective value and its source (`env`, `file`, `default` or `cli`).

Modules: a plain `mac-ops run` runs only enabled modules and logs one line for each disabled one. By default only modules that move files to the mac-ops trash are enabled (`cache`, `tmp`, `log`, `orphan-app`). `brew` (deletes permanently), `dev`, `browser`, `docker`, `zombie` and `orphan` (process modules) are off until you enable them. `mac-ops run --module=NAME` runs that one module even when it is disabled, and logs that it was explicitly requested.

| config.plist key | Environment variable | Default | Allowed |
|---|---|---|---|
| `DryRun` | `MAC_OPS_DRY_RUN` | `false` | true / false |
| `Verbose` | `MAC_OPS_VERBOSE` | `false` | true / false |
| `Force` | `MAC_OPS_FORCE` | `false` | true / false |
| `TrashRetentionHours` | `MAC_OPS_TRASH_RETENTION_HOURS` | `72` | integer 1 to 8760 (one year) |
| `MaxSingleFileBytes` | `MAC_OPS_MAX_SINGLE_FILE_BYTES` | `2147483648` | integer >= 1 |
| `ParallelTimeoutSeconds` | `MAC_OPS_PARALLEL_TIMEOUT_SECONDS` | `300` | integer >= 1 |
| `IndexLockTimeoutSeconds` | `MAC_OPS_INDEX_LOCK_TIMEOUT_SECONDS` | `120` | integer >= 1 |
| `OpenFilesTTLSeconds` | `MAC_OPS_OPEN_FILES_TTL_SECONDS` | `60` | integer >= 0 |
| `TrashSkipOpenDirs` | `MAC_OPS_TRASH_SKIP_OPEN_DIRS` | `true` | true / false |
| `TrashReconcileMaxDepth` | `MAC_OPS_TRASH_RECONCILE_MAX_DEPTH` | `6` | integer >= 1 |
| `TrashRecoveryMinLeftHours` | `MAC_OPS_TRASH_RECOVERY_MIN_LEFT_HOURS` | `24` | integer >= 0 |
| `Modules.cache-cleanup.Enabled` | `MAC_OPS_MODULE_CACHE_CLEANUP_ENABLED` | `true` | true / false |
| `Modules.cache-cleanup.MaxAgeDays` | `MAC_OPS_CACHE_MAX_AGE_DAYS` | `30` | integer >= 1 |
| `Modules.cache-cleanup.RecentDays` | `MAC_OPS_CACHE_RECENT_DAYS` | `7` | integer >= 0 |
| `Modules.tmp-cleanup.Enabled` | `MAC_OPS_MODULE_TMP_CLEANUP_ENABLED` | `true` | true / false |
| `Modules.tmp-cleanup.MaxAgeDays` | `MAC_OPS_TMP_MAX_AGE_DAYS` | `3` | integer >= 1 |
| `Modules.tmp-cleanup.VarFoldersMaxAgeDays` | `MAC_OPS_VAR_FOLDERS_MAX_AGE_DAYS` | `7` | integer >= 1 |
| `Modules.tmp-cleanup.CrashMaxAgeDays` | `MAC_OPS_CRASH_MAX_AGE_DAYS` | `14` | integer >= 1 |
| `Modules.log-cleanup.Enabled` | `MAC_OPS_MODULE_LOG_CLEANUP_ENABLED` | `true` | true / false |
| `Modules.log-cleanup.MaxAgeDays` | `MAC_OPS_LOG_CLEANUP_MAX_AGE_DAYS` | `7` | integer >= 1 |
| `Modules.log-cleanup.DiagReportMaxAgeDays` | `MAC_OPS_DIAG_REPORT_MAX_AGE_DAYS` | `30` | integer >= 1 |
| `Modules.orphan-app-cleanup.Enabled` | `MAC_OPS_MODULE_ORPHAN_APP_CLEANUP_ENABLED` | `true` | true / false |
| `Modules.orphan-app-cleanup.GraceDays` | `MAC_OPS_ORPHAN_APP_GRACE_DAYS` | `7` | integer >= 0 |
| `Modules.orphan-app-cleanup.DataAction` | `MAC_OPS_ORPHAN_APP_DATA_ACTION` | `report` | report / trash |
| `Modules.brew-cleanup.Enabled` | `MAC_OPS_MODULE_BREW_CLEANUP_ENABLED` | `false` | true / false |
| `Modules.dev-cleanup.Enabled` | `MAC_OPS_MODULE_DEV_CLEANUP_ENABLED` | `false` | true / false |
| `Modules.dev-cleanup.MaxAgeDays` | `MAC_OPS_DEV_CACHE_MAX_AGE_DAYS` | `30` | integer >= 1 |
| `Modules.browser-cleanup.Enabled` | `MAC_OPS_MODULE_BROWSER_CLEANUP_ENABLED` | `false` | true / false |
| `Modules.docker-cleanup.Enabled` | `MAC_OPS_MODULE_DOCKER_CLEANUP_ENABLED` | `false` | true / false |
| `Modules.docker-cleanup.Action` | `MAC_OPS_DOCKER_ACTION` | `report` | report / prune |
| `Modules.docker-cleanup.PruneUntilHours` | `MAC_OPS_DOCKER_PRUNE_UNTIL_HOURS` | `720` | integer >= 1 |
| `Modules.docker-cleanup.ProbeTimeoutSeconds` | `MAC_OPS_DOCKER_PROBE_TIMEOUT` | `10` | integer >= 1 |
| `Modules.zombie-killer.Enabled` | `MAC_OPS_MODULE_ZOMBIE_KILLER_ENABLED` | `false` | true / false |
| `Modules.zombie-killer.Action` | `MAC_OPS_ZOMBIE_ACTION` | `report` | report / sigchld |
| `Modules.orphan-killer.Enabled` | `MAC_OPS_MODULE_ORPHAN_KILLER_ENABLED` | `false` | true / false |
| `Modules.orphan-killer.MinRunningHours` | `MAC_OPS_ORPHAN_MIN_RUNNING_HOURS` | `24` | integer >= 1 |
| `Modules.orphan-killer.Action` | `MAC_OPS_ORPHAN_ACTION` | `report` | report / term |
| `Monitor.RetentionDays` | `MAC_OPS_MONITOR_RETENTION_DAYS` | `7` | integer >= 1 |
| `Monitor.KillThresholdMB` | `MAC_OPS_MONITOR_KILL_THRESHOLD_MB` | `500` | integer >= 1 |

### Environment Variables

You can customize cleanup behavior by setting environment variables:

```bash
# Cache cleanup settings
export MAC_OPS_CACHE_MAX_AGE_DAYS=30   # Delete caches older than N days (default: 30)
export MAC_OPS_CACHE_RECENT_DAYS=7     # Protect caches used within N days (default: 7)

# Orphan process settings
export MAC_OPS_ORPHAN_ACTION=report          # report (default): list candidates only, term: send SIGTERM to candidates
export MAC_OPS_ORPHAN_MIN_RUNNING_HOURS=24   # Only consider processes running N hours or more (whole number >= 1, default: 24)

# Example: More aggressive cache cleanup
MAC_OPS_CACHE_MAX_AGE_DAYS=30 mac-ops run --module=cache

# Example: Protect only very recent caches
MAC_OPS_CACHE_RECENT_DAYS=1 mac-ops run --module=cache

# Orphan app data settings
export MAC_OPS_ORPHAN_APP_GRACE_DAYS=7          # Skip entries modified (or holding a file modified) within N days (default: 7)
export MAC_OPS_ORPHAN_APP_DATA_ACTION=report    # Orphans in settings/data locations: report (default) or trash
# Settings/data locations: Application Support, Preferences, Containers, HTTPStorages (cookies),
# WebKit (per-app local storage, IndexedDB).
# Only the exact value "trash" moves them; any other value reports.
# An entry is never touched when an installed app (or a helper/login item nested inside one)
# has the same bundle ID vendor, e.g. com.garmin.*, or when it is a symbolic link.

# Example: Preview what opting in to moving orphan settings/data would do
MAC_OPS_ORPHAN_APP_DATA_ACTION=trash mac-ops run --module=orphan-app --dry-run
```

### Orphan Processes

The `orphan` module reports by default and never ends a process unless you set `MAC_OPS_ORPHAN_ACTION=term`. A process is a candidate only if all of these hold:

- its parent is PID 1 and it is owned by the current user
- it is not managed by launchd (its PID is not in `launchctl list`)
- it has no controlling terminal and its executable is not inside a `.app` bundle
- neither it nor any ancestor or descendant is a terminal, shell, tmux, or coding-agent session
- it is not part of mac-ops' own process tree and is not security software
- it has no child process (something may still depend on it)
- its executable is not a user daemon started on purpose: `gpg-agent`, `ssh-agent`, `ollama`, `limactl`, `colima`, `qemu-system-*`, `pm2` (and node running as a pm2 God daemon), `emacs`, `tmux`, `screen`, `mosh-server`, `syncthing`, `rclone`, `cloudflared`, `ngrok`, `tailscaled`, databases (`postgres`, `mysqld`, `mariadbd`, `redis-server`, `mongod`), web servers (`nginx`, `httpd`, `caddy`), container engines (`dockerd`, `containerd`, `podman`), `jupyter*`, `code-server`, and a few more
- it passes the system path, protected process, and ignore file rules, and has run for `MAC_OPS_ORPHAN_MIN_RUNNING_HOURS` or more (a whole number of at least 1; any other value logs a warning and uses 24)

Each candidate is logged with its PID, uptime, memory, executable, and the checks it passed. All name rules compare the executable, not the command-line arguments. With `MAC_OPS_ORPHAN_ACTION=term`, the PID is re-checked right before the signal (same start time, same executable, and the full candidate rule run again on a fresh `ps` row) and only SIGTERM is sent, never SIGKILL.

> **Warning:** The daemon list cannot know every tool. Before you turn on `MAC_OPS_ORPHAN_ACTION=term`, run the module in report mode, and put every long-running tool you start by hand (local servers, agents, tunnels, VMs) in `~/.mac-ops/ignore`.

### Ignore File

Create `~/.mac-ops/ignore` to permanently exempt specific apps, processes, or paths from cleanup:

```ini
# ~/.mac-ops/ignore
# Lines starting with # are comments. Empty lines are ignored.
# Glob patterns are supported (*, **, ?).

[bundle]
# Bundle ID patterns — skipped by orphan-app-cleanup
# com.mycompany.*
# com.example.DevBuild

[process]
# Process name patterns — skipped by zombie-killer and orphan-killer
# my-custom-daemon
# MyVendorHelper*

[path]
# Path patterns — skipped by all file-based cleanup modules
# ~/work/.cache
# ~/projects/my-project
```

Copy `config/ignore.example` as a starting template.

### Cache Protection Policy

The cache cleanup module includes **smart protection** to prevent accidental deletion of active application data:

1. ✅ **Apple system caches** (`com.apple.*`) - Always protected
2. ✅ **Installed applications** - Caches from apps in `/Applications` are protected
3. ✅ **Running applications** - Caches from currently running apps are protected
4. ✅ **Recently used caches** - Caches accessed within `MAC_OPS_CACHE_RECENT_DAYS` (default: 7 days) are protected
5. ✅ **Orphan caches only** - Only caches from uninstalled/inactive apps older than `MAC_OPS_CACHE_MAX_AGE_DAYS` (default: 30 days) are cleaned

This ensures your login sessions, preferences, and active app data are never touched during cleanup.

## Scheduled Execution

### Method 1: launchd (Recommended)

macOS native scheduler runs automatically every hour. Catches up on missed tasks when waking from sleep.

```bash
# Install
mac-ops install
```

```bash
# Uninstall
mac-ops uninstall
```

With a Homebrew install the agent is registered with the version-independent `$(brew --prefix)/opt/mac-ops/libexec/bin/mac-ops` path, so it keeps working after `brew upgrade mac-ops`. `mac-ops status` reports an installed plist whose program path does not exist (BROKEN) or is a versioned `Cellar/mac-ops/<version>` path that the next upgrade deletes (STALE), together with the exact command that fixes it: `mac-ops monitor unsetup && mac-ops monitor setup` for the monitor agent, `mac-ops uninstall && mac-ops install` for the cleanup agent.

### Method 2: crontab

```bash
crontab -e
```

Add the following content:

```cron
# Run mac-ops every hour
0 * * * * mac-ops run --scheduled 2>&1 >> ~/.mac-ops/.logs/cron.log

# Or run daily at 3 AM
0 3 * * * mac-ops run --scheduled 2>&1 >> ~/.mac-ops/.logs/cron.log
```

### Method 3: Monitor Collection (launchd)

Automatically collect CPU/memory snapshots every 5 minutes:

```bash
mac-ops monitor setup    # Install launchd agent
mac-ops monitor unsetup  # Uninstall
```

Or via crontab:

```cron
*/5 * * * * mac-ops monitor collect >> ~/.mac-ops/.logs/monitor.log 2>&1
```

## Cautions

### Destructive Commands

> **WARNING**: The following commands are irreversible. Data cannot be recovered once executed.

```bash
# 1. Force cleanup - bypasses the size guard (2GB limit)
mac-ops run --force

# 2. Permanently delete all trash - bypasses 72-hour grace period
sudo rm -rf ~/.mac-ops/.trash
```

| Command | Risk | What It Does |
|---------|------|--------------|
| `run --force` | **HIGH** | Skips the size guard, so files over 2GB are cleaned too |
| `sudo rm -rf ~/.mac-ops/.trash` | **CRITICAL** | Permanently deletes all recoverable files, bypassing the 72-hour safety net |

**Before running these commands:**
1. Run `mac-ops list-trash` to check what is in the trash
2. Run `mac-ops run --dry-run` to preview cleanup targets
3. Restore any important files with `mac-ops restore <path>`

### Full Disk Access Permission Required

Due to macOS TCC policy, **Full Disk Access** permission is required to access certain paths like `~/Library/Caches`, `~/Library/Logs`.

```
System Settings > Privacy & Security > Full Disk Access
```

Add Terminal.app (or iTerm, Warp, etc. depending on your terminal). For launchd automatic execution, add the `mac-ops` binary itself to the FDA list.

### Run dry-run First

When using for the first time, always check what files will be cleaned with `--dry-run`.

```bash
mac-ops run --dry-run
```

### 72-hour Grace Period

- All cleanup targets are moved to `~/.mac-ops/.trash/` and automatically purged **after 72 hours**
- You can restore with `mac-ops restore <path>` within 72 hours
- Running `mac-ops purge` immediately purges expired items

### Paths Never Touched

| Path | Reason |
|------|--------|
| `/System/*`, `/bin/*`, `/sbin/*`, `/usr/*` | SIP protected |
| `~/Library/Keychains/*` | Keychains (passwords, certificates) |
| `~/Library/Preferences/*` | User preferences |
| `~/Documents/*`, `~/Desktop/*`, `~/Downloads/*` | User documents |
| `/Library/LaunchDaemons/*`, `/Library/LaunchAgents/*` | System services |

### Processes Never Killed

```
kernel_task, launchd, WindowServer, loginwindow,
SystemUIServer, Finder, Dock, cfprefsd, mds, mds_stores,
coreaudiod, opendirectoryd
```

### Docker Module

Report-only by default: logs `docker system df`, the number of stopped containers, unused images older than the age limit and the reclaimable build cache. Stopped containers and volumes are never removed (they can hold data, and Docker deletes permanently). Skipped when Docker is not installed or the daemon does not answer `docker info` within `MAC_OPS_DOCKER_PROBE_TIMEOUT` seconds (default 10); Docker Desktop is never started or quit.

```bash
export MAC_OPS_DOCKER_ACTION=report             # report (default) or prune; only the exact value "prune" acts
export MAC_OPS_DOCKER_PRUNE_UNTIL_HOURS=720     # prune: only images/build cache older than N hours (default 720 = 30 days)
# prune runs exactly: docker image prune -a --filter "until=<N>h" -f
#                     docker builder prune --filter "until=<N>h" -f
```

### Zombie Module

Report-only by default: each zombie is logged with its PID, parent PID, parent executable and age. A zombie holds no resources, so its parent is never terminated. `MAC_OPS_ZOMBIE_ACTION=sigchld` (exact value) sends SIGCHLD to the parent, never to PID 1, to an ancestor of the mac-ops run, to protected or ignored processes, or to security software.

### Size Guard

Single files exceeding 2GB are automatically skipped. Can be overridden with `--force` option.

## Project Structure

```
mac-ops/
├── bin/mac-ops                    # CLI entry point
├── lib/
│   ├── core/                      # Core utilities
│   │   ├── config.zsh             # Settings registry and config.plist loader
│   │   ├── dispatch.zsh           # Module selection (Enabled flags) and dispatch
│   │   ├── run.zsh                # Run ID, run manifests, runs/status health, restore --run
│   │   ├── trash.zsh              # Trash management
│   │   ├── logger.zsh             # Logging
│   │   ├── lock.zsh               # Prevent duplicate execution
│   │   ├── safety.zsh             # Safety system
│   │   ├── disk.zsh               # Disk monitoring
│   │   └── ignore.zsh             # User ignore rules (~/.mac-ops/ignore)
│   ├── modules/                   # Cleanup modules
│   │   ├── cache-cleanup.zsh
│   │   ├── tmp-cleanup.zsh
│   │   ├── log-cleanup.zsh
│   │   ├── zombie-killer.zsh
│   │   ├── orphan-killer.zsh
│   │   ├── orphan-app-cleanup.zsh
│   │   ├── brew-cleanup.zsh
│   │   ├── dev-cleanup.zsh
│   │   ├── docker-cleanup.zsh
│   │   ├── browser-cleanup.zsh
│   │   ├── analyze.zsh
│   │   └── monitor.zsh
│   └── utils/                     # Shared utilities
│       ├── format.zsh             # Size formatting, colors, run report
│       ├── notify.zsh             # macOS notifications
│       ├── parallel.zsh           # Wait for parallel modules with a timeout
│       ├── plist-helper.zsh
│       ├── running.zsh            # Running process / running app detection
│       ├── security-keywords.zsh  # Security software keywords (never touched)
│       └── snapshot.zsh           # Disk/memory snapshot before and after a run
├── config/                        # Configuration files
│   ├── default.plist              # Every setting with its default (copy to ~/.mac-ops/config.plist)
│   └── ignore.example             # Example ignore file template
├── launchd/                       # launchd agents
├── scripts/                       # Utility scripts
├── demo/                          # Demo and example files
├── .github/                       # GitHub workflows and templates
└── tests/                         # Test suites
    ├── test-trash.zsh             # Trash, index, restore and purge
    ├── test-safety.zsh            # Protected paths and processes, size guard
    ├── test-core-safety.zsh       # Config loading, CLI precedence, module flags, settings
    ├── test-modules.zsh           # Module behaviour
    ├── test-module-safety.zsh     # docker, zombie, dev, cache, orphan-app, brew safety
    ├── test-file-cleanup.zsh      # tmp, log, cache, browser, dev protection
    ├── test-orphan-killer.zsh     # Orphan process candidate rules
    ├── test-timeout.zsh           # Parallel module timeout
    └── test-e2e.zsh               # End-to-end CLI runs
```

## Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on how to submit issues, feature requests, and pull requests.

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=seunggabi/mac-ops&type=Date)](https://star-history.com/#seunggabi/mac-ops&Date)

## License

[MIT](LICENSE)

<!-- GitHub Topics: macos, cli, cleanup, disk-space, system-optimization, shell, productivity, macos-utility, zsh -->
