#import <Cocoa/Cocoa.h>
#import <LuaSkin/LuaSkin.h>
#include <dlfcn.h>
#include <mach/mach_time.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static LSRefTable refTable = LUA_NOREF;
static NSMutableDictionary<NSNumber *, dispatch_queue_t> *queues;
static NSMutableDictionary<NSNumber *, NSValue *> *frames;

extern AXError _AXUIElementGetWindow(AXUIElementRef element, CGWindowID *wid);
static AXUIElementRef (*remoteElement)(CFDataRef token);
static CGError (*setFront)(ProcessSerialNumber *psn, CGWindowID wid, uint32_t mode);
static CGError (*postRecord)(ProcessSerialNumber *psn, uint8_t *bytes);
static CFArrayRef (*copySpaces)(int connection, int mask, CFArrayRef windows);
static int connection;

// Lua closes loadlib handles on reload while queued blocks may still run.
static BOOL keepImageLoaded(void) {
  static void *handle;
  if (handle) return YES;
  Dl_info image;
  if (!dladdr(&queues, &image)) return NO;
  handle = dlopen(image.dli_fname, RTLD_NOW | RTLD_LOCAL);
  return handle != NULL;
}

#pragma mark - Space switching

// Dock swipe synthesis, ported from rift (src/sys/space_switch.rs, Apache-2.0).
enum {
  typeField = 55, hidTypeField = 110, maskField = 115, motionField = 123, progressField = 124,
  positionXField = 125, positionYField = 126, velocityXField = 129, velocityYField = 130,
  phaseField = 132, phaseMirrorField = 134, flavorField = 138, timestampField = 169,
  payloadField = 4205,
};
enum { dockControl = 30, dockSwipe = 23, began = 1, ended = 4 };

#pragma pack(push, 1)
typedef struct { uint64_t timestamp, sender; uint32_t options, attributes, count; } QueueElement;
typedef struct { uint32_t size, type, options; uint8_t depth, reserved[3]; } HIDBase;
typedef struct {
  HIDBase base; int32_t x, y, z; uint32_t mask; uint16_t motion, flavor; int32_t progress;
} HIDGesture;
typedef struct { HIDBase base; int32_t x, y, z; } HIDVelocity;
#pragma pack(pop)

static int32_t fixed(double value) {
  int32_t result = (int32_t)(value * 65536.0);
  return (result == 0 && value != 0) ? (value < 0 ? -1 : 1) : result;
}

static CGEventRef swipe(int phase, uint32_t mask, double progress, double velocity, CGPoint point) {
  CGEventRef event = CGEventCreate(NULL);
  CGEventSetLocation(event, point);
  CGEventSetIntegerValueField(event, typeField, dockControl);
  CGEventSetIntegerValueField(event, hidTypeField, dockSwipe);
  CGEventSetIntegerValueField(event, phaseField, phase);
  CGEventSetIntegerValueField(event, phaseMirrorField, phase);
  CGEventSetIntegerValueField(event, motionField, 1);
  CGEventSetIntegerValueField(event, maskField, mask);
  CGEventSetDoubleValueField(event, progressField, progress);
  if (velocity != 0) CGEventSetDoubleValueField(event, velocityXField, velocity);
  CGEventSetDoubleValueField(event, flavorField, 3.0);
  CGEventSetDoubleValueField(event, timestampField, (double)mach_absolute_time());
  CGEventSetDoubleValueField(event, positionXField, 0.1);
  return event;
}

