# Tedplatform — one-shot Claude integration installer (Windows PowerShell).
#
# Usage (PowerShell):
#   iwr -useb https://raw.githubusercontent.com/grknatabay/tedplatform-claude/main/install.ps1 | iex
#
# What it does:
#   1. Browser-based OAuth (Keycloak Device Code flow) — you click "Allow" once
#      using your OWN account (Keycloak username/password — or, when GitHub
#      federation is live, "Sign in with GitHub").
#   2. Saves a long-lived refresh token to %USERPROFILE%\.tedplatform\refresh-token.
#   3. Writes a get-mcp-token.ps1 helper that exchanges the refresh token for a
#      fresh access token on every Claude session.
#   4. Adds the Tedplatform MCP server to:
#        • Claude Desktop  (%APPDATA%\Claude\claude_desktop_config.json)
#        • Claude Code CLI (via `claude mcp add` if found)
#   5. Installs the `tedplatform-publish` skill into %USERPROFILE%\.claude\skills\.
#   6. Prints example prompts you can paste into Claude.
#
# No platform secrets are baked into this script — your refresh token is yours.

$ErrorActionPreference = "Stop"

# Top-level trap: any uncaught throw (e.g. from Die) prints the message
# in red and pauses for input. Without this, an `iwr | iex` run that hits
# an error would unwind back to the host PowerShell, which on Windows
# PowerShell 5.1 sometimes auto-closes the window — leaving the user with
# no diagnostic.
trap {
    Write-Host ""
    Write-Host "✗ $_" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Re-run the installer after fixing the issue:" -ForegroundColor Yellow
    Write-Host "    iwr -useb https://raw.githubusercontent.com/grknatabay/tedplatform-claude/main/install.ps1 | iex" -ForegroundColor Yellow
    Write-Host ""
    Read-Host "  Press Enter to close this window"
    continue
}

# ---------- config ----------
$KC_URL    = if ($env:KEYCLOAK_URL)        { $env:KEYCLOAK_URL }        else { "https://keycloak.tederga.org" }
$KC_REALM  = if ($env:KC_REALM)            { $env:KC_REALM }            else { "operators" }
$KC_CLIENT = if ($env:KC_CLIENT)           { $env:KC_CLIENT }           else { "tedplatform-cli" }
$MCP_URL   = if ($env:TEDPLATFORM_MCP_URL) { $env:TEDPLATFORM_MCP_URL } else { "https://mcp.tederga.org/mcp" }
$REPO_GIT  = "https://github.com/grknatabay/tedplatform-claude"

$DOTDIR    = Join-Path $env:USERPROFILE ".tedplatform"
$SKILL_DIR = Join-Path $env:USERPROFILE ".claude\skills\tedplatform-publish"

function Say  ($m) { Write-Host $m -ForegroundColor Cyan }
function OK   ($m) { Write-Host "✓ $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "! $m" -ForegroundColor Yellow }
# Die throws a terminating error rather than calling `exit 1`. When this
# script is run via `iwr | iex` (the documented install path), `exit` would
# terminate the HOST PowerShell window; `throw` bubbles up to the top-level
# try/catch which prints a clear message and pauses for input.
function Die  ($m) { throw $m }

# Cross-version reader for an Invoke-RestMethod / Invoke-WebRequest error
# body. PowerShell 7+ exposes the response body via `$_.ErrorDetails.Message`,
# but Windows PowerShell 5.1 does NOT — the body is only reachable through
# `$_.Exception.Response.GetResponseStream()`. Without this helper, polling
# the device-code token endpoint would fail to recognize the expected
# `authorization_pending` 400 response and crash on PS 5.1.
function Get-ErrorBody {
    param($ErrorRecord)
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        return $ErrorRecord.ErrorDetails.Message
    }
    $resp = $ErrorRecord.Exception.Response
    if ($resp -and $resp.GetResponseStream) {
        try {
            $stream = $resp.GetResponseStream()
            $stream.Position = 0
            $reader = New-Object System.IO.StreamReader($stream)
            return $reader.ReadToEnd()
        } catch { return $null }
    }
    return $null
}

