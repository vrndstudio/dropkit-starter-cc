# ─── Environment ──────────────────────────────────────────
export EDITOR="nvim"

alias vim="nvim"

# ─── Oh My Zsh ────────────────────────────────────────────
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="agnoster"

plugins=(
  git
  node
  npm
  z
  zsh-autosuggestions
  zsh-syntax-highlighting
)

source $ZSH/oh-my-zsh.sh

# ─── Aliases (kept in a separate file for tidiness) ───────
[ -f "$HOME/.aliases" ] && source "$HOME/.aliases"

# fzf integration (after the other env vars):
[ -f /usr/share/doc/fzf/examples/key-bindings.zsh ] && source /usr/share/doc/fzf/examples/key-bindings.zsh
[ -f /usr/share/doc/fzf/examples/completion.zsh ]   && source /usr/share/doc/fzf/examples/completion.zsh

# ─── nvm (loads default Node version on every shell) ──────
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

# ─── bun ──────────────────────────────────────────────────
export BUN_INSTALL="$HOME/.bun"
[ -d "$BUN_INSTALL/bin" ] && export PATH="$BUN_INSTALL/bin:$PATH"

# --- local config ----
[[ -f ~/.zshrc.local ]] && source ~/.zshrc.local