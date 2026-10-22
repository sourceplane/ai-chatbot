#!/usr/bin/env bash
# THE REBRAND WRITES EACH VALUE ONCE, AND WHAT IT WROTE STAYS WRITTEN.
#
# Drives the real tooling/rebrand/rebrand.mjs over one-file trees and compares
# the file. Each case is a shape this baseline's identity actually takes in the
# tree — the name seam, the worker name, the Worker's own origin, the
# placeholder domain, a secret ref, the `repo` the Supabase project, the
# Hyperdrive config and the bucket are named after — and each runs through as
# many passes as a bootstrap might make, so a value written once must survive
# every later pass unchanged. Two things must NOT be renamed although they
# spell the slug: the upstream template's repository link (`vercel/ai-chatbot`
# — its name is this baseline's slug), and a migration (its checksum is in the
# manifest and in every database it was applied to).
#
# The identity is PINNED (fixtures/baseline-identity.ai-chatbot.json) rather
# than read from .baseline/identity.json: what this tests is the engine, and
# its fixtures spell the identity out literally.
#
# Needs: node, git. No network.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
rebrand="$here/../tooling/rebrand/rebrand.mjs"
identity="$here/fixtures/baseline-identity.ai-chatbot.json"

fail=0
# check NAME VALUES-JSON FILE CONTENT WANT [PASSES]
check() {
  local name="$1" values="$2" file="$3" content="$4" want="$5" passes="${6:-1}"
  local tmp got out i
  tmp="$(mktemp -d)"
  git -C "$tmp" init -q
  mkdir -p "$tmp/$(dirname "$file")" "$tmp/.rebrand"
  printf '%s\n' "$content" > "$tmp/$file"
  printf '%s\n' "$values" > "$tmp/.rebrand/values.json"
  for ((i = 1; i <= passes; i++)); do
    git -C "$tmp" add -A
    if ! out="$(cd "$tmp" && node "$rebrand" --baseline-identity "$identity" --values .rebrand/values.json --allow-dirty 2>&1)"; then
      echo "   ✕  $name: rebrand pass $i failed:" >&2
      printf '%s\n' "$out" | sed 's/^/        /' >&2
      fail=1
      rm -rf "$tmp"
      return
    fi
  done
  got="$(cat "$tmp/$file")"
  rm -rf "$tmp"
  if [ "$got" = "$want" ]; then
    echo "   ok  $name"
  else
    echo "   ✕  $name:" >&2
    echo "        got:  $got" >&2
    echo "        want: $want" >&2
    fail=1
  fi
}

acme='{"reponame":"acme-chat","productname":"Acme Chat","productdomain":"acme.dev","githuborg":"acme-inc","subdomain":"acme","orunWorkspace":"ws_79BDXAZQ"}'

echo "── rebrand: the product's own identity"
check "the name seam takes the product's name" \
  "$acme" apps/web/lib/site.ts 'export const SITE_NAME = "Chatbot";' \
  'export const SITE_NAME = "Acme Chat";'
check "…and stays a valid string for a name with an apostrophe and an ampersand" \
  '{"reponame":"sams-chat","productname":"Sam'"'"'s Chat & Answers","productdomain":"sam.dev"}' \
  apps/web/lib/site.ts 'export const SITE_NAME = "Chatbot";' \
  'export const SITE_NAME = "Sam'"'"'s Chat & Answers";'
check "the display name elsewhere is content, and is left alone" \
  "$acme" apps/web/app/x.tsx '<p>Ask the Chatbot.</p>' \
  '<p>Ask the Chatbot.</p>'
check "the worker name is re-prefixed, the environment suffix kept" \
  "$acme" apps/web/component.yaml 'workerName: ai-chatbot-web' \
  'workerName: acme-chat-web'
check "the Worker's own wrangler name" \
  "$acme" apps/web/wrangler.template.jsonc '  "name": "ai-chatbot-web",' \
  '  "name": "acme-chat-web",'
check "the Worker's origin in the docs: worker name and subdomain" \
  "$acme" README.md 'https://ai-chatbot-web-stage.your-workers-subdomain.workers.dev/ping' \
  'https://acme-chat-web-stage.acme.workers.dev/ping'
