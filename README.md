# ai-chatbot

Vercel's [Next.js AI Chatbot](https://github.com/vercel/ai-chatbot) — AI
SDK 7 streaming chat with tools and artifacts, Auth.js with a guest flow,
Drizzle over Postgres, image attachments — running on **Cloudflare Workers +
Static Assets** through
[`@opennextjs/cloudflare`](https://opennext.js.org/cloudflare), with its
models on **Workers AI** through the Worker's own binding, its Postgres a
**Supabase** project reached through **Hyperdrive**, its attachments in an
**R2** bucket, and the project, the Hyperdrive config, the bucket and the
schema all provisioned by Terraform and Orun's `db-migrate` through
[Orun](https://github.com/sourceplane/orun), the way the
[Lumen baseline](https://github.com/sourceplane/lumen) does it — and packaged
as an **Orun baseline**: one command takes a new chatbot from nothing to live
on stage and prod, in its own repository, under its own name, in ONE
landing.

The template's code is the code. What the port changes is what the Workers
runtime and a fresh, unattended deployment force: the Postgres client comes
from the `HYPERDRIVE` binding, one per call; attachments go to the `BLOB` R2
binding and are served back at `/api/files/<key>`; the Vercel-only modules —
Blob, BotID, `@vercel/functions`, `@vercel/otel`, `@vercel/analytics` — are
each replaced by their Cloudflare counterpart or a no-op; the models default
to Workers AI (so a fresh product chats with no model key, and the AI
Gateway's models appear only once its key is set); and the session key
defaults to one the database generates for itself (so no secret has to be
set by hand). What the baseline adds is everything needed to make a copy of
it somebody else's — built the way
[cirrus-baseline](https://github.com/sourceplane/cirrus-baseline) builds a
product, in one landing. See
[`specs/epics/ai-chatbot`](specs/epics/ai-chatbot/README.md) for the design,
the milestones and the as-built status, including every departure.

## Instantiating a product

```bash
git clone --depth 1 --branch <baseline-tag> https://github.com/sourceplane/ai-chatbot
cd ai-chatbot
orun new --blueprint repo-blueprint.yaml --out ~/products/acme-chat --run-hooks --resume \
  --set reponame=acme-chat --set productname="Acme Chat" \
  --set githuborg=acme-inc --set subdomain=<workers-dev-subdomain>
```

Or, once the platform's registry lists it, from the Orun console (Baselines →
`ai-chatbot` → Build). Two phases: **`01-product`** creates the repository,
mints the six brokered credentials (Cloudflare and Supabase) and lands the
whole product as one pull request, whose convergence on `main` provisions and
deploys it per environment in a fixed order —

```
supabase ──▶ cloudflare-hyperdrive ──▶ db-migrate ──▶ web
                                  cloudflare-r2 ──▶ web
```

— each edge `mode: enforced` on a push to main and advisory on a pull
request; then **`02-docs`** records the live deployment from probed facts.
**[BOOTSTRAP.md](BOOTSTRAP.md)** is the operator guide;
[docs/phases/](docs/phases/README.md) has a page per phase.

The new repository receives the **product only** — the app, the Terraform
roots, the migrations, the tests, its CI, its tooling, a README of its own
and its operating contract — renamed throughout to the product's name,
repository, Worker, Supabase project, Hyperdrive config and bucket. None of
this repository's machinery ships. **No AI vendor key is asked for**: the
platform brokers none, and the chat runs on Workers AI; the AI Gateway's key
is the owner's to add afterwards (the product's README, "Models"). The
Supabase organisation the build uses needs room for **two projects**, stage
and prod — the free plan's limit.

| What makes it a baseline | Where |
|---|---|
| The console card (inputs, secrets, programme) | `blueprint.yaml` |
| The build document (modules, phases, hooks) | `repo-blueprint.yaml` |
| This tree's identity, the product's README and the bootstrap's task contracts | `.baseline/` |
| The rename engine (product-name seam: `apps/web/lib/site.ts`) | `tooling/rebrand/rebrand.mjs` |
| The bootstrap's helpers (deferrals, redeploy marker, work-tree strip) | `tooling/bootstrap/` |
| The deployment-record renderer | `hooks/render-deployment-docs.sh` |
| The product's context pack | `ai/context/` |
| The baseline's tests: contract, wiring, leak, offline bootstrap and plans, end to end | `testing/`, `.github/workflows/baseline.yml` |
| Cutting a `baseline-vN` tag | `.github/workflows/tag.yml` |

## What is here (the product)

| Surface | Where |
|---|---|
| The product's name | `apps/web/lib/site.ts` |
| The chat, auth, artifacts, tools, components and hooks | `apps/web/app`, `apps/web/components`, `apps/web/artifacts`, `apps/web/lib`, `apps/web/hooks` |
| The models (Workers AI by default; the AI Gateway when its key is set) | `apps/web/lib/ai/models.ts`, `apps/web/lib/ai/providers.ts` |
| Postgres through Hyperdrive (`getDb()`), the schema for drizzle-kit | `apps/web/lib/db/queries.ts`, `apps/web/lib/db/schema.ts`, `apps/web/lib/db/migrations` |
| The session key: AUTH_SECRET, or the one the database generated | `apps/web/lib/auth-secret.ts` |
| Attachments on R2 (upload, serve) | `apps/web/app/(chat)/api/files/upload`, `apps/web/app/(chat)/api/files/[...key]` |
| The database check the deploy smoke-tests | `apps/web/app/api/health/route.ts` |
| The Vercel-only stand-ins | `apps/web/lib/geo.ts`, `apps/web/lib/bot.ts`, `apps/web/instrumentation.ts`, `apps/web/components/cloudflare-web-analytics.tsx` |
| Workers build and deploy contract | `apps/web/next.config.ts`, `apps/web/open-next.config.ts`, `apps/web/wrangler.template.jsonc` → `wrangler.jsonc` (committed), `apps/web/component.yaml` |
| The schema as migrations, and their runner | `packages/db` (`@saas/db`), `infra/db-migrate` |
| The Supabase project, the Hyperdrive config, the R2 bucket (stage, prod) | `infra/terraform/supabase`, `infra/terraform/cloudflare-hyperdrive`, `infra/terraform/cloudflare-r2` |
| Tests | `tests/web`, `tests/db` (vitest); upstream's Playwright suite stays in `apps/web/tests` behind `test:e2e` and is not run in CI |

## Getting started

```bash
pnpm install
pnpm run wire:fixture   # re-render apps/web/wrangler.jsonc from its template (committed; this changes nothing)
pnpm typecheck
pnpm lint               # the template's own biome/ultracite in apps/web; eslint in the packages
pnpm test               # tests/web, tests/db
pnpm build              # next build + opennextjs-cloudflare build → apps/web/.open-next
```

The build needs no database, no Cloudflare account and no model key.
Running it locally — a Postgres, `pnpm --filter @app/web db:migrate`,
`next dev` or `wrangler dev` (Workers AI is reached remotely, so
`wrangler login` first) — is in the product's README
(`.baseline/product/README.md`), which is what a product built from here
carries.

## How it maps to Vercel

| Vercel | Here |
|---|---|
| Next.js hosting, `proxy.ts` on the edge | One Cloudflare Worker (`.open-next/worker.js`) + Static Assets; the proxy runs in the Worker |
| Neon Postgres via `POSTGRES_URL`, one client at module scope | A Supabase project's Postgres through Hyperdrive; `getDb()` builds the `postgres` + drizzle client per call from the `HYPERDRIVE` binding (`apps/web/lib/db/queries.ts`) |
| `tsx lib/db/migrate` at build time | `packages/db` holds the SQL; Orun's `db-migrate` applies it per environment before the Worker deploys |
| Vercel Blob for attachments | The `BLOB` R2 bucket; uploads keyed `<uuid>/<name>`, served by the Worker at `/api/files/<key>` (public by URL, as Blob's were) |
| `@vercel/functions` geolocation / ipAddress | `request.cf` and `cf-connecting-ip` (`apps/web/lib/geo.ts`) |
| BotID | Removed; `lib/bot.ts` never flags a request — use Cloudflare Bot Management or Turnstile at the edge |
| `@vercel/otel` + `@ai-sdk/otel` | Workers observability (`observability.enabled` in wrangler); `instrumentation.ts` registers nothing |
| `@vercel/analytics` | Cloudflare Web Analytics beacon (`NEXT_PUBLIC_CF_BEACON_TOKEN` at build time; unset renders nothing) |
| Vercel AI Gateway (OIDC on Vercel) for every model call | Workers AI through the `AI` binding by default (`workers-ai-provider`); the gateway's models only with `AI_GATEWAY_API_KEY` as a Worker secret |
| `AUTH_SECRET` set by the owner | Optional: unset, the session key is the one the environment's database generated (`app_private.secrets`) |
| Redis resumable streams + IP rate limit (`REDIS_URL`) | Off without `REDIS_URL`, as upstream; per-user entitlements still apply |
| A database created by hand | `infra/terraform/supabase` + `infra/terraform/cloudflare-hyperdrive` + `infra/terraform/cloudflare-r2`, ids and credentials as orun secrets |
| "Deploy with Vercel" (clone the template) | `orun new --blueprint repo-blueprint.yaml` — a new repository, branded, provisioned, deployed |

## CI

| Workflow | What it runs | Ships to a product |
|---|---|---|
| `checks.yml` | install, wire fixture (which must change nothing), typecheck, lint, test, build — every PR (not pushes: on main, `ci.yml` must be the only run a commit has, because the bootstrap's convergence watch takes the newest one) | yes |
| `ci.yml` | the Orun pipeline: `orun plan --changed`, then one job per lane; applies, migrates and deploys stage → prod on merge. It plans nothing while `intent.yaml` names the placeholder workspace `ws_CHANGE_ME`, as this repository does | yes |
| `baseline.yml` | the baseline's own tiers: contract tests; the blueprint read by the pinned orun, the leak gate, the offline bootstrap and the product's own plans; the product built, migrated into a local Postgres, dry-deployed, served, and chatted with through a stand-in AI binding | no |
| `tag.yml` | cuts a `baseline-vN` tag (manual) | no |
