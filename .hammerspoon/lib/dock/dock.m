// Loaded into the Dock, whose connection may move windows and switch Spaces directly.
#import <Cocoa/Cocoa.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <malloc/malloc.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <pthread.h>
#import <ptrauth.h>
#import <time.h>

extern int SLSMainConnectionID(void);
extern void SLSMoveWindowsToManagedSpace(int connection, CFArrayRef windows, uint64_t space);
extern CFArrayRef SLSCopySpacesForWindows(int connection, int mask, CFArrayRef windows);
extern CFStringRef SLSCopyManagedDisplayForSpace(int connection, uint64_t space);
extern uint64_t SLSManagedDisplayGetCurrentSpace(int connection, CFStringRef display);
extern CFTypeRef SLSTransactionCreate(int connection);
extern void SLSTransactionWillSwitchSpaces(CFTypeRef transaction, CFArrayRef spaces);
extern void SLSTransactionHideSpace(CFTypeRef transaction, uint64_t space);
extern void SLSTransactionShowSpace(CFTypeRef transaction, uint64_t space);
extern void SLSTransactionSetManagedDisplayCurrentSpace(CFTypeRef transaction, CFStringRef display, uint64_t space);
extern void SLSTransactionCommit(CFTypeRef transaction, int synchronous);

typedef struct {
  void *bits;
} SwiftWeakRef;

static void (*weakInit)(SwiftWeakRef *slot, void *value);
static void (*weakAssign)(void *slot, id value);
static void *(*weakLoadStrong)(SwiftWeakRef *slot);
static void (*weakDestroy)(SwiftWeakRef *slot);
static SwiftWeakRef dockSpacesRef;
static SwiftWeakRef displaySpacesRefs[64];
static size_t displaySpacesCount;
static Ivar displayIvar, currentIvar, lastUserIvar;

static void clearRefs(void) {
  if (weakDestroy) {
    if (dockSpacesRef.bits) {
      weakDestroy(&dockSpacesRef);
      dockSpacesRef.bits = NULL;
    }
    for (size_t index = 0; index < displaySpacesCount; index++) {
      weakDestroy(&displaySpacesRefs[index]);
      displaySpacesRefs[index].bits = NULL;
    }
  }
  displaySpacesCount = 0;
}

static id loadWeak(SwiftWeakRef *slot) {
  if (!weakLoadStrong || !slot->bits) return nil;
  return CFBridgingRelease(weakLoadStrong(slot));
}

typedef struct {
  uintptr_t spacesClass;
  uintptr_t displayClass;
  uintptr_t mask;
  size_t spacesSize;
  size_t displaySize;
  void *spacesHits[64];
  size_t spacesCount;
  void *displayHits[64];
  size_t displayCount;
} Scan;

static CFDataRef reply(NSString *message) {
  return CFBridgingRetain([message dataUsingEncoding:NSUTF8StringEncoding]);
}

static kern_return_t readLocal(task_t __unused task, vm_address_t address, vm_size_t __unused size, void **memory) {
  *memory = (void *)address;
  return KERN_SUCCESS;
}

static void recordRange(task_t __unused task, void *context, unsigned __unused type, vm_range_t *ranges,
                        unsigned count) {
  Scan *scan = (Scan *)context;
  for (unsigned index = 0; index < count; index++) {
    vm_range_t range = ranges[index];
    if ((range.address & 7) != 0 || range.size < sizeof(uintptr_t)) continue;
    uintptr_t word = *(uintptr_t *)range.address;
    uintptr_t masked = word & scan->mask;
    uintptr_t stripped = (uintptr_t)ptrauth_strip((void *)word, ptrauth_key_asda);
    if (range.size >= scan->spacesSize && (masked == scan->spacesClass || stripped == scan->spacesClass)) {
      if (scan->spacesCount < 64) scan->spacesHits[scan->spacesCount++] = (void *)range.address;
    } else if (range.size >= scan->displaySize && (masked == scan->displayClass || stripped == scan->displayClass)) {
      if (scan->displayCount < 64) scan->displayHits[scan->displayCount++] = (void *)range.address;
    }
  }
}

