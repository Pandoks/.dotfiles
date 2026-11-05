#ifdef PREVIEWS_TEST_MODULE
#import <Cocoa/Cocoa.h>
#import <LuaSkin/LuaSkin.h>
#include <assert.h>
#include <stdatomic.h>

static atomic_int active, peak, started, captured, oldCallbacks;
static atomic_bool blocked, closed;
static dispatch_semaphore_t entered, gate;

#import "../lib/previews/previews.m"

static CGError fixtureOwner(int server, CGWindowID window, int *owner) {
  (void)server;
  if (window == 15) return kCGErrorFailure;
  *owner = window == 12 || (window == 14 && atomic_load(&closed)) ? 999 : 123;
  return kCGErrorSuccess;
}
static CGError fixturePID(int owner, pid_t *pid) { *pid = owner; return kCGErrorSuccess; }
static CGWindowID held;

static CFArrayRef fixtureImage(int server, CGWindowID *windows, uint32_t count, uint32_t flags) {
  (void)server;
  assert(count == 1 && flags == ((1U << 11) | (1U << 9) | (1U << 19)));
  CGWindowID window = windows[0];
  assert(![NSThread isMainThread]);
  int running = atomic_fetch_add(&active, 1) + 1;
  int previous = atomic_load(&peak);
  while (running > previous && !atomic_compare_exchange_weak(&peak, &previous, running)) {}
  atomic_fetch_add(&started, 1);
  dispatch_semaphore_signal(entered);
  if (atomic_load(&blocked) && (!held || held == window)) {
    assert(dispatch_semaphore_wait(gate, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0);
  }
  CGImageRef image = NULL;
  if (window != 13) {
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    size_t width = window >= 1000 ? 920 : window == 8 ? 4000 : window == 9 ? 400 : window == 16 ? 1 : 8;
    size_t height = window >= 1000 ? 520 : window == 8 ? 3000 : window == 9 ? 2000 : window == 16 ? 1 : 8;
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, width * 4, colorSpace, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextSetRGBFillColor(context, 1, 0, 0, 1);
    CGContextFillRect(context, CGRectMake(0, 0, (CGFloat)width, (CGFloat)height));
    image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
  }
  if (window == 14) atomic_store(&closed, true);
  atomic_fetch_add(&captured, 1);
  atomic_fetch_sub(&active, 1);
  CFArrayRef images = image ? CFBridgingRetain(@[(__bridge id)image]) : NULL;
  if (image) CGImageRelease(image);
  return images;
}

static int prepare(lua_State *state) {
  assert(atomic_load(&active) == 0);
  captureImage = fixtureImage;
  windowOwner = fixtureOwner;
  connectionPID = fixturePID;
  held = (CGWindowID)luaL_optinteger(state, 2, 0);
  atomic_store(&active, 0); atomic_store(&peak, 0); atomic_store(&started, 0);
  atomic_store(&captured, 0); atomic_store(&closed, false);
  atomic_store(&blocked, lua_toboolean(state, 1));
  entered = dispatch_semaphore_create(0);
  gate = dispatch_semaphore_create(0);
  return 0;
}

static int waitStarted(lua_State *state) {
  int count = (int)luaL_checkinteger(state, 1);
  for (int index = 0; index < count; index++) {
    assert(dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0);
  }
  return 0;
}

static void unblock(void) {
  atomic_store(&blocked, false);
  for (int index = 0; index < 4; index++) dispatch_semaphore_signal(gate);
}

static int resume(lua_State *state) { (void)state; unblock(); return 0; }

static int stats(lua_State *state) {
  lua_pushinteger(state, atomic_load(&peak));
  lua_pushinteger(state, atomic_load(&started));
  lua_pushinteger(state, atomic_load(&captured));
  return 3;
}

static void drain(dispatch_block_t done) {
  dispatch_group_t group = dispatch_group_create();
  for (size_t index = 0; index < 4; index++) dispatch_group_async(group, workers[index], ^{});
  dispatch_group_notify(group, dispatch_get_main_queue(), done);
}

static int idle(lua_State *state) {
  luaL_checktype(state, 1, LUA_TFUNCTION);
  lua_pushvalue(state, 1);
  int callback = luaL_ref(state, LUA_REGISTRYINDEX);
  drain(^{
    lua_rawgeti(state, LUA_REGISTRYINDEX, callback);
    luaL_unref(state, LUA_REGISTRYINDEX, callback);
    if (lua_pcall(state, 0, 0, 0)) { fprintf(stderr, "%s\n", lua_tostring(state, -1)); abort(); }
  });
  return 0;
}

static int mark(lua_State *state) { (void)state; atomic_fetch_add(&oldCallbacks, 1); return 0; }

static int reloaded(lua_State *state) {
  assert(lua_isnil(state, 1) && lua_isnil(state, 2) && lua_isnil(state, 3));
  assert(atomic_load(&oldCallbacks) == 0);
  puts("PASS reload discards old callbacks and keeps pending native code mapped");
  puts("12 native preview tests passed");
  exit(0);
}

static int reload(lua_State *state) {
  (void)state;
  dispatch_async(dispatch_get_main_queue(), ^{
    LuaSkin *skin = [LuaSkin sharedWithState:NULL];
    [skin resetLuaState]; // Runs userdata finalizers and package.loadlib's dlclose.
    Dl_info info;
    assert(dladdr(&workers, &info));
    lua_State *next = ((LuaSkin *)[LuaSkin sharedWithState:NULL]).L;
    luaL_openlibs(next);
    luaopen_previews(next);
    lua_setglobal(next, "previews");
    unblock();
    drain(^{
      assert(atomic_load(&oldCallbacks) == 0);
      lua_getglobal(next, "previews");
      lua_getfield(next, -1, "capture");
      lua_newtable(next);
      lua_pushcfunction(next, reloaded);
      if (lua_pcall(next, 2, 1, 0)) { fprintf(stderr, "%s\n", lua_tostring(next, -1)); abort(); }
      lua_setglobal(next, "cancel");
      lua_pop(next, 1);
    });
  });
  return 0;
}

static const luaL_Reg fixtures[] = {
  { "prepare", prepare }, { "waitStarted", waitStarted }, { "resume", resume },
  { "stats", stats }, { "idle", idle }, { "mark", mark }, { "reload", reload }, { NULL, NULL },
};
int luaopen_fixture(lua_State *state) { luaL_newlib(state, fixtures); return 1; }
#else
#import <Cocoa/Cocoa.h>
#import <LuaSkin/LuaSkin.h>
#include <assert.h>

@interface PreviewTestLog : NSObject <LuaSkinDelegate>
@end
@implementation PreviewTestLog
- (void)handleCatastrophe:(NSString *)message {
  fprintf(stderr, "%s\n", message.UTF8String); abort();
}
- (void)logForLuaSkinAtLevel:(int)level withMessage:(NSString *)message {
  fprintf(stderr, "%s\n", message.UTF8String);
  if (level == LS_LOG_ERROR) abort();
}
@end

static int pushImage(lua_State *state, id object) {
  assert([NSThread isMainThread]);
  assert([object isKindOfClass:[NSImage class]]);
  NSImage *image = object;
  assert(image.representations.count == 1);
  NSBitmapImageRep *bitmap = (NSBitmapImageRep *)image.representations.firstObject;
  assert([bitmap isKindOfClass:[NSBitmapImageRep class]]);
  assert(bitmap.pixelsWide <= 460 && bitmap.pixelsHigh <= 260);
  lua_newtable(state);
  lua_pushinteger(state, bitmap.pixelsWide); lua_setfield(state, -2, "w");
  lua_pushinteger(state, bitmap.pixelsHigh); lua_setfield(state, -2, "h");
  lua_pushinteger(state, bitmap.bytesPerRow * bitmap.pixelsHigh); lua_setfield(state, -2, "bytes");
  return 1;
}

int main(int argc, char **argv) {
  @autoreleasepool {
    assert(argc == 3);
    PreviewTestLog *logger = [PreviewTestLog new];
    LuaSkin *skin = [LuaSkin sharedWithDelegate:logger];
    lua_State *state = skin.L;
    luaL_openlibs(state);
    assert([skin registerPushNSHelper:pushImage forClass:"NSImage"]);
    lua_newtable(state);
    lua_pushstring(state, argv[1]); lua_rawseti(state, -2, 1);
    lua_setglobal(state, "arg");
    if (luaL_dofile(state, argv[2])) { fprintf(stderr, "%s\n", lua_tostring(state, -1)); return 1; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 45 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      fprintf(stderr, "preview tests timed out\n"); abort();
    });
    CFRunLoopRun();
  }
  return 1;
}
#endif
