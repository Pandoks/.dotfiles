#import <Foundation/Foundation.h>
#import <LuaSkin/LuaSkin.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <libproc.h>
#include <signal.h>
#include <sys/stat.h>
#include <unistd.h>

static LSRefTable references = LUA_NOREF;
static const char *watcherType = "url_router.watcher";

@interface RouterWatcher : NSObject
@property dispatch_source_t source;
@property int callback;
@property LSGCCanary canary;
@property BOOL active;
- (void)stop;
- (void)notify:(NSString *)error;
@end

@implementation RouterWatcher
- (void)stop {
  if (!self.active) return;
  self.active = NO;
  dispatch_source_cancel(self.source);
  self.source = nil;
  LuaSkin *skin = [LuaSkin sharedWithState:NULL];
  if ([skin checkGCCanary:self.canary]) {
    [skin luaUnref:references ref:self.callback];
    LSGCCanary canary = self.canary;
    [skin destroyGCCanary:&canary];
  }
}
- (void)notify:(NSString *)error {
  LuaSkin *skin = [LuaSkin sharedWithState:NULL];
  if (!self.active || ![skin checkGCCanary:self.canary]) return;
  lua_State *state = skin.L;
  _lua_stackguard_entry(state);
  [skin pushLuaRef:references ref:self.callback];
  if (error) lua_pushstring(state, error.UTF8String);
  else lua_pushnil(state);
  [skin protectedCallAndError:@"URL router status" nargs:1 nresults:0];
  _lua_stackguard_exit(state);
  if (error) [self stop];
}
@end

static int collect(lua_State *state) {
  void **userdata = luaL_checkudata(state, 1, watcherType);
  if (*userdata) {
    RouterWatcher *watcher = (__bridge_transfer RouterWatcher *)*userdata;
    [watcher stop];
    *userdata = NULL;
  }
  return 0;
}

static int stop(lua_State *state) {
  void **userdata = luaL_checkudata(state, lua_upvalueindex(1), watcherType);
  if (*userdata) [(__bridge RouterWatcher *)*userdata stop];
  return 0;
}

static void retainWatcher(lua_State *state, RouterWatcher *watcher) {
  void **userdata = lua_newuserdata(state, sizeof(void *));
  *userdata = (__bridge_retained void *)watcher;
  luaL_getmetatable(state, watcherType);
  lua_setmetatable(state, -2);
  lua_pushcclosure(state, stop, 1);
}

static int watch(lua_State *state) {
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  [skin checkArgs:LS_TSTRING, LS_TFUNCTION, LS_TBREAK];
  NSString *path = [skin toNSObjectAtIndex:1];
  NSString *parent = path.stringByDeletingLastPathComponent;
  if (mkdir(parent.fileSystemRepresentation, 0700) != 0 && errno != EEXIST) {
    lua_pushnil(state); lua_pushstring(state, strerror(errno)); return 2;
  }
  int directory = open(parent.fileSystemRepresentation,
                       O_EVTONLY | O_CLOEXEC | O_NOFOLLOW);
  if (directory < 0) {
    lua_pushnil(state); lua_pushstring(state, strerror(errno)); return 2;
  }
  dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE,
    (uintptr_t)directory, DISPATCH_VNODE_WRITE | DISPATCH_VNODE_DELETE |
    DISPATCH_VNODE_RENAME | DISPATCH_VNODE_REVOKE, dispatch_get_main_queue());
  if (!source) {
    close(directory); lua_pushnil(state);
    lua_pushliteral(state, "could not watch the status directory"); return 2;
  }
  RouterWatcher *watcher = [RouterWatcher new];
  watcher.source = source;
  watcher.active = YES;
  watcher.canary = [skin createGCCanary];
  lua_pushvalue(state, 2);
  watcher.callback = [skin luaRef:references];
  __weak RouterWatcher *weak = watcher;
  dispatch_source_set_event_handler(source, ^{
    RouterWatcher *current = weak;
    if (!current.active) return;
    unsigned long flags = dispatch_source_get_data(current.source);
    [current notify:flags & (DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_REVOKE)
      ? @"status directory was removed or replaced" : nil];
  });
  dispatch_source_set_cancel_handler(source, ^{ close(directory); });
  dispatch_resume(source);
  retainWatcher(state, watcher);
  return 1;
}

