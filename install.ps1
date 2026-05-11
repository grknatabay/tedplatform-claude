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

# Force UTF-8 console output. Windows PowerShell 5.1 defaults to the legacy
# OEM code page (cp1252 on most systems) which renders box-drawing chars
# and emoji as `?`. PS 7+ already defaults to UTF-8. Best-effort: skip on
# error rather than abort — the script still works, just with mojibake.
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding           = [System.Text.Encoding]::UTF8
} catch { }

# ASCII-friendly UI characters. PS 5.1 + cp1252 console can't render the
# unicode box-drawing set even with UTF-8 encoding (font fallback limit),
# so we use the lowest common denominator everywhere.

# Top-level trap: any uncaught throw (e.g. from Die) prints the message
# in red and pauses for input. Without this, an `iwr | iex` run that hits
# an error would unwind back to the host PowerShell, which on Windows
# PowerShell 5.1 sometimes auto-closes the window — leaving the user with
# no diagnostic.
trap {
    Write-Host ""
    Write-Host "[X] $_" -ForegroundColor Red
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
function OK   ($m) { Write-Host "[OK] $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "[!]  $m" -ForegroundColor Yellow }
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

# ---------- prereqs (auto-install where possible) ----------
# Strategy: same as install.sh - use the OS package manager (winget here)
# to install Node.js + Claude Code automatically so the install is genuinely
# one-shot. No "go install X then re-run" cycles.

# Refresh the current process' PATH from machine + user registry. winget /
# npm install side effects only show up in NEW shells unless we do this.
function Refresh-Path {
    $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath    = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path    = "$machinePath;$userPath"
    # npm global bin lives under %APPDATA%\npm by default; ensure it.
    $npmBin = Join-Path $env:APPDATA "npm"
    if (Test-Path $npmBin) { $env:Path = "$npmBin;$env:Path" }
}

# Run an external command (winget, npm, ...) without letting their stderr
# output trigger our top-level `$ErrorActionPreference = Stop` + trap. These
# tools routinely write informational notices to stderr (e.g. `npm notice`,
# `winget warning`); we only care about the actual exit code.
#
# Returns the exit code; caller checks for non-zero.
function Invoke-External {
    param(
        [Parameter(Mandatory)]$Cmd,
        [string[]]$Args = @(),
        [switch]$Quiet  # if set, drop output entirely (still honours exit code)
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        if ($Quiet) {
            & $Cmd @Args 2>&1 | Out-Null
        } else {
            & $Cmd @Args 2>&1 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
        }
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Ensure-Git {
    if (Get-Command git -ErrorAction SilentlyContinue) {
        OK "git found: $((git --version) 2>&1) (already installed - skipping)"
        return
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Die "git is required and winget isn't available. Install git from https://git-scm.com/download/win"
    }
    Say "git not found - installing via winget..."
    $rc = Invoke-External -Quiet -Cmd "winget" -Args @(
        "install","--silent","--accept-source-agreements","--accept-package-agreements",
        "--id","Git.Git","--scope","user"
    )
    if ($rc -ne 0) {
        Die "winget install Git.Git failed (exit $rc). Install manually from https://git-scm.com/download/win"
    }
    Refresh-Path
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Die "git install reported success but 'git' still not in PATH. Open a new PowerShell and re-run."
    }
    OK "git installed: $((git --version) 2>&1)"
}

function Ensure-Node {
    if ((Get-Command node -ErrorAction SilentlyContinue) -and (Get-Command npx -ErrorAction SilentlyContinue)) {
        $ver = (node -v) -replace '^v', ''
        $major = [int]($ver -split '\.')[0]
        if ($major -ge 18) {
            OK "Node.js found: v$ver (already installed - skipping)"
            return
        }
        Warn "Node.js v$ver is too old; mcp-remote requires v18+. Upgrading..."
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Die "Node.js v18+ required and winget isn't available. Install Node.js LTS from https://nodejs.org/"
    }
    Say "Installing Node.js LTS via winget (this can take 1-2 minutes)..."
    $rc = Invoke-External -Quiet -Cmd "winget" -Args @(
        "install","--silent","--accept-source-agreements","--accept-package-agreements",
        "--id","OpenJS.NodeJS.LTS"
    )
    if ($rc -ne 0) {
        Die "winget install Node.js failed (exit $rc). Install manually from https://nodejs.org/"
    }
    Refresh-Path
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
        Die "Node install reported success but 'node' still not in PATH. Open a new PowerShell and re-run."
    }
    OK "Node.js installed: $((node -v) 2>&1)"
}

function Ensure-ClaudeCLI {
    if (Get-Command claude -ErrorAction SilentlyContinue) {
        OK "Claude Code CLI found: $((claude --version) 2>&1 | Select-Object -First 1) (already installed - skipping)"
        return
    }
    Say "Claude Code CLI not found - installing globally via npm..."
    $rc = Invoke-External -Cmd "npm" -Args @("install","-g","@anthropic-ai/claude-code")
    if ($rc -ne 0) {
        Die "npm install -g @anthropic-ai/claude-code failed (exit $rc). Try running it manually from a new PowerShell to see the full error."
    }
    Refresh-Path
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        Warn "Claude Code installed but 'claude' is not yet in PATH for this shell."
        Warn "After this installer finishes, open a new PowerShell to use it."
    } else {
        OK "Claude Code installed: $((claude --version) 2>&1 | Select-Object -First 1)"
    }
}

# Module-level state so the configure step downstream knows whether it
# should force-create the config dir (the binary is installed but the user
# never opened Claude → no config dir yet) vs genuinely skip (no binary).
$script:ClaudeDesktopPresent = $false

function Test-ClaudeDesktopInstalled {
    # 1. Config dir exists → user has opened it at least once.
    if (Test-Path (Join-Path $env:APPDATA "Claude")) { return $true }

    # 2. Registry uninstall keys - the most reliable way regardless of
    #    where the installer (Squirrel / MSI / winget) put the binary.
    $regPaths = @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $found = Get-ItemProperty -Path $regPaths -ErrorAction SilentlyContinue |
        Where-Object {
            ($_.DisplayName -like "*Claude*") -and
            ($_.Publisher   -like "*Anthropic*" -or $_.DisplayName -like "*Anthropic*")
        } | Select-Object -First 1
    if ($found) { return $true }

    # 3. Known binary paths - covers Squirrel installer (per-user) AND
    #    MSI per-machine layouts including newer paths Anthropic ships.
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA "AnthropicClaude\Claude.exe"),
        (Join-Path $env:LOCALAPPDATA "Anthropic\Claude\Claude.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Claude\Claude.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Anthropic Claude\Claude.exe"),
        "C:\Program Files\Claude\Claude.exe",
        "C:\Program Files\Anthropic Claude\Claude.exe",
        "C:\Program Files\AnthropicClaude\Claude.exe"
    )
    foreach ($p in $candidates) { if (Test-Path $p) { return $true } }

    # 4. Squirrel pattern: %LOCALAPPDATA%\AnthropicClaude\app-X.Y.Z\Claude.exe
    $squirrelRoots = @(
        (Join-Path $env:LOCALAPPDATA "AnthropicClaude"),
        (Join-Path $env:LOCALAPPDATA "Anthropic")
    )
    foreach ($root in $squirrelRoots) {
        if (Test-Path $root) {
            $exe = Get-ChildItem -Path $root -Filter "Claude.exe" -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($exe) { return $true }
        }
    }

    return $false
}

