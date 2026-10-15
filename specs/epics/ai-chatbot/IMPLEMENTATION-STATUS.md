# ai-chatbot (AC) — Implementation status

As-built ≠ intent. This file records what actually shipped, and every place
the code departed from `design.md` or from the upstream template.

> Rewritten in AC5. The copy AC4 merged (#5) carried another epic's status
> file by mistake (rag-chatbot's, "RG"); its own milestones, departures and
> verification are restored here from the PRs, the risks register and the
> code.

| Milestone | State | PR |
|---|---|---|
| AC0 — the spec | ✅ Shipped | [#1](https://github.com/sourceplane/ai-chatbot/pull/1) |
| AC1 — the chatbot on Workers | ✅ Shipped | [#2](https://github.com/sourceplane/ai-chatbot/pull/2) |
| AC2 — the schema through db-migrate | ✅ Shipped (planned offline; apply gated on a linked workspace) | [#3](https://github.com/sourceplane/ai-chatbot/pull/3) |
| AC3 — Supabase, Hyperdrive and R2 from Terraform | ✅ Shipped (validated; apply gated on a linked workspace) | [#4](https://github.com/sourceplane/ai-chatbot/pull/4) |
| AC4 — ready to instantiate | ✅ Shipped | [#5](https://github.com/sourceplane/ai-chatbot/pull/5) |
| AC5 — a baseline | 🔄 In review | this PR |

## Departures from the upstream template (AC1–AC4)

### `getDb()` in place of the module-level client (forced by the Workers runtime)

Upstream opened one `postgres(process.env.POSTGRES_URL)` client at module
scope in `lib/db/queries.ts`. On Workers a socket opened in one request
cannot be used by another, and the connection string is the `HYPERDRIVE`
binding's. `getDb()` builds `postgres(connectionString, { max: 5,
fetch_types: false, prepare: false })` + drizzle per call, from
`getCloudflareContext({ async: true }).env.HYPERDRIVE` when a Cloudflare
context exists and `POSTGRES_URL` otherwise. Every query body is upstream's
(risk AC-A).

### The schema from `packages/db`, applied by db-migrate

`tsx lib/db/migrate` left the build script, which is `next build &&
opennextjs-cloudflare build` (and, since AC5, the static-assets cache copy).
The SQL is upstream's `0000_initial.sql`, verbatim, as `010_initial` in
`packages/db`, applied per environment by `infra/db-migrate`; drizzle-kit
stays for local databases.

### Attachments in R2, public by unguessable URL

Vercel Blob's `put(…, { access: "public" })` became a put into the `BLOB` R2
binding under `<uuid>/<name>`, answered in Blob's response shape; the Worker
serves objects back at `/api/files/<key>` without a session, as Blob's
public URLs were (the model provider and `next/image` fetch them without the
cookie — risk AC-B).

### The Vercel-only modules

| Upstream | Here |
|---|---|
| BotID (`checkBotId`, `withBotId`, `initBotId`) | `lib/bot.ts` never flags a request; bot handling is a Cloudflare zone setting or Turnstile (AC-G) |
| `@vercel/functions` `geolocation` / `ipAddress` | `lib/geo.ts`: `request.cf` and `cf-connecting-ip`, same return shape |
| `@vercel/otel` + `@ai-sdk/otel` | Workers observability; `instrumentation.ts` registers nothing |
| `@vercel/analytics` | the Cloudflare Web Analytics beacon, rendered only with `NEXT_PUBLIC_CF_BEACON_TOKEN` |
| Redis resumable streams + IP rate limit | off without `REDIS_URL`, as upstream; per-user entitlements apply (AC-D) |

### Build, lint and versions

The template's biome/ultracite is the app's lint; eslint lints the
packages. `next.config.ts` adds `output: "standalone"` and the monorepo
tracing root for OpenNext; `open-next.config.ts` uses the static-assets
incremental cache (AC-C). Five dependencies are pinned to the versions
upstream's lockfile resolved (`streamdown`, `@streamdown/code`, `shiki`,
`@ai-sdk/provider`, …) because floating ranges broke `tsc` in upstream's own
files (AC-E).

## Departures added by AC5 (a baseline)

### Workers AI is the default model provider; the gateway is optional

Upstream sends every model call through the Vercel AI Gateway, which needs a
key no platform brokers. `lib/ai/providers.ts` now runs the Workers AI
models through the Worker's `AI` binding with `workers-ai-provider` 4.0.0 —
the chat (`@cf/moonshotai/kimi-k2.6`, the default), the titles
(`@cf/zai-org/glm-4.7-flash`, thinking off) and the artifact tools (they use
the chat's model). `lib/ai/models.ts` keeps upstream's gateway list as
`gatewayModels`, offered only when `AI_GATEWAY_API_KEY` is set
(`getAvailableModels`); `/api/models` returns `available`, and the picker
shows exactly that list (its logo comes from each model's `provider`, since
a Workers AI id starts with `@cf/`). A request naming a model the deployment
cannot run is answered by the default model (`resolveModelId`). Workers AI's
own errors appear in the chat ("Workers AI could not answer with …") rather
than as "Oops"; the writing-suggestions tool, which needs structured output,
returns its error to the model instead of failing the response. Workers AI
model capabilities are declared rather than fetched, so a chat no longer
makes five capability lookups to the gateway (AC-C).

### Dev-server bindings only in the dev server; no `populateCache`

`initOpenNextCloudflareForDev()` runs only for `next dev` (the config is a
phase function): the `AI` binding has no local simulator, so wrangler's
platform proxy opens a remote session, and a build must need no Cloudflare
credential. For the same reason the build's last step is
`scripts/populate-static-assets-cache.mjs` — the copy
`opennextjs-cloudflare populateCache local` makes for the static-assets
cache — instead of that command, which opens the platform proxy first.

### The session key is the database's own unless `AUTH_SECRET` is set

`lib/auth-secret.ts` returns `AUTH_SECRET` when set, else the 64-hex key
migration `020_app_secrets` generated into `app_private.secrets` (not a
schema the Data API exposes), read once per isolate. Auth.js is initialised
lazily (`NextAuth(async () => ({ …, secret }))`) so its config can await it;
`proxy.ts` and the guest route decode the session with it too (risk AC-N).
`lib/auth-cookie.ts` picks the session cookie's name as Auth.js does — the
`__Secure-` prefix over https only — where upstream used
`!isDevelopmentEnvironment`, which disagreed with Auth.js for the built
Worker served over http.

### Row-level security on every table in `public`

Migration `030_row_level_security` (drizzle twin `0002`; `.enableRLS()` on
each table in `schema.ts`) enables RLS with no policy on `User`, `Chat`,
`Message_v2`, `Vote_v2`, `Document`, `Suggestion` and `Stream`, behind a
guard (AC-M).

### The rest

- `apps/web/wrangler.jsonc` is committed (the fixture render, with a
  GENERATED banner); every lane re-renders it — stage and prod from their
  wiring documents, dev from the fixture (`live.mjs --fixture-envs dev`).
- `/api/health` (database reachable and migrated; which model provider
  serves) and `/ping` are what the smoke and the probes read; the proxy lets
  both through without a session.
- `lib/site.ts` is the product-name seam (the `<title>`, the sidebar
  tooltip, the preview label).
- `metadataBase` is the product's own origin, baked at build
  (`NEXT_PUBLIC_SITE_URL` from the environment's `SITE_URL` or its
  workers.dev URL), not upstream's `chat.vercel.ai`; the header's "Deploy
  with Vercel" button and its mobile icon link are gone, and the sign-in
  page says "Powered by Workers AI".
- The R2 root applies with its own `r2-data` key (`CLOUDFLARE_R2_TOKEN`);
  the Supabase root publishes Lumen's three outputs only; every infra edge
  is enforced on main and advisory on pull requests; stack-tectonic 0.19.0.

## Verified

- AC1–AC4: Checks (typecheck, lint, test, build); the Worker under
  `wrangler dev` without a Postgres; the offline migration plan;
  `terraform validate` on the three roots.
- AC5: the contract, wiring, leak and placement tests; `orun new --status`
  at v2.58.11, v2.78.4 and 2.79.0; `orun validate`; `orun work check`; the
  e2e tier — the product built in the job tree orun stages, migrated into a
  local Postgres by its own runner, served under `wrangler dev` with a guest
  signed in by the database's key, a chat streamed through a stand-in AI
  binding, titled, persisted and listed, an attachment round-tripped through
  local R2, a registration and a sign-in, and `anon`/`authenticated` reading
  none of it.

## Not verified (gated on a live bootstrap)

- The Supabase, Hyperdrive and R2 applies and db-migrate against a real
  project; a real deploy and its smoke.
- Workers AI itself: the model ids served on the account, tool calling
  driving the artifact tools, structured output for suggestions (AC-K).
- Whether the `workers-deploy` token may attach the `BLOB` R2 binding
  (AC-L).
