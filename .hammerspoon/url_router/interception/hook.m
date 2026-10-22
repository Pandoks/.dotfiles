#import "selectors.h"
#import "platform.h"
#import "status.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/lock.h>
#include <stdatomic.h>
#include <unistd.h>

static URLSelectorStore *store;
static URLRouterTarget *target;
static URLRouterStatus *status;
static os_unfair_lock publication = OS_UNFAIR_LOCK_INIT;
static atomic_bool installed;
static NSDictionary *acknowledgement;

static NSString *environment(const char *name) {
  const char *value = getenv(name);
  return value ? [NSString stringWithUTF8String:value] : nil;
}

// A nil event publishes the current snapshot, read under the lock so an older one can't win.
static void publish(NSDictionary *event) {
  os_unfair_lock_lock(&publication);
  event = event ?: store.snapshot;
  NSMutableDictionary *row = [event mutableCopy];
  BOOL ready = atomic_load(&installed) && [event[@"kind"] isEqual:@"loaded"] && !event[@"error"] && [target unchanged];
  row[@"kind"] = ready ? @"ready" : @"error";
  if (!ready && [event[@"kind"] isEqual:@"loaded"] && !event[@"error"]) {
    row[@"stage"] = @"target-changed";
    row[@"error"] = @"Router executable changed; reinstall interception";
  }
  row[@"version"] = @1;
  row[@"pid"] = @(getpid());
  row[@"macOSBuild"] = URLRouterBuild();
  row[@"generation"] = row[@"generation"] ?: @"";
  row[@"sha256"] = row[@"sha256"] ?: @"";
  row[@"count"] = row[@"count"] ?: @0;
  NSError *error;
  BOOL written = status && [status write:row error:&error];
  acknowledgement = ready && written ? [row copy] : nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:row options:NSJSONWritingSortedKeys error:nil];
  NSMutableData *line = [data mutableCopy];
  [line appendBytes:"\n" length:1];
  if (line) (void)write(STDOUT_FILENO, line.bytes, line.length);
  if (!written) NSLog(@"Hammerspoon URL Router: status publication failed: %@", error.localizedDescription ?: @"status path is unavailable");
  os_unfair_lock_unlock(&publication);
}

static NSError *failure(NSString *message) {
  return [NSError errorWithDomain:@"HammerspoonURLRouter" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

// Failures leave swcd running unhooked; exiting would stall every link lookup.
__attribute__((constructor)) static void install(void) {
  @autoreleasepool {
    NSError *error;
    NSString *statusPath = environment("URL_ROUTER_STATUS_PATH");
    if (statusPath) status = [[URLRouterStatus alloc] initWithPath:statusPath error:&error];
    if (!status) {
      NSLog(@"Hammerspoon URL Router: %@", error.localizedDescription ?: @"URL_ROUTER_STATUS_PATH is missing");
      return;
    }
    if (!URLRouterCheckABI(&error)) {
      publish(@{@"stage": @"runtime", @"error": error.localizedDescription});
      return;
    }
    NSString *app = environment("URL_ROUTER_APP_PATH");
    NSString *identifier = environment("URL_ROUTER_APPLICATION_IDENTIFIER");
    NSString *hash = environment("URL_ROUTER_CODE_HASH");
    NSString *selectors = environment("URL_ROUTER_SELECTORS_PATH");
    if (!app || !identifier || !hash || !selectors) {
      publish(@{@"stage": @"environment", @"error": @"Router app, application identifier, code hash and selector path are required"});
      return;
    }
    target = [[URLRouterTarget alloc] initWithPath:app identifier:identifier hash:hash error:&error];
    if (!target) {
      publish(@{@"stage": @"target", @"error": error.localizedDescription});
      return;
    }
    Class manager = NSClassFromString(@"SWCManager");
    SEL selector = NSSelectorFromString(@"getDetailsWithServiceSpecifier:URL:limit:callerAuditToken:completionHandler:");
    Method method = class_getInstanceMethod(manager, selector);
    if (!method || strcmp(method_getTypeEncoding(method), "v56@0:8@16@24Q32@40@?48")) {
      publish(@{@"stage": @"manager", @"error": @"SWCManager method or encoding does not match the validated runtime"});
      return;
    }
    IMP original = method_getImplementation(method);
    IMP replacement = imp_implementationWithBlock(^(id receiver, id specifier, NSURL *url, NSUInteger limit,
        id token, void (^completion)(id, id)) {
      @autoreleasepool {
        id service = [specifier respondsToSelector:NSSelectorFromString(@"serviceType")]
          ? ((id (*)(id, SEL))objc_msgSend)(specifier, NSSelectorFromString(@"serviceType")) : nil;
        if (![service isEqual:@"applinks"] || !url || ![@[@"http", @"https"] containsObject:url.scheme.lowercaseString]
            || [target isCaller:token connection:NSXPCConnection.currentConnection]) {
          ((void (*)(id, SEL, id, id, NSUInteger, id, id))original)(receiver, selector, specifier, url, limit, token, completion);
          return;
        }
        NSDictionary *snapshot;
        int rule = [store classifyURL:url snapshot:&snapshot];
        if (rule == 0) {
          ((void (*)(id, SEL, id, id, NSUInteger, id, id))original)(receiver, selector, specifier, url, limit, token, completion);
          return;
        }
        if (!completion) return;
        os_unfair_lock_lock(&publication);
        BOOL acknowledged = [snapshot[@"generation"] isEqual:acknowledgement[@"generation"]]
          && [snapshot[@"sha256"] isEqual:acknowledgement[@"sha256"]]
          && [snapshot[@"count"] isEqual:acknowledgement[@"count"]];
        os_unfair_lock_unlock(&publication);
        if (rule < 0 || !acknowledged) {
          completion(nil, failure(@"URL selectors are unavailable or have not been acknowledged"));
          return;
        }
        if (![target unchanged]) {
          NSMutableDictionary *event = [store.snapshot mutableCopy];
          event[@"stage"] = @"target-changed"; event[@"error"] = @"Router executable changed; reinstall interception";
          publish(event);
          completion(nil, failure(event[@"error"]));
          return;
        }
        NSError *error;
        id detail = [target detailForURL:url error:&error];
        if (!detail) {
          NSMutableDictionary *event = [store.snapshot mutableCopy];
          event[@"stage"] = @"app-link"; event[@"error"] = error.localizedDescription;
          publish(event);
          completion(nil, error);
          return;
        }
        completion(@[detail], nil);
      }
    });
    if (!replacement) {
      publish(@{@"stage": @"hook", @"error": @"Could not create selective interception"});
      return;
    }
    store = [[URLSelectorStore alloc] initWithPath:selectors report:^(NSDictionary *event) {
      if (atomic_load(&installed) || [event[@"kind"] isEqual:@"error"]) publish(event);
    }];
    method_setImplementation(method, replacement);
    atomic_store(&installed, YES);
    publish(nil);
  }
}
