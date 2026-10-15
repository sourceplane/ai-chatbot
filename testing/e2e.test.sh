#!/usr/bin/env bash
# TIER 2 — the product a bootstrap produces builds, migrates, deploys (dry),
# serves, signs a guest in and chats, with no model key and no AUTH_SECRET.
#
# placement.test.sh proves the tree a bootstrap ends with is the right tree,
# and that its own plan converges in the right order. This proves it WORKS,
# by doing to it what its own pipelines will:
#
#   1. at the 01-product landing (the commit its PR merges), run what
#      `checks.yml` runs on that PR — install with the lockfile the phase
#      placed, render the wrangler fixture (which must change nothing: the
#      render is committed), typecheck, lint, test, build. That landing WAITS
#      on its checks;
#   2. a Postgres of its own on a random port, with Supabase's roles — the
#      database a Supabase project would be: `postgres` a login role WITHOUT
#      superuser or BYPASSRLS, `anon` and `authenticated` with the Data API's
#      default grants (testing/lib/local-postgres.sh) — and a stand-in for the
#      ONE Supabase Management API endpoint the migration runner calls
#      (testing/lib/fake-supabase-api.py), connected as `postgres`;
#   3. the db-migrate lane's own steps, rendered by `orun plan` for a push to
#      main and run IN THE TREE THE RUNNER STAGES for the job: install, build
#      @saas/db, apply — every migration, the session key the database
#      generates for itself and row-level security on every table in `public`
#      included — then apply again, which must apply nothing, and the
#      pull-request profile's offline plan;
#   4. the web lane's own steps for stage, rendered for a pull request (the
#      verify profile carries deploy-dry-run; the deploy profile does not) and
#      run in its staged job tree: install, `verify-app-structure` (the
#      committed wrangler.jsonc must exist BEFORE the build, in a tree with no
#      build output), `build-app` — which re-renders the config from the two
#      stage wiring documents it is handed (Hyperdrive's and R2's), as the
#      deploy does — then `verify-build-output` and `deploy-dry-run`;
#   5. the built Worker under `wrangler dev`, its HYPERDRIVE binding pointed at
#      that Postgres, its BLOB bucket wrangler's local R2, with NO .dev.vars —
#      no model key, no AUTH_SECRET — and the component's OWN `smokeCommand`
#      against it, verbatim; then every route the product promises and its
#      real flow: a visitor is signed in as a guest (the session encrypted
#      with the key the database generated), sends a message to the app's own
#      chat route and gets a streamed answer, the chat is titled, persisted
#      and listed in the history, an image is uploaded to R2 and read back,
#      and a visitor registers and signs in;
#   6. the Data API's view of the same database: every table in `public` has
#      row-level security, and `anon` and `authenticated` — granted everything
#      Supabase grants them — read none of the rows the flow wrote and can
#      write none, while the app, as the tables' owner and nothing more, just
#      did both.
#
# WORKERS AI CANNOT BE CALLED OFFLINE. In step 5 the Worker's `AI` binding —
# the one thing in its wrangler config this test changes — is a service
# binding to a deterministic stand-in (testing/lib/fake-ai/), run in the same
# `wrangler dev` session, that answers `run()` the way Workers AI's binding
# does: a JSON body, or a server-sent-event stream, of canned text naming the
# model it was asked for. So this proves the app's half — the route, the
# provider, the model it picks, the stream, the title, the persistence — and
# NOT that a real Workers AI model answers, calls tools or honours structured
# output; that is verified only by a live deployment.
#
# What it cannot do either is the platform's half: create the repository,
# mint the brokered tokens, create a real Supabase project, Hyperdrive config
# and R2 bucket (Terraform is validated, not applied, in this repository),
# deploy for real and probe workers.dev. That is a bootstrap against a
# workspace (BOOTSTRAP.md); everything short of it is here.
#
# Needs: orun, node, pnpm, python3 (+PyYAML), git, curl, psql and a
# PostgreSQL server install (initdb, pg_ctl), and the network for
# `pnpm install` (or a warm store). A few minutes: three installs, two builds.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
# shellcheck source=lib/bootstrap.sh
source "$here/lib/bootstrap.sh"
# shellcheck source=lib/local-postgres.sh
source "$here/lib/local-postgres.sh"

for bin in orun node pnpm python3 git curl psql; do
  command -v "$bin" >/dev/null || { echo "e2e.test.sh needs $bin on PATH" >&2; exit 1; }
done
pg_bin >/dev/null || { echo "e2e.test.sh needs a PostgreSQL server install (initdb, pg_ctl)" >&2; exit 1; }

