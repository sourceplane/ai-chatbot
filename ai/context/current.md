# ai-chatbot — where this repository stands

The entry page for anyone (or any agent) picking this repository up. It is
this repository's own state and does not ship to a chatbot built from it; the
two pages that do are [operations.md](operations.md) and
[deployment.md](deployment.md).

## What it is

Vercel's Next.js AI Chatbot on Cloudflare Workers + Static Assets (through
`@opennextjs/cloudflare`): a Supabase Postgres reached through Hyperdrive,
attachments in R2, and Workers AI as the default model provider. It is
packaged as an Orun baseline: `orun new --blueprint repo-blueprint.yaml`
builds a new chatbot in its own repository and takes it to live on stage and
prod in one landing (`01-product`: Supabase, then Hyperdrive, then the
migrations, then the app, with the R2 bucket beside them), then records what
went live (`02-docs`).

## Release

| | |
|---|---|
| Latest tag | `baseline-v2` (AC6 — the cirrus standard, [#7](https://github.com/sourceplane/ai-chatbot/pull/7) and [#8](https://github.com/sourceplane/ai-chatbot/pull/8): no kiox, generated component docs, this context pack, and the workers.dev subdomain read from the Cloudflare connection instead of asked) |
| Before it | `baseline-v1` (AC5, [#6](https://github.com/sourceplane/ai-chatbot/pull/6)) |
| Proven live | No. Everything short of the platform is proven offline in Baseline CI: the e2e tier builds the product in orun's staged job tree, migrates a local Postgres with its own runner and serves the Worker over local R2 with a stand-in AI binding. No bootstrap from a tag has run against a workspace yet: the three applies, db-migrate against a real project, a real deploy, Workers AI itself (AC-K) and the `BLOB` binding under the deploy token (AC-L) are unproven |

## Where to read

| Question | Page |
|---|---|
| What shipped, and every departure from upstream | `specs/epics/ai-chatbot/IMPLEMENTATION-STATUS.md` |
| Why it is built this way | [decisions.md](decisions.md), then `specs/epics/ai-chatbot/design.md` (passages AC5 superseded are marked) |
| What could still go wrong | [open-risks.md](open-risks.md), then `specs/epics/ai-chatbot/risks-and-open-questions.md` |
| How to instantiate it | `BOOTSTRAP.md`, `docs/phases/` |
| What each component is | `<component>/docs/` beside each `component.yaml` — `apps/web`, `packages/db`, `infra/db-migrate`, `infra/terraform/{supabase,cloudflare-hyperdrive,cloudflare-r2}`, `tests/{web,db}` (generated; `python3 tooling/catalog/gen-component-docs.py`) |

## Next

1. Bootstrap one chatbot from `baseline-v2` against a workspace with
   Cloudflare and Supabase connected, and record its timings: the first
   proof of the applies, the deploy, Workers AI's models and tools (AC-K)
   and the R2 binding under the deploy token (AC-L).
