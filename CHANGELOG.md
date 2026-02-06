# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2025-02-07

### Added
- CLI entry point (`bin/mac-ops`) with ERR_EXIT/PIPE_FAIL strict mode
- 10 cleanup modules: cache, tmp, log, zombie, orphan, orphan-app, brew, dev, docker, browser
- Disk space analyzer (`analyze` command)
- 72-hour trash retention system with restore capability
- 5-layer safety system: whitelist, blacklist, size guard, process protection, lock
- Protected paths and processes lists
- Parallel execution for file cleanup modules
- launchd agent for scheduled execution (hourly)
- crontab-based installation via install.sh
- Log rotation (5MB max, 7 files)
- Dry-run mode for safe preview
- plist-based configuration system
- macOS native notifications on completion
- 64 tests across 3 test suites (trash, safety, modules)
