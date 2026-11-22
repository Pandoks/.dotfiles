#import <Cocoa/Cocoa.h>
#import <LuaSkin/LuaSkin.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <stdatomic.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

@interface EnhancedState : NSObject
@property (nonatomic) BOOL disabled;
@property (nonatomic) uint64_t generation;
@property (nonatomic) NSTimeInterval checked;
@end

@implementation EnhancedState
@end

@interface PendingCallback : NSObject
@property (nonatomic) int ref;
@property (nonatomic) LSGCCanary canary;
@end

@implementation PendingCallback
@end

@interface PendingFrame : NSObject
@property (nonatomic) NSRect rect;
@property (nonatomic, strong) NSMutableArray<PendingCallback *> *callbacks;
@end

@implementation PendingFrame
@end

static LSRefTable refTable = LUA_NOREF;
static dispatch_queue_t frontQueue;
static NSMutableDictionary<NSNumber *, dispatch_queue_t> *queues;
static NSMutableDictionary<NSNumber *, dispatch_queue_t> *focusQueues;
static NSMutableDictionary<NSNumber *, dispatch_queue_t> *focusedQueues;
static NSMutableDictionary<NSNumber *, NSNumber *> *focusedGenerations;
static NSMutableDictionary<NSNumber *, PendingFrame *> *frames;
static NSMutableDictionary<NSNumber *, NSObject *> *scans;
static NSMutableDictionary<NSNumber *, EnhancedState *> *enhancedStates;
static _Atomic BOOL naturalScroll = YES;
static _Atomic uint64_t focusGeneration = 0;

extern AXError _AXUIElementGetWindow(AXUIElementRef element, CGWindowID *windowID);
typedef void (*SLSNotifyProc)(uint32_t type, void *data, size_t dataLength, void *userData, int cid);
static AXUIElementRef (*remoteElement)(CFDataRef token);
static CGError (*setFront)(ProcessSerialNumber *process, CGWindowID windowID, uint32_t mode);
static CGError (*postRecord)(ProcessSerialNumber *process, uint8_t *bytes);
static CFArrayRef (*copySpaces)(int connection, int mask, CFArrayRef windows);
static CFArrayRef (*copyDisplaySpaces)(int connection);
static CFArrayRef (*copySpaceWindows)(int connection, uint32_t owner, CFArrayRef spaces, uint32_t options,
  uint64_t *setTags, uint64_t *clearTags);
static CFTypeRef (*queryWindows)(int connection, CFArrayRef windows, int count);
static CFTypeRef (*copyIterator)(CFTypeRef query);
static bool (*advance)(CFTypeRef iterator);
static uint32_t (*windowOf)(CFTypeRef iterator), (*parentOf)(CFTypeRef iterator);
static int (*pidOf)(CFTypeRef iterator), (*levelOf)(CFTypeRef iterator);
static uint64_t (*tagsOf)(CFTypeRef iterator), (*attributesOf)(CFTypeRef iterator);
static CGError (*registerNotify)(int cid, SLSNotifyProc proc, uint32_t event, void *userData);
static CGError (*removeNotify)(int cid, SLSNotifyProc proc, uint32_t event, void *userData);
static CGError (*windowBounds)(int cid, uint32_t wid, CGRect *outBounds);
static CGError (*windowLevel)(int cid, uint32_t wid, int32_t *outLevel);
static CGError (*windowOwner)(int cid, uint32_t wid, int *outOwner);
static CGError (*connectionPID)(int cid, pid_t *outPID);
static int connection;

enum { spaceWindowAdded = 1325, spaceWindowRemoved = 1326 };
static int spaceWindowRef = LUA_NOREF;
static LSGCCanary spaceWindowCanary;
static BOOL hasSpaceWindowCanary = NO;
static BOOL spaceWindowAddedRegistered = NO;
static BOOL spaceWindowRemovedRegistered = NO;
static _Atomic uint64_t spaceWindowGeneration = 0;

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

// Swipe synthesis from rift (src/sys/space_switch.rs, Apache-2.0) and InstantSpaceSwitcher (MIT).
enum {
  typeField = 55, hidTypeField = 110, maskField = 115, motionField = 123, progressField = 124,
  positionXField = 125, positionYField = 126, velocityXField = 129, velocityYField = 130,
  phaseField = 132, phaseMirrorField = 134, flavorField = 138, timestampField = 169,
  payloadField = 4205,
};
enum { gesture = 29, dockControl = 30, dockSwipe = 23, began = 1, changed = 2, ended = 4 };

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

// Near-zero progress leaves nothing to animate; the fling on the ended phase commits the switch.
static CGEventRef swipe(int phase, uint32_t mask, double sign, CGPoint point) {
  CGEventRef event = CGEventCreate(NULL);
  CGEventSetLocation(event, point);
  CGEventSetIntegerValueField(event, typeField, dockControl);
  CGEventSetIntegerValueField(event, hidTypeField, dockSwipe);
  CGEventSetIntegerValueField(event, phaseField, phase);
  CGEventSetIntegerValueField(event, phaseMirrorField, phase);
  CGEventSetIntegerValueField(event, motionField, 1);
  CGEventSetIntegerValueField(event, maskField, mask);
  CGEventSetDoubleValueField(event, progressField, sign * 0.000016);
  if (phase == ended) CGEventSetDoubleValueField(event, velocityXField, sign * 9999.0);
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

  // Fields are (size, tag << 14 | field, value), sorted by field.
  NSMutableData *serialized = [NSMutableData dataWithBytes:bytes length:4];
  BOOL inserted = NO;
  void (^insert)(void) = ^{
    uint16_t head[2] = { OSSwapHostToBigInt16((uint16_t)payload.length), OSSwapHostToBigInt16(payloadField) };
    [serialized appendBytes:head length:sizeof head];
    [serialized appendData:payload];
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
    if (field != payloadField) [serialized appendBytes:bytes + offset length:4 + width];
    offset += 4 + width;
  }
  if (!inserted) insert();
  CFRelease(data);
  return CGEventCreateFromData(NULL, (__bridge CFDataRef)serialized);
}

// The Dock ignores a swipe without a companion gesture event.
static BOOL post(CGEventRef event) {
  CGEventRef augmented = withPayload(event);
  CFRelease(event);
  if (!augmented) return NO;
  CGEventRef companion = CGEventCreate(NULL);
  CGEventSetIntegerValueField(companion, typeField, gesture);
  CGEventPost(kCGSessionEventTap, augmented);
  CGEventPost(kCGSessionEventTap, companion);
  CFRelease(augmented);
  CFRelease(companion);
  return YES;
}

