#!/usr/bin/env bash
# Render the product's LIVE-DEPLOYMENT documentation from verified state.
# Called by phase 02-docs as a `run:` hook (and safe to run by hand, from the
# product's checkout). Idempotent: the generated file and the README section
# are fully re-rendered on every run, so re-running after a redeploy, a custom
# domain or connecting the AI Gateway refreshes them.
#
#   hooks/render-deployment-docs.sh <out> <workspace> <baseline-dir>
#
# What it writes (in <out>):
#   ai/context/deployment.md   — REGENERATED: URLs with live probe results
#                                (the Worker, its database check, which model
#                                provider serves), identity, secrets
#                                inventory BY NAME, integrations
#   ai/context/operations.md   — healed from the baseline's copy if absent
#                                (the static operating contract; never rewritten)
#   README.md                  — the section between <!-- 02-docs:begin/end -->
#                                is replaced (appended after the title if the
#                                README predates the markers)
#
# No secret VALUE is ever read or written here — inventories are names only.
set -euo pipefail

out="${1:?usage: render-deployment-docs.sh <out> <workspace> <baseline-dir>}"
ws="${2:-}"
L="${3:?usage: render-deployment-docs.sh <out> <workspace> <baseline-dir>}"

cd "$out"
vals=".rebrand/values.json"
[ -f "$vals" ] || { echo "render-docs: $vals missing — is this a bootstrapped product?" >&2; exit 1; }
val() { python3 -c "import json,sys;print(json.load(open('$vals')).get(sys.argv[1],'') or '')" "$1"; }

repo="$(val reponame)"
brand="$(val brandSlug)"; [ -n "$brand" ] || brand="$repo"
sub="$(val subdomain)"; [ -n "$sub" ] || sub="your-workers-subdomain"
[ -n "$ws" ] || ws="$(sed -n 's/^[[:space:]]*workspace:[[:space:]]*\([^[:space:]#]*\).*/\1/p' intent.yaml | head -1)"
[ -n "$ws" ] || ws="?"

# Workspace slug via the direct backend read; tolerate failure.
slug="$( { orun workspace "$ws" 2>/dev/null || true; } | sed -n 's/^ *slug: *//p' | head -1)"
[ -n "$slug" ] || slug="?"

# CI lane pin (what version the deploy lanes run).
lanepin="$(sed -n 's/^ *version: *\(v[0-9.]*\) *$/\1/p' .github/workflows/ci.yml 2>/dev/null | head -1)"
[ -n "$lanepin" ] || lanepin="?"

# curl emits the -w format even on connection failure (000) — capture, don't
# append, or a failed probe reads "000000".
probe() { local c; c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$1" 2>/dev/null)" || true; printf '%s' "${c:-000}"; }
badge() { case "$1" in 2*|3*) echo "LIVE ($1)" ;; 000) echo "unreachable" ;; *) echo "answering $1" ;; esac; }

stage_url="https://${brand}-web-stage.${sub}.workers.dev"
prod_url="https://${brand}-web-prod.${sub}.workers.dev"

# Which model provider serves: /api/health names the default Workers AI
# model and whether the AI Gateway's key is set (a yes/no, never the key).
# Read only from an answer that is 200: anything else says nothing about it.
models_state() {
  local page code
  page="$(mktemp)"
  code="$(curl -s -o "$page" -w '%{http_code}' --max-time 20 "$1/api/health" 2>/dev/null)" || true
  code="${code:-000}"
  if [ "$code" != 200 ]; then echo "unknown (/api/health $(badge "$code")) | unknown"
  else python3 -c "
import json,sys
m=(json.load(open(sys.argv[1])).get('models') or {})
print('Workers AI, ' + str(m.get('default', '?')) + ' | ' + str(m.get('gateway', '?')))" "$page" 2>/dev/null || echo "unknown | unknown"
  fi
  rm -f "$page"
}

# The app row probes /ping: every page sends a visitor with no session to the
# guest sign-in (a redirect); /ping is the Worker's own answer.
rows=""
for pair in "stage|$stage_url" "prod|$prod_url"; do
  env="${pair%%|*}"; url="${pair#*|}"
  rows+="| app (${env}) | ${url} (probed at /ping) | $(badge "$(probe "$url/ping")") |"$'\n'
  rows+="| database check (${env}) | ${url}/api/health | $(badge "$(probe "$url/api/health")") |"$'\n'
done
models_stage="$(models_state "$stage_url")"; models_prod="$(models_state "$prod_url")"

