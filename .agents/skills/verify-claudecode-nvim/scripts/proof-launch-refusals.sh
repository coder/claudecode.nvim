#!/usr/bin/env bash
# Proves that `vcn.sh launch` exits 1 and leaves nothing running when:
#   init           the plugin answers initialize with an error: launch sends jsonrpc "1.0", the plugin answers -32600
#   out-link       VERIFY_OUT is a symlink
#   out-other      VERIFY_OUT is owned by another user
#   out-group      VERIFY_OUT is group-writable
#   out-dot        VERIFY_OUT has a . part
#   out-dotdot     VERIFY_OUT has a .. part
#   parent-link    the default parent dir is a symlink
#   parent-group   the default parent dir is group-writable
#   parent-world   the default parent dir is world-writable
#   above-world    a dir above the default parent dir is world-writable and not sticky
#   tmp-world      TMPDIR, where launch makes its state dir, is world-writable and not sticky
#   tmp-above-world  a dir above TMPDIR is world-writable and not sticky
#   tmp-missing    TMPDIR does not exist, under a sticky dir where another user could make it after the checks
#   tmp-dotdot     TMPDIR has a .. part after a symlink (G/L/../y)
#   tmp-dot        TMPDIR has a . part
#   tmp-link-loose   TMPDIR is a symlink in a dir that others can write and that is not sticky, to a dir only this user can
#                  write: main refused it, so the dir that holds the symlink counts
#   tmp-link-foreign TMPDIR is a symlink that another user owns, to a dir of this user (a bwrap user namespace, where
#                  /var/run is root's; SKIP where it cannot be built)
#   tmp-newline-loose  TMPDIR is a symlink to a loose dir whose name ends in a newline, and a twin symlink without the newline
#                  leads to a safe dir: the resolved path is read with its newline
#   tmp-load-refused  mktemp answers with a path that is not its own resolved path (a // in it): load refuses the new state dir,
#                  and launch leaves no state dir and no evidence dir
#   node-relative  node is found through a relative PATH entry (no mise): its dir would go on PATH in every agent-tty call
#   att-root-nosticky  /tmp/agent-tty is this user's 0700 dir, and /tmp is world-writable without the sticky bit
#   tmp-root       TMPDIR is /: launch gives mktemp /vcn.XXXXXX, not //vcn.XXXXXX (a mktemp shim stops launch and prints it)
#   tmp-space      a dir above TMPDIR that others can write has a name that ends in a space
#   out-space      the same above VERIFY_OUT
#   out-above-resolved  a symlink above VERIFY_OUT points into a dir that others can write: only the resolved path shows it
#   out-above-logical   a dir that others can write holds a symlink above VERIFY_OUT, to a safe dir: only the path as given
#                  shows it
#   out-uncreatable  mkdir cannot create VERIFY_OUT
#   out-file       VERIFY_OUT is a file
#   parent-uncreatable  mkdir cannot create the default parent dir
#   tool-nvim      the nvim that launch finds cannot run (a mise shim in a checkout that mise does not trust): launch names it
#                  and the fix, where it once went on and blamed agent-tty
#   tool-vcn-nvim  the nvim that VCN_NVIM names cannot run
#   tool-jq        the jq that launch finds cannot run, with VCN_NVIM set: launch names jq
#   tool-node      the node that launch finds cannot run, with VCN_NVIM set: launch names node
#   tool-setsid    the setsid that launch finds cannot run, with VCN_NVIM set: launch names setsid
#   old-run-cleanup  a run that exists, with a run.env that has no JQ_BIN (an older vcn.sh wrote it), and a jq on PATH that
#                  cannot run: cleanup still exits 0 and leaves no process and no state dir, as on main (only launch checks)
#   connect-setsid   a run that exists and a setsid on PATH that cannot run: connect still starts a client, because launch
#                  recorded its setsid in run.env. A run.env without SETSID_BIN (an older vcn.sh wrote it) still connects and
#                  cleans up, because connect resolves setsid again
#   old-run-setsid   a run that exists, with a run.env that has no SETSID_BIN: get exits 0 with a setsid that cannot run first
#                  on PATH, and cleanup exits 0 and leaves nothing on a PATH that has no setsid (only connect needs one)
#   out-acl-unremovable  VERIFY_OUT has a default ACL that launch cannot remove (setfacl fails)
#   race           another launch makes the missing dir above VERIFY_OUT first, group-writable: launch uses it,
#                  refuses it in the check after mkdir, and leaves it in place
# and that it accepts:
#   out-dash       a relative VERIFY_OUT that starts with "-", run from another directory
#   tmp-sticky     a world-writable TMPDIR with the sticky bit, like /tmp: the state dir is made there
#   tmp-link       TMPDIR is a symlink to that dir: the state dir is made in the dir, not through the symlink
#   tmp-vcn-entry  a symlink named vcn in a sticky TMPDIR, pointing into a dir that others can write: launch still works
#   tmp-newline-ok  TMPDIR is a symlink whose name ends in a newline, to a safe dir whose name ends in a newline, and loose twins
#                  without the newline exist: launch reaches mktemp with the whole resolved path (a mktemp shim stops it)
#   out-link-locale  VERIFY_OUT under a symlink, with a stat that prints translated file types: launch still works
#   out-acl        a 0500 VERIFY_OUT with a default ACL: launch makes it 0700 without the ACL, so every evidence file is 0600
#   out-made       a new VERIFY_OUT two levels below a dir with a default ACL: launch creates both dirs 0700 and
#                  without an ACL, so every evidence file is 0600
# A refused launch must also leave the files under the proof's temp dir as it found them.
# Prints PASS <case> per case, or FAIL: <reason> and exits 1. The init case's evidence dir is
# deleted when every case passes, and kept with its path printed when one fails.
set -euo pipefail
V="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vcn.sh"
# Resolved, because launch prints the state dir under the resolved path of TMPDIR.
TMP=$(realpath -- "$(mktemp -d)")
init_out=""
finish() {
  local rc=$?
  rm -rf "$TMP"
  [[ -n $init_out ]] || return 0
  if ((rc == 0)); then
    rm -rf "$init_out"
  else
    echo "init evidence kept in $init_out" >&2
  fi
}
trap finish EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# launch <case> [VAR=value...]: run launch and set err to its output. A launch that succeeds is a
# failed case: clean its run up and stop.
launch() {
  local name=$1 rc=0
  shift
  err=$(env -u VERIFY_OUT -u XUM_SCRATCH_DIR "$@" "$V" launch 2>&1) || rc=$?
  if ((rc == 0)); then
    VCN_STATE=$(sed -n 's/^VCN_STATE=//p' <<<"$err") "$V" cleanup >/dev/null
    fail "$name: launch exited 0, wanted 1: $err"
  fi
  ((rc == 1)) || fail "$name: launch exited $rc, wanted 1: $err"
}