scratch="$(mktemp -d)"
pgdir="$(mktemp -d)"
dev_pid=""
api_pid=""
# wrangler dev runs under pnpm, node and two workerd processes; a TERM to the
# first does not reach the rest, and waiting on it then never returns. So each
# server is started as its own process group (setsid) and the group stopped.
stop_group() {
  local pid="$1"
  [ -n "$pid" ] || return 0
  kill -TERM -- "-$pid" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 -- "-$pid" 2>/dev/null || break; sleep 0.5; done
  kill -KILL -- "-$pid" 2>/dev/null || true
}
cleanup() {
  stop_group "$dev_pid"
  stop_group "$api_pid"
  pg_down "$pgdir"
  [ -n "$pgdir" ] && [ -d "$pgdir" ] && rm -rf "$pgdir"
  [ -n "$scratch" ] && [ -d "$scratch" ] && rm -rf "$scratch"
}
trap cleanup EXIT
free_port() { python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()"; }
values="$here/fixtures/acme.json"
repo="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['reponame'])" "$values")"
export CI=1 WRANGLER_SEND_METRICS=false NEXT_TELEMETRY_DISABLED=1 TURBO_TELEMETRY_DISABLED=1

# What checks.yml runs, step for step, read out of the workflow the product
# carries so the two cannot drift: every `run:` of its one job, in order.
checks() { # DIR LOG
  local dir="$1" log="$2" cmd
  while IFS= read -r cmd; do
    echo "   \$ $cmd" | tee -a "$log"
    if ! (cd "$dir" && bash -c "$cmd") >> "$log" 2>&1; then
      echo "FAIL: \`$cmd\` failed in $dir" >&2; tail -40 "$log" >&2; return 1
    fi
  done < <(python3 - "$dir/.github/workflows/checks.yml" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
for job in wf["jobs"].values():
    for step in job["steps"]:
        if "run" in step:
            print(step["run"].strip())
PY
)
}

# One job of a plan, written out as the runner would run it: each `run:` step
# (the `use:` actions are setup-node and setup-pnpm, which this machine has)
# as a numbered script, the job's env, and the component path the steps run
# in. Steps are picked BY ID when given, else every `run:` step in order.
extract_job() { # PLAN JOB-ID OUT-DIR [STEP-ID…]
  python3 - "$@" <<'PY'
import json, pathlib, sys
plan, jid, out, *want = sys.argv[1:]
job = next((j for j in json.load(open(plan))["jobs"] if j["id"] == jid), None)
if job is None:
    sys.exit(f"the plan has no job {jid}")
out = pathlib.Path(out); out.mkdir(parents=True)
steps = [s for s in job["steps"] if s.get("run")]
if want:
    by = {s["id"]: s for s in steps}
    missing = [w for w in want if w not in by]
    if missing:
        sys.exit(f"{jid} has no step(s) {missing}")
    steps = [by[w] for w in want]
for i, s in enumerate(steps):
    (out / f"{i:02d}.sh").write_text(s["run"])
    (out / f"{i:02d}.id").write_text(s["id"])
(out / "path").write_text(job.get("path") or ".")
with (out / "env").open("w") as f:
    for k, v in (job.get("env") or {}).items():
        f.write(f"export {k}={json.dumps(v)}\n")
PY
}
run_job() { # STEPS-DIR WORK-TREE ENV LOG-PREFIX
  local steps="$1" work="$2" envname="$3" logp="$4" s id
  for s in "$steps"/[0-9][0-9].sh; do
    id="$(cat "${s%.sh}.id")"
    echo "   ▸ $id"
    if ! (cd "$work/$(cat "$steps/path")" && source "$steps/env" && export ORUN_ENVIRONMENT="$envname" \
          && bash -e "$s") > "$logp-$id.log" 2>&1; then
      echo "FAIL: the lane's $id step" >&2; tail -40 "$logp-$id.log" >&2; return 1
    fi
  done
}

echo "── the offline bootstrap (testing/lib/bootstrap.sh)"
tree="$scratch/$repo"
bootstrap_offline "$root" "$tree" "$values" "$scratch/logs" > "$scratch/bootstrap.log" 2>&1 || {
  echo "FAIL: the offline bootstrap stopped" >&2; tail -40 "$scratch/bootstrap.log" >&2; exit 1; }
echo "   2 phases placed and landed"

# ── 1. the product's own pull request ──────────────────────────────────────
echo "── 01-product's landing, under the checks its PR waits on"
s01="$(git -C "$tree" rev-parse HEAD~1)"
at01="$scratch/at-01/$repo"
git -C "$tree" worktree add -q "$at01" "$s01"
checks "$at01" "$scratch/checks.log"
dirty="$(git -C "$at01" status --porcelain)"
[ -z "$dirty" ] || { echo "FAIL: the checks changed tracked files — the committed wrangler.jsonc is not the fixture render:" >&2; echo "$dirty" >&2; exit 1; }
echo "   the checks left the tree as committed (wire:fixture rendered the committed wrangler.jsonc)"

# ── 2. a database, and the one API the migration runner calls ──────────────
echo "── a local Postgres and the Supabase Management API stand-in"
pgurl="$(pg_up "$pgdir" "$(free_port)")" || { echo "FAIL: Postgres did not start" >&2; exit 1; }
api_port="$(free_port)"
ref="localproject"
setsid python3 "$here/lib/fake-supabase-api.py" "$api_port" "$pgurl" --ref "$ref" > "$scratch/api.log" 2>&1 < /dev/null &
api_pid=$!
for _ in $(seq 1 30); do curl -s -o /dev/null "http://127.0.0.1:$api_port/" && break; sleep 0.3; done
echo "   $pgurl; the API on :$api_port"

