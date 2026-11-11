// /statechart view for SelectionTracking.tla: what you do, what Claude holds, and whether a timer still waits.
const file = (b: string) =>
  ({ f1: "a.txt", f2: "b.txt" })[b] ?? "the Claude terminal";

const waiting = (v: any) =>
  v.db !== "nil" ||
  v.dbStale ||
  v.dbLoose ||
  v.dm !== "nil" ||
  v.dmStale ||
  v.chk ||
  (v.dmLoose && v.dmLoose.length > 0);

// What Claude holds. While a timer waits, a cursor that is behind is normal, so only a settled state says so.
const what = (v: any) => {
  const sel = v.latest;
  if (!sel || sel.kind === undefined) return "nothing";
  if (sel.kind === "cur") {
    const behind = !waiting(v) && sel.buf === v.buf && sel.at !== v.cur;
    return `the cursor in ${file(sel.buf)}${behind ? ", where it was" : ""}`;
  }
  if (sel.ver !== v.ver[sel.buf])
    return `text you deleted from ${file(sel.buf)}`;
  const live = v.mode === "v" && sel.buf === v.buf && sel.at === v.vsel;
  const held =
    v.hold &&
    v.hold.kind === "vis" &&
    v.hold.at === sel.at &&
    v.hold.buf === sel.buf;
  return live || held
    ? `your selection in ${file(sel.buf)}`
    : `an old selection in ${file(sel.buf)}`;
};

const you = (v: any) => {
  if (v.buf === "term")
    return v.mode === "v"
      ? "you select in the Claude terminal"
      : "you are in the Claude terminal";
  if (v.mode === "v") return `you select in ${file(v.buf)}`;
  if (v.hold && v.hold.kind === "vis") {
    const changed = v.hold.ver !== v.ver[v.hold.buf] ? " and edited it" : "";
    return `you released a selection in ${file(v.buf)}${changed}`;
  }
  return `your cursor is in ${file(v.buf)}`;
};

export const title = "What Claude sees as your selection (claudecode.nvim)";

export const state = (v: any) => {
  if (v.mode === "v" && waiting(v)) return `${you(v)}; a timer waits`;
  return `${you(v)}; Claude holds ${what(v)}${waiting(v) ? "; a timer waits" : ""}`;
};

export const group = (v: any) => {
  if (waiting(v)) return "waiting";
  const sel = v.latest;
  const otherFile =
    sel && sel.kind !== undefined && v.buf !== "term" && sel.buf !== v.buf;
  return otherFile || /deleted|old|where it was/.test(what(v))
    ? "stale"
    : "current";
};
export const colors = { stale: "pink", current: "teal", waiting: "blue" };

const labels: Record<string, string> = {
  YouStartSelecting: "you start selecting (v, V, gv)",
  YouExtendSelection: "you extend the selection",
  YouReleaseSelection: "you press Esc",
  YouEditSelection: "you delete or change the selection (d, c)",
  YouMoveCursor: "you move the cursor",
  YouEditAtCursor: "you press x on the cursor",
  YouEditElsewhere: "you edit another line",
  DebounceTimerFires: "100 ms pass",
  DebounceCallbackRuns: "the plugin updates Claude",
  LooseDebounceCallbackRuns: "a lost debounce timer runs",
  DemotionTimerFires: "the demotion delay passes",
  DemotionCallbackRuns: "the plugin checks whether you moved",
  LooseDemotionCallbackRuns: "a lost demotion timer runs",
};

// A callback of a cancelled timer returns at once in the code as written, so the chart hides it.
export const step = (action: string, _from: any, to: any) => {
  if (
    action === "StaleDebounceCallbackRuns" ||
    action === "StaleDemotionCallbackRuns"
  )
    return null;
  if (action === "YouSwitchBuffer") return `you go to ${file(to.buf)}`;
  return labels[action] ?? action;
};
