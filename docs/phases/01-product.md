# 01-product — the product, in one landing

The whole product lands as ONE pull request, and ONE convergence on main
provisions and deploys it on stage and prod: the Supabase project, the
Hyperdrive config over its database, the migrations, the R2 bucket and the
chatbot — infra before app, per environment.

**Places** every module `repo-blueprint.yaml` declares: the root manifests,
CI, tooling and identity; `infra/terraform/supabase`,
`infra/terraform/cloudflare-hyperdrive`, `infra/terraform/cloudflare-r2` and
`infra/db-migrate`; `packages/db` (the migrations and their runner);
`apps/web`; and `tests/web`, `tests/db`. `testing/phases.test.sh` holds the
set.

**Requires** three live connections, probed and waited for (up to ten
minutes, so a consent can be clicked while it waits): the GitHub App on the
account that OWNS the repository — the platform sees a PR only through that
installation — and Cloudflare and Supabase, which every credential below is
minted from. The Supabase organisation needs room for two projects (stage
and prod; the free plan's limit).

## How one convergence keeps the order

| what has to come first | how the plan holds it |
|---|---|
| the Supabase project before Hyperdrive | `cloudflare-hyperdrive` reads `SUPABASE_PROJECT_REF` and `SUPABASE_DB_PASSWORD`, which the `supabase` apply lease-publishes, and declares `dependsOn: supabase`, `mode: enforced` on main. A job resolves its secrets when it STARTS, so the values are there |
| the migrations after the project — and after Hyperdrive | `db-migrate` reads the project's three credentials and declares `dependsOn` on `supabase` and `cloudflare-hyperdrive`, enforced on main. Nothing in it needs Hyperdrive: a migration is the one step a re-run cannot take back, so it runs only once everything else the app needs exists, right before the app |
| the bucket before the app | `web` binds the bucket by name (`WIRING_CLOUDFLARE_R2_<ENV>`, rendered into `wrangler.jsonc`) and declares `dependsOn: cloudflare-r2`, enforced on main. The bucket depends on nothing, so it applies beside the Supabase chain |
| the app last | `web` binds the Hyperdrive id (`WIRING_CLOUDFLARE_HYPERDRIVE_<ENV>`) and queries the migrated schema, so it declares `dependsOn` on `cloudflare-hyperdrive` and `db-migrate` too, enforced on main |
| stage before prod | deferred during the bootstrap (below), so both environments run their chains side by side |

Every one of these edges is **advisory on a pull request**, which applies and
deploys nothing. `testing/placement.test.sh` plans the placed product's own
push to main and reads the order off it:
`supabase → cloudflare-hyperdrive → db-migrate → web`, and
`cloudflare-r2 → web`.

## What runs

| hook | what it does |
|---|---|
| `task` (pre) | finds the phase's task and yields its key |
| `retouch` | one trailing `# orun: redeploy 01-product <stamp>` line in each component `.baseline/tasks/01-product.TaskContract.yaml` names (supabase, cloudflare-hyperdrive, cloudflare-r2, db, db-migrate, web), so a RE-RUN has a diff to land |
| `git-init`, `stage` | the tree becomes a git repository with a populated index (the rebrand enumerates `git ls-files`) |
| `rebrand` | renames the baseline's identity to the product's: the slug (intent, worker, secret project, the `repo` the Supabase project, Hyperdrive config and bucket are named after), the name seam, the domain, the workers.dev subdomain. The upstream template's repository link and every migration are left alone |
| `orun-workspace` | writes the product's workspace into `intent.yaml` |
| `work-tree` | strips this repository's `work:` block from the product's intent |
| `promotion`, `dev-lanes` | defer prod's wait on stage and dev's push lanes until `02-docs` |
| `restage`, `rebrand-verify` | the sweep: no baseline identity left |
| `pnpm-lockfile` | confirms the complete lockfile `root-pnpm-lock` placed |
| `repo` | `orun.repo/ensure@v1`: creates (or finds) `<githuborg>/<reponame>` |
| `link` | the repository becomes the workspace's (`orun cloud link`, best effort; `orun cloud check` is the gate). Every convergence lane authenticates over GitHub OIDC through that link |
| `secret-*` | six `orun.integrations/reconcile@v1` hooks, one key and one scope each: `CLOUDFLARE_API_TOKEN` (workers-deploy), `CLOUDFLARE_HYPERDRIVE_TOKEN` (hyperdrive-edit), `CLOUDFLARE_R2_TOKEN` (r2-data), `CLOUDFLARE_ACCOUNT_ID` (account-id), `SUPABASE_ACCESS_TOKEN` (management-access), `SUPABASE_ORG_ID` (org-id). Keys that exist are kept |
| `land` | one PR, checked (Checks, and `plan` alone on a bootstrap branch), then merged |
| `converge` (await) | `orun.run/watch@v1` on the merge commit's run; resumes it up to three times |
| `wiring` (await) | `orun.secrets/exists@v1`: `SUPABASE_PROJECT_REF`, `SUPABASE_DB_PASSWORD`, `SUPABASE_DB_URL`, `WIRING_CLOUDFLARE_HYPERDRIVE` and `WIRING_CLOUDFLARE_R2` on stage and prod |
| `verify` (await) | `orun.http/probe@v1`: `/ping` and `/api/health` on both workers.dev URLs. Not `/`: every page sends a visitor with no session to the guest sign-in (a redirect), and the probe wants a 200 |

## What the convergence does, per environment

1. **supabase** — `terraform apply`: one project, `<reponame>-<env>`, in the
   org `SUPABASE_ORG_ID` names, with a generated database password. Its
   outputs are lease-published as `SUPABASE_PROJECT_REF`,
   `SUPABASE_DB_PASSWORD` and `SUPABASE_DB_URL`. A new project takes five to
   seven minutes to come up.
2. **cloudflare-hyperdrive** — `terraform apply` with the Hyperdrive token: a
   config over the project's Postgres, published as
   `WIRING_CLOUDFLARE_HYPERDRIVE` (its id and name).
3. **cloudflare-r2** — `terraform apply` with the R2 token (`r2-data`): one
   bucket, published as `WIRING_CLOUDFLARE_R2` (its name). Beside steps 1–2;
   it waits on nothing.
4. **db-migrate** — builds `@saas/db` and applies every migration the
   database's `_migrations.applied` ledger does not have, through Supabase's
   Management API: the template's schema, `app_private.secrets` with the
   session key the environment generates for itself, and row-level security
   on every table in `public` — closed to Supabase's Data API, open to the
   app, which owns them.
5. **web** — installs, re-renders `wrangler.jsonc` from this environment's
   two wiring documents, builds with OpenNext, deploys `<reponame>-web-<env>`
   with its `HYPERDRIVE`, `BLOB` (R2) and `AI` bindings, and smoke-tests it:
   `/ping`, and `/api/health`, which answers only when the database behind
   the binding is reachable and migrated.

No model key is in it: the models are Workers AI through the Worker's `AI`
binding. The AI Gateway's models turn on when the owner adds its key (the
product's README, "Models").

**An open platform risk.** The deploy step binds the bucket with the
`workers-deploy` token, which is scoped to Workers Scripts and KV. Whether
Cloudflare lets that token attach an R2 binding to a Worker is unverified
live; if it does not, the `web` deploy fails with an authentication error
naming R2, and the fix belongs to the platform's `workers-deploy` template,
not to this tree.

## Verify / done means

- The convergence for the merge commit is green on stage and prod.
- The five published secrets exist on stage and prod.
- `/ping` and `/api/health` answer on both workers.dev URLs.

## Failure modes

| symptom | meaning → fix |
|---|---|
| parks on the `providers` probe | a connection is missing — GitHub on the repository's owner, Cloudflare, or Supabase. Connect it (console → Integrations); the probe is a wait, not a failure |
| supabase apply: project limit reached | the organisation already has two active projects (the free plan's limit). Pause or delete one, or upgrade, then re-run the phase |
| supabase apply: `does not support oauth access` | the provider is above 1.5.x, which reads billing endpoints an OAuth token cannot — `~> 1.5.1` is pinned for this reason |
| supabase apply: project name already exists | `adopt.tf` looks the project up by name and imports it — if you removed that file, restore it |
| hyperdrive or db-migrate lane: secret resolution failed (`SUPABASE_*`) | the supabase apply for that environment did not publish — read its log; both wait on it, so they show as not run |
| hyperdrive apply: Authentication error (10000) | the token in play is workers-deploy, which deliberately cannot touch Hyperdrive — the component binds `CLOUDFLARE_HYPERDRIVE_TOKEN` |
| r2 apply: Authentication error (10000) | the component binds `CLOUDFLARE_R2_TOKEN` (r2-data); check the `secret-r2-data` hook minted it |
| web deploy: an authentication error naming R2 or a bucket | the open risk above: the `workers-deploy` token could not attach the `BLOB` binding |
| db-migrate: checksum mismatch | an applied migration's file changed. Never edit one; add a new migration |
| db-migrate: `row-level security would lock the app out of …` | migration 030's guard: the tables in `public` are not owned by `postgres` (the role Hyperdrive connects as), and `postgres` has neither SUPERUSER nor BYPASSRLS. Nothing was enabled and the app did not deploy. Give `postgres` the tables (`ALTER TABLE … OWNER TO postgres`) or BYPASSRLS, then re-run the phase |
| web smoke: `/api/health` 503 | the database is unreachable through the binding (`database: unreachable`) or not migrated (`schema: missing`) — the Hyperdrive and db-migrate lanes for that environment say which |
| `build-app` fails: `Symlink apps/web/node_modules/next is invalid, it points out of the filesystem root` | the product's intent pins stack-tectonic ≥ 0.20.0 (lane-scoped install), which Next 16's Turbopack refuses. Pin 0.19.0 — `intent.yaml` says why |
| `verify-app-structure` fails: `test -f wrangler.jsonc` | `apps/web/wrangler.jsonc` is not committed. It must be: the check runs before the build, in a fresh checkout (`pnpm run wire:fixture` renders it) |
| the watch says green, the probe says 404 | another workflow ran on the push and the watch took its run. Only `ci.yml` may run on a push to main |
| re-run lands nothing | the hooks did not run (`--run-hooks`), or the contract names no component — `node tooling/bootstrap/retouch.mjs --check --affects .baseline/tasks/01-product.TaskContract.yaml` in the product's tree says which |

## Re-running

Idempotent: placement is additive, the rebrand is a no-op on branded files,
`git init` and the repo step are guarded, the Supabase project, the
Hyperdrive config and the bucket are adopted rather than recreated, and the
migration ledger lives in the database, so only missing migrations apply. A
re-run of a phase whose PR already merged lands the retouch markers alone,
which re-plans exactly the components they name. Once the tree is branded
the phase derives as `drifted`, so `--resume` leaves it alone; re-run it
deliberately with `--phase 01-product` (or `--redo 01-product`).

## What one convergence will run, before running it

From a placed product's tree:

```bash
node <baseline>/tooling/bootstrap/promotion.mjs --defer && node <baseline>/tooling/bootstrap/dev-lanes.mjs --defer
orun plan --intent intent.yaml --trigger github-push-main -v lanes
git checkout intent.yaml
```
