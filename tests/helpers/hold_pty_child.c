/* LD_PRELOAD shim for tests: holds the forked children of Neovim inside the signal(SIGCHLD, SIG_DFL) call that they
 * make first. The child of a pty job is the case that matters: Neovim forks it with its own signal handlers, and
 * init_child() runs setsid() and then resets the handlers with signal(). Until then the child is a copy of Neovim, and
 * a hangup that reaches it ends Neovim ("Caught deadly signal 'SIGHUP'"). The shim waits for HOLD_PTY_CHILD_US
 * microseconds (default 400000), so a test can close a job while its child is in that window. It holds every fork of
 * Neovim that makes that call, not only the child of a pty job: libuv's uv_spawn children wait too, such as each `ps`
 * that nvim_get_proc starts where /proc is missing, so a test that times such a call reads the hold as well. When
 * HOLD_PTY_CHILD_READY names a file, a held child creates it before it waits, so the test knows that a child is held.
 * Neovim itself never waits. A hangup ends the wait early. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <unistd.h>

static pid_t main_pid;
__attribute__((constructor)) static void remember_main(void) { main_pid = getpid(); }

sighandler_t signal(int sig, sighandler_t handler) {
  static sighandler_t (*real)(int, sighandler_t);
  if (!real) real = (sighandler_t (*)(int, sighandler_t))dlsym(RTLD_NEXT, "signal");
  if (getpid() != main_pid && sig == SIGCHLD && handler == SIG_DFL) {
    const char *ready = getenv("HOLD_PTY_CHILD_READY");
    if (ready) close(open(ready, O_CREAT | O_WRONLY, 0600));
    const char *hold = getenv("HOLD_PTY_CHILD_US");
    usleep(hold ? (useconds_t)atol(hold) : 400000);
  }
  return real(sig, handler);
}
