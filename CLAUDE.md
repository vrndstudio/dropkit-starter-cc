# Dropkit with Claude Code & default installs: secure droplet dev environment

## Use case

Disposable DigitalOcean droplets as sandboxed environments for Claude Code. Each droplet is Tailscale-only, used for one project (or untrusted-repo review), then destroyed or hibernated. This repo installs user configs and preferred tools to bootstrap a fresh droplet and get started.

Primary user: freelance web developer on client projects.

## Threat model

In scope:

- Prompt injection in repo content (READMEs, issues, comments) → malicious shell commands
- Credential exfiltration (GitHub tokens, SSH keys, API keys) via the agent
- Dependency poisoning via npm postinstall in untrusted projects
- Inbound network exposure

Out of scope: outbound network restriction (Tailscale-only inbound is the perimeter); container escapes (not using containers).

Reference incidents: RoguePilot (Orca, Feb 2026), Comment-and-Control (Aonan Guan + JHU, Apr 2026), CVE-2025-59536.

## Goals

1. Fresh isolated VM per project — compromised session can't damage host or user
2. Tailnet-only inbound
3. Cheap create/destroy/hibernate; iteration in minutes
4. Pre-configured dev tooling + Claude Code
5. Project context (CLAUDE.md, .claude/) lives in the repo, travels with `git clone`

## Stack

