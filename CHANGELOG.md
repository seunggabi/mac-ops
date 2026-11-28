# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.5.0] - 2026-11-28

Safety release. Upgrading changes what a plain `mac-ops run` does: read
**Changed** before upgrading.

### Upgrade
- After `brew upgrade mac-ops`, register the agents again so they point at the
  version-independent path and pick up the new plists:
  `mac-ops monitor unsetup && mac-ops monitor setup` and `mac-ops install`.
  `mac-ops status` reports an agent plist that points at a missing (BROKEN) or
  versioned Cellar (STALE) path, with the command that fixes it.

### Changed
- Only modules that move files to the mac-ops trash run by default: `cache`,
  `tmp`, `log`, `orphan-app`. `brew` (deletes permanently), `dev`, `browser`,
  `docker`, `zombie` and `orphan` are off until enabled with
  `Modules.<name>.Enabled` in config.plist or `MAC_OPS_MODULE_<NAME>_ENABLED=true`.
  `--module=NAME` runs one module even when it is disabled.
- Modules that act on processes or data report by default; each action is opt-in:
  - `orphan`: lists candidates; `MAC_OPS_ORPHAN_ACTION=term` sends SIGTERM only
    (never SIGKILL), after re-checking the process.
  - `zombie`: reports; `MAC_OPS_ZOMBIE_ACTION=sigchld` sends SIGCHLD to the
    parent; no process is terminated.
  - `docker`: reports; `MAC_OPS_DOCKER_ACTION=prune` prunes only old unused
    images and build cache, never containers or volumes.
  - `orphan-app`: settings and data (Application Support, Preferences,
    Containers, HTTPStorages, WebKit) are reported;
    `MAC_OPS_ORPHAN_APP_DATA_ACTION=trash` moves them to the trash.
- Settings: one registry, precedence environment variable > config.plist >
  default, with command-line flags (`--dry-run`, `--verbose`, `--force`) above
  all three. An invalid value logs a WARN and falls back; an unparsable
  config.plist stops every command. `mac-ops config` shows each value and its
  source.
- Summary and notification say items were moved to the trash (purged after the
  retention period) instead of claiming the space as freed.

### Added
- Per-run manifests (`~/.mac-ops/runs/<run-id>.json`), `mac-ops runs`, and
  `mac-ops restore --run <run-id>`, which restores every item of a run that is
  still in the trash and refuses destinations that exist again.
- `mac-ops status` health section: last run, exit status, ERROR/WARN counts,
  agents loaded or overdue, run lock holder; an `[ALERT]` first line when
  something needs attention.
- A failed run (an ERROR logged or a non-zero exit) sends a notification,
  scheduled or not.

### Fixed
- Trash index: records are validated on every load (paths outside the trash
  are quarantined), an out-of-range expiry is re-stamped, retention is capped
  at 8760 hours (default 72), updates hold an fcntl lock, and entries are never
  nested or purged while a live entry is inside them. Moves into the trash are
  atomic or verified copies, and items open in a running process are not moved.
- Run lock: held for the whole run, survives PID reuse, and every exit path
  (normal, error, INT/TERM/HUP) releases it and finishes the run.
- File modules skip items that are open, recently used, owned by a running app
  or package manager, or belong to security software, and fail closed when
  that cannot be determined. mac-ops never moves its own home or a companion
  tool's directories.
- cache-cleanup never moves `ms-playwright-mcp`, and matches installed bundle
  IDs literally.
- `install` and `monitor setup` fail with an error when `launchctl load`
  fails instead of reporting success.

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
