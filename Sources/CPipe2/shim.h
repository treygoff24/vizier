// Linux calls that Swift's Glibc module does not expose, or exposes unusably.
#ifndef CPIPE2_SHIM_H
#define CPIPE2_SHIM_H
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>

/// pipe2(O_CLOEXEC): both ends are close-on-exec from the first instant, so no concurrent spawn can inherit them.
static inline int cpipe2_cloexec(int fds[2]) { return pipe2(fds, O_CLOEXEC); }

/// Whether `pid` has terminated, without collecting it (waitid with WNOWAIT), retrying on EINTR.
/// Blocks until it has when `block` is nonzero. Returns 1 terminated, 0 still running (non-blocking
/// only), -1 on error (errno set; ECHILD means someone else already collected it).
static inline int cpipe2_has_exited(pid_t pid, int block) {
    for (;;) {
        siginfo_t info;
        memset(&info, 0, sizeof info);
        int options = WEXITED | WNOWAIT | (block ? 0 : WNOHANG);
        if (waitid(P_PID, (id_t)pid, &info, options) == 0) return info.si_pid == pid ? 1 : 0;
        if (errno != EINTR) return -1;
    }
}

/// Bytes waiting in the pipe `fd`, or -1.
static inline int cpipe2_pending(int fd) {
    int count = 0;
    return ioctl(fd, FIONREAD, &count) == 0 ? count : -1;
}
#endif
