# Contributing to mac-ops

Thank you for your interest in contributing to mac-ops! This guide will help you get started with development and explain how to contribute effectively.

## Getting Started

1. **Clone the repo**
   ```bash
   git clone https://github.com/yourusername/mac-ops.git
   cd mac-ops
   ```

2. **Run tests** to ensure everything works
   ```bash
   zsh tests/test-trash.zsh
   zsh tests/test-safety.zsh
   zsh tests/test-modules.zsh
   ```

3. **Try a dry run** to see the tool in action
   ```bash
   bin/mac-ops run --dry-run
   ```

All tests should pass before making changes.

## Development Setup

### Requirements
- macOS 13 or later
- zsh (default macOS shell)
- No external dependencies needed

### Why Minimal Dependencies?
mac-ops uses only macOS built-in tools to ensure:
- No package manager overhead (Homebrew not required for the tool itself)
- Reliability across different macOS configurations
- Fast execution with minimal startup time
- Maximum portability and system safety

## Project Structure

```
mac-ops/
├── bin/
│   └── mac-ops              # CLI entry point with strict mode (ERR_EXIT, PIPE_FAIL)
├── lib/
│   ├── core/                # Core functions (module execution, dry-run)
│   ├── modules/             # Cleanup modules (cache, tmp, log, zombie, etc.)
│   └── utils/               # Shared utilities (logging, color, trash, safety)
├── config/
│   └── default.plist        # Default configuration for modules
├── launchd/                 # Scheduled execution setup
├── tests/                   # Test suites
└── README.md, LICENSE       # Documentation
```

### Key Directories

- **bin/**: Entry point handling CLI arguments, module discovery, and execution
- **lib/core/**: Core execution logic for running modules and managing dry-run mode
- **lib/modules/**: Individual cleanup modules (each handles one cleanup task)
- **lib/utils/**: Shared utilities for logging, colors, trash management, process safety
- **config/**: Default configuration via plist (module settings, exclusions, paths)
- **tests/**: Comprehensive test suites using custom assertions

## Coding Conventions

### Strict Shell Options
All scripts use the following options for safety:
```bash
setopt ERR_EXIT PIPE_FAIL
```
This ensures the script exits on any error and catches pipe failures.

### Variable Declaration
- All variables must be declared with `local` inside functions
- Global variables should be avoided when possible
- Use descriptive names in lowercase with underscores

### Naming Conventions
- **Public functions**: Prefix with `mac_ops_` (e.g., `mac_ops_cleanup_cache`)
- **Private/internal functions**: Prefix with `_mac_ops_` (e.g., `_mac_ops_parse_args`)
- **Module main function**: `mac_ops_<module_name>()` (e.g., `mac_ops_cleanup_cache`)

### Logging
All log messages must use the centralized logging utilities:
- `mac_ops_log_info "message"` - Informational messages
- `mac_ops_log_warn "message"` - Warnings
- `mac_ops_log_error "message"` - Errors
- `mac_ops_log_debug "message"` - Debug information (if enabled)

### Comments and Messages
- All comments and user-facing messages must be in English
- Comments should explain the "why", not the "what"
- Use clear, concise language

### Code Style
- Use 2-space indentation
- Keep functions focused and reasonably sized
- Use meaningful variable names
- Avoid deep nesting where possible

## Adding a New Cleanup Module

Creating a new cleanup module is the primary way to extend mac-ops.

### Step-by-Step Guide

#### 1. Create the module file
Create `lib/modules/my-cleanup.zsh` with the main function:

```bash
#!/bin/zsh
# My cleanup module description

mac_ops_my_cleanup() {
    local dry_run="${1:-false}"

    mac_ops_log_info "Cleaning up my resources..."

    # Your cleanup logic here

    if [[ "$dry_run" == "true" ]]; then
        mac_ops_log_info "Would clean up X files (dry-run mode)"
    else
        # Perform actual cleanup
        mac_ops_log_info "Cleaned up X files"
    fi
}
```

#### 2. Source the module in `bin/mac-ops`
Add a source line in the module loading section:
```bash
source "$SCRIPT_DIR/../lib/modules/my-cleanup.zsh"
```

#### 3. Register in the module map
Add your module to the module discovery in `bin/mac-ops`:
```bash
mac_ops["my-cleanup"]="mac_ops_my_cleanup"
```

#### 4. Parallel execution (if applicable)
If your module performs file-based operations that don't block each other, add it to the parallel execution array:
```bash
PARALLEL_MODULES+=(mac_ops_my_cleanup)
```

#### 5. Add configuration (if needed)
Update `config/default.plist` with any module-specific settings:
```xml
<key>my-cleanup</key>
<dict>
    <key>enabled</key>
    <true/>
    <key>exclude-paths</key>
    <array>
        <string>/path/to/exclude</string>
    </array>
</dict>
```

#### 6. Write tests
Add test cases to `tests/test-modules.zsh`:
```bash
test_my_cleanup_basic() {
    local temp_dir=$(mktemp -d)
    # Setup test data

    mac_ops_my_cleanup false

    # Verify results
    assert_eq "expected" "actual" "Test description"

    rm -rf "$temp_dir"
}
```

#### 7. Document the module
Update README.md with:
- What the module cleans up
- What it safely skips
- Any important notes or warnings

## Testing

### Test Framework
mac-ops uses a custom lightweight test framework with these assertion functions:
- `assert_eq "expected" "actual" "message"` - Equality check
- `assert_true "condition" "message"` - Boolean assertion
- `assert_exit_code "expected" "command" "message"` - Exit code check
- `assert_file_exists "path" "message"` - File existence check

### Running Tests

Run all tests:
```bash
zsh tests/test-trash.zsh
zsh tests/test-safety.zsh
zsh tests/test-modules.zsh
```

Run a specific test file:
```bash
zsh tests/test-modules.zsh
```

### Test Safety
- Tests use temporary directories created with `mktemp -d`
- Tests never touch real system directories
- Cleanup is automatic; no manual intervention needed
- All 64 tests pass reliably

### Writing Good Tests
- Use temporary directories for all file operations
- Test both success and failure paths
- Verify side effects (files deleted, logs generated)
- Test with dry-run mode enabled
- Add clear descriptive messages to assertions

## Pull Request Process

1. **Fork the repository** on GitHub

2. **Create a feature branch** with a descriptive name
   ```bash
   git checkout -b feature/add-new-module
   ```

3. **Write tests first** (or alongside your code)
   - Add test cases to `tests/test-modules.zsh`
   - Ensure tests pass before submitting

4. **Ensure all tests pass**
   ```bash
   zsh tests/test-trash.zsh && zsh tests/test-safety.zsh && zsh tests/test-modules.zsh
   ```

5. **Make commits with clear messages**
   - Use present tense ("Add feature" not "Added feature")
   - Reference issues if applicable

6. **Submit a pull request** with:
   - Clear title describing what you've done
   - Description of the changes and why they're needed
   - Reference to any related issues
   - Confirmation that all tests pass

## Code of Conduct

We are committed to providing a welcoming and inspiring community for all. Please be:

- **Respectful**: Treat all community members with respect
- **Constructive**: Provide helpful feedback and suggestions
- **Inclusive**: Welcome diverse perspectives and backgrounds
- **Professional**: Keep discussions focused on the project and its goals

Unacceptable behavior (harassment, discrimination, etc.) will not be tolerated. Report concerns to the maintainers.

---

Thank you for contributing to mac-ops! Your help makes this tool better for everyone.