# refused <case> <stderr text> [VAR=value...]: launch exits 1 with that text before it starts a run.
refused() {
  local name=$1 want=$2 before after
  shift 2
  before=$(find "$TMP" | sort)
  launch "$name" "$@"
  [[ $err == *"$want"* ]] || fail "$name: stderr lacks '$want': $err"
  [[ $err != *VCN_STATE=* ]] || fail "$name: launch started a run before it refused: $err"
  after=$(find "$TMP" | sort)
  [[ $after == "$before" ]] ||
    fail "$name: launch changed $TMP (< removed, > added): $(diff <(echo "$before") <(echo "$after") | grep '^[<>]' | tr '\n' ' ')"
  echo "PASS $name: $err"
}

mkdir "$TMP/out" "$TMP/link" "$TMP/group" "$TMP/world"
ln -s "$TMP/out" "$TMP/out-link"
refused out-link "$TMP/out-link is a symlink" VERIFY_OUT="$TMP/out-link/"
# Root owns /, so a root caller gets a dir that nobody (uid 65534) owns.
other=/
if ((EUID == 0)); then
  other=$TMP/other
  mkdir "$other"
  chown 65534 "$other"
fi
refused out-other "$other is owned by another user" VERIFY_OUT="$other"
mkdir -m 770 "$TMP/out-group"
refused out-group "$TMP/out-group is group- or world-writable" VERIFY_OUT="$TMP/out-group"
refused out-dot "$TMP/out-link/. has a . or .. part" VERIFY_OUT="$TMP/out-link/."
refused out-dotdot "$TMP/out-link/../out has a . or .. part" VERIFY_OUT="$TMP/out-link/../out"
ln -s "$TMP/out" "$TMP/link/verify-claudecode-nvim"
refused parent-link "$TMP/link/verify-claudecode-nvim is a symlink" XUM_SCRATCH_DIR="$TMP/link"
mkdir -m 770 "$TMP/group/verify-claudecode-nvim"
refused parent-group "$TMP/group/verify-claudecode-nvim is group- or world-writable" XUM_SCRATCH_DIR="$TMP/group"
mkdir -m 707 "$TMP/world/verify-claudecode-nvim"
refused parent-world "$TMP/world/verify-claudecode-nvim is group- or world-writable" XUM_SCRATCH_DIR="$TMP/world"
mkdir -m 777 "$TMP/above"
refused above-world "$TMP/above, above the evidence dir, is writable by others and not sticky" \
  XUM_SCRATCH_DIR="$TMP/above"
# The state dir holds the run.env that cleanup and every other command source, so another user who can swap it runs code
# as this one. VERIFY_OUT is fresh, so only the TMPDIR check can refuse these.
mkdir -m 777 "$TMP/tmp-world"
refused tmp-world "$TMP/tmp-world, above the state dir, is writable by others and not sticky" \
  TMPDIR="$TMP/tmp-world" VERIFY_OUT="$TMP/tmp-out"
mkdir -m 700 "$TMP/above/tmp"
refused tmp-above-world "$TMP/above, above the state dir, is writable by others and not sticky" \
  TMPDIR="$TMP/above/tmp" VERIFY_OUT="$TMP/tmp-out"
mkdir "$TMP/tmp-shared"
chmod 1777 "$TMP/tmp-shared"
refused tmp-missing "TMPDIR=$TMP/tmp-shared/later is not an existing directory" \
  TMPDIR="$TMP/tmp-shared/later" VERIFY_OUT="$TMP/tmp-out"
