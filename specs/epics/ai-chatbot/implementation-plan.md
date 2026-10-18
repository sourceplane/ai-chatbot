# ai-chatbot — implementation plan

Milestones land in order; each task is one pull request on an
`orun/AC-n-<slug>` branch with an `Orun-Task: AC-n` trailer.

## AC0 — the spec ✅

This doc set, `epic.yaml` and the task contracts, merged to `main`.

**Done when**
- the five documents and `epic.yaml` are on `main`
- `tasks/AC-1..AC-5.TaskContract.yaml` exist

## AC1 — the chatbot on Workers ✅

`apps/web` is the upstream template with the Workers build around it and
the Vercel-only modules swapped: `getDb()` over the HYPERDRIVE binding, the
R2 attachment routes, `lib/geo.ts`, `lib/bot.ts`, an empty
`instrumentation.ts`, the Cloudflare Web Analytics component.
`wrangler.template.jsonc` + `wiring.fixture.json` render the config;
`tests/web` exercises the pure helpers, the two shims and the attachment
routes with a mocked session and a mocked R2 binding.

**Done when**
- `pnpm install && pnpm run wire:fixture && pnpm typecheck && pnpm lint && pnpm test && pnpm build` is green locally and in `Checks`
- `wrangler dev` over the built Worker with a `.dev.vars` boots: `/ping` answers `pong`, static assets serve, a cookie-less `/` is sent to `/api/auth/guest`, `GET /api/files/<missing>` is 404, and the guest route fails with a database error (no Postgres locally) rather than a crash
- the template's own linter (`ultracite check`) is what `pnpm lint` runs

## AC2 — the schema through db-migrate ✅

`packages/db` (`@saas/db`) carries the control migration and
`010_initial/up.sql`, the template's SQL verbatim; `tests/db` checks the
manifest's checksums and the offline plan; `infra/db-migrate` applies the
migrations per environment after the Supabase project exists.

**Done when**
- `pnpm --filter @saas/db run manifest:check` passes
- `node packages/db/dist/runner/cli.js plan --env stage` lists both migrations as pending offline
- `tests/db` is green

## AC3 — Supabase, Hyperdrive and R2 from Terraform ✅

`infra/terraform/supabase` provisions a project per environment and
publishes its secrets and wiring document; `cloudflare-hyperdrive` fronts
that project's Postgres and publishes `{hyperdrive_id, hyperdrive_name}`;
`cloudflare-r2` creates the attachments bucket and publishes
`{r2_bucket_name}`. The app component (AC1) and db-migrate (AC2) already
name those secrets; this is the half that makes the names true.

**Done when**
- `terraform init -backend=false && terraform validate` passes on the three roots
- the fixture's wiring keys match the template's tokens (`wire:fixture` renders)
- the component names in `dependsOn` and `secretEnv` match the roots' component names and `secretOutputs`

## AC4 — ready to instantiate ✅

README (run locally with a Postgres, test, preview, deploy through Orun,
the Worker secrets, attachments on R2, the model gateway),
`IMPLEMENTATION-STATUS.md` with PRs and every departure, epic `completed`.

**Done when**
- the README quick start works from a fresh clone
- the status file lists every PR and departure

## AC5 — a baseline (AC-6) ✅

The repository becomes an Orun baseline on the Lumen conventions, built the
way cirrus-baseline v22 builds a product: in ONE landing. `blueprint.yaml`
(the console card) and `repo-blueprint.yaml` (the build: `01-product` places
everything and lands one PR, `02-docs` is hook-only), `.baseline/` (identity,
task contracts, the product's README), the rebrand engine with the
`lib/site.ts` name seam, the bootstrap helpers, the deployment-record hook,
`ai/context/`, the `baseline.yml`/`tag.yml` workflows and `testing/`.

What a fresh, unattended build forces on the app:
- **Workers AI is the default model provider**, through an `AI` binding in
  the committed wrangler config (`workers-ai-provider` 4.0.0, which speaks AI
  SDK 7): the chat (Kimi K2.6), the titles and the artifact tools (GLM 4.7
  Flash for titles). The AI Gateway's models are offered only with
  `AI_GATEWAY_API_KEY`; the picker shows exactly what can answer.
- **The session key** is `AUTH_SECRET` or, unset, one the database generated
  (`020_app_secrets`, in `app_private`, which the Data API does not expose);
  the proxy and the guest route read it too.
- **Row-level security** on every table in `public` (`030`), no policy.
- `apps/web/wrangler.jsonc` committed as the fixture render; `/api/health`;
  the R2 root on its own `r2-data` key; infra-before-app edges enforced on
  main and advisory on pull requests.

**Done when**
- the contract, wiring, leak and placement tests pass, `orun new --status`
  reads the blueprint at v2.58.11, v2.78.4 and 2.79.0, and `orun work check`
  is clean
- the e2e tier builds the product in the staged job tree, migrates a local
  Postgres with the product's own runner, serves it under `wrangler dev` and
  signs a guest in, streams a chat answer through the (stand-in) AI binding,
  persists and lists it, round-trips an attachment through local R2,
  registers and signs a user in — and the Data API's roles read none of it

## AC6 — the cirrus standard (AC-7) ✅

Bring the baseline to cirrus-baseline's standard, with nothing about the
chatbot itself changing.

- **No kiox.** `kiox.yaml`/`kiox.lock` pinned an orun (v2.15.0) that nothing
  ran: every workflow installs orun itself through `orun-action` with its own
  `version:`. The files, their two modules and the rebrand's skip entry go.
- **Component docs.** `tooling/catalog/gen-component-docs.py` writes each of
  the eight components' `docs/overview.md`, `docs/architecture.md` and
  `docs/runbook.md` from what the component declares, as cirrus-baseline's
  do; the pages ship with the component. Baseline CI runs it with `--check`.
- **The context pack.** `ai/context/current.md`, `decisions.md` and
  `open-risks.md` beside the two pages a product ships with — this
  repository's own, so no module places them.
- **Status that agrees with the tags and the code.** AC5 is shipped and
  tagged; `design.md` marks what AC5 superseded (Workers AI by default, the
  optional `AUTH_SECRET`, the committed `wrangler.jsonc`).

**Done when**
- nothing outside this milestone's own record names kiox (`git grep -i
  kiox`), and the leak gate and the offline bootstrap pass without the two
  modules
- the docs check is green in Baseline CI
- this file, the status file and `epic.yaml` agree

## Sequencing note

AC1 is verified without a database: the Worker boots and every route
answers with its own error when Postgres is unreachable. AC2 and AC3 are
independent files but both need a workspace with Supabase and Cloudflare
connections to apply; until the product is linked the Orun lane is gated
and `Checks` is the merge gate. AC4 is documentation over all of them.
