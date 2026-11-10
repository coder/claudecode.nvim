// /statechart view for WsConnection.tla: one Claude connection, as three regions: the plugin's view of the
// connection, Claude's side, and the server. A wrapper spec that narrows an action names it Flow<Action>; it gets
// the label of <Action>.
const has = (set: any, x: string) => Array.isArray(set) && set.includes(x);
const seq = (s: any): any[] => (s ? Object.values(s) : []);
const first = (vars: any) => Object.keys(vars.st).sort()[0];

const connection = (v: any, c: string) => {
  const st = v.st[c];
  if (st === "none") return "not connected";
  const open = v.handle[c] === "open";
  if (!v.listed[c])
    return open ? "dropped, socket still open" : "dropped, socket closed";
  if (st === "connecting") return "TCP accepted, no handshake yet";
  if (st === "upgrading") return "handshake accepted, 101 being written";
  if (st === "connected")
    return seq(v.sched).some((e: any) => e.c === c && e.k === "message")
      ? "connected, a request waits to run"
      : "connected";
  if (has(v.queued[c], "close")) return "closing, its Close frame waits";
  return "closing";
};

const claude = (v: any, c: string) =>
  ({
    idle: "not started",
    live: "reading",
    silent: "not reading",
    stuck: "not reading, window full",
    gone: "hung up",
  })[v.peer[c] as string] ?? v.peer[c];

export const title =
  "One Claude connection to the claudecode.nvim WebSocket server";

export const state = (v: any) => ({
  Connection: connection(v, first(v)),
  Claude: claude(v, first(v)),
  Server: v.serverUp ? "running" : "stopped",
});

export const group = (v: any) => {
  const label = connection(v, first(v));
  if (label.startsWith("dropped")) return "ended";
  if (label.startsWith("connected")) return "connected";
  return "transition";
};
export const colors = { ended: "teal", connected: "blue", transition: "pink" };

const labels: Record<string, string> = {
  Accept: "Claude connects",
  Read: "the plugin reads what Claude sent",
  ReadEOF: "the plugin sees Claude hang up",
  WriteDone: "a write to Claude completes",
  CloseFinishes: "the socket finishes closing",
  ScheduledRuns: "the main loop runs a scheduled step",
  TimerTicks: "the ping timer ticks",
  TimerTicksAfterGap: "the ping timer ticks after Neovim was blocked",
  TimerTicksLate:
    "the ping timer ticks late, before the plugin reads Claude's pong",
  TimerTicksExact:
    "the ping timer ticks with the last pong exactly two intervals old",
  ServerStops: "you stop the server",
  PluginSendsLarge: "the plugin sends Claude a large message",
  ClaudeSends: "Claude sends a frame",
  ClaudeAnswersPing: "Claude answers a ping",
  ClaudeStopsReading: "Claude stops reading",
  ClaudeResumes: "Claude reads again",
  ClaudeHangsUp: "Claude hangs up",
};

const frames: Record<string, string> = {
  hello: "its upgrade request",
  badhello: "a bad upgrade request",
  req: "a request",
  pong: "a pong",
  close: "a Close frame",
  bad: "a frame that breaks the protocol",
};

export const step = (name: string, from: any, to: any) => {
  const action = name.replace(/^Flow/, "");
  const c = first(from);
  if (action === "ClaudeSends") {
    const sent = seq(to.inq[c]);
    return `Claude sends ${frames[sent[sent.length - 1]] ?? "a frame"}`;
  }
  if (action === "Read")
    return `the plugin reads ${frames[seq(from.inq[c])[0]] ?? "a frame"}`;
  if (action === "WriteDone") {
    const k = seq(from.kern[c])[0]?.k;
    if (k === "101") return "the 101 reply is written";
    if (k === "reject") return "the rejection is written";
    return "the plugin's Close frame is written";
  }
  if (action === "ScheduledRuns") {
    const e = seq(from.sched)[0];
    if (e?.k === "message")
      return to.badDispatch && !from.badDispatch
        ? "the request runs [too late]"
        : "the request runs";
    if (e?.k === "close") return "the plugin handles Claude's Close frame";
    return "the plugin handles the protocol error";
  }
  if (
    action === "TimerTicks" ||
    action === "TimerTicksAfterGap" ||
    action === "TimerTicksLate" ||
    action === "TimerTicksExact"
  ) {
    if (from.listed[c] && !to.listed[c])
      return "the ping timer drops Claude for no reply";
  }
  return labels[action] ?? action;
};