| Layer           | Tool                                                          | Role                                                               |
| --------------- | ------------------------------------------------------------- | ------------------------------------------------------------------ |
| VM provisioning | [trailofbits/dropkit](https://github.com/trailofbits/dropkit) | DigitalOcean droplet lifecycle CLI                                 |
| Network         | Tailscale                                                     | Tailnet-only inbound; public locked down                           |
| First boot      | dropkit's `cloud-init.yaml` (unmodified)                      | User w/ NOPASSWD sudo, SSH, Tailscale, UFW, zsh, Docker            |
| Dev env         | `install.sh` from user's `dropkit-starter-cc` repo            | Node + Claude Code, ripgrep/fzf/jq/tmux, oh-my-zsh, dotfiles merge |
| Editor          | VS Code Remote-SSH                                            | Edit droplet filesystem locally                                    |
| Project config  | Repo `CLAUDE.md` + `.claude/settings.json`                    | Via a template or existing repo via `git clone`                    |

## Repo layout

- `install.sh` — bootstrap (apt + npm + oh-my-zsh + dotfiles); idempotent via marker-block merge for `.zshrc`. `INSTALL_GSD=1` adds get-shit-done.
- `set-git-identity.sh` — interactive prompt for `user.name` / `user.email`. Does **not** touch `EXA_API_KEY`.
- `.gitconfig` — aliases + editor + `pull.rebase`; no identity (set separately).
- `.zshrc` / `.aliases` — agnoster theme, oh-my-zsh plugins, fzf bindings, pnpm dev aliases.
- `.mcp.json` — context7 + exa servers. **Exa key is a placeholder**; `settings.local.json` disables exa until set.
- `.claude/CLAUDE.md` — global dev standards (Python/Node/Rust/Bash tooling, hard limits, testing policy). Applies to every project on the droplet.
- `.claude/settings.json` — model + sandbox + permission allow/deny/ask + hooks (blocks `rm -rf`, force-push to main).
- `.claude/statusline.sh` — custom statusline (model, branch, cost, context%, cache hit, progress bar).
- `.claude/commands/` — 7 slash commands: `code-review`, `fix-issue`, `review-pr`, `security-check`, `test`, `update-docs`, `update-while-working`.
- `.claude/templates/` — project-level templates (currently: `typescript-node-claude.md`).

## Credentials

- **DigitalOcean API token**: 90-day, custom scopes (23 from dropkit README), not Full Access.
- **SSH key**: existing GitHub ed25519, registered with DigitalOcean during `dropkit init`. Lets the laptop SSH _into_ droplets; grants droplets **no** GitHub access.
- **Private-repo clones** (occasional, manual) — inline fine-grained PAT, never on disk:
  ```bash
  read -s GH_TOKEN                  # paste, Enter — nothing echoed, nothing in history
  git clone https://x-access-token:$GH_TOKEN@github.com/you/repo.git
  cd repo && git remote set-url origin https://github.com/you/repo.git
  unset GH_TOKEN
  ```
  PAT scoped per-repo, 1-day expiry.

## Sandboxing layers

- Tailscale ACL: only user's tailnet reaches the droplet
- UFW (cloud-init): inbound default-deny, SSH only
- No laptop credentials on droplet at boot — closes the agent-abuse path for credential exfil
- Repo `.claude/settings.json` deny block (`Bash(curl:*)`, `WebFetch`, `Read(**/.env*)`)
- User `~/.claude/settings.json` personal hardening overlay

## References

- [trailofbits/dropkit](https://github.com/trailofbits/dropkit)
- [Claude Code settings](https://docs.claude.com/en/docs/claude-code/settings) · [memory](https://docs.claude.com/en/docs/claude-code/memory)
- [VS Code Remote-SSH](https://code.visualstudio.com/docs/remote/ssh)
- [Tailscale + other VPNs](https://tailscale.com/kb/1105/other-vpns)
- [DO API token scopes](https://docs.digitalocean.com/reference/api/scopes/)

## Next Steps

### Done

`install.sh` script:

- [x] gate gsd install behind `INSTALL_GSD=1` flag
- [x] add `bubblewrap` & `socat` to allow claude sandbox
- [x] copy dotfiles `./.claude/commands/*` to `~/.claude/commands/`
- [x] copy `./statusline.sh` to `~/.claude/`
- [x] copy `.gitconfig` directly (identity set by `set-git-identity.sh`)
- [x] install `.mcp.json` to `~/.claude/.mcp.json`
- [x] install Node 22 LTS via nvm (default alias, auto-activates in new shells via `.zshrc` init)
- [x] install `pnpm`, `npm-check-updates`, `bun`
- [x] bootstrap template repo at `~/code/template-repo/` with project-scoped `.claude/settings.json`, commands subset, `CLAUDE.md` placeholder, `.gitignore`, `.editorconfig`, plugin install doc

### Open

#### Urgent

- [ ] **Sandbox fails to start on 24.04 droplet** — `kernel.apparmor_restrict_unprivileged_userns=1` (24.04 default) blocks bubblewrap's userns, so every sandboxed command falls through to an unsandboxed prompt. Without a working sandbox, `deny` rules only bind Claude's built-in tools — **Bash subprocesses bypass them** (verified against ToB `claude-code-config`), so credential-read and outbound-exec containment is not enforced. Fix = the official per-bwrap AppArmor profile from Anthropic's sandboxing docs (grants `userns` to `/usr/bin/bwrap` only, keeps the global restriction on). Bake into `install.sh` / cloud-init; also `npm i -g @anthropic-ai/sandbox-runtime` (seccomp/unix-socket helper). Verify `bwrap --unshare-net --dev-bind / / true` exits clean. Full diagnosis + profile: `docs/permissions.md` → "Primary cause: the sandbox can't start".

#### Later

- [ ] improve `README.md`
- [ ] add step to delete cloned `dropkit-starter-cc` repo once done?
- [ ] `.mcp.json` has `EXA_API_KEY` placeholder — wire to env var or prompt in `set-git-identity.sh`
- [ ] add `shellcheck` / `shfmt` to install or as a prek hook (CLAUDE.md mandates them)

## Errors encountered while using latest droplet

- sandboxing triggers many unsandboxed interuption asks
- how to scan skills/plugins before adding
- install
  - gh (claude loves it) `sudo apt install gh`
  - `jq`
  - `npm install -g typescript-language-server typescript` for claude typescript plugin

- let me run servers and check browser myself
- how to set env variables????? (convo in cc in droplet)

### Resolved

- Node 22.13+ required for `pnpm` → install.sh now uses nvm + lts/jod (Node 22).
- `pnpm`, `npm-check-updates`, `bun` → all installed by install.sh.
- Project-scoped `.claude/settings.json` → shipped via template repo at `~/code/template-repo/`.

### Droplet size too small

`/read-codebase` command makes the connection drop
as well as `pnpm start` on a CRA app

#### Claude suggestions (verify)

One small thing: 25.10 is a non-LTS interim release (supported only 9 months, until July 2026). For a dev sandbox that's fine, but if you want stability and don't want to rebuild snapshots when support ends, switch your dropkit config to `ubuntu-24-04-x64` (LTS, supported until 2029). Refs: Ubuntu release schedule, VS Code Remote-SSH requirements.

Why pnpm start is killing your connection
Yes, almost certainly the cause. And it's not really an SSH problem, it's a RAM problem masquerading as an SSH problem. Here's what's happening on 2 GB:

VS Code Remote-SSH server: ~300-500 MB
Claude Code (Node process): ~200-400 MB
pnpm start (likely Vite/Next/whatever dev server + esbuild/swc workers): 800 MB to 1.5 GB easily
The kernel, sshd, tailscaled, your shell: ~200 MB

VSCode settings.json

```
{
  ...
  "remote.SSH.connectTimeout": 60,
  "remote.SSH.serverInstallLockTimeout": 120,
  "remote.SSH.useLocalServer": true,
  "remote.SSH.lockfilesInTmp": true,
}
```

`~/.ssh/config`
Host dropkit.\*
ServerAliveInterval 30
ServerAliveCountMax 6
TCPKeepAlive yes
