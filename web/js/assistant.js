// The tool-calling loop — message + context + tool schema → run the returned tool calls →
// send the results back → repeat until the model answers in plain language. The same
// algorithm as AriaKit's and Aria.Core's AssistantEngine.
import { TOOLS } from "./tools.js";
import { systemPrompt } from "./planner.js";

export class AssistantEngine {
  /** `client.complete({model, messages, tools, toolChoice})` → {content, toolCalls: [{id, name, arguments}]} */
  constructor(client, executor, maxToolRounds = 6) {
    this.client = client;
    this.executor = executor;
    this.maxToolRounds = maxToolRounds;
  }

  async respond(text, model, history, snapshot, now = new Date(), signal) {
    const userText = (text ?? "").trim();
    if (!userText) throw new Error("Type a message first.");
    const messages = [{ role: "system", content: systemPrompt(now, snapshot) }, ...history, { role: "user", content: userText }];
    const transcript = [{ role: "user", content: userText }];
    const outcomes = [];

    for (let round = 0; round < this.maxToolRounds; round++) {
      const reply = await this.client.complete({ model, messages, tools: TOOLS, toolChoice: "auto", signal });
      const calls = reply.toolCalls ?? [];
      if (calls.length === 0) {
        const answer = finalText(reply.content, outcomes);
        transcript.push({ role: "assistant", content: answer });
        return { text: answer, outcomes, transcript };
      }
      const turn = { role: "assistant", content: reply.content ?? null, toolCalls: calls };
      messages.push(turn);
      transcript.push(turn);
      for (const call of calls) {
        const outcome = await this.executor.execute(call);
        outcomes.push(outcome);
        const result = { role: "tool", toolCallId: call.id, name: call.name, content: JSON.stringify(outcome.output) };
        messages.push(result);
        transcript.push(result);
      }
    }

    // Too many rounds: ask for a wrap-up without further tool calls.
    const wrapUp = await this.client.complete({ model, messages, tools: TOOLS, toolChoice: "none", signal });
    const answer = finalText((wrapUp.toolCalls ?? []).length === 0 ? wrapUp.content : null, outcomes);
    transcript.push({ role: "assistant", content: answer });
    return { text: answer, outcomes, transcript };
  }
}

export function finalText(content, outcomes) {
  const text = (content ?? "").trim();
  if (text) return text;
  const done = outcomes.filter((o) => o.ok && o.mutation).map((o) => o.summary);
  return done.length === 0 ? "Okay." : `${done.join(". ")}.`;
}

/** Earlier user/assistant text for context (ai_conversations rows, oldest first); tool
 *  traffic from past turns is left out. */
export function contextMessages(rows, limit = 12) {
  const texts = [];
  for (const row of rows) {
    const content = (row.content ?? "").trim();
    if (!content) continue;
    if (row.role === "user") texts.push({ role: "user", content });
    else if (row.role === "assistant" && row.tool_calls == null) texts.push({ role: "assistant", content });
  }
  const window = texts.slice(Math.max(0, texts.length - limit));
  while (window.length > 0 && window[0].role !== "user") window.shift();
  return window;
}

/** ai_conversations rows for a finished turn, 1 ms apart so their order survives a batch insert. */
export function logEntries(reply, start = new Date()) {
  const outcomes = new Map();
  for (const outcome of reply.outcomes) if (!outcomes.has(outcome.callId)) outcomes.set(outcome.callId, outcome);
  return reply.transcript.map((message, index) => {
    const created_at = new Date(start.getTime() + index).toISOString();
    if (message.role === "assistant") {
      const calls = message.toolCalls?.length
        ? message.toolCalls.map((c) => ({ id: c.id, type: "function", function: { name: c.name, arguments: c.arguments } }))
        : null;
      return { role: "assistant", content: message.content ?? null, tool_calls: calls, created_at };
    }
    if (message.role === "tool") {
      const meta = { tool_call_id: message.toolCallId ?? "", name: message.name ?? "" };
      const outcome = outcomes.get(message.toolCallId);
      if (outcome) {
        meta.summary = outcome.summary;
        meta.ok = outcome.ok;
      }
      return { role: "tool", content: message.content, tool_calls: meta, created_at };
    }
    return { role: "user", content: message.content, tool_calls: null, created_at };
  });
}

/** Rows as chat bubbles: user text, action chips for tool results, assistant answers. */
export function bubbles(rows) {
  const out = [];
  for (const row of rows) {
    if (row.role === "user" && row.content?.trim()) out.push({ kind: "user", text: row.content.trim() });
    else if (row.role === "tool") {
      const meta = row.tool_calls ?? {};
      if (meta.summary) out.push({ kind: "action", ok: meta.ok !== false, text: meta.summary });
    } else if (row.role === "assistant" && row.tool_calls == null && row.content?.trim()) out.push({ kind: "assistant", text: row.content.trim() });
  }
  return out;
}
