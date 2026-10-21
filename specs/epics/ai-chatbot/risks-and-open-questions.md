# ai-chatbot — risks and open questions

## AC-A — A Workers socket cannot outlive its request (RESOLVED)

Upstream's module-scope `postgres()` client would be reused across requests
and the runtime refuses it ("Cannot perform I/O on behalf of a different
request" — Lumen hit exactly this). `getDb()` builds the client per call
from the HYPERDRIVE binding; Hyperdrive holds the real connection pool, so
a per-call client costs a local handshake, not a Postgres connection. Every
query body is unchanged.

## AC-B — Attachments must be fetchable without the session cookie (RESOLVED)

The brief asked for the serving route to be auth-checked like the upload.
It is not, deliberately: the model provider fetches image parts by URL
through the gateway, and `next/image` fetches the source server-side —
neither carries the browser's cookie, and the proxy would have sent each
such fetch to the guest sign-in (creating a user per fetch). Vercel Blob's
`access: "public"` had the same property: public, unguessable URL. The key
is `<uuid>/<name>`, the route is public, and `proxy.ts` lets `GET
/api/files/*` through. Upload stays session-gated and validated as upstream.

## AC-C — `cacheComponents` on OpenNext with the static-assets cache (ACCEPTED)

No `"use cache"`, no tags, every page dynamic: the pre-rendered shells are
the only cache content and the read-only static-assets cache serves them.
The `fetch(..., { next: { revalidate } })` hints in `lib/ai/models.ts`
become live fetches (five parallel gateway lookups per chat message for
capabilities, one for availability after nine seconds); the browser still
caches `/api/models` for a day. The R2 incremental cache on the same bucket
is the documented upgrade (design §4) if that cost matters.

*Since AC5:* the Workers AI models declare their capabilities in
`lib/ai/models.ts`, so a chat makes no capability lookups unless
`AI_GATEWAY_API_KEY` is set and the gateway's models are offered; the cost
above applies only to that deployment.

## AC-D — Resumable streams and the IP rate limit need Redis (ACCEPTED)

Both are opt-in on `REDIS_URL` upstream and both degrade cleanly without
it: `consumeSseStream` returns before creating a stream context,
`checkIpRateLimit` returns before touching a client, `/api/chat/[id]/stream`
is a 204. Per-user entitlements (10 messages/hour) still apply from the
database. No Redis is provisioned; the `redis` and `resumable-stream`
packages stay in the bundle, unused.

## AC-E — Floating dependency ranges drift past the template (RESOLVED)

Upstream pins by lockfile, not by range. Without that lockfile `streamdown`
(2.3 → 2.7) narrowed a prop type the template spreads, `@streamdown/code`
(1.0.3 → 1.1.1) changed its plugin type, `shiki` and `@ai-sdk/provider`
followed, and `tsc` failed in upstream's own files. Those five are pinned
to the versions upstream's lockfile resolved; everything else floats as
upstream wrote it.

## AC-F — The model gateway from a Worker (ACCEPTED; superseded by AC-K)

The AI Gateway is an HTTPS API; the Worker calls it with
`AI_GATEWAY_API_KEY` (no OIDC off Vercel, as upstream's README says for
non-Vercel deployments). Model streaming responses are long-lived; Workers
allow it, and the route's `maxDuration = 60` is a Vercel hint the Worker
ignores. The `x-vercel-id` header read in the chat route's error log is
simply null here.

## AC-G — BotID is gone (ACCEPTED, documented)

`lib/bot.ts` never flags a request. Bot handling on Cloudflare is a zone
setting (Bot Management / Super Bot Fight Mode) or a Turnstile challenge on
the chat form; neither is in the repository. Per-user entitlements and the
guest flow still bound what an unauthenticated visitor can do.

## AC-H — Worker secrets are set by hand (ACCEPTED; superseded by AC5)

`AUTH_SECRET` and `AI_GATEWAY_API_KEY` are set once per environment with
`wrangler secret put`; the deploy lane renders the wrangler config from the
wiring documents and does not touch secrets. A missing `AUTH_SECRET` makes
every signed-in request fail at the proxy; the README says so.

## AC-I — First request latency: bcrypt at module load (ACCEPTED)

`lib/constants.ts` hashes a dummy password with bcrypt (10 rounds) when the
module loads, as upstream does, to make credential checks constant-time.
On a cold Worker isolate that lands on the first auth request; well within
limits and identical to a cold Vercel function.

## AC-J — Node ≥ 25 locally (SETTLED)

The build and tests were run on Node 25; CI builds on Node 22. Nothing in
this template reads `localStorage` at prerender.

## AC-K — Workers AI by default; real models unverified offline (OPEN until a live bootstrap)

The platform brokers no AI vendor, so a product built from the baseline must
chat with only Cloudflare and Supabase connected. Workers AI through the
Worker's `AI` binding is the default (`lib/ai/models.ts`: Kimi K2.6 for the
chat, GLM 4.7 Flash for titles), via `workers-ai-provider` 4.0.0 (AI SDK 7,
`@ai-sdk/provider` 4). The e2e cannot call Workers AI: it stands the binding
in with a deterministic Worker (`testing/lib/fake-ai/`) that answers
`run()` in the binding's own shapes. So what is proven offline is the app's
half — the route picks the model, the provider streams the binding's events,
the title, the persistence, the fallback from an unavailable gateway model.
What is NOT proven until a live deployment: that those model ids are served
on the account, that their tool calls drive the artifact tools, and that the
writing-suggestions tool's structured output is honoured (it answers the
model with the error instead of failing the chat if it is not). Workers AI
usage is billed to the Cloudflare account after its free allocation.

