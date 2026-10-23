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
  NSString *_path;
  os_unfair_lock _lock;
}

// Opens by path each time so a removed directory is recreated.
- (int)directory:(NSError **)error {
  NSString *path = _path.stringByDeletingLastPathComponent;
  if (mkdir(path.fileSystemRepresentation, 0700) != 0 && errno != EEXIST) {
    failure(error, [@"Could not create status directory: " stringByAppendingString:@(strerror(errno))]);
    return -1;
  }
  int directory = open(path.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  struct stat status;
  if (directory < 0 || fstat(directory, &status) || !S_ISDIR(status.st_mode)
      || status.st_uid != getuid() || (status.st_mode & 0077)) {
    if (directory >= 0) close(directory);
    failure(error, @"Status directory must be owned by this user with permissions 0700");
    return -1;
  }
  return directory;
}

- (instancetype)initWithPath:(NSString *)path error:(NSError **)error {
  if (!(self = [super init])) return nil;
  _lock = OS_UNFAIR_LOCK_INIT;
  _path = [path copy];
  int directory = [self directory:error];
  if (directory < 0) return nil;
  close(directory);
  return self;
}

- (BOOL)write:(NSDictionary *)event error:(NSError **)error {
  NSData *data = [NSJSONSerialization dataWithJSONObject:event options:NSJSONWritingSortedKeys error:error];
  if (!data) return NO;
  NSString *temporary = [@".status-" stringByAppendingString:NSUUID.UUID.UUIDString];
  os_unfair_lock_lock(&_lock);
  int directory = [self directory:error];
  if (directory < 0) {
    os_unfair_lock_unlock(&_lock);
    return NO;
  }
  int file = openat(directory, temporary.fileSystemRepresentation,
    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (file < 0) {
    int saved = errno;
    close(directory);
    os_unfair_lock_unlock(&_lock);
    return failure(error, [@"Could not create status file: " stringByAppendingString:@(strerror(saved))]);
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
  if (success) success = renameat(directory, temporary.fileSystemRepresentation,
    directory, _path.lastPathComponent.fileSystemRepresentation) == 0;
  int saved = errno;
  if (!success) unlinkat(directory, temporary.fileSystemRepresentation, 0);
  close(directory);
  os_unfair_lock_unlock(&_lock);
  return success ?: failure(error, [@"Could not publish status: " stringByAppendingString:@(strerror(saved))]);
}
@end
