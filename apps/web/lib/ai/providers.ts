import { createOpenAICompatible } from "@ai-sdk/openai-compatible";
import { getCloudflareContext } from "@opennextjs/cloudflare";
import { customProvider, type LanguageModel } from "ai";
import { createWorkersAI } from "workers-ai-provider";
import { isTestEnvironment } from "../constants";
import {
  DEFAULT_CHAT_MODEL,
  getGatewayId,
  isAvailableModel,
  isHuggingFaceModel,
  isWorkersAiModel,
  titleModel,
} from "./models";

export const myProvider = isTestEnvironment
  ? (() => {
      const {
        chatModel,
        titleModel: mockTitleModel,
      } = require("./models.mock");
      return customProvider({
        languageModels: {
          "chat-model": chatModel,
          "title-model": mockTitleModel,
        },
      });
    })()
  : null;

// Workers AI through the Worker's own `AI` binding (wrangler.jsonc). No key:
// the binding is the credential. Read per call — the binding lives on the
// request's Cloudflare context, not at module scope.
function workersAi() {
  const { env } = getCloudflareContext();
  if (!env.AI) {
    throw new Error(
      'The AI binding is missing: wrangler.jsonc must declare `"ai": { "binding": "AI" }`'
    );
  }
  return createWorkersAI({ binding: env.AI });
}

// Another provider's model, through Cloudflare AI Gateway on the same `AI`
// binding: `workers-ai-provider` runs a catalogue id (`openai/gpt-5.4-mini`)
// as `env.AI.run(id, inputs, { gateway })`, and the gateway holds the
// credential — Unified Billing against the account's credits, or a key stored
// on the gateway. No provider key reaches this Worker.
function aiGateway() {
  const { env } = getCloudflareContext();
  if (!env.AI) {
    throw new Error(
      'The AI binding is missing: wrangler.jsonc must declare `"ai": { "binding": "AI" }`'
    );
  }
  return createWorkersAI({
    binding: env.AI,
    gateway: { id: getGatewayId() ?? "default" },
  });
}

// Hugging Face's Inference Providers router: OpenAI-compatible chat
// completions, HF_TOKEN as the bearer. Built per call, like the binding — the
// secret reaches process.env per request (lib/ai/models.ts).
function huggingFace() {
  return createOpenAICompatible({
    apiKey: process.env.HF_TOKEN,
    baseURL: "https://router.huggingface.co/v1",
    name: "huggingface",
  });
}

// A model id the request may not use — a gateway or Hugging Face model with
// nothing configured, or one nobody lists — falls back to the default Workers AI model rather
// than failing the chat (lib/ai/models.ts, getAvailableModels).
export function resolveModelId(modelId: string): string {
  return isAvailableModel(modelId) ? modelId : DEFAULT_CHAT_MODEL;
}

export function getLanguageModel(modelId: string): LanguageModel {
  if (isTestEnvironment && myProvider) {
    return myProvider.languageModel(modelId);
  }

  const id = resolveModelId(modelId);
  if (isWorkersAiModel(id)) {
    return workersAi()(id);
  }
  if (isHuggingFaceModel(id)) {
    return huggingFace()(id);
  }
  return aiGateway()(id);
}

export function getTitleModel(): LanguageModel {
  if (isTestEnvironment && myProvider) {
    return myProvider.languageModel("title-model");
  }
  return workersAi()(titleModel.id);
}
