---
name: tedplatform-publish
description: Use this skill when the user wants to deploy an application to the Tedplatform managed Kubernetes platform. TRIGGER when the user says any of "publish", "deploy", "yayınla", "release", "ship", "go live", "push to prod" AND there's tedplatform code/context in the conversation — OR when they reference "tenant", "tedplatform", or hostnames ending in "tederga.org". SKIP when the user is deploying to a different platform (Vercel, Fly, Render, AWS, GCP) or asking general K8s questions unrelated to tedplatform.
---

# Tedplatform Publish — workflow skill

You are deploying an application to **Tedplatform**, a managed Kubernetes
platform. The platform exposes ~20 MCP tools via the `tedplatform` MCP
server (typically `https://mcp.tederga.org/mcp` or local
port-forward). Use them; don't reach for raw `kubectl`, `helm`, or
`docker` unless explicitly asked.

## Mental model — read this once per session

The platform's contract:

- **Tenants** are isolation boundaries — created via `tenant_onboard`. Each
  tenant gets prod+test K8s namespaces, a Keycloak group, a Harbor image
  project, a wildcard TLS cert, and default-deny+base-allow NetworkPolicies.
- **Apps** run inside a tenant ns and become reachable via `app_expose`
  (writes an AppExposure CR → Contour HTTPProxy + DNS + TLS).
- **Dependencies** (Postgres, Redis, Kafka) are tenant-scoped CRs created
  via `db_provision`. Each returns a `secret_ref` the app's Deployment
  mounts as `DATABASE_URL` / `REDIS_HOST` / `KAFKA_BROKERS`.
- **CI** (image build + push + signing) happens in **GitHub Actions** of
  the user's tenant repo — NOT via MCP. After CI, ArgoCD auto-syncs the
  new tag from the infra repo.

