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

# Skill-only refresh — for when the only change in a release is the skill
# (e.g. MCP server got new tools and the SKILL.md needs to teach Claude
# Desktop the new flow). Skips OAuth, refresh-token cache, launcher, and
# Claude config — just pulls the latest skill from the repo and overwrites
# the local copy. Trigger via:
#   $env:TEDPLATFORM_SKILL_ONLY=1; iwr -useb https://raw.githubusercontent.com/grknatabay/tedplatform-claude/main/install.ps1 | iex
if ($env:TEDPLATFORM_SKILL_ONLY -eq "1") {
    Say "Skill-only refresh — re-pulling tedplatform-publish skill from main."
    $skillParent = Split-Path $SKILL_DIR -Parent
    if (-not (Test-Path $skillParent)) { New-Item -ItemType Directory -Path $skillParent -Force | Out-Null }
    $tmp = Join-Path $env:TEMP ("tedclaude-skillonly-" + [guid]::NewGuid().ToString("N"))
    git clone -q --depth 1 $REPO_GIT $tmp 2>&1 | Out-Null
    if (-not (Test-Path "$tmp\skills\tedplatform-publish\SKILL.md")) { Die "Repo missing skills/tedplatform-publish/SKILL.md — clone failed?" }
    if (Test-Path $SKILL_DIR) { Remove-Item -Recurse -Force $SKILL_DIR }
    Copy-Item -Recurse "$tmp\skills\tedplatform-publish" $SKILL_DIR
    Remove-Item -Recurse -Force $tmp
    OK "Skill refreshed: $SKILL_DIR"
    Write-Host ""
    Write-Host "  Restart Claude Desktop to pick up the new skill instructions." -ForegroundColor Yellow
    Write-Host ""
    return
}
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

# Write a string to disk as BOM-less UTF-8. Windows PowerShell 5.1's
# `Set-Content -Encoding UTF8` writes WITH BOM (the EF BB BF prefix);
# Claude Desktop's Electron JSON parser rejects that with
# "Unexpected token '', '{ \"p\"...'". PS 7+ defaults to no-BOM but we
# can't assume PS 7. Use the .NET API for both.
function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false))
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

# Module-level state for downstream configure step:
#   $script:ClaudeDesktopPresent  - any flavor of Claude Desktop is installed
#   $script:ClaudeDesktopCfgDir   - the actual config dir to write into.
#                                   MSIX/AppX redirects %APPDATA%\Claude to
#                                   %LOCALAPPDATA%\Packages\<PFN>\LocalCache\
#                                   Roaming\Claude — Win32 installs use the
#                                   plain %APPDATA%\Claude.
$script:ClaudeDesktopPresent = $false
$script:ClaudeDesktopCfgDir  = $null

function Test-ClaudeDesktopInstalled {
    # 1. Microsoft Store / MSIX install (the new "Claude" unified app).
    #    Get-AppxPackage is the authoritative source for AppX packages -
    #    they don't show up in the classic uninstall registry. The MSIX
    #    redirects classic %APPDATA%\Claude to a per-package LocalCache.
    $appx = Get-AppxPackage -Name "Claude*" -ErrorAction SilentlyContinue |
        Where-Object { $_.Publisher -like "*Anthropic*" -or $_.PackageFamilyName -like "Claude_*" } |
        Select-Object -First 1
    if ($appx) {
        $script:ClaudeDesktopCfgDir = Join-Path $env:LOCALAPPDATA "Packages\$($appx.PackageFamilyName)\LocalCache\Roaming\Claude"
        return $true
    }

    # 2. Classic Win32 install - config dir is the plain %APPDATA%\Claude.
    $win32Cfg = Join-Path $env:APPDATA "Claude"
    if (Test-Path $win32Cfg) {
        $script:ClaudeDesktopCfgDir = $win32Cfg
        return $true
    }

    # 3. Windows uninstall registry keys (Squirrel, MSI, winget Win32).
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
    if ($found) {
        $script:ClaudeDesktopCfgDir = $win32Cfg
        return $true
    }

    # 4. Known direct binary paths.
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA "AnthropicClaude\Claude.exe"),
        (Join-Path $env:LOCALAPPDATA "Anthropic\Claude\Claude.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Claude\Claude.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Anthropic Claude\Claude.exe"),
        "C:\Program Files\Claude\Claude.exe",
        "C:\Program Files\Anthropic Claude\Claude.exe",
        "C:\Program Files\AnthropicClaude\Claude.exe"
    )
    foreach ($p in $candidates) {
        if (Test-Path $p) { $script:ClaudeDesktopCfgDir = $win32Cfg; return $true }
    }

    # 5. Squirrel pattern: %LOCALAPPDATA%\AnthropicClaude\app-X.Y.Z\Claude.exe
    foreach ($root in @((Join-Path $env:LOCALAPPDATA "AnthropicClaude"),
                         (Join-Path $env:LOCALAPPDATA "Anthropic"))) {
        if (Test-Path $root) {
            $exe = Get-ChildItem -Path $root -Filter "Claude.exe" -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($exe) { $script:ClaudeDesktopCfgDir = $win32Cfg; return $true }
        }
    }

    return $false
}

