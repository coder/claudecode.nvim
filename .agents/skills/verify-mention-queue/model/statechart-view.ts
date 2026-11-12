// /statechart view for MentionQueue.tla: one region per Claude client slot, and one per @ mention.
const has = (seq: any, m: number) => Object.values(seq ?? {}).includes(m);

const client = (v: any, c: number) => {
  if (!v.serverUp) return "integration stopped";
  const state = (
    {
      none: "not connected",
      connecting: "connecting",
      upgrading: "connecting",
      connected: "connected",
      closing: "hanging up",
    } as Record<string, string>
  )[v.cstate[c]];
  if (v.cstate[c] === "connected")
    return v.age[c] === "handshake"
      ? "connected, ready"
      : "connected, not ready yet";
  return state;
};

const outcomes: Record<string, string> = {
  refused: "refused with an error",
  delivered: "Claude has it",
  failed: "write failed, with an error",
  lost: "lost, no error",
  errored: "dropped at its deadline, with an error",
  silent: "dropped, no error",
  cleared: "cleared by the stop",
};

const mention = (v: any, m: number) => {
  if (!v.sent[m]) return "not sent";
  if (has(v.queue, m)) {
    const moving =
      v.flushTimer !== "nil" || v.dlTimer !== "nil" || v.openRuns > 0;
    return moving ? "queued" : "queued, nothing will send or drop it";
  }
  return outcomes[v.outcome[m]] ?? v.outcome[m];
};

const ids = (v: any) =>
  Object.keys(v.sent)
    .map(Number)
    .sort((a, b) => a - b);

export const title = "Your @ mentions and the Claude clients (claudecode.nvim)";

export const state = (v: any) => {
  const regions: Record<string, string> = {};
  for (const c of [1, 2]) regions[`Claude ${c}`] = client(v, c);
  for (const m of ids(v)) regions[`Mention ${m}`] = mention(v, m);
  if (v.early)
    regions["Sent early"] = "a mention went out before any client was ready";
  if (v.luaError) regions["Lua error"] = "Lua error";
  if (v.leaked)
    regions["Sent after a stop"] =
      "a mention queued before :ClaudeCodeStop reached a Claude after the stop";
  return regions;
};

export const group = (v: any) => {
  const all = ids(v).map((m) => mention(v, m));
  if (
    v.early ||
    v.luaError ||
    v.leaked ||
    all.some((s) => s.includes("no error") || s.includes("nothing will"))
  )
    return "harm";
  if (all.every((s) => s === "Claude has it")) return "good";
  return "open";
};
export const colors = { harm: "pink", good: "teal", open: "blue" };

const labels: Record<string, string> = {
  YouSend: "you send a mention",
  YouStop: "you run :ClaudeCodeStop",
  YouStart: "you run :ClaudeCodeStart",
  ClaudeConnects: "a Claude opens its socket",
  ClaudeUpgrades: "Claude asks for the WebSocket",
  HandshakeWritten: "the handshake completes",
  AcceptWaitPasses: "600 ms pass since the socket opened",
  HandshakeWaitPasses: "600 ms pass since the handshake: Claude is ready",
  ClaudeCloses: "Claude hangs up",
  CloseCallbackRuns: "Claude's socket goes away",
  ClaudeDrops: "Claude's socket goes away",
  OpenRuns: "the handshake schedules a flush",
  FlushTimerFires: "a flush is due",
  FlushRuns: "the flush runs",
  DeadlineFires: "a deadline passes",
  DeadlineRuns: "the deadline clears the expired mentions",
  Done: "nothing more happens",
};
export const step = (action: string) =>
  labels[action.replace(/\(.*$/, "")] ?? action;