# The two plans the lanes below run from, each in the product's own tree: a
# push to main at the 01-product commit (the db-migrate lane's APPLY profile),
# and a pull request over the finished product against an empty base (the web
# lane's VERIFY profile, which carries deploy-dry-run, and db-migrate's PLAN).
(cd "$at01" && orun plan --intent intent.yaml --trigger github-push-main --env stage --output "$scratch/plan-main.json") > "$scratch/plan-main.log" 2>&1 \
  || { echo "FAIL: orun plan (push to main)" >&2; tail -15 "$scratch/plan-main.log" >&2; exit 1; }
git -C "$tree" worktree remove --force "$at01"
mkdir -p "$scratch/pr"
git clone -q "$tree" "$scratch/pr/$repo"
prtree="$scratch/pr/$repo"
git -C "$prtree" checkout -q --orphan empty
git -C "$prtree" rm -rqf .
git -C "$prtree" -c user.email=t@example.invalid -c user.name=t commit -qm empty --allow-empty
git -C "$prtree" checkout -q main
(cd "$prtree" && orun plan --intent intent.yaml --trigger github-pull-request --base empty --head HEAD --env stage \
   --output "$scratch/plan-pr.json") > "$scratch/plan-pr.log" 2>&1 \
  || { echo "FAIL: orun plan (pull request)" >&2; tail -15 "$scratch/plan-pr.log" >&2; exit 1; }
# This tier runs the orun the product's CI pins, which reads the per-edge
# `modeRules`: on a pull request — which applies and deploys nothing — the
# infrastructure edges that order a push to main are advisory, so no lane
# waits on another. (placement.test.sh checks the push to main's order.)
python3 - "$scratch/plan-pr.json" <<'PY'
import json, sys
jobs = {j["component"]: j for j in json.load(open(sys.argv[1]))["jobs"] if j["environment"] == "stage"}
chain = ["supabase", "cloudflare-hyperdrive", "db-migrate", "web"]
for a, b in list(zip(chain, chain[1:])) + [("cloudflare-r2", "web")]:
    ja, jb = jobs[a], jobs[b]
    if ja["id"] in (jb.get("dependsOn") or []) or ja["id"] not in (jb.get("advisoryDependsOn") or []):
        sys.exit(f"FAIL: on a pull request {b}@stage must name {a}@stage as advisory, not wait on it")
print("   pull request: " + " → ".join(chain) + " and cloudflare-r2 → web, every edge advisory")
PY

# ── 3. the db-migrate lane, in its staged job tree ─────────────────────────
echo "── the stage db-migrate lane: install, build @saas/db, apply — then apply again, and the PR's plan"
extract_job "$scratch/plan-main.json" db-migrate.stage.migrate "$scratch/steps-migrate" \
  install-dependencies build-db-package "Migration Apply"
extract_job "$scratch/plan-main.json" db-migrate.stage.migrate "$scratch/steps-migrate-again" "Migration Apply"
extract_job "$scratch/plan-pr.json" db-migrate.stage.migrate "$scratch/steps-migrate-plan" "Migration Plan"
# Staged from the fresh clone (a CI checkout: no build output, no
# node_modules); its migrations are the 01-product commit's, byte for byte.
mwork="$prtree/.orun/runs/e2e/db-migrate.stage.migrate/work"
python3 "$here/lib/stage-job.py" "$prtree" "$mwork"
# The component's secretEnv, as the lane resolves it: the supabase apply's
# published credentials and the brokered access token. SUPABASE_API_URL is
# the one value no lane has — it points the runner at the stand-in.
export SUPABASE_ACCESS_TOKEN=e2e-token SUPABASE_PROJECT_REF="$ref" SUPABASE_DB_PASSWORD=postgres \
       SUPABASE_DB_URL="$pgurl" SUPABASE_API_URL="http://127.0.0.1:$api_port"
run_job "$scratch/steps-migrate" "$mwork" stage "$scratch/migrate"
applied() { python3 -c "import json,sys;t=open(sys.argv[1]).read();print(' '.join(json.loads(t[t.index('{'):t.rindex('}')+1])['applied']))" "$1"; }
want="000_control_baseline 010_initial 020_app_secrets 030_row_level_security"
[ "$(applied "$scratch/migrate-Migration Apply.log")" = "$want" ] \
  || { echo "FAIL: the first apply applied '$(applied "$scratch/migrate-Migration Apply.log")', not '$want'" >&2; exit 1; }
echo "   applied $want"
run_job "$scratch/steps-migrate-again" "$mwork" stage "$scratch/migrate-again"
[ -z "$(applied "$scratch/migrate-again-Migration Apply.log")" ] \
  || { echo "FAIL: a second apply applied '$(applied "$scratch/migrate-again-Migration Apply.log")'" >&2; exit 1; }
echo "   a second apply applied nothing (the ledger holds $(psql "$pgurl" -XAtc 'select count(*) from _migrations.applied') migrations)"
key_len="$(psql "$pgurl" -XAtc "select length(value) from app_private.secrets where name = 'auth_secret'")"
[ "$key_len" = 64 ] || { echo "FAIL: the database generated no 64-character session key (got '$key_len')" >&2; exit 1; }
echo "   the database generated its own session key (64 hex characters)"
run_job "$scratch/steps-migrate-plan" "$mwork" stage "$scratch/migrate-plan"
[ "$(applied "$scratch/migrate-plan-Migration Plan.log")" = "$want" ] \
  || { echo "FAIL: the pull request's offline plan did not verify every migration" >&2; exit 1; }
