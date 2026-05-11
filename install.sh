#!/usr/bin/env bash
# Tedplatform — one-shot Claude integration installer (macOS / Linux).
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/grknatabay/tedplatform-claude/main/install.sh | bash
#
# Does:
#   1. Browser-based OAuth (Keycloak Device Code flow) — you click "Allow" once.
#   2. Saves a long-lived refresh token to ~/.tedplatform/refresh-token (chmod 600).
#   3. Writes ~/.tedplatform/get-mcp-token.sh that exchanges the refresh token
#      for a fresh access token on every Claude session.
#   4. Adds the Tedplatform MCP server to:
#        • Claude Desktop  (~/Library/Application Support/Claude/claude_desktop_config.json
#                           on macOS, ~/.config/Claude/ on Linux)
#        • Claude Code CLI (via `claude mcp add` if found in PATH)
#   5. Installs the `tedplatform-publish` skill into ~/.claude/skills/.
#   6. Prints example prompts you can paste into Claude.
#
# Prereqs: bash, curl, jq, python3 (for JSON merge), an existing Keycloak
# user in the `tederga-admins` group. No GitHub PAT needed.

set -euo pipefail

# ---------- config (override via env) ----------
KC_URL="${KEYCLOAK_URL:-https://keycloak.tederga.org}"
KC_REALM="${KC_REALM:-operators}"
KC_CLIENT="${KC_CLIENT:-tedplatform-cli}"
MCP_URL="${TEDPLATFORM_MCP_URL:-https://mcp.tederga.org/mcp}"
INSTALL_REPO_RAW="https://raw.githubusercontent.com/grknatabay/tedplatform-claude/main"
INSTALL_REPO_GIT="https://github.com/grknatabay/tedplatform-claude"

DOTDIR="${HOME}/.tedplatform"
SKILL_DIR="${HOME}/.claude/skills/tedplatform-publish"

# ---------- helpers ----------
say()  { printf "\033[36m%s\033[0m\n" "$*"; }
ok()   { printf "\033[32m✓ %s\033[0m\n" "$*"; }
warn() { printf "\033[33m! %s\033[0m\n" "$*"; }
die()  { printf "\033[31m✗ %s\033[0m\n" "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null || die "Required: $1 (install with brew/apt)"; }
need curl
need jq
need python3

OS="$(uname -s)"
case "$OS" in
  Darwin) OPENER="open" ;;
  Linux)  OPENER="xdg-open" ;;
  *)      die "Unsupported OS: $OS (use install.ps1 on Windows)" ;;
esac

# ---------- 0. auto-install Node.js + Claude Code CLI ----------
# The MCP launcher (used by both Claude Desktop and Claude Code) is
# `npx -y mcp-remote ...`, which requires Node.js. And there's no
# point installing the MCP entry if the user has no Claude client.
# We install both automatically here so the install is genuinely
# one-shot — no follow-up "go install X then re-run" cycles.

ensure_node() {
  if command -v node >/dev/null 2>&1 && command -v npx >/dev/null 2>&1; then
    NODE_MAJOR=$(node -v | sed 's/^v\([0-9]*\)\..*/\1/')
    if [ -n "$NODE_MAJOR" ] && [ "$NODE_MAJOR" -ge 18 ] 2>/dev/null; then
      ok "Node.js found: $(node -v) (already installed - skipping)"
      return 0
    fi
    warn "Node.js $(node -v) is too old; mcp-remote requires v18+. Upgrading..."
  fi
  say "Node.js not found - installing automatically..."
  case "$OS" in
    Darwin)
      if command -v brew >/dev/null 2>&1; then
        brew install node >/dev/null || die "brew install node failed"
      else
        die "Homebrew not found. Install it first:
  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"
Then re-run this installer."
      fi
      # Apple Silicon brew lives in /opt/homebrew; Intel in /usr/local. Make
      # both visible to the rest of this script run.
      for d in /opt/homebrew/bin /usr/local/bin; do
        [ -d "$d" ] && case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH" ;; esac
      done
      export PATH
      ;;
    Linux)
      if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -qq && sudo apt-get install -y nodejs npm \
          || die "apt-get install nodejs failed - try installing manually from https://nodejs.org/"
      elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y nodejs npm \
          || die "dnf install nodejs failed - try installing manually from https://nodejs.org/"
      elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -S --noconfirm nodejs npm \
          || die "pacman install nodejs failed - try installing manually from https://nodejs.org/"
      else
        die "No supported package manager. Install Node.js manually: https://nodejs.org/"
      fi
      ;;
  esac
  command -v node >/dev/null 2>&1 \
    || die "Node install completed but 'node' is not in PATH. Open a new terminal and re-run."
  ok "Node.js installed: $(node -v)"
}

