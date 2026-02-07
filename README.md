[![GitHub stars](https://img.shields.io/github/stars/seunggabi/mac-ops?style=flat&color=yellow)](https://github.com/seunggabi/mac-ops/stargazers)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](https://opensource.org/licenses/MIT)
[![Version](https://img.shields.io/github/v/release/seunggabi/mac-ops?color=blue)](https://github.com/seunggabi/mac-ops/releases)
[![macOS](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)](https://github.com/seunggabi/mac-ops)
[![Open Source Love](https://img.shields.io/badge/Open%20Source-%E2%9D%A4-red)](https://github.com/seunggabi/mac-ops)
[![Zero Dependencies](https://img.shields.io/badge/dependencies-0-brightgreen)](https://github.com/seunggabi/mac-ops)

# mac-ops

> A safe, zero-dependency macOS system optimizer with a 72-hour safety net.

macOS system optimization CLI tool. Automatically cleans up unnecessary caches, temporary files, and zombie/orphan processes.

## Quick Start

```bash
git clone https://github.com/seunggabi/mac-ops.git
cd mac-ops
bin/mac-ops run --dry-run   # Preview what will be cleaned
bin/mac-ops analyze          # See disk space report
```

## Key Features

- **72-hour safety net**: Files are moved to trash instead of immediate deletion. Recoverable if mistakes happen
- **Zero external dependencies**: Uses only macOS built-in tools (zsh, plutil, launchd)
- **5-layer safety system**: Whitelist, blacklist, size guard, process protection, lock
- **10 cleanup modules**: Cache, tmp files, logs, zombie/orphan processes, Homebrew, dev tools, Docker, browser
- **108+ test suite**: Thoroughly tested (18 trash + 24 safety + 22 modules + 44 E2E + 6 timeout)

## Installation

### From Source

```bash
git clone https://github.com/seunggabi/mac-ops.git
cd mac-ops
chmod +x bin/mac-ops
```

### Homebrew ([homebrew-mac-ops](https://github.com/seunggabi/homebrew-mac-ops))

```bash
brew tap seunggabi/mac-ops
brew install mac-ops
```

### Add to PATH (Optional)

```bash
# Add to ~/.zshrc
export PATH="/path/to/mac-ops/bin:$PATH"
```

## Usage

### Basic Commands

```bash
# Preview (dry-run) - Check cleanup targets without actual deletion
bin/mac-ops run --dry-run

# Execute cleanup
bin/mac-ops run

# Run specific module only
bin/mac-ops run --module=cache
bin/mac-ops run --module=browser
bin/mac-ops run --module=docker

# Disk space analysis report
bin/mac-ops analyze

# Verbose logging
bin/mac-ops run --verbose
```

### Available Modules

| Module | Description |
|--------|-------------|
| `cache` | Clean ~/Library/Caches (except Apple) |
| `tmp` | Clean /tmp, /private/var/folders, CrashReporter |
| `log` | Clean ~/Library/Logs, system diagnostic reports |
| `zombie` | Detect and clean zombie processes |
| `orphan` | Detect and clean orphan processes |
| `orphan-app` | Clean residual files from deleted apps |
| `brew` | Clean Homebrew caches |
| `dev` | Clean Xcode, npm, yarn, pnpm, pip, Gradle caches |
| `docker` | Clean Docker dangling images, stopped containers, unused volumes |
| `browser` | Clean Safari, Chrome, Firefox caches |

### Trash Management

```bash
# List trash contents
bin/mac-ops list-trash

# Restore accidentally deleted files
bin/mac-ops restore ~/Library/Caches/com.important.app

# Immediately purge expired items
bin/mac-ops purge

# Check current status (trash, disk usage, launchd status)
bin/mac-ops status
```

### Miscellaneous

```bash
# Check current configuration
bin/mac-ops config

# Check version
bin/mac-ops version

# Show help
bin/mac-ops help
```

## Scheduled Execution

### Method 1: launchd (Recommended)

macOS native scheduler runs automatically every hour. Catches up on missed tasks when waking from sleep.

```bash
# Install
bin/mac-ops install
```

```bash
# Uninstall
bin/mac-ops uninstall
```

### Method 2: crontab

```bash
crontab -e
```

Add the following content:

```cron
# Run mac-ops every hour
0 * * * * /path/to/mac-ops/bin/mac-ops run --scheduled 2>&1 >> ~/.mac-ops/.logs/cron.log

# Or run daily at 3 AM
0 3 * * * /path/to/mac-ops/bin/mac-ops run --scheduled 2>&1 >> ~/.mac-ops/.logs/cron.log
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
1. Run `bin/mac-ops list-trash` to check what is in the trash
2. Run `bin/mac-ops run --dry-run` to preview cleanup targets
3. Restore any important files with `bin/mac-ops restore <path>`

### Full Disk Access Permission Required

Due to macOS TCC policy, **Full Disk Access** permission is required to access certain paths like `~/Library/Caches`, `~/Library/Logs`.

```
System Settings > Privacy & Security > Full Disk Access
```

Add Terminal.app (or iTerm, Warp, etc. depending on your terminal). For launchd automatic execution, add the `mac-ops` binary itself to the FDA list.

### Run dry-run First

When using for the first time, always check what files will be cleaned with `--dry-run`.

```bash
bin/mac-ops run --dry-run
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
| `~/Documents/*`, `~/Desktop/*` | User documents |
| `/Library/LaunchDaemons/*` | System services |

### Processes Never Killed

```
kernel_task, launchd, WindowServer, loginwindow,
SystemUIServer, Finder, cfprefsd, mds, mds_stores
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
│   │   └── disk.zsh               # Disk monitoring
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
│   │   └── analyze.zsh
│   └── utils/                     # Shared utilities
│       ├── format.zsh
│       ├── notify.zsh
│       ├── parallel.zsh
│       ├── plist-helper.zsh
│       └── snapshot.zsh
├── config/                        # Configuration files
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

MIT
