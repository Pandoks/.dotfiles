#import <Foundation/Foundation.h>
@import Accelerate;
#import <LuaSkin/LuaSkin.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

enum {
  fftLog2 = 10,
  fftSize = 1 << fftLog2,
  fftHalf = fftSize / 2,
  fftBytes = fftSize * 2,
};

static LSRefTable references = LUA_NOREF;
static const char *metatableName = "stream.listener";
// Reads off the main thread: a stalled reader would stall the writer's whole pipeline.
static dispatch_queue_t queue;

// Sockets, sources, and buffers change only on `queue`; Lua state only on main.
@interface Stream : NSObject
@property NSString *path;
@property dispatch_source_t listener, reader;
@property NSMutableData *pending;
@property NSString *error;
@property BOOL scheduled, closed;
@property int callback;
@end

@implementation Stream
- (void)fail:(NSString *)action {
  if (!self.error) self.error = [NSString stringWithFormat:@"could not %@ the stream: %s", action, strerror(errno)];
}

- (void)accept {
  int client = accept((int)dispatch_source_get_handle(self.listener), NULL, NULL);
  if (client < 0 && (errno == EAGAIN || errno == EINTR || errno == ECONNABORTED)) return;
  if (client < 0) [self fail:@"accept"];
  // One writer, or none after an error: no one else can connect.
  dispatch_source_cancel(self.listener);
  self.listener = nil;
  unlink(self.path.fileSystemRepresentation);
  self.path = nil;
  if (client < 0) return;
  if (fcntl(client, F_SETFD, FD_CLOEXEC) < 0) {
    [self fail:@"configure"];
    close(client);
    return;
  }
  self.reader = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)client, 0, queue);
  dispatch_source_set_event_handler(self.reader, ^{
    [self read];
    if (self.pending.length || self.error) [self schedule];
  });
  dispatch_source_set_cancel_handler(self.reader, ^{ close(client); });
  dispatch_resume(self.reader);
}

- (void)read {
  uint8_t buffer[16384];
  while (self.reader) {
    ssize_t count = read((int)dispatch_source_get_handle(self.reader), buffer, sizeof buffer);
    if (count < 0 && errno == EINTR) continue;
    if (count < 0 && errno == EAGAIN) return;
    if (count < 0) [self fail:@"read"];
    if (count > 0) {
      [self.pending appendBytes:buffer length:(NSUInteger)count];
      continue;
    }
    dispatch_source_cancel(self.reader);
    self.reader = nil;
  }
}

- (void)schedule {
  if (self.scheduled) return;
  self.scheduled = YES;
  dispatch_async(dispatch_get_main_queue(), ^{ [self deliver]; });
}

- (void)deliver {
  __block NSData *chunk;
  dispatch_sync(queue, ^{
    self.scheduled = NO;
    if (self.closed) return;
    chunk = [self.pending copy];
    self.pending.length = 0;
  });
  if (chunk.length) [self call:chunk error:nil];
  // Taken after the chunk, so a close() from its callback returns the error instead.
  __block NSString *error;
  dispatch_sync(queue, ^{
    if (self.closed) return;
    error = self.error;
    self.error = nil;
  });
  if (error) [self call:nil error:error];
}

- (void)call:(NSData *)chunk error:(NSString *)error {
  LuaSkin *skin = [LuaSkin sharedWithState:NULL];
  lua_State *state = skin.L;
  _lua_stackguard_entry(state);
  [skin pushLuaRef:references ref:self.callback];
  if (chunk) lua_pushlstring(state, chunk.bytes, chunk.length);
  else lua_pushnil(state);
  if (error) lua_pushstring(state, error.UTF8String);
  else lua_pushnil(state);
  [skin protectedCallAndError:@"stream callback" nargs:2 nresults:0];
  _lua_stackguard_exit(state);
}

// Accepts a waiting writer and drains it: undelivered bytes and any unraised error.
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
  [[LuaSkin sharedWithState:NULL] luaUnref:references ref:self.callback];
  return rest;
}
@end

static int collect(lua_State *state) {
  void **userdata = luaL_checkudata(state, 1, metatableName);
  if (*userdata) {
    [(__bridge_transfer Stream *)*userdata finish:nil];
    *userdata = NULL;
  }
  return 0;
}

static int stop(lua_State *state) {
  void **userdata = luaL_checkudata(state, lua_upvalueindex(1), metatableName);
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
  stream.pending = [NSMutableData new];
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
  luaL_setmetatable(state, metatableName);
  lua_pushcclosure(state, stop, 1);
  return 1;
}

