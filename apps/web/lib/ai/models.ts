// WHERE THE MODELS COME FROM. Upstream sends every model call through
// Vercel's AI Gateway. Here everything runs on the Worker's own `AI` binding
// (wrangler.jsonc). The default is Workers AI: it needs no key, so a fresh
// deployment chats with nothing configured. Other providers' models go
// through Cloudflare AI Gateway on the same binding, billed to the Cloudflare
// account's AI Gateway credits (Unified Billing) — no provider key, but the
// account must hold credits and the gateway must have authentication on, so
// they are offered only when AI_GATEWAY_ID names the gateway to use.
// Hugging Face's models are offered only when HF_TOKEN is set, and the picker
// shows exactly what is available (`getAvailableModels`), never a model that
// would fail.
export const DEFAULT_CHAT_MODEL = "@cf/moonshotai/kimi-k2.6";

export type ModelCapabilities = {
  tools: boolean;
  vision: boolean;
  reasoning: boolean;
};

export type ChatModel = {
  id: string;
  name: string;
  provider: string;
  description: string;
  // `workers-ai`: the AI binding; `gateway`: Cloudflare AI Gateway, on the
  // same binding (needs AI_GATEWAY_ID); `huggingface`: Hugging Face's
  // Inference Providers router (needs HF_TOKEN).
  via?: "workers-ai" | "gateway" | "huggingface";
  // Every model's capabilities are declared here: nothing is looked up.
  capabilities?: ModelCapabilities;
};

// Current Workers AI text models with tool calling (OpenAI-compatible chat
// completions on the binding), run through `workers-ai-provider`.
export const workersAiModels: ChatModel[] = [
  {
    capabilities: { reasoning: true, tools: true, vision: true },
    description: "Moonshot AI's Kimi on Workers AI — tools, vision, reasoning",
    id: "@cf/moonshotai/kimi-k2.6",
    name: "Kimi K2.6",
    provider: "moonshotai",
    via: "workers-ai",
  },
  {
    capabilities: { reasoning: true, tools: true, vision: false },
    description: "Fast GLM on Workers AI — tools, reasoning",
    id: "@cf/zai-org/glm-4.7-flash",
    name: "GLM 4.7 Flash",
    provider: "zai",
    via: "workers-ai",
  },
];

// Titles: the fast Workers AI model, its thinking turned off
// (app/(chat)/actions.ts).
export const titleModel: ChatModel = {
  description: "Fast model for title generation",
  id: "@cf/zai-org/glm-4.7-flash",
  name: "GLM 4.7 Flash",
  provider: "zai",
  via: "workers-ai",
};

// Other providers' models from Cloudflare's AI Gateway catalogue
// (developers.cloudflare.com/ai/models), by their catalogue ids. Offered only
// with AI_GATEWAY_ID set.
export const gatewayModels: ChatModel[] = [
  {
    capabilities: { reasoning: true, tools: true, vision: true },
    description: "OpenAI's small GPT-5.4 — tools, vision, reasoning",
    id: "openai/gpt-5.4-mini",
    name: "GPT-5.4 mini",
    provider: "openai",
    via: "gateway",
  },
  {
    capabilities: { reasoning: true, tools: true, vision: true },
    description: "xAI's Grok 4.3 — tools, vision, reasoning",
    id: "xai/grok-4.3",
    name: "Grok 4.3",
    provider: "xai",
    via: "gateway",
  },
  {
    capabilities: { reasoning: true, tools: true, vision: false },
    description: "DeepSeek's reasoning model — tools, reasoning",
    id: "deepseek/deepseek-v4-pro",
    name: "DeepSeek V4 Pro",
    provider: "deepseek",
    via: "gateway",
  },
];