echo "   the pull request's plan step verifies every migration's checksum offline"
unset SUPABASE_ACCESS_TOKEN SUPABASE_PROJECT_REF SUPABASE_DB_PASSWORD SUPABASE_DB_URL SUPABASE_API_URL
rm -rf "$mwork"

# ── 4. the web lane's steps, for stage ─────────────────────────────────────
echo "── the stage web lane: install, verify-app-structure, build-app, verify-build-output, deploy-dry-run"
extract_job "$scratch/plan-pr.json" web.stage.verify-deploy "$scratch/steps-web" \
  install-workspace-dependencies verify-app-structure build-app verify-build-output deploy-dry-run
work="$prtree/.orun/runs/e2e/web.stage.verify-deploy/work"
# The job's private tree, staged as orun stages it — no build output, no
# node_modules: under stack-tectonic 0.19.0 the job installs inside it.
python3 "$here/lib/stage-job.py" "$prtree" "$work"
[ ! -e "$work/apps/web/.open-next" ] && [ -f "$work/apps/web/wrangler.jsonc" ] \
  || { echo "FAIL: the staged tree is not a fresh checkout with the committed wrangler.jsonc" >&2; exit 1; }
echo "   staged: $(realpath --relative-to="$prtree" "$work") — no build output, the committed wrangler.jsonc"
# The two stage wiring documents, as the cloudflare-hyperdrive and
# cloudflare-r2 applies publish them and the lane resolves them (secretEnv
# WIRING_CLOUDFLARE_HYPERDRIVE_STAGE, WIRING_CLOUDFLARE_R2_STAGE).
hd_id="e2e0000000000000000000000000c0de"
bucket="stg-$repo-stage-e2e"
export WIRING_CLOUDFLARE_HYPERDRIVE_STAGE="{\"hyperdrive_id\":\"$hd_id\",\"hyperdrive_name\":\"stg-$repo-stage\"}"
export WIRING_CLOUDFLARE_R2_STAGE="{\"r2_bucket_name\":\"$bucket\"}"
run_job "$scratch/steps-web" "$work" stage "$scratch/web"
unset WIRING_CLOUDFLARE_HYPERDRIVE_STAGE WIRING_CLOUDFLARE_R2_STAGE
build_log="$(ls "$scratch"/web-build-app.log)"
grep -q '(Turbopack)' "$build_log" \
  || { echo "FAIL: the staged build did not run on Turbopack" >&2; grep -m3 'Next.js' "$build_log" >&2; exit 1; }
grep -q "\"id\": \"$hd_id\"" "$work/apps/web/wrangler.jsonc" && grep -q "\"bucket_name\": \"$bucket\"" "$work/apps/web/wrangler.jsonc" \
  || { echo "FAIL: build-app did not re-render wrangler.jsonc from the stage wiring documents" >&2; exit 1; }
[ "$(node -e 'const fs=require("fs");process.stdout.write(String(fs.readdirSync(process.argv[1]).length))' "$work/node_modules")" -gt 0 ] && [ ! -L "$work/node_modules" ] \
  || { echo "FAIL: the job's install did not land inside its own tree" >&2; exit 1; }
echo "   the staged build ran on Turbopack, inside its own tree, bound to the stage Hyperdrive id and bucket it was handed"

# ── 5. serve it with no model key and no AUTH_SECRET ───────────────────────
echo "── wrangler dev over the built Worker: HYPERDRIVE on the local Postgres, BLOB on local R2, AI on the stand-in"
[ ! -e "$work/apps/web/.dev.vars" ] || { echo "FAIL: the staged tree carries a .dev.vars" >&2; exit 1; }
# The ONE change to the config the lane built with: the AI binding becomes a
# service binding to the Workers AI stand-in. Everything else is the stage
# render build-app wrote.
python3 - "$work/apps/web/wrangler.jsonc" "$work/apps/web/wrangler.e2e.jsonc" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
swapped, n = re.subn(r'"ai":\s*\{\s*"binding":\s*"AI"\s*\}',
                     '"services": [{ "binding": "AI", "service": "fake-workers-ai", "entrypoint": "FakeAI" }]', text)
if n != 1:
    sys.exit("FAIL: the built config does not bind Workers AI as `\"ai\": { \"binding\": \"AI\" }`")
open(sys.argv[2], "w").write(swapped)
PY
cp -r "$here/lib/fake-ai" "$scratch/fake-ai"
port="$(free_port)"
(cd "$work/apps/web" && CLOUDFLARE_HYPERDRIVE_LOCAL_CONNECTION_STRING_HYPERDRIVE="$pgurl" \
   exec setsid pnpm exec wrangler dev -c wrangler.e2e.jsonc -c "$scratch/fake-ai/wrangler.jsonc" \
   --ip 127.0.0.1 --port "$port" --persist-to "$scratch/wrangler-state" \
   --show-interactive-dev-session=false) > "$scratch/dev.log" 2>&1 < /dev/null &
