#import <Foundation/Foundation.h>
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

static BOOL exchange(const char *socketPath, NSData *request, int timeoutMs,
                     NSMutableData *response, NSString **error) {
  // Start the deadline and open a local socket.
  int64_t deadline = nowMs() + timeoutMs;
  int socketFd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (socketFd < 0) {
    *error = @(strerror(errno));
    return NO;
  }

  // Prevent SIGPIPE and descriptor inheritance by executed child programs.
  int noSigPipe = 1;
  if (setsockopt(socketFd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof noSigPipe) != 0) {
    *error = @(strerror(errno));
    close(socketFd);
    return NO;
  }
  int descriptorFlags = fcntl(socketFd, F_GETFD);
  if (descriptorFlags != -1) {
    fcntl(socketFd, F_SETFD, descriptorFlags | FD_CLOEXEC);
  }

  // Connect to the running yabai daemon.
  struct sockaddr_un address = { .sun_family = AF_UNIX };
  strlcpy(address.sun_path, socketPath, sizeof address.sun_path);
  if (connect(socketFd, (struct sockaddr *)&address, sizeof address) != 0) {
    int errorCode = errno;
    close(socketFd);
    *error = (errorCode == ENOENT || errorCode == ECONNREFUSED)
      ? @"could not connect to yabai socket" : @(strerror(errorCode));
    return NO;
  }

  // Set the send timeout from the remaining budget.
  int64_t sendBudget = deadline - nowMs();
  if (sendBudget <= 0) {
    close(socketFd);
    *error = @"timed out";
    return NO;
  }
  struct timeval sendTimeout = {
    .tv_sec = sendBudget / 1000,
    .tv_usec = (sendBudget % 1000) * 1000,
  };
  setsockopt(socketFd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, sizeof sendTimeout);

  // Send every request byte, then close the write direction.
  const char *cursor = request.bytes;
  size_t bytesRemaining = request.length;
  while (bytesRemaining > 0) {
    ssize_t bytesSent = send(socketFd, cursor, bytesRemaining, 0);
    if (bytesSent < 0) {
      if (errno == EINTR) continue;
      *error = (errno == EAGAIN || errno == EWOULDBLOCK) ? @"timed out" : @(strerror(errno));
      close(socketFd);
      return NO;
    }
    if (bytesSent == 0) {
      close(socketFd);
      *error = @"send made no progress";
      return NO;
    }
    cursor += bytesSent;
    bytesRemaining -= (size_t)bytesSent;
  }
  shutdown(socketFd, SHUT_WR);

  // Accumulate reply chunks until EOF or the deadline.
  char buffer[8192];
  for (;;) {
    int64_t remainingMs = deadline - nowMs();
    if (remainingMs <= 0) {
      close(socketFd);
      *error = @"timed out";
      return NO;
    }
    struct pollfd socketEvent = { .fd = socketFd, .events = POLLIN };
    int pollResult = poll(&socketEvent, 1, (int)remainingMs);
    if (pollResult == 0) {
      close(socketFd);
      *error = @"timed out";
      return NO;
    }
    if (pollResult < 0) {
      if (errno == EINTR) continue;
      *error = @(strerror(errno));
      close(socketFd);
      return NO;
    }
    ssize_t bytesRead = read(socketFd, buffer, sizeof buffer);
    if (bytesRead < 0) {
      if (errno == EINTR) continue;
      *error = @(strerror(errno));
      close(socketFd);
      return NO;
    }
    if (bytesRead == 0) break;
    [response appendBytes:buffer length:(NSUInteger)bytesRead];
  }
  // Close the socket and report transport success.
  close(socketFd);
  return YES;
}

