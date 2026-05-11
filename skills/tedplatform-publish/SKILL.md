---
name: tedplatform-publish
description: Use this skill when the user wants to deploy an application to the Tedplatform managed Kubernetes platform. TRIGGER when the user says any of "publish", "deploy", "yayınla", "release", "ship", "go live", "push to prod" AND there's tedplatform code/context in the conversation — OR when they reference "tenant", "tedplatform", or hostnames ending in "tederga.org". SKIP when the user is deploying to a different platform (Vercel, Fly, Render, AWS, GCP) or asking general K8s questions unrelated to tedplatform.
---

# Tedplatform Publish — workflow skill

You are deploying an application to **Tedplatform**, a managed Kubernetes
platform. The platform exposes ~20 MCP tools via the `tedplatform` MCP
server (typically `https://mcp.teleport.tederga.org/mcp` or local
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
config first (see https://mcp.teleport.tederga.org/docs/CLAUDE_DESKTOP.md
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

Each call returns an `env_template` map and `secret_ref` — KEEP these.
You need them in Step 5 when writing the Deployment manifest.

If `kind=kafka-topic` errors with "no Kafka cluster", tell the user kafka
isn't provisioned on the platform yet — they should either restructure
to use Redis pub/sub or wait for the Kafka cluster rollout.

### Step 4 — Get the code into the cluster

Pick ONE path. **Path C is the default when you (Claude) wrote the code
this session** — it's the fastest path to a running URL.

**Path C — In-cluster Kaniko build (no GitHub):**

Tar+gzip the user's source directory, base64-encode, and call:

```
tenant_app_build(tenant=acme, app_name=crm,
                 code_archive_b64=<base64>,
                 dockerfile_path=Dockerfile,
                 wait=true)
```

The tool spawns a Kaniko Job in `<tenant>-build` namespace, builds the
image, pushes it to `harbor.tederga.org/<tenant>/<app>:sha-<ts>`, and
(when `wait=true`) returns the final status + log tail. Auto-creates the
Harbor robot account on first call and caches creds in Vault. **Raw
archive limit ~700 KB** — for larger trees use Path A or B.

The returned `image` field is what you'll put in the Deployment you
write next. Generate a minimal Deployment + Service YAML, `kubectl apply`
it to `<tenant>-test` (or `<tenant>-prod`) — or let your AppExposure
controller wire it.

**Path A — Fresh starter repo (user wants source code on GitHub):**

If the user wants a GitHub-backed repo from day one and their stack
matches a starter (`nestjs-postgres`, `go-postgres`, `nextjs`):

```
tenant_app_create(tenant=acme, app_name=crm, starter=nestjs-postgres, private=true)
```

Creates `<tenant>-<app>` repo, populates from starter, substitutes
`REPLACE_TENANT` → tenant. Tell the user to clone, swap in their code,
push.

**Path B — User has a repo already:**

Tell them to push to `harbor.tederga.org/<tenant>/<app>` via their CI.
The platform's tenant-template repo includes `_pending_workflows/ci.yml`.
Repo secrets:

- `HARBOR_USER` = robot account name from Vault `secret/tenants/<tenant>/harbor`
- `HARBOR_TOKEN` = robot secret from the same path
- (Cosign signing uses OIDC keyless — no extra secret)

### Step 5 — Wait for the image (only paths A/B)

For path C, the build is synchronous (you waited inside `tenant_app_build`).
For paths A/B, the build happens in GitHub Actions. Poll `app_list` until
the ArgoCD Application shows `sync=Synced & health=Healthy`. If it
doesn't appear within 2 minutes, ask the user to check their CI run.

### Step 6 — Expose to traffic

```
app_expose(namespace=<tenant>-test, name=<app>, service=<svc-name>,
           port=8080, visibility=public,
           hosts=test.<tenant>.tederga.org)
```

For initial publish use `env=test` → host `test.<tenant>.tederga.org`.
The per-tenant wildcard cert covers it.

**DNS is auto-wired** by `app_expose` for *.tederga.org hosts — you do
NOT need to call `dns_set` afterwards. The response includes a `dns`
array showing what changed.

For a custom domain (e.g. `acme.com`) the customer pre-points DNS, then:

```
tenant_custom_domain_add(tenant=acme, domain=acme.com,
                         service_name=<app>, env=test, tls_mode=letsencrypt)
```

### Step 7 — Promote test → prod (when user says "production'a geç")

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

### Step 8 — Verify

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
4. db_provision(tenant=deneme1, env=test, kind=postgres, name=crm-db).
   → secret_ref { name: 'crm-db-app' }, env_template DATABASE_URL.
5. tar -czf code.tar.gz . → base64. Inject DATABASE_URL envFrom in your
   generated Deployment template (the Deployment YAML you'll apply
   alongside).
6. tenant_app_build(tenant=deneme1, app_name=api,
                    code_archive_b64=<...>, wait=true).
   → image: harbor.tederga.org/deneme1/api:sha-1747000000.
7. kubectl -n deneme1-test apply -f <Deployment + Service>  (with the
   image and DATABASE_URL envFrom from secret_ref).
8. app_expose(namespace=deneme1-test, name=api, service=api, port=8080,
              visibility=public, hosts=test.deneme1.tederga.org).
   → DNS auto-wired by the tool.
9. curl -sI https://test.deneme1.tederga.org/  → expect HTTP 200.
```

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
  workflow`** → platform PAT lacks `workflow` scope. The starter ships
  workflows at `_pending_workflows/` — tell user to commit them via web
  UI (no PAT involved) or rotate the PAT with workflow scope.
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
