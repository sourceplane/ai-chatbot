# ai-chatbot — implementation plan

Milestones land in order; each task is one pull request on an
`orun/AC-n-<slug>` branch with an `Orun-Task: AC-n` trailer.

## AC0 — the spec

This doc set, `epic.yaml` and the task contracts, merged to `main`.

**Done when**
- the five documents and `epic.yaml` are on `main`
- `tasks/AC-1..AC-5.TaskContract.yaml` exist

## AC1 — the chatbot on Workers

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

## AC2 — the schema through db-migrate

`packages/db` (`@saas/db`) carries the control migration and
`010_initial/up.sql`, the template's SQL verbatim; `tests/db` checks the
manifest's checksums and the offline plan; `infra/db-migrate` applies the
migrations per environment after the Supabase project exists.

**Done when**
- `pnpm --filter @saas/db run manifest:check` passes
- `node packages/db/dist/runner/cli.js plan --env stage` lists both migrations as pending offline
- `tests/db` is green

## AC3 — Supabase, Hyperdrive and R2 from Terraform

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

## AC4 — ready to instantiate

README (run locally with a Postgres, test, preview, deploy through Orun,
the Worker secrets, attachments on R2, the model gateway),
`IMPLEMENTATION-STATUS.md` with PRs and every departure, epic `completed`.

**Done when**
- the README quick start works from a fresh clone
- the status file lists every PR and departure

## Sequencing note

AC1 is verified without a database: the Worker boots and every route
answers with its own error when Postgres is unreachable. AC2 and AC3 are
independent files but both need a workspace with Supabase and Cloudflare
connections to apply; until the product is linked the Orun lane is gated
and `Checks` is the merge gate. AC4 is documentation over all of them.