static NSString *discover(void) {
  if (!weakInit || !weakLoadStrong || !weakDestroy) return @"Swift weak runtime unavailable";
  clearRefs();
  Class spacesClass = NSClassFromString(@"Spaces");
  Class displayClass = NSClassFromString(@"_TtC8DockCore13DisplaySpaces");
  if (!spacesClass || !displayClass) return @"Dock Spaces classes unavailable";
  displayIvar = class_getInstanceVariable(displayClass, "display");
  currentIvar = class_getInstanceVariable(displayClass, "_currentSpace");
  lastUserIvar = class_getInstanceVariable(displayClass, "lastUserSpace");
  if (!displayIvar || !currentIvar || !lastUserIvar) return @"Dock DisplaySpaces ivars unavailable";

  uintptr_t *mask = dlsym(RTLD_DEFAULT, "objc_debug_isa_class_mask");
  Scan scan = {
    .spacesClass = (uintptr_t)ptrauth_strip((__bridge void *)spacesClass, ptrauth_key_asda),
    .displayClass = (uintptr_t)ptrauth_strip((__bridge void *)displayClass, ptrauth_key_asda),
    .mask = mask ? *mask : ~(uintptr_t)0x7,
    .spacesSize = class_getInstanceSize(spacesClass),
    .displaySize = class_getInstanceSize(displayClass),
  };

  vm_address_t *zones = NULL;
  unsigned zoneCount = 0;
  if (malloc_get_all_zones(mach_task_self(), readLocal, &zones, &zoneCount) != KERN_SUCCESS) {
    return @"could not inspect Dock heap";
  }
  for (unsigned index = 0; index < zoneCount; index++) {
    malloc_zone_t *zone = (malloc_zone_t *)zones[index];
    if (zone && zone->introspect && zone->introspect->enumerator) {
      zone->introspect->enumerator(mach_task_self(), &scan, MALLOC_PTR_IN_USE_RANGE_TYPE,
                                   (vm_address_t)zone, readLocal, recordRange);
    }
  }

  for (size_t index = 0; index < scan.spacesCount; index++) {
    id candidate = (__bridge id)scan.spacesHits[index];
    if (object_getClass(candidate) == spacesClass) {
      weakInit(&dockSpacesRef, (__bridge void *)candidate);
      break;
    }
  }
  for (size_t index = 0; index < scan.displayCount && displaySpacesCount < 64; index++) {
    id candidate = (__bridge id)scan.displayHits[index];
    if (object_getClass(candidate) == displayClass) {
      weakInit(&displaySpacesRefs[displaySpacesCount++], (__bridge void *)candidate);
    }
  }
  return (loadWeak(&dockSpacesRef) && displaySpacesCount) ? nil : @"Dock Spaces state not found";
}

static NSString *displayUUID(int connection, uint64_t space) {
  NSString *uuid = CFBridgingRelease(SLSCopyManagedDisplayForSpace(connection, space));
  if (![uuid isEqualToString:@"Main"]) return uuid;
  CFUUIDRef raw = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID());
  if (!raw) return nil;
  NSString *resolved = CFBridgingRelease(CFUUIDCreateString(NULL, raw));
  CFRelease(raw);
  return resolved;
}

static void replaceStrong(id object, Ivar ivar, id value) {
  void **slot = (void **)(void *)((char *)(__bridge void *)object + ivar_getOffset(ivar));
  void *retained = (void *)CFBridgingRetain(value);
  id previous = (__bridge_transfer id)(*slot);
  *slot = retained;
  (void)previous;
}