// The Dock reads the sign through the natural scrolling preference (on unless set off).
static void refreshScroll(void) {
  CFPreferencesAppSynchronize(kCFPreferencesAnyApplication);
  Boolean valid = false;
  Boolean natural = CFPreferencesGetAppBooleanValue(CFSTR("com.apple.swipescrolldirection"),
    kCFPreferencesAnyApplication, &valid);
  atomic_store(&naturalScroll, !valid || natural);
}

static void scrollChanged(CFNotificationCenterRef center, void *observer, CFNotificationName name,
  const void *object, CFDictionaryRef info) {
  (void)center; (void)observer; (void)name; (void)object; (void)info;
  refreshScroll();
}

static int move(lua_State *state) {
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  [skin checkArgs:LS_TBOOLEAN, LS_TNUMBER | LS_TINTEGER, LS_TNUMBER, LS_TNUMBER, LS_TBREAK];
  if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27) {
    lua_pushboolean(state, 0);
    lua_pushstring(state, "instant Space switching needs macOS 27");
    return 2;
  }
  BOOL right = lua_toboolean(state, 1);
  lua_Integer count = lua_tointeger(state, 2);
  CGPoint point = { lua_tonumber(state, 3), lua_tonumber(state, 4) };

  double sign = (right ? -1.0 : 1.0) * (atomic_load(&naturalScroll) ? 1.0 : -1.0);
  uint32_t mask = right ? 4 : 8;
  for (lua_Integer index = 0; index < count; index++) {
    if (!post(swipe(began, mask, sign, point)) || !post(swipe(changed, mask, sign, point))
      || !post(swipe(ended, mask, sign, point))) {
      lua_pushboolean(state, 0);
      lua_pushstring(state, "could not build the Space swipe");
      return 2;
    }
  }
  lua_pushboolean(state, 1);
  return 1;
}

#pragma mark - Accessibility

