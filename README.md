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

1. **Auto-installs prerequisites** if missing, **skips them if present**:
   - `git`
   - `Node.js LTS` (≥ v18 — checked, upgrades older Node automatically)
   - `@anthropic-ai/claude-code` (Claude Code CLI, via `npm install -g`)
   - `Claude Desktop` (Mac via `brew install --cask claude`, Windows via
     `winget install Anthropic.Claude`; Linux: skipped, no official build)

   Each tool is detected before install (`command -v` / `Get-Command` /
   known file paths). Existing installations are respected — including
   custom Node managers (nvm, fnm, volta) and Claude Desktop installed
   manually from claude.ai/download.
2. Opens your browser to a Keycloak login page. Sign in with **your own
   account** — either Keycloak username/password OR "Sign in with GitHub"
   (federation live).
3. After you click **Allow**, saves a refresh token to `~/.tedplatform/`.
4. Configures **both** Claude Desktop and Claude Code CLI MCP entries
   (whichever is present — typically both, since step 1 installed them).
   The Claude Desktop config dir is force-created so the entry is in
   place even if you have not opened Claude yet.
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

The Keycloak login page the installer opens supports two paths — pick
whichever your platform team has set up for you:

- **Sign in with GitHub** (recommended). Your GitHub identity (must be a
  member of the `TedergaGO/tedplatform-admins` team) federates into a
  Keycloak account automatically on first login. Nothing for the
  operator to provision per developer.
- **Keycloak username/password**. The platform operator creates a
  Keycloak user for you in the `tederga-admins` group; you enter those
  creds in the browser. Useful when GitHub federation isn't desired or
  for service accounts.

Either way, the device-code flow itself is the same — the installer
script doesn't care which path you took.

---

## Re-running

The installer is **idempotent** — re-running it N times does nothing
already done. Concretely:

- Already-installed tools (git / Node / Claude Code / Claude Desktop)
  are detected and **skipped**, never re-installed or re-downloaded.
- Existing `tedplatform` MCP entries in your Claude configs are replaced
  in place; other MCP servers you may have configured are **left untouched**.
- The skill at `~/.claude/skills/tedplatform-publish/` is replaced with
  the latest `main` version each run (so re-running is also how you
  update the skill).
- Your refresh token in `~/.tedplatform/refresh-token` is overwritten
  with the new device-flow result; old token is invalidated server-side
  by Keycloak only when explicitly revoked.

When to re-run:
- Refresh an expired refresh token (default offline session ~30 days).
- Pull a newer skill version.
- Add a Claude client you didn't have before (e.g. you installed Claude
  Desktop manually, then re-run to wire it).

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
