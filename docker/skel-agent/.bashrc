export FNM_DIR="$HOME/.local/share/fnm"
export PATH="$FNM_DIR/aliases/default/bin:$PATH"
eval "$(fnm env --use-on-cd --shell bash)"

export PNPM_HOME="$HOME/.local/share/pnpm"
export PATH="$PNPM_HOME:$PATH"

export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

claude() { command claude --mcp-config "$HOME/.claude/mcp-config.json" "$@"; }
