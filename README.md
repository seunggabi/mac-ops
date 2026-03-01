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
git clone https://github.com/seunggabi/mac-ops.git && cd mac-ops && chmod +x bin/mac-ops
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

| Module | Description |
|--------|-------------|
| `cache` | Clean `~/Library/Caches` (Apple system caches excluded) |
| `tmp` | Clean `/tmp`, `/private/var/folders`, CrashReporter |
| `log` | Clean `~/Library/Logs`, system diagnostic reports |
| `zombie` | Detect and terminate zombie processes |
| `orphan` | Detect and terminate orphan processes |
| `orphan-app` | Clean residual files from deleted applications |
| `brew` | Clean Homebrew caches and outdated downloads |
| `dev` | Clean Xcode, npm, yarn, pnpm, pip, Gradle caches |
| `docker` | Clean dangling images, stopped containers, unused volumes |
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

To collect snapshots automatically, add to crontab (`crontab -e`):

```cron
# Collect every 5 minutes
*/5 * * * * mac-ops monitor collect >> ~/.mac-ops/.logs/monitor.log 2>&1
```

Or via launchd (recommended on macOS):

```bash
mac-ops monitor setup    # Install launchd agent (every 5 min)
mac-ops monitor unsetup  # Uninstall
```

### Trash Management

```bash
# List trash contents
mac-ops list-trash

# Restore accidentally deleted files
mac-ops restore ~/Library/Caches/com.important.app

# Immediately purge expired items
mac-ops purge

# Check current status (trash, disk usage, launchd status)
mac-ops status
```

### Miscellaneous

```bash
# Check current configuration
mac-ops config

# Check version
mac-ops version

# Show help
mac-ops help
```

> Available modules: `cache`, `tmp`, `log`, `zombie`, `orphan`, `orphan-app`, `brew`, `dev`, `docker`, `browser`

## Configuration

### Environment Variables

You can customize cleanup behavior by setting environment variables:

```bash
# Cache cleanup settings
export MAC_OPS_CACHE_MAX_AGE_DAYS=30   # Delete caches older than N days (default: 30)
export MAC_OPS_CACHE_RECENT_DAYS=7     # Protect caches used within N days (default: 7)

# Example: More aggressive cache cleanup
MAC_OPS_CACHE_MAX_AGE_DAYS=30 mac-ops run --module=cache

# Example: Protect only very recent caches
MAC_OPS_CACHE_RECENT_DAYS=1 mac-ops run --module=cache
```

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

The cache cleanup module now includes **smart protection** to prevent accidental deletion of active application data:

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

> Replace `/path/to/mac-ops` with your actual installation path.

## Cautions

### Danger Process

> **WARNING**: The following commands are irreversible. Data cannot be recovered once executed.

```bash
# 1. Force cleanup - bypasses size guard (2GB limit), skips all safety prompts
mac-ops run --force

# 2. Permanently delete all trash - bypasses 72-hour grace period
sudo rm -rf ~/.mac-ops/.trash
```

| Command | Risk | What It Does |
|---------|------|--------------|
| `run --force` | **HIGH** | Skips size guard, forces cleanup of all targets including large files (>2GB) |
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

Only works when Docker Desktop is running. Automatically skipped if Docker is not installed or stopped.

### Size Guard

Single files exceeding 2GB are automatically skipped. Can be overridden with `--force` option.

## Project Structure

```
mac-ops/
├── bin/mac-ops                    # CLI entry point
├── lib/
│   ├── core/                      # Core utilities
│   │   ├── config.zsh             # Configuration loader
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
│       ├── format.zsh
│       ├── notify.zsh
│       ├── parallel.zsh
│       ├── plist-helper.zsh
│       └── snapshot.zsh
├── config/                        # Configuration files
│   ├── default.plist              # Default module enable/disable settings
│   └── ignore.example             # Example ignore file template
├── launchd/                       # launchd agents
├── scripts/                       # Utility scripts
├── demo/                          # Demo and example files
├── .github/                       # GitHub workflows and templates
└── tests/                         # Test suites
    ├── test-trash.zsh             # 18 trash system tests
    ├── test-safety.zsh            # 24 safety protection tests
    ├── test-modules.zsh           # 22 module tests
    ├── e2e/                       # 44 end-to-end tests
    └── timeout/                   # 6 timeout handling tests
```

## Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on how to submit issues, feature requests, and pull requests.

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=seunggabi/mac-ops&type=Date)](https://star-history.com/#seunggabi/mac-ops&Date)

## License

[MIT](LICENSE)

<!-- GitHub Topics: macos, cli, cleanup, disk-space, system-optimization, shell, productivity, macos-utility, zsh -->
