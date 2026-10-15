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

## AC-F — The model gateway from a Worker (ACCEPTED)

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

## AC-H — Worker secrets are set by hand (ACCEPTED)

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
