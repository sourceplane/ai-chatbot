import { generateText, streamText } from "ai";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// The model provider (lib/ai/models.ts, lib/ai/providers.ts). Workers AI,
// through the Worker's AI binding, is the default and needs no key; Cloudflare
// AI Gateway's models, on the same binding, are offered only with AI_GATEWAY_ID. The binding is a
// stand-in here — it records what it was asked and answers the way Workers
// AI's binding does: a JSON body, or a server-sent-event stream when the
// inputs ask for `stream: true`.
const run = vi.fn();
vi.mock("@opennextjs/cloudflare", () => ({
  getCloudflareContext: () => ({ env: { AI: { run } } }),
}));

function sse(chunks: string[]): ReadableStream<Uint8Array> {
  const enc = new TextEncoder();
  return new ReadableStream({
    start(controller) {
      for (const chunk of chunks) {
        controller.enqueue(enc.encode(`data: ${JSON.stringify({ response: chunk })}\n\n`));
      }
      controller.enqueue(enc.encode("data: [DONE]\n\n"));
      controller.close();
    },
  });
}

describe("the models a deployment offers (lib/ai/models.ts)", () => {
  beforeEach(() => {
    vi.resetModules();
    delete process.env.AI_GATEWAY_ID;
    delete process.env.HF_TOKEN;
  });
  afterEach(() => {
    delete process.env.AI_GATEWAY_ID;
    delete process.env.HF_TOKEN;
  });

  it("offers only Workers AI with no gateway named, the default among them", async () => {
    const models = await import("@/lib/ai/models");
    const ids = models.getAvailableModels().map((m) => m.id);
    expect(ids.every((id) => id.startsWith("@cf/"))).toBe(true);
    expect(ids).toContain(models.DEFAULT_CHAT_MODEL);
    expect(models.isAvailableModel("openai/gpt-5.4-mini")).toBe(false);
  });

  it("adds the gateway's models once a gateway is named", async () => {
    process.env.AI_GATEWAY_ID = "default";
    const models = await import("@/lib/ai/models");
    const ids = models.getAvailableModels().map((m) => m.id);
    expect(ids).toEqual(expect.arrayContaining(["@cf/moonshotai/kimi-k2.6", "openai/gpt-5.4-mini"]));
  });

  it("adds Hugging Face's models once HF_TOKEN is set, and only then", async () => {
    let models = await import("@/lib/ai/models");
    expect(models.isAvailableModel("moonshotai/Kimi-K3")).toBe(false);
    process.env.HF_TOKEN = "hf_token";
    vi.resetModules();
    models = await import("@/lib/ai/models");
    const ids = models.getAvailableModels().map((m) => m.id);
    expect(ids).toEqual(expect.arrayContaining(["@cf/moonshotai/kimi-k2.6", "moonshotai/Kimi-K3", "zai-org/GLM-5.3"]));
    expect(ids).not.toContain("openai/gpt-5.4-mini");
  });

  it("knows each Hugging Face model's capabilities without a network call", async () => {
    process.env.HF_TOKEN = "hf_token";
    const fetchSpy = vi.spyOn(globalThis, "fetch");
    const models = await import("@/lib/ai/models");
    const caps = await models.getCapabilities();
    for (const m of models.huggingFaceModels) {
      expect(caps[m.id]).toEqual(m.capabilities);
    }
    expect(fetchSpy).not.toHaveBeenCalled();
    fetchSpy.mockRestore();
  });

  it("knows each Workers AI model's capabilities without a network call", async () => {
    const fetchSpy = vi.spyOn(globalThis, "fetch");
    const models = await import("@/lib/ai/models");
    const caps = await models.getCapabilities();
    expect(caps[models.DEFAULT_CHAT_MODEL]).toEqual({ reasoning: true, tools: true, vision: true });
    expect(Object.keys(caps).every((id) => id.startsWith("@cf/"))).toBe(true);
    expect(fetchSpy).not.toHaveBeenCalled();
    fetchSpy.mockRestore();
  });
});

