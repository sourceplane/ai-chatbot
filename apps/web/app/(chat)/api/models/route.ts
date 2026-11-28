import { getAvailableModels, getCapabilities } from "@/lib/ai/models";

// What the model picker shows: `available` is exactly what this deployment
// can run — the Workers AI models always, Hugging Face's only with HF_TOKEN
// and Cloudflare AI Gateway's only with AI_GATEWAY_ID — and `capabilities`
// says what each supports.
export async function GET() {
  const headers = {
    // Per deployment, and it changes when a setting is added: short-lived.
    "Cache-Control": "public, max-age=300, s-maxage=300",
  };

  return Response.json(
    { available: getAvailableModels(), capabilities: await getCapabilities() },
    { headers }
  );
}
