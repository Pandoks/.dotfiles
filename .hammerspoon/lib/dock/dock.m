// Loaded into the Dock, whose connection may move windows and switch Spaces directly.
#import <Cocoa/Cocoa.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <malloc/malloc.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <ptrauth.h>

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

static CFDataRef switchSpace(uint64_t space) {
  int connection = SLSMainConnectionID();
  NSString *uuid = displayUUID(connection, space);
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

// "<window> <space>" or "switch <space>" in; nothing out on success, else the error.
static CFDataRef handle(__unused CFMessagePortRef port, __unused SInt32 message, CFDataRef data, __unused void *info) {
  NSString *request = [[NSString alloc] initWithData:(__bridge NSData *)data encoding:NSUTF8StringEncoding];
  unsigned long long window, space;
  if (sscanf(request.UTF8String, "switch %llu", &space) == 1) {
    return switchSpace(space);
  }
  if (sscanf(request.UTF8String, "%llu %llu", &window, &space) == 2) {
    return moveWindow(window, space);
  }
  return reply([NSString stringWithFormat:@"malformed request %@", request]);
}

// The port is named after this file, so each build answers on its own port.
__attribute__((constructor)) static void load(void) {
  weakInit = dlsym(RTLD_DEFAULT, "swift_unknownObjectWeakInit");
  weakAssign = dlsym(RTLD_DEFAULT, "swift_unknownObjectWeakAssign");
  weakLoadStrong = dlsym(RTLD_DEFAULT, "swift_unknownObjectWeakLoadStrong");
  weakDestroy = dlsym(RTLD_DEFAULT, "swift_unknownObjectWeakDestroy");
  Dl_info image;
  dladdr((const void *)load, &image);
  NSString *name = [@"org.hammerspoon." stringByAppendingString:@(image.dli_fname).lastPathComponent];
  dispatch_async(dispatch_get_main_queue(), ^{
    CFMessagePortRef port = CFMessagePortCreateLocal(NULL, (__bridge CFStringRef)name, handle, NULL, NULL);
    if (!port) {
      NSLog(@"%@: could not create message port", name);
      return;
    }
    CFRunLoopSourceRef source = CFMessagePortCreateRunLoopSource(NULL, port, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
    CFRelease(source);
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!loadWeak(&dockSpacesRef)) discover();
    });
  });
}