# ---------- prereqs ----------
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Die "git is required. Install via 'winget install Git.Git' or https://git-scm.com/download/win"
}
# Node.js is needed by the npx-based MCP launcher that both Claude Desktop
# and Claude Code use to bridge stdio → HTTP MCP transport. Warn now (don't
# Die) so the device-flow + skill install still happen — user can install
# Node afterward and re-run the launcher path.
$NODE_OK = $true
if (-not (Get-Command npx -ErrorAction SilentlyContinue)) {
    $NODE_OK = $false
    Warn "Node.js / npx not found in PATH."
    Warn "  Install: winget install OpenJS.NodeJS.LTS  (or https://nodejs.org/)"
    Warn "  Without Node, the MCP launcher Claude uses cannot run."
    Warn "  The device-flow login + skill install will still proceed."
}

# ---------- 1. device flow ----------
Say "═══ Tedplatform Claude installer ═══"
Say "Starting browser-based login (Keycloak device code)…"

if (-not (Test-Path $DOTDIR)) { New-Item -ItemType Directory -Path $DOTDIR -Force | Out-Null }

$deviceResp = Invoke-RestMethod -Method Post `
    -Uri "$KC_URL/realms/$KC_REALM/protocol/openid-connect/auth/device" `
    -Body @{
        client_id = $KC_CLIENT
        scope     = "openid profile email groups offline_access"
    }

$DEVICE_CODE = $deviceResp.device_code
$USER_CODE   = $deviceResp.user_code
$VERIFY_URL  = $deviceResp.verification_uri_complete
$INTERVAL    = $deviceResp.interval
$EXPIRES_IN  = $deviceResp.expires_in

if (-not $DEVICE_CODE) { Die "Device flow failed: $($deviceResp | ConvertTo-Json)" }

Write-Host ""
Write-Host "   ┌────────────────────────────────────────────────────┐" -ForegroundColor White
Write-Host "   │  Open the following URL in your browser:           │" -ForegroundColor White
Write-Host "   │                                                    │" -ForegroundColor White
Write-Host "   │  $VERIFY_URL"                                          -ForegroundColor White
Write-Host "   │                                                    │" -ForegroundColor White
Write-Host "   │  Verification code: $USER_CODE                          │" -ForegroundColor White
Write-Host "   │                                                    │" -ForegroundColor White
Write-Host "   │  Login with your account, then click 'Yes' / 'Allow'│" -ForegroundColor White
Write-Host "   └────────────────────────────────────────────────────┘" -ForegroundColor White
Write-Host ""

try { Start-Process $VERIFY_URL } catch { Warn "Could not auto-open browser. Copy the URL above." }

Say "Waiting for browser approval (timeout ${EXPIRES_IN}s)…"
$deadline = (Get-Date).AddSeconds($EXPIRES_IN)
$ACCESS = $null
$REFRESH = $null
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds $INTERVAL
    try {
        $tokResp = Invoke-RestMethod -Method Post `
            -Uri "$KC_URL/realms/$KC_REALM/protocol/openid-connect/token" `
            -Body @{
                client_id   = $KC_CLIENT
                device_code = $DEVICE_CODE
                grant_type  = "urn:ietf:params:oauth:grant-type:device_code"
            }
        if ($tokResp.access_token) {
            $ACCESS = $tokResp.access_token
            $REFRESH = $tokResp.refresh_token
            break
        }
    } catch {
        # Both PS 5.1 and PS 7+ throw on non-2xx; Get-ErrorBody returns the
        # JSON body the device-code spec mandates ({"error": "..."}).
        $body    = Get-ErrorBody $_
        $errBody = $null
        if ($body) { try { $errBody = $body | ConvertFrom-Json } catch {} }
        if ($errBody -and $errBody.error) {
            switch ($errBody.error) {
                "authorization_pending" { Write-Host -NoNewline "." }
                "slow_down"             { Write-Host -NoNewline "." }
                "expired_token"         { Die "Login window expired. Re-run the installer." }
                "access_denied"         { Die "You clicked 'No' in the browser. Re-run if that was a mistake." }
                default                 { Die "Token error: $($errBody | ConvertTo-Json -Compress)" }
            }
        } else {
            # Network blip / DNS / non-JSON 5xx — keep polling rather than dying,
            # the loop will time out via $deadline if it never recovers.
            Write-Host -NoNewline "?"
        }
    }
}
Write-Host ""
if (-not $ACCESS) { Die "Timed out waiting for browser approval." }
OK "Logged in (access $($ACCESS.Length) chars, refresh $($REFRESH.Length) chars)"