check "the origin the build bakes into absolute metadata URLs: worker name and subdomain" \
  "$acme" apps/web/component.yaml 'NEXT_PUBLIC_SITE_URL="${SITE_URL:-https://ai-chatbot-web-${ORUN_ENVIRONMENT}.your-workers-subdomain.workers.dev}"' \
  'NEXT_PUBLIC_SITE_URL="${SITE_URL:-https://acme-chat-web-${ORUN_ENVIRONMENT}.acme.workers.dev}"'
check "the placeholder domain is the product's domain, not a renamed slug" \
  "$acme" intent.yaml '      BASE_DOMAIN: ai-chatbot.example.com' \
  '      BASE_DOMAIN: acme.dev'
check "no domain given: the reserved placeholder, for an owner to replace later" \
  '{"reponame":"acme-chat","productname":"Acme Chat","githuborg":"acme-inc","subdomain":"acme"}' \
  intent.yaml '      BASE_DOMAIN: ai-chatbot.example.com' \
  '      BASE_DOMAIN: acme-chat.example.com'
check "an empty domain is no domain" \
  '{"reponame":"acme-chat","productname":"Acme Chat","productdomain":""}' \
  intent.yaml '      BASE_DOMAIN: ai-chatbot.example.com' \
  '      BASE_DOMAIN: acme-chat.example.com'
check "the repo slug" \
  "$acme" package.json '  "name": "ai-chatbot",' \
  '  "name": "acme-chat",'
check "the repo Terraform names the Supabase project, Hyperdrive config and bucket after" \
  "$acme" intent.yaml '        repo: ai-chatbot' \
  '        repo: acme-chat'
check "the fixture's Hyperdrive name follows it" \
  "$acme" apps/web/wiring.fixture.json '    "hyperdrive_name": "stg-ai-chatbot-stage"' \
  '    "hyperdrive_name": "stg-acme-chat-stage"'
check "…and so does its bucket name" \
  "$acme" apps/web/wiring.fixture.json '    "r2_bucket_name": "prod-ai-chatbot-prod"' \
  '    "r2_bucket_name": "prod-acme-chat-prod"'
check "a secret ref names the product's workspace and project" \
  "$acme" infra/terraform/cloudflare-r2/component.yaml \
  '    CLOUDFLARE_API_TOKEN: "secret://ai-chatbot/ai-chatbot/{{ .environment }}/CLOUDFLARE_R2_TOKEN"' \
  '    CLOUDFLARE_API_TOKEN: "secret://ws_79BDXAZQ/acme-chat/{{ .environment }}/CLOUDFLARE_R2_TOKEN"'
check "this repository's source link names the product's owner and repository" \
  "$acme" README.md 'See https://github.com/sourceplane/ai-chatbot.' \
  'See https://github.com/acme-inc/acme-chat.'
check "org-owned identity is not renamed" \
  "$acme" intent.yaml 'apiVersion: sourceplane.io/v1 # mail ops@sourceplane.ai' \
  'apiVersion: sourceplane.io/v1 # mail ops@sourceplane.ai'

echo "── rebrand: what spells the slug and is not this baseline's"
check "the upstream template's repository is upstream's" \
  "$acme" README.md 'Vercel'"'"'s [Next.js AI Chatbot](https://github.com/vercel/ai-chatbot) — AI' \
  'Vercel'"'"'s [Next.js AI Chatbot](https://github.com/vercel/ai-chatbot) — AI'
check "…in the app's own README too" \
  "$acme" apps/web/README.md 'A chatbot from Vercel'"'"'s [Next.js AI Chatbot](https://github.com/vercel/ai-chatbot)' \
  'A chatbot from Vercel'"'"'s [Next.js AI Chatbot](https://github.com/vercel/ai-chatbot)'
check "a Workers AI model id is not an identity" \
  "$acme" apps/web/lib/ai/models.ts 'export const DEFAULT_CHAT_MODEL = "@cf/moonshotai/kimi-k2.6";' \
  'export const DEFAULT_CHAT_MODEL = "@cf/moonshotai/kimi-k2.6";'
check "a migration is never rewritten (its checksum is in the manifest)" \
  "$acme" packages/db/src/migrations/030_x/up.sql '-- ai-chatbot: a comment the checksum covers' \
  '-- ai-chatbot: a comment the checksum covers'
check "nor is its drizzle-kit twin" \
  "$acme" apps/web/lib/db/migrations/0002_x.sql '-- ai-chatbot: a comment the checksum covers' \
  '-- ai-chatbot: a comment the checksum covers'