static id findDisplaySpaces(uint32_t displayID, uint64_t currentSpace) {
  id fallback = nil;
  for (size_t index = 0; index < displaySpacesCount; index++) {
    id entry = loadWeak(&displaySpacesRefs[index]);
    if (!entry) continue;
    uint32_t current = *(uint32_t *)(void *)((char *)(__bridge void *)entry + ivar_getOffset(displayIvar));
    if (current != displayID) continue;
    void **slot = (void **)(void *)((char *)(__bridge void *)entry + ivar_getOffset(currentIvar));
    id active = (__bridge id)(*slot);
    if (active && ((uint64_t (*)(id, SEL))objc_msgSend)(active, sel_registerName("spid")) == currentSpace) {
      return entry;
    }
    if (!fallback) fallback = entry;
  }
  return fallback;
}

static CFDataRef switchSpace(uint64_t space, NSString *uuid, BOOL *changed) {
  int connection = SLSMainConnectionID();
  if (!uuid) return reply([NSString stringWithFormat:@"Space %llu has no display", space]);
  uint64_t current = SLSManagedDisplayGetCurrentSpace(connection, (__bridge CFStringRef)uuid);
  if (current == space) return NULL;

  if (!weakAssign) return reply(@"swift_unknownObjectWeakAssign unavailable");
  id dockSpaces = loadWeak(&dockSpacesRef);
  if (!dockSpaces) {
    NSString *error = discover();
    if (error) return reply(error);
    dockSpaces = loadWeak(&dockSpacesRef);
    if (!dockSpaces) return reply(@"Dock Spaces state not found");
  }
  if (((BOOL (*)(id, SEL))objc_msgSend)(dockSpaces, sel_registerName("anySwitchingOccurring"))) {
    return reply(@"Space switch already in progress");
  }

  NSArray *list = ((NSArray *(*)(id, SEL, id))objc_msgSend)(dockSpaces, sel_registerName("spacesForDisplay:"), uuid);
  if (!list.count) {
    list = ((NSArray *(*)(id, SEL, id))objc_msgSend)(dockSpaces, sel_registerName("spacesForDisplay:"), @"Main");
  }
  id target = nil;
  for (id item in list) {
    if (((uint64_t (*)(id, SEL))objc_msgSend)(item, sel_registerName("spid")) == space) {
      target = item;
      break;
    }
  }
  if (!target) return reply([NSString stringWithFormat:@"Space %llu not found in Dock", space]);

  uint32_t displayID = ((uint32_t (*)(id, SEL, uint64_t))objc_msgSend)(
    dockSpaces, sel_registerName("displayForSPID:"), space);
  id entry = findDisplaySpaces(displayID, current);
  if (!entry) {
    NSString *error = discover();
    if (error) return reply(error);
    entry = findDisplaySpaces(displayID, current);
    if (!entry) return reply([NSString stringWithFormat:@"display %u not found in Dock", displayID]);
  }

  CFTypeRef transaction = SLSTransactionCreate(connection);
  if (!transaction) return reply(@"could not create SkyLight transaction");
  SLSTransactionWillSwitchSpaces(transaction, (__bridge CFArrayRef) @[ @(space) ]);
  SLSTransactionHideSpace(transaction, current);
  SLSTransactionShowSpace(transaction, space);
  SLSTransactionSetManagedDisplayCurrentSpace(transaction, (__bridge CFStringRef)uuid, space);
  SLSTransactionCommit(transaction, 1);
  CFRelease(transaction);

  if (SLSManagedDisplayGetCurrentSpace(connection, (__bridge CFStringRef)uuid) != space) {
    return reply([NSString stringWithFormat:@"did not switch to Space %llu", space]);
  }

  replaceStrong(entry, currentIvar, target);
  if (((BOOL (*)(id, SEL))objc_msgSend)(target, sel_registerName("userSpace"))) {
    weakAssign((void *)((char *)(__bridge void *)entry + ivar_getOffset(lastUserIvar)), target);
  }
  if (changed) *changed = YES;
  return NULL;
}