// macOS 27 reads the gesture from an IOHID payload inside the serialized event.
static CGEventRef withPayload(CGEventRef event) {
  CFDataRef data = CGEventCreateData(NULL, event);
  if (!data) return NULL;
  const uint8_t *bytes = CFDataGetBytePtr(data);
  CFIndex length = CFDataGetLength(data);
  if (length < 4 || OSReadBigInt32(bytes, 0) != 2) {
    CFRelease(data);
    return NULL;
  }

  // Build the HID queue element: a gesture, plus velocity when the swipe ends.
  int phase = (int)CGEventGetIntegerValueField(event, phaseField);
  double velocity = CGEventGetDoubleValueField(event, velocityXField);
  BOOL moving = velocity != 0 || phase == ended;
  QueueElement header = { CGEventGetTimestamp(event) ?: mach_absolute_time(), 0, 0, 0, moving ? 2 : 1 };
  HIDGesture gesture = {
    { sizeof(HIDGesture), 23, ((uint32_t)phase & 0xFF) << 24, 0, { 0 } },
    fixed(CGEventGetDoubleValueField(event, positionXField)),
    fixed(CGEventGetDoubleValueField(event, positionYField)), 0,
    (uint32_t)CGEventGetIntegerValueField(event, maskField),
    (uint16_t)CGEventGetIntegerValueField(event, motionField), 3,
    fixed(CGEventGetDoubleValueField(event, progressField)),
  };
  HIDVelocity motion = {
    { sizeof(HIDVelocity), 9, 0, 1, { 0 } },
    fixed(velocity), fixed(CGEventGetDoubleValueField(event, velocityYField)), 0,
  };
  NSMutableData *payload = [NSMutableData dataWithBytes:&header length:sizeof header];
  [payload appendBytes:&gesture length:sizeof gesture];
  if (moving) [payload appendBytes:&motion length:sizeof motion];

  // Fields are (size, tag << 14 | field, value), sorted by field; insert the payload in order.
  NSMutableData *out = [NSMutableData dataWithBytes:bytes length:4];
  BOOL inserted = NO;
  void (^insert)(void) = ^{
    uint16_t head[2] = { OSSwapHostToBigInt16((uint16_t)payload.length), OSSwapHostToBigInt16(payloadField) };
    [out appendBytes:head length:sizeof head];
    [out appendData:payload];
  };
  for (CFIndex offset = 4; offset + 4 <= length;) {
    uint16_t size = OSReadBigInt16(bytes, offset), tagged = OSReadBigInt16(bytes, offset + 2);
    uint16_t tag = tagged >> 14, field = tagged & 0x3FFF;
    CFIndex width = tag == 1 ? 4 : tag == 3 ? (size == 2 ? 8 : 4) : (size == 1 ? 8 : size);
    if (offset + 4 + width > length) break;
    if (!inserted && field >= payloadField) {
      insert();
      inserted = YES;
    }
    if (field != payloadField) [out appendBytes:bytes + offset length:4 + width];
    offset += 4 + width;
  }
  if (!inserted) insert();
  CFRelease(data);
  return CGEventCreateFromData(NULL, (__bridge CFDataRef)out);
}

static void post(CGEventRef event) {
  CGEventRef augmented = withPayload(event);
  CGEventPost(kCGSessionEventTap, augmented ?: event);
  if (augmented) CFRelease(augmented);
  CFRelease(event);
}

/// wm.step(right, x, y) switches one Space on the display containing (x, y), without animation.
static int step(lua_State *state) {
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  [skin checkArgs:LS_TBOOLEAN, LS_TNUMBER, LS_TNUMBER, LS_TBREAK];
  BOOL right = lua_toboolean(state, 1);
  CGPoint point = { lua_tonumber(state, 2), lua_tonumber(state, 3) };
  double sign = right ? -1.0 : 1.0;
  uint32_t mask = right ? 4 : 8;
  post(swipe(began, mask, 1e-15 * sign, 0, point));
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    post(swipe(ended, mask, 1e-15 * sign, 100.0 * sign, point));
  });
  return 0;
}

#pragma mark - Accessibility