mkdir -m 700 "$TMP/dd" "$TMP/dd/y" "$TMP/dd/real"
ln -s "$TMP/dd/real" "$TMP/dd/L"
refused tmp-dotdot "TMPDIR=$TMP/dd/L/../y has a . or .. part" TMPDIR="$TMP/dd/L/../y" VERIFY_OUT="$TMP/tmp-out"
refused tmp-dot "TMPDIR=$TMP/dd/./y has a . or .. part" TMPDIR="$TMP/dd/./y" VERIFY_OUT="$TMP/tmp-out"
# GNU mktemp keeps a // in its template, and load refuses a VCN_STATE that is not its own resolved path, so the state dir that
# a TMPDIR of / made would be refused and left behind. The shim records the template and stops launch.
mkdir "$TMP/mktemp-bin"
printf '#!/bin/sh\necho "mktemp shim: template=$2" >&2\nexit 1\n' >"$TMP/mktemp-bin/mktemp"
chmod +x "$TMP/mktemp-bin/mktemp"
# launch resolves node itself. Without mise (a shim that fails stands in, whatever /usr/bin holds), `command -v node` prints a
# relative path for a relative PATH entry, and the dir of that path would go in front of PATH in every agent-tty call. Launch
# refuses before it makes anything.
mkdir -m 700 "$TMP/relnode" "$TMP/relnode/nb" "$TMP/relnode/t" "$TMP/relnode/nomise"
printf '#!/bin/sh\nexit 0\n' >"$TMP/relnode/nb/node"
printf '#!/bin/sh\nexit 1\n' >"$TMP/relnode/nomise/mise"
chmod +x "$TMP/relnode/nb/node" "$TMP/relnode/nomise/mise"
nvim_dir=$(dirname -- "$(mise which nvim 2>/dev/null || command -v nvim)")
(
  cd "$TMP/relnode"
  refused node-relative "node is at ./nb/node, and its dir is not usable: it is not an absolute path" \
    PATH="./nb:$TMP/relnode/nomise:$nvim_dir:/usr/bin:/bin" VCN_AGENT_TTY=/usr/bin/true TMPDIR="$TMP/relnode/t" VERIFY_OUT="$TMP/relnode/o"
)
refused tmp-root "mktemp shim: template=/vcn.XXXXXX" PATH="$TMP/mktemp-bin:$PATH" TMPDIR=/ VERIFY_OUT="$TMP/tmp-out"
# mktemp gets the resolved path. The path as given must pass the same walk, which is main's rule: the symlink itself, its
# owner and the dirs above it.
mkdir -m 777 "$TMP/lnk-loose"
mkdir -m 700 "$TMP/lnk-safe"
ln -s "$TMP/lnk-safe" "$TMP/lnk-loose/t"
refused tmp-link-loose "refusing TMPDIR: $TMP/lnk-loose, above the state dir, is writable by others and not sticky" \
  TMPDIR="$TMP/lnk-loose/t" VERIFY_OUT="$TMP/tmp-out"
# bwrap makes a user namespace that this user owns (no sudo, no second account). Root's inodes show as another user there.
# sandbox_base <case> sets sb to the bwrap arguments that the sandboxed launches below share, or prints SKIP and fails. The tools
# that launch resolves before its checks are bound read-only under their own paths, the repo is at /w, and /tmp is a tmpfs of
# its own, so no case touches the host's /tmp.
sandbox_base() {
  local name=$1 tool exe root repo paths="" binds=()
  command -v bwrap >/dev/null || {
    echo "SKIP $name: bwrap is not installed"
    return 1
  }
  for tool in nvim node jq; do
    exe=$(mise which "$tool" 2>/dev/null || command -v "$tool") || {
      echo "SKIP $name: $tool not found"
      return 1
    }
    exe=$(realpath -- "$exe")
    # nvim needs the runtime beside its bin dir.
    if [[ $tool == nvim ]]; then root=$(dirname -- "$(dirname -- "$exe")"); else root=$(dirname -- "$exe"); fi
    binds+=(--ro-bind "$root" "$root")
    paths+=$(dirname -- "$exe"):
  done
  repo=$(cd "$(dirname "$V")/../../../.." && pwd)
  sb=(--unshare-user --uid 0 --gid 0 --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib
    --symlink usr/lib64 /lib64 --unshare-pid --dev /dev --proc /proc --perms 01777 --tmpfs /tmp "${binds[@]}"
    --ro-bind "$repo" /w --setenv PATH "$paths/usr/bin:/bin" --setenv HOME /tmp --setenv VERIFY_OUT /tmp/out)
  bwrap "${sb[@]}" /usr/bin/true 2>/dev/null || {
    echo "SKIP $name: bwrap cannot make a user namespace here"
    return 1
  }
}