function Ensure-ClaudeDesktop {
    # Desktop is the GUI fallback. The CLI (`claude`) consumes the same
    # MCP launcher + skill, so once it's installed Desktop is optional.
    # Force-installing the GUI on top of a working CLI is a surprise app
    # on the operator's machine.
    if (Test-ClaudeDesktopInstalled) {
        $kind = if ($script:ClaudeDesktopCfgDir -like "*\Packages\*") { "Microsoft Store / MSIX" } else { "Win32" }
        OK "Claude Desktop found ($kind - already installed, skipping)"
        $script:ClaudeDesktopPresent = $true
        return
    }
    if (Get-Command claude -ErrorAction SilentlyContinue) {
        Say "Claude Desktop install skipped (CLI already present - Desktop is optional)."
        return
    }
    Say "Claude Desktop not found - attempting install..."
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        # Try Microsoft Store source first (the new unified Claude app
        # ships there), then classic winget source.
        $attempts = @(
            @{ Args = @("install","--silent","--accept-source-agreements","--accept-package-agreements","--source","msstore","--id","9NLG58FMZD0L"); Label = "Microsoft Store (msstore: 9NLG58FMZD0L)" },
            @{ Args = @("install","--silent","--accept-source-agreements","--accept-package-agreements","--id","Anthropic.Claude","--scope","user");   Label = "winget Anthropic.Claude" },
            @{ Args = @("install","--silent","--accept-source-agreements","--accept-package-agreements","--id","Anthropic.ClaudeDesktop","--scope","user"); Label = "winget Anthropic.ClaudeDesktop" }
        )
        foreach ($a in $attempts) {
            $rc = Invoke-External -Quiet -Cmd "winget" -Args $a.Args
            if ($rc -eq 0) {
                OK "Claude Desktop installed via $($a.Label)"
                # Re-detect to populate $script:ClaudeDesktopCfgDir.
                if (Test-ClaudeDesktopInstalled) { $script:ClaudeDesktopPresent = $true }
                return
            }
        }
        Warn "winget could not install Claude Desktop under any known id."
    } else {
        Warn "winget unavailable - cannot auto-install Claude Desktop."
    }
    Warn "  Install manually from https://claude.ai/download (Microsoft Store)"
    Warn "  After installing, re-run this script to wire the MCP entry."
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

# ---------- 2. cache refresh token + Node-based writer ----------
# Clean up legacy PS artifacts from previous installer versions. Earlier
# revisions wrote claude-mcp-launcher.ps1 + get-mcp-token.ps1; both are
# replaced by launcher.cmd + token-fetcher.js below. Stale .ps1 files in
# the dotdir would confuse anyone debugging the installer later.
foreach ($legacy in @("claude-mcp-launcher.ps1","get-mcp-token.ps1")) {
    $p = Join-Path $DOTDIR $legacy
    if (Test-Path $p) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
}

# Refresh token is the only persistent secret. Write it ASCII (no BOM, no
# newline) so a plain ReadFileSync gives the exact value.
Set-Content -Path "$DOTDIR\refresh-token" -Value $REFRESH -NoNewline -Encoding ASCII

# token-fetcher.js — Node script that exchanges the cached refresh token
# for a fresh access token (printed to stdout). Written in Node (not PS)
# because the MSIX-sandboxed PowerShell that Claude Desktop spawns has
# repeatedly broken our PS launchers (BOM, here-string escape gotchas,
# npx.ps1 LASTEXITCODE quirk, silent crashes). Node is rock-solid in
# the same spawn context and is already installed at this point.
$tokenJs = @'
'use strict';
const fs = require('fs');
const path = require('path');
const https = require('https');
const querystring = require('querystring');

const dotdir = path.join(require('os').homedir(), '.tedplatform');
const tokenPath = path.join(dotdir, 'refresh-token');

let refresh;
try { refresh = fs.readFileSync(tokenPath, 'utf8').trim(); }
catch (e) { console.error('Cannot read ' + tokenPath + ': ' + e.message); process.exit(2); }

const KC_URL    = process.env.KEYCLOAK_URL || '__KC_URL__';
const KC_REALM  = process.env.KC_REALM     || '__KC_REALM__';
const KC_CLIENT = process.env.KC_CLIENT    || '__KC_CLIENT__';