static CFDataRef moveWindow(unsigned long long window, unsigned long long space) {
  int connection = SLSMainConnectionID();
  CFArrayRef windows = (__bridge CFArrayRef) @[ @(window) ];
  SLSMoveWindowsToManagedSpace(connection, windows, space);
  NSArray *spaces = CFBridgingRelease(SLSCopySpacesForWindows(connection, 7, windows));
  if (![spaces containsObject:@(space)]) {
    return reply([NSString stringWithFormat:@"window %llu did not move to Space %llu", window, space]);
  }
  return NULL;
}

typedef void (*FollowSetter)(void (^block)(CFDictionaryRef info));

typedef struct {
  uint32_t window;
  uint64_t time;
} Leaving;

// Stale follows were observed 25-280 ms after our switch; WindowServer waits 100 ms before asking Dock.
static const uint64_t leavingDuration = 1ULL * NSEC_PER_SEC;
static const uint64_t switchDuration = 300ULL * NSEC_PER_MSEC;
static NSString *const followStateKey = @"org.hammerspoon.dock.follow";

static NSString *portName;
static NSString *followError;
static uint64_t switchedSpace;
static NSString *switchedDisplay;
static uint64_t switchedTime;
static Leaving recentLeaving[8];

// "<window> <space>", "switch <space> [<leaving>]", or "follow" in; nothing out on success, else the error.
static CFDataRef handle(__unused CFMessagePortRef port, __unused SInt32 message, CFDataRef data, __unused void *info) {
  @autoreleasepool {
    @try {
      if (!data) return reply(@"malformed request");
      NSString *request = [[NSString alloc] initWithData:(__bridge NSData *)data encoding:NSUTF8StringEncoding];
      if (!request) return reply(@"malformed request");
      if ([request isEqualToString:@"follow"]) {
        return followError ? reply(followError) : NULL;
      }
      const char *text = request.UTF8String;
      unsigned long long window, space, leaving = 0;
      int consumed = 0;
      BOOL isSwitch = NO;
      if (sscanf(text, "switch %llu %llu%n", &space, &leaving, &consumed) == 2 && !text[consumed] &&
          leaving <= UINT32_MAX) {
        isSwitch = YES;
      } else if (sscanf(text, "switch %llu%n", &space, &consumed) == 1 && !text[consumed]) {
        leaving = 0;
        isSwitch = YES;
      }
      if (isSwitch) {
        NSString *uuid = displayUUID(SLSMainConnectionID(), space);
        CFDataRef error = switchSpace(space, uuid, NULL);
        if (!error) {
          uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
          switchedSpace = space;
          switchedDisplay = uuid;
          switchedTime = now;
          if (leaving != 0) {
            uint32_t leavingWindow = (uint32_t)leaving;
            size_t slot = 0;
            for (size_t index = 0; index < sizeof(recentLeaving) / sizeof(recentLeaving[0]); index++) {
              if (recentLeaving[index].window == leavingWindow) {
                slot = index;
                break;
              }
              if (recentLeaving[index].time < recentLeaving[slot].time) slot = index;
            }
            recentLeaving[slot] = (Leaving){ .window = leavingWindow, .time = now };
          }
        }
        return error;
      }
      if (sscanf(text, "%llu %llu%n", &window, &space, &consumed) == 2 && !text[consumed]) {
        return moveWindow(window, space);
      }
      return reply([NSString stringWithFormat:@"malformed request %@", request]);
    } @catch (NSException *exception) {
      return reply(exception.reason ?: @"exception");
    }
  }
}

