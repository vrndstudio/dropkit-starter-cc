# Dropkit Starter CC

This starter copies user configs & preferred tools to the root of a Digital Ocean droplet setup following the [Trail of Bits' Dropkit](https://github.com/trailofbits/dropkit) repo.

## Installation

Follow [dropkit setup steps](https://github.com/trailofbits/dropkit#installation).

Recommended minimum settings for new droplets:

```
Size:       s-2vcpu-4gb
Image:      ubuntu-24-04-x64             # supported til 2029
```

### Workflow

```bash
dropkit create <name>
ssh dropkit.<name>
# ... work ...
dropkit hibernate <name>   # pause billing
dropkit wake <name>        # resume
dropkit destroy <name>     # done
```

### Troubleshooting

```shell
tailscale status
tailscale ping <droplet>

dropkit off <droplet>    # if ip address differs from tailscale's
dropkit on <droplet>

dropkit enable-tailscale <droplet>

# after waking, if remote host identification has changed
ssh-kegen -R 100.103... # whatever IP the warning showed
```

### Clone this starter

Most dotfiles and defaults in this repo draw from Trail of Bit's [claude-code-config](https://github.com/trailofbits/claude-code-config/tree/main).

Once entered `ssh dropkit.<droplet>`, clone this template repo or adapt yours.

```shell
git clone https://github.com/vrndstudio/dropkit-starter-cc.git
cd dropkit-starter-cc
bash install.sh
```

shorthand:

```shell
git clone https://github.com/vrndstudio/dropkit-starter-cc.git && cd dropkit-starter-cc && bash install.sh
```

Installs:

- System: `nodejs`, `npm`, `ripgrep`, `fzf`, `jq`, `tmux`, `bubblewrap`, `socat`
- Node global: `@anthropic-ai/claude-code`, corepack (pnpm/yarn on demand)
- Shell: oh-my-zsh + `zsh-autosuggestions` + `zsh-syntax-highlighting`; sets zsh as login shell
- Dotfiles: `.gitconfig`, `.aliases`, `.zshrc` (merged — preserves cloud-init defaults, re-runs are safe), `.zshrc.local` (mode `0600`, holds env vars)
- Claude Code: `~/.claude/{CLAUDE.md, settings.json, statusline.sh, commands/, templates/}` + `~/.mcp.json`

Optional: `INSTALL_GSD=1 bash install.sh` also installs the [get-shit-done](https://github.com/JamesAndresen/get-shit-done) skill pack.

### Set git identity

Run before your first commit.

```shell
bash set-git-identity.sh
```

### Set Exa API key (optional)

`.mcp.json` references `$EXA_API_KEY` from the environment — the key itself lives in `~/.zshrc.local` (mode `0600`, git-ignored, sourced by `~/.zshrc`).
Edit it in place after first install:

```shell
nvim ~/.zshrc.local              # replace your-api-key-here with the real Exa key
exec zsh -l                      # reload so EXA_API_KEY is exported
echo "$EXA_API_KEY"              # sanity-check
```

## Usage

Start a new repo or clone one

### SSH Git Cloning

One time auth for cloning, using a fine-grained github PAT

```shell
read -s GH_TOKEN                    # paste token, press Enter, nothing echoed
echo "len: ${#GH_TOKEN}"            # sanity-check it's the expected ~93 chars
git clone https://x-access-token:${GH_TOKEN}@github.com/you/repo.git
cd repo
git remote set-url origin https://github.com/you/repo.git   # strip token from stored URL
unset GH_TOKEN
```

### Pasting multiple files from own file system

Just drag drop files into the vscode files explorer

## Development

### Maintenance

```bash
apt list --upgradable
sudo apt update
sudo apt upgrade -y
```

remove ophanated deps

### Know issues

- difficulty running 2 parallel claude sessions
- laggy commands sometimes
- only way to copy directories is pushing them as public repos?

### Next Steps

- [ ] Test against threats (described in [CLAUDE.md](./CLAUDE.md))
- [ ] dig into https://github.com/trailofbits/claude-code-config#usage for suggested usage
- [ ] add step to delete this starter once `install.sh` is complete?