// One serial queue per app: a busy app delays only its own requests.
static dispatch_queue_t queueFor(pid_t pid) {
  NSNumber *key = @(pid);
  dispatch_queue_t queue = queues[key];
  if (!queue) {
    queue = dispatch_queue_create("wm.app", dispatch_queue_attr_make_with_qos_class(
      DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    queues[key] = queue;
  }
  return queue;
}

static AXUIElementRef application(pid_t pid) {
  AXUIElementRef app = AXUIElementCreateApplication(pid);
  AXUIElementSetMessagingTimeout(app, 1.0);
  return app;
}

static id attribute(AXUIElementRef element, CFStringRef name) {
  CFTypeRef value = NULL;
  if (AXUIElementCopyAttributeValue(element, name, &value) != kAXErrorSuccess) return nil;
  return CFBridgingRelease(value);
}

// Per-app caches, touched only on that app's queue: found elements, and ids no search found.
static NSMutableDictionary<NSNumber *, NSMutableDictionary<NSNumber *, id> *> *elements;
static NSMutableDictionary<NSNumber *, NSMutableSet<NSNumber *> *> *absent;

// Fills the caches for `wanted`. Windows on other Spaces are missing from AXWindows, so
// ids not seen before are searched once by remote token.
static NSDictionary<NSNumber *, id> *resolve(pid_t pid, NSSet<NSNumber *> *wanted) {
  NSMutableDictionary *cache;
  NSMutableSet *skipped;
  @synchronized(elements) {
    cache = elements[@(pid)] ?: (elements[@(pid)] = [NSMutableDictionary dictionary]);
    skipped = absent[@(pid)] ?: (absent[@(pid)] = [NSMutableSet set]);
  }
  NSMutableSet<NSNumber *> *missing = [wanted mutableCopy];
  for (NSNumber *wid in wanted) {
    if (cache[wid] || [skipped containsObject:wid]) [missing removeObject:wid];
  }
  if (!missing.count) return cache;

  AXUIElementRef app = application(pid);
  for (id element in attribute(app, kAXWindowsAttribute) ?: @[]) {
    CGWindowID wid = 0;
    if (_AXUIElementGetWindow((__bridge AXUIElementRef)element, &wid) != kAXErrorSuccess) continue;
    cache[@(wid)] = element;
    [missing removeObject:@(wid)];
  }
  CFRelease(app);
  if (!missing.count) return cache;

  uint8_t token[0x14] = { 0 };
  uint32_t magic = 0x636f636f;
  memcpy(token, &pid, sizeof pid);
  memcpy(token + 0x8, &magic, sizeof magic);
  for (uint64_t element = 0; element < 0x7fff && missing.count; element++) {
    memcpy(token + 0xc, &element, sizeof element);
    CFDataRef data = CFDataCreate(NULL, token, sizeof token);
    AXUIElementRef candidate = remoteElement(data);
    CFRelease(data);
    if (!candidate) continue;
    CGWindowID wid = 0;
    if (_AXUIElementGetWindow(candidate, &wid) == kAXErrorSuccess && [missing containsObject:@(wid)]) {
      AXUIElementSetMessagingTimeout(candidate, 1.0);
      cache[@(wid)] = (__bridge id)candidate;
      [missing removeObject:@(wid)];
    }
    CFRelease(candidate);
  }
  [skipped unionSet:missing];
  return cache;
}

static AXUIElementRef copyWindow(pid_t pid, CGWindowID wid) {
  id element = resolve(pid, [NSSet setWithObject:@(wid)])[@(wid)];
  return element ? (AXUIElementRef)CFBridgingRetain(element) : NULL;
}

// A destroyed window's element stays cached until its id is looked up again.
static void forget(pid_t pid, CGWindowID wid) {
  @synchronized(elements) {
    [elements[@(pid)] removeObjectForKey:@(wid)];
  }
}

#pragma mark - Lua callbacks

typedef void (^Push)(lua_State *state);

// Runs `work` on the app's queue, then calls the Lua callback with (ok, error) plus `push` values.
static void schedule(lua_State *state, int callback, pid_t pid, NSString *(^work)(Push *push)) {
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  int ref = LUA_NOREF;
  if (callback && lua_isfunction(state, callback)) {
    lua_pushvalue(state, callback);
    ref = [skin luaRef:refTable];
  }
  LSGCCanary canary = [skin createGCCanary];
  dispatch_async(queueFor(pid), ^{
    __block Push push = nil;
    NSString *error = work(&push);
    dispatch_async(dispatch_get_main_queue(), ^{
      LuaSkin *main = [LuaSkin sharedWithState:NULL];
      LSGCCanary done = canary;
      if (![main checkGCCanary:canary]) return;
      [main destroyGCCanary:&done];
      if (ref == LUA_NOREF) return;
      lua_State *L = main.L;
      _lua_stackguard_entry(L);
      [main pushLuaRef:refTable ref:ref];
      [main luaUnref:refTable ref:ref];
      lua_pushboolean(L, error == nil);
      if (error) lua_pushstring(L, error.UTF8String); else lua_pushnil(L);
      int count = 2;
      if (push) {
        push(L);
        count++;
      }
      [main protectedCallAndError:@"wm callback" nargs:count nresults:0];
      _lua_stackguard_exit(L);
    });
  });
}

/// wm.focus(pid, id, done) focuses and raises a window; done(ok, error).
static int focus(lua_State *state) {
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  [skin checkArgs:LS_TNUMBER | LS_TINTEGER, LS_TNUMBER | LS_TINTEGER, LS_TFUNCTION | LS_TOPTIONAL, LS_TBREAK];
  pid_t pid = (pid_t)lua_tointeger(state, 1);
  CGWindowID wid = (CGWindowID)lua_tointeger(state, 2);
  schedule(state, 3, pid, ^NSString *(Push *push) {
    (void)push;
    ProcessSerialNumber psn;
    if (GetProcessForPID(pid, &psn) != noErr) return @"process unavailable";
    AXUIElementRef window = copyWindow(pid, wid);
    if (!window) return @"window unavailable";

    // Same sequence as yabai: front process, key-window event records, then raise.
    setFront(&psn, wid, 0x200);
    uint8_t record[0xf8] = { [0x04] = 0xf8, [0x3a] = 0x10 };
    memcpy(record + 0x3c, &wid, sizeof wid);
    memset(record + 0x20, 0xFF, 0x10);
    record[0x08] = 0x01;
    postRecord(&psn, record);
    record[0x08] = 0x02;
    postRecord(&psn, record);
    AXError raised = AXUIElementPerformAction(window, kAXRaiseAction);
    CFRelease(window);
    if (raised == kAXErrorInvalidUIElement) forget(pid, wid);
    return raised == kAXErrorSuccess ? nil : [NSString stringWithFormat:@"raise failed (%d)", raised];
  });
  return 0;
}

/// wm.frame(pid, id, x, y, w, h, done) moves a window; requests not yet started collapse to the latest.
static int frame(lua_State *state) {
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  [skin checkArgs:LS_TNUMBER | LS_TINTEGER, LS_TNUMBER | LS_TINTEGER, LS_TNUMBER, LS_TNUMBER, LS_TNUMBER,
    LS_TNUMBER, LS_TFUNCTION | LS_TOPTIONAL, LS_TBREAK];
  pid_t pid = (pid_t)lua_tointeger(state, 1);
  CGWindowID wid = (CGWindowID)lua_tointeger(state, 2);
  NSNumber *key = @(wid);
  @synchronized(frames) {
    frames[key] = [NSValue valueWithRect:NSMakeRect(lua_tonumber(state, 3), lua_tonumber(state, 4),
      lua_tonumber(state, 5), lua_tonumber(state, 6))];
  }
  schedule(state, 7, pid, ^NSString *(Push *push) {
    (void)push;
    NSValue *value;
    @synchronized(frames) {
      value = frames[key];
      [frames removeObjectForKey:key];
    }
    if (!value) return nil;
    NSRect rect = value.rectValue;
    AXUIElementRef window = copyWindow(pid, wid);
    if (!window) return @"window unavailable";

    // Chromium and Electron animate frame changes while enhanced UI is on.
    AXUIElementRef app = application(pid);
    BOOL enhanced = [attribute(app, CFSTR("AXEnhancedUserInterface")) boolValue];
    if (enhanced) AXUIElementSetAttributeValue(app, CFSTR("AXEnhancedUserInterface"), kCFBooleanFalse);

    // Size, position, size: a window shrinking across a display edge is clamped otherwise.
    CGSize size = rect.size;
    CGPoint origin = rect.origin;
    AXValueRef sizeValue = AXValueCreate(kAXValueCGSizeType, &size);
    AXValueRef originValue = AXValueCreate(kAXValueCGPointType, &origin);
    AXUIElementSetAttributeValue(window, kAXSizeAttribute, sizeValue);
    AXError moved = AXUIElementSetAttributeValue(window, kAXPositionAttribute, originValue);
    AXError resized = AXUIElementSetAttributeValue(window, kAXSizeAttribute, sizeValue);
    CFRelease(sizeValue);
    CFRelease(originValue);

    if (enhanced) AXUIElementSetAttributeValue(app, CFSTR("AXEnhancedUserInterface"), kCFBooleanTrue);
    CFRelease(app);
    CFRelease(window);
    if (moved == kAXErrorInvalidUIElement) forget(pid, wid);
    if (moved != kAXErrorSuccess || resized != kAXErrorSuccess) {
      return [NSString stringWithFormat:@"frame failed (%d, %d)", moved, resized];
    }
    return nil;
  });
  return 0;
}

/// wm.minimize(pid, id, minimized, done) minimizes or restores a window.
static int minimize(lua_State *state) {
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  [skin checkArgs:LS_TNUMBER | LS_TINTEGER, LS_TNUMBER | LS_TINTEGER, LS_TBOOLEAN, LS_TFUNCTION | LS_TOPTIONAL,
    LS_TBREAK];
  pid_t pid = (pid_t)lua_tointeger(state, 1);
  CGWindowID wid = (CGWindowID)lua_tointeger(state, 2);
  CFBooleanRef minimized = lua_toboolean(state, 3) ? kCFBooleanTrue : kCFBooleanFalse;
  schedule(state, 4, pid, ^NSString *(Push *push) {
    (void)push;
    AXUIElementRef window = copyWindow(pid, wid);
    if (!window) return @"window unavailable";
    AXError result = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute, minimized);
    CFRelease(window);
    if (result == kAXErrorInvalidUIElement) forget(pid, wid);
    return result == kAXErrorSuccess ? nil : [NSString stringWithFormat:@"minimize failed (%d)", result];
  });
  return 0;
}

/// wm.windows(done) lists normal-layer windows on every Space with their Accessibility details;
/// done(ok, error, rows) where each row is {id, pid, role, subrole, title, root, minimized}.
static int windows(lua_State *state) {
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  [skin checkArgs:LS_TFUNCTION, LS_TBREAK];

  // The window server knows every window; Accessibility tells which are real.
  NSMutableDictionary<NSNumber *, NSMutableSet<NSNumber *> *> *owners = [NSMutableDictionary dictionary];
  NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID));
  // Background processes own windows too, but never answer for them.
  NSMutableSet<NSNumber *> *apps = [NSMutableSet set];
  for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
    if (app.activationPolicy != NSApplicationActivationPolicyProhibited) [apps addObject:@(app.processIdentifier)];
  }
  [apps removeObject:@(getpid())];
  for (NSDictionary *info in list) {
    if ([info[(id)kCGWindowLayer] intValue] != 0) continue;
    pid_t pid = [info[(id)kCGWindowOwnerPID] intValue];
    if (![apps containsObject:@(pid)]) continue;
    NSMutableSet *ids = owners[@(pid)] ?: (owners[@(pid)] = [NSMutableSet set]);
    [ids addObject:info[(id)kCGWindowNumber]];
  }

  // Query each app on its own queue, then answer once.
  lua_pushvalue(state, 1);
  int ref = [skin luaRef:refTable];
  LSGCCanary canary = [skin createGCCanary];
  dispatch_group_t group = dispatch_group_create();
  NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
  for (NSNumber *owner in owners) {
    NSSet *wanted = [owners[owner] copy];
    pid_t pid = owner.intValue;
    dispatch_group_async(group, queueFor(pid), ^{
      NSMutableArray *found = [NSMutableArray array];
      NSDictionary<NSNumber *, id> *cache = resolve(pid, wanted);
      for (NSNumber *key in wanted) {
        AXUIElementRef element = (__bridge AXUIElementRef)cache[key];
        if (!element) continue;
        CGWindowID wid = key.unsignedIntValue;
        id role = attribute(element, kAXRoleAttribute);
        if (!role) {
          forget(pid, wid);
          continue;
        }
        id parent = attribute(element, kAXParentAttribute);
        id parentRole = parent ? attribute((__bridge AXUIElementRef)parent, kAXRoleAttribute) : nil;
        [found addObject:@{
          @"id": @(wid),
          @"pid": @(pid),
          @"role": role,
          @"subrole": attribute(element, kAXSubroleAttribute) ?: @"",
          @"title": attribute(element, kAXTitleAttribute) ?: @"",
          @"root": @(!parent || [parentRole isEqual:(id)kAXApplicationRole]),
          @"minimized": @([attribute(element, kAXMinimizedAttribute) boolValue]),
        }];
      }
      @synchronized(rows) {
        [rows addObjectsFromArray:found];
      }
    });
  }
  dispatch_group_notify(group, dispatch_get_main_queue(), ^{
    LuaSkin *main = [LuaSkin sharedWithState:NULL];
    LSGCCanary done = canary;
    if (![main checkGCCanary:canary]) return;
    [main destroyGCCanary:&done];
    lua_State *L = main.L;
    _lua_stackguard_entry(L);
    [main pushLuaRef:refTable ref:ref];
    [main luaUnref:refTable ref:ref];
    lua_pushboolean(L, 1);
    lua_pushnil(L);
    [main pushNSObject:rows];
    [main protectedCallAndError:@"wm windows callback" nargs:3 nresults:0];
    _lua_stackguard_exit(L);
  });
  return 0;
}