## AC-L — The deploy token and the R2 binding (OPEN, platform)

The `cloudflare-r2` root applies with its own `r2-data` key
(`CLOUDFLARE_R2_TOKEN`), not the deploy token. But the Worker's `BLOB`
binding is attached by `wrangler deploy`, which runs with the
`workers-deploy` token (Workers Scripts and KV Storage). Whether Cloudflare
accepts an R2 binding on a script uploaded with that token is unverified
live; if it does not, the first `web` deploy fails, and the fix is the
platform's `workers-deploy` template (blob-starter and commerce carry the
same risk). Nothing in this repository can fix it.

## AC-M — Row-level security on every table in public (RESOLVED in AC5)

Supabase's Data API serves `public` to the anon key. Migration
`030_row_level_security` enables RLS with no policy on all seven tables,
after a guard that refuses if `postgres` (Hyperdrive's role) neither owns
them nor bypasses RLS. tests/db fails on any table left without it; the e2e
shows `anon` and `authenticated` read none of the rows a guest's chat wrote.
Unverified live: that the Management API runs migrations as `postgres`, so
that it owns the tables (the guard stops the migration if not).

## AC-N — The session key before the database answers (SETTLED)

Auth.js (next-auth v5) is initialised lazily, its config resolved per
request, so `secret` can be the database's key. `proxy.ts` decodes the
session BEFORE any route runs and needs the key too: it reads it the same
way, over the same Hyperdrive binding (OpenNext runs the proxy inside the
Worker), once per isolate. `/ping` and `/api/health` answer before that read,
so a database outage still shows on the health route rather than as a
redirect loop. Separately, the proxy and the guest route now pick the
session cookie's name the way Auth.js does (`__Secure-` over https only):
upstream's `!isDevelopmentEnvironment` disagreed with Auth.js for the built
Worker served over http (`wrangler dev`), where every page redirected back
to the guest sign-in.

## AC-O — A prerender/resume mismatch is logged on `/` (ACCEPTED, upstream)

Served by the built Worker, the first `GET /` logs "Expected the resume to
render <h> in this slot but instead it rendered <h2>… React will fallback
to client rendering". It is not AC5's: a build of `main` at AC4 logs the same
line under `wrangler dev`. The page answers 200 and renders on the client;
it is Next 16's `cacheComponents` shell resumed under OpenNext, left for an
upstream or OpenNext release rather than worked around in the template.
