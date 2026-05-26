#!/bin/bash
# Combined statusline: caveman badge + wt worktree info.
# Claude Code statusLine supports one command — this wrapper outputs both.

STDIN_DATA=$(cat)

# Caveman badge — delegate to caveman's own installed script (dynamic path,
# resilient to SHA changes in the plugin cache).
CAVEMAN_SL=$(find "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache/caveman" \
  -name "caveman-statusline.sh" 2>/dev/null | head -1)
[ -n "$CAVEMAN_SL" ] && { bash "$CAVEMAN_SL"; printf ' '; }

# Worktrunk statusline
printf '%s' "$STDIN_DATA" | wt list statusline --format=claude-code 2>/dev/null
