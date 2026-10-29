#import <Cocoa/Cocoa.h>
#import <LuaSkin/LuaSkin.h>
#include <dlfcn.h>
#include <stdatomic.h>

static LSRefTable refTable = LUA_NOREF;
static dispatch_queue_t workers[4];
static size_t nextWorker;
typedef CFArrayRef (*Capture)(int, CGWindowID *, uint32_t, uint32_t);
typedef CGError (*Owner)(int, CGWindowID, int *);
typedef CGError (*Process)(int, pid_t *);
static Capture captureImage;
static Owner windowOwner;
static Process connectionPID;
static int connection;
static const char *tag = "previews.cancel";

typedef struct {
  CGWindowID id;
  pid_t pid;
} Preview;

typedef struct {
  atomic_bool cancelled;
  atomic_uint references;
  Preview windows[];
} Batch;

static void releaseBatch(Batch *batch) {
  if (atomic_fetch_sub(&batch->references, 1) == 1) free(batch);
}

static BOOL belongsTo(Preview *window) {
  int owner = 0;
  pid_t pid = 0;
  return windowOwner(connection, window->id, &owner) == kCGErrorSuccess
    && connectionPID(owner, &pid) == kCGErrorSuccess && pid == window->pid;
}

static CGImageRef thumbnail(CGImageRef image) {
  size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
  if (width <= 1 || height <= 1) return NULL;
  double scale = fmin(1, fmin(460.0 / (double)width, 260.0 / (double)height));
  width = (size_t)fmax(1, round((double)width * scale));
  height = (size_t)fmax(1, round((double)height * scale));
  CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8,
    (width * 4 + 63) & ~(size_t)63, colorSpace, (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(colorSpace);
  if (!context) return NULL;
  CGContextSetInterpolationQuality(context, kCGInterpolationMedium);
  CGContextDrawImage(context, CGRectMake(0, 0, (CGFloat)width, (CGFloat)height), image);
  CGImageRef result = CGBitmapContextCreateImage(context);
  CGContextRelease(context);
  return result;
}

static void deliver(Batch *batch, LSRefTable references, int callback, LSGCCanary canary,
    CGWindowID id, CGImageRef image, BOOL failed) {
  LuaSkin *skin = [LuaSkin sharedWithState:NULL];
  if (![skin checkGCCanary:canary]) return;
  lua_State *state = skin.L;
  _lua_stackguard_entry(state);
  [skin pushLuaRef:references ref:callback];
  if (!id) {
    [skin luaUnref:references ref:callback];
    [skin destroyGCCanary:&canary];
  }
  if (!atomic_load(&batch->cancelled)) {
    if (id) lua_pushinteger(state, id); else lua_pushnil(state);
    if (image) {
      // A bitmap representation avoids retaining a full-size or lazily rendered snapshot.
      NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithCGImage:image];
      bitmap.size = NSMakeSize((CGFloat)CGImageGetWidth(image) / 2, (CGFloat)CGImageGetHeight(image) / 2);
      NSImage *result = [[NSImage alloc] initWithSize:bitmap.size];
      [result addRepresentation:bitmap];
      [skin pushNSObject:result];
    } else {
      lua_pushnil(state);
    }
    if (failed) {
      lua_pushstring(state, [NSString stringWithFormat:@"could not capture window: %u", id].UTF8String);
    } else {
      lua_pushnil(state);
    }
    [skin protectedCallAndError:@"previews callback" nargs:3 nresults:0];
  } else {
    lua_pop(state, 1);
  }
  _lua_stackguard_exit(state);
}

static int cancel(lua_State *state) {
  Batch *batch = *(Batch **)lua_touserdata(state, lua_upvalueindex(1));
  atomic_store(&batch->cancelled, true);
  return 0;
}

static int collect(lua_State *state) {
  Batch **pointer = luaL_checkudata(state, 1, tag);
  if (*pointer) {
    atomic_store(&(*pointer)->cancelled, true);
    releaseBatch(*pointer);
    *pointer = NULL;
  }
  return 0;
}

