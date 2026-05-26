#!/bin/bash
# Combined statusline: caveman badge + wt list statusline --format=claude-code

# Read stdin once (Claude Code pipes JSON context here)
STDIN_DATA=$(cat)

# --- Caveman badge ---
FLAG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.caveman-active"
[ ! -L "$FLAG" ] && [ -f "$FLAG" ] && {
  MODE=$(head -c 64 "$FLAG" 2>/dev/null | tr -d '\n\r' | tr '[:upper:]' '[:lower:]')
  MODE=$(printf '%s' "$MODE" | tr -cd 'a-z0-9-')
  case "$MODE" in
    off|lite|full|ultra|wenyan-lite|wenyan|wenyan-full|wenyan-ultra|commit|review|compress)
      if [ -z "$MODE" ] || [ "$MODE" = "full" ]; then
        printf '\033[38;5;172m[CAVEMAN]\033[0m'
      else
        SUFFIX=$(printf '%s' "$MODE" | tr '[:lower:]' '[:upper:]')
        printf '\033[38;5;172m[CAVEMAN:%s]\033[0m' "$SUFFIX"
      fi
      ;;
  esac

  SAVINGS_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.caveman-statusline-suffix"
  if [ "${CAVEMAN_STATUSLINE_SAVINGS:-1}" != "0" ] && [ -f "$SAVINGS_FILE" ] && [ ! -L "$SAVINGS_FILE" ]; then
    SAVINGS=$(head -c 64 "$SAVINGS_FILE" 2>/dev/null | tr -d '\000-\037')
    [ -n "$SAVINGS" ] && printf ' \033[38;5;172m%s\033[0m' "$SAVINGS"
  fi

  printf ' '
}

# --- Worktrunk statusline ---
printf '%s' "$STDIN_DATA" | wt list statusline --format=claude-code 2>/dev/null
