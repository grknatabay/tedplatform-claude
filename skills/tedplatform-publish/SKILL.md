---
name: tedplatform-publish
description: Use this skill when the user wants to deploy an application to the Tedplatform managed Kubernetes platform. TRIGGER when the user says any of "publish", "deploy", "yayınla", "release", "ship", "go live", "push to prod" AND there's tedplatform code/context in the conversation — OR when they reference "tenant", "tedplatform", or hostnames ending in "tederga.org". SKIP when the user is deploying to a different platform (Vercel, Fly, Render, AWS, GCP) or asking general K8s questions unrelated to tedplatform.
---

# Tedplatform Publish — workflow skill (thin loader)

This skill is intentionally minimal. The authoritative, always-current
workflow lives **server-side** in the `tedplatform_help` MCP tool, which
is updated atomically with each MCP server release. That way you never
read a stale local doc.

## Rule — call `tedplatform_help(topic="publish")` FIRST

Before any other tool, call:

```
tedplatform_help(topic="publish")
```

Read the response in full. It is the authoritative orchestration guide
for the deployed MCP server version, including:

- exact tool names + argument schemas (which may differ from anything
  documented here),
- the current build path (single one-shot publish, or split build +
  expose, or GitHub-Actions-driven),
- the current wait/polling semantics (sync vs async job_id pattern),
- the current dep-detection table (Postgres / Redis / Kafka / ...),
- the current host/URL convention.

Then follow that response **verbatim**. Do not substitute your own
mechanisms.

## Hard rules — do NOT improvise

1. **If a tool's response includes a `hint` or `next` field, follow it
   exactly.** These are server-emitted directives, not suggestions.
   The most common mistake is ignoring a `hint` like "Poll
   `tenant_app_publish_status job_id=...` every 5-10s" and substituting
   ad-hoc Monitor-based curl polling on the URL. That gives you a
   distorted view of saga state and produces false "still running" or
   "no pod" reports while the saga has actually completed.
2. **If a publish-like tool returns a `job_id`, the tool is async.**
   Poll the matching `*_status` tool — never poll the future URL with
   curl as a substitute. The URL becoming reachable lags the saga
   completion by 30-90s and tells you nothing about which step failed.
3. **Do not interpret transport-level errors as saga failure.** A
   `-32001` / connection-reset / read-timeout on the publish call may
   mean the HTTP client gave up while the server-side saga keeps
   running. Call the status tool with the last-known `job_id` (or just
   re-run publish — every publish-shaped tool here is idempotent on
   matching arguments) before declaring failure.
4. **Verify with cluster ground truth, not single signals.** When
   diagnosing a "stuck" publish, walk the layers in order: app pod
   (`app_logs` or `app_status`) → AppExposure CR → HTTPProxy →
   Cloudflare DNS A record. Don't conclude "DNS missing" from a single
   `dig` against a stale local resolver — go to the source.
5. **Tenant existence is a prerequisite for publish.** If the user
   names a tenant ("acme'ye yayınla") and it's missing, call
   `tenant_onboard` first — it is idempotent and safe to call on an
   existing tenant.

## When `tedplatform_help` is unavailable

If the MCP server itself is unreachable, surface that to the user
directly — don't try to publish offline. There is no offline mode.
Don't fall back to `kubectl`, `helm`, or `docker` unless the user
explicitly says "by hand".

## Why this skill is thin

Earlier versions of this skill embedded the full publish recipe inline.
When the server's tool surface changed (e.g. sync→async refactor), the
local skill rot meant Claude Desktop continued to follow stale steps
and produced false diagnostics. Pinning the recipe server-side via
`tedplatform_help` removes that class of drift entirely.
