// The assistant's model providers, called straight from the browser with the account's own
// key: OpenRouter (hundreds of models, reads PDFs natively) or Groq (GroqCloud, very fast
// open models). Both speak the OpenAI chat-completions format.
export const DEFAULT_MODEL = "anthropic/claude-sonnet-4.5";

export const CURATED_MODELS = [
  ["anthropic/claude-sonnet-4.5", "Claude Sonnet 4.5"],
  ["anthropic/claude-haiku-4.5", "Claude Haiku 4.5"],
  ["openai/gpt-4o", "GPT-4o"],
  ["openai/gpt-4o-mini", "GPT-4o mini"],
  ["google/gemini-2.5-pro", "Gemini 2.5 Pro"],
  ["google/gemini-2.5-flash", "Gemini 2.5 Flash"],
  ["meta-llama/llama-3.3-70b-instruct", "Llama 3.3 70B Instruct"],
  ["mistralai/mistral-large", "Mistral Large"],
].map(([id, name]) => ({ id, name }));

export const GROQ_DEFAULT_MODEL = "qwen/qwen3.8-27b";

export const GROQ_MODELS = [
  ["qwen/qwen3.8-27b", "Qwen 3.8 27B · reads images"],
  ["qwen/qwen3.6-27b", "Qwen 3.6 27B · reads images"],
  ["openai/gpt-oss-120b", "GPT-OSS 120B · text only"],
  ["openai/gpt-oss-20b", "GPT-OSS 20B · text only"],
].map(([id, name]) => ({ id, name }));

/** Groq models that accept images (the rest get images described to them first). */
export const groqReadsImages = (id = "") => /qwen3\.\d+-\d+b|llama-4|vision|(^|[-/])vl([-/]|$)/i.test(id);

export const PROVIDERS = {
  openrouter: {
    id: "openrouter", name: "OpenRouter", base: "https://openrouter.ai/api/v1",
    keyField: "openrouter_key", modelField: "openrouter_model", defaultModel: DEFAULT_MODEL, curated: CURATED_MODELS,
    keyPlaceholder: "sk-or-v1-…", keysUrl: "https://openrouter.ai/keys", keysHost: "openrouter.ai/keys", modelExample: "openai/gpt-4.1",
  },
  groq: {
    id: "groq", name: "Groq", base: "https://api.groq.com/openai/v1",
    keyField: "groq_key", modelField: "groq_model", defaultModel: GROQ_DEFAULT_MODEL, curated: GROQ_MODELS,
    keyPlaceholder: "gsk_…", keysUrl: "https://console.groq.com/keys", keysHost: "console.groq.com/keys", modelExample: "openai/gpt-oss-120b",
  },
};

export const providerOf = (id) => PROVIDERS[id] ?? PROVIDERS.openrouter;

/** A chat-completions client for one provider. `getKey()` returns the key at call time. */
export class ChatClient {
  constructor(provider, getKey, fetchImpl = (...a) => fetch(...a), base = null) {
    this.provider = typeof provider === "string" ? providerOf(provider) : provider;
    this.getKey = getKey;
    this.base = base ?? this.provider.base;
    this.fetch = fetchImpl;
  }

  get groq() {
    return this.provider.id === "groq";
  }

  headers() {
    const key = this.getKey();
    if (!key) throw new Error(`Add your ${this.provider.name} key in Settings to use the assistant.`);
    const headers = { Authorization: `Bearer ${key}`, "Content-Type": "application/json" };
    if (!this.groq) headers["X-Title"] = "Aria";
    return headers;
  }

  async complete({ model, messages, tools, toolChoice = "auto", signal }) {
    const body = { model, messages: messages.map((m) => this.wire(m)) };
    if (tools) Object.assign(body, { tools, tool_choice: toolChoice });
    const headers = this.headers(); // no key → say so, not "couldn't be reached"
    let response;
    try {
      response = await this.fetch(`${this.base}/chat/completions`, { method: "POST", headers, body: JSON.stringify(body), signal });
    } catch (error) {
      if (error?.name === "AbortError") throw error;
      throw new Error(`${this.provider.name} could not be reached. Check your connection.`);
    }
    const json = await response.json().catch(() => null);
    if (!response.ok || json?.error) throw new Error(describeError(this.provider.name, response.status, json));
    const message = json?.choices?.[0]?.message;
    if (!message) throw new Error(`${this.provider.name} returned an empty answer. Try again.`);
    const toolCalls = (message.tool_calls ?? []).map((c, i) => ({
      id: c.id || `call_${i}`,
      name: c.function?.name ?? "",
      arguments: typeof c.function?.arguments === "string" ? c.function.arguments : JSON.stringify(c.function?.arguments ?? {}),
    }));
    const content = typeof message.content === "string" ? stripThinking(message.content) : null;
    return { content, toolCalls };
  }

  /** Models that can call tools, for the picker. */
  async models() {
    const response = await this.fetch(`${this.base}/models`, this.groq ? { headers: this.headers() } : undefined);
    if (!response.ok) throw new Error(response.status === 401 ? `${this.provider.name} didn't accept your key. Check it in Settings.` : "Couldn't load the model list.");
    const json = await response.json();
    return (json.data ?? [])
      .filter((m) => (this.groq
        ? m.active !== false && !/whisper|tts|guard|orpheus|playai|distil|prompt-guard|compound/i.test(m.id)
        : (m.supported_parameters ?? []).includes("tools")))
      .map((m) => ({ id: m.id, name: m.name || m.id }))
      .sort((a, b) => a.name.localeCompare(b.name));
  }

  wire(m) {
    if (m.role === "assistant" && m.toolCalls?.length) {
      return {
        role: "assistant",
        content: m.content ?? null,
        tool_calls: m.toolCalls.map((c) => ({ id: c.id, type: "function", function: { name: c.name, arguments: c.arguments } })),
      };
    }
    if (m.role === "tool") {
      return this.groq
        ? { role: "tool", tool_call_id: m.toolCallId, content: m.content }
        : { role: "tool", tool_call_id: m.toolCallId, name: m.name, content: m.content };
    }
    // Groq's text-only models want a plain string; only send parts when there's an image.
    if (this.groq && Array.isArray(m.content) && m.content.every((p) => p.type === "text")) {
      return { role: m.role, content: m.content.map((p) => p.text).join("\n\n") };
    }
    return { role: m.role, content: m.content };
  }
}

/** OpenRouter, as before. */
export class OpenRouterClient extends ChatClient {
  constructor(getKey, base = PROVIDERS.openrouter.base, fetchImpl) {
    super("openrouter", getKey, fetchImpl, base);
  }
}

/** Some reasoning models put their thinking inline; only the answer is shown. */
const stripThinking = (text) => text.replace(/<think>[\s\S]*?<\/think>\s*/gi, "").replace(/^[\s\S]*?<\/think>\s*/i, "");

function describeError(name, status, json) {
  const detail = json?.error?.message;
  const code = json?.error?.code;
  if (status === 401) return `${name} didn't accept your key. Check it in Settings.`;
  if (status === 402) return `Your ${name} account is out of credits.`;
  if (status === 413) return `That's too much for ${name} in one go. Try a smaller file or fewer pages.`;
  if (status === 429) return `${name} is rate-limiting requests. Wait a moment and try again.`;
  if (code === "tool_use_failed") return "The model made a malformed tool call. Try again, or pick another model in Settings.";
  if (code === "model_not_found" || /model .*(does not exist|not found|decommissioned)/i.test(detail ?? "")) return `${name} doesn't have that model any more. Pick another in Settings.`;
  return detail ? `${name}: ${detail}` : `${name} returned an error (${status}).`;
}
