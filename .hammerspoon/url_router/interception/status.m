#import "status.h"
#import <os/lock.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

static BOOL failure(NSError **error, NSString *message) {
  if (error) *error = [NSError errorWithDomain:@"HammerspoonURLRouter" code:1
    userInfo:@{NSLocalizedDescriptionKey: message}];
  return NO;
}

NSData *URLRouterReadStatus(NSString *path, NSError **error) {
  int file = open(path.fileSystemRepresentation, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW);
  int code = file < 0 ? errno : 0;
  struct stat before, after;
  if (!code && fstat(file, &before)) code = errno;
  if (!code && (!S_ISREG(before.st_mode) || before.st_uid != getuid()
      || (before.st_mode & 0022) || before.st_size <= 0 || before.st_size > 1024 * 1024)) code = EINVAL;
  NSMutableData *data = code ? nil : [NSMutableData dataWithLength:(NSUInteger)before.st_size];
  size_t offset = 0;
  while (!code && offset < data.length) {
    ssize_t count = pread(file, (char *)data.mutableBytes + offset, data.length - offset, (off_t)offset);
    if (count < 0 && errno == EINTR) continue;
    if (count < 0) code = errno;
    else if (!count) code = EIO;
    else offset += (size_t)count;
  }
  if (!code && fstat(file, &after)) code = errno;
  if (!code && (before.st_size != after.st_size
      || before.st_mtimespec.tv_sec != after.st_mtimespec.tv_sec
      || before.st_mtimespec.tv_nsec != after.st_mtimespec.tv_nsec)) code = EAGAIN;
  if (file >= 0) close(file);
  if (!code) return data;
  if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
  return nil;
}

@implementation URLRouterStatus {
  int _directory;
  NSString *_name;
  os_unfair_lock _lock;
}

- (instancetype)initWithPath:(NSString *)path error:(NSError **)error {
  if (!(self = [super init])) return nil;
  _lock = OS_UNFAIR_LOCK_INIT;
  _name = path.lastPathComponent;
  NSString *directory = path.stringByDeletingLastPathComponent;
  if (mkdir(directory.fileSystemRepresentation, 0700) != 0 && errno != EEXIST) {
    _directory = -1;
    failure(error, [@"Could not create status directory: " stringByAppendingString:@(strerror(errno))]);
    return nil;
  }
  _directory = open(directory.fileSystemRepresentation,
    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  struct stat status;
  if (_directory < 0 || fstat(_directory, &status) || !S_ISDIR(status.st_mode)
      || status.st_uid != getuid() || (status.st_mode & 0077)) {
    if (_directory >= 0) close(_directory);
    _directory = -1;
    failure(error, @"Status directory must be owned by this user with permissions 0700");
    return nil;
  }
  return self;
}

- (BOOL)write:(NSDictionary *)event error:(NSError **)error {
  NSData *data = [NSJSONSerialization dataWithJSONObject:event options:NSJSONWritingSortedKeys error:error];
  if (!data) return NO;
  NSString *temporary = [@".status-" stringByAppendingString:NSUUID.UUID.UUIDString];
  os_unfair_lock_lock(&_lock);
  int file = openat(_directory, temporary.fileSystemRepresentation,
    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (file < 0) {
    os_unfair_lock_unlock(&_lock);
    return failure(error, [@"Could not create status file: " stringByAppendingString:@(strerror(errno))]);
  }
  size_t offset = 0;
  while (offset < data.length) {
    ssize_t count = write(file, (const char *)data.bytes + offset, data.length - offset);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) break;
    offset += (size_t)count;
  }
  BOOL success = offset == data.length && close(file) == 0;
  if (offset != data.length) close(file);
  if (success) success = renameat(_directory, temporary.fileSystemRepresentation,
    _directory, _name.fileSystemRepresentation) == 0;
  int saved = errno;
  if (!success) unlinkat(_directory, temporary.fileSystemRepresentation, 0);
  os_unfair_lock_unlock(&_lock);
  return success ?: failure(error, [@"Could not publish status: " stringByAppendingString:@(strerror(saved))]);
}

- (void)dealloc {
  if (_directory >= 0) close(_directory);
}
@end