dev_pid=$!
url="http://127.0.0.1:$port"
for _ in $(seq 1 120); do
  curl -s -o /dev/null "$url/ping" && break
  kill -0 "$dev_pid" 2>/dev/null || { echo "FAIL: wrangler dev exited" >&2; tail -30 "$scratch/dev.log" >&2; exit 1; }
  sleep 1
done
curl -s -o /dev/null "$url/ping" || { echo "FAIL: wrangler dev never answered" >&2; tail -30 "$scratch/dev.log" >&2; exit 1; }

echo "   ▸ the component's own smokeCommand, DEPLOYED_URL=$url"
smoke="$(python3 -c "import yaml,sys;print(yaml.safe_load(open(sys.argv[1]))['spec']['parameters']['smokeCommand'])" "$tree/apps/web/component.yaml")"
DEPLOYED_URL="$url" bash -c "$smoke" || { echo "FAIL: the deploy's smoke refused the product" >&2; tail -20 "$scratch/dev.log" >&2; exit 1; }

echo "   ▸ every route the product promises, a guest's chat, an attachment, a registration"
python3 - "$url" "$values" "$pgurl" "$work/apps/web" "$scratch" <<'PY' || { echo "FAIL: the routes; wrangler dev said:" >&2; tail -60 "$scratch/dev.log" >&2; exit 1; }
import html, http.client, json, re, struct, subprocess, sys, time, urllib.error, urllib.parse
import urllib.request, uuid, zlib
base, values, pgurl, app, scratch = sys.argv[1], json.load(open(sys.argv[2])), sys.argv[3], sys.argv[4], sys.argv[5]
name = values["productname"]
problems = []
def bad(m): problems.append(m)

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k): return None
opener = urllib.request.build_opener(NoRedirect)

def req(path, data=None, headers=None, method=None, cookies=None):
    """(status, headers as a Message, body bytes). A GET whose CONNECTION
    drops (not one that answers an error) is asked again, twice at most, and
    says so: `wrangler dev` on a loaded machine has dropped one. A POST is
    never repeated — it would submit twice."""
    h = dict(headers or {})
    if cookies:
        h["cookie"] = "; ".join(f"{k}={v}" for k, v in cookies.items())
    for attempt in range(3):
        r = urllib.request.Request(path if path.startswith("http") else base + path,
                                   data=data, headers=h, method=method)
        try:
            with opener.open(r, timeout=120) as resp:
                return resp.status, resp.headers, resp.read()
        except urllib.error.HTTPError as e:
            return e.code, e.headers, e.read()
        except (http.client.RemoteDisconnected, ConnectionResetError) as e:
            if data is not None or attempt == 2:
                raise
            print(f"   (GET {path}: the connection dropped ({e.__class__.__name__}) — asking again)")
            time.sleep(1)

def set_cookies(h):
    out = {}
    for line in h.get_all("set-cookie") or []:
        k, _, v = line.split(";", 1)[0].partition("=")
        out[k.strip()] = v
    return out

def location(h):
    return urllib.parse.urlparse(h.get("location", "")).path

def psql(sql):
    return subprocess.run(["psql", pgurl, "-XAtc", sql], capture_output=True, text=True, check=True).stdout.strip()

SESSION = re.compile(r"^(__Secure-)?authjs\.session-token$")
def session_of(cookies):
    return next(((k, v) for k, v in cookies.items() if SESSION.match(k)), (None, None))

# ── what only the Worker answers, with no session ─────────────────────────
s, _, body = req("/ping")
if s != 200 or body.decode().strip() != "pong":
    bad(f"/ping answered {s} {body[:40]!r}")
s, _, body = req("/api/health")
health = json.loads(body) if s == 200 else {}
if s != 200 or health.get("ok") is not True or health.get("schema") != "migrated" \
        or (health.get("models") or {}).get("default") != "@cf/moonshotai/kimi-k2.6" \
        or (health.get("models") or {}).get("gateway") != "not connected":
    bad(f"/api/health answered {s} {body[:200]!r}")

# ── a visitor with no session is signed in as a guest ─────────────────────
s, h, _ = req("/")
if s != 307 or not h.get("location", "").endswith("/api/auth/guest?redirectUrl=%2F"):
    bad(f"/ with no session answered {s} → {h.get('location')}, not the guest sign-in")
s, h, _ = req("/api/auth/guest?redirectUrl=%2F")
jar = set_cookies(h)
cookie_name, token = session_of(jar)
if s not in (302, 303, 307) or location(h) != "/" or not token:
    bad(f"the guest sign-in answered {s} → {h.get('location')} with cookies {sorted(jar)}")
    token = None
