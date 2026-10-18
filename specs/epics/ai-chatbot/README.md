# Epic: ai-chatbot (AC)

**Vercel's AI Chatbot is the largest template in the series and the one most entangled with Vercel's platform: Blob for attachments, BotID in front of the chat route, `@vercel/functions` for the request's geolocation, `@vercel/otel` for traces, the AI Gateway for models, Redis-backed resumable streams, and `tsx lib/db/migrate` in the build. The port keeps everything that is the chatbot — the AI SDK streaming route with its tools and artifacts, next-auth with the guest flow, Drizzle and the schema, the whole UI — and swaps each Vercel primitive for its Cloudflare + Supabase counterpart: a Supabase Postgres reached through Hyperdrive with the client built per call, an R2 bucket the Worker serves attachments from, `request.cf` for geolocation, Cloudflare Web Analytics, edge bot management in place of BotID, and the schema applied by Orun's db-migrate from `packages/db`. The gateway stays, because it is an HTTPS API and works from a Worker.**

The upstream code stays the code: `app/(chat)/api/chat/route.ts` with `streamText`, the document/suggestion tools and artifact handlers, `app/(auth)/auth.ts` with the credentials and guest providers, `lib/db/schema.ts` and every query body in `lib/db/queries.ts`, `proxy.ts`, the components and hooks. The port adds the Workers build, the monorepo wrapper, a test package over the pure helpers and the attachment routes, the migrations package and its tests, three Terraform roots and the db-migrate component, and the deploy contract that threads each environment's Hyperdrive id and bucket name into the Worker's bindings.

## Status

| Field | Value |
|-------|-------|
| Status | ✅ AC0–AC5 shipped (#1–#6), tagged `baseline-v1`: AC5 made the repository an Orun baseline (one landing), Workers AI the default model provider, the session key the database's own and row-level security universal. AC6 (the cirrus standard, AC-7) on `main`, not yet tagged. The Supabase, Hyperdrive and R2 applies, db-migrate and a live deploy are not yet proven by a live bootstrap (risks AC-K, AC-L) |
| Cluster | **AC** (AC0–AC6) |
| Owner(s) | `apps/web` (the app) · `tests/web` (vitest) · `packages/db` + `tests/db` (the schema) · `infra/terraform/{supabase,cloudflare-hyperdrive,cloudflare-r2}` + `infra/db-migrate` |
| Builds on | `lumen` conventions — the `supabase`, `cloudflare-hyperdrive` and `db-migrate` components, `@saas/db`, the orun-secrets wiring, the per-request `postgres` client; `cirrus-baseline` for the R2 root and the repository shape |
| Upstream | [vercel/ai-chatbot](https://github.com/vercel/ai-chatbot) v3.1 (AI SDK 7, Next 16, next-auth v5 beta, Drizzle) |
| Changes | Adds the Workers build, the monorepo wrapper, tests, the migrations package, the infra roots and the deploy contract; in the template's code: the per-call Postgres client, the R2 attachment routes, and shims for the Vercel-only modules (`lib/bot.ts`, `lib/geo.ts`, an empty `instrumentation.ts`) |
| Decisions locked | (1) OpenNext on Workers + Static Assets, `next` pinned to 16.3.8. (2) Postgres through Hyperdrive, one `postgres` client per `getDb()` call, never at module scope. (3) Attachments in R2 behind `/api/files/<key>`, public by unguessable URL exactly as Vercel Blob's `access: "public"` was. (4) The schema ships in `packages/db` and is applied by db-migrate; drizzle-kit stays for local development. (5) Static-assets incremental cache: the app has no `use cache` and nothing revalidates. (6) No Redis: resumable streams and the IP rate limit stay off, as upstream does without `REDIS_URL`. (7) `AUTH_SECRET` and `AI_GATEWAY_API_KEY` are Worker secrets set once per environment — **superseded by AC5**: both are optional; Workers AI through the `AI` binding is the default model provider, and the session key defaults to one the database generates. |
| Gate | AC1 is the first user-visible rung and is verified without a database (the Worker boots, the routes answer). AC2 and AC3 need a workspace with Supabase and Cloudflare connections to apply; they are verified by `plan`, `terraform validate` and the offline migration tests. |
| Shipped as | `baseline-v1` ([#6](https://github.com/sourceplane/ai-chatbot/pull/6)), then AC6 on `main`; proven offline (Baseline CI: contract, leak, placement and the e2e tier), deploy gated until a workspace is linked |

## Read order

1. `design.md` — what maps to what, the request flow, the cache decision, the env/secret flow, the rejected alternatives
2. `implementation-plan.md` — the milestones and what "done" means for each
3. `risks-and-open-questions.md` — what could go wrong and what was decided
4. `IMPLEMENTATION-STATUS.md` — what actually shipped (kept distinct from intent)

## Milestones at a glance

| Milestone | What it lands | Done when |
|---|---|---|
| AC0 — the spec | this doc set and the task contracts | merged on `main` |
| AC1 — the chatbot on Workers | `apps/web` built by OpenNext with the Hyperdrive client and the R2 attachment routes, rendered wrangler config, `tests/web` | `wrangler dev` boots and answers; Checks green |
| AC2 — the schema through db-migrate | `packages/db` with the template's SQL, `tests/db`, `infra/db-migrate` | the manifest checks, the offline plan lists the migration |
| AC3 — Supabase, Hyperdrive and R2 from Terraform | the three roots and the app's wiring from them | the roots validate; the wiring keys match the template's tokens |
| AC4 — ready to instantiate | README, as-built status | a reader can run, test, preview and deploy it |
| AC5 — a baseline | the card, the build document, `.baseline/`, the rebrand engine, the bootstrap helpers, `testing/`; Workers AI by default, the database's session key, RLS, the committed wrangler config, `/api/health`, the R2 root on its own `r2-data` key | Baseline CI green: contract, leak, placement (infra before app) and the e2e tier |
| AC6 — the cirrus standard | no kiox, generated component docs, the context pack, status that agrees with the tags and the code | Baseline CI green with the docs check |