// One serial queue per app: a busy app delays only its own requests.
static dispatch_queue_t queueFor(NSMutableDictionary<NSNumber *, dispatch_queue_t> *pool,
  const char *label, pid_t pid) {
  NSNumber *key = @(pid);
  @synchronized(pool) {
    dispatch_queue_t queue = pool[key];
    if (!queue) {
      queue = dispatch_queue_create(label, dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
      pool[key] = queue;
    }
    return queue;
  }
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

static BOOL onSameDisplay(CGRect first, CGRect second, CGRect *bounds) {
  CGDirectDisplayID firstDisplays[2], secondDisplays[2];
  uint32_t firstCount = 0, secondCount = 0;
  if (CGGetDisplaysWithRect(first, 2, firstDisplays, &firstCount) != kCGErrorSuccess || firstCount != 1) return NO;
  if (CGGetDisplaysWithRect(second, 2, secondDisplays, &secondCount) != kCGErrorSuccess || secondCount != 1) return NO;
  if (firstDisplays[0] != secondDisplays[0]) return NO;
  *bounds = CGDisplayBounds(firstDisplays[0]);
  return YES;
}

// Per-app caches guarded by the PID's dictionary; absent = ids no search found.
static NSMutableDictionary<NSNumber *, NSMutableDictionary<NSNumber *, id> *> *elements;
static NSMutableDictionary<NSNumber *, NSMutableSet<NSNumber *> *> *absent;

static BOOL screenIsLocked(void) {
  NSDictionary *session = CFBridgingRelease(CGSessionCopyCurrentDictionary());
  if (![session isKindOfClass:NSDictionary.class]) return NO;
  NSNumber *locked = session[@"CGSSessionScreenIsLocked"];
  if ([locked isKindOfClass:NSNumber.class] && locked.boolValue) return YES;
  NSNumber *onConsole = session[(__bridge NSString *)kCGSessionOnConsoleKey];
  if ([onConsole isKindOfClass:NSNumber.class] && !onConsole.boolValue) return YES;
  return NO;
}

static void clearAbsent(void) {
  NSArray<NSNumber *> *pids;
  @synchronized(elements) {
    pids = absent.allKeys;
  }
  for (NSNumber *pidKey in pids) {
    NSMutableDictionary<NSNumber *, id> *cache;
    NSMutableSet<NSNumber *> *skipped;
    @synchronized(elements) {
      cache = elements[pidKey];
      skipped = absent[pidKey];
    }
    if (!skipped) continue;
    if (cache) {
      @synchronized(cache) {
        [skipped removeAllObjects];
      }
    } else {
      @synchronized(elements) {
        [skipped removeAllObjects];
      }
    }
  }
}

static void screenUnlocked(CFNotificationCenterRef center, void *observer, CFNotificationName name,
  const void *object, CFDictionaryRef info) {
  (void)center; (void)observer; (void)name; (void)object; (void)info;
  clearAbsent();
}

// Windows on other Spaces aren't in AXWindows; unseen ids are searched once by remote token.
static NSDictionary<NSNumber *, id> *resolve(pid_t pid, NSSet<NSNumber *> *wanted, NSSet<NSNumber *> *searchable) {
  NSMutableDictionary<NSNumber *, id> *cache;
  NSMutableSet<NSNumber *> *skipped;
  NSObject *scanLock;
  @synchronized(elements) {
    NSNumber *pidKey = @(pid);
    cache = elements[pidKey] ?: (elements[pidKey] = [NSMutableDictionary dictionary]);
    skipped = absent[pidKey] ?: (absent[pidKey] = [NSMutableSet set]);
    scanLock = scans[pidKey] ?: (scans[pidKey] = [NSObject new]);
  }
  NSMutableDictionary<NSNumber *, id> *resolved = [NSMutableDictionary dictionary];
  NSMutableSet<NSNumber *> *missing = [wanted mutableCopy], *unlisted = [wanted mutableCopy];
  [unlisted minusSet:searchable];
  @synchronized(cache) {
    for (NSNumber *windowID in wanted) {
      id cached = cache[windowID];
      if (cached) {
        resolved[windowID] = cached;
        [missing removeObject:windowID];
      }
    }
  }
  if (!missing.count && !unlisted.count) return resolved;
  if (screenIsLocked()) return resolved;

  // AXWindows is rechecked every time: a window can gain its element after a search missed it.
  NSMutableDictionary<NSNumber *, id> *discovered = [NSMutableDictionary dictionary];
  AXUIElementRef app = application(pid);
  CFTypeRef axValue = NULL;
  AXError axStatus = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, &axValue);
  BOOL axHealthy = (axStatus == kAXErrorSuccess || axStatus == kAXErrorNoValue
    || axStatus == kAXErrorAttributeUnsupported);
  NSArray *axList = (axStatus == kAXErrorSuccess && axValue) ? CFBridgingRelease(axValue) : nil;
  if (axStatus != kAXErrorSuccess && axValue) CFRelease(axValue);
  for (id element in [axList isKindOfClass:NSArray.class] ? axList : @[]) {
    CGWindowID windowID = 0;
    if (_AXUIElementGetWindow((__bridge AXUIElementRef)element, &windowID) != kAXErrorSuccess) continue;
    AXUIElementSetMessagingTimeout((__bridge AXUIElementRef)element, 1.0);
    discovered[@(windowID)] = element;
    [missing removeObject:@(windowID)];
    [unlisted removeObject:@(windowID)];
  }
  CFRelease(app);

  @synchronized(cache) {
    [cache addEntriesFromDictionary:discovered];
    // Unsearchable ids count only while AXWindows lists them.
    if (unlisted.count && axHealthy) {
      NSArray *drop = unlisted.allObjects;
      [cache removeObjectsForKeys:drop];
      [resolved removeObjectsForKeys:drop];
    }
    for (NSNumber *windowID in wanted) {
      id cached = cache[windowID];
      if (cached) {
        resolved[windowID] = cached;
        [missing removeObject:windowID];
      }
    }
    [missing minusSet:skipped];
  }
  [missing intersectSet:searchable];
  if (!missing.count || !axHealthy || screenIsLocked()) return resolved;

  @synchronized(scanLock) {
    @synchronized(cache) {
      for (NSNumber *windowID in [missing copy]) {
        id cached = cache[windowID];
        if (cached) {
          resolved[windowID] = cached;
          [missing removeObject:windowID];
        }
      }
      [missing minusSet:skipped];
    }
    if (!missing.count || screenIsLocked()) return resolved;

    uint8_t token[0x14] = { 0 };
    uint32_t magic = 0x636f636f;
    memcpy(token, &pid, sizeof pid);
    memcpy(token + 0x8, &magic, sizeof magic);
    NSMutableDictionary<NSNumber *, id> *found = [NSMutableDictionary dictionary];
    NSMutableSet<NSNumber *> *unread = [NSMutableSet set];
    BOOL scanAborted = NO;
    for (uint64_t element = 0; element < 0x7fff && missing.count; element++) {
      memcpy(token + 0xc, &element, sizeof element);
      CFDataRef data = CFDataCreate(NULL, token, sizeof token);
      AXUIElementRef candidate = remoteElement(data);
      CFRelease(data);
      if (!candidate) continue;
      CGWindowID windowID = 0;
      AXError widError = _AXUIElementGetWindow(candidate, &windowID);
      if (widError == kAXErrorAPIDisabled || widError == kAXErrorCannotComplete) {
        scanAborted = YES;
        CFRelease(candidate);
        break;
      }
      if (widError == kAXErrorSuccess && [missing containsObject:@(windowID)]) {
        AXUIElementSetMessagingTimeout(candidate, 1.0);
        // Menu bars report their window's id too.
        CFTypeRef role = NULL;
        if (AXUIElementCopyAttributeValue(candidate, kAXRoleAttribute, &role) != kAXErrorSuccess) {
          [unread addObject:@(windowID)];
        } else if (CFEqual(role, kAXWindowRole)) {
          found[@(windowID)] = (__bridge id)candidate;
          [missing removeObject:@(windowID)];
        }
        if (role) CFRelease(role);
      }
      CFRelease(candidate);
    }
    @synchronized(cache) {
      [cache addEntriesFromDictionary:found];
      [resolved addEntriesFromDictionary:found];
      if (!scanAborted && !screenIsLocked()) {
        // A timed-out read isn't proof of absence; search again next time.
        [missing minusSet:unread];
        [skipped unionSet:missing];
      }
    }
  }
  return resolved;
}

static AXUIElementRef copyWindow(pid_t pid, CGWindowID windowID) {
  NSSet *wanted = [NSSet setWithObject:@(windowID)];
  id element = resolve(pid, wanted, wanted)[@(windowID)];
  return element ? (AXUIElementRef)CFBridgingRetain(element) : NULL;
}

// A destroyed window's element stays cached until its id is looked up again.
static void forget(pid_t pid, CGWindowID windowID) {
  NSMutableDictionary<NSNumber *, id> *cache;
  @synchronized(elements) {
    cache = elements[@(pid)];
  }
  if (cache) {
    @synchronized(cache) {
      [cache removeObjectForKey:@(windowID)];
    }
  }
}

#pragma mark - Lua callbacks

static void deliver(int callback, LSGCCanary canary, NSString *error) {
  dispatch_async(dispatch_get_main_queue(), ^{
    LuaSkin *main = [LuaSkin sharedWithState:NULL];
    LSGCCanary done = canary;
    if (![main checkGCCanary:canary]) return;
    [main destroyGCCanary:&done];
    if (callback == LUA_NOREF) return;
    lua_State *lua = main.L;
    _lua_stackguard_entry(lua);
    [main pushLuaRef:refTable ref:callback];
    [main luaUnref:refTable ref:callback];
    lua_pushboolean(lua, error == nil);
    if (error) lua_pushstring(lua, error.UTF8String); else lua_pushnil(lua);
    [main protectedCallAndError:@"window_manager callback" nargs:2 nresults:0];
    _lua_stackguard_exit(lua);
  });
}

static void schedule(lua_State *state, int argument, dispatch_queue_t queue, NSString *(^work)(void)) {
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  int callback = LUA_NOREF;
  if (lua_isfunction(state, argument)) {
    lua_pushvalue(state, argument);
    callback = [skin luaRef:refTable];
  }
  LSGCCanary canary = [skin createGCCanary];
  dispatch_async(queue, ^{
    deliver(callback, canary, work());
  });
}

static BOOL spaceIsActive(uint64_t space) {
  NSArray *displays = CFBridgingRelease(copyDisplaySpaces(connection));
  if (![displays isKindOfClass:NSArray.class]) return NO;
  for (NSDictionary *display in displays) {
    if (![display isKindOfClass:NSDictionary.class]) continue;
    NSDictionary *current = display[@"Current Space"];
    NSNumber *active = [current isKindOfClass:NSDictionary.class] ? current[@"ManagedSpaceID"] : nil;
    if ([active isKindOfClass:NSNumber.class] && active.unsignedLongLongValue == space) return YES;
  }
  return NO;
}

static BOOL windowExists(pid_t pid, CGWindowID windowID) {
  CFTypeRef query = queryWindows(connection, (__bridge CFArrayRef)@[ @(windowID) ], 1);
  CFTypeRef iterator = query ? copyIterator(query) : NULL;
  BOOL match = NO;
  while (iterator && advance(iterator)) {
    if (windowOf(iterator) == windowID && pidOf(iterator) == pid) {
      match = YES;
      break;
    }
  }
  if (iterator) CFRelease(iterator);
  if (query) CFRelease(query);
  return match;
}

static int cancelFocus(lua_State *state) {
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  [skin checkArgs:LS_TBREAK];
  atomic_fetch_add(&focusGeneration, 1);
  return 0;
}

static int focus(lua_State *state) {
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  [skin checkArgs:LS_TNUMBER | LS_TINTEGER, LS_TNUMBER | LS_TINTEGER,
    LS_TFUNCTION | LS_TNIL | LS_TOPTIONAL, LS_TNUMBER | LS_TINTEGER | LS_TNIL | LS_TOPTIONAL, LS_TBREAK];
  pid_t pid = (pid_t)lua_tointeger(state, 1);
  CGWindowID windowID = (CGWindowID)lua_tointeger(state, 2);
  int callback = LUA_NOREF;
  if (lua_isfunction(state, 3)) {
    lua_pushvalue(state, 3);
    callback = [skin luaRef:refTable];
  }
  LSGCCanary canary = [skin createGCCanary];
  uint64_t expectedSpace = lua_isnumber(state, 4) ? (uint64_t)lua_tointeger(state, 4) : 0;
  uint64_t token = atomic_fetch_add(&focusGeneration, 1) + 1;
  dispatch_async(frontQueue, ^{
    if (atomic_load(&focusGeneration) != token || (expectedSpace && !spaceIsActive(expectedSpace))) {
      deliver(callback, canary, @"superseded");
      return;
    }
    ProcessSerialNumber process;
    if (GetProcessForPID(pid, &process) != noErr) {
      deliver(callback, canary, @"process unavailable");
      return;
    }
    if (!windowExists(pid, windowID)) {
      forget(pid, windowID);
      deliver(callback, canary, @"window unavailable");
      return;
    }

    // Front process and key-window event records return immediately; AX raise finishes on the app's queue.
    CGError fronted = setFront(&process, windowID, 0x200);
    uint8_t record[0xf8] = { [0x04] = 0xf8, [0x3a] = 0x10 };
    memcpy(record + 0x3c, &windowID, sizeof windowID);
    memset(record + 0x20, 0xFF, 0x10);
    record[0x08] = 0x01;
    CGError pressed = fronted ?: postRecord(&process, record);
    record[0x08] = 0x02;
    CGError released = pressed ?: postRecord(&process, record);
    if (released != kCGErrorSuccess) {
      deliver(callback, canary, [NSString stringWithFormat:@"focus failed (%d)", released]);
      return;
    }

    dispatch_async(queueFor(focusQueues, "window_manager.focus", pid), ^{
      if (atomic_load(&focusGeneration) != token || (expectedSpace && !spaceIsActive(expectedSpace))) {
        deliver(callback, canary, @"superseded");
        return;
      }
      AXUIElementRef target = copyWindow(pid, windowID);
      if (!target) {
        deliver(callback, canary, @"window unavailable");
        return;
      }
      if (atomic_load(&focusGeneration) != token || (expectedSpace && !spaceIsActive(expectedSpace))) {
        CFRelease(target);
        deliver(callback, canary, @"superseded");
        return;
      }
      AXError raised = AXUIElementPerformAction(target, kAXRaiseAction);
      CFRelease(target);
      if (raised == kAXErrorInvalidUIElement) forget(pid, windowID);
      deliver(callback, canary,
        raised == kAXErrorSuccess ? nil : [NSString stringWithFormat:@"raise failed (%d)", raised]);
    });
  });
  return 0;
}

static uint64_t nextFocusedGeneration(pid_t pid) {
  NSNumber *key = @(pid);
  @synchronized(focusedGenerations) {
    uint64_t next = [focusedGenerations[key] unsignedLongLongValue] + 1;
    focusedGenerations[key] = @(next);
    return next;
  }
}

static uint64_t currentFocusedGeneration(pid_t pid) {
  @synchronized(focusedGenerations) {
    return [focusedGenerations[@(pid)] unsignedLongLongValue];
  }
}

static int focusedWindow(lua_State *state) {
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  [skin checkArgs:LS_TNUMBER | LS_TINTEGER, LS_TFUNCTION, LS_TBREAK];
  pid_t pid = (pid_t)lua_tointeger(state, 1);
  lua_pushvalue(state, 2);
  int callback = [skin luaRef:refTable];
  LSGCCanary canary = [skin createGCCanary];
  uint64_t token = nextFocusedGeneration(pid);
  dispatch_async(queueFor(focusedQueues, "window_manager.focused", pid), ^{
    CGWindowID windowID = 0;
    NSString *failure = nil;
    if (currentFocusedGeneration(pid) != token) {
      failure = @"cancelled";
    } else {
      AXUIElementRef app = application(pid);
      CFTypeRef value = NULL;
      AXError status = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute, &value);
      CFRelease(app);
      if (status == kAXErrorSuccess) {
        if (currentFocusedGeneration(pid) != token) {
          failure = @"cancelled";
        } else if (value) {
          if (_AXUIElementGetWindow((AXUIElementRef)value, &windowID) != kAXErrorSuccess) windowID = 0;
        }
        if (value) CFRelease(value);
      } else if (status != kAXErrorNoValue && status != kAXErrorAttributeUnsupported) {
        failure = [NSString stringWithFormat:@"focused window failed (%d)", status];
      }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      LuaSkin *main = [LuaSkin sharedWithState:NULL];
      LSGCCanary done = canary;
      if (![main checkGCCanary:canary]) return;
      [main destroyGCCanary:&done];
      lua_State *lua = main.L;
      _lua_stackguard_entry(lua);
      [main pushLuaRef:refTable ref:callback];
      [main luaUnref:refTable ref:callback];
      if (windowID) lua_pushinteger(lua, windowID); else lua_pushnil(lua);
      if (failure) lua_pushstring(lua, failure.UTF8String); else lua_pushnil(lua);
      [main protectedCallAndError:@"window_manager focusedWindow callback" nargs:2 nresults:0];
      _lua_stackguard_exit(lua);
    });
  });
  return 0;
}