# /var/run is a root-owned symlink to /run, and `--dir /run` makes the target this user's, so only the owner of the symlink
# can refuse it.
tmp_link_foreign_case() {
  local name=tmp-link-foreign out rc=0
  [[ -L /var/run && $(stat -c %u /var/run) == 0 && $(realpath /var/run) == /run ]] || {
    echo "SKIP $name: /var/run is not a root-owned symlink to /run"
    return 0
  }
  sandbox_base "$name" || return 0
  local args=("${sb[@]}" --ro-bind /var /var --dir /run --setenv VCN_AGENT_TTY /usr/bin/true --setenv TMPDIR /var/run)
  out=$(bwrap "${args[@]}" /usr/bin/bash -c '[[ $(stat -c %u /var/run) != "$EUID" && $(stat -c %u /run) == "$EUID" ]] || echo SETUP-WRONG-OWNERS
    /w/.agents/skills/verify-claudecode-nvim/scripts/vcn.sh launch; echo "rc=$?"' 2>&1) || rc=$?
  [[ $out != *SETUP-WRONG-OWNERS* ]] || fail "$name: the symlink is not another user's or its target is not this user's, so the case proves nothing: $out"
  [[ $out == *"refusing TMPDIR: /var/run, above the state dir, is owned by another user"* && $out == *"rc=1"* && $out != *VCN_STATE=* ]] ||
    fail "$name: launch did not refuse /var/run with the owner text and exit 1: $out"
  echo "PASS $name: TMPDIR=/var/run, a symlink that another user owns, was refused before launch made anything"
}
tmp_link_foreign_case

# agent-tty keeps every socket under the fixed dir /tmp/agent-tty and never checks who owns it. Another user who owns it, or who
# can rename entries in it, could swap the socket dir of a run and answer every command. Launch makes the dir 0700 when it is
# missing and refuses one that is not this user's alone.
# att_root_case <case> <planting shell> <want> <mode> [bwrap args]: launch in a sandbox after the planting shell ran. <want> is
# the text of a refusal, which must leave nothing behind, or empty when launch must get past the check and leave
# /tmp/agent-tty with <mode> and this user as its owner. The agent-tty here is `false`, so a launch that got past the check stops
# at the next step, `agent-tty doctor`, and says so: that text, not only the absence of one refusal, is what shows the launch went
# on, so a guard that refuses a safe dir with any other message fails the case.
att_root_case() {
  local name=$1 plant=$2 want=$3 mode=$4 out rc=0
  shift 4
  sandbox_base "$name" || return 0
  local args=("${sb[@]}" "$@" --setenv VCN_AGENT_TTY /usr/bin/false)
  out=$(bwrap "${args[@]}" /usr/bin/bash -c "$plant"'
    /w/.agents/skills/verify-claudecode-nvim/scripts/vcn.sh launch; echo "rc=$?"
    [[ ! -e /tmp/out && ! -e /run/o && -z $(ls -d /tmp/vcn.* /run/t/vcn.* 2>/dev/null) ]] || echo LEFT-BEHIND
    stat -c "ROOT %a %u" /tmp/agent-tty 2>&1' 2>&1) || rc=$?
  if [[ -n $want ]]; then
    [[ $out == *"refusing the agent-tty socket dir: $want"* && $out == *"rc=1"* && $out != *VCN_STATE=* && $out != *LEFT-BEHIND* ]] ||
      fail "$name: launch did not refuse /tmp/agent-tty with '$want', exit 1 and nothing left behind: $out"
    echo "PASS $name: $want, and launch refused it before it made anything"
  else
    [[ $out != *"refusing the agent-tty socket dir"* && $out == *'no agent-tty passes `agent-tty doctor`'* && $out == *"rc=1"* && $out == *"ROOT $mode 0"* ]] ||
      fail "$name: launch did not go on to agent-tty doctor after /tmp/agent-tty, or left it with a mode other than $mode or another owner: $out"
    echo "PASS $name: launch accepted /tmp/agent-tty, went on to agent-tty doctor and left the dir with mode $mode"
  fi
}
host_root_dir=""
for cand in /srv /opt /usr /etc; do
  [[ $(stat -c '%u %a' -- "$cand" 2>/dev/null) == "0 755" ]] && {
    host_root_dir=$cand
    break
  }
done
if [[ -n $host_root_dir ]]; then
  att_root_case att-root-foreign : "/tmp/agent-tty is owned by another user" "" --ro-bind "$host_root_dir" /tmp/agent-tty
else
  echo "SKIP att-root-foreign: no host-root-owned 0755 dir to bind"
fi
att_root_case att-root-loose 'mkdir -m 777 /tmp/agent-tty' "/tmp/agent-tty is group- or world-writable" ""
att_root_case att-root-link 'ln -s /tmp /tmp/agent-tty' "/tmp/agent-tty is a symlink" ""
att_root_case att-root-made : "" 700
att_root_case att-root-own-700 'mkdir -m 700 /tmp/agent-tty' "" 700
att_root_case att-root-own-755 'mkdir -m 755 /tmp/agent-tty' "" 755
# The dir is safe, but /tmp is not sticky, so another user could rename it. TMPDIR and VERIFY_OUT sit in a dir of their own, so
# only the check of the dirs above /tmp/agent-tty can refuse.
att_root_case att-root-nosticky 'mkdir -m 700 /tmp/agent-tty' "/tmp, above the agent-tty socket dir, is writable by others and not sticky" "" \
  --perms 0777 --tmpfs /tmp --dir /run/t --setenv TMPDIR /run/t --setenv VERIFY_OUT /run/o
# A newline at the end of a name is cut by a command substitution. The resolved TMPDIR is a dir with a newline at the end of its
# name and mode 777, and a twin symlink without the newline leads to a safe dir: a launch that cuts the newline would take the twin.
mkdir -m 700 "$TMP/nl" "$TMP/nl/safe"
mkdir -m 777 "$TMP/nl/q"$'\n'
ln -s "$TMP/nl/safe" "$TMP/nl/q"
ln -s "$TMP/nl/q"$'\n' "$TMP/nl/ln"
refused tmp-newline-loose "refusing TMPDIR: $TMP/nl/q"$'\n'", above the state dir, is writable by others and not sticky" \
  TMPDIR="$TMP/nl/ln" VERIFY_OUT="$TMP/tmp-out"
# The same names the other way round: this user's symlink and safe dir end in a newline, and the twins without it are loose.
# launch must reach mktemp with the whole resolved path, so it read both the path as given and the resolved path whole.
mkdir -m 700 "$TMP/nk" "$TMP/nk/t"$'\n'
mkdir -m 777 "$TMP/nk/t" "$TMP/nk/ln"
ln -s "$TMP/nk/t"$'\n' "$TMP/nk/ln"$'\n'
refused tmp-newline-ok "mktemp shim: template=$TMP/nk/t"$'\n'"/vcn.XXXXXX" PATH="$TMP/mktemp-bin:$PATH" \
  TMPDIR="$TMP/nk/ln"$'\n' VERIFY_OUT="$TMP/tmp-out"
# load refuses a state dir that is not its own resolved path. mktemp answers with a // here, so it refuses the new one at its
# first call, before launch has any teardown. Launch must remove the state dir and the evidence dir it made.
mkdir -m 700 "$TMP/tmp-slash" "$TMP/mktemp-slash"
printf '#!/bin/sh\nd=$("%s" "$@") || exit 1\nprintf "%%s//%%s\\n" "$(dirname "$d")" "$(basename "$d")"\n' "$(command -v mktemp)" >"$TMP/mktemp-slash/mktemp"
chmod +x "$TMP/mktemp-slash/mktemp"
refused tmp-load-refused "it is not its own resolved path (" PATH="$TMP/mktemp-slash:$PATH" TMPDIR="$TMP/tmp-slash" VERIFY_OUT="$TMP/tmp-out"
# A twin symlink with the name cut at the trailing space sits next to it: a walk that read the name back from a line of
# stat output tested the twin and passed it.
mkdir -m 700 "$TMP/sp"
mkdir -m 777 "$TMP/sp/q "
ln -s "$TMP/sp" "$TMP/sp/q"
mkdir -m 700 "$TMP/sp/q /tmp" "$TMP/sp/q /out-parent"
refused tmp-space "TMPDIR: $TMP/sp/q , above the state dir, is writable by others and not sticky" \
  TMPDIR="$TMP/sp/q /tmp" VERIFY_OUT="$TMP/tmp-out"
refused out-space "refusing evidence dir: $TMP/sp/q , above the evidence dir, is writable by others and not sticky" \
  VERIFY_OUT="$TMP/sp/q /out-parent/out"
# The dirs above VERIFY_OUT are walked as given and as resolved. Each chain has a case that only it can refuse. The first
# case has a clean chain as given (a symlink that this user owns, then dirs that only this user can write). The second has a
# clean chain as resolved, but the dir that holds the symlink lets another user point the symlink elsewhere.
mkdir -m 700 "$TMP/ch" "$TMP/ch/safe"
mkdir -m 777 "$TMP/ch/loose" "$TMP/ch/loose2"
ln -s "$TMP/ch/loose" "$TMP/ch/to-loose"
ln -s "$TMP/ch/safe" "$TMP/ch/loose2/to-safe"
refused out-above-resolved "$TMP/ch/loose, above the evidence dir, is writable by others and not sticky" \
  VERIFY_OUT="$TMP/ch/to-loose/out"
refused out-above-logical "$TMP/ch/loose2, above the evidence dir, is writable by others and not sticky" \
  VERIFY_OUT="$TMP/ch/loose2/to-safe/out"
refused out-uncreatable "cannot create /proc/vcn-proof" VERIFY_OUT=/proc/vcn-proof
: >"$TMP/out-file"
refused out-file "$TMP/out-file is not a directory" VERIFY_OUT="$TMP/out-file"
refused parent-uncreatable "cannot create /proc/verify-claudecode-nvim/" XUM_SCRATCH_DIR=/proc
# A tool that is found but cannot run, as a mise shim cannot in a checkout that mise does not trust, stops launch at once and
# is named. The stand-in mise names only the real node and agent-tty, so `mise which` fails for the other tools, as it does
# there, and only the stand-in under test cannot run.
real_node=$(mise which node 2>/dev/null || command -v node) || fail "tool: no node to use"
real_att=$(command -v agent-tty || mise which agent-tty) || fail "tool: no agent-tty to use"
real_nvim=$(mise which nvim 2>/dev/null || command -v nvim) || fail "tool: no nvim to use"
for dead in nvim jq node setsid; do
  mkdir "$TMP/dead-$dead"
  {
    printf '#!/bin/sh\ncase "$*" in\n'
    [[ $dead == node ]] || printf '"which node") echo "%s" ;;\n' "$real_node"
    printf '"which agent-tty") echo "%s" ;;\n*) exit 1 ;;\nesac\n' "$real_att"
  } >"$TMP/dead-$dead/mise"
  printf '#!/bin/sh\necho "mise ERROR stand-in %s cannot run" >&2\nexit 1\n' "$dead" >"$TMP/dead-$dead/$dead"
  chmod +x "$TMP/dead-$dead/mise" "$TMP/dead-$dead/$dead"
done
refused tool-nvim "nvim at $TMP/dead-nvim/nvim does not run: mise ERROR stand-in nvim cannot run" PATH="$TMP/dead-nvim:$PATH"
[[ $err == *"Put a working nvim earlier on PATH."* ]] || fail "tool-nvim: the advice does not say to put a working nvim earlier on PATH: $err"
refused tool-vcn-nvim "nvim at $TMP/dead-nvim/nvim does not run: mise ERROR stand-in nvim cannot run" VCN_NVIM="$TMP/dead-nvim/nvim"
[[ $err == *"Set VCN_NVIM to a Neovim that runs."* ]] || fail "tool-vcn-nvim: the advice does not name VCN_NVIM: $err"
refused tool-jq "jq at $TMP/dead-jq/jq does not run: mise ERROR stand-in jq cannot run" PATH="$TMP/dead-jq:$PATH" VCN_NVIM="$real_nvim"
refused tool-node "node at $TMP/dead-node/node does not run: mise ERROR stand-in node cannot run" PATH="$TMP/dead-node:$PATH" VCN_NVIM="$real_nvim"
refused tool-setsid "setsid at $TMP/dead-setsid/setsid does not run: mise ERROR stand-in setsid cannot run" \
  PATH="$TMP/dead-setsid:$PATH" VCN_NVIM="$real_nvim"
# Only launch checks a tool, so a run that exists can always be cleaned up. A run.env without JQ_BIN makes cleanup resolve jq
# again, and here that jq cannot run: cleanup must still exit 0 and leave nothing, as it does on main. A cleanup that refuses
# leaves its run, so the case stops that run with a working jq before it fails.
name=old-run-cleanup rc=0
err=$(env -u VERIFY_OUT -u XUM_SCRATCH_DIR VCN_NVIM="$real_nvim" VERIFY_OUT="$TMP/old-run-out" "$V" launch 2>&1) || fail "$name: launch failed: $err"
state=$(sed -n 's/^VCN_STATE=//p' <<<"$err")
sed -i '/^JQ_BIN=/d' "$state/run.env"
err=$(env PATH="$TMP/dead-jq:$PATH" VCN_STATE="$state" "$V" cleanup 2>&1) || rc=$?
pids=$(grep -lzxF "VCN_RUN_TAG=$state" /proc/[0-9]*/environ 2>/dev/null | cut -d/ -f3 || true)
left=0
[[ ! -e $state ]] || left=1
((left == 0)) || VCN_STATE=$state "$V" cleanup >/dev/null 2>&1 || true
((rc == 0)) || fail "$name: cleanup exited $rc, wanted 0: $err"
[[ -z $pids ]] || fail "$name: processes tagged $state are still alive: $(tr '\n' ' ' <<<"$pids")"
((left == 0)) || fail "$name: $state is still there"
echo "PASS $name: cleanup of a run without JQ_BIN, with a jq that cannot run, exited 0 and left no process and no state dir"
# Launch records its setsid in run.env, and connect uses it: a setsid that cannot run first on PATH does not break the run. The
# second check drops SETSID_BIN from run.env, as an older vcn.sh wrote it: connect resolves setsid again, and connect and cleanup
# still work. The case runs cleanup with a working PATH at the end, whatever happened, so that it leaves no run.
name=connect-setsid why=""
err=$(env -u VERIFY_OUT -u XUM_SCRATCH_DIR VCN_NVIM="$real_nvim" VERIFY_OUT="$TMP/connect-out" "$V" launch 2>&1) || fail "$name: launch failed: $err"
state=$(sed -n 's/^VCN_STATE=//p' <<<"$err")
rc=0
err=$(env PATH="$TMP/dead-setsid:$PATH" VCN_STATE="$state" VCN_CLIENT=b "$V" connect 2>&1) || rc=$?
((rc == 0)) || why="connect with a setsid that cannot run first on PATH exited $rc: $err"
sed -i '/^SETSID_BIN=/d' "$state/run.env"
rc=0
err=$(env VCN_STATE="$state" VCN_CLIENT=c "$V" connect 2>&1) || rc=$?
((rc == 0)) || why="${why:+$why, }connect on a run.env without SETSID_BIN exited $rc: $err"
rc=0
err=$(env VCN_STATE="$state" "$V" cleanup 2>&1) || rc=$?
pids=$(grep -lzxF "VCN_RUN_TAG=$state" /proc/[0-9]*/environ 2>/dev/null | cut -d/ -f3 || true)
((rc == 0)) || why="${why:+$why, }cleanup of the run exited $rc: $err"
[[ -z $pids ]] || why="${why:+$why, }processes tagged $state are still alive: $(tr '\n' ' ' <<<"$pids")"
[[ ! -e $state ]] || why="${why:+$why, }$state is still there"
[[ -z $why ]] || fail "$name: $why"
echo "PASS $name: connect started a client with a setsid that cannot run first on PATH, and again on a run.env without SETSID_BIN, and cleanup left nothing"
# A run.env without SETSID_BIN (an older vcn.sh wrote it) has no setsid to run. Only connect resolves one, so a setsid that
# cannot run first on PATH, or a PATH with none, must stop neither get nor cleanup. get checks the first, because it leaves
# the run for the second. The PATH with no setsid holds links to everything in /usr/bin (and /bin, where that is another
# dir) but setsid. A cleanup that refuses leaves its run, so the case stops that run with a working PATH before it fails.
name=old-run-setsid why=""
err=$(env -u VERIFY_OUT -u XUM_SCRATCH_DIR VCN_NVIM="$real_nvim" VERIFY_OUT="$TMP/old-setsid-out" "$V" launch 2>&1) || fail "$name: launch failed: $err"
state=$(sed -n 's/^VCN_STATE=//p' <<<"$err")
sed -i '/^SETSID_BIN=/d' "$state/run.env"
mkdir "$TMP/no-setsid"
ln -sf -t "$TMP/no-setsid" /usr/bin/*
[[ -L /bin ]] || ln -sf -t "$TMP/no-setsid" /bin/*
rm "$TMP/no-setsid/setsid"
rc=0
err=$(env PATH="$TMP/dead-setsid:$PATH" VCN_STATE="$state" "$V" get PORT 2>&1) || rc=$?
((rc == 0)) || why="get with a setsid that cannot run first on PATH exited $rc: $err"
rc=0
err=$(env PATH="$TMP/no-setsid" VCN_STATE="$state" "$V" cleanup 2>&1) || rc=$?
pids=$(grep -lzxF "VCN_RUN_TAG=$state" /proc/[0-9]*/environ 2>/dev/null | cut -d/ -f3 || true)
left=0
[[ ! -e $state ]] || left=1
((left == 0)) || VCN_STATE=$state "$V" cleanup >/dev/null 2>&1 || true
((rc == 0)) || why="${why:+$why, }cleanup on a PATH with no setsid exited $rc: $err"
[[ -z $pids ]] || why="${why:+$why, }processes tagged $state are still alive: $(tr '\n' ' ' <<<"$pids")"
((left == 0)) || why="${why:+$why, }$state is still there"
[[ -z $why ]] || fail "$name: $why"
echo "PASS $name: on a run.env without SETSID_BIN, get exited 0 with a setsid that cannot run first on PATH, and cleanup exited 0 and left no process and no state dir on a PATH with no setsid"
# Two first launches can both find the default parent dir missing. The mkdir shim plays the launch that makes
# $TMP/race/mid first, and makes it unsafe, so only the check after mkdir can refuse it.
mkdir "$TMP/race" "$TMP/race-bin"
printf '#!/bin/sh\n[ "$4" = "%s" ] && "%s" -m 770 -- "$4" && echo "mkdir: File exists" >&2 && exit 1\nexec "%s" "$@"\n' \
  "$TMP/race/mid" "$(command -v mkdir)" "$(command -v mkdir)" >"$TMP/race-bin/mkdir"
chmod +x "$TMP/race-bin/mkdir"
launch race PATH="$TMP/race-bin:$PATH" VERIFY_OUT="$TMP/race/mid/out"
[[ $err == *"$TMP/race/mid, above the evidence dir, is writable by others and not sticky"* ]] ||
  fail "race: launch did not take the dir the other launch made: $err"
[[ -d $TMP/race/mid && ! -e $TMP/race/mid/out ]] ||
  fail "race: launch removed the dir the other launch made, or kept the one it made"
echo "PASS race: $err"
# A default ACL gives a new dir or file group access whatever the harness's umask 077.
mkdir "$TMP/acl"
if command -v setfacl >/dev/null && setfacl -d -m u::rwx,g::rwx,o::--- "$TMP/acl" 2>/dev/null; then
  # chmod does not touch a default ACL, so this dir passes both checks, and its files would get group access.
  mkdir -m 700 "$TMP/acl-out" "$TMP/no-setfacl"
  setfacl -d -m u::rwx,g::rwx,o::--- "$TMP/acl-out"
  printf '#!/bin/sh\nexit 1\n' >"$TMP/no-setfacl/setfacl"
  chmod +x "$TMP/no-setfacl/setfacl"
  refused out-acl-unremovable "a new file in $TMP/acl-out gets mode 660, not 600" \
    PATH="$TMP/no-setfacl:$PATH" VERIFY_OUT="$TMP/acl-out"
else
  echo "SKIP out-acl-unremovable, out-acl, out-made: setfacl cannot set a default ACL on $TMP/acl"
fi
[[ -z $(ls -A "$TMP/out") ]] || fail "a refused launch wrote into $TMP/out"

vcn=$(cd "$(dirname "$V")" && pwd)/vcn.sh
mkdir "$TMP/cwd"
err=$(cd "$TMP/cwd" && env -u XUM_SCRATCH_DIR VERIFY_OUT=-dash "$vcn" launch 2>&1) || fail "out-dash: launch failed: $err"
VCN_STATE=$(sed -n 's/^VCN_STATE=//p' <<<"$err") "$vcn" cleanup >/dev/null
[[ $(stat -c %a -- "$TMP/cwd/-dash") == 700 ]] || fail "out-dash: $TMP/cwd/-dash is not a 0700 dir"
[[ -e $TMP/cwd/-dash/session.webm ]] || fail "out-dash: cleanup from another directory did not save session.webm there"
echo "PASS out-dash: launched with VERIFY_OUT=-dash from $TMP/cwd; cleanup from $PWD saved its evidence there"

# The sticky bit stops another user from renaming a dir that this user made, so a sticky TMPDIR is safe: it is what /tmp is.
mkdir "$TMP/tmp-sticky"
chmod 1777 "$TMP/tmp-sticky"
[[ $(stat -c %a -- "$TMP/tmp-sticky") == 1777 ]] || fail "tmp-sticky: cannot make $TMP/tmp-sticky 1777"
err=$(env -u XUM_SCRATCH_DIR TMPDIR="$TMP/tmp-sticky" VERIFY_OUT="$TMP/tmp-sticky-out" "$vcn" launch 2>&1) || fail "tmp-sticky: launch failed: $err"
state=$(sed -n 's/^VCN_STATE=//p' <<<"$err")
VCN_STATE=$state "$vcn" cleanup >/dev/null
[[ $state == "$TMP/tmp-sticky"/vcn.* ]] || fail "tmp-sticky: launch made its state dir $state outside TMPDIR"
echo "PASS tmp-sticky: launch made its state dir in the sticky $TMP/tmp-sticky"
ln -s "$TMP/tmp-sticky" "$TMP/tmp-link"
err=$(env -u XUM_SCRATCH_DIR TMPDIR="$TMP/tmp-link" VERIFY_OUT="$TMP/tmp-link-out" "$vcn" launch 2>&1) || fail "tmp-link: launch failed: $err"
state=$(sed -n 's/^VCN_STATE=//p' <<<"$err")
VCN_STATE=$state "$vcn" cleanup >/dev/null
[[ $state == "$TMP/tmp-sticky"/vcn.* ]] || fail "tmp-link: launch made its state dir $state, not in $TMP/tmp-sticky"
echo "PASS tmp-link: TMPDIR=$TMP/tmp-link gave the state dir $state, with no symlink in its path"
# Anyone can make an entry named vcn in a sticky TMPDIR. The walk above TMPDIR starts at TMPDIR itself, so a symlink named
# vcn that points into a dir that others can write does not change the chain that is checked.
mkdir -m 1777 "$TMP/tmp-vcnentry"
mkdir -m 777 "$TMP/vcnentry-loose"
mkdir "$TMP/vcnentry-loose/sub"
ln -s "$TMP/vcnentry-loose/sub" "$TMP/tmp-vcnentry/vcn"
err=$(env -u XUM_SCRATCH_DIR TMPDIR="$TMP/tmp-vcnentry" VERIFY_OUT="$TMP/tmp-vcnentry-out" "$vcn" launch 2>&1) || fail "tmp-vcn-entry: launch failed: $err"
state=$(sed -n 's/^VCN_STATE=//p' <<<"$err")
VCN_STATE=$state "$vcn" cleanup >/dev/null
[[ $state == "$TMP/tmp-vcnentry"/vcn.* ]] || fail "tmp-vcn-entry: launch made its state dir $state, not in $TMP/tmp-vcnentry"
echo "PASS tmp-vcn-entry: a symlink named vcn in a sticky TMPDIR did not change the checked chain"

# GNU stat prints a translated label for %F ("lien symbolique" for "symbolic link"), so a walk that compared that label
# refused a symlink above VERIFY_OUT. The shim translates the labels the way a French locale does.
mkdir -m 700 "$TMP/ll" "$TMP/ll/real" "$TMP/stat-bin"
ln -s "$TMP/ll/real" "$TMP/ll/link"
printf '#!/bin/sh\n"%s" "$@" | sed -e "s/symbolic link/lien symbolique/" -e "s/^directory$/repertoire/"\n' "$(command -v stat)" >"$TMP/stat-bin/stat"
chmod +x "$TMP/stat-bin/stat"
[[ $(PATH="$TMP/stat-bin:$PATH" stat -c %F "$TMP/ll/link") == "lien symbolique" ]] || fail "out-link-locale: the stat shim does not translate"
err=$(env -u XUM_SCRATCH_DIR PATH="$TMP/stat-bin:$PATH" VERIFY_OUT="$TMP/ll/link/out" "$vcn" launch 2>&1) || fail "out-link-locale: launch failed: $err"
state=$(sed -n 's/^VCN_STATE=//p' <<<"$err")
VCN_STATE=$state "$vcn" cleanup >/dev/null
[[ -d $TMP/ll/real/out ]] || fail "out-link-locale: launch made no evidence dir in $TMP/ll/real/out"
echo "PASS out-link-locale: launch with VERIFY_OUT=$TMP/ll/link/out worked with a stat that prints translated file types"

# private <case> <dir>: a run with VERIFY_OUT=dir works, and after cleanup dir is 0700 and holds only 0600 files.
private() {
  local name=$1 dir=$2 shared
  err=$(env -u XUM_SCRATCH_DIR VERIFY_OUT="$dir" "$vcn" launch 2>&1) || fail "$name: launch failed: $err"
  VCN_STATE=$(sed -n 's/^VCN_STATE=//p' <<<"$err") "$vcn" cleanup >/dev/null
  shared=$(find "$dir" -type f ! -perm 600 -printf '%m %P, ')
  [[ -z $shared ]] || fail "$name: evidence files that are not 0600: $shared"
  [[ -e $dir/session.webm ]] || fail "$name: cleanup did not save session.webm"
  [[ $(stat -c %a -- "$dir") == 700 ]] || fail "$name: $dir is not a 0700 dir"
}

if [[ -d $TMP/acl-out ]]; then
  # 0500 is safe too, but the owner cannot create files there until launch makes it 0700.
  chmod 500 "$TMP/acl-out"
  private out-acl "$TMP/acl-out"
  echo "PASS out-acl: launch made the 0500 $TMP/acl-out a 0700 dir without its default ACL, and all $(find "$TMP/acl-out" -type f | wc -l) evidence files are 0600"
  # A new default parent dir (XUM_SCRATCH_DIR=$TMP/acl) is made by the same code as $TMP/acl/mid.
  private out-made "$TMP/acl/mid/out"
  [[ $(stat -c %a -- "$TMP/acl/mid") == 700 ]] || fail "out-made: $TMP/acl/mid is not a 0700 dir"
  acl=$(getfacl --skip-base -- "$TMP/acl/mid" 2>/dev/null | grep -v '^#' || true)
  [[ -z $acl ]] || fail "out-made: $TMP/acl/mid keeps the ACL it inherited: $(tr '\n' ' ' <<<"$acl")"
  echo "PASS out-made: launch created $TMP/acl/mid and $TMP/acl/mid/out as 0700 without an ACL in a dir with a default ACL, and all $(find "$TMP/acl/mid/out" -type f | wc -l) evidence files are 0600"
fi

init_out=$(mktemp -d)
launch init VCN_INIT_JSONRPC=1.0 VERIFY_OUT="$init_out"
state=$(sed -n 's/^vcn: launch failed (VCN_STATE=\([^)]*\)).*/\1/p' <<<"$err")
out=$(sed -n 's/^vcn: cleanup ok, no processes left; evidence kept in //p' <<<"$err")
[[ -n $state && -n $out ]] || fail "init: launch did not start a run and tear it down: $err"
printf '%s\n' "$err" >"$out/init-refusal-launch.txt"
[[ $err == *'vcn: initialize failed: '* ]] || fail "init: launch failed at another step: $err"
jq -e 'select(.id == "init") | .jsonrpc == "1.0"' "$out/ws-out.jsonl" >/dev/null ||
  fail "init: launch did not send jsonrpc 1.0"
jq -e 'select(.id == "init") | .error.code == -32600 and .result == null' "$out/ws-in.jsonl" >/dev/null ||
  fail "init: the plugin did not answer -32600: $(cat "$out/ws-in.jsonl")"
[[ ! -e $state ]] || fail "init: $state still exists"
pids=$(grep -lzxF "VCN_RUN_TAG=$state" /proc/[0-9]*/environ 2>/dev/null | cut -d/ -f3 || true)
[[ -z $pids ]] || fail "init: processes tagged $state still alive: $pids"
echo "PASS init: launch exited 1 on the plugin's -32600 answer; $state is gone, no tagged process"
