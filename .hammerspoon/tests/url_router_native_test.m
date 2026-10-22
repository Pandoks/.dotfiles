#import <Cocoa/Cocoa.h>
#import <LuaSkin/LuaSkin.h>
#import <CommonCrypto/CommonDigest.h>
#include <assert.h>
#include <stdatomic.h>
#include <sys/stat.h>

@interface RouterTestLog : NSObject <LuaSkinDelegate>
@end
@implementation RouterTestLog
- (void)handleCatastrophe:(NSString *)message { fprintf(stderr, "%s\n", message.UTF8String); abort(); }
- (void)logForLuaSkinAtLevel:(int)level withMessage:(NSString *)message {
  fprintf(stderr, "%s\n", message.UTF8String);
  if (level == LS_LOG_ERROR) abort();
}
@end

static void execute(lua_State *state, const char *code) {
  if (luaL_dostring(state, code)) { fprintf(stderr, "%s\n", lua_tostring(state, -1)); abort(); }
}

static int encode(lua_State *state) {
  NSError *error;
  NSData *data = [NSJSONSerialization dataWithJSONObject:[[LuaSkin sharedWithState:state] toNSObjectAtIndex:1] options:0 error:&error];
  if (!data) return luaL_error(state, "%s", error.localizedDescription.UTF8String);
  lua_pushlstring(state, data.bytes, data.length); return 1;
}
static int decode(lua_State *state) {
  size_t size; const char *bytes = luaL_checklstring(state, 1, &size);
  NSError *error;
  id value = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes length:size] options:0 error:&error];
  if (!value) return luaL_error(state, "%s", error.localizedDescription.UTF8String);
  [[LuaSkin sharedWithState:state] pushNSObject:value]; return 1;
}
static int hash(lua_State *state) {
  size_t size; const char *bytes = luaL_checklstring(state, 1, &size);
  unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(bytes, (CC_LONG)size, digest);
  NSMutableString *value = [NSMutableString new];
  for (NSUInteger index = 0; index < sizeof(digest); index++) [value appendFormat:@"%02x", digest[index]];
  lua_pushstring(state, value.UTF8String); return 1;
}
static int permissions(lua_State *state) {
  const char *path = luaL_checkstring(state, 1); mode_t mode = (mode_t)luaL_checkinteger(state, 2);
  if (chmod(path, mode) && errno != ENOENT) return luaL_error(state, "chmod: %s", strerror(errno));
  return 0;
}

static int finish(lua_State *state) { (void)state; CFRunLoopStop(CFRunLoopGetMain()); return 0; }
static void awaitEvents(void) {
  __block BOOL completed = NO;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    if (!completed) { fprintf(stderr, "native URL router test timed out\n"); abort(); }
  });
  CFRunLoopRun();
  completed = YES;
}
static lua_Integer number(lua_State *state, const char *name) {
  lua_getglobal(state, name); lua_Integer result = lua_tointeger(state, -1); lua_pop(state, 1); return result;
}