static int run(lua_State *state) {
  // Validate Lua arguments and keep an owned copy of the socket path.
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  [skin checkArgs:LS_TSTRING, LS_TTABLE, LS_TNUMBER | LS_TINTEGER, LS_TFUNCTION, LS_TBREAK];
  size_t pathLength;
  const char *pathBytes = lua_tolstring(state, 1, &pathLength);
  luaL_argcheck(state, pathLength < sizeof(((struct sockaddr_un *)0)->sun_path), 1, "socket path too long");
  NSData *socketPath = [NSData dataWithBytes:pathBytes length:pathLength + 1];
  int timeoutMs = (int)lua_tointeger(state, 3);
  luaL_argcheck(state, timeoutMs > 0, 3, "timeout must be > 0 ms");

  // Encode NUL-separated arguments with a 32-bit length prefix.
  NSMutableData *body = [NSMutableData data];
  lua_Integer argumentCount = (lua_Integer)lua_rawlen(state, 2);
  for (lua_Integer index = 1; index <= argumentCount; index++) {
    lua_rawgeti(state, 2, index);
    size_t argumentLength;
    const char *argumentBytes = lua_tolstring(state, -1, &argumentLength);
    if (!argumentBytes) return luaL_error(state, "args[%d] is not a string", (int)index);
    [body appendBytes:argumentBytes length:argumentLength];
    [body appendBytes:"" length:1];
    lua_pop(state, 1);
  }
  [body appendBytes:"" length:1];
  int32_t bodyLength = (int32_t)body.length;
  NSMutableData *request = [NSMutableData dataWithBytes:&bodyLength length:sizeof bodyLength];
  [request appendData:body];

  // Retain the callback and record the current Lua state's identity.
  lua_pushvalue(state, 4);
  int callbackRef = [skin luaRef:refTable];
  LSGCCanary canary = [skin createGCCanary];

  // Run the blocking socket exchange on a background worker.
  dispatch_async(ioQueue, ^{
    NSMutableData *response = [NSMutableData data];
    NSString *error = nil;
    BOOL ok = exchange(socketPath.bytes, request, timeoutMs, response, &error);

    // Restore the callback on the main thread unless Lua has reloaded.
    dispatch_async(dispatch_get_main_queue(), ^{
      LuaSkin *mainSkin = [LuaSkin sharedWithState:NULL];
      if (![mainSkin checkGCCanary:canary]) return;
      lua_State *mainState = mainSkin.L;
      _lua_stackguard_entry(mainState);
      [mainSkin pushLuaRef:refTable ref:callbackRef];
      [mainSkin luaUnref:refTable ref:callbackRef];
      LSGCCanary completedCanary = canary;
      [mainSkin destroyGCCanary:&completedCanary];

      // Map socket errors, yabai errors, or success to Lua arguments.
      const char *responseBytes = response.bytes;
      NSUInteger responseLength = response.length;
      if (!ok) {
        lua_pushboolean(mainState, 0);
        lua_pushliteral(mainState, "");
        lua_pushstring(mainState, error.UTF8String);
      } else if (responseLength > 0 && responseBytes[0] == '\a') {
        lua_pushboolean(mainState, 0);
        lua_pushliteral(mainState, "");
        lua_pushlstring(mainState, responseBytes + 1, responseLength - 1);
      } else {
        lua_pushboolean(mainState, 1);
        lua_pushlstring(mainState, responseBytes, responseLength);
        lua_pushliteral(mainState, "");
      }
      // Invoke the callback with (ok, stdout, stderr).
      [mainSkin protectedCallAndError:@"yabai callback" nargs:3 nresults:0];
      _lua_stackguard_exit(mainState);
    });
  });
  // Return to Lua without waiting for the queued work.
  return 0;
}

static const luaL_Reg functions[] = {
  { "run", run },
  { NULL, NULL },
};

int luaopen_yabai(lua_State *state) {
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  if (!ioQueue) ioQueue = dispatch_queue_create("yabai.io", DISPATCH_QUEUE_CONCURRENT);
  refTable = [skin registerLibrary:"yabai" functions:functions metaFunctions:nil];
  return 1;
}
