#import "platform.h"
#import "status.h"
#import <objc/message.h>
#import <objc/runtime.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>

static void print(id document) {
  NSData *data = [NSJSONSerialization dataWithJSONObject:document options:NSJSONWritingSortedKeys error:nil];
  if (data) fwrite(data.bytes, 1, data.length, stdout);
  putchar('\n');
}

static int fail(NSString *message) {
  fprintf(stderr, "%s\n", message.UTF8String);
  return 1;
}

static NSString *health(dispatch_time_t deadline) {
  Class details = NSClassFromString(@"_SWCServiceDetails");
  SEL query = NSSelectorFromString(@"serviceDetailsWithServiceSpecifier:URLComponents:limit:error:");
  Method method = class_getClassMethod(details, query);
  if (!method || strcmp(method_getTypeEncoding(method), "@48@0:8@16@24Q32^@40"))
    return @"Unsupported SWC health-query method";
  dispatch_semaphore_t queried = dispatch_semaphore_create(0);
  __block NSError *error;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    @autoreleasepool {
      (void)((id (*)(id, SEL, id, id, NSUInteger, NSError **))objc_msgSend)(details, query, nil,
        [NSURLComponents componentsWithString:@"https://127.0.0.1/"], 1, &error);
      dispatch_semaphore_signal(queried);
    }
  });
  if (dispatch_semaphore_wait(queried, deadline)) return @"SWC health query timed out";
  return error ? [@"SWC health query failed: " stringByAppendingString:error.localizedDescription] : nil;
}

int main(int argc, const char **argv) {
  @autoreleasepool {
    NSError *error;
    if (!URLRouterCheckABI(&error)) return fail(error.localizedDescription);
    if (argc == 5 && !strcmp(argv[1], "--preflight")) {
      URLRouterTarget *target = [[URLRouterTarget alloc] initWithPath:@(argv[2]) identifier:@(argv[3]) hash:@(argv[4]) error:&error];
      if (!target) return fail(error.localizedDescription);
      print(@{@"version": @1, @"macOSBuild": URLRouterBuild(), @"applicationIdentifier": target.applicationIdentifier, @"privateABI": @"validated"});
      return 0;
    }
    if (argc != 4) return fail(@"usage: probe --preflight APP_PATH APPLICATION_IDENTIFIER CODE_HASH | STATUS_PATH GENERATION SHA256");
    NSString *path = @(argv[1]), *generation = @(argv[2]), *hash = @(argv[3]);
    int directory = open(path.stringByDeletingLastPathComponent.fileSystemRepresentation, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW);
    if (directory < 0) return fail(@"Could not watch the router status directory");
    dispatch_semaphore_t changed = dispatch_semaphore_create(0);
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)directory,
      DISPATCH_VNODE_WRITE | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_REVOKE,
      dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    if (!source) { close(directory); return fail(@"Could not create router status watcher"); }
    dispatch_source_set_event_handler(source, ^{ dispatch_semaphore_signal(changed); });
    dispatch_source_set_cancel_handler(source, ^{ close(directory); });
    dispatch_resume(source);
    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC);
    NSString *message = health(deadline);
    if (message) {
      dispatch_source_cancel(source);
      return fail(message);
    }
    for (;;) {
      NSError *readError;
      NSData *data = URLRouterReadStatus(path, &readError);
      if (!data && readError.code != ENOENT) {
        dispatch_source_cancel(source);
        return fail([@"Could not read router status: " stringByAppendingString:readError.localizedDescription]);
      }
      id row = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
      if ([row isKindOfClass:NSDictionary.class] && [row[@"version"] isEqual:@1]) {
        BOOL current = [row[@"generation"] isEqual:generation] && [row[@"sha256"] isEqual:hash];
        BOOL live = [row[@"pid"] intValue] > 0 && kill([row[@"pid"] intValue], 0) == 0;
        // A running hook that failed setup reports no generation.
        if ([row[@"kind"] isEqual:@"error"] && (current || (live && [row[@"generation"] isEqual:@""]))) {
          dispatch_source_cancel(source);
          return fail(row[@"error"] ?: @"Router daemon reported an error");
        }
        if (current && live && [row[@"kind"] isEqual:@"ready"]) {
          print(row); dispatch_source_cancel(source); return 0;
        }
      }
      if (dispatch_semaphore_wait(changed, deadline)) break;
    }
    dispatch_source_cancel(source);
    return fail(@"Router did not acknowledge the current selector generation within 10 seconds");
  }
}
