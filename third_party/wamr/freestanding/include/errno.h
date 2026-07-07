#ifndef AGENT_OS_WAMR_ERRNO_H
#define AGENT_OS_WAMR_ERRNO_H

extern int errno;

#define EPERM 1
#define ENOENT 2
#define EIO 5
#define EBADF 9
#define EAGAIN 11
#define ENOMEM 12
#define EACCES 13
#define EFAULT 14
#define EBUSY 16
#define EEXIST 17
#define ENODEV 19
#define EINVAL 22
#define ENFILE 23
#define EMFILE 24
#define ENOSYS 38
#define ENOTEMPTY 39
#define ENOTSUP 95

#endif
