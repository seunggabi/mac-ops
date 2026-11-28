# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.5.0] - 2026-11-28

Safety release: everything that deletes, moves or signals now defaults to the
safe choice, and failures are visible without repeating forever.

### Changed
- Modules: only cache, tmp, log and orphan-app (move to the mac-ops trash)
  are enabled by default; brew, dev, browser, docker, zombie and orphan are
  off until enabled. `Modules.<name>.Enabled` accepts only true/false
  (`yes`, `1`, `TRUE` never enable a module) (#52)
- Process modules report by default: orphan-killer sends SIGTERM only with
  `Action=term` and never SIGKILL; zombie-killer only sends SIGCHLD with
  `Action=sigchld`; both re-verify before signalling and never touch
  security software, protected processes or their own process tree
  (#43, #50)
- docker-cleanup reports by default; `Action=prune` prunes only old unused
  images and build cache, never containers or volumes (#50)
- orphan-app: settings/data locations (Application Support, Preferences,
  Containers, HTTPStorages, WebKit) are reported, not moved, unless
  `DataAction=trash`; nested and same-vendor bundle IDs count as installed;
  report-only when Spotlight is incomplete (#42, #50)
- tmp, log, cache, browser, dev: items in use, of running apps, recently
  used, sockets, security software and protected names are skipped;
  diagnostic reports are kept at least 30 days (#45)
- Settings: one registry with env > config.plist > default precedence and
  validation; CLI flags win; an unparsable config.plist aborts (#52)
- An item larger than `MaxSingleFileBytes` is skipped with a WARN naming
  the limit instead of an ERROR on every run (#56)
- Notifications: a failed run is notified (scheduled or manual), the same
  failure at most once per `Notify.FailureRepeatHours` (24); a successful
  run only with `Notify.OnSuccess` (#52, #56)

### Fixed
- Trash index: never rewritten without the lock, atomic writes, unique keys,
  reconcile and recovery of lost entries, control characters in names
  escaped (#44, #52)
- Trash index paths are untrusted: records pointing outside the trash, at a
  bookkeeping file (in any letter case) or through a symlink are never
  purged; restore refuses relative, `..` and protected destinations (#52, #56)
- Empty or unparsable `expire_after` no longer keeps an item forever; a
  trashed empty directory is no longer swept away before it can be
  restored (#52, #56)
- Restore never overwrites or nests into a destination that appeared (#52)
- A cache directory moved by another module first is a skip, not a run
  error (#56)
- Run lock with PID reuse detection; `status` shows the lock holder, a hung
  run, a failed or overdue scheduled run, run manifests and
  `restore --run` (#52)
- launchd: install writes the upgrade-safe path; a failed `launchctl load`
  is now an error (#44, #56)
- Nine system daemons (diskarbitrationd, configd, UserEventAgent, trustd,
  securityd, syslogd, notifyd, logd, powerd) are protected processes; the
  unread config/protected-processes.plist is removed (#56)
- cache-cleanup never moves ms-playwright-mcp (#56)

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