ensure_claude_cli() {
  if command -v claude >/dev/null 2>&1; then
    ok "Claude Code CLI found: $(claude --version 2>/dev/null | head -1) (already installed - skipping)"
    return 0
  fi
  say "Claude Code CLI not found - installing globally via npm..."
  if ! npm install -g @anthropic-ai/claude-code >/dev/null 2>&1; then
    warn "npm global install failed (likely a permissions issue with the npm prefix)."
    warn "Trying with sudo..."
    sudo npm install -g @anthropic-ai/claude-code >/dev/null \
      || die "Could not install claude-code. Try manually: sudo npm install -g @anthropic-ai/claude-code"
  fi
  # npm global bin needs to be in PATH for the rest of this run.
  NPM_BIN="$(npm config get prefix 2>/dev/null)/bin"
  if [ -n "$NPM_BIN" ] && [ -d "$NPM_BIN" ]; then
    case ":$PATH:" in *":$NPM_BIN:"*) ;; *) PATH="$NPM_BIN:$PATH"; export PATH ;; esac
  fi
  if ! command -v claude >/dev/null 2>&1; then
    warn "Claude Code installed but 'claude' is not yet in PATH for this shell."
    warn "After this installer finishes, open a new terminal to use it."
  else
    ok "Claude Code installed: $(claude --version 2>/dev/null | head -1)"
  fi
}

ensure_claude_desktop() {
  case "$OS" in
    Darwin)
      if [ -d "/Applications/Claude.app" ]; then
        ok "Claude Desktop found (/Applications/Claude.app - already installed, skipping)"
        return 0
      fi
      if ! command -v brew >/dev/null 2>&1; then
        warn "Claude Desktop not installed and Homebrew unavailable - skipping."
        warn "  Install manually from https://claude.ai/download if you want the GUI."
        return 0
      fi
      say "Claude Desktop not found - installing via brew cask..."
      if brew install --cask claude >/dev/null 2>&1; then
        ok "Claude Desktop installed (/Applications/Claude.app)"
      else
        warn "brew install --cask claude failed (cask may have been renamed)."
        warn "  Install manually from https://claude.ai/download"
      fi
      ;;
    Linux)
      # Claude Desktop has no official Linux build yet; CLI is the only path.
      :
      ;;
  esac
}

ensure_node
ensure_claude_cli
ensure_claude_desktop

# ---------- 1. device flow ----------
say "═══ Tedplatform Claude installer ═══"
say "Starting browser-based login (Keycloak device code)…"

mkdir -p "$DOTDIR"
chmod 700 "$DOTDIR"

DEVICE_RESP=$(curl -sSf -X POST \
  "$KC_URL/realms/$KC_REALM/protocol/openid-connect/auth/device" \
  -d "client_id=$KC_CLIENT" \
  -d "scope=openid profile email groups offline_access")

DEVICE_CODE=$(echo "$DEVICE_RESP" | jq -r .device_code)
USER_CODE=$(echo "$DEVICE_RESP" | jq -r .user_code)
VERIFY_URL=$(echo "$DEVICE_RESP" | jq -r .verification_uri_complete)
INTERVAL=$(echo "$DEVICE_RESP" | jq -r .interval)
EXPIRES_IN=$(echo "$DEVICE_RESP" | jq -r .expires_in)

[ -z "$DEVICE_CODE" ] || [ "$DEVICE_CODE" = "null" ] && die "Device flow failed: $DEVICE_RESP"

cat <<EOF

   ┌────────────────────────────────────────────────────┐
   │  Open the following URL in your browser:           │
   │                                                    │
   │  $VERIFY_URL
   │                                                    │
   │  Verification code: $USER_CODE                          │
   │                                                    │
   │  Login with your Keycloak account, then click      │
   │  "Yes" / "Grant Access".                           │
   └────────────────────────────────────────────────────┘

EOF

# Best-effort browser open (ignore failure — user can copy/paste).
"$OPENER" "$VERIFY_URL" >/dev/null 2>&1 || warn "Could not auto-open browser. Copy the URL above."

