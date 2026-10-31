// /statechart view for DiffLifecycle.tla: one parallel region per openDiff call.
const first = (seq: any) => (seq && seq[1] !== undefined ? seq[1] : null);

const call = (v: any, r: string) => {
  const phase = v.phase[r];
  if (phase === "unsent") return "not called";
  const diff = v.active[v.reqTab[r]];
  const shown = diff.req !== r ? "its diff closed" : `diff ${diff.status}`;
  if (phase === "setup") return `opening, ${shown}`;
  if (phase === "waiting")
    return diff.req === r && diff.status === "pending"
      ? "waits for the user"
      : `waits, ${shown}, nothing can answer`;
  return `got ${first(v.answers[r]) ?? "no answer"}, ${shown}`;
};

export const title = "Claude's openDiff calls (claudecode.nvim)";

export const state = (v: any) =>
  Object.fromEntries(
    Object.keys(v.phase)
      .sort()
      .map((r) => [`Call ${r}`, call(v, r)]),
  );

export const group = (v: any) => {
  const calls = Object.keys(v.phase).map((r) => call(v, r));
  if (calls.some((c) => c.includes("nothing can answer"))) return "stuck";
  return calls.every((c) => c.startsWith("got")) ? "answered" : "open";
};
export const colors = { stuck: "pink", answered: "teal", open: "blue" };

const labels: Record<string, string> = {
  ClaudeOpensDiff: "Claude calls openDiff",
  UserHandlerResolves: "a ClaudeCodeDiffOpened handler accepts or denies",
  DiffYields: "setup finishes, the call waits",
  SetupAnswers: "setup finishes, Claude gets the handler's answer",
  UserAccepts: "you :w",
  UserRejects: "you :q or deny",
  UserClosesAllDiffs: "you run :ClaudeCodeCloseAllDiffs",
  ClaudeClosesTab: "Claude calls close_tab",
  ClaudeClosesAllDiffTabs: "Claude calls closeAllDiffTabs",
  ClientDisconnects: "Claude disconnects",
  DisconnectCleanupRuns: "the disconnect cleanup runs",
  ServerStops: "the server stops",
};
export const step = (action: string) => labels[action] ?? action;