function Ensure-ClaudeDesktop {
    if (Test-ClaudeDesktopInstalled) {
        OK "Claude Desktop found (already installed - skipping)"
        $script:ClaudeDesktopPresent = $true
        return
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Warn "Claude Desktop not installed and winget unavailable - skipping."
        Warn "  Install manually from https://claude.ai/download"
        return
    }
    Say "Claude Desktop not found - installing via winget..."
    # Try a few known IDs in order; Anthropic has shipped multiple package
    # IDs over time. First non-zero exit just means "this ID doesn't exist
    # in the user's winget sources" — fall through to the next.
    $tried = @()
    foreach ($pkgId in @("Anthropic.Claude", "Anthropic.ClaudeDesktop", "AnthropicClaude.Claude")) {
        $tried += $pkgId
        $rc = Invoke-External -Quiet -Cmd "winget" -Args @(
            "install","--silent","--accept-source-agreements","--accept-package-agreements",
            "--id",$pkgId,"--scope","user"
        )
        if ($rc -eq 0) {
            OK "Claude Desktop installed (winget id: $pkgId)"
            $script:ClaudeDesktopPresent = $true
            return
        }
    }
    Warn "winget could not find Claude Desktop under any known package id (tried: $($tried -join ', '))."
    Warn "  Install manually from https://claude.ai/download"
}