describe("the provider (lib/ai/providers.ts)", () => {
  beforeEach(() => {
    vi.resetModules();
    run.mockReset();
    delete process.env.AI_GATEWAY_ID;
    delete process.env.HF_TOKEN;
  });
  afterEach(() => {
    vi.unstubAllGlobals();
    delete process.env.HF_TOKEN;
  });

  it("answers a gateway model with no gateway named by the default Workers AI model", async () => {
    const { resolveModelId } = await import("@/lib/ai/providers");
    const { DEFAULT_CHAT_MODEL } = await import("@/lib/ai/models");
    expect(resolveModelId("xai/grok-4.3")).toBe(DEFAULT_CHAT_MODEL);
    expect(resolveModelId("@cf/zai-org/glm-4.7-flash")).toBe("@cf/zai-org/glm-4.7-flash");
    process.env.AI_GATEWAY_ID = "default";
    expect(resolveModelId("xai/grok-4.3")).toBe("xai/grok-4.3");
  });

  it("runs a gateway model on the AI binding, through the named gateway", async () => {
    process.env.AI_GATEWAY_ID = "my-gateway";
    run.mockResolvedValue({
      choices: [{ finish_reason: "stop", index: 0, message: { content: "Hello from the gateway", role: "assistant" } }],
      usage: { completion_tokens: 4, prompt_tokens: 1, total_tokens: 5 },
    });
    const fetchSpy = vi.spyOn(globalThis, "fetch");
    const { getLanguageModel } = await import("@/lib/ai/providers");
    const { text } = await generateText({ model: getLanguageModel("openai/gpt-5.4-mini"), prompt: "hi" });
    expect(text).toBe("Hello from the gateway");
    expect(run).toHaveBeenCalledTimes(1);
    expect(run.mock.calls[0]![0]).toBe("openai/gpt-5.4-mini");
    expect(run.mock.calls[0]![2]).toMatchObject({ gateway: { id: "my-gateway" } });
    expect(fetchSpy).not.toHaveBeenCalled();
    fetchSpy.mockRestore();
    delete process.env.AI_GATEWAY_ID;
  });

  it("knows each gateway model's capabilities without a network call", async () => {
    process.env.AI_GATEWAY_ID = "default";
    const fetchSpy = vi.spyOn(globalThis, "fetch");
    const models = await import("@/lib/ai/models");
    const caps = await models.getCapabilities();
    for (const m of models.gatewayModels) {
      expect(caps[m.id]).toEqual(m.capabilities);
    }
    expect(fetchSpy).not.toHaveBeenCalled();
    fetchSpy.mockRestore();
    delete process.env.AI_GATEWAY_ID;
  });

  it("answers a Hugging Face model with no token by the default Workers AI model", async () => {
    const { resolveModelId } = await import("@/lib/ai/providers");
    const { DEFAULT_CHAT_MODEL } = await import("@/lib/ai/models");
    expect(resolveModelId("zai-org/GLM-5.3")).toBe(DEFAULT_CHAT_MODEL);
    process.env.HF_TOKEN = "hf_token";
    expect(resolveModelId("zai-org/GLM-5.3")).toBe("zai-org/GLM-5.3");
  });

  it("runs a Hugging Face model through the router, HF_TOKEN as the bearer", async () => {
    process.env.HF_TOKEN = "hf_token";
    const fetchMock = vi.fn(async () =>
      Response.json({
        choices: [{ finish_reason: "stop", index: 0, message: { content: "Hello from Hugging Face", role: "assistant" } }],
        created: 0,
        id: "chatcmpl-1",
        model: "zai-org/GLM-5.3",
        object: "chat.completion",
        usage: { completion_tokens: 4, prompt_tokens: 1, total_tokens: 5 },
      })
    );
    vi.stubGlobal("fetch", fetchMock);
    const { getLanguageModel } = await import("@/lib/ai/providers");
    const { text } = await generateText({ model: getLanguageModel("zai-org/GLM-5.3"), prompt: "hi" });
    expect(text).toBe("Hello from Hugging Face");
    expect(run).not.toHaveBeenCalled();
    const [url, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe("https://router.huggingface.co/v1/chat/completions");
    expect(new Headers(init.headers).get("authorization")).toBe("Bearer hf_token");
    expect(JSON.parse(String(init.body))).toMatchObject({ model: "zai-org/GLM-5.3" });
  });

  it("runs a chat model on the AI binding", async () => {
    run.mockResolvedValue({ response: "Hello from Workers AI" });
    const { getLanguageModel } = await import("@/lib/ai/providers");
    const { text } = await generateText({
      model: getLanguageModel("@cf/moonshotai/kimi-k2.6"),
      prompt: "hi",
    });
    expect(text).toBe("Hello from Workers AI");
    expect(run).toHaveBeenCalledTimes(1);
    expect(run.mock.calls[0]![0]).toBe("@cf/moonshotai/kimi-k2.6");
  });

  it("streams a chat model's answer from the binding's event stream", async () => {
    run.mockResolvedValue(sse(["Streamed ", "through ", "the binding."]));
    const { getLanguageModel } = await import("@/lib/ai/providers");
    const result = streamText({
      model: getLanguageModel("@cf/moonshotai/kimi-k2.6"),
      prompt: "hi",
    });
    let text = "";
    for await (const delta of result.textStream) {
      text += delta;
    }
    expect(text).toBe("Streamed through the binding.");
    expect(run.mock.calls[0]![1]).toMatchObject({ stream: true });
  });

  it("titles chats with the fast Workers AI model", async () => {
    run.mockResolvedValue({ response: "A title" });
    const { getTitleModel } = await import("@/lib/ai/providers");
    const { titleModel } = await import("@/lib/ai/models");
    await generateText({ model: getTitleModel(), prompt: "hi" });
    expect(run.mock.calls[0]![0]).toBe(titleModel.id);
  });
});
