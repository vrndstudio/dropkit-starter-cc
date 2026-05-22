#!/usr/bin/env bash
# droplet dev environment setup

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="$SCRIPT_DIR"

if [ ! -f "$DOTFILES_DIR/.zshrc" ] && [ ! -f "$DOTFILES_DIR/.gitconfig" ]; then
  cat >&2 <<EOF
ERROR: $DOTFILES_DIR doesn't look like the dotfiles repo
       (no .zshrc or .gitconfig found alongside this script).
Clone the repo first, then run this script from inside it:
  git clone https://github.com/<user>/dotfiles.git
  cd dotfiles
  bash bootstrap.sh
EOF
  exit 1
fi

echo "==> Using dotfiles at $DOTFILES_DIR"

echo "==> Updating apt"
sudo apt-get update -qq

echo "==> Installing system packages"
# git, curl, zsh, ca-certificates already provided by dropkit's cloud-init.
sudo apt-get install -y -qq \
  ripgrep \
  fzf \
  jq \
  tmux \
  bubblewrap \
  socat \
  unzip

echo "==> Installing nvm + Node 22 LTS (Jod) as default"
export NVM_DIR="$HOME/.nvm"
if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
fi
# shellcheck disable=SC1091
\. "$NVM_DIR/nvm.sh"
nvm install --lts=jod
nvm alias default lts/jod
nvm use default

echo "==> Installing Claude Code"
npm install -g @anthropic-ai/claude-code

echo "==> Installing pnpm + npm-check-updates"
npm install -g pnpm npm-check-updates

echo "==> Installing bun"
if [ ! -x "$HOME/.bun/bin/bun" ]; then
  curl -fsSL https://bun.sh/install | bash
fi
export PATH="$HOME/.bun/bin:$PATH"

echo "==> Installing oh-my-zsh (unattended, keeping our own .zshrc)"
if [ ! -d "$HOME/.oh-my-zsh" ]; then
  RUNZSH=no CHSH=no KEEP_ZSHRC=yes \
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended --keep-zshrc
fi

ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

echo "==> Installing zsh plugins"
for plugin in zsh-autosuggestions zsh-syntax-highlighting; do
  dest="$ZSH_CUSTOM/plugins/$plugin"
  if [ ! -d "$dest" ]; then
    git clone --depth=1 "https://github.com/zsh-users/$plugin" "$dest"
  else
    git -C "$dest" pull --ff-only --quiet || true
  fi
done

# Marker-block append strategy for files cloud-init already populates
# (.gitconfig owns [user]; .zshrc has minimal cloud-init defaults). We
# bracket our additions with these markers so re-runs replace only our
# block and leave cloud-init's preamble alone.
MARK_BEGIN="# >>> dotfiles bootstrap >>>"
MARK_END=" # <<< dotfiles bootstrap <<<"

merge_append() {
  local src="$1" dst="$2"
  [ -f "$src" ] || return 0
  touch "$dst"
  if grep -qF "$MARK_BEGIN" "$dst"; then
    sed -i "/^${MARK_BEGIN}\$/,/^${MARK_END}\$/d" "$dst"
  fi
  {
    echo ""
    echo "$MARK_BEGIN"
    cat "$src"
    echo "$MARK_END"
  } >> "$dst"
}

copy_dotfile() {
  local src="$1" dst="$2"
  [ -f "$src" ] || return 0
  install -m 0644 "$src" "$dst"
}

copy_script() {
  local src="$1" dst="$2"
  [ -f "$src" ] || return 0
  install -m 0755 "$src" "$dst"
}

copy_dir() {
  local src="$1" dst="$2"
  [ -d "$src" ] || return 0
  mkdir -p "$dst"
  cp -r "$src"/. "$dst"/
}

copy_secret_if_missing() {
  local src="$1" dst="$2"
  [ -f "$src" ] || return 0
  if [ -f "$dst" ]; then
    echo "    skip $dst (already exists — edit in place to set real key)"
    return 0
  fi
  install -m 0600 "$src" "$dst"
}

echo "==> Copying .gitconfig (identity set separately by set-git-identity.sh)"
copy_dotfile "$DOTFILES_DIR/.gitconfig" "$HOME/.gitconfig"

echo "==> Merging .zshrc (preserving cloud-init's defaults)"
merge_append "$DOTFILES_DIR/.zshrc" "$HOME/.zshrc"

echo "==> Seeding ~/.zshrc.local (mode 0600, only if missing)"
copy_secret_if_missing "$DOTFILES_DIR/.zshrc.local" "$HOME/.zshrc.local"

echo "==> Copying .aliases"
copy_dotfile "$DOTFILES_DIR/.aliases" "$HOME/.aliases"

echo "==> Copying user-level Claude Code config"
mkdir -p "$HOME/.claude"
copy_dotfile "$DOTFILES_DIR/.claude/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
copy_dotfile "$DOTFILES_DIR/.claude/settings.json" "$HOME/.claude/settings.json"
copy_dotfile "$DOTFILES_DIR/.mcp.json" "$HOME/.mcp.json"
copy_script "$DOTFILES_DIR/.claude/statusline.sh" "$HOME/.claude/statusline.sh"
copy_dir "$DOTFILES_DIR/.claude/commands" "$HOME/.claude/commands"
copy_dir "$DOTFILES_DIR/.claude/templates" "$HOME/.claude/templates"

if [[ "${INSTALL_GSD:-0}" == "1" ]]; then
  echo "==> Installing get-shit-done (Claude global skill)"
  npx -y get-shit-done-cc@latest --claude --global
else
  echo "==> Skipping get-shit-done install (set INSTALL_GSD=1 to enable)"
fi

echo "==> Setting zsh as login shell"
zsh_path="$(command -v zsh)"
current_shell="$(getent passwd "$USER" | cut -d: -f7)"
if [ "$current_shell" != "$zsh_path" ]; then
  sudo chsh -s "$zsh_path" "$USER"
fi

echo "==> Done."
echo
echo "Verify (open a new shell first so nvm + bun are on PATH):"
echo "  nvm --version"
echo "  node --version              # expect v22.x (lts/jod)"
echo "  pnpm --version"
echo "  bun --version"
echo "  ncu --version"
echo "  claude --version"
echo "  rg --version"
echo "  echo \$SHELL                # expect /usr/bin/zsh after next login"
echo "  grep -A1 'dotfiles' ~/.gitconfig | head -20"
echo
echo "Open a new shell (zsh) or run: exec zsh -l"
echo
echo "For private-repo clones from this droplet, paste a short-lived fine-grained PAT:"
echo '  read -s GH_TOKEN          # paste, Enter — nothing echoed, nothing in history'
echo '  git clone "https://x-access-token:$GH_TOKEN@github.com/<you>/<repo>.git"'
echo '  cd <repo> && git remote set-url origin https://github.com/<you>/<repo>.git'
echo '  unset GH_TOKEN'

