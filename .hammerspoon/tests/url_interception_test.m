#import "selectors.h"
#import "status.h"
#import "platform.h"
#include <dlfcn.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

static void require(BOOL condition, NSString *message) {
  if (!condition) { fprintf(stderr, "FAIL %s\n", message.UTF8String); exit(1); }
}

static NSData *publish(NSString *path, NSString *generation, id rules) {
  NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"version": @1, @"generation": generation, @"rules": rules} options:0 error:nil];
  require([data writeToFile:path options:NSDataWritingAtomic error:nil], @"atomic selector publication");
  return data;
}

static NSDictionary *next(dispatch_semaphore_t semaphore, NSMutableArray *events, NSLock *lock) {
  require(dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0,
    @"directory notification or generation acknowledgement timed out");
  [lock lock]; NSDictionary *event = events.firstObject; [events removeObjectAtIndex:0]; [lock unlock];
  return event;
}

static void await(dispatch_semaphore_t semaphore, NSMutableArray *events, NSLock *lock, NSString *key, NSString *value) {
  for (;;) {
    NSDictionary *event = next(semaphore, events, lock);
    if ([event[key] isEqual:value]) return;
  }
}

static void sandbox(void) {
  NSString *profile = [NSString stringWithContentsOfFile:@"/System/Library/Sandbox/Profiles/com.apple.swcd.sb"
    encoding:NSUTF8StringEncoding error:nil];
  int (*initialize)(const char *, uint64_t, const char *const *, char **) = dlsym(RTLD_DEFAULT, "sandbox_init_with_parameters");
  const char *parameters[] = {"_HOME", NSHomeDirectory().fileSystemRepresentation, NULL};
  char *error = NULL;
  require(initialize && initialize(profile.UTF8String, 0, parameters, &error) == 0,
    error ? @(error) : @"actual swcd sandbox initialization");
}

