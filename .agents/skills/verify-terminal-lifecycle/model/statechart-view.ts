// /statechart view for TerminalLifecycle.tla, in the words of the person who uses Claude in Neovim.
const none = "none";
const terms = (v: any) => Object.keys(v.job).sort();
const running = (v: any) => terms(v).filter((t) => v.job[t] === "running");
// The terminal that the provider in use tracks (terminal.lua get_provider decides which one).
const tracked = (v: any) => {
  // The model's SnacksUp is `seen` while SnacksAvailabilityCached is TRUE (check.sh reads TRUE at 3cac7ef) and `loadable`
  // while it is FALSE. The view cannot read a constant, so it takes `seen`, and `state` names a state where the two differ.
  const snacksUp = v.seen;
  const prov = v.cfg.provider === "native" || !snacksUp ? "native" : "snacks";
  const t = prov === "native" ? v.ntrack : v.strack;
  return t === none ? null : t;
};
const isLast = (v: any, t: string) =>
  v.win[t] && !v.others && terms(v).every((u) => u === t || !v.win[u]);

const claude = (v: any) => {
  const t = tracked(v);
  const n = running(v).length;
  const count =
    n === 0 ? "no Claude runs" : n === 1 ? "Claude runs" : `${n} Claudes run`;
  if (v.pc.op === "split") return `${count}, a start is setting up a window`;
  if (v.pc.op === "started") return `${count}, a start ran termopen`;
  if (v.pc.op === "waiting")
    return `${count}, a close waits for Claude to stop`;
  if (t === null) {
    const lost = n > 0 ? " (the plugin tracks none)" : "";
    const leftover = terms(v).some((u) => v.win[u] && v.job[u] === "exited")
      ? ", an exited terminal is on screen"
      : "";
    return `${count}${lost}${leftover}`;
  }
  const state =
    v.job[t] === "exited"
      ? "the tracked terminal's Claude exited"
      : v.swapped[t]
        ? "your file is in Claude's window"
        : v.win[t]
          ? isLast(v, t)
            ? "Claude's window is the only window"
            : "Claude is on screen"
          : "Claude is hidden";
  const untracked = running(v).filter((u) => u !== t).length;
  return `${count}, ${state}${untracked ? ", one runs untracked" : ""}`;
};

export const title = "The Claude terminal (claudecode.nvim)";

export const state = (v: any) => {
  const extra: string[] = [];
  if (v.reloaded) extra.push("after a reload");
  if (v.seen !== v.loadable)
    extra.push(
      "snacks.nvim became loadable after the module loaded (SnacksAvailabilityCached decides which provider runs)",
    );
  if (v.queue.length > 0) extra.push("exit cleanup queued");
  return [claude(v), ...extra].join(", ");
};

// AtMostOneClaude exempts the Claude that a close is stopping.
const notStopping = (v: any) =>
  running(v).filter((t) => !(v.pc.op === "waiting" && v.pc.t === t));

export const group = (v: any) => {
  if (v.bad.length > 0) return "broken";
  if (notStopping(v).length > 1) return "broken";
  if (v.pc.op !== "idle") return "busy";
  return running(v).length === 1 ? "running" : "idle";
};
export const colors = {
  broken: "pink",
  busy: "orange",
  running: "teal",
  idle: "blue",
};

const flagged = (from: any, to: any, f: string) =>
  !from.bad.includes(f) && to.bad.includes(f);

export const step = (action: string, from: any, to: any) => {
  switch (action) {
    case "YouOpen": {
      if (to.pc.op === "split")
        return "you open or toggle Claude (a start begins)";
      if (flagged(from, to, "hideError"))
        return "you toggle Claude (E444: cannot close last window)";
      if (flagged(from, to, "badOpen"))
        return "you open or toggle Claude (no running Claude shows)";
      const t = tracked(from) ?? tracked(to);
      if (t && from.win[t] && !to.win[t]) return "you toggle Claude away";
      return "you open or toggle Claude";
    }
    case "AutocmdCalls":
      return flagged(from, to, "hideError")
        ? "an autocmd calls a toggle during the start (it hides the new window)"
        : "an autocmd calls open or a toggle during the start";
    case "TermopenRuns":
      return to.pc.op === "started"
        ? "termopen starts Claude"
        : "termopen fails";
    case "StartReturns":
      return flagged(from, to, "hideError")
        ? "the start returns and raises Invalid window id (its split is gone)"
        : "the start returns";
    case "YouClose":
      return to.pc.op === "waiting"
        ? "you run :ClaudeCodeClose (it waits)"
        : "you run :ClaudeCodeClose";
    case "CloseWaitEnds":
      return "the close deletes the buffer";
    case "ScheduledOpen":
      return "a scheduled open runs during the close";
    case "ClaudeExits":
      return "Claude exits";
    case "CallbackRuns":
      return flagged(from, to, "exitClosedOther")
        ? "the exit cleanup closes your window"
        : "the exit cleanup runs";
    case "YouMakeItTheOnlyWindow":
      return "you run :only in Claude's window";
    case "YouSplitAWindow":
      return "you split a window";
    case "YouShowAnotherBufferThere":
      return "you :e a file in Claude's window";
    case "YouWipeTheBuffer":
      return "you wipe Claude's buffer";
    case "SnacksBecomesLoadable":
      return "snacks.nvim becomes loadable";
    case "PluginReloads":
      return "the plugin reloads";
    default:
      return action;
  }
};
