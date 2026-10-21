# ai-chatbot — decisions

The choices that shape this repository, one line each, with where the full
reasoning lives. Superseded decisions stay listed, marked, so the history
reads in order.

| # | Decision | Why | Source |
|---|---|---|---|
| 1 | OpenNext on Workers + Static Assets, `next` pinned to 16.3.8 | The newest Next the adapter boots; the Worker serves SSR, streaming routes and `proxy.ts` | `specs/epics/ai-chatbot/design.md` §2, epic README |
| 2 | Supabase Postgres through Hyperdrive, one `postgres` client per `getDb()` call; the schema in `packages/db`, applied by db-migrate | A Workers socket cannot outlive its request; drizzle-kit stays for local databases | design.md §2, risk AC-A |
| 3 | Attachments in R2 behind `/api/files/<key>`, public by unguessable URL | As Vercel Blob's `access: "public"`: the model provider and `next/image` fetch without the cookie | design.md §2, risk AC-B |
| 4 | Static-assets incremental cache; no Redis (resumable streams and the IP rate limit off) | Nothing revalidates or is `"use cache"`; both Redis features are opt-in upstream | design.md §4, risks AC-C, AC-D |
| 5 | Workers AI through the `AI` binding is the default model provider (Kimi K2.6 chat, GLM 4.7 Flash titles); the AI Gateway's models only with `AI_GATEWAY_API_KEY`. *Supersedes "the gateway, unchanged" (AC1–AC4)* | The platform brokers no AI vendor: a fresh product must chat with nothing configured | IMPLEMENTATION-STATUS (AC5), risk AC-K |
| 6 | The session key is `AUTH_SECRET` if set, else one migration `020_app_secrets` generated into `app_private.secrets`. *Supersedes "Worker secrets set by hand" (AC-H)* | A bootstrap cannot set a Worker secret; `app_private` is not a schema the Data API exposes | IMPLEMENTATION-STATUS (AC5), risk AC-N |
| 7 | Row-level security with no policy on every table in `public` (`030_row_level_security`) | Supabase's Data API serves `public` to the anon key; the app owns the tables | risk AC-M |
| 8 | `apps/web/wrangler.jsonc` is committed as the fixture render; every lane re-renders it (stage/prod from wiring, dev from the fixture) | The lane's structure check needs it in a fresh checkout, before the build | IMPLEMENTATION-STATUS (AC5), `apps/web/component.yaml` |
| 9 | One landing (`01-product`) then the record (`02-docs`); infra before app enforced on main, advisory on a pull request; the R2 root on its own `r2-data` key | A landing has a fixed cost; the plan carries deploy order; the deploy token does not cover R2 | `repo-blueprint.yaml`, `epic.yaml` (AC5), risk AC-L |
| 10 | stack-tectonic 0.19.0, not 0.20.0 | 0.20.0 links each job's `node_modules` out of its tree, which Next 16's Turbopack refuses | `intent.yaml`, BOOTSTRAP.md |
| 11 | orun is pinned only where it runs (the `orun-action` `version:` in each workflow); no kiox | `kiox.yaml` pinned a version (v2.15.0) nothing ran | IMPLEMENTATION-STATUS (AC6) |
| 12 | Component docs are generated from the manifests and checked in CI | A hand-written copy of the dependency graph and bindings drifts silently | `tooling/catalog/gen-component-docs.py` |
| 13 | `subdomain` is read from the Cloudflare connection (`from: connection.cloudflare.workersSubdomain`), never asked | It belongs to the account like its id and has one right answer; a typed one could only be wrong, and showed up after deploy in the public origin, the smoke and the probes | `blueprint.yaml`, IMPLEMENTATION-STATUS (AC-8) |
