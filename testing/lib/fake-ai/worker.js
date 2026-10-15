// A DETERMINISTIC STAND-IN FOR WORKERS AI, for testing/e2e.test.sh only.
//
// The product's chat, titles and artifact tools call Workers AI through the
// Worker's `AI` binding (apps/web/lib/ai/providers.ts, via
// workers-ai-provider): `env.AI.run(model, inputs, options)`, answered with a
// JSON body or — when `inputs.stream` is true — a server-sent-event stream of
// `data: {"response": "<delta>"}` events ending in `data: [DONE]`. Workers AI
// has no local mode and cannot be called offline, so under `wrangler dev` the
// e2e points the `AI` binding at this Worker instead (a service binding to its
// `FakeAI` entrypoint, an RPC method with the binding's own shape), and it
// answers every call with canned text that names the model it was asked for.
// What that proves is the app's half — the route, the provider, the stream,
// the persistence — not that a real model answers: that is only verified live.
import { WorkerEntrypoint } from "cloudflare:workers";

const calls = [];

function sse(text) {
  const enc = new TextEncoder();
  // A few words per event, as a model streams them.
  const words = text.split(/(?<= )/);
  return new ReadableStream({
    start(controller) {
      for (const w of words) {
        controller.enqueue(enc.encode(`data: ${JSON.stringify({ response: w })}\n\n`));
      }
      controller.enqueue(
        enc.encode(`data: ${JSON.stringify({ response: "", usage: { prompt_tokens: 7, completion_tokens: words.length, total_tokens: 7 + words.length } })}\n\n`),
      );
      controller.enqueue(enc.encode("data: [DONE]\n\n"));
      controller.close();
    },
  });
}

export class FakeAI extends WorkerEntrypoint {
  async run(model, inputs) {
    const tools = Array.isArray(inputs?.tools) ? inputs.tools.map((t) => t?.function?.name).filter(Boolean) : [];
    calls.push({ model, stream: Boolean(inputs?.stream), tools });
    const short = String(model).split("/").pop();
    if (inputs?.stream) {
      return sse(`Canned answer from ${model}: the stand-in for Workers AI streamed this.`);
    }
    return {
      response: `Canned title from ${short}`,
      usage: { prompt_tokens: 7, completion_tokens: 4, total_tokens: 11 },
    };
  }
}

export default {
  // What the stand-in was asked, for the e2e to read back (it is reachable
  // only through the app's service binding, so this is for debugging).
  fetch() {
    return Response.json(calls);
  },
};
