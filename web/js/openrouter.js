// OpenRouter from the browser. The key is the user's own, kept in this browser only.
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

export class OpenRouterClient {
  constructor(getKey, base = "https://openrouter.ai/api/v1", fetchImpl = (...a) => fetch(...a)) {
    this.getKey = getKey;
    this.base = base;
    this.fetch = fetchImpl;
  }

  headers() {
    const key = this.getKey();
    if (!key) throw new Error("Add your OpenRouter key in Settings to use the assistant.");
    return { Authorization: `Bearer ${key}`, "Content-Type": "application/json", "X-Title": "Aria" };
  }

  async complete({ model, messages, tools, toolChoice = "auto", signal }) {
    const body = { model, messages: messages.map(wireMessage), tools, tool_choice: toolChoice };
    let response;
    try {
      response = await this.fetch(`${this.base}/chat/completions`, { method: "POST", headers: this.headers(), body: JSON.stringify(body), signal });
    } catch (error) {
      if (error?.name === "AbortError") throw error;
      throw new Error("OpenRouter could not be reached. Check your connection.");
    }
    const json = await response.json().catch(() => null);
    if (!response.ok || json?.error) throw new Error(describeError(response.status, json));
    const message = json?.choices?.[0]?.message;
    if (!message) throw new Error("OpenRouter returned an empty answer. Try again.");
    const toolCalls = (message.tool_calls ?? []).map((c, i) => ({
      id: c.id || `call_${i}`,
      name: c.function?.name ?? "",
      arguments: typeof c.function?.arguments === "string" ? c.function.arguments : JSON.stringify(c.function?.arguments ?? {}),
    }));
    return { content: typeof message.content === "string" ? message.content : null, toolCalls };
  }

  /** Models that can call tools, for the picker. */
  async models() {
    const response = await this.fetch(`${this.base}/models`);
    if (!response.ok) throw new Error("Couldn't load the model list.");
    const json = await response.json();
    return (json.data ?? [])
      .filter((m) => (m.supported_parameters ?? []).includes("tools"))
      .map((m) => ({ id: m.id, name: m.name || m.id }))
      .sort((a, b) => a.name.localeCompare(b.name));
  }
}

function wireMessage(m) {
  if (m.role === "assistant" && m.toolCalls?.length) {
    return {
      role: "assistant",
      content: m.content ?? null,
      tool_calls: m.toolCalls.map((c) => ({ id: c.id, type: "function", function: { name: c.name, arguments: c.arguments } })),
    };
  }
  if (m.role === "tool") return { role: "tool", tool_call_id: m.toolCallId, name: m.name, content: m.content };
  return { role: m.role, content: m.content };
}

function describeError(status, json) {
  const detail = json?.error?.message;
  if (status === 401) return "OpenRouter didn't accept your key. Check it in Settings.";
  if (status === 402) return "Your OpenRouter account is out of credits.";
  if (status === 429) return "OpenRouter is rate-limiting requests. Wait a moment and try again.";
  return detail ? `OpenRouter: ${detail}` : `OpenRouter returned an error (${status}).`;
}