**Your job is not to ask the user technical platform questions** ("what
Postgres version?", "what Harbor robot token?"). The platform handles
those. **Your job is to map the user's intent into the right MCP call
sequence**, detecting what's needed from their code.

## Trigger flow

When the user says "publish" / "yayınla" / "deploy", follow these steps
in order. Don't skip steps even if you think you know what the user wants
— ask if uncertain about a specific value (tenant name, app name).

### Step 0 — Connect & introspect

Call `tedplatform_help` once at session start (it returns the full
orchestration guide). Then call `tools/list` to see the live tool roster
(it may differ from this skill — the live response is authoritative).

If `tools/list` doesn't include the tools below, the user isn't connected
to a Tedplatform MCP server — tell them to add it to their Claude Desktop
config first (see https://github.com/grknatabay/tedplatform-claude/blob/main/CLAUDE_DESKTOP.md
or equivalent).

### Step 1 — Detect dependencies from the user's code

Scan the user's working directory for dependency manifests:

| Manifest | Detection | Provision as |
|---|---|---|
| `package.json` | dep includes `@prisma/client` or `prisma` | postgres |
| `package.json` | dep includes `drizzle-orm` + (`pg` \| `postgres`) | postgres |
| `package.json` | dep includes `pg` | postgres |
| `package.json` | dep includes `mongoose` or `mongodb` | NOT SUPPORTED — tell user |
| `package.json` | dep includes `redis` or `ioredis` | redis |
| `package.json` | dep includes `kafkajs` | kafka-topic |
| `package.json` | dep includes `mysql2` or `mysql` | NOT SUPPORTED — tell user |
| `go.mod` | uses `github.com/jackc/pgx` or `gorm.io/driver/postgres` | postgres |
| `go.mod` | uses `github.com/redis/go-redis` | redis |
| `go.mod` | uses `github.com/segmentio/kafka-go` or `github.com/twmb/franz-go` | kafka-topic |
| `requirements.txt` | includes `psycopg2` or `asyncpg` or `sqlalchemy[postgres]` | postgres |
| `requirements.txt` | includes `redis` | redis |

Also scan the source code itself for usage of `DATABASE_URL`,
`REDIS_HOST`, `KAFKA_BROKERS` env vars — confirms what env vars your
generated Deployment needs to inject.

Build a concrete dependency list before proceeding. Show it to the user
in plain language ("I detected Prisma + Redis — I'll provision 1 Postgres
cluster and 1 Redis instance").

### Step 2 — Ensure the tenant exists

Call `tenant_list`. Then:

- **If the user named the tenant explicitly** (e.g. "deneme1 adında CRM
  yap", "publish to acme") — DON'T ask for confirmation. Just call
  `tenant_onboard(tenant=<that name>)` if it isn't already there. The
  call is idempotent — re-running on an existing tenant is safe and
  cheap (returns `action=exists` for each substep).
- **If the user said "the project" / "my app" / "this thing"** without
  naming it — ASK once which tenant to use. Don't invent.
- **Don't reuse a wrong tenant.** If `tenant_list` shows similar names
  (e.g. "acme" and "acme-corp"), confirm which one.
- **If the tenant exists but is empty** (no apps yet) — continue
  straight to Step 3, no re-onboard, no re-confirm.

### Step 3 — Provision detected dependencies

For each detected dep, call `db_provision` once. Use `env=test` unless
the user explicitly says prod.

```
db_provision(tenant=acme, env=prod, kind=postgres, name=<app>-db)
db_provision(tenant=acme, env=prod, kind=redis,    name=<app>-cache)
db_provision(tenant=acme, env=prod, kind=kafka-topic,
             name=<app>-events, kafka_cluster=kafka/tedplatform-kafka)
```

Each call returns an `env_template` map and `secret_ref`. With Path C
(below) you pass `deps_json` to `tenant_app_publish` and it auto-wires
these into the Deployment — you do NOT have to thread them through env
vars by hand. Skip this step entirely if you've decided Claude will pass
deps in the same `tenant_app_publish` call.

If `kind=kafka-topic` errors with "no Kafka cluster", tell the user kafka
isn't provisioned on the platform yet — they should either restructure
to use Redis pub/sub or wait for the Kafka cluster rollout.

### Step 4 — Publish

Pick ONE path. **Path C is the default when you (Claude) wrote the code
this session** — one call goes from source bytes to a working URL.

**Path C — In-cluster one-shot publish (no GitHub, no YAML):**

Tar+gzip the user's source directory, base64-encode, and call:

```
tenant_app_publish(
  tenant=acme, app_name=crm, env=test,
  code_archive_b64=<base64>,
  port=8080,
  deps_json='[{"kind":"postgres","name":"crm-db"}]',
  hosts_json='["test.acme.tederga.org"]',
  visibility=public
)
```

This returns in **under 5 seconds** with a `job_id`:

```json
{ "job_id": "pub_abc123…",
  "status": "running",
  "hint":   "Poll tenant_app_publish_status …" }
```

The saga runs server-side and is decoupled from the HTTP request, so a
client-side transport timeout/disconnect does NOT abort it. Then poll
the status tool every 5-10 seconds until it terminates:

```
tenant_app_publish_status(job_id=pub_abc123…)
```

Terminal states:
- `status="succeeded"` — read `urls[]`. Curl the first URL (HTTPS, no -k)
  to sanity-check; report it to the user verbatim.
- `status="failed"` — read `error`. The `steps[]` list shows exactly
  which step failed; the surrounding fields hint at the fix.

Still running? `steps[]` shows progress (provision_postgres/crm-db →
build → pull_secret → deployment → service → appexposure → wait_ready).
Typical full run for a Go/Node CRM + Postgres dep: 90-150 seconds. If
the call is still running at 5 min, something is genuinely stuck —
look at the latest step.

What the saga does (same as v0.14.2, just async now):
1. Provisions each dep (Postgres/Redis) and waits for its Secret.
2. Decodes + validates the archive (fail-fast on non-gzip).
3. Builds with Kaniko, pushes to `harbor.tederga.org/<tenant>/<app>:sha-<ts>`.
4. Clones the Harbor robot dockerconfig into the env namespace.
5. Applies Deployment + Service with PodSecurity "restricted"-safe
   defaults (runAsNonRoot, drop ALL caps, seccomp RuntimeDefault,
   readOnlyRootFilesystem, /healthz probes). Auto-merges the deps'
   `env_template` into the Deployment.
6. Applies the AppExposure → controller creates HTTPProxy + DNS.
7. Waits for Deployment Ready and (best-effort) HTTPProxy admitted.
8. Marks the job succeeded with the final URL(s).

Re-runs of `tenant_app_publish` with the same args are idempotent —
every step keys on stable names. **Raw archive limit ~700 KB**; for
larger trees use Path A or B.

**Important** — if the initial `tenant_app_publish` call ever throws a
transport-level error (network, timeout, -32001), the saga may still
be running server-side. Try `tenant_app_publish_status` with the
last-known `job_id` first; if you don't have one, just re-run the
publish call — it's idempotent.

Defaults you can omit:
- `env=test`, `port=8080`, `visibility=public`, `health_path=/healthz`,
  `replicas=1`, `read_only_root_fs=true`, `timeout_seconds=240`
- `hosts_json` defaults to `["test.<tenant>.tederga.org"]` for test and
  `["<tenant>.tederga.org"]` for prod
- `env_vars_json` for extra env (literals or `secretKeyRef:secret/key`)
- `image=<ref>` instead of `code_archive_b64` if the image is already
  built (skips the build step)

**Path A — Fresh starter repo (user wants source code on GitHub):**

If the user wants a GitHub-backed repo from day one and their stack
matches a starter (`nestjs-postgres`, `go-postgres`, `nextjs`):

```
tenant_app_create(tenant=acme, app_name=crm, starter=nestjs-postgres, private=true)
```

Creates `<tenant>-<app>` repo, populates from starter, substitutes
`REPLACE_TENANT` → tenant. Tell the user to clone, swap in their code,
push. GitHub Actions builds + pushes to Harbor; ArgoCD auto-syncs.

**Path B — User has a repo already:**

Tell them to push to `harbor.tederga.org/<tenant>/<app>` via their CI.
Reference the reusable workflow at
`grknatabay/tedplatform-ci-templates/.github/workflows/reusable-build-publish.yml`
(call it from their own `.github/workflows/ci.yml`). Repo secrets:

- `HARBOR_USER` = robot account name (cached in K8s Secret `<tenant>-build/harbor-robot-creds`)
- `HARBOR_TOKEN` = robot secret from the same Secret
- (Cosign signing uses OIDC keyless — no extra secret)

For paths A/B, after the build lands in Harbor, call `tenant_app_publish`
with `image=registry.tederga.org/<tenant>/<app>:<tag>` instead of
`code_archive_b64` to wire up Deployment + Service + AppExposure.

**Lower-level primitives** (only use when `tenant_app_publish` doesn't
fit, e.g. building once and deploying to many envs):

- `tenant_app_build` — just the Kaniko build half. Returns the image
  ref; you then deploy with `tenant_app_publish image=...`.
- `app_expose` — just the AppExposure half. Use when you already have a
  Service in place and only need to attach a route.

### Step 5 — Custom domains

For a customer-owned domain (e.g. `acme.com`) where the customer
pre-points DNS, follow the publish call with:

```
tenant_custom_domain_add(tenant=acme, domain=acme.com,
                         service_name=<app>, env=test, tls_mode=letsencrypt)
```

### Step 6 — Promote test → prod (when user says "production'a geç")

```
tenant_app_promote(tenant=acme, app_name=crm, from=test, to=prod)
```

This atomically:
- Clones the Deployment + Service to `<tenant>-prod`
- Mirrors any Postgres/Redis CRs (NEW empty DB in prod — data is NOT moved)
- Rewrites the AppExposure host (`test.X.tederga.org` → `X.tederga.org`)
- Switches any custom-domain HTTPProxy to prod ns (re-issues LE cert if needed)
- Auto-wires DNS for the new prod hosts

The prod URL `<tenant>.tederga.org` is the **apex** of the tenant's
wildcard cert (the wildcard cert SAN now includes the apex — no extra
cert needed).

### Step 7 — Verify

Call `app_status(name=<app>)` — wait for sync=Synced & health=Healthy.
Then `curl https://<app>.<tenant>.tederga.org/healthz` to prove the
public URL works.

Report to the user with the URL + the Secret names they may want to
reference in their app config.

## Examples

### Example A — "deneme1 adında CRM yap, Go+PG kullan, test olarak yayınla"

```
1. Generate code locally: cmd/server, internal/handlers, go.mod with pgx,
   minimal Dockerfile.
2. tenant_list → "deneme1" not present. User named it explicitly → no
   confirmation. Just call tenant_onboard(tenant=deneme1).
3. Detect from go.mod: github.com/jackc/pgx → postgres needed.
4. tar -czf code.tar.gz . → base64.
5. tenant_app_publish(
     tenant=deneme1, app_name=api, env=test,
     code_archive_b64=<...>, port=8080,
     deps_json='[{"kind":"postgres","name":"crm-db"}]',
     hosts_json='["test.deneme1.tederga.org"]').
   → returns job_id="pub_abc…", status="running" (in <5s).
6. Poll tenant_app_publish_status(job_id=pub_abc…) every 5-10s.
   After ~90-150s → status="succeeded",
   urls=["https://test.deneme1.tederga.org/"].
7. curl -sI https://test.deneme1.tederga.org/  → expect HTTP 200.
```

That's the full publish. The single `tenant_app_publish` call covers
build + deploy + expose + DNS + readiness in one go.

### Example B — "ahmetbsd.com bağla" (custom domain, customer pre-pointed DNS)

```
1. tenant_custom_domain_add(tenant=deneme1, domain=ahmetbsd.com,
                            service_name=api, env=test,
                            tls_mode=letsencrypt).
2. Tool runs DNS pre-flight (ahmetbsd.com → 194.187.253.62?) — if yes,
   creates LE Certificate + HTTPProxy in deneme1-test ns. ~60s for cert.
3. curl -sI https://ahmetbsd.com/  → HTTP 200.
```

### Example C — "production'a geç"

```
1. tenant_app_promote(tenant=deneme1, app_name=api, from=test, to=prod).
   → clones Deployment + Service into deneme1-prod
   → mirrors Postgres CR (new empty crm-db in prod ns)
   → rewrites AppExposure host: test.deneme1.tederga.org → deneme1.tederga.org
   → if a custom-domain HTTPProxy exists in deneme1-test, switches it to
     deneme1-prod (re-issues LE cert in the new ns)
   → auto-wires DNS for the new prod host
2. URLs live: https://deneme1.tederga.org/  AND  https://ahmetbsd.com/
3. Note: data in test crm-db is NOT migrated. Use pg_dump | pg_restore
   between deneme1-test/crm-db-rw and deneme1-prod/crm-db-rw if needed.
```

### Example D — "Tenant'ı sil"

```
1. Confirm with user: "I'm about to delete tenant 'demo-pilot'. This
   removes prod + test namespaces, the Keycloak group, the Harbor project,
   and the wildcard cert. The build namespace + DNS records stay. OK?"
2. tenant_offboard(tenant=demo-pilot)  → returns DRY-RUN plan only.
3. Show user the plan, ask for explicit "yes, delete".
4. tenant_offboard(tenant=demo-pilot, confirm=true).
```

## Common failure modes (and your response)

- **`admin only`** → user's JWT lacks `tederga-admins` group. Tell them
  to re-auth as an admin or use only tenant-scoped tools.
- **`namespace not found`** → tenant_onboard hasn't run. Run it.
- **`refusing to allow a Personal Access Token to create or update
  workflow`** → should not happen post cont 11; platform PAT was rotated
  with `workflow` scope. If it recurs, re-rotate using
  `~/.secrets/scripts/rotate-github-pat.sh` with a fresh PAT.
- **CNPG Cluster created but Secret missing** → wait ~30-60s, CNPG is
  async. If still missing after 2 minutes, check operator logs.
- **`app_expose` OK but URL 503** → either the Service has no Endpoints
  yet (pod not ready) or the Service name in the call doesn't match
  what's in the Deployment. Use `app_status` to inspect.

## Anti-patterns — DON'T do these

- Don't call MCP tools without checking auth scope first. If a call
  returns `admin only`, surface that to the user; don't try to work
  around it.
- Don't run `kubectl apply` directly. Use the MCP tools.
- Don't generate K8s YAML by hand for tenant apps — `app_expose` and
  `db_provision` produce the right shape. Hand-rolled YAML will get
  blocked by the tenant-only Kyverno Enforce policies (privileged
  containers, missing resources, hostNetwork).
- Don't push images to Docker Hub or anywhere except
  `harbor.tederga.org/<tenant>/<app>`. The Deployment pulls from there.
- Don't ask the user for Vault tokens, Harbor robot passwords, or
  Keycloak admin creds. The MCP server has those out-of-band.

## Where to read more

- `tedplatform_help` MCP tool — re-readable orchestration guide.
- `tedplatform_help topic=publish` — just the publish flow.
- `tedplatform_help topic=troubleshoot` — common error recipes.
- `tedplatform_help topic=tools` — live tool roster.
- `https://github.com/grknatabay/tedplatform-mcp/blob/main/docs/CLAUDE_DESKTOP.md` — Claude Desktop config.
