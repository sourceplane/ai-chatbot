# ai-chatbot

Vercel's [Next.js AI Chatbot](https://github.com/vercel/ai-chatbot) — AI
SDK 7 streaming chat with tools and artifacts, Auth.js with a guest flow,
Drizzle over Postgres, image attachments — running on **Cloudflare Workers +
Static Assets** through
[`@opennextjs/cloudflare`](https://opennext.js.org/cloudflare), with its
Postgres a **Supabase** project reached through **Hyperdrive**, its
attachments in an **R2** bucket, and the project, the Hyperdrive config, the
bucket and the schema all provisioned by Terraform and Orun's db-migrate
through [Orun](https://github.com/sourceplane/orun), the way the
[Lumen baseline](https://github.com/sourceplane/lumen) does it.

The template's code is the code. What the port changes is where the
Postgres client comes from (the `HYPERDRIVE` binding, one client per call),
where attachments go (the `BLOB` R2 binding, served back at
`/api/files/<key>`), and the Vercel-only modules — Blob, BotID,
`@vercel/functions`, `@vercel/otel`, `@vercel/analytics` — each replaced by
its Cloudflare counterpart or a no-op. The AI Gateway stays. See
[`specs/epics/ai-chatbot`](specs/epics/ai-chatbot/README.md) for the design,
the milestones and the as-built status with every departure.

## What is here

| Surface | Where |
|---|---|
| The chat, auth, artifacts, tools, components and hooks | `apps/web/app`, `apps/web/components`, `apps/web/artifacts`, `apps/web/lib`, `apps/web/hooks` |
| Postgres through Hyperdrive (`getDb()`), the schema for drizzle-kit | `apps/web/lib/db/queries.ts`, `apps/web/lib/db/schema.ts`, `apps/web/lib/db/migrations` |
| Attachments on R2 (upload, serve) | `apps/web/app/(chat)/api/files/upload`, `apps/web/app/(chat)/api/files/[...key]` |
| The Vercel-only stand-ins | `apps/web/lib/geo.ts`, `apps/web/lib/bot.ts`, `apps/web/instrumentation.ts`, `apps/web/components/cloudflare-web-analytics.tsx` |
| Workers build and deploy contract | `apps/web/next.config.ts`, `apps/web/open-next.config.ts`, `apps/web/wrangler.template.jsonc`, `apps/web/component.yaml` |
| The schema as migrations, and their runner | `packages/db` (`@saas/db`), `infra/db-migrate` |
| The Supabase project, the Hyperdrive config, the R2 bucket (stage, prod) | `infra/terraform/supabase`, `infra/terraform/cloudflare-hyperdrive`, `infra/terraform/cloudflare-r2` |
| Tests | `tests/web` (vitest: helpers, the shims, the attachment routes), `tests/db` (vitest: the manifest, the offline plan); upstream's Playwright suite stays in `apps/web/tests` behind `test:e2e` and is not run in CI |

## Getting started

```bash
pnpm install
pnpm run wire:fixture   # render apps/web/wrangler.jsonc from the offline fixture
pnpm typecheck
pnpm lint               # the template's own biome/ultracite in apps/web; eslint in the packages
pnpm test               # tests/web, tests/db
pnpm build              # next build + opennextjs-cloudflare build → apps/web/.open-next
```

## Local development

The app needs a Postgres, a model key and an auth secret.

1. **Postgres.** Any local Postgres works; the wrangler config points the
   `HYPERDRIVE` binding's `localConnectionString` at
   `postgres://postgres:postgres@localhost:5432/postgres` (edit it if
   yours differs). Apply the schema with drizzle-kit, which reads
   `POSTGRES_URL` from `apps/web/.env.local`:

   ```bash
   cp apps/web/.env.example apps/web/.env.local   # set POSTGRES_URL, AUTH_SECRET, AI_GATEWAY_API_KEY
   pnpm --filter @app/web db:migrate              # drizzle-kit migrate over apps/web/lib/db/migrations
   ```

   (In stage and prod the same SQL is applied by `infra/db-migrate` from
   `packages/db`; drizzle-kit is local-only.)

2. **Model key.** `AI_GATEWAY_API_KEY` from
   [Vercel AI Gateway](https://vercel.com/ai-gateway) — the template's
   provider, model list and capability lookups all speak the gateway's API.
   To route through Cloudflare AI Gateway instead, point the `ai` gateway
   provider's `baseURL` at it (`apps/web/lib/ai/providers.ts`).

3. **Run it.**

   ```bash
   pnpm --filter @app/web dev        # http://localhost:3000 — Next's dev server with the Worker's bindings (HYPERDRIVE → your Postgres, BLOB → a local R2)
   pnpm --filter @app/web preview    # wrangler dev over the built Worker; secrets from apps/web/.dev.vars (see .dev.vars.example)
   ```

   Opening `/` signs you in as a guest (a row in `User`); `/register`
   creates an account. Attachments land in the local R2 emulation and are
   served from `/api/files/<key>`.

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
| Vercel AI Gateway (OIDC on Vercel) | The same gateway with `AI_GATEWAY_API_KEY` as a Worker secret |
| Redis resumable streams + IP rate limit (`REDIS_URL`) | Off, as upstream is without `REDIS_URL`; per-user entitlements still apply |
| Project env vars in the dashboard | `AUTH_SECRET`, `AI_GATEWAY_API_KEY` as Worker secrets per environment; the Hyperdrive id and bucket name as bindings rendered from the infra roots' wiring documents |
| Deploy on push | Orun deploys `ai-chatbot-web-{stage,prod}` on merge to `main` (`apps/web/component.yaml`), after the three roots and db-migrate |

## Deploying

`.github/workflows/checks.yml` runs install, wire, typecheck, lint, test
and build on every push and pull request. `ci.yml` is the Orun pipeline:
set `execution.state.workspace` in `intent.yaml` to this product's workspace
(`orun cloud link`), connect Cloudflare **and Supabase** to that workspace,
and set the `ORUN_CI` repository variable to `true`. A merge to `main`
then applies the Supabase project, the Hyperdrive config and the R2 bucket,
applies the schema with db-migrate, builds the app with that environment's
Hyperdrive id and bucket name rendered into `wrangler.jsonc`, and deploys
the Worker to `stage`, then `prod`.

Two Worker secrets are yours to set once per environment, before the first
deploy takes traffic:

```bash
wrangler secret put AUTH_SECRET          --name ai-chatbot-web-stage   # openssl rand -base64 32
wrangler secret put AI_GATEWAY_API_KEY   --name ai-chatbot-web-stage
```

(and again for `ai-chatbot-web-prod`). Without `AUTH_SECRET` every
signed-in request fails at the proxy; without the gateway key the chat
route answers with the gateway's error.
