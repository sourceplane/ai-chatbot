# ai-chatbot — design

> AC5 (a baseline) changed parts of this design: Workers AI is the default
> model provider, the session key is the database's own unless `AUTH_SECRET`
> is set, `wrangler.jsonc` is committed, and every table has row-level
> security. The passages it superseded are marked below and kept for the
> history; `IMPLEMENTATION-STATUS.md` is the as-built record.

## 1. What the template is

Next.js App Router (16, `cacheComponents`, React Compiler) + AI SDK 7. The
chat route (`app/(chat)/api/chat/route.ts`) validates the body with zod,
checks the session and the per-user hourly entitlement, saves the user
message, streams `streamText` through the AI Gateway (`lib/ai/providers.ts`,
`gateway.languageModel(id)`) with five tools — weather, create/edit/update
document, request suggestions — and persists the finished messages. Artifacts
(text, code, sheet) render beside the chat and are versioned in the
`Document` table. `next-auth` v5 (beta) provides a credentials provider with
`bcrypt-ts` and a guest provider; `proxy.ts` sends a cookie-less visitor
through `/api/auth/guest`. Drizzle over `postgres` holds users, chats,
messages, votes, documents, suggestions and stream ids. Image attachments are
uploaded to Vercel Blob and referenced by URL in the message parts. Biome
through ultracite is the linter; Playwright is the e2e suite.

Vercel-specific pieces: `@vercel/blob` (`put`), `botid` (`withBotId`,
`checkBotId`, `initBotId`), `@vercel/functions` (`geolocation`, `ipAddress`,
the `Geo` type), `@vercel/otel` + `@ai-sdk/otel` in `instrumentation.ts`,
`@vercel/analytics` (listed, not rendered), `resumable-stream` + `redis` when
`REDIS_URL` is set, `tsx lib/db/migrate` in the build script, and
`x-vercel-id` in an error log.

## 2. The mapping (Vercel → Cloudflare + Supabase)