# ---------- 2. cache refresh token + writer ----------
Set-Content -Path "$DOTDIR\refresh-token" -Value $REFRESH -NoNewline -Encoding ASCII
$tokenScript = @"
# Auto-generated by tedplatform-claude installer.
# Exchanges cached refresh token for a fresh access token (printed to stdout).
`$ErrorActionPreference = "Stop"
`$REFRESH = Get-Content "$DOTDIR\refresh-token" -Raw
`$resp = Invoke-RestMethod -Method Post ``
    -Uri "$KC_URL/realms/$KC_REALM/protocol/openid-connect/token" ``
    -Body @{
        client_id     = "$KC_CLIENT"
        grant_type    = "refresh_token"
        refresh_token = `$REFRESH.Trim()
    }
if (`$resp.refresh_token -and `$resp.refresh_token -ne `$REFRESH.Trim()) {
    Set-Content -Path "$DOTDIR\refresh-token" -Value `$resp.refresh_token -NoNewline -Encoding ASCII
}
Write-Output `$resp.access_token
"@
Set-Content -Path "$DOTDIR\get-mcp-token.ps1" -Value $tokenScript -Encoding UTF8
OK "Token refresher: $DOTDIR\get-mcp-token.ps1"

# ---------- 3. install skill ----------
Say "Installing tedplatform-publish skill…"
$skillParent = Split-Path $SKILL_DIR -Parent
if (-not (Test-Path $skillParent)) { New-Item -ItemType Directory -Path $skillParent -Force | Out-Null }
$tmp = Join-Path $env:TEMP ("tedclaude-" + [guid]::NewGuid().ToString("N"))
git clone -q --depth 1 $REPO_GIT $tmp 2>&1 | Out-Null
if (Test-Path $SKILL_DIR) { Remove-Item -Recurse -Force $SKILL_DIR }
Copy-Item -Recurse "$tmp\skills\tedplatform-publish" $SKILL_DIR
Remove-Item -Recurse -Force $tmp
OK "Skill installed: $SKILL_DIR"

# ---------- 4. configure Claude Desktop ----------
$DESKTOP_DIR = Join-Path $env:APPDATA "Claude"
$DESKTOP_CFG = Join-Path $DESKTOP_DIR "claude_desktop_config.json"
$DESKTOP_CONFIGURED = $false
if (Test-Path $DESKTOP_DIR) {
    if (-not (Test-Path $DESKTOP_CFG)) { Set-Content $DESKTOP_CFG '{}' }
    $cfg = Get-Content $DESKTOP_CFG -Raw | ConvertFrom-Json
    if (-not $cfg.PSObject.Properties.Name.Contains("mcpServers")) {
        $cfg | Add-Member -MemberType NoteProperty -Name "mcpServers" -Value (New-Object PSObject)
    }
    # Wrapper: pwsh fetches a fresh token then exec npx mcp-remote with it.
    $launcherCmd = "powershell"
    $launcherArgs = @(
      "-NoProfile",
      "-Command",
      "`$t = & '$DOTDIR\get-mcp-token.ps1'; npx -y mcp-remote '$MCP_URL' --header `"Authorization: Bearer $t`""
    )
    $entry = New-Object PSObject -Property @{
        command = $launcherCmd
        args    = $launcherArgs
    }
    $cfg.mcpServers | Add-Member -MemberType NoteProperty -Name "tedplatform" -Value $entry -Force
    $cfg | ConvertTo-Json -Depth 10 | Set-Content $DESKTOP_CFG
    OK "Claude Desktop configured: $DESKTOP_CFG"
    $DESKTOP_CONFIGURED = $true
} else {
    Warn "Claude Desktop not detected (no $DESKTOP_DIR). Skipping."
}

