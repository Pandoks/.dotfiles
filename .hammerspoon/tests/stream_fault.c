// Inserted into the stream test to fail a socket read, which no writer can cause.
#include <errno.h>
#include <stdatomic.h>
#include <sys/stat.h>
#include <unistd.h>

// 1: fail the socket read after the next one that returns bytes.
atomic_int armed;

static ssize_t faulty(int fd, void *buffer, size_t size) {
  struct stat info;
  if (!atomic_load(&armed) || fstat(fd, &info) != 0 || !S_ISSOCK(info.st_mode)) {
    return read(fd, buffer, size);
  }
  if (atomic_load(&armed) == 2) {
    atomic_store(&armed, 0);
    errno = EIO;
    return -1;
  }
  ssize_t count = read(fd, buffer, size);
  if (count > 0) atomic_store(&armed, 2);
  return count;
}

// dyld swaps calls to `read` in other images for `faulty`.
__attribute__((used, section("__DATA,__interpose"))) static const struct {
  const void *replacement, *replacee;
} interpose = { (const void *)(unsigned long)&faulty, (const void *)(unsigned long)&read };