static void followSpace(uint64_t space, uint32_t window, uint64_t generation) {
  @autoreleasepool {
    @try {
      id state = NSThread.mainThread.threadDictionary[followStateKey];
      NSMutableDictionary *shared = [state isKindOfClass:[NSMutableDictionary class]] ? state : nil;
      id current = shared[@"generation"];
      if (![current isKindOfClass:[NSNumber class]] ||
          [(NSNumber *)current unsignedLongLongValue] != generation) {
        return;
      }

      uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
      if (window != 0) {
        for (size_t index = 0; index < sizeof(recentLeaving) / sizeof(recentLeaving[0]); index++) {
          Leaving entry = recentLeaving[index];
          if (entry.window == window && entry.time != 0 &&
              now >= entry.time && (now - entry.time) <= leavingDuration) {
            NSLog(@"%@: ignored follow space=%llu window=%u reason=leaving",
                  portName, space, window);
            return;
          }
        }
      }

      NSString *uuid = displayUUID(SLSMainConnectionID(), space);
      if (switchedTime != 0 && now >= switchedTime &&
          (now - switchedTime) <= switchDuration && space != switchedSpace &&
          uuid && switchedDisplay && [uuid isEqualToString:switchedDisplay]) {
        NSLog(@"%@: ignored follow space=%llu window=%u reason=recent-switch target=%llu",
              portName, space, window, switchedSpace);
        return;
      }

      // Relies on switchSpace's checks; Dock's Mission Control, gesture, and kiosk guards are not mirrored.
      BOOL changed = NO;
      CFDataRef failure = switchSpace(space, uuid, &changed);
      if (failure) {
        NSString *message = [[NSString alloc] initWithData:(__bridge_transfer NSData *)failure
                                                  encoding:NSUTF8StringEncoding];
        NSLog(@"%@: ignored follow space=%llu window=%u reason=%@",
              portName, space, window, message);
        return;
      }
      if (!changed) {
        NSLog(@"%@: ignored follow space=%llu window=%u reason=already-current",
              portName, space, window);
        return;
      }
      NSLog(@"%@: performed follow space=%llu window=%u", portName, space, window);
    } @catch (NSException *exception) {
      NSLog(@"%@: follow handler exception: %@", portName, exception);
    }
  }
}

static void failFollow(NSString *reason) {
  followError = reason;
  NSLog(@"%@: follow handler not installed: %@", portName, reason);
}