guest_jar = {cookie_name: token} if token else {}
guest_id = None
if token:
    # The session is encrypted with the key the database generated for
    # itself: Auth.js's own decode, run in the app's tree, opens it with that
    # key — and AUTH_SECRET is set nowhere.
    key = psql("select value from app_private.secrets where name = 'auth_secret'")
    script = ("import { decode } from 'next-auth/jwt';"
              "const [token, secret, salt] = process.argv.slice(1);"
              "const t = await decode({ token, secret, salt });"
              "process.stdout.write(JSON.stringify(t));")
    out = subprocess.run(["node", "--input-type=module", "-e", script, token, key, cookie_name],
                         cwd=app, capture_output=True, text=True)
    try:
        claims = json.loads(out.stdout)
    except ValueError:
        claims = {}
        bad(f"the guest's session does not open with the database's key: {out.stderr.strip()[:200]}")
    if claims and not re.match(r"^guest-\d+$", claims.get("email") or ""):
        bad(f"the guest's session carries {claims!r}")
    guest_id = claims.get("id")

# ── the pages, signed in, under the product's own name ────────────────────
s, _, page = req("/", cookies=guest_jar)
page = page.decode()
title = re.search(r"<title>(.*?)</title>", page, re.S)
if s != 200 or not title or html.unescape(title.group(1)) != name:
    bad(f"/ signed in answered {s} with <title> {title and title.group(1)!r}, not {name!r}")
if ">Chatbot<" in page:
    bad("the home page still carries the baseline's name")
# Absolute metadata URLs — the Open Graph and Twitter images — are on the
# product's own origin: this stage build's workers.dev URL, baked in by the
# lane's build command (no SITE_URL set). Not upstream's demo, not Vercel's.
origin = f"https://{values['reponame']}-web-stage.{values['subdomain']}.workers.dev"
metas = re.findall(r'<meta\s+(?:property|name)="((?:og|twitter):[a-z:_]+)"\s+content="([^"]*)"', page)
absolute = [(k, html.unescape(v)) for k, v in metas if re.match(r"https?://", html.unescape(v))]
if not any(k in ("og:image", "twitter:image") for k, _ in absolute):
    bad(f"/ carries no absolute og:image or twitter:image to check: {metas[:6]}")
for k, v in absolute:
    if not v.startswith(origin + "/"):
        bad(f"/'s {k} is {v!r}, not on the product's origin {origin}")
if re.search(r"vercel\.(ai|app|com)|Deploy with Vercel", page, re.I):
    bad("the served page links to Vercel (a demo origin or a deploy-to-Vercel call to action)")
for path, want in (("/login", 200), ("/register", 200), ("/no-such-page", 404),
                   ("/api/chat/00000000-0000-4000-8000-000000000000/stream", 204)):
    s, _, _ = req(path, cookies=guest_jar)
    if s != want:
        bad(f"{path} signed in as a guest answered {s}, want {want}")

# ── the model picker offers only what can answer: Workers AI ──────────────
s, _, body = req("/api/models", cookies=guest_jar)
models = json.loads(body) if s == 200 else {}
ids = [m["id"] for m in models.get("available") or []]
if s != 200 or not ids or not all(i.startswith("@cf/") for i in ids) or "@cf/moonshotai/kimi-k2.6" not in ids:
    bad(f"/api/models answered {s} with {ids} — without a gateway key only Workers AI's models are available")

# ── an attachment, into R2 and back ───────────────────────────────────────
def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(b"\x00\xff\x00\x00")) + chunk(b"IEND", b""))
boundary = uuid.uuid4().hex
form = (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="dot.png"\r\n'
        f"Content-Type: image/png\r\n\r\n").encode() + png + f"\r\n--{boundary}--\r\n".encode()
s, _, body = req("/api/files/upload", form, {"content-type": f"multipart/form-data; boundary={boundary}"},
                 "POST", cookies=guest_jar)
uploaded = json.loads(body) if s == 200 else {}
if s != 200 or uploaded.get("contentType") != "image/png" or "/api/files/" not in uploaded.get("url", ""):
    bad(f"the upload answered {s} {body[:200]!r}")
else:
    path = urllib.parse.urlparse(uploaded["url"]).path
    s, h, back = req(path)  # public by URL, as Vercel Blob's were: no cookie
    if s != 200 or back != png or h.get("content-type") != "image/png":
        bad(f"reading the attachment back answered {s} {h.get('content-type')} ({len(back)} bytes)")
    s, h, _ = req(path + "?download=1")
    if s != 200 or "attachment" not in (h.get("content-disposition") or ""):
        bad(f"the attachment's download link answered {s} {h.get('content-disposition')}")
s, _, _ = req("/api/files/upload", form, {"content-type": f"multipart/form-data; boundary={boundary}"}, "POST")
if s != 307:
    bad(f"an upload with no session answered {s}, not the guest redirect")

# ── a message to the app's own chat route, answered as a stream ───────────
def chat(chat_id, text, model):
    payload = {"id": chat_id,
               "message": {"id": str(uuid.uuid4()), "parts": [{"text": text, "type": "text"}], "role": "user"},
               "selectedChatModel": model, "selectedVisibilityType": "private"}
    s, h, body = req("/api/chat", json.dumps(payload).encode(), {"content-type": "application/json"},
                     "POST", cookies=guest_jar)
    events = []
    for line in body.decode().splitlines():
        if line.startswith("data: ") and line[6:].strip() not in ("", "[DONE]"):
            try:
                events.append(json.loads(line[6:]))
            except ValueError:
                pass
    text_out = "".join(e.get("delta", "") for e in events if e.get("type") == "text-delta")
    return s, h, events, text_out

