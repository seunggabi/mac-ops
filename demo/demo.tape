# mac-ops demo tape
# Record with: cd mac-ops && vhs demo/demo.tape

Output demo/demo.gif

Set Shell "zsh"
Set FontSize 14
Set Width 800
Set Height 600
Set Theme "Catppuccin Mocha"
Set Padding 20
Set TypingSpeed 60ms

# --- Title ---
Sleep 1s
Type "# mac-ops - Safe macOS System Optimizer"
Enter
Sleep 1.5s

# --- Show version ---
Type "bin/mac-ops version"
Sleep 300ms
Enter
Sleep 2s

# --- Analyze disk space ---
Type "bin/mac-ops analyze"
Sleep 300ms
Enter
Sleep 4s

# --- Dry-run cache module ---
Type "bin/mac-ops run --dry-run --module=cache"
Sleep 300ms
Enter
Sleep 4s

# --- Show status ---
Type "bin/mac-ops status"
Sleep 300ms
Enter
Sleep 3s

# --- Show trash list ---
Type "bin/mac-ops list-trash"
Sleep 300ms
Enter
Sleep 3s

# --- End with project URL ---
Type "# https://github.com/seunggabi/mac-ops"
Sleep 300ms
Enter
Sleep 3s