static BOOL closeEnough(CGFloat first, CGFloat second) {
  return fabs(first - second) < 0.5;
}

/// Requests not yet started collapse to the latest, delivering its result to every caller.
static int frame(lua_State *state) {
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  [skin checkArgs:LS_TNUMBER | LS_TINTEGER, LS_TNUMBER | LS_TINTEGER, LS_TNUMBER, LS_TNUMBER, LS_TNUMBER,
    LS_TNUMBER, LS_TFUNCTION | LS_TOPTIONAL, LS_TBREAK];
  pid_t pid = (pid_t)lua_tointeger(state, 1);
  CGWindowID windowID = (CGWindowID)lua_tointeger(state, 2);
  NSRect targetRect = NSMakeRect(lua_tonumber(state, 3), lua_tonumber(state, 4),
    lua_tonumber(state, 5), lua_tonumber(state, 6));
  PendingCallback *cb = nil;
  if (lua_isfunction(state, 7)) {
    cb = [PendingCallback new];
    lua_pushvalue(state, 7);
    cb.ref = [skin luaRef:refTable];
    cb.canary = [skin createGCCanary];
  }
  NSNumber *key = @(windowID);
  BOOL shouldSchedule = NO;
  @synchronized(frames) {
    PendingFrame *pending = frames[key];
    if (!pending) {
      pending = [PendingFrame new];
      pending.callbacks = [NSMutableArray array];
      frames[key] = pending;
      shouldSchedule = YES;
    }
    pending.rect = targetRect;
    if (cb) [pending.callbacks addObject:cb];
  }
  if (!shouldSchedule) return 0;

  dispatch_queue_t queue = queueFor(queues, "window_manager.app", pid);
  dispatch_async(queue, ^{
    PendingFrame *job;
    @synchronized(frames) {
      job = frames[key];
      [frames removeObjectForKey:key];
    }
    if (!job) return;
    NSRect rect = job.rect;
    NSString *error = nil;
    CGRect target = NSRectToCGRect(rect);
    CGRect actual = CGRectZero;
    BOOL hasActual = (windowBounds(connection, windowID, &actual) == kCGErrorSuccess
      && actual.size.width > 0 && actual.size.height > 0);
    if (!(hasActual && closeEnough(actual.origin.x, target.origin.x)
      && closeEnough(actual.origin.y, target.origin.y)
      && closeEnough(actual.size.width, target.size.width)
      && closeEnough(actual.size.height, target.size.height))) {
      AXUIElementRef window = copyWindow(pid, windowID);
      if (!window) {
        error = @"window unavailable";
      } else {
        // Chromium and Electron animate frame changes while enhanced UI is on.
        EnhancedState *enhanced;
        @synchronized(enhancedStates) {
          enhanced = enhancedStates[@(pid)] ?: (enhancedStates[@(pid)] = [EnhancedState new]);
        }
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        if (!enhanced.disabled && (!enhanced.checked || now - enhanced.checked >= 2.0)) {
          AXUIElementRef app = application(pid);
          if ([attribute(app, CFSTR("AXEnhancedUserInterface")) boolValue]) {
            AXUIElementSetAttributeValue(app, CFSTR("AXEnhancedUserInterface"), kCFBooleanFalse);
            enhanced.disabled = YES;
            enhanced.checked = 0;
          } else {
            enhanced.checked = now;
          }
          CFRelease(app);
        }

        // Size, position, size: a window shrinking across a display edge is clamped otherwise.
        BOOL sameSize = hasActual && closeEnough(actual.size.width, target.size.width)
          && closeEnough(actual.size.height, target.size.height);
        CGPoint origin = rect.origin;
        AXValueRef originValue = AXValueCreate(kAXValueCGPointType, &origin);
        AXError moved = kAXErrorSuccess, resized = kAXErrorSuccess;
        if (sameSize) {
          moved = AXUIElementSetAttributeValue(window, kAXPositionAttribute, originValue);
        } else {
          CGSize size = rect.size;
          AXValueRef sizeValue = AXValueCreate(kAXValueCGSizeType, &size);
          BOOL leadSize = YES;
          if (hasActual) {
            CGRect displayBounds = CGRectZero;
            if (onSameDisplay(actual, target, &displayBounds)
              && CGRectContainsRect(displayBounds, CGRectMake(target.origin.x, target.origin.y,
                actual.size.width, actual.size.height))) {
              leadSize = NO;
            }
          }
          if (leadSize) AXUIElementSetAttributeValue(window, kAXSizeAttribute, sizeValue);
          moved = AXUIElementSetAttributeValue(window, kAXPositionAttribute, originValue);
          resized = AXUIElementSetAttributeValue(window, kAXSizeAttribute, sizeValue);
          CFRelease(sizeValue);
        }
        CFRelease(originValue);
        CFRelease(window);

        if (enhanced.disabled) {
          uint64_t token = ++enhanced.generation;
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(150 * NSEC_PER_MSEC)), queue, ^{
            if (!enhanced.disabled || enhanced.generation != token) return;
            enhanced.disabled = NO;
            AXUIElementRef targetApp = application(pid);
            AXUIElementSetAttributeValue(targetApp, CFSTR("AXEnhancedUserInterface"), kCFBooleanTrue);
            CFRelease(targetApp);
          });
        }

        if (moved == kAXErrorInvalidUIElement || resized == kAXErrorInvalidUIElement) forget(pid, windowID);
        if (moved != kAXErrorSuccess || resized != kAXErrorSuccess) {
          error = [NSString stringWithFormat:@"frame failed (%d, %d)", moved, resized];
        }
      }
    }
    for (PendingCallback *entry in job.callbacks) {
      deliver(entry.ref, entry.canary, error);
    }
  });
  return 0;
}