say "Waiting for you to approve in the browser (timeout ${EXPIRES_IN}s)…"
DEADLINE=$(( $(date +%s) + EXPIRES_IN ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  sleep "$INTERVAL"
  TOK_RESP=$(curl -sS -X POST \
    "$KC_URL/realms/$KC_REALM/protocol/openid-connect/token" \
    -d "client_id=$KC_CLIENT" \
    -d "device_code=$DEVICE_CODE" \
    -d "grant_type=urn:ietf:params:oauth:grant-type:device_code")
  ERR=$(echo "$TOK_RESP" | jq -r '.error // empty')
  case "$ERR" in
    "")
      ACCESS=$(echo "$TOK_RESP" | jq -r .access_token)
      REFRESH=$(echo "$TOK_RESP" | jq -r .refresh_token)
      [ -n "$ACCESS" ] && [ "$ACCESS" != "null" ] && break
      ;;
    "authorization_pending"|"slow_down")
      printf "."
      ;;
    "expired_token")
      die "Login window expired. Re-run the installer."
      ;;
    "access_denied")
      die "You clicked 'No' / 'Cancel' in the browser. Re-run if that was a mistake."
      ;;
    *)
      die "Token endpoint error: $TOK_RESP"
      ;;
  esac
done
echo
[ -z "${ACCESS:-}" ] && die "Timed out waiting for browser approval."
ok "Logged in (access token: ${#ACCESS} chars, refresh token: ${#REFRESH} chars)"

# ---------- 2. cache refresh token + writer ----------
echo "$REFRESH" > "$DOTDIR/refresh-token"
chmod 600 "$DOTDIR/refresh-token"

cat > "$DOTDIR/get-mcp-token.sh" <<EOF
#!/usr/bin/env bash
# Auto-generated by tedplatform-claude installer. Do not edit by hand.
# Exchanges the cached refresh token for a fresh access token (printed to stdout).
# Re-run the installer if the refresh token expires (default ~30d offline session).
set -euo pipefail
REFRESH=\$(cat "${DOTDIR}/refresh-token")
RESP=\$(curl -sSf -X POST \\
  "${KC_URL}/realms/${KC_REALM}/protocol/openid-connect/token" \\
  -d "client_id=${KC_CLIENT}" \\
  -d "grant_type=refresh_token" \\
  -d "refresh_token=\${REFRESH}")
ACC=\$(echo "\$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
# Rotate refresh token if Keycloak issued a new one (default 'use refresh token rotation').
NEW=\$(echo "\$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('refresh_token',''))")
if [ -n "\$NEW" ] && [ "\$NEW" != "\$REFRESH" ]; then
  echo "\$NEW" > "${DOTDIR}/refresh-token"
  chmod 600 "${DOTDIR}/refresh-token"
fi
echo "\$ACC"
EOF
chmod 700 "$DOTDIR/get-mcp-token.sh"
ok "Token refresher: $DOTDIR/get-mcp-token.sh"

# ---------- 3. install skill ----------
say "Installing tedplatform-publish skill…"
mkdir -p "$(dirname "$SKILL_DIR")"
TMP=$(mktemp -d)
git clone -q --depth 1 "$INSTALL_REPO_GIT" "$TMP/repo"
rm -rf "$SKILL_DIR"
cp -r "$TMP/repo/skills/tedplatform-publish" "$SKILL_DIR"
rm -rf "$TMP"
ok "Skill installed: $SKILL_DIR"

# ---------- 4. configure Claude Desktop ----------
# Detect Claude Desktop by the app bundle (Mac) rather than the config dir,
# since Claude only creates the config dir on first launch. We installed
# the app in step 0; create the config dir ourselves so the MCP entry is
# in place BEFORE the user first opens Claude.
case "$OS" in
  Darwin)
    DESKTOP_DIR="$HOME/Library/Application Support/Claude"
    DESKTOP_PRESENT=0
    [ -d "/Applications/Claude.app" ] && DESKTOP_PRESENT=1
    ;;
  Linux)
    DESKTOP_DIR="$HOME/.config/Claude"
    DESKTOP_PRESENT=0
    # No official Linux build yet. If user side-loaded one, the config dir
    # being present is the only signal we have.
    [ -d "$DESKTOP_DIR" ] && DESKTOP_PRESENT=1
    ;;
esac
DESKTOP_CFG="$DESKTOP_DIR/claude_desktop_config.json"

if [ "$DESKTOP_PRESENT" = "1" ]; then
  mkdir -p "$DESKTOP_DIR"
  [ -f "$DESKTOP_CFG" ] || echo '{}' > "$DESKTOP_CFG"
  python3 - <<PY