static int capture(lua_State *state) {
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  [skin checkArgs:LS_TTABLE, LS_TFUNCTION, LS_TBREAK];
  size_t count = lua_rawlen(state, 1);
  luaL_argcheck(state, count <= (SIZE_MAX - sizeof(Batch)) / sizeof(Preview), 1, "too many windows");
  // Validate before allocating: Lua argument errors unwind through longjmp.
  for (size_t index = 0; index < count; index++) {
    lua_rawgeti(state, 1, (lua_Integer)index + 1);
    luaL_checktype(state, -1, LUA_TTABLE);
    lua_getfield(state, -1, "id");
    lua_Integer id = luaL_checkinteger(state, -1);
    luaL_argcheck(state, id > 0 && id <= UINT32_MAX, 1, "invalid window id");
    lua_pop(state, 1);
    lua_getfield(state, -1, "pid");
    lua_Integer pid = luaL_checkinteger(state, -1);
    luaL_argcheck(state, pid > 0 && pid <= INT32_MAX, 1, "invalid window pid");
    lua_pop(state, 2);
  }
  Batch **pointer = lua_newuserdata(state, sizeof(Batch *));
  *pointer = NULL;
  luaL_setmetatable(state, tag);
  Batch *batch = calloc(1, sizeof(Batch) + count * sizeof(Preview));
  if (!batch) return luaL_error(state, "could not allocate preview batch");
  *pointer = batch;
  atomic_init(&batch->references, 1);
  atomic_init(&batch->cancelled, false);
  for (size_t index = 0; index < count; index++) {
    lua_rawgeti(state, 1, (lua_Integer)index + 1);
    lua_getfield(state, -1, "id");
    batch->windows[index].id = (CGWindowID)lua_tointeger(state, -1);
    lua_pop(state, 1);
    lua_getfield(state, -1, "pid");
    batch->windows[index].pid = (pid_t)lua_tointeger(state, -1);
    lua_pop(state, 2);
  }
  lua_pushcclosure(state, cancel, 1);
  lua_pushvalue(state, 2);
  int callback = [skin luaRef:refTable];
  LSRefTable references = refTable;
  LSGCCanary canary = [skin createGCCanary];

  atomic_fetch_add(&batch->references, 1);
  dispatch_group_t group = dispatch_group_create();
  for (size_t index = 0; index < count; index++) {
    dispatch_group_async(group, workers[nextWorker++ % 4], ^{
      @autoreleasepool {
        if (atomic_load(&batch->cancelled)) return;
        Preview *window = &batch->windows[index];
        CGImageRef image = NULL;
        BOOL failed = NO;
        if (belongsTo(window)) {
          // Ignore clipping, capture at nominal resolution, and bypass Stage Manager scaling.
          CFArrayRef images = captureImage(connection, &window->id, 1, (1U << 11) | (1U << 9) | (1U << 19));
          if (images && CFArrayGetCount(images)) {
            image = thumbnail((CGImageRef)CFArrayGetValueAtIndex(images, 0));
          }
          if (images) CFRelease(images);
          if (atomic_load(&batch->cancelled) || !belongsTo(window)) {
            if (image) CGImageRelease(image);
            image = NULL;
          } else {
            failed = image == NULL;
          }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
          deliver(batch, references, callback, canary, window->id, image, failed);
          if (image) CGImageRelease(image);
        });
      }
    });
  }
  // Every worker queues its result before the final completion can be enqueued.
  dispatch_group_notify(group, dispatch_get_main_queue(), ^{
    deliver(batch, references, callback, canary, 0, NULL, NO);
    releaseBatch(batch);
  });
  return 1;
}

static const luaL_Reg functions[] = {
  { "capture", capture },
  { NULL, NULL },
};

int luaopen_previews(lua_State *state) {
  // Keep pending blocks executable when Lua unloads modules during reload.
  static void *handle, *skyLight;
  static BOOL initialized;
  if (!handle) {
    Dl_info info;
    if (!dladdr(&workers, &info) || !(handle = dlopen(info.dli_fname, RTLD_NOW | RTLD_LOCAL))) {
      return luaL_error(state, "could not retain preview library");
    }
  }
  if (!initialized) {
    skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW | RTLD_LOCAL);
    if (!skyLight) return luaL_error(state, "SkyLight unavailable");
    int (*mainConnection)(void) = NULL;
    struct { const char *name; void *address; size_t size; } symbols[] = {
      { "CGSHWCaptureWindowList", &captureImage, sizeof captureImage },
      { "SLSGetWindowOwner", &windowOwner, sizeof windowOwner },
      { "SLSConnectionGetPID", &connectionPID, sizeof connectionPID },
      { "SLSMainConnectionID", &mainConnection, sizeof mainConnection },
    };
    for (size_t index = 0; index < sizeof symbols / sizeof *symbols; index++) {
      void *symbol = dlsym(skyLight, symbols[index].name);
      if (!symbol) return luaL_error(state, "%s unavailable", symbols[index].name);
      memcpy(symbols[index].address, &symbol, symbols[index].size);
    }
    connection = mainConnection();
    initialized = YES;
  }
  if (!workers[0]) {
    for (size_t index = 0; index < 4; index++) {
      workers[index] = dispatch_queue_create("previews.capture", dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    }
  }
  luaL_newmetatable(state, tag);
  lua_pushcfunction(state, collect);
  lua_setfield(state, -2, "__gc");
  lua_pop(state, 1);
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  refTable = [skin registerLibrary:"previews" functions:functions metaFunctions:nil];
  return 1;
}