echo "── rebrand: a written value is not rewritten, in any later pass"
contains='{"reponame":"ai-chatbot-2","productname":"Chatbot 2","productdomain":"ai-chatbot.example.com.au","githuborg":"sourceplane","subdomain":"your-workers-subdomain-2"}'
check "a repo slug containing the baseline's slug survives three passes" \
  "$contains" package.json '  "name": "ai-chatbot",' \
  '  "name": "ai-chatbot-2",' 3
check "a worker name built on it survives three passes" \
  "$contains" apps/web/component.yaml 'workerName: ai-chatbot-web' \
  'workerName: ai-chatbot-2-web' 3
check "a domain containing the baseline's domain survives three passes" \
  "$contains" intent.yaml 'BASE_DOMAIN: ai-chatbot.example.com' \
  'BASE_DOMAIN: ai-chatbot.example.com.au' 3
check "a subdomain containing the placeholder survives three passes" \
  "$contains" apps/web/component.yaml 'workersDevSubdomain: your-workers-subdomain' \
  'workersDevSubdomain: your-workers-subdomain-2' 3
check "a name containing the baseline's name survives three passes" \
  "$contains" apps/web/lib/site.ts 'export const SITE_NAME = "Chatbot";' \
  'export const SITE_NAME = "Chatbot 2";' 3

# --verify runs after every rebrand. Without the product's values it cannot
# tell the product's own identity from a leftover; with them it can. A real
# leftover must fail it either way.
verify() { # NAME VALUES FILE CONTENT WANT(pass|fail) [--values]
  local name="$1" values="$2" file="$3" content="$4" want="$5" withvalues="${6:-}" tmp got
  tmp="$(mktemp -d)"
  git -C "$tmp" init -q
  mkdir -p "$tmp/$(dirname "$file")" "$tmp/.rebrand"
  printf '%s\n' "$content" > "$tmp/$file"
  printf '%s\n' "$values" > "$tmp/.rebrand/values.json"
  git -C "$tmp" add -A
  if (cd "$tmp" && node "$rebrand" --baseline-identity "$identity" --verify ${withvalues:+--values .rebrand/values.json} >/dev/null 2>&1); then got=pass; else got=fail; fi
  rm -rf "$tmp"
  if [ "$got" = "$want" ]; then echo "   ok  $name"; else echo "   ✕  $name: --verify ${got}ed, want $want" >&2; fail=1; fi
}
echo "── rebrand --verify: the product's own identity is not residue"
verify "given the values, a slug containing the baseline's passes" \
  "$contains" package.json '"name": "ai-chatbot-2"' pass --values
verify "without them it cannot know, and fails" \
  "$contains" package.json '"name": "ai-chatbot-2"' fail
verify "given the values, a real leftover still fails" \
  "$acme" package.json '"name": "ai-chatbot"' fail --values
verify "a leftover worker name fails" \
  "$acme" apps/web/component.yaml 'workerName: ai-chatbot-web' fail --values
verify "a leftover code identifier fails (no rule renames it — so nothing may spell it)" \
  "$acme" apps/web/app/x.ts 'export class AiChatbot {}' fail --values
verify "the upstream template's repository link is not residue" \
  "$acme" README.md 'See https://github.com/vercel/ai-chatbot for upstream.' pass --values
verify "a clean product passes" \
  "$acme" package.json '"name": "acme-chat"' pass --values

echo "── rebrand: a residue it cannot rename fails the rebrand itself"
tmp="$(mktemp -d)"; git -C "$tmp" init -q; mkdir -p "$tmp/.rebrand" "$tmp/apps/web"
printf '%s\n' "$acme" > "$tmp/.rebrand/values.json"
printf 'const x = "AI_CHATBOT_TOKEN"\n' > "$tmp/apps/web/x.ts"
git -C "$tmp" add -A
if (cd "$tmp" && node "$rebrand" --baseline-identity "$identity" --values .rebrand/values.json --allow-dirty >/dev/null 2>&1); then
  echo "   ✕  an unrenamable env-var prefix passed the rebrand" >&2; fail=1
else
  echo "   ok  an unrenamable env-var prefix fails the rebrand, naming the file"
fi
rm -rf "$tmp"

[ "$fail" -eq 0 ] || exit 1
echo "rebrand.test.sh: ok"