chat_id = str(uuid.uuid4())
s, h, events, answer = chat(chat_id, "Hello there — who are you?", "@cf/moonshotai/kimi-k2.6")
deltas = [e for e in events if e.get("type") == "text-delta"]
if s != 200 or "text/event-stream" not in (h.get("content-type") or ""):
    bad(f"the chat route answered {s} {h.get('content-type')}")
if answer != "Canned answer from @cf/moonshotai/kimi-k2.6: the stand-in for Workers AI streamed this." or len(deltas) < 3:
    bad(f"the chat streamed {len(deltas)} delta(s): {answer!r}")
titles = [e.get("data") for e in events if e.get("type") == "data-chat-title"]
if titles != ["Canned title from glm-4.7-flash"]:
    bad(f"the chat was titled {titles} — the title comes from the fast Workers AI model")
if not any(e.get("type") == "finish" for e in events):
    bad("the chat stream never finished")

# A gateway model, asked for with no gateway key: answered by the default
# Workers AI model, never failed.
s, _, _, answer2 = chat(chat_id, "And again, with a model this deployment does not have.",
                        "xai/grok-4.1-fast-non-reasoning")
if s != 200 or not answer2.startswith("Canned answer from @cf/moonshotai/kimi-k2.6"):
    bad(f"a gateway model without its key answered {s} {answer2!r}, not the default Workers AI model")

# ── persisted, and listed in the history ──────────────────────────────────
for _ in range(20):
    rows = psql(f"""select role from "Message_v2" where "chatId" = '{chat_id}' order by "createdAt" """).split()
    if rows.count("assistant") >= 2:
        break
    time.sleep(0.5)
if rows != ["user", "assistant", "user", "assistant"]:
    bad(f"the chat's messages in the database are {rows}")
stored = psql(f"""select parts::text from "Message_v2" where "chatId" = '{chat_id}' and role = 'assistant' order by "createdAt" limit 1""")
if "Canned answer from @cf/moonshotai/kimi-k2.6" not in stored:
    bad(f"the assistant's answer was not persisted: {stored[:160]!r}")
owner, chat_title = (psql(f"""select "userId" || '|' || title from "Chat" where id = '{chat_id}'""") or "|").split("|", 1)
if guest_id and owner != guest_id:
    bad(f"the chat belongs to {owner!r}, not the guest {guest_id!r}")
if chat_title != "Canned title from glm-4.7-flash":
    bad(f"the chat's stored title is {chat_title!r}")
s, _, body = req("/api/history?limit=20", cookies=guest_jar)
history = json.loads(body) if s == 200 else {}
listed = [(c.get("id"), c.get("title")) for c in history.get("chats") or []]
if s != 200 or (chat_id, "Canned title from glm-4.7-flash") not in listed:
    bad(f"/api/history answered {s} listing {listed}")
s, _, _ = req(f"/chat/{chat_id}", cookies=guest_jar)
if s != 200:
    bad(f"/chat/<id> answered {s}")
s, _, body = req(f"/api/messages?chatId={chat_id}", cookies=guest_jar)
if s == 200 and b"Canned answer" not in body:
    bad("/api/messages does not return the stored answer")

# ── a visitor registers, and signs in again ───────────────────────────────
# Both forms submit a server action (`register`, `login`), as React's client
# does: a multipart body with the action's arguments — the previous state,
# then the form's fields, prefixed `_1_` — to the page, with its action id,
# read from the build's own manifest.
manifest = json.load(open(f"{app}/.next/server/server-reference-manifest.json"))
def action_id(export):
    hits = [k for k, v in manifest["node"].items()
            if v.get("exportedName") == export and v.get("filename", "").endswith("app/(auth)/actions.ts")]
    if len(hits) != 1:
        raise SystemExit(f"FAIL: no single `{export}` action in the build's manifest ({hits})")
    return hits[0]
def act(path, export, fields, jar):
    b = uuid.uuid4().hex
    parts = {"0": json.dumps([{"status": "idle"}, "$K1"]), **{f"_1_{k}": v for k, v in fields.items()}}
    body = "".join(f'--{b}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'
                   for k, v in parts.items()) + f"--{b}--\r\n"
    s, h, out = req(path, body.encode(), {"content-type": f"multipart/form-data; boundary={b}",
                                          "next-action": action_id(export), "accept": "text/x-component",
                                          "origin": base}, "POST", cookies=jar)
    status = re.findall(r'"status":"([a-z_]+)"', out.decode(errors="replace"))
    return s, set_cookies(h), status[0] if status else None

email, password = "sam@answers.example", "correct horse battery"
s, jar, status = act("/register", "register", {"email": email, "password": password}, guest_jar)
_, reg_token = session_of(jar)
if s != 200 or status != "success" or not reg_token:
    bad(f"registering answered {s} with status {status!r} and cookies {sorted(jar)}")