// Open models on Hugging Face's Inference Providers router, each one served
// with tool calling by at least two providers (router.huggingface.co/v1/models).
// The router picks the provider; the id is the model's Hub id. Offered only
// with HF_TOKEN set.
export const huggingFaceModels: ChatModel[] = [
  {
    capabilities: { reasoning: true, tools: true, vision: false },
    description: "Moonshot AI's Kimi K3 on Hugging Face — tools, reasoning",
    id: "moonshotai/Kimi-K3",
    name: "Kimi K3",
    provider: "huggingface",
    via: "huggingface",
  },
  {
    capabilities: { reasoning: true, tools: true, vision: false },
    description: "Z.ai's GLM 5.3 on Hugging Face — tools, reasoning",
    id: "zai-org/GLM-5.3",
    name: "GLM 5.3",
    provider: "huggingface",
    via: "huggingface",
  },
  {
    capabilities: { reasoning: true, tools: true, vision: false },
    description: "Fast DeepSeek on Hugging Face — tools, reasoning",
    id: "deepseek-ai/DeepSeek-V4.1-Flash",
    name: "DeepSeek V4.1 Flash",
    provider: "huggingface",
    via: "huggingface",
  },
  {
    capabilities: { reasoning: true, tools: true, vision: false },
    description: "Compact Qwen on Hugging Face — tools, reasoning",
    id: "Qwen/Qwen3.8-27B",
    name: "Qwen3.8 27B",
    provider: "huggingface",
    via: "huggingface",
  },
];

// Every model this app knows, in picker order.
export const chatModels: ChatModel[] = [
  ...workersAiModels,
  ...huggingFaceModels,
  ...gatewayModels,
];

// The Cloudflare AI Gateway the gateway's models run through: AI_GATEWAY_ID,
// the gateway's name (`default` is the one every account has). OpenNext
// copies the Worker's secrets and vars into process.env per request, so this
// is read at call time, never at module load.
export function getGatewayId(): string | undefined {
  return process.env.AI_GATEWAY_ID?.trim() || undefined;
}

export function isGatewayConfigured(): boolean {
  return Boolean(getGatewayId());
}

// Whether Hugging Face is configured: HF_TOKEN, a Hugging Face access token
// with the "Make calls to Inference Providers" permission, as a Worker secret.
// Read at call time, like the gateway's id.
export function isHuggingFaceConfigured(): boolean {
  return Boolean(process.env.HF_TOKEN);
}

// What a request may use: Workers AI always (the binding is in the committed
// wrangler config), Hugging Face's models only with HF_TOKEN and the
// gateway's only with AI_GATEWAY_ID.
export function getAvailableModels(): ChatModel[] {
  return [
    ...workersAiModels,
    ...(isHuggingFaceConfigured() ? huggingFaceModels : []),
    ...(isGatewayConfigured() ? gatewayModels : []),
  ];
}

export function isAvailableModel(modelId: string): boolean {
  return getAvailableModels().some((m) => m.id === modelId);
}

export function isWorkersAiModel(modelId: string): boolean {
  return workersAiModels.some((m) => m.id === modelId);
}

export function isHuggingFaceModel(modelId: string): boolean {
  return huggingFaceModels.some((m) => m.id === modelId);
}

const NO_CAPABILITIES: ModelCapabilities = {
  reasoning: false,
  tools: false,
  vision: false,
};

export function getCapabilities(): Promise<Record<string, ModelCapabilities>> {
  return Promise.resolve(
    Object.fromEntries(
      getAvailableModels().map((model) => [
        model.id,
        model.capabilities ?? NO_CAPABILITIES,
      ])
    )
  );
}

export const isDemo = process.env.IS_DEMO === "1";

export function getActiveModels(): ChatModel[] {
  return getAvailableModels();
}

export const modelsByProvider = chatModels.reduce(
  (acc, model) => {
    if (!acc[model.provider]) {
      acc[model.provider] = [];
    }
    acc[model.provider].push(model);
    return acc;
  },
  {} as Record<string, ChatModel[]>
);

export type ModelAvailability = "healthy" | "impacted" | "unknown";

// No provider here reports per-model health the way upstream's gateway did,
// so the chat's "may be slow right now" notice never fires: every model is
// "unknown".
export function getModelAvailability(
  _modelId: string
): Promise<ModelAvailability> {
  return Promise.resolve("unknown");
}