static double loudness(double energy) {
  double rms = sqrt(energy / (double)fftSize) + 1e-9;
  double value = (20.0 * log10(rms) + 50.0) / 40.0;
  if (value < 0.0) return 0.0;
  if (value > 1.0) return 1.0;
  return value;
}

static double windowEnergy(const char *bytes, float *samples) {
  int16_t raw[fftSize];
  memcpy(raw, bytes, fftBytes);
  vDSP_vflt16(raw, 1, samples, 1, fftSize);
  float sum = 0.0f;
  vDSP_svesq(samples, 1, &sum, fftSize);
  return (double)sum / (32768.0 * 32768.0);
}

static lua_Integer checkBin(lua_State *state, lua_Integer slot) {
  lua_rawgeti(state, 2, slot);
  int valid = 0;
  int kind = lua_type(state, -1);
  lua_Integer edge = kind == LUA_TNUMBER ? lua_tointegerx(state, -1, &valid) : 0;
  lua_pop(state, 1);
  luaL_argcheck(state, valid && edge >= 0 && edge <= fftHalf, 2, "invalid bin edge");
  return edge;
}

static int analyze(lua_State *state) {
  luaL_checktype(state, 1, LUA_TSTRING);
  luaL_checktype(state, 2, LUA_TTABLE);
  size_t length = 0;
  const char *pcm = lua_tolstring(state, 1, &length);
  luaL_argcheck(state, length >= fftBytes, 1, "expected at least 2048 bytes of PCM");
  size_t count = lua_rawlen(state, 2);
  luaL_argcheck(state, count > 0 && count <= INT_MAX, 2, "expected at least one frequency band");
  lua_Integer previous = checkBin(state, 0);

  static dispatch_once_t fftOnce;
  static FFTSetup fftSetup;
  static float hann[fftSize];
  dispatch_once(&fftOnce, ^{
    fftSetup = vDSP_create_fftsetup(fftLog2, kFFTRadix2);
    for (size_t sample = 0; sample < fftSize; sample++) {
      hann[sample] = (float)((0.5 - 0.5 * cos(2.0 * M_PI * (double)sample / (double)(fftSize - 1))) / 32768.0);
    }
  });
  if (!fftSetup) return luaL_error(state, "could not create FFT setup");

  float samples[fftSize];
  double energy = windowEnergy(pcm + length - fftBytes, samples);
  double level = loudness(energy);
  double peak = level;

  vDSP_vmul(samples, 1, hann, 1, samples, 1, fftSize);
  float real[fftHalf], imag[fftHalf];
  for (size_t pair = 0; pair < fftHalf; pair++) {
    real[pair] = samples[2 * pair];
    imag[pair] = samples[2 * pair + 1];
  }
  DSPSplitComplex split = { real, imag };
  vDSP_fft_zrip(fftSetup, &split, 1, fftLog2, kFFTDirection_Forward);

  float magnitudes[fftHalf + 1];
  float dc = fabsf(split.realp[0]) * 0.5f;
  float nyquist = fabsf(split.imagp[0]) * 0.5f;
  vDSP_zvabs(&split, 1, magnitudes, 1, fftHalf);
  float half = 0.5f;
  vDSP_vsmul(magnitudes + 1, 1, &half, magnitudes + 1, 1, fftHalf - 1);
  magnitudes[0] = dc;
  magnitudes[fftHalf] = nyquist;

  for (size_t last = length - fftBytes; last >= fftBytes; last -= fftBytes) {
    double older = loudness(windowEnergy(pcm + last - fftBytes, samples));
    if (older > peak) peak = older;
  }

  lua_pushnumber(state, level);
  lua_pushnumber(state, energy);
  lua_pushnumber(state, peak);
  lua_createtable(state, (int)count, 0);
  for (size_t band = 1; band <= count; band++) {
    lua_Integer edge = checkBin(state, (lua_Integer)band);
    lua_Integer low = previous;
    lua_Integer high = edge > low ? edge : low + 1;
    double sum = 0.0;
    for (lua_Integer bin = low; bin < high; bin++) {
      sum += (double)magnitudes[bin];
    }
    lua_pushnumber(state, sqrt(sum / (double)(high - low)));
    lua_rawseti(state, -2, (lua_Integer)band);
    previous = edge;
  }
  return 4;
}

static const luaL_Reg functions[] = {
  { "listen", serve },
  { "analyze", analyze },
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
  luaL_newmetatable(state, metatableName);
  lua_pushcfunction(state, collect);
  lua_setfield(state, -2, "__gc");
  lua_pop(state, 1);
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  references = [skin registerLibrary:"stream" functions:functions metaFunctions:nil];
  return 1;
}