static int minimize(lua_State *state) {
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  [skin checkArgs:LS_TNUMBER | LS_TINTEGER, LS_TNUMBER | LS_TINTEGER, LS_TBOOLEAN, LS_TFUNCTION | LS_TOPTIONAL,
    LS_TBREAK];
  pid_t pid = (pid_t)lua_tointeger(state, 1);
  CGWindowID windowID = (CGWindowID)lua_tointeger(state, 2);
  CFBooleanRef minimized = lua_toboolean(state, 3) ? kCFBooleanTrue : kCFBooleanFalse;
  schedule(state, 4, queueFor(queues, "window_manager.app", pid), ^NSString *{
    AXUIElementRef window = copyWindow(pid, windowID);
    if (!window) return @"window unavailable";
    AXError result = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute, minimized);
    CFRelease(window);
    if (result == kAXErrorInvalidUIElement) forget(pid, windowID);
    return result == kAXErrorSuccess ? nil : [NSString stringWithFormat:@"minimize failed (%d)", result];
  });
  return 0;
}

static int windows(lua_State *state) {
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  [skin checkArgs:LS_TFUNCTION, LS_TTABLE | LS_TOPTIONAL, LS_TBREAK];
  NSMutableSet<NSNumber *> *filter = nil;
  if (lua_istable(state, 2)) {
    filter = [NSMutableSet set];
    lua_pushnil(state);
    while (lua_next(state, 2)) {
      int valid = 0;
      if (lua_type(state, -1) == LUA_TNUMBER) {
        lua_Integer target = lua_tointegerx(state, -1, &valid);
        if (valid && target > 0) [filter addObject:@((pid_t)target)];
      } else if (lua_toboolean(state, -1) && lua_type(state, -2) == LUA_TNUMBER) {
        lua_Integer target = lua_tointegerx(state, -2, &valid);
        if (valid && target > 0) [filter addObject:@((pid_t)target)];
      }
      lua_pop(state, 1);
    }
  }

  // yabai's bits. Menu-bar strips and closed find bars match none, so they're never searched.
  enum : uint64_t { shownAttribute = 0x2, shownTag = 1ULL << 58, minimizedTag = 1ULL << 60, hiddenTag = 1ULL << 39 };
  NSString *failure = nil;
  NSMutableDictionary<NSNumber *, NSMutableSet<NSNumber *> *> *owners = [NSMutableDictionary dictionary];
  NSMutableDictionary<NSNumber *, NSMutableSet<NSNumber *> *> *reals = [NSMutableDictionary dictionary];
  if (!filter || filter.count) {
    CFArrayRef list = CGWindowListCreate(kCGWindowListOptionAll, kCGNullWindowID);
    NSMutableArray<NSNumber *> *ids = [NSMutableArray array];
    for (CFIndex index = 0; list && index < CFArrayGetCount(list); index++) {
      [ids addObject:@((CGWindowID)(uintptr_t)CFArrayGetValueAtIndex(list, index))];
    }
    if (list) CFRelease(list);
    CFTypeRef query = queryWindows(connection, (__bridge CFArrayRef)ids, (int)ids.count);
    CFTypeRef iterator = query ? copyIterator(query) : NULL;
    if (!iterator) failure = @"window server query failed";
    while (iterator && advance(iterator)) {
      pid_t ownerPID = pidOf(iterator);
      if (levelOf(iterator) || parentOf(iterator) || ownerPID == getpid()) continue;
      NSNumber *pid = @(ownerPID);
      if (filter && ![filter containsObject:pid]) continue;
      NSNumber *windowID = @(windowOf(iterator));
      NSMutableSet *set = owners[pid] ?: (owners[pid] = [NSMutableSet set]);
      [set addObject:windowID];
      uint64_t tags = tagsOf(iterator);
      if (!(attributesOf(iterator) & shownAttribute) && !(tags & (shownTag | minimizedTag | hiddenTag))) continue;
      set = reals[pid] ?: (reals[pid] = [NSMutableSet set]);
      [set addObject:windowID];
    }
    if (iterator) CFRelease(iterator);
    if (query) CFRelease(query);
  }

  lua_pushvalue(state, 1);
  int callback = [skin luaRef:refTable];
  LSGCCanary canary = [skin createGCCanary];
  dispatch_group_t group = dispatch_group_create();
  NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
  for (NSNumber *owner in owners) {
    NSSet *wantedAll = [owners[owner] copy], *real = [reals[owner] copy] ?: [NSSet set];
    pid_t pid = owner.intValue;
    dispatch_group_async(group, queueFor(queues, "window_manager.app", pid), ^{
      // Background processes never answer. Off the main thread: policies refetch each run loop turn.
      NSRunningApplication *running = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
      if (!running || running.activationPolicy != NSApplicationActivationPolicyRegular) return;
      // Windows made while hidden were never shown but are in AXWindows.
      NSSet *wanted = running.hidden ? wantedAll : real;
      if (!wanted.count) return;
      // Ids that left the window server may come back for new windows; search those again.
      NSMutableDictionary<NSNumber *, id> *cache;
      NSMutableSet<NSNumber *> *skipped;
      @synchronized(elements) {
        NSNumber *pidKey = @(pid);
        cache = elements[pidKey] ?: (elements[pidKey] = [NSMutableDictionary dictionary]);
        skipped = absent[pidKey] ?: (absent[pidKey] = [NSMutableSet set]);
      }
      @synchronized(cache) {
        [skipped intersectSet:wanted];
      }
      NSMutableArray *found = [NSMutableArray array];
      NSDictionary<NSNumber *, id> *resolved = resolve(pid, wanted, real);
      AXUIElementRef app = application(pid);
      NSArray *names = @[ (id)kAXRoleAttribute, (id)kAXSubroleAttribute, (id)kAXTitleAttribute,
        (id)kAXMinimizedAttribute, (id)kAXParentAttribute ];
      for (NSNumber *key in wanted) {
        AXUIElementRef element = (__bridge AXUIElementRef)resolved[key];
        if (!element) continue;
        CGWindowID windowID = key.unsignedIntValue;
        // Missing attributes come back as AXValue errors.
        CFArrayRef copied = NULL;
        AXUIElementCopyMultipleAttributeValues(element, (__bridge CFArrayRef)names, 0, &copied);
        NSMutableArray *values = [CFBridgingRelease(copied) mutableCopy];
        for (NSUInteger index = 0; index < values.count; index++) {
          if (CFGetTypeID((__bridge CFTypeRef)values[index]) == AXValueGetTypeID()) values[index] = NSNull.null;
        }
        if (values.count != names.count || values[0] == NSNull.null) {
          forget(pid, windowID);
          continue;
        }
        id parent = values[4];
        [found addObject:@{
          @"id": @(windowID),
          @"pid": @(pid),
          @"role": values[0],
          @"subrole": values[1] == NSNull.null ? @"" : values[1],
          @"title": values[2] == NSNull.null ? @"" : values[2],
          @"root": @((BOOL)(parent == NSNull.null || CFEqual((__bridge CFTypeRef)parent, app))),
          @"minimized": @([values[3] isEqual:@YES]),
        }];
      }
      CFRelease(app);
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
    lua_State *lua = main.L;
    _lua_stackguard_entry(lua);
    [main pushLuaRef:refTable ref:callback];
    [main luaUnref:refTable ref:callback];
    lua_pushboolean(lua, failure == nil);
    if (failure) lua_pushstring(lua, failure.UTF8String); else lua_pushnil(lua);
    [main pushNSObject:rows];
    [main protectedCallAndError:@"window_manager windows callback" nargs:3 nresults:0];
    _lua_stackguard_exit(lua);
  });
  return 0;
}

static int spaces(lua_State *state) {
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  [skin checkArgs:LS_TTABLE, LS_TBREAK];
  lua_newtable(state);
  lua_Integer count = (lua_Integer)lua_rawlen(state, 1);
  if (count == 0) return 1;
  if (count == 1) {
    lua_rawgeti(state, 1, 1);
    lua_Integer windowID = lua_tointeger(state, -1);
    lua_pop(state, 1);
    NSArray *found = CFBridgingRelease(copySpaces(connection, 0x7, (__bridge CFArrayRef)@[ @(windowID) ]));
    if (found.count) {
      lua_pushinteger(state, [found.firstObject longLongValue]);
      lua_rawseti(state, -2, windowID);
    }
    return 1;
  }

  NSMutableSet<NSNumber *> *wanted = [NSMutableSet setWithCapacity:(NSUInteger)count];
  for (lua_Integer index = 1; index <= count; index++) {
    lua_rawgeti(state, 1, index);
    lua_Integer windowID = lua_tointeger(state, -1);
    lua_pop(state, 1);
    [wanted addObject:@((CGWindowID)windowID)];
  }
  NSArray *displays = CFBridgingRelease(copyDisplaySpaces(connection));
  if (![displays isKindOfClass:NSArray.class]) {
    return luaL_error(state, "could not read managed Spaces");
  }
  for (NSDictionary *display in displays) {
    if (!wanted.count) break;
    if (![display isKindOfClass:NSDictionary.class]) continue;
    NSArray *entries = display[@"Spaces"];
    if (![entries isKindOfClass:NSArray.class]) continue;
    for (NSDictionary *entry in entries) {
      if (!wanted.count) break;
      if (![entry isKindOfClass:NSDictionary.class]) continue;
      NSNumber *spaceID = entry[@"ManagedSpaceID"];
      if (![spaceID isKindOfClass:NSNumber.class]) continue;
      uint64_t setTags = 0, clearTags = 0;
      NSArray *members = CFBridgingRelease(copySpaceWindows(connection, 0,
        (__bridge CFArrayRef)@[ spaceID ], 0x7, &setTags, &clearTags));
      for (NSNumber *member in members) {
        if (![wanted containsObject:member]) continue;
        lua_pushinteger(state, spaceID.longLongValue);
        lua_rawseti(state, -2, member.longLongValue);
        [wanted removeObject:member];
        if (!wanted.count) break;
      }
    }
  }
  return 1;
}

static NSString *mainDisplayUUID(void) {
  CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID());
  if (!uuid) return nil;
  NSString *string = CFBridgingRelease(CFUUIDCreateString(NULL, uuid));
  CFRelease(uuid);
  return string;
}

