#ifndef CPIPE2_H
#define CPIPE2_H

/// pipe2(O_CLOEXEC): both ends are close-on-exec before any concurrent spawn can inherit them.
int cpipe2_cloexec(int fds[2]);

/// Whether the Linux pid_t (a signed int) has terminated without collecting it.
/// Blocks if requested; returns 1 terminated, 0 still running, or -1 with errno set.
int cpipe2_has_exited(int pid, int block);

/// Bytes waiting in the pipe fd, or -1.
int cpipe2_pending(int fd);

#endif