int main(int argc, const char **argv) {
  @autoreleasepool {
    require(argc == 4, @"pass SELECTOR_DIRECTORY STATUS_DIRECTORY MODE");
    NSString *rules = [@(argv[1]) stringByAppendingPathComponent:@"rules.json"];
    NSString *statusPath = [@(argv[2]) stringByAppendingPathComponent:@"status.json"];
    if (!strcmp(argv[3], "snapshot")) {
      __block NSDictionary *result;
      URLSelectorStore *store = [[URLSelectorStore alloc] initWithPath:rules report:^(NSDictionary *event) { result = event; }];
      require(result != nil, @"snapshot reports its initial status synchronously");
      require([store classifyURL:[NSURL URLWithString:@"https://ramp.com/"] snapshot:nil]
        == ([result[@"kind"] isEqual:@"loaded"] ? 1 : -1), @"snapshot result agrees with classifier readiness");
      puts([result[@"stage"] ?: result[@"kind"] UTF8String]);
      [store stop];
      return 0;
    }
    if (!strcmp(argv[3], "status-snapshot")) {
      NSError *error;
      NSData *data = URLRouterReadStatus(statusPath, &error);
      if (data) puts("loaded");
      else printf("error %ld\n", (long)error.code);
      return 0;
    }
    if (!strcmp(argv[3], "sandbox")) {
      sandbox();
      int denied = open("/var/tmp/url-interception-sandbox-denied", O_WRONLY | O_CREAT | O_EXCL, 0600);
      require(denied < 0 && errno == EPERM, @"swcd sandbox rejects ordinary /var/tmp writes");
      NSError *error;
      URLRouterStatus *status = [[URLRouterStatus alloc] initWithPath:statusPath error:&error];
      require(status != nil, error.localizedDescription);
      require([status write:@{@"version": @1, @"kind": @"ready", @"generation": @"sandbox", @"pid": @(getpid())} error:&error],
        error.localizedDescription ?: @"atomic temp status creation/write/rename in real swcd sandbox");
      require(!unlink(statusPath.fileSystemRepresentation)
        && !rmdir(statusPath.stringByDeletingLastPathComponent.fileSystemRepresentation), @"remove status directory");
      require([status write:@{@"version": @1, @"kind": @"ready", @"generation": @"recreated", @"pid": @(getpid())} error:&error],
        error.localizedDescription ?: @"status writer recreates a removed directory");
      dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
      NSLock *lock = [NSLock new]; NSMutableArray *events = [NSMutableArray new];
      URLSelectorStore *store = [[URLSelectorStore alloc] initWithPath:rules report:^(NSDictionary *event) {
        require([event[@"kind"] isEqual:@"loaded"], [event description]);
        require([status write:event error:nil], @"sandbox publishes selector acknowledgement");
        [lock lock]; [events addObject:event]; [lock unlock]; dispatch_semaphore_signal(semaphore);
      }];
      await(semaphore, events, lock, @"generation", @"sandbox");
      require([store classifyURL:[NSURL URLWithString:@"https://ramp.com/allowed"] snapshot:nil] == 1,
        @"sandbox reads selectors outside writable temp tree");
      puts("READY sandbox watcher"); fflush(stdout);
      await(semaphore, events, lock, @"generation", @"sandbox-reload");
      require([store classifyURL:[NSURL URLWithString:@"https://ramp.com/allowed"] snapshot:nil] == 0
        && [store classifyURL:[NSURL URLWithString:@"https://notion.com/allowed"] snapshot:nil] == 1,
        @"sandbox observes external atomic selector replacement");
      [store stop];
      puts("PASS actual swcd sandbox: external selector read/watch/replacement, denied external write, atomic temp status acknowledgement after directory removal");
      return 0;
    }
    NSError *error;
    require(URLRouterCheckABI(&error), error.localizedDescription);
    URLRouterStatus *status = [[URLRouterStatus alloc] initWithPath:statusPath error:&error];
    require(status != nil, error.localizedDescription);
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    NSLock *lock = [NSLock new]; NSMutableArray *events = [NSMutableArray new];
    NSArray *original = @[@{@"host": @"ramp.com"}, @{@"pattern": @"^https?://app%.notion%.com/p/sieve%-data/"},
      @{@"pattern": @"^https?://app%.notion%.com/p/pandoks/"}];
    publish(rules, @"initial", original);
    URLSelectorStore *store = [[URLSelectorStore alloc] initWithPath:rules report:^(NSDictionary *event) {
      require([status write:event error:nil], @"native ACK publication");
      [lock lock]; [events addObject:event]; [lock unlock]; dispatch_semaphore_signal(semaphore);
    }];
    await(semaphore, events, lock, @"generation", @"initial");
    NSArray *cases = @[
      @[@"https://ramp.com/pay", @1], @[@"https://cards.ramp.com/pay", @1], @[@"https://RAMP.COM./pay", @1],
      @[@"https://notramp.com/pay", @0], @[@"https://ramp.com.example/pay", @0],
      @[@"https://app.notion.com/p/sieve-data/page", @2], @[@"http://app.notion.com/p/sieve-data/page", @2],
      @[@"https://app.notion.com/p/pandoks/page", @3], @[@"https://app.notion.com/p/unconfigured/page", @0],
      @[@"https://APP.NOTION.COM/p/pandoks/page", @0], @[@"https://notion.com/p/pandoks/page", @0],
      @[@"https://example.test/?next=https://app.notion.com/p/pandoks/page", @0],
    ];
    for (NSArray *row in cases) require([store classifyURL:[NSURL URLWithString:row[0]] snapshot:nil] == [row[1] intValue], row[0]);
    publish(rules, @"ordered", @[@{@"pattern": @"^https?://ramp%.com/specific"}, @{@"host": @"ramp.com"}]);
    await(semaphore, events, lock, @"generation", @"ordered");
    require([store classifyURL:[NSURL URLWithString:@"https://ramp.com/specific"] snapshot:nil] == 1, @"ordered overlap");
    require([store classifyURL:[NSURL URLWithString:@"https://ramp.com/general"] snapshot:nil] == 2, @"ordered later rule");
    NSData *ack = [NSData dataWithContentsOfFile:statusPath];
    NSDictionary *row = [NSJSONSerialization JSONObjectWithData:ack options:0 error:nil];
    require([row[@"generation"] isEqual:@"ordered"] && [row[@"count"] isEqual:@2], @"published generation ACK identifies active rules");
    puts("PASS native ordered matcher, host boundaries, exact URL patterns, and atomic generation ACK");
    NSArray *first = @[@{@"host": @"alpha.example"}, @{@"host": @"beta.example"}];
    NSArray *second = @[@{@"host": @"beta.example"}, @{@"host": @"alpha.example"}];
    publish(rules, @"before-concurrency", first); await(semaphore, events, lock, @"generation", @"before-concurrency");
    dispatch_group_t group = dispatch_group_create(); __block NSUInteger failures = 0; NSLock *count = [NSLock new];
    for (int worker = 0; worker < 4; worker++) dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      NSUInteger failed = 0;
      for (int index = 0; index < 10000; index++) {
        NSDictionary *snapshot;
        int result = [store classifyURL:[NSURL URLWithString:@"https://alpha.example/value"] snapshot:&snapshot];
        NSString *generation = snapshot[@"generation"];
        int expected = [generation isEqual:@"before-concurrency"] ? 1
          : ([generation substringFromIndex:[@"concurrency-" length]].intValue % 2 ? 1 : 2);
        if (result != expected || ![snapshot[@"count"] isEqual:@2]) failed++;
      }
      [count lock]; failures += failed; [count unlock];
    });
    for (int index = 0; index < 20; index++) {
      NSString *generation = [NSString stringWithFormat:@"concurrency-%d", index];
      publish(rules, generation, index % 2 ? first : second); await(semaphore, events, lock, @"generation", generation);
    }
    require(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0 && failures == 0,
      @"concurrent readers receive the classification and its exact generation together");
    puts("PASS 20 atomic inode replacements and 40000 concurrent classifications with their matching generation");
    publish(rules, @"bad-pattern", @[@{@"pattern": @"%"}]); await(semaphore, events, lock, @"stage", @"snapshot-pattern");
    require([store classifyURL:[NSURL URLWithString:@"https://ramp.com"] snapshot:nil] == -1, @"invalid pattern fails closed");
    publish(rules, @"runtime-pattern", @[@{@"pattern": @"^https://ramp%.com/["}]);
    await(semaphore, events, lock, @"generation", @"runtime-pattern");
    require([store classifyURL:[NSURL URLWithString:@"https://ramp.com/value"] snapshot:nil] == -1, @"unreachable malformed suffix fails closed when reached");
    await(semaphore, events, lock, @"stage", @"classifier");
    require([store classifyURL:[NSURL URLWithString:@"https://unmatched.example/"] snapshot:nil] == -1, @"runtime failure disables previous classifier");
    publish(rules, @"repaired", original); await(semaphore, events, lock, @"generation", @"repaired");
    require([store classifyURL:[NSURL URLWithString:@"https://ramp.com"] snapshot:nil] == 1, @"valid replacement repairs runtime failure");
    publish(rules, @"repaired", @[]); await(semaphore, events, lock, @"stage", @"snapshot-generation");
    require([store classifyURL:[NSURL URLWithString:@"https://ramp.com"] snapshot:nil] == -1, @"generation identity cannot be reused for other bytes");
    require([[@"{" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:rules atomically:YES], @"publish malformed JSON");
    await(semaphore, events, lock, @"stage", @"snapshot-json");
    require([store classifyURL:[NSURL URLWithString:@"https://ramp.com"] snapshot:nil] == -1, @"malformed JSON fails closed");
    require(unlink(rules.fileSystemRepresentation) == 0, @"remove selectors");
    await(semaphore, events, lock, @"stage", @"snapshot-open");
    require(symlink("/etc/passwd", rules.fileSystemRepresentation) == 0, @"symlink replacement fixture");
    await(semaphore, events, lock, @"stage", @"snapshot-open");
    require([store classifyURL:[NSURL URLWithString:@"https://ramp.com"] snapshot:nil] == -1, @"symlink snapshot refused");
    require(unlink(rules.fileSystemRepresentation) == 0, @"remove symlink fixture");
    require(mkfifo(rules.fileSystemRepresentation, 0600) == 0, @"FIFO replacement fixture");
    await(semaphore, events, lock, @"stage", @"snapshot-file");
    require([store classifyURL:[NSURL URLWithString:@"https://ramp.com"] snapshot:nil] == -1, @"FIFO replacement fails closed");
    require(unlink(rules.fileSystemRepresentation) == 0, @"remove FIFO fixture");
    publish(rules, @"empty", @[]); await(semaphore, events, lock, @"generation", @"empty");
    require([store classifyURL:[NSURL URLWithString:@"https://ramp.com"] snapshot:nil] == 0, @"empty active selectors pass through");
    [store stop];
    puts("PASS invalid patterns, runtime failure, generation immutability, malformed JSON, symlink/FIFO rejection, deletion, and recovery");
    return 0;
  }
}