static int displaySpaces(lua_State *state) {
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  [skin checkArgs:LS_TBREAK];
  NSArray *displays = CFBridgingRelease(copyDisplaySpaces(connection));
  if (![displays isKindOfClass:NSArray.class]) {
    lua_pushnil(state);
    lua_pushstring(state, "could not read managed Spaces");
    return 2;
  }

  lua_newtable(state);
  lua_newtable(state);
  lua_newtable(state);
  lua_newtable(state);
  NSString *mainUUID = nil;
  lua_Integer position = 0;
  for (NSDictionary *display in displays) {
    if (![display isKindOfClass:NSDictionary.class]) continue;
    NSString *uuid = display[@"Display Identifier"];
    if (![uuid isKindOfClass:NSString.class]) continue;
    if ([uuid isEqualToString:@"Main"]) {
      if (!mainUUID) mainUUID = mainDisplayUUID();
      if (!mainUUID) continue;
      uuid = mainUUID;
    }
    NSDictionary *current = display[@"Current Space"];
    NSNumber *activeID = [current isKindOfClass:NSDictionary.class] ? current[@"ManagedSpaceID"] : nil;
    if ([activeID isKindOfClass:NSNumber.class]) {
      lua_pushinteger(state, activeID.longLongValue);
      lua_setfield(state, -3, uuid.UTF8String);
    }
    NSArray *entries = display[@"Spaces"];
    if (![entries isKindOfClass:NSArray.class]) continue;
    for (NSDictionary *entry in entries) {
      if (![entry isKindOfClass:NSDictionary.class]) continue;
      NSNumber *spaceID = entry[@"ManagedSpaceID"];
      if (![spaceID isKindOfClass:NSNumber.class]) continue;
      position++;

      lua_createtable(state, 0, 2);
      lua_pushinteger(state, spaceID.longLongValue);
      lua_setfield(state, -2, "id");
      lua_pushstring(state, uuid.UTF8String);
      lua_setfield(state, -2, "display");
      lua_rawseti(state, -4, position);

      lua_createtable(state, 0, 2);
      lua_pushinteger(state, position);
      lua_setfield(state, -2, "index");
      lua_pushstring(state, uuid.UTF8String);
      lua_setfield(state, -2, "display");
      lua_rawseti(state, -2, spaceID.longLongValue);
    }
  }
  lua_setfield(state, -4, "bySpace");
  lua_setfield(state, -3, "active");
  lua_setfield(state, -2, "spaces");
  return 1;
}