static int process(lua_State *state) {
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  [skin checkArgs:LS_TNUMBER | LS_TINTEGER, LS_TSTRING, LS_TFUNCTION, LS_TBREAK];
  lua_Integer pid = lua_tointeger(state, 1);
  luaL_argcheck(state, pid > 0 && pid <= INT_MAX, 1, "invalid process ID");
  char executable[PROC_PIDPATHINFO_MAXSIZE];
  NSString *path = [skin toNSObjectAtIndex:2];
  if (kill((pid_t)pid, 0) != 0 || proc_pidpath((int)pid, executable, sizeof executable) <= 0 ||
      strcmp(executable, path.fileSystemRepresentation) != 0) {
    lua_pushnil(state); lua_pushliteral(state, "interception process is missing or has a different executable");
    return 2;
  }
  dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC,
    (uintptr_t)pid, DISPATCH_PROC_EXIT, dispatch_get_main_queue());
  if (!source) {
    lua_pushnil(state); lua_pushliteral(state, "could not watch interception process"); return 2;
  }
  RouterWatcher *watcher = [RouterWatcher new];
  watcher.source = source;
  watcher.active = YES;
  watcher.canary = [skin createGCCanary];
  lua_pushvalue(state, 3);
  watcher.callback = [skin luaRef:references];
  __weak RouterWatcher *weak = watcher;
  dispatch_source_set_event_handler(source, ^{
    [weak notify:@"Universal Link interception process exited"];
  });
  dispatch_resume(source);
  retainWatcher(state, watcher);
  return 1;
}

static int readFile(lua_State *state) {
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  [skin checkArgs:LS_TSTRING, LS_TBREAK];
  NSString *path = [skin toNSObjectAtIndex:1];
  int file = open(path.fileSystemRepresentation, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW);
  int failure = file < 0 ? errno : 0;
  struct stat before, after;
  if (!failure && fstat(file, &before) != 0) failure = errno;
  NSString *message;
  if (!failure && (!S_ISREG(before.st_mode) || before.st_uid != getuid()
      || (before.st_mode & 0022) || before.st_size <= 0 || before.st_size > 1024 * 1024)) {
    failure = EINVAL;
    message = @"Expected a user-owned regular router file of at most 1 MiB, not writable by others";
  }
  NSMutableData *data = failure ? nil : [NSMutableData dataWithLength:(NSUInteger)before.st_size];
  size_t offset = 0;
  while (!failure && offset < data.length) {
    ssize_t count = pread(file, (char *)data.mutableBytes + offset, data.length - offset, (off_t)offset);
    if (count < 0 && errno == EINTR) continue;
    if (count < 0) failure = errno;
    else if (!count) failure = EIO;
    else offset += (size_t)count;
  }
  if (!failure && fstat(file, &after) != 0) failure = errno;
  if (!failure && (before.st_size != after.st_size
      || before.st_mtimespec.tv_sec != after.st_mtimespec.tv_sec
      || before.st_mtimespec.tv_nsec != after.st_mtimespec.tv_nsec)) {
    failure = EAGAIN;
    message = @"The router file changed while reading; publish replacements atomically";
  }
  if (file >= 0) close(file);
  if (failure) {
    lua_pushnil(state);
    lua_pushstring(state, message ? message.UTF8String : strerror(failure));
    lua_pushinteger(state, failure);
    return 3;
  }
  lua_pushlstring(state, data.bytes, data.length);
  return 1;
}

static int publish(lua_State *state) {
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  [skin checkArgs:LS_TSTRING, LS_TSTRING, LS_TBREAK];
  NSString *path = [skin toNSObjectAtIndex:1];
  size_t size;
  const char *contents = lua_tolstring(state, 2, &size);
  if (size == 0 || size > 1024 * 1024) {
    lua_pushboolean(state, NO);
    lua_pushliteral(state, "selectors must contain at most 1 MiB"); return 2;
  }
  char *temporary = strdup([[path stringByAppendingString:@".XXXXXX"] fileSystemRepresentation]);
  if (!temporary) return luaL_error(state, "could not allocate selector path");
  int file = mkstemp(temporary), failure = file < 0 ? errno : 0;
  if (!failure && (fcntl(file, F_SETFD, FD_CLOEXEC) < 0 || fchmod(file, 0600) < 0)) failure = errno;
  size_t written = 0;
  while (!failure && written < size) {
    ssize_t count = write(file, contents + written, size - written);
    if (count <= 0) failure = count < 0 ? errno : EIO;
    else written += (size_t)count;
  }
  if (!failure && fsync(file) != 0) failure = errno;
  if (file >= 0 && close(file) != 0 && !failure) failure = errno;
  if (!failure && rename(temporary, path.fileSystemRepresentation) != 0) failure = errno;
  if (failure) unlink(temporary);
  free(temporary);
  lua_pushboolean(state, failure == 0);
  if (failure) lua_pushstring(state, strerror(failure));
  else lua_pushnil(state);
  return 2;
}

static const luaL_Reg functions[] = {
  { "watch", watch }, { "process", process }, { "publish", publish }, { "read", readFile }, { NULL, NULL },
};

int luaopen_url_router(lua_State *state) {
  // Dispatch cancellation handlers outlive Lua's loadlib handles on reload.
  static void *image;
  if (!image) {
    Dl_info info;
    if (!dladdr(&references, &info) || !(image = dlopen(info.dli_fname, RTLD_NOW | RTLD_LOCAL)))
      return luaL_error(state, "could not retain native URL router callbacks");
  }
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  luaL_newmetatable(state, watcherType);
  lua_pushcfunction(state, collect); lua_setfield(state, -2, "__gc");
  lua_pop(state, 1);
  references = [skin registerLibrary:"url_router" functions:functions metaFunctions:nil];
  return 1;
}