Ensure-Git
Ensure-Node
Ensure-ClaudeCLI
Ensure-ClaudeDesktop


# ---------- 1. device flow ----------
Say "=== Tedplatform Claude installer ==="
Say "Starting browser-based login (Keycloak device code)..."

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
Write-Host "   +------------------------------------------------------------+" -ForegroundColor White
Write-Host "   |  Open the following URL in your browser:                   |" -ForegroundColor White
Write-Host "   |                                                            |" -ForegroundColor White
Write-Host "   |  $VERIFY_URL"                                                  -ForegroundColor White
Write-Host "   |                                                            |" -ForegroundColor White
Write-Host "   |  Verification code: $USER_CODE                                  |" -ForegroundColor White
Write-Host "   |                                                            |" -ForegroundColor White
Write-Host "   |  Login with your account, then click 'Yes' / 'Allow'       |" -ForegroundColor White
Write-Host "   +------------------------------------------------------------+" -ForegroundColor White
Write-Host ""

try { Start-Process $VERIFY_URL } catch { Warn "Could not auto-open browser. Copy the URL above." }

Say "Waiting for browser approval (timeout ${EXPIRES_IN}s)..."
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
Say "Installing tedplatform-publish skill..."
$skillParent = Split-Path $SKILL_DIR -Parent
if (-not (Test-Path $skillParent)) { New-Item -ItemType Directory -Path $skillParent -Force | Out-Null }
$tmp = Join-Path $env:TEMP ("tedclaude-" + [guid]::NewGuid().ToString("N"))
git clone -q --depth 1 $REPO_GIT $tmp 2>&1 | Out-Null
if (Test-Path $SKILL_DIR) { Remove-Item -Recurse -Force $SKILL_DIR }
Copy-Item -Recurse "$tmp\skills\tedplatform-publish" $SKILL_DIR
Remove-Item -Recurse -Force $tmp
OK "Skill installed: $SKILL_DIR"

# ---------- 4. configure Claude Desktop ----------
# Trust the registry/binary detection from Ensure-ClaudeDesktop. If the
# user has Claude Desktop installed but never opened it, the config dir
# doesn't exist yet — we create it ourselves so the MCP entry is in
# place at first launch.
$DESKTOP_DIR = Join-Path $env:APPDATA "Claude"
$DESKTOP_CFG = Join-Path $DESKTOP_DIR "claude_desktop_config.json"
$DESKTOP_CONFIGURED = $false
if ($script:ClaudeDesktopPresent) {
    if (-not (Test-Path $DESKTOP_DIR)) {
        New-Item -ItemType Directory -Path $DESKTOP_DIR -Force | Out-Null
    }
    if (-not (Test-Path $DESKTOP_CFG)) { Set-Content $DESKTOP_CFG '{}' -Encoding UTF8 }
    $cfg = Get-Content $DESKTOP_CFG -Raw | ConvertFrom-Json
    if (-not $cfg.PSObject.Properties.Name.Contains("mcpServers")) {
        $cfg | Add-Member -MemberType NoteProperty -Name "mcpServers" -Value (New-Object PSObject)
    }
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
    $cfg | ConvertTo-Json -Depth 10 | Set-Content $DESKTOP_CFG -Encoding UTF8
    OK "Claude Desktop configured: $DESKTOP_CFG"
    $DESKTOP_CONFIGURED = $true
} else {
    Warn "Claude Desktop not present - skipping Desktop config."
}