static void installFollow(void) {
  @try {
    if (!pthread_main_np()) {
      failFollow(@"follow handler must register on main thread");
      return;
    }

    Boolean exists = false;
    Boolean swoosh = CFPreferencesGetAppBooleanValue(
      CFSTR("workspaces-auto-swoosh"), CFSTR("com.apple.dock"), &exists);
    if (exists && !swoosh) {
      failFollow(@"workspaces-auto-swoosh is disabled");
      return;
    }

    void *setter = dlsym(
      RTLD_DEFAULT, "SLSSetWindowDidOrderInOnNonCurrentManagedSpacesOnlyNotificationBlock");
    void *alias = dlsym(
      RTLD_DEFAULT, "CGSSetWindowDidOrderInOnNonCurrentManagedSpacesOnlyNotificationBlock");
    if (!setter || !alias || setter != alias) {
      failFollow(@"SkyLight follow notification symbol unavailable");
      return;
    }
    Dl_info symbol = { 0 };
    if (!dladdr(setter, &symbol) || !symbol.dli_fname ||
        !strstr(symbol.dli_fname, "SkyLight.framework")) {
      failFollow(@"SkyLight follow notification symbol outside SkyLight");
      return;
    }

    if (SLSMainConnectionID() == 0) {
      failFollow(@"SLSMainConnectionID unavailable");
      return;
    }
    if (!weakAssign) {
      failFollow(@"swift_unknownObjectWeakAssign unavailable");
      return;
    }

    if (!loadWeak(&dockSpacesRef) || !displaySpacesCount) {
      NSString *error = discover();
      if (error) {
        failFollow(error);
        return;
      }
    }
    id spaces = loadWeak(&dockSpacesRef);
    if (!spaces || !displaySpacesCount) {
      failFollow(@"Dock Spaces state not found");
      return;
    }
    if (![spaces respondsToSelector:sel_registerName("anySwitchingOccurring")] ||
        ![spaces respondsToSelector:sel_registerName("spacesForDisplay:")] ||
        ![spaces respondsToSelector:sel_registerName("displayForSPID:")]) {
      failFollow(@"Dock Spaces selectors unavailable");
      return;
    }
    Class spaceClass = NSClassFromString(@"ManagedSpace");
    if (!spaceClass ||
        ![spaceClass instancesRespondToSelector:sel_registerName("spid")] ||
        ![spaceClass instancesRespondToSelector:sel_registerName("userSpace")]) {
      failFollow(@"Dock ManagedSpace selectors unavailable");
      return;
    }

    id state = NSThread.mainThread.threadDictionary[followStateKey];
    NSMutableDictionary *shared = [state isKindOfClass:[NSMutableDictionary class]] ? state : nil;
    if (!shared) {
      shared = [NSMutableDictionary dictionary];
      NSThread.mainThread.threadDictionary[followStateKey] = shared;
    }
    id previous = shared[@"generation"];
    uint64_t generation =
      ([previous isKindOfClass:[NSNumber class]] ? [(NSNumber *)previous unsignedLongLongValue] : 0) + 1;
    shared[@"generation"] = @(generation);

    ((FollowSetter)setter)(^(CFDictionaryRef info) {
      @autoreleasepool {
        @try {
          if (!info || CFGetTypeID(info) != CFDictionaryGetTypeID()) return;
          NSDictionary *dictionary = (__bridge NSDictionary *)info;
          id list = dictionary[@"Spaces Info"];
          if (![list isKindOfClass:[NSArray class]] || [(NSArray *)list count] == 0) return;
          id first = ((NSArray *)list)[0];
          if (![first isKindOfClass:[NSDictionary class]]) return;
          id managed = ((NSDictionary *)first)[@"ManagedSpaceID"];
          if (!managed || CFGetTypeID((__bridge CFTypeRef)managed) != CFNumberGetTypeID()) return;
          uint64_t space = [(NSNumber *)managed unsignedLongLongValue];
          if (space == 0) return;
          uint32_t window = 0;
          id windowValue = dictionary[@"WindowID"];
          if (windowValue) {
            if (CFGetTypeID((__bridge CFTypeRef)windowValue) != CFNumberGetTypeID()) return;
            window = [(NSNumber *)windowValue unsignedIntValue];
          }

          if (pthread_main_np()) {
            followSpace(space, window, generation);
          } else {
            dispatch_async(dispatch_get_main_queue(), ^{
              followSpace(space, window, generation);
            });
          }
        } @catch (NSException *exception) {
          NSLog(@"%@: follow handler exception: %@", portName, exception);
        }
      }
    });
    followError = nil;
  } @catch (NSException *exception) {
    failFollow(exception.reason ?: @"exception");
  }
}

// The port is named after this file, so each build answers on its own port.
__attribute__((constructor)) static void load(void) {
  @autoreleasepool {
    weakInit = dlsym(RTLD_DEFAULT, "swift_unknownObjectWeakInit");
    weakAssign = dlsym(RTLD_DEFAULT, "swift_unknownObjectWeakAssign");
    weakLoadStrong = dlsym(RTLD_DEFAULT, "swift_unknownObjectWeakLoadStrong");
    weakDestroy = dlsym(RTLD_DEFAULT, "swift_unknownObjectWeakDestroy");
    Dl_info image = { 0 };
    dladdr((const void *)load, &image);
    NSString *base = image.dli_fname ? @(image.dli_fname).lastPathComponent : @"dock";
    portName = [@"org.hammerspoon." stringByAppendingString:base];
    dispatch_async(dispatch_get_main_queue(), ^{
      @autoreleasepool {
        CFMessagePortRef port =
          CFMessagePortCreateLocal(NULL, (__bridge CFStringRef)portName, handle, NULL, NULL);
        if (!port) {
          NSLog(@"%@: could not create message port", portName);
          return;
        }
        CFRunLoopSourceRef source = CFMessagePortCreateRunLoopSource(NULL, port, 0);
        if (!source) {
          CFRelease(port);
          NSLog(@"%@: could not create run loop source", portName);
          return;
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
        CFRelease(source);
        installFollow();
      }
    });
  }
}