int main(int argc, char **argv) {
  @autoreleasepool {
    assert(argc == 5);
    RouterTestLog *logger = [RouterTestLog new];
    LuaSkin *skin = [LuaSkin sharedWithDelegate:logger];
    lua_State *state = skin.L;
    luaL_openlibs(state);
    lua_pushstring(state, argv[1]); lua_setglobal(state, "binary");
    NSString *directory = @(argv[2]), *path = [directory stringByAppendingPathComponent:@"rules.json"];
    lua_pushstring(state, path.fileSystemRepresentation); lua_setglobal(state, "path");
    lua_pushcfunction(state, finish); lua_setglobal(state, "finish");
    execute(state, "native=assert(package.loadlib(binary,'luaopen_url_router'))(); assert(native.publish(path,'old')); events=0; cancel=assert(native.watch(path,function(error) assert(error==nil); events=events+1; finish() end))");
    struct stat info;
    assert(stat(path.fileSystemRepresentation, &info) == 0 && (info.st_mode & 0777) == 0600);
    NSString *first = [@"A" stringByPaddingToLength:32768 withString:@"A" startingAtIndex:0];
    NSString *second = [@"B" stringByPaddingToLength:32768 withString:@"B" startingAtIndex:0];
    NSData *one = [first dataUsingEncoding:NSUTF8StringEncoding], *two = [second dataUsingEncoding:NSUTF8StringEncoding];
    lua_pushlstring(state, one.bytes, one.length); lua_setglobal(state, "one");
    lua_pushlstring(state, two.bytes, two.length); lua_setglobal(state, "two");
    __block atomic_bool running = true;
    __block atomic_int reads = 0;
    dispatch_group_t reader = dispatch_group_create();
    dispatch_group_async(reader, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      while (atomic_load(&running)) {
        @autoreleasepool {
          NSData *data = [NSData dataWithContentsOfFile:path];
          assert([data isEqualToData:one] || [data isEqualToData:two] || [data isEqualToData:[@"old" dataUsingEncoding:NSUTF8StringEncoding]]);
          atomic_fetch_add(&reads, 1);
        }
      }
    });
    execute(state, "for index=1,128 do assert(native.publish(path,index%2==0 and one or two)) end");
    atomic_store(&running, false);
    assert(dispatch_group_wait(reader, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);
    assert(atomic_load(&reads) > 0);
    assert([[NSData dataWithContentsOfFile:path] isEqualToData:one]);
    awaitEvents();
    assert(number(state, "events") > 0);
    puts("PASS atomic replacement never exposes partial selectors and delivers vnode events");

    execute(state, "local ok,error=native.publish(path,string.rep('X',1024*1024+1)); assert(not ok and type(error)=='string'); ok,error=native.publish(path..'/missing','bad'); assert(not ok and type(error)=='string'); cancel(); cancel()");
    assert([[NSData dataWithContentsOfFile:path] isEqualToData:one]);
    NSArray<NSString *> *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:nil];
    assert([entries isEqualToArray:@[@"rules.json"]]);
    lua_Integer previous = number(state, "events");
    execute(state, "assert(native.publish(path,'after cancellation'))");
    dispatch_async(dispatch_get_main_queue(), ^{ CFRunLoopStop(CFRunLoopGetMain()); });
    awaitEvents();
    assert(number(state, "events") == previous);
    puts("PASS publication failures preserve prior contents and cancellation stops callbacks");

    execute(state, "assert(native.read(path)=='after cancellation'); local contents,error,code=native.read(path..'.missing'); assert(contents==nil and type(error)=='string' and code==2)");
    NSString *fifo = [directory stringByAppendingPathComponent:@"fifo.json"];
    assert(mkfifo(fifo.fileSystemRepresentation, 0600) == 0);
    lua_pushstring(state, fifo.fileSystemRepresentation); lua_setglobal(state, "fifo");
    alarm(3);
    execute(state, "local contents,error,code=native.read(fifo); assert(contents==nil and error:find('regular',1,true) and code==22)");
    alarm(0);
    assert(unlink(fifo.fileSystemRepresentation) == 0);
    assert(symlink(path.fileSystemRepresentation, fifo.fileSystemRepresentation) == 0);
    execute(state, "local contents,error,code=native.read(fifo); assert(contents==nil and type(error)=='string' and code~=2); assert(native.read(path)=='after cancellation')");
    assert(unlink(fifo.fileSystemRepresentation) == 0);
    puts("PASS metadata reads reject FIFOs and symlinks promptly while preserving ENOENT and regular contents");

    execute(state, "invalidated=false; cancel=assert(native.watch(path,function(error) assert(type(error)=='string'); invalidated=true; finish() end))");
    NSString *moved = [directory stringByAppendingString:@".moved"];
    assert([[NSFileManager defaultManager] moveItemAtPath:directory toPath:moved error:nil]);
    awaitEvents();
    lua_getglobal(state, "invalidated"); assert(lua_toboolean(state, -1)); lua_pop(state, 1);
    execute(state, "cancel(); cancel=nil; collectgarbage('collect')");
    assert([[NSFileManager defaultManager] moveItemAtPath:moved toPath:directory error:nil]);
    puts("PASS removed or renamed status directories fail explicitly");

    NSString *cold = [directory stringByAppendingPathComponent:@"cold-session"];
    NSString *coldPath = [cold stringByAppendingPathComponent:@"status.json"];
    lua_pushstring(state, coldPath.fileSystemRepresentation); lua_setglobal(state, "coldPath");
    execute(state, "coldReady=false; cancel=assert(native.watch(coldPath,function(error) assert(error==nil); coldReady=true; finish() end)); assert(native.publish(coldPath,'ready'))");
    awaitEvents();
    lua_getglobal(state, "coldReady"); assert(lua_toboolean(state, -1)); lua_pop(state, 1);
    assert(stat(cold.fileSystemRepresentation, &info) == 0 && (info.st_mode & 0777) == 0700);
    execute(state, "cancel(); cancel=nil; collectgarbage('collect')");
    puts("PASS cold status watcher creates a private temporary directory before acknowledgement");

    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/sleep"];
    task.arguments = @[@"10"];
    assert([task launchAndReturnError:nil]);
    lua_pushinteger(state, task.processIdentifier); lua_setglobal(state, "pid");
    execute(state, "assert(native.process(pid,'/bin/false',function() error('wrong executable callback') end)==nil); exited=false; cancel=assert(native.process(pid,'/bin/sleep',function(error) assert(type(error)=='string'); exited=true; finish() end))");
    [task terminate];
    awaitEvents();
    lua_getglobal(state, "exited"); assert(lua_toboolean(state, -1)); lua_pop(state, 1);
    [task waitUntilExit];
    execute(state, "cancel(); assert(native.process(pid,'/bin/sleep',function() error('dead process callback') end)==nil)");
    puts("PASS executable validation and process exit invalidate readiness without polling");

    execute(state, "cancel=assert(native.watch(path,function() error('old Lua callback') end)); assert(native.publish(path,'reload pending')); native=nil");
    [skin resetLuaState];
    skin = [LuaSkin sharedWithState:NULL];
    state = skin.L;
    luaL_openlibs(state);
    lua_pushstring(state, argv[1]); lua_setglobal(state, "binary");
    lua_pushstring(state, path.fileSystemRepresentation); lua_setglobal(state, "path");
    lua_pushcfunction(state, finish); lua_setglobal(state, "finish");
    execute(state, "native=assert(package.loadlib(binary,'luaopen_url_router'))(); fresh=false; cancel=assert(native.watch(path,function(error) assert(error==nil); fresh=true; finish() end)); assert(native.publish(path,'fresh Lua state'))");
    awaitEvents();
    lua_getglobal(state, "fresh"); assert(lua_toboolean(state, -1)); lua_pop(state, 1);
    execute(state, "cancel(); cancel=nil; collectgarbage('collect')");
    puts("PASS Lua reload discards old callbacks while native cancellation code remains mapped");

    NSString *home = [directory stringByAppendingPathComponent:@"home"];
    NSString *support = [home stringByAppendingPathComponent:@"Library/Application Support/HammerspoonURLRouter"];
    assert([[NSFileManager defaultManager] createDirectoryAtPath:[support stringByAppendingPathComponent:@"selectors"]
      withIntermediateDirectories:YES attributes:nil error:nil]);
    NSString *statePath = [support stringByAppendingPathComponent:@"state.json"];
    NSString *statusPath = [directory stringByAppendingPathComponent:@"status.json"];
    assert(mkfifo(statePath.fileSystemRepresentation, 0600) == 0 && mkfifo(statusPath.fileSystemRepresentation, 0600) == 0);
    assert(setenv("HOME", home.fileSystemRepresentation, 1) == 0);
    lua_pushstring(state, argv[4]); lua_setglobal(state, "root");
    lua_pushstring(state, statePath.fileSystemRepresentation); lua_setglobal(state, "state");
    lua_pushstring(state, statusPath.fileSystemRepresentation); lua_setglobal(state, "status");
    lua_pushstring(state, argv[3]); lua_setglobal(state, "script");
    task = [NSTask new]; task.executableURL = [NSURL fileURLWithPath:@"/bin/sleep"]; task.arguments = @[@"30"];
    assert([task launchAndReturnError:nil]);
    lua_pushinteger(state, task.processIdentifier); lua_setglobal(state, "pid");
    lua_newtable(state);
    lua_pushcfunction(state, encode); lua_setfield(state, -2, "encode");
    lua_pushcfunction(state, decode); lua_setfield(state, -2, "decode");
    lua_pushcfunction(state, hash); lua_setfield(state, -2, "hash");
    lua_pushcfunction(state, permissions); lua_setfield(state, -2, "permissions");
    lua_setglobal(state, "json");
    alarm(3);
    execute(state, "metadata=assert(loadfile(script))(native,root,state,status,json,pid,finish)");
    alarm(0);
    const char *modes[] = { "uninstalling", "restored", "removed", "readyCleanup", "unexpected", "mismatch", "corrupt", "deniedState", "deniedStatus", "processCleanup", "pending" };
    for (NSUInteger index = 0; index < sizeof(modes) / sizeof(modes[0]); index++) {
      NSString *start = [NSString stringWithFormat:@"metadata.start('%s')", modes[index]];
      execute(state, start.UTF8String);
      if (!strcmp(modes[index], "readyCleanup") || !strcmp(modes[index], "unexpected") || !strcmp(modes[index], "processCleanup")) {
        execute(state, "metadata.acknowledge()"); awaitEvents(); execute(state, "metadata.ready()");
      }
      execute(state, "metadata.change()");
      if (!strcmp(modes[index], "processCleanup")) [task terminate];
      awaitEvents(); execute(state, "metadata.verify(); metadata.touch()");
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ CFRunLoopStop(CFRunLoopGetMain()); });
      awaitEvents(); execute(state, "metadata.repeated()");
    }
    execute(state, "metadata.close()"); awaitEvents(); execute(state, "metadata.closed()");
    if (task.running) [task terminate]; [task waitUntilExit];
    puts("RESULT 20 passed, 0 failed");
  }
  return 0;
}