| Vercel primitive the template uses | Here |
|---|---|
| Next.js hosting (SSR, streaming route handlers, `proxy.ts`) | Cloudflare Workers + Static Assets; the Worker is `@opennextjs/cloudflare` 1.20's output (`next` 16.3.8, the newest the adapter boots), assets bound as `ASSETS`, `proxy.ts` bundled as Node.js middleware |
| Postgres via `POSTGRES_URL` (Neon), one `postgres()` client at module scope in `lib/db/queries.ts` | A Supabase project's Postgres reached through a Hyperdrive config (`HYPERDRIVE` binding). `getDb()` builds `postgres(env.HYPERDRIVE.connectionString, { max: 5, fetch_types: false, prepare: false })` + drizzle **per call**, because a Workers socket cannot be reused across requests; every query body is unchanged, it just starts with `const db = await getDb()`. Without a Cloudflare context (drizzle-kit, scripts, tests) `POSTGRES_URL` is used, as upstream |
| `tsx lib/db/migrate` in the build script (drizzle migrator at build time) | The schema ships in `packages/db` (`@saas/db`) as `src/migrations/010_initial/up.sql`, verbatim from `lib/db/migrations/0000_initial.sql`, listed in `src/manifest.ts` with its checksum; `infra/db-migrate` applies it per environment through Supabase's Management API after the project exists. drizzle-kit and `lib/db/migrations` stay in `apps/web` for local development (`db:migrate` is `drizzle-kit migrate`) |
| Vercel Blob `put(name, body, { access: "public" })` in `api/files/upload` | `env.BLOB.put(key, body, { httpMetadata: { contentType } })` into the R2 bucket bound as `BLOB`, under `<uuid>/<safe-name>`; the response keeps Blob's shape (`url`, `downloadUrl`, `pathname`, `contentType`, `contentDisposition`) so the client is untouched. `url` is this app's `/api/files/<key>`, served by a new `app/(chat)/api/files/[...key]/route.ts` that streams the object out of R2 with its content type, etag and an immutable cache header; `?download=1` sends it as an attachment |
| Blob's public host in `images.remotePatterns` | Dropped: the attachment URL is same-origin |
| `@vercel/functions` `geolocation(request)` / `ipAddress(request)` / `Geo` | `lib/geo.ts`: the same functions and type over `request.cf` (from the raw request when present, else `getCloudflareContext().cf`) and the `cf-connecting-ip` header |
| BotID (`withBotId`, `checkBotId`, `initBotId`) | Removed; `lib/bot.ts` `checkBotId()` always returns `{ isBot: false }`, with the pointer to Cloudflare Bot Management / Turnstile. `instrumentation-client.ts` (which only initialised BotID) is gone |
| `@vercel/otel` + `@ai-sdk/otel` in `instrumentation.ts` | An empty `register()`; the Worker's `observability.enabled` gives logs and traces. `streamText`'s `telemetry` option stays and is a no-op without a registered tracer |
| `@vercel/analytics` | `components/cloudflare-web-analytics.tsx`, rendered in the root layout only when `NEXT_PUBLIC_CF_BEACON_TOKEN` is set at build time |
| Vercel AI Gateway (`ai`'s `gateway` provider, `AI_GATEWAY_API_KEY`; OIDC on Vercel) | **Superseded by AC5.** Workers AI through the Worker's `AI` binding (`workers-ai-provider`) is the default: Kimi K2.6 (`@cf/moonshotai/kimi-k2.6`) for the chat and the artifact tools, GLM 4.7 Flash (`@cf/zai-org/glm-4.7-flash`, thinking off) for titles. Upstream's gateway models are offered only when the optional `AI_GATEWAY_API_KEY` Worker secret is set (`getAvailableModels`). *AC1–AC4: unchanged — an HTTPS API, its key a Worker secret.* |
| Resumable streams + IP rate limit over Redis (`REDIS_URL`) | Off: no `REDIS_URL` is set. `consumeSseStream` returns before touching the stream context, `checkIpRateLimit` returns before touching Redis — both as upstream intends without Redis. The packages stay in the bundle, unused |
| Project env vars in the dashboard (`AUTH_SECRET`, `AI_GATEWAY_API_KEY`) | Worker secrets: `.dev.vars` locally, `wrangler secret put` once per environment. **Since AC5 both are optional**: unset, the session key is the one migration `020_app_secrets` generated into `app_private.secrets` (`lib/auth-secret.ts`), and the chat runs on Workers AI only |
| Deploy on push | Orun: `apps/web/component.yaml` (`cloudflare-workers-assets-turbo`) deploys `ai-chatbot-web-{stage,prod}` on merge to `main` once the product is linked, after the three roots and db-migrate |

## 3. The request flow

```
browser ──► ai-chatbot-web-<env> (Worker)
             ├─ proxy.ts: /ping → pong; /api/health passes without a session; no session → /api/auth/guest
             ├─ next-auth: credentials / guest ──► getDb() ──► HYPERDRIVE ──► Supabase Postgres
             ├─ POST /api/chat ──► getDb() (entitlement, chat, messages)
             │                 ├─► AI binding (Workers AI) ──► model           (the default, since AC5)
             │                 └─► AI Gateway (HTTPS, AI_GATEWAY_API_KEY) ──► model   (only with the key)
             ├─ POST /api/files/upload ──► BLOB.put(<uuid>/<name>) ──► R2
             └─ GET  /api/files/<uuid>/<name> ──► BLOB.get ──► stream (public by URL)
```

The chat route's `geolocation(request)` reads `request.cf`; the model's
image parts carry the `/api/files/...` URL, which the gateway's provider
fetches without a cookie — hence the route is public and `proxy.ts` lets
`GET /api/files/*` through (a cookie-less fetch would otherwise be sent to
the guest sign-in and create a user per fetch).

## 4. The cache decision

`cacheComponents: true` stays. The app has no `"use cache"`, no `cacheTag`
/ `revalidateTag` / `unstable_cache`, and every page is dynamic behind
`auth()`; what `next build` pre-renders is the static shells. The
static-assets incremental cache serves those from the Worker's assets
(`populateCache local` in the build script — since AC5, the same copy made
by `scripts/populate-static-assets-cache.mjs`, which opens no platform
proxy), the shape every port in the
series uses when nothing revalidates. The composable cache that the
static-assets cache does not support is not used.

The one caching hint left is `fetch(..., { next: { revalidate } })` in
`lib/ai/models.ts` (the gateway's model-capability and availability
lookups). On a read-only cache that data-cache write is a no-op, so those
lookups go to the gateway on each call; `/api/models` still sets a day-long
`Cache-Control` for the browser. (Since AC5 the Workers AI models declare
their capabilities, so these lookups happen only for gateway models, offered
only when `AI_GATEWAY_API_KEY` is set.) A deployment that wants them cached swaps
`open-next.config.ts` to `r2IncrementalCache` on the same bucket (a second
binding `NEXT_INC_CACHE_R2_BUCKET` on the `cloudflare-r2` wiring token, plus
the `WORKER_SELF_REFERENCE` service binding named `ai-chatbot-web-<env>`);
that path also needs `populateCache remote` as a documented one-off outside
the Orun lane, and first requests render on demand. Not taken here.

## 5. The env and secret flow

```
infra/terraform/supabase ──apply──► orun secrets (project/<env> rung)
   SUPABASE_PROJECT_REF, SUPABASE_DB_PASSWORD, SUPABASE_DB_URL
   (Lumen's three outputs since AC5; the API keys and WIRING_SUPABASE are gone)
        │
        ├──► infra/terraform/cloudflare-hyperdrive (origin = the project's Postgres)
        │       ──apply──► WIRING_CLOUDFLARE_HYPERDRIVE {hyperdrive_id, hyperdrive_name}
        ├──► infra/db-migrate (plan|apply packages/db/src/migrations through the Management API)
        │
infra/terraform/cloudflare-r2 ──apply──► WIRING_CLOUDFLARE_R2 {r2_bucket_name}   (its own r2-data key)
        │
apps/web/component.yaml secretEnv ◄──────────┘
   WIRING_CLOUDFLARE_HYPERDRIVE_<ENV>, WIRING_CLOUDFLARE_R2_<ENV>
      → tooling/wire/live.mjs → wrangler.jsonc (hyperdrive id, r2 bucket_name)
Worker secrets (per environment, by hand) — optional since AC5:
   AUTH_SECRET (unset: the key 020_app_secrets generated in app_private.secrets)
   AI_GATEWAY_API_KEY (unset: Workers AI only, through the AI binding)
Build-time, optional: NEXT_PUBLIC_CF_BEACON_TOKEN
```

`wrangler.template.jsonc` carries `@@wiring(cloudflare-hyperdrive/__ENV__:hyperdrive_id)@@`
and `@@wiring(cloudflare-r2/__ENV__:r2_bucket_name)@@`. `pnpm run
wire:fixture` renders it from `wiring.fixture.json`. ~~The verify lane renders
it from the fixture, the deploy lane from the live documents; the rendered
`wrangler.jsonc` is git-ignored.~~ **Superseded by AC5:** `wrangler.jsonc` is
committed as the fixture render (with a GENERATED banner), so the lane's
structure check finds it in a fresh checkout, and every lane re-renders it in
its own job tree — stage and prod from that environment's wiring documents
(refusing to build without them), dev from the fixture
(`live.mjs --fixture-envs dev`). The Hyperdrive binding also names
a `localConnectionString` (a Postgres on localhost) for `wrangler dev` and
`next dev`.

## 6. The repository

```
apps/web                      the template (app/, components/, lib/, artifacts/, hooks/, proxy.ts, tests/ for Playwright) + the Workers build
  lib/db/queries.ts           getDb(): the per-call Hyperdrive client; every query as written
  lib/geo.ts, lib/bot.ts      the @vercel/functions and BotID stand-ins
  app/(chat)/api/files/       upload → R2; [...key] → serve from R2
  component.yaml              render wrangler from the two wiring documents, build with turbo, deploy, smoke /ping and /api/health
  wrangler.template.jsonc     worker name, nodejs_compat, ASSETS, HYPERDRIVE (+ localConnectionString), BLOB, AI (since AC5)
  wrangler.jsonc              the fixture render, committed (since AC5)
  wiring.fixture.json         offline values for the verify lane
  open-next.config.ts         static-assets incremental cache
packages/db                   @saas/db: the control migration + 010_initial (the template's SQL), 020_app_secrets and 030_row_level_security (AC5), the runner
infra/db-migrate              applies packages/db/src/migrations per environment (depends on db, supabase)
infra/terraform/supabase      the Supabase project per environment (Lumen's root; its API-key outputs dropped in AC5)
infra/terraform/cloudflare-hyperdrive   the Hyperdrive config over that project's Postgres
infra/terraform/cloudflare-r2           the attachments bucket per environment
tests/web                     vitest: lib/utils, entitlements, the bot and geo shims, the two attachment routes (mocked session, mocked R2)
tests/db                      vitest: manifest checksums, the offline plan
```

Upstream's Playwright suite stays in `apps/web/tests` behind `test:e2e`; it
needs a running app with a database and a model key and is not run in CI.

## 7. The build

`next build` (Turbopack, standalone output traced from the monorepo root,
`cacheComponents` and `reactCompiler` kept, the `experimental.*` flags
kept) → `opennextjs-cloudflare build --skipBuild` → `populateCache local`
(since AC5, `scripts/populate-static-assets-cache.mjs`: the same copy,
without opening the platform proxy, so a build needs no Cloudflare
credential).
Lint is the template's own `ultracite check` (Biome 2.5), wired as the
package's `lint` script so `turbo run lint` runs it.

## 8. Out of scope

A Redis for resumable streams and the IP rate limit (a Worker would reach
one over TCP through `nodejs_compat`; Upstash or a Durable Object are the
Cloudflare-shaped answers, neither wired here), Cloudflare Images for the
attachment thumbnails (OpenNext serves `next/image` sources as-is without an
`IMAGES` binding), a custom domain, Bot Management / Turnstile configuration
(zone settings, documented pointer only), and the demo mode (`IS_DEMO`),
which is kept as written and untested.

## 9. Rejected alternatives

- **D1 instead of Supabase Postgres.** The schema and every query are
  Postgres (uuid defaults, `timestamp`, `json`, composite keys, Drizzle's
  `pg-core`); porting to SQLite would rewrite the data layer and the
  migrations, and the series' Supabase ports exist precisely to keep
  Postgres templates on Postgres.
- **Keep Vercel Blob through `BLOB_READ_WRITE_TOKEN`.** It works from a
  Worker (an HTTPS API), but leaves a Vercel dependency and a Vercel bill in
  a Cloudflare deployment; R2 behind the Worker's own route is a one-file
  change on each side.
- ~~**Workers AI as the model.** The template is gateway-shaped: model ids,
  `gatewayOrder`, the capabilities and availability lookups all speak the
  AI Gateway's API. Swapping the provider would change the model list and
  the UI; pointing the same provider at Cloudflare AI Gateway is the
  no-code-change option a deployment can take.~~ **Reversed in AC5:**
  Workers AI is the default. A product built unattended must chat with only
  Cloudflare and Supabase connected, and the platform brokers no AI vendor
  (risk AC-K). The gateway's models stay, as upstream lists them, offered
  only when `AI_GATEWAY_API_KEY` is set.
- **R2 incremental cache from the start.** Nothing revalidates and nothing
  is `"use cache"`; the only beneficiary would be the fetch data cache for
  the gateway's model lookups. The static-assets cache needs no extra
  bindings, no DO migrations and no remote populate step; the R2 path is
  documented in §4 for a deployment that wants it.