static void spaceWindowChanged(uint32_t type, void *data, size_t dataLength, void *userData, int cid);

static void clearSpaceWindowWatcher(void) {
  atomic_fetch_add(&spaceWindowGeneration, 1);
  if (spaceWindowAddedRegistered) {
    removeNotify(connection, spaceWindowChanged, spaceWindowAdded, NULL);
    spaceWindowAddedRegistered = NO;
  }
  if (spaceWindowRemovedRegistered) {
    removeNotify(connection, spaceWindowChanged, spaceWindowRemoved, NULL);
    spaceWindowRemovedRegistered = NO;
  }
  if (hasSpaceWindowCanary) {
    LuaSkin *skin = [LuaSkin sharedWithState:NULL];
    if (skin && [skin checkGCCanary:spaceWindowCanary]) {
      if (spaceWindowRef != LUA_NOREF) {
        [skin luaUnref:refTable ref:spaceWindowRef];
      }
      [skin destroyGCCanary:&spaceWindowCanary];
    }
    hasSpaceWindowCanary = NO;
  }
  spaceWindowRef = LUA_NOREF;
}

static void spaceWindowChanged(uint32_t type, void *data, size_t dataLength, void *userData, int cid) {
  (void)userData;
  (void)cid;
  if (!data || dataLength < sizeof(uint64_t) + sizeof(uint32_t)) return;
  uint64_t spaceID = 0;
  uint32_t windowID = 0;
  memcpy(&spaceID, data, sizeof spaceID);
  memcpy(&windowID, (const uint8_t *)data + sizeof spaceID, sizeof windowID);
  if (!spaceID || !windowID) return;

  int32_t level = 0;
  if (windowLevel(connection, windowID, &level) == kCGErrorSuccess && level != 0) return;

  pid_t ownerPID = 0;
  int ownerCid = 0;
  if (windowOwner(connection, windowID, &ownerCid) == kCGErrorSuccess) {
    connectionPID(ownerCid, &ownerPID);
  }
  if (ownerPID == getpid()) return;

  BOOL added = (type == spaceWindowAdded);
  uint64_t generation = atomic_load(&spaceWindowGeneration);
  dispatch_async(dispatch_get_main_queue(), ^{
    if (atomic_load(&spaceWindowGeneration) != generation || !hasSpaceWindowCanary || spaceWindowRef == LUA_NOREF) {
      return;
    }
    LuaSkin *main = [LuaSkin sharedWithState:NULL];
    if (![main checkGCCanary:spaceWindowCanary]) {
      clearSpaceWindowWatcher();
      return;
    }
    lua_State *lua = main.L;
    _lua_stackguard_entry(lua);
    [main pushLuaRef:refTable ref:spaceWindowRef];
    lua_pushinteger(lua, (lua_Integer)windowID);
    lua_pushinteger(lua, (lua_Integer)spaceID);
    lua_pushboolean(lua, added);
    if (ownerPID > 0) lua_pushinteger(lua, (lua_Integer)ownerPID); else lua_pushnil(lua);
    [main protectedCallAndError:@"window_manager windowSpace callback" nargs:4 nresults:0];
    _lua_stackguard_exit(lua);
  });
}

