#import <Foundation/Foundation.h>
#import <LuaSkin/LuaSkin.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

static LSRefTable references = LUA_NOREF;
static const char *type = "stream.listener";
// Reads off the main thread: a stalled reader would stall the writer's whole pipeline.
static dispatch_queue_t queue;

// Sockets, sources, and buffers change only on `queue`; Lua state only on main.
@interface Stream : NSObject
@property NSString *path;
@property int server, client;
@property dispatch_source_t listener, reader;
@property NSMutableData *pending;
@property NSString *error;
@property BOOL scheduled, closed;
@property int callback;
@property LSGCCanary canary;
@end

@implementation Stream
- (void)fail:(NSString *)action {
  if (!self.error) self.error = [NSString stringWithFormat:@"could not %@ the stream: %s", action, strerror(errno)];
}

- (void)accept {
  int client = accept(self.server, NULL, NULL);
  if (client < 0 && (errno == EAGAIN || errno == EINTR || errno == ECONNABORTED)) return;
  if (client < 0) [self fail:@"accept"];
  // One writer, or none after an error: no one else can connect.
  dispatch_source_cancel(self.listener);
  self.listener = nil;
  self.server = -1;
  unlink(self.path.fileSystemRepresentation);
  self.path = nil;
  if (client < 0) return;
  if (fcntl(client, F_SETFD, FD_CLOEXEC) < 0 || fcntl(client, F_SETFL, O_NONBLOCK) < 0) {
    [self fail:@"configure"];
    close(client);
    return;
  }
  self.client = client;
  self.reader = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)client, 0, queue);
  dispatch_source_set_event_handler(self.reader, ^{
    [self read];
    if (self.pending.length || self.error) [self schedule];
  });
  dispatch_source_set_cancel_handler(self.reader, ^{ close(client); });
  dispatch_resume(self.reader);
}

// Everything buffered; stops at the writer's end or an error.
- (void)read {
  uint8_t buffer[16384];
  while (self.client >= 0) {
    ssize_t count = read(self.client, buffer, sizeof buffer);
    if (count > 0) {
      [self.pending appendBytes:buffer length:(NSUInteger)count];
      continue;
    } else if (count < 0 && errno == EINTR) {
      continue;
    } else if (count < 0 && errno == EAGAIN) {
      return;
    } else if (count < 0) {
      [self fail:@"read"];
    }
    dispatch_source_cancel(self.reader);
    self.reader = nil;
    self.client = -1;
  }
}

- (void)schedule {
  if (self.scheduled) return;
  self.scheduled = YES;
  dispatch_async(dispatch_get_main_queue(), ^{ [self deliver]; });
}

- (void)deliver {
  __block NSData *chunk;
  __block NSString *error;
  dispatch_sync(queue, ^{
    self.scheduled = NO;
    if (self.closed) return;
    chunk = [self.pending copy];
    self.pending.length = 0;
    error = self.error;
    self.error = nil;
  });
  if (chunk.length) [self call:chunk error:nil];
  if (error && [self call:nil error:error]) [self finish:nil];
}

- (BOOL)call:(NSData *)chunk error:(NSString *)error {
  LuaSkin *skin = [LuaSkin sharedWithState:NULL];
  if (self.closed || ![skin checkGCCanary:self.canary]) return NO;
  lua_State *state = skin.L;
  _lua_stackguard_entry(state);
  [skin pushLuaRef:references ref:self.callback];
  if (chunk) lua_pushlstring(state, chunk.bytes, chunk.length);
  else lua_pushnil(state);
  if (error) lua_pushstring(state, error.UTF8String);
  else lua_pushnil(state);
  [skin protectedCallAndError:@"stream callback" nargs:2 nresults:0];
  _lua_stackguard_exit(state);
  return YES;
}