import json, os
cfg_path = "$DESKTOP_CFG"
with open(cfg_path) as f:
    cfg = json.load(f)
cfg.setdefault("mcpServers", {})
cfg["mcpServers"]["tedplatform"] = {
  "command": "/bin/bash",
  "args": [
    "-lc",
    'TOKEN=$("'$DOTDIR'/get-mcp-token.sh") && exec npx -y mcp-remote "'$MCP_URL'" --header "Authorization: Bearer ${TOKEN}"'
  ]
}
with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=2)
PY
  ok "Claude Desktop configured: $DESKTOP_CFG"
  DESKTOP_CONFIGURED=1
else
  warn "Claude Desktop not present - skipping Desktop config."
  DESKTOP_CONFIGURED=0
fi

# ---------- 5. configure Claude Code (CLI) ----------
if command -v claude >/dev/null; then
  claude mcp remove tedplatform >/dev/null 2>&1 || true
  # Use a wrapper command so the token is fetched fresh each session.
  CLI_WRAPPER="$DOTDIR/claude-mcp-launcher.sh"
  cat > "$CLI_WRAPPER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
TOKEN=\$("$DOTDIR/get-mcp-token.sh")
exec npx -y mcp-remote "$MCP_URL" --header "Authorization: Bearer \${TOKEN}"
EOF
  chmod 700 "$CLI_WRAPPER"
  # Modern Claude CLI requires `--` between MCP options and the child
  # command + its args. Show the actual error if it fails - no >/dev/null.
  if claude mcp add --scope user --transport stdio tedplatform -- "$CLI_WRAPPER"; then
    ok "Claude Code CLI configured (user scope)"
    CLI_CONFIGURED=1
  else
    warn "Claude Code 'mcp add' failed. Manual command:"
    warn "    claude mcp add --scope user --transport stdio tedplatform -- $CLI_WRAPPER"
    CLI_CONFIGURED=0
  fi
else
  warn "Claude Code CLI not found in PATH. Install it from https://claude.com/code if you want CLI support."
  CLI_CONFIGURED=0
fi

# ---------- 6. final smoke test ----------
say "Running smoke test against $MCP_URL …"
TOKEN=$("$DOTDIR/get-mcp-token.sh")
SESSION=$(curl -si -X POST "$MCP_URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"installer","version":"1"}}}' \
  | grep -i "Mcp-Session-Id" | tr -d '\r' | awk '{print $2}')
TOOLS=$(curl -s -X POST "$MCP_URL" \
  -H "Authorization: Bearer $TOKEN" -H "Mcp-Session-Id: $SESSION" \
  -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | grep -oE '"name":"[^"]*"' | wc -l | tr -d ' ')
if [ "$TOOLS" -gt 0 ]; then
  ok "MCP reachable — $TOOLS tools listed"
else
  warn "MCP responded but tool count was 0 — check that your user is in the 'tederga-admins' group"
fi

# ---------- 7. ready message ----------
cat <<EOF

\033[1;32m
╔══════════════════════════════════════════════════════════════════╗
║  ✓ Tedplatform is ready in Claude!                              ║
╠══════════════════════════════════════════════════════════════════╣
║                                                                  ║
║  Open Claude (Desktop or Code), then try:                       ║
║                                                                  ║
║   • "deneme1 adında Go+PG CRM yap, test olarak yayınla"          ║
║                                                                  ║
║   • "ahmetbsd.com'u deneme1'in test ortamına bağla"              ║
║                                                                  ║
║   • "deneme1'i production'a geç"                                 ║
║                                                                  ║
║   • "deneme1 tenant'ını sil"                                     ║
║                                                                  ║
║  The skill auto-triggers on words like 'yayınla', 'publish',    ║
║  'deploy', 'release' when combined with tedplatform context.    ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝
\033[0m

EOF

if [ "$DESKTOP_CONFIGURED" = "1" ]; then
  echo "  ↻ Restart Claude Desktop to pick up the MCP server."
fi
if [ "$CLI_CONFIGURED" = "1" ]; then
  echo "  ↻ For Claude Code CLI: just run 'claude' — MCP is loaded automatically."
fi

cat <<EOF

  ↻ Re-run this installer any time to refresh the OAuth login.
  ↻ Files written:
       $DOTDIR/refresh-token        (chmod 600 — keep secret)
       $DOTDIR/get-mcp-token.sh
       $DOTDIR/claude-mcp-launcher.sh
       $SKILL_DIR/SKILL.md
EOF