# ---------- 5. configure Claude Code CLI ----------
$CLI_CONFIGURED = $false
if (Get-Command claude -ErrorAction SilentlyContinue) {
    $launcher = Join-Path $DOTDIR "claude-mcp-launcher.ps1"
    @"
`$ErrorActionPreference = "Stop"
`$t = & "$DOTDIR\get-mcp-token.ps1"
npx -y mcp-remote "$MCP_URL" --header "Authorization: Bearer `$t"
"@ | Set-Content $launcher
    & claude mcp remove tedplatform 2>$null | Out-Null
    & claude mcp add --scope user tedplatform "powershell" "-NoProfile" "-File" $launcher 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        OK "Claude Code CLI configured (user scope)"
        $CLI_CONFIGURED = $true
    } else {
        Warn "Claude Code 'mcp add' failed — older CLI? Add manually with the launcher at $launcher"
    }
} else {
    Warn "Claude Code CLI not in PATH. Install from https://claude.com/code if you want CLI support."
}

# ---------- 6. smoke test ----------
Say "Running smoke test against $MCP_URL …"
try {
    $TOKEN = & "$DOTDIR\get-mcp-token.ps1"
    $initBody = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"installer","version":"1"}}}'
    $initResp = Invoke-WebRequest -Method Post -Uri $MCP_URL -Body $initBody `
        -Headers @{
            "Authorization" = "Bearer $TOKEN"
            "Content-Type"  = "application/json"
            "Accept"        = "application/json, text/event-stream"
        } -UseBasicParsing
    $session = $initResp.Headers["Mcp-Session-Id"]
    # PS 5.1 returns header values as string[]; PS 7+ returns string. Normalize.
    if ($session -is [array]) { $session = $session[0] }
    $listBody = '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
    $listResp = Invoke-WebRequest -Method Post -Uri $MCP_URL -Body $listBody `
        -Headers @{
            "Authorization"   = "Bearer $TOKEN"
            "Mcp-Session-Id"  = $session
            "Content-Type"    = "application/json"
            "Accept"          = "application/json, text/event-stream"
        } -UseBasicParsing
    $count = ([regex]::Matches($listResp.Content, '"name":"[^"]+"')).Count
    if ($count -gt 0) {
        OK "MCP reachable — $count tools listed"
    } else {
        Warn "MCP responded but tool count was 0 — check that your user is in the 'tederga-admins' group"
    }
} catch {
    Warn "Smoke test failed: $_"
}

# ---------- 7. ready message ----------
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  ✓ Tedplatform is ready in Claude!                              ║" -ForegroundColor Green
Write-Host "╠══════════════════════════════════════════════════════════════════╣" -ForegroundColor Green
Write-Host "║                                                                  ║" -ForegroundColor Green
Write-Host "║  Open Claude (Desktop or Code), then try:                       ║" -ForegroundColor Green
Write-Host "║                                                                  ║" -ForegroundColor Green
Write-Host "║   • `"deneme1 adında Go+PG CRM yap, test olarak yayınla`"          ║" -ForegroundColor Green
Write-Host "║                                                                  ║" -ForegroundColor Green
Write-Host "║   • `"ahmetbsd.com'u deneme1'in test ortamına bağla`"              ║" -ForegroundColor Green
Write-Host "║                                                                  ║" -ForegroundColor Green
Write-Host "║   • `"deneme1'i production'a geç`"                                 ║" -ForegroundColor Green
Write-Host "║                                                                  ║" -ForegroundColor Green
Write-Host "║   • `"deneme1 tenant'ını sil`"                                     ║" -ForegroundColor Green
Write-Host "║                                                                  ║" -ForegroundColor Green
Write-Host "║  Skill triggers on 'yayınla', 'publish', 'deploy', 'release'.   ║" -ForegroundColor Green
Write-Host "║                                                                  ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""

if ($DESKTOP_CONFIGURED) { Write-Host "  ↻ Restart Claude Desktop to pick up the MCP server." }
if ($CLI_CONFIGURED)     { Write-Host "  ↻ For Claude Code CLI: just run 'claude' — MCP loads automatically." }

Write-Host ""
Write-Host "  ↻ Re-run this installer any time to refresh the OAuth login."
Write-Host "  ↻ Files written:"
Write-Host "       $DOTDIR\refresh-token"
Write-Host "       $DOTDIR\get-mcp-token.ps1"
Write-Host "       $DOTDIR\claude-mcp-launcher.ps1"
Write-Host "       $SKILL_DIR\SKILL.md"