secrets_list() { { orun secrets list --org "$ws" "$@" 2>/dev/null || true; } | awk 'NR>1 && NF {print "  - "$1}'; }
secrets_proj="$(secrets_list --project)"; [ -n "$secrets_proj" ] || secrets_proj="  - (listing unavailable to this credential)"
secrets_stage="$(secrets_list --env stage)"; [ -n "$secrets_stage" ] || secrets_stage="  - (listing unavailable to this credential)"
secrets_prod="$(secrets_list --env prod)"; [ -n "$secrets_prod" ] || secrets_prod="  - (listing unavailable to this credential)"
integrations="$( { orun integrations list --org "$ws" --json 2>/dev/null || true; } | python3 -c "
import json,sys
try: rows=json.load(sys.stdin)
except Exception: rows=[]
out=[f\"  - {r.get('provider','?')}: {r.get('status','?')}\" for r in rows]
print('\n'.join(out) if out else '  - (listing unavailable to this credential)')" )"

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Heal the static operating contract when the product predates it.
mkdir -p ai/context
if [ ! -f ai/context/operations.md ] && [ -f "$L/ai/context/operations.md" ]; then
  cp "$L/ai/context/operations.md" ai/context/operations.md
  git add ai/context/operations.md 2>/dev/null || true
  node "$L/tooling/rebrand/rebrand.mjs" --values "$vals" --allow-dirty >/dev/null 2>&1 || true
  echo "render-docs: healed ai/context/operations.md"
fi

cat > ai/context/deployment.md <<EOF
# ${repo} — live deployment manifest

> GENERATED by the \`02-docs\` phase on ${now}; re-run it to refresh
> (idempotent; see [operations.md](operations.md)). Hand-edits here are
> overwritten. No secret values appear in this file — inventories are names
> only.

## Identity

| | |
|---|---|
| repository / project slug | \`${repo}\` |
| Orun workspace | \`${ws}\` (slug \`${slug}\`) |
| declared in | \`intent.yaml\` → \`execution.state.workspace\` |
| Workers | \`${brand}-web-stage\`, \`${brand}-web-prod\` on \`${sub}.workers.dev\` |
| CI lane CLI pin | orun \`${lanepin}\` (\`.github/workflows/ci.yml\`) |

## Public URLs (probed ${now})

| surface | URL | status |
|---|---|---|
${rows}
\`/api/health\` answers 200 only when the Worker reaches the Supabase database
through its Hyperdrive binding and the migrations are applied. The \`dev\`
environment is verify-only by design — no deployed URL.

## Models

| environment | default model | AI Gateway |
|---|---|---|
| stage | ${models_stage} |
| prod | ${models_prod} |

The chat runs on Workers AI through the Worker's own \`AI\` binding — no key.
The AI Gateway is not a provider the platform brokers: its key is an optional
Worker secret the owner adds per environment (README, "Models"), which adds
the gateway's models to the picker.

## Secrets inventory (names only)

Project rung:
${secrets_proj}

Environment \`stage\`:
${secrets_stage}

Environment \`prod\`:
${secrets_prod}

Provider secrets are BROKERED (minted per run from the workspace's Cloudflare
and Supabase connections; no long-lived values at rest). The Supabase
project's ref, password and URL and the Hyperdrive and R2 wiring are
published by the Terraform applies onto the stage and prod rungs.

## Workspace integrations

${integrations}

## How this deployment changes

Merges to \`main\` converge automatically: CI plans the changed components and
runs each lane with \`orun run --remote-state\` against the workspace above.
See [operations.md](operations.md) for the full operating contract.
EOF
echo "render-docs: wrote ai/context/deployment.md"

python3 - <<'PY'
import re
begin, end = "<!-- 02-docs:begin -->", "<!-- 02-docs:end -->"
body = f"""{begin}
This product is **live**. Verified URLs, identity, which model provider serves
and the secrets inventory are recorded in
[ai/context/deployment.md](ai/context/deployment.md) (re-rendered by the
`02-docs` phase); how it deploys and how to operate it:
[ai/context/operations.md](ai/context/operations.md).
{end}"""
s = open("README.md").read()
if begin in s and end in s:
    s = re.sub(re.escape(begin) + r".*?" + re.escape(end), lambda _m: body, s, count=1, flags=re.S)
else:
    lines = s.splitlines(keepends=True)
    at = 1
    while at < len(lines) and lines[at].strip() == "":
        at += 1
    lines.insert(at, f"\n## Live deployment\n\n{body}\n")
    s = "".join(lines)
open("README.md", "w").write(s)
print("render-docs: README live-deployment section rendered")
PY
echo "render-docs: done"