// Accepts a waiting writer and drains it: the bytes not yet delivered, and any error not yet raised.
- (NSData *)finish:(NSString **)error {
  __block NSData *rest;
  __block NSString *problem;
  dispatch_sync(queue, ^{
    if (self.closed) return;
    self.closed = YES;
    if (self.listener) [self accept];
    [self read];
    if (self.listener) dispatch_source_cancel(self.listener);
    if (self.reader) dispatch_source_cancel(self.reader);
    if (self.path) unlink(self.path.fileSystemRepresentation);
    self.listener = self.reader = nil;
    self.path = nil;
    rest = self.pending;
    self.pending = nil;
    problem = self.error;
  });
  if (error) *error = problem;
  if (!rest) return nil; // already closed
  LuaSkin *skin = [LuaSkin sharedWithState:NULL];
  if ([skin checkGCCanary:self.canary]) {
    [skin luaUnref:references ref:self.callback];
    LSGCCanary canary = self.canary;
    [skin destroyGCCanary:&canary];
  }
  return rest;
}
@end

static int collect(lua_State *state) {
  void **userdata = luaL_checkudata(state, 1, type);
  if (*userdata) {
    [(__bridge_transfer Stream *)*userdata finish:nil];
    *userdata = NULL;
  }
  return 0;
}

static int stop(lua_State *state) {
  void **userdata = luaL_checkudata(state, lua_upvalueindex(1), type);
  NSString *error;
  NSData *rest = *userdata ? [(__bridge Stream *)*userdata finish:&error] : nil;
  lua_pushlstring(state, rest ? rest.bytes : "", rest.length);
  if (error) lua_pushstring(state, error.UTF8String);
  else lua_pushnil(state);
  return 2;
}

static int serve(lua_State *state) {
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  [skin checkArgs:LS_TSTRING, LS_TFUNCTION, LS_TBREAK];
  struct sockaddr_un address = { .sun_family = AF_UNIX };
  if (strlcpy(address.sun_path, lua_tostring(state, 1), sizeof address.sun_path) >= sizeof address.sun_path) {
    lua_pushnil(state);
    lua_pushliteral(state, "socket path is too long");
    return 2;
  }
  // Owner-only, and closed in children such as the writer itself.
  int server = socket(AF_UNIX, SOCK_STREAM, 0);
  BOOL bound = NO;
  if (server < 0 || fcntl(server, F_SETFD, FD_CLOEXEC) < 0 || fcntl(server, F_SETFL, O_NONBLOCK) < 0
      || !(bound = bind(server, (struct sockaddr *)&address, sizeof address) == 0)
      || chmod(address.sun_path, 0600) < 0 || listen(server, 1) < 0) {
    int failure = errno;
    if (bound) unlink(address.sun_path);
    if (server >= 0) close(server);
    lua_pushnil(state);
    lua_pushfstring(state, "could not listen on %s: %s", address.sun_path, strerror(failure));
    return 2;
  }
  Stream *stream = [Stream new];
  stream.path = @(address.sun_path);
  stream.server = server;
  stream.client = -1;
  stream.pending = [NSMutableData new];
  stream.canary = [skin createGCCanary];
  lua_pushvalue(state, 2);
  stream.callback = [skin luaRef:references];
  stream.listener = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)server, 0, queue);
  dispatch_source_set_event_handler(stream.listener, ^{
    [stream accept];
    if (stream.error) [stream schedule];
  });
  dispatch_source_set_cancel_handler(stream.listener, ^{ close(server); });
  dispatch_resume(stream.listener);
  void **userdata = lua_newuserdata(state, sizeof(void *));
  *userdata = (__bridge_retained void *)stream;
  luaL_setmetatable(state, type);
  lua_pushcclosure(state, stop, 1);
  return 1;
}

static const luaL_Reg functions[] = {
  { "listen", serve },
  { NULL, NULL },
};

int luaopen_stream(lua_State *state) {
  // Keep queued blocks executable when Lua unloads modules during reload.
  static void *image;
  if (!image) {
    Dl_info info;
    if (!dladdr(&references, &info) || !(image = dlopen(info.dli_fname, RTLD_NOW | RTLD_LOCAL))) {
      return luaL_error(state, "could not retain stream library");
    }
  }
  if (!queue) {
    queue = dispatch_queue_create("stream.read", dispatch_queue_attr_make_with_qos_class(
      DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
  }
  luaL_newmetatable(state, type);
  lua_pushcfunction(state, collect);
  lua_setfield(state, -2, "__gc");
  lua_pop(state, 1);
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  references = [skin registerLibrary:"stream" functions:functions metaFunctions:nil];
  return 1;
}