/// wm.spaces(ids) -> {[id] = space}, the managed Space id holding each window (absent if none).
static int spaces(lua_State *state) {
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  [skin checkArgs:LS_TTABLE, LS_TBREAK];
  lua_newtable(state);
  lua_Integer count = (lua_Integer)lua_rawlen(state, 1);
  for (lua_Integer index = 1; index <= count; index++) {
    lua_rawgeti(state, 1, index);
    lua_Integer wid = lua_tointeger(state, -1);
    lua_pop(state, 1);
    CFArrayRef result = copySpaces(connection, 0x7, (__bridge CFArrayRef)@[ @(wid) ]);
    NSArray *found = CFBridgingRelease(result);
    if (found.count) {
      lua_pushinteger(state, [found.firstObject longLongValue]);
      lua_rawseti(state, -2, wid);
    }
  }
  return 1;
}

static const luaL_Reg functions[] = {
  { "step", step },
  { "focus", focus },
  { "frame", frame },
  { "minimize", minimize },
  { "windows", windows },
  { "spaces", spaces },
  { NULL, NULL },
};

int luaopen_wm(lua_State *state) {
  if (!keepImageLoaded()) return luaL_error(state, "could not retain wm library");
  if (!copySpaces) {
    void *sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW | RTLD_LOCAL);
    void *hi = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW);
    if (!sky || !hi) return luaL_error(state, "SkyLight unavailable");
    int (*mainConnection)(void) = NULL;
    struct { void *library; const char *name; void *address; size_t size; } symbols[] = {
      { sky, "SLSMainConnectionID", &mainConnection, sizeof mainConnection },
      { sky, "_SLPSSetFrontProcessWithOptions", &setFront, sizeof setFront },
      { sky, "SLPSPostEventRecordTo", &postRecord, sizeof postRecord },
      { sky, "SLSCopySpacesForWindows", &copySpaces, sizeof copySpaces },
      { hi, "_AXUIElementCreateWithRemoteToken", &remoteElement, sizeof remoteElement },
    };
    for (size_t index = 0; index < sizeof symbols / sizeof *symbols; index++) {
      void *symbol = dlsym(symbols[index].library, symbols[index].name);
      if (!symbol) return luaL_error(state, "%s unavailable", symbols[index].name);
      memcpy(symbols[index].address, &symbol, symbols[index].size);
    }
    connection = mainConnection();
    queues = [NSMutableDictionary dictionary];
    elements = [NSMutableDictionary dictionary];
    absent = [NSMutableDictionary dictionary];
    frames = [NSMutableDictionary dictionary];
  }
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  refTable = [skin registerLibrary:"wm" functions:functions metaFunctions:nil];
  return 1;
}