else:
    hashed = psql(f"""select password from "User" where email = '{email}'""")
    if not hashed.startswith("$2"):
        bad("the registered user has no bcrypt hash")
    # A registered (not guest) session: the proxy sends it away from /login.
    s, h, _ = req("/login", cookies={session_of(jar)[0]: reg_token})
    if s != 307 or location(h) != "/":
        bad(f"/login with the new user's session answered {s} → {h.get('location')}, not → /")
s, jar, status = act("/register", "register", {"email": email, "password": password}, guest_jar)
if status != "user_exists":
    bad(f"registering the same address again answered {status!r}, not user_exists")
s, jar, status = act("/login", "login", {"email": email, "password": "not the password"}, guest_jar)
if status != "failed" or session_of(jar)[1]:
    bad(f"a wrong password answered {status!r}")
s, jar, status = act("/login", "login", {"email": email, "password": password}, guest_jar)
if status != "success" or not session_of(jar)[1]:
    bad(f"signing in answered {s} with status {status!r}")

if problems:
    for p in problems:
        print(f"  ✕ {p}", file=sys.stderr)
    sys.exit(1)
print(f"   /ping, /api/health; a guest signed in with the database's own key; /, /login, /register, "
      f"a 404, the history, the models (Workers AI only), an attachment in R2 and back; a chat "
      f"streamed through the AI binding in {len(deltas)} deltas, titled, persisted and listed, a "
      f"gateway model answered by Workers AI; a registration and a sign-in — as {name!r}")
PY

# ── 6. what Supabase's Data API would see ──────────────────────────────────
echo "── the Data API's roles (anon, authenticated) against the same database"
psql "$pgurl" -X -q -v ON_ERROR_STOP=1 -At > "$scratch/rls.out" 2> "$scratch/rls.err" <<'SQL' \
  || { echo "FAIL: the row-level security checks" >&2; cat "$scratch/rls.err" >&2; exit 1; }
SELECT 'app role: superuser=' || rolsuper || ' bypassrls=' || rolbypassrls FROM pg_roles WHERE rolname = current_user;
SELECT 'public tables without RLS: ' || count(*) FILTER (WHERE NOT c.relrowsecurity) || ' of ' || count(*)
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p');
SELECT 'not owned by the app: ' || count(*) FILTER (WHERE pg_get_userbyid(c.relowner) <> current_user)
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p');
SELECT 'app sees users: ' || count(*) FROM "User";
SELECT 'app sees chats: ' || count(*) FROM "Chat";
SELECT 'app sees messages: ' || count(*) FROM "Message_v2";
SET ROLE anon;
SELECT 'anon sees users: ' || count(*) FROM "User";
SELECT 'anon sees chats: ' || count(*) FROM "Chat";
SELECT 'anon sees messages: ' || count(*) FROM "Message_v2";
RESET ROLE;
SET ROLE authenticated;
SELECT 'authenticated sees users: ' || count(*) FROM "User";
SELECT 'authenticated sees chats: ' || count(*) FROM "Chat";
SELECT 'authenticated sees messages: ' || count(*) FROM "Message_v2";
RESET ROLE;
SQL
sed 's/^/   /' "$scratch/rls.out"
grep -qx "app role: superuser=false bypassrls=false" "$scratch/rls.out" \
  && grep -qE "^public tables without RLS: 0 of [1-9][0-9]*$" "$scratch/rls.out" \
  && grep -qx "not owned by the app: 0" "$scratch/rls.out" \
  || { echo "FAIL: the app's role, the tables' owner or their row-level security is not what Supabase's would be" >&2; exit 1; }
for what in users chats messages; do
  n="$(sed -n "s/^app sees $what: //p" "$scratch/rls.out")"
  [ "${n:-0}" -ge 1 ] || { echo "FAIL: the flow wrote no $what the app can see" >&2; exit 1; }
  for role in anon authenticated; do
    grep -qx "$role sees $what: 0" "$scratch/rls.out" || { echo "FAIL: expected '$role sees $what: 0'" >&2; exit 1; }
  done
done
# A write through the Data API's role is refused by row-level security, and
# app_private (the session key) is not theirs to read at all.
for role in anon authenticated; do
  if psql "$pgurl" -X -q -At -c "SET ROLE $role; INSERT INTO \"User\" (email, password) VALUES ('$role@example.invalid', 'x')" > "$scratch/rls-write.log" 2>&1; then
    echo "FAIL: $role wrote a user through row-level security" >&2; exit 1
  fi
  grep -q "row-level security" "$scratch/rls-write.log" \
    || { echo "FAIL: $role's write was refused for another reason:" >&2; cat "$scratch/rls-write.log" >&2; exit 1; }
  if psql "$pgurl" -X -q -At -c "SET ROLE $role; SELECT value FROM app_private.secrets" > "$scratch/rls-secret.log" 2>&1; then
    echo "FAIL: $role read app_private.secrets" >&2; exit 1
  fi
  grep -q "permission denied" "$scratch/rls-secret.log" \
    || { echo "FAIL: $role's read of app_private was refused for another reason" >&2; cat "$scratch/rls-secret.log" >&2; exit 1; }
done
echo "   anon and authenticated, granted what Supabase grants them, read 0 users, chats and messages and write none; app_private is closed to them"

echo "e2e.test.sh: ok"
