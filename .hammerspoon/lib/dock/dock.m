// Loaded into the Dock, whose connection may move any window between Spaces.
#import <Foundation/Foundation.h>
#import <dlfcn.h>

extern int SLSMainConnectionID(void);
extern void SLSMoveWindowsToManagedSpace(int connection, CFArrayRef windows, uint64_t space);
extern CFArrayRef SLSCopySpacesForWindows(int connection, int mask, CFArrayRef windows);

static CFDataRef reply(NSString *message) {
  return CFBridgingRetain([message dataUsingEncoding:NSUTF8StringEncoding]);
}

// "<window> <space>" in; nothing out on success, else the error.
static CFDataRef move(__unused CFMessagePortRef port, __unused SInt32 message, CFDataRef data, __unused void *info) {
  NSString *request = [[NSString alloc] initWithData:(__bridge NSData *)data encoding:NSUTF8StringEncoding];
  unsigned long long window, space;
  if (sscanf(request.UTF8String, "%llu %llu", &window, &space) != 2) {
    return reply([NSString stringWithFormat:@"malformed request %@", request]);
  }
  int connection = SLSMainConnectionID();
  CFArrayRef windows = (__bridge CFArrayRef) @[ @(window) ];
  SLSMoveWindowsToManagedSpace(connection, windows, space);
  NSArray *spaces = CFBridgingRelease(SLSCopySpacesForWindows(connection, 7, windows));
  if (![spaces containsObject:@(space)]) {
    return reply([NSString stringWithFormat:@"window %llu did not move to Space %llu", window, space]);
  }
  return NULL;
}

// The port is named after this file, so each build answers on its own port.
__attribute__((constructor)) static void load(void) {
  Dl_info image;
  dladdr((const void *)load, &image);
  NSString *name = [@"org.hammerspoon." stringByAppendingString:@(image.dli_fname).lastPathComponent];
  dispatch_async(dispatch_get_main_queue(), ^{
    CFMessagePortRef port = CFMessagePortCreateLocal(NULL, (__bridge CFStringRef)name, move, NULL, NULL);
    if (!port) {
      NSLog(@"%@: could not create message port", name);
      return;
    }
    CFRunLoopSourceRef source = CFMessagePortCreateRunLoopSource(NULL, port, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
    CFRelease(source);
  });
}
