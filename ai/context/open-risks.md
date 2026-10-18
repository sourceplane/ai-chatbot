# ai-chatbot — open risks

What is not yet proven or not yet decided. The full write-up of every risk,
including the accepted and resolved ones, is
`specs/epics/ai-chatbot/risks-and-open-questions.md`; this page lists only
what is still live, so it should be short.

| ID | Risk | State | What closes it |
|---|---|---|---|
| AC-K | Workers AI is the default but cannot be called offline: that Kimi K2.6 and GLM 4.7 Flash are served on the account, that their tool calls drive the artifact tools, and that the suggestions tool's structured output is honoured are unproven (the e2e uses a stand-in binding) | OPEN | A live bootstrap that chats, titles and edits an artifact |
| AC-L | The Worker's `BLOB` R2 binding is attached by `wrangler deploy` under the `workers-deploy` token; whether Cloudflare accepts it is unverified, and the fix would be the platform's token template | OPEN (platform) | The first live `web` deploy |

Not yet exercised live either, though resolved offline: that the Management
API runs migrations as `postgres`, so it owns the tables (AC-M; the guard
stops the migration if not). Accepted, and worth knowing before you change
them: AC-C (static-assets cache), AC-D (no Redis), AC-G (no BotID), AC-I
(bcrypt at module load), AC-O (a prerender/resume mismatch logged on `/`).