const body = querystring.stringify({
  client_id: KC_CLIENT,
  grant_type: 'refresh_token',
  refresh_token: refresh
});

const u = new URL(KC_URL + '/realms/' + KC_REALM + '/protocol/openid-connect/token');
const req = https.request({
  hostname: u.hostname,
  port:     u.port || 443,
  path:     u.pathname,
  method:   'POST',
  headers:  { 'Content-Type': 'application/x-www-form-urlencoded',
              'Content-Length': Buffer.byteLength(body) }
}, res => {
  let data = '';
  res.on('data', c => data += c);
  res.on('end', () => {
    if (res.statusCode !== 200) {
      console.error('KC token endpoint returned ' + res.statusCode + ': ' + data);
      process.exit(3);
    }
    let json;
    try { json = JSON.parse(data); }
    catch (e) { console.error('Bad JSON from KC: ' + e.message); process.exit(4); }
    if (!json.access_token) { console.error('No access_token in KC response'); process.exit(5); }
    if (json.refresh_token && json.refresh_token !== refresh) {
      try { fs.writeFileSync(tokenPath, json.refresh_token); } catch (_) { /* non-fatal */ }
    }
    process.stdout.write(json.access_token);
    process.exit(0);
  });
});
req.on('error', e => { console.error('KC request error: ' + e.message); process.exit(6); });
req.write(body); req.end();
'@
$tokenJs = $tokenJs.Replace('__KC_URL__', $KC_URL).Replace('__KC_REALM__', $KC_REALM).Replace('__KC_CLIENT__', $KC_CLIENT)
Write-Utf8NoBom -Path "$DOTDIR\token-fetcher.js" -Content $tokenJs
OK "Token fetcher: $DOTDIR\token-fetcher.js"

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

# ---------- 3.5. write the shared MCP launcher (cmd.exe batch — PS-free) ----------
# Both Claude Desktop and Claude Code CLI invoke this script. Written as
# a plain Windows batch (.cmd) for one specific reason: PowerShell launchers
# repeatedly broke under MSIX-sandboxed Claude Desktop spawn (BOM, here-
# string n-escape, npx.ps1 LASTEXITCODE bug, silent crashes, four other
# gotchas). cmd.exe + node + npx.cmd is the most boring possible chain.
#
# Resolution order at runtime:
#   1. cmd.exe runs the batch
#   2. batch calls `node token-fetcher.js` -> stdout = access token
#   3. batch calls `npx.cmd -y mcp-remote URL --header "Bearer <token>"`
#
# Locate npx.cmd at install time so the batch has an absolute path; PATH
# resolution from inside Claude Desktop's spawn isn't always reliable.
$npxCmdSource = (Get-Command 'npx.cmd' -ErrorAction SilentlyContinue).Source
if (-not $npxCmdSource) {
    Die "npx.cmd not found in PATH after Node install. Reopen PowerShell and re-run."
}

$launcher = Join-Path $DOTDIR "launcher.cmd"
# Use SINGLE-QUOTED here-string + .Replace() so PowerShell does not
# touch backticks. Batch's `for /f "usebackq"` syntax requires literal
# backticks around the inner command, and double-quoted PS here-strings
# treat `n as a newline escape — which silently splits the batch line
# and leaves "ode ..." as a bare command (the user actually saw "The
# system cannot find the file ode."). Same trap I hit twice before in
# the launcher.ps1 comments. Single-quoted is the cure.
$launcherCmd = @'
@echo off
setlocal enabledelayedexpansion
for /f "usebackq delims=" %%i in (`node "__DOTDIR__\token-fetcher.js"`) do set "TOKEN=%%i"
if "!TOKEN!"=="" (
    echo Failed to fetch access token from Keycloak 1>&2
    exit /b 1
)
"__NPXCMD__" -y mcp-remote "__MCP_URL__" --header "Authorization: Bearer !TOKEN!"
exit /b !ERRORLEVEL!
'@
$launcherCmd = $launcherCmd.Replace('__DOTDIR__', $DOTDIR).Replace('__NPXCMD__', $npxCmdSource).Replace('__MCP_URL__', $MCP_URL)
Write-Utf8NoBom -Path $launcher -Content $launcherCmd
OK "MCP launcher: $launcher"