# ---------- 5. configure Claude Code CLI ----------
$CLI_CONFIGURED = $false
if (Get-Command claude -ErrorAction SilentlyContinue) {
    $launcher = Join-Path $DOTDIR "claude-mcp-launcher.ps1"
    @"
`$ErrorActionPreference = "Stop"
`$t = & "$DOTDIR\get-mcp-token.ps1"
npx -y mcp-remote "$MCP_URL" --header "Authorization: Bearer `$t"
"@ | Set-Content $launcher -Encoding UTF8

    # `claude mcp remove` writes "No MCP server found ..." to stderr when
    # the entry doesn't exist yet — Invoke-External keeps that off our
    # error path and we just ignore the exit code.
    Invoke-External -Quiet -Cmd "claude" -Args @("mcp","remove","tedplatform") | Out-Null

    $rc = Invoke-External -Quiet -Cmd "claude" -Args @(
        "mcp","add","--scope","user","tedplatform",
        "powershell","-NoProfile","-File",$launcher
    )
    if ($rc -eq 0) {
        OK "Claude Code CLI configured (user scope)"
        $CLI_CONFIGURED = $true
    } else {
        Warn "Claude Code 'mcp add' failed (exit $rc). Add manually with the launcher at $launcher"
    }
} else {
    Warn "Claude Code CLI not in PATH. Install from https://claude.com/code if you want CLI support."
}

# ---------- 6. smoke test ----------
Say "Running smoke test against $MCP_URL ..."
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
        OK "MCP reachable - $count tools listed"
    } else {
        Warn "MCP responded but tool count was 0 - check that your user is in the 'tederga-admins' group"
    }
} catch {
    Warn "Smoke test failed: $_"
}

# ---------- 7. ready message ----------
Write-Host ""
Write-Host "+==================================================================+" -ForegroundColor Green
Write-Host "|  [OK] Tedplatform is ready in Claude!                            |" -ForegroundColor Green
Write-Host "+==================================================================+" -ForegroundColor Green
Write-Host "|                                                                  |" -ForegroundColor Green
Write-Host "|  Open Claude (Desktop or Code), then try:                        |" -ForegroundColor Green
Write-Host "|                                                                  |" -ForegroundColor Green
Write-Host "|   - `"deneme1 adinda Go+PG CRM yap, test olarak yayinla`"          |" -ForegroundColor Green
Write-Host "|                                                                  |" -ForegroundColor Green
Write-Host "|   - `"ahmetbsd.com'u deneme1'in test ortamina bagla`"              |" -ForegroundColor Green
Write-Host "|                                                                  |" -ForegroundColor Green
Write-Host "|   - `"deneme1'i production'a gec`"                                 |" -ForegroundColor Green
Write-Host "|                                                                  |" -ForegroundColor Green
Write-Host "|   - `"deneme1 tenant'ini sil`"                                     |" -ForegroundColor Green
Write-Host "|                                                                  |" -ForegroundColor Green
Write-Host "|  Skill triggers on 'yayinla', 'publish', 'deploy', 'release'.    |" -ForegroundColor Green
Write-Host "|                                                                  |" -ForegroundColor Green
Write-Host "+==================================================================+" -ForegroundColor Green
Write-Host ""

if ($DESKTOP_CONFIGURED) { Write-Host "  -> Restart Claude Desktop to pick up the MCP server." }
if ($CLI_CONFIGURED)     { Write-Host "  -> For Claude Code CLI: just run 'claude' - MCP loads automatically." }
if (-not $DESKTOP_CONFIGURED -and -not $CLI_CONFIGURED) {
    Write-Host ""
    Write-Host "  [!] No Claude client detected. Install one of:" -ForegroundColor Yellow
    Write-Host "        Claude Code CLI : npm install -g @anthropic-ai/claude-code  (needs Node.js)"
    Write-Host "        Claude Desktop  : https://claude.ai/download"
    Write-Host "      Then re-run this installer to wire the MCP server in."
}

Write-Host ""
Write-Host "  -> Re-run this installer any time to refresh the OAuth login."
Write-Host "  -> Files written:"
Write-Host "       $DOTDIR\refresh-token"
Write-Host "       $DOTDIR\get-mcp-token.ps1"
Write-Host "       $DOTDIR\claude-mcp-launcher.ps1"
Write-Host "       $SKILL_DIR\SKILL.md"