static int watchWindowSpaces(lua_State *state) {
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  [skin checkArgs:LS_TFUNCTION | LS_TNIL, LS_TBREAK];
  clearSpaceWindowWatcher();
  if (lua_isfunction(state, 1)) {
    // 1325/1326 carry Space-membership payloads on macOS 27+.
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27) {
      lua_pushboolean(state, 0);
      lua_pushstring(state, "window Space notifications need macOS 27");
      return 2;
    }
    lua_pushvalue(state, 1);
    spaceWindowRef = [skin luaRef:refTable];
    spaceWindowCanary = [skin createGCCanary];
    hasSpaceWindowCanary = YES;
    if (registerNotify(connection, spaceWindowChanged, spaceWindowAdded, NULL) != kCGErrorSuccess) {
      clearSpaceWindowWatcher();
      lua_pushboolean(state, 0);
      lua_pushstring(state, "could not watch window Spaces");
      return 2;
    }
    spaceWindowAddedRegistered = YES;
    if (registerNotify(connection, spaceWindowChanged, spaceWindowRemoved, NULL) != kCGErrorSuccess) {
      clearSpaceWindowWatcher();
      lua_pushboolean(state, 0);
      lua_pushstring(state, "could not watch window Spaces");
      return 2;
    }
    spaceWindowRemovedRegistered = YES;
  }
  lua_pushboolean(state, 1);
  return 1;
}

static const luaL_Reg functions[] = {
  { "move", move },
  { "focus", focus },
  { "cancelFocus", cancelFocus },
  { "focusedWindow", focusedWindow },
  { "frame", frame },
  { "minimize", minimize },
  { "windows", windows },
  { "spaces", spaces },
  { "displaySpaces", displaySpaces },
  { "watchWindowSpaces", watchWindowSpaces },
  { NULL, NULL },
};

int luaopen_window_manager(lua_State *state) {
  if (!keepImageLoaded()) return luaL_error(state, "could not retain window_manager library");
  static BOOL loaded;
  if (!loaded) {
    void *skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW | RTLD_LOCAL);
    void *services = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW);
    if (!skyLight || !services) return luaL_error(state, "SkyLight unavailable");
    const char *names[] = { "SLSMainConnectionID", "_SLPSSetFrontProcessWithOptions", "SLPSPostEventRecordTo",
      "SLSCopySpacesForWindows", "_AXUIElementCreateWithRemoteToken", "SLSWindowQueryWindows",
      "SLSWindowQueryResultCopyWindows", "SLSWindowIteratorAdvance", "SLSWindowIteratorGetWindowID",
      "SLSWindowIteratorGetParentID", "SLSWindowIteratorGetPID", "SLSWindowIteratorGetLevel",
      "SLSWindowIteratorGetTags", "SLSWindowIteratorGetAttributes",
      "SLSCopyManagedDisplaySpaces", "SLSCopyWindowsWithOptionsAndTags",
      "SLSRegisterConnectionNotifyProc", "SLSRemoveConnectionNotifyProc",
      "SLSGetWindowBounds", "SLSGetWindowLevel", "SLSGetWindowOwner", "SLSConnectionGetPID" };
    void *found[sizeof names / sizeof *names];
    for (size_t index = 0; index < sizeof names / sizeof *names; index++) {
      found[index] = dlsym(index == 4 ? services : skyLight, names[index]);
      if (!found[index]) return luaL_error(state, "%s unavailable", names[index]);
    }
    // Published only once every symbol resolved, so a failed load fails again on reload.
    connection = ((int (*)(void))found[0])();
    setFront = found[1];
    postRecord = found[2];
    copySpaces = found[3];
    remoteElement = found[4];
    queryWindows = found[5];
    copyIterator = found[6];
    advance = found[7];
    windowOf = found[8];
    parentOf = found[9];
    pidOf = found[10];
    levelOf = found[11];
    tagsOf = found[12];
    attributesOf = found[13];
    copyDisplaySpaces = found[14];
    copySpaceWindows = found[15];
    registerNotify = found[16];
    removeNotify = found[17];
    windowBounds = found[18];
    windowLevel = found[19];
    windowOwner = found[20];
    connectionPID = found[21];
    frontQueue = dispatch_queue_create("window_manager.front", dispatch_queue_attr_make_with_qos_class(
      DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    queues = [NSMutableDictionary dictionary];
    focusQueues = [NSMutableDictionary dictionary];
    focusedQueues = [NSMutableDictionary dictionary];
    focusedGenerations = [NSMutableDictionary dictionary];
    elements = [NSMutableDictionary dictionary];
    absent = [NSMutableDictionary dictionary];
    frames = [NSMutableDictionary dictionary];
    scans = [NSMutableDictionary dictionary];
    enhancedStates = [NSMutableDictionary dictionary];
    CFNotificationCenterAddObserver(CFNotificationCenterGetDistributedCenter(), NULL, scrollChanged,
      CFSTR("SwipeScrollDirectionDidChangeNotification"), NULL,
      CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDistributedCenter(), NULL, screenUnlocked,
      CFSTR("com.apple.screenIsUnlocked"), NULL,
      CFNotificationSuspensionBehaviorDeliverImmediately);
    loaded = YES;
  }
  clearSpaceWindowWatcher();
  clearAbsent();
  refreshScroll();
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  refTable = [skin registerLibrary:"window_manager" functions:functions metaFunctions:nil];
  return 1;
}