# ---------- 4. configure Claude Desktop ----------
# Detection (above) tells us whether ANY Claude Desktop flavor is installed
# AND which config dir it actually uses (MSIX vs Win32). We can't know in
# advance which package the user picked, so we read the state and follow.
$DESKTOP_DIR = if ($script:ClaudeDesktopCfgDir) { $script:ClaudeDesktopCfgDir } else { Join-Path $env:APPDATA "Claude" }
$DESKTOP_CFG = Join-Path $DESKTOP_DIR "claude_desktop_config.json"
$DESKTOP_CONFIGURED = $false
if ($script:ClaudeDesktopPresent) {
    if (-not (Test-Path $DESKTOP_DIR)) {
        New-Item -ItemType Directory -Path $DESKTOP_DIR -Force | Out-Null
    }

    # Read existing config defensively. Empty file, BOM-corrupt JSON, or
    # missing file all collapse to "start with an empty object".
    $cfg = $null
    if (Test-Path $DESKTOP_CFG) {
        try {
            $raw = [System.IO.File]::ReadAllText($DESKTOP_CFG)
            # Strip leading UTF-8 BOM if a previous installer left one.
            if ($raw.Length -ge 1 -and $raw[0] -eq [char]0xFEFF) { $raw = $raw.Substring(1) }
            if ($raw.Trim()) { $cfg = $raw | ConvertFrom-Json -ErrorAction Stop }
        } catch {
            Warn "Existing $DESKTOP_CFG was not valid JSON ($($_.Exception.Message)); replacing with a fresh one."
            $cfg = $null
        }
    }
    if (-not $cfg) { $cfg = [pscustomobject]@{} }

    # Ensure mcpServers property exists. -contains works on PSCustomObject
    # property name lists across PS 5.1 / 7 without method-call quirks.
    $hasMcpServers = $false
    if ($cfg.PSObject -and $cfg.PSObject.Properties) {
        $hasMcpServers = ($cfg.PSObject.Properties.Name -contains "mcpServers")
    }
    if (-not $hasMcpServers) {
        $cfg | Add-Member -MemberType NoteProperty -Name "mcpServers" -Value (New-Object PSObject)
    }

    # cmd.exe + launcher.cmd. PS launchers are out (see section 3.5 comment).
    $entry = New-Object PSObject -Property @{
        command = "cmd.exe"
        args    = @("/c", $launcher)
    }
    $cfg.mcpServers | Add-Member -MemberType NoteProperty -Name "tedplatform" -Value $entry -Force

    Write-Utf8NoBom -Path $DESKTOP_CFG -Content ($cfg | ConvertTo-Json -Depth 10)
    OK "Claude Desktop configured: $DESKTOP_CFG"
    $DESKTOP_CONFIGURED = $true
} else {
    Warn "Claude Desktop not present - skipping Desktop config."
}

# ---------- 5. configure Claude Code CLI ----------
$CLI_CONFIGURED = $false
if (Get-Command claude -ErrorAction SilentlyContinue) {
    # `claude mcp remove` writes "No MCP server found ..." to stderr when
    # the entry doesn't exist yet — Invoke-External keeps that off our
    # error path and we just ignore the exit code.
    Invoke-External -Quiet -Cmd "claude" -Args @("mcp","remove","tedplatform") | Out-Null

    # cmd.exe + launcher.cmd (PS-free runtime). `--` separates Claude's
    # MCP add options from the child command + args.
    $rc = Invoke-External -Cmd "claude" -Args @(
        "mcp","add","--scope","user","--transport","stdio","tedplatform",
        "--","cmd.exe","/c",$launcher
    )
    if ($rc -eq 0) {
        OK "Claude Code CLI configured (user scope)"
        $CLI_CONFIGURED = $true
    } else {
        Warn "Claude Code 'mcp add' failed (exit $rc). Manual add command:"
        Warn "    claude mcp add --scope user --transport stdio tedplatform -- cmd.exe /c `"$launcher`""
    }
} else {
    Warn "Claude Code CLI not in PATH. Install from https://claude.com/code if you want CLI support."
}

# ---------- 6. smoke test ----------
Say "Running smoke test against $MCP_URL ..."
try {
    # Token comes from the same Node fetcher the runtime launcher uses.
    # We're in PS at install time, so just call `node` directly (PATH was
    # refreshed earlier). Trim any trailing newline node may emit.
    $TOKEN = (& node "$DOTDIR\token-fetcher.js").Trim()
    if (-not $TOKEN) { throw "token-fetcher.js returned empty" }
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
Write-Host "  -> Files written (runtime is 100% PS-free, just node + cmd):"
Write-Host "       $DOTDIR\refresh-token       (OAuth refresh token, 30d offline)"
Write-Host "       $DOTDIR\token-fetcher.js    (Node script: refresh -> access token)"
Write-Host "       $DOTDIR\launcher.cmd        (cmd.exe wrapper Claude invokes)"
Write-Host "       $SKILL_DIR\SKILL.md         (orchestration guide for Claude)"
