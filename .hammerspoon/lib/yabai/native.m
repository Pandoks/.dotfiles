// Direct yabai client for Hammerspoon.
//
//   native.run(socketPath, args, timeoutMs, function(ok, stdout, stderr) end)
//
// Speaks yabai's socket protocol (see yabai/src/yabai.c): connect, send one
// length-prefixed NUL-separated argument blob, then read until yabai closes
// the connection. A reply starting with "\a" is an error message.
// I/O runs on a background GCD queue; the callback is invoked on the main
// thread exactly once. Built by lib/yabai.lua; see there for the clang line.
@import Foundation;
#import <LuaSkin/LuaSkin.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>

static LSRefTable refTable = LUA_NOREF;
static dispatch_queue_t ioQueue;

static int64_t nowMs(void) {
  return (int64_t)(clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1000000);
}

// Off the main thread. Returns YES and fills `out`, or NO and sets `err`.
// `timeoutMs` is a deadline for the whole exchange, not per read.
static BOOL exchange(const char *path, NSData *message, int timeoutMs, NSMutableData *out, NSString **err) {
  int64_t deadline = nowMs() + timeoutMs;
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) { *err = @(strerror(errno)); return NO; }
  // Hammerspoon installs no signal handlers (hammerspoon#3514): a send() to a
  // yabai that died after accept would otherwise SIGPIPE the whole app.
  int one = 1;
  if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one) != 0) {
    *err = @(strerror(errno)); close(fd); return NO;
  }
  int fdFlags = fcntl(fd, F_GETFD);
  if (fdFlags != -1) fcntl(fd, F_SETFD, fdFlags | FD_CLOEXEC); // don't leak into hs.task children

  struct sockaddr_un addr = { .sun_family = AF_UNIX };
  strlcpy(addr.sun_path, path, sizeof addr.sun_path);
  if (connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) {
    int e = errno;
    close(fd);
    *err = (e == ENOENT || e == ECONNREFUSED) ? @"could not connect to yabai socket" : @(strerror(e));
    return NO;
  }

  // A send() only blocks if the payload outgrows the 8 KB socket buffers while
  // yabai isn't reading; bound it by what is left of the deadline anyway.
  int64_t sendBudget = deadline - nowMs();
  if (sendBudget <= 0) { close(fd); *err = @"timed out"; return NO; }
  struct timeval sendTimeout = { .tv_sec = sendBudget / 1000, .tv_usec = (sendBudget % 1000) * 1000 };
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, sizeof sendTimeout);

  const char *p = message.bytes;
  size_t left = message.length;
  while (left > 0) {
    ssize_t n = send(fd, p, left, 0);
    if (n < 0) {
      if (errno == EINTR) continue;
      *err = (errno == EAGAIN || errno == EWOULDBLOCK) ? @"timed out" : @(strerror(errno));
      close(fd); return NO;
    }
    if (n == 0) { close(fd); *err = @"send made no progress"; return NO; } // unreachable for len > 0, keeps the loop obviously finite
    p += n; left -= (size_t)n;
  }
  shutdown(fd, SHUT_WR);

  char buf[8192];
  for (;;) {
    int64_t remaining = deadline - nowMs();
    if (remaining <= 0) { close(fd); *err = @"timed out"; return NO; }
    struct pollfd pfd = { .fd = fd, .events = POLLIN };
    int r = poll(&pfd, 1, (int)remaining);
    if (r == 0) { close(fd); *err = @"timed out"; return NO; }
    if (r < 0) {
      if (errno == EINTR) continue;
      *err = @(strerror(errno)); close(fd); return NO;
    }
    ssize_t n = read(fd, buf, sizeof buf);
    if (n < 0) {
      if (errno == EINTR) continue;
      *err = @(strerror(errno)); close(fd); return NO;
    }
    if (n == 0) break; // EOF: yabai fclose()d its end, reply complete
    [out appendBytes:buf length:(NSUInteger)n];
  }
  close(fd);
  return YES;
}

static int native_run(lua_State *L) {
  LuaSkin *skin = [LuaSkin sharedWithState:L];
  [skin checkArgs:LS_TSTRING, LS_TTABLE, LS_TNUMBER | LS_TINTEGER, LS_TFUNCTION, LS_TBREAK];
  size_t pathLength;
  const char *pathBytes = lua_tolstring(L, 1, &pathLength);
  luaL_argcheck(L, pathLength < sizeof(((struct sockaddr_un *)0)->sun_path), 1, "socket path too long");
  NSData *path = [NSData dataWithBytes:pathBytes length:pathLength + 1]; // keep the NUL
  int timeoutMs = (int)lua_tointeger(L, 3);
  luaL_argcheck(L, timeoutMs > 0, 3, "timeout must be > 0 ms");

  // body = arg NUL arg NUL ... NUL ; message = int32 length(body) + body
  NSMutableData *body = [NSMutableData data];
  lua_Integer count = (lua_Integer)lua_rawlen(L, 2);
  for (lua_Integer i = 1; i <= count; i++) {
    lua_rawgeti(L, 2, i);
    size_t len;
    const char *s = lua_tolstring(L, -1, &len);
    if (!s) return luaL_error(L, "args[%d] is not a string", (int)i);
    [body appendBytes:s length:len];
    [body appendBytes:"" length:1];
    lua_pop(L, 1);
  }
  [body appendBytes:"" length:1];
  int32_t length = (int32_t)body.length;
  NSMutableData *message = [NSMutableData dataWithBytes:&length length:sizeof length];
  [message appendData:body];

  lua_pushvalue(L, 4);
  int callback = [skin luaRef:refTable];
  LSGCCanary canary = [skin createGCCanary]; // detects a config reload while in flight

  dispatch_async(ioQueue, ^{
    NSMutableData *out = [NSMutableData data];
    NSString *err = nil;
    BOOL ok = exchange(path.bytes, message, timeoutMs, out, &err);

    dispatch_async(dispatch_get_main_queue(), ^{
      LuaSkin *mainSkin = [LuaSkin sharedWithState:NULL];
      if (![mainSkin checkGCCanary:canary]) return; // Lua state is gone; drop the callback
      lua_State *ML = mainSkin.L;
      _lua_stackguard_entry(ML);
      [mainSkin pushLuaRef:refTable ref:callback];
      [mainSkin luaUnref:refTable ref:callback];
      LSGCCanary c = canary;
      [mainSkin destroyGCCanary:&c];

      const char *bytes = out.bytes;
      NSUInteger len = out.length;
      if (!ok) {
        lua_pushboolean(ML, 0); lua_pushliteral(ML, ""); lua_pushstring(ML, err.UTF8String);
      } else if (len > 0 && bytes[0] == '\a') { // yabai FAILURE_MESSAGE
        lua_pushboolean(ML, 0); lua_pushliteral(ML, ""); lua_pushlstring(ML, bytes + 1, len - 1);
      } else {
        lua_pushboolean(ML, 1); lua_pushlstring(ML, bytes, len); lua_pushliteral(ML, "");
      }
      [mainSkin protectedCallAndError:@"yabai native callback" nargs:3 nresults:0];
      _lua_stackguard_exit(ML);
    });
  });
  return 0;
}

static const luaL_Reg functions[] = {
  { "run", native_run },
  { NULL, NULL },
};

int luaopen_yabai_native(lua_State *L) {
  LuaSkin *skin = [LuaSkin sharedWithState:L];
  if (!ioQueue) ioQueue = dispatch_queue_create("yabai.native.io", DISPATCH_QUEUE_CONCURRENT);
  refTable = [skin registerLibrary:"yabai_native" functions:functions metaFunctions:nil];
  return 1;
}
