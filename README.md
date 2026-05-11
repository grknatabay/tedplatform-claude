# Tedplatform — Claude integration

Install the Tedplatform MCP server into **Claude Desktop** and/or **Claude Code CLI**
on macOS, Linux, or Windows. After install, you talk to Claude in plain language
("publish my CRM as test") and the platform provisions tenants, databases,
container builds (Kaniko), TLS certs, DNS, and exposed URLs for you.

> This repo is intentionally **public**. It contains no secrets — only the
> installer, the OAuth wiring, and the Claude skill that teaches the model
> how to use the MCP. Backend code lives in private repositories.

---

## One-line install

### macOS / Linux

```bash
curl -sSL https://raw.githubusercontent.com/grknatabay/tedplatform-claude/main/install.sh | bash
```

### Windows (PowerShell)

```powershell
iwr -useb https://raw.githubusercontent.com/grknatabay/tedplatform-claude/main/install.ps1 | iex
```

The installer is genuinely one-shot. It:

1. **Auto-installs prerequisites** if missing — `git`, `Node.js LTS`, and
   `@anthropic-ai/claude-code` (npm global). Mac uses Homebrew, Linux
   uses apt/dnf/pacman, Windows uses winget. If you already have them,
   they are skipped.
2. Opens your browser to a Keycloak login page (use your **own** account —
   `Sign in with GitHub` is supported via Keycloak's IdP federation).
3. After you click **Allow**, saves a refresh token to `~/.tedplatform/`.
4. Configures Claude Desktop and Claude Code CLI (whichever is present —
   the installer installed Claude Code for you in step 1).
5. Installs the `tedplatform-publish` skill into `~/.claude/skills/`.
6. Smoke-tests the connection (lists the live MCP tool count, expect 24).
7. Prints example prompts you can paste into Claude.

No platform secrets are baked into the installer. Your refresh token is
yours alone.

### Truly required up-front

- macOS: nothing — the installer bootstraps Homebrew-installable bits.
  (If Homebrew itself is missing, the installer prints the one-line
  Homebrew install command for you.)
- Linux: a sudo-capable account so apt/dnf can install `nodejs npm`.
- Windows: `winget` (ships with Windows 10 1809+ / Server 2022). The
  installer uses winget user-scope so no admin elevation is needed.

---

## First conversation with Claude

Restart Claude Desktop (or just run `claude` for the CLI) and try:

```
deneme1 adında Go+PG CRM yap, test olarak yayınla
```

Claude will:

1. Generate a minimal Go + Postgres app locally.
2. Call `tenant_onboard deneme1` (no confirmation — you named it explicitly).
3. Call `db_provision postgres` for the database.
4. Tar+gzip your code, call `tenant_app_build` → Kaniko in-cluster build →
   image pushed to `harbor.tederga.org/deneme1/api:sha-XXX`.
5. Apply a small Deployment + Service.
6. Call `app_expose` (DNS auto-wires for `*.tederga.org`).
7. Verify `https://test.deneme1.tederga.org/healthz` returns 200.

Other example prompts:

| Say to Claude | What happens |
|---|---|
| `ahmetbsd.com'u deneme1'in test ortamına bağla` | LE cert + HTTPProxy for your custom domain |
| `deneme1'i production'a geç` | Atomic test→prod; rewrites URL to `deneme1.tederga.org` (apex), switches custom domain too |
| `deneme1 tenant'ını sil` | Cascade delete (asks for confirmation first) |
| `deneme1'in loglarına bak` | `app_logs` tail |

The skill auto-triggers on words like **publish, deploy, yayınla, release**
combined with tedplatform context. If unsure, just ask "what can you do here?"
— the `tedplatform_help` MCP tool returns the full orchestration guide.

---

## What gets installed

| Path | Purpose |
|---|---|
| `~/.tedplatform/refresh-token` | Long-lived OAuth refresh token (chmod 600) |
| `~/.tedplatform/get-mcp-token.sh` (or `.ps1`) | Exchanges refresh → fresh access token per session |
| `~/.tedplatform/claude-mcp-launcher.sh` (or `.ps1`) | Wrapper invoked by Claude to start the MCP client |
| `~/.claude/skills/tedplatform-publish/SKILL.md` | Orchestration guide loaded by Claude on session start |
| `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS) <br> `%APPDATA%\Claude\claude_desktop_config.json` (Windows) <br> `~/.config/Claude/claude_desktop_config.json` (Linux) | Claude Desktop MCP entry (merged, not overwritten) |
| `~/.claude.json` (or `claude mcp add` user scope) | Claude Code CLI MCP entry |

To uninstall: `rm -rf ~/.tedplatform ~/.claude/skills/tedplatform-publish` plus
remove the `tedplatform` entry from your Claude Desktop config and run
`claude mcp remove tedplatform` for the CLI.

---

## Login modes

**Today** — Keycloak username/password.
Your platform operator (Ahmet/Gürkan) creates a Keycloak user for you in the
`tederga-admins` group. You enter those creds in the browser when the installer
opens it.

**Coming next** — GitHub OAuth.
Once `apply-github-federation.sh` runs against the cluster, the same Keycloak
login page will show a "Sign in with GitHub" button. Your GitHub identity (in
the right TedergaGO team) will auto-create a Keycloak user behind the scenes.
The installer code does not change — Keycloak handles the IdP layer
transparently.

---

## Re-running

Re-run the installer any time:

- to refresh an expired refresh token (default offline session ~30 days),
- to pick up a newer skill version (the installer pulls the latest `main`),
- to switch which Claude clients are configured (Desktop / CLI).

It is idempotent: existing config entries for `tedplatform` are replaced
in place; other MCP servers in your config are untouched.

---

## Troubleshooting

**`Login window expired`** — you took longer than 10 min in the browser.
Re-run the installer.

**`MCP responded but tool count was 0`** — your Keycloak account is not in the
`tederga-admins` group. Ask your platform operator.

**`Could not auto-open browser`** — copy the URL printed by the installer
into your browser manually. The verification code is also printed.

**Claude Desktop doesn't see the MCP after install** — restart the app
(quit fully, not just close window).

**`claude mcp add` fails** — your Claude Code CLI may be older. Run:
`claude --version` and update if < 0.7. Or copy the launcher path printed
at the end of the installer and add the MCP manually.

---

## Source code

| Repo | Access | Purpose |
|---|---|---|
| <https://github.com/grknatabay/tedplatform-claude> | **public** | Installer + Claude skill (this repo). No secrets — safe to fork or audit. |
| <https://github.com/grknatabay/tedplatform-mcp> | private | MCP server source (Go, mark3labs/mcp-go). Tools the platform exposes to Claude. |
| <https://github.com/grknatabay/tedplatform-infra> | private | ArgoCD `apps/`, Helm values, Vault/Keycloak/Harbor configs. |
| <https://github.com/grknatabay/tedplatform-tenant-template> | private | Starter trees (`examples/go-postgres`, `nestjs-postgres`, `nextjs`) used by `tenant_app_create`. |
| <https://github.com/grknatabay/tedplatform-ci-templates> | private | Reusable GitHub Actions workflow tenant repos call. |
| <https://github.com/grknatabay/tedplatform-backstage> | private | Operator console (Backstage) source. |
| <https://github.com/grknatabay/tedplatform-controllers> | private | AppExposure CRD reconciler. |

The private repos return **404** to anyone not invited as a collaborator —
that is GitHub's design (private repos hide their existence from
non-members). If you need access, ask your platform team to invite your
GitHub user; you'll get an email + notification.
