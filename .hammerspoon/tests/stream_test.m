#import <Foundation/Foundation.h>
#import <LuaSkin/LuaSkin.h>
#include <assert.h>
#include <spawn.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>

extern char **environ;

@interface StreamTestLog : NSObject <LuaSkinDelegate>
@end
@implementation StreamTestLog
- (void)handleCatastrophe:(NSString *)message { fprintf(stderr, "%s\n", message.UTF8String); abort(); }
- (void)logForLuaSkinAtLevel:(int)level withMessage:(NSString *)message {
  fprintf(stderr, "%s\n", message.UTF8String);
  if (level == LS_LOG_ERROR) abort();
}
@end

static const char *binary, *ffmpeg, *directory;
static int passed;

static void execute(lua_State *state, const char *code) {
  if (luaL_dostring(state, code)) { fprintf(stderr, "%s\n", lua_tostring(state, -1)); abort(); }
}
static void pass(const char *name) { printf("PASS %s\n", name); passed++; }
static int now(lua_State *state) { lua_pushnumber(state, CFAbsoluteTimeGetCurrent()); return 1; }
static int finish(lua_State *state) { (void)state; CFRunLoopStop(CFRunLoopGetMain()); return 0; }

// Connects to `path`, writes `data`, and hangs up.
static int deliver(lua_State *state) {
  struct sockaddr_un address = { .sun_family = AF_UNIX };
  strlcpy(address.sun_path, luaL_checkstring(state, 1), sizeof address.sun_path);
  size_t size;
  const char *data = luaL_checklstring(state, 2, &size);
  int client = socket(AF_UNIX, SOCK_STREAM, 0);
  assert(client >= 0 && connect(client, (struct sockaddr *)&address, sizeof address) == 0);
  assert(write(client, data, size) == (ssize_t)size);
  close(client);
  return 0;
}

// Fresh Lua with the module, paths, and helpers as globals.
static lua_State *prepare(LuaSkin *skin) {
  lua_State *state = skin.L;
  luaL_openlibs(state);
  lua_pushstring(state, binary); lua_setglobal(state, "binary");
  lua_pushstring(state, directory); lua_setglobal(state, "directory");
  lua_pushcfunction(state, now); lua_setglobal(state, "now");
  lua_pushcfunction(state, finish); lua_setglobal(state, "finish");
  lua_pushcfunction(state, deliver); lua_setglobal(state, "send");
  execute(state, "stream=assert(package.loadlib(binary,'luaopen_stream'))();"
    "local file=assert(io.open(directory..'/reference.pcm','rb')); reference=file:read('a'); file:close()");
  return state;
}

// Runs the main run loop until finish(), aborting after `seconds`; or, unless `strict`, just for them.
static void await(double seconds, BOOL strict) {
  __block BOOL done = NO;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    if (done) return;
    if (strict) { fprintf(stderr, "stream test timed out\n"); abort(); }
    CFRunLoopStop(CFRunLoopGetMain());
  });
  CFRunLoopRun();
  done = YES;
}

// ffmpeg's 2 s, 16 kHz s16le sine into `output`, in real time when `live`.
static pid_t sine(const char *output, BOOL live) {
  const char *arguments[] = { ffmpeg, "-hide_banner", "-loglevel", "fatal", "-nostdin", "-y",
    live ? "-re" : "-nostats", "-f", "lavfi", "-i", "sine=f=440:r=16000:d=2", "-f", "s16le", "-ac", "1",
    "-flush_packets", "1", output, NULL };
  pid_t pid;
  assert(posix_spawn(&pid, ffmpeg, NULL, NULL, (char *const *)arguments, environ) == 0);
  return pid;
}

static int reap(pid_t pid) {
  int status;
  assert(waitpid(pid, &status, 0) == pid);
  return status;
}

// Stops the run loop when `pid` exits, setting the Lua global `exited` to the time.
static void watch(lua_State *state, pid_t pid) {
  dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)pid,
    DISPATCH_PROC_EXIT, dispatch_get_main_queue());
  dispatch_source_set_event_handler(source, ^{
    lua_pushnumber(state, CFAbsoluteTimeGetCurrent()); lua_setglobal(state, "exited");
    dispatch_source_cancel(source);
    CFRunLoopStop(CFRunLoopGetMain());
  });
  dispatch_resume(source);
}

static void socketPath(lua_State *state, const char *name, char *path) {
  snprintf(path, 1024, "%s/%s.sock", directory, name);
  lua_pushstring(state, path); lua_setglobal(state, "path");
}

int main(int argc, char **argv) {
  @autoreleasepool {
    assert(argc == 4);
    binary = argv[1]; ffmpeg = argv[2]; directory = argv[3];
    char reference[1024], path[1024];
    snprintf(reference, sizeof reference, "%s/reference.pcm", directory);
    assert(reap(sine(reference, NO)) == 0);
    LuaSkin *skin = [LuaSkin sharedWithDelegate:[StreamTestLog new]];
    lua_State *state = prepare(skin);
    struct stat info;

    socketPath(state, "live", path);
    execute(state, "chunks,times={},{}; close=assert(stream.listen(path,function(chunk,problem)"
      " assert(chunk and not problem,problem); chunks[#chunks+1]=chunk; times[#times+1]=now() end))");
    assert(stat(path, &info) == 0 && S_ISSOCK(info.st_mode) && (info.st_mode & 0777) == 0600);
    char target[1100];
    snprintf(target, sizeof target, "unix:%s", path);
    pid_t pid = sine(target, YES);
    watch(state, pid);
    await(10, YES);
    assert(reap(pid) == 0);
    execute(state, "local rest,problem=close(); assert(problem==nil,problem);"
      " assert(table.concat(chunks)..rest==reference,'bytes lost or reordered');"
      " assert(#chunks>=10 and exited-times[1]>=1,'chunks came only at the end');"
      " assert(close()=='')");
    assert(stat(path, &info) != 0 && errno == ENOENT);
    pass("a live writer's bytes all arrive, in chunks well before it ends, and the socket goes away");

    socketPath(state, "busy", path);
    snprintf(target, sizeof target, "unix:%s", path);
    execute(state, "chunks={}; close=assert(stream.listen(path,function(chunk) chunks[#chunks+1]=chunk end))");
    assert(reap(sine(target, NO)) == 0); // main stays blocked: nothing can be delivered
    execute(state, "local rest,problem=close(); assert(problem==nil,problem);"
      " assert(#chunks==0 and rest==reference,'close() lost the undelivered bytes')");
    await(0.3, NO);
    execute(state, "assert(#chunks==0,'delivered after close()')");
    // Gone before the reader can accept it.
    socketPath(state, "quick", path);
    execute(state, "local data=string.rep('ab',2048); for _=1,50 do"
      " local close=assert(stream.listen(path,error)); send(path,data);"
      " local rest,problem=close(); assert(rest==data and problem==nil,'lost a finished writer') end");
    pass("close() returns every byte not yet delivered, and nothing is delivered after it");

    socketPath(state, "existing", path);
    execute(state, "local long=directory..'/'..string.rep('x',120);"
      " local close,problem=stream.listen(long,error); assert(close==nil and problem:find('too long'),problem);"
      " close,problem=stream.listen(directory..'/reference.pcm',error);"
      " assert(close==nil and problem:find('could not listen'),problem);"
      " assert(io.open(directory..'/reference.pcm')):close()");
    socketPath(state, "refused", path);
    execute(state, "failures={}; close=assert(stream.listen(path,function(chunk,problem)"
      " assert(chunk==nil); failures[#failures+1]=problem; finish() end))");
    // No descriptor left for accept().
    int client = socket(AF_UNIX, SOCK_STREAM, 0);
    struct rlimit limits;
    assert(client >= 0 && getrlimit(RLIMIT_NOFILE, &limits) == 0);
    struct rlimit tight = { .rlim_cur = (rlim_t)client + 1, .rlim_max = limits.rlim_max };
    assert(setrlimit(RLIMIT_NOFILE, &tight) == 0);
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    strlcpy(address.sun_path, path, sizeof address.sun_path);
    assert(connect(client, (struct sockaddr *)&address, sizeof address) == 0);
    await(3, YES);
    assert(setrlimit(RLIMIT_NOFILE, &limits) == 0);
    close(client);
    await(0.3, NO);
    execute(state, "assert(#failures==1 and failures[1]:find('accept'),failures[1]);"
      " local rest,problem=close(); assert(rest=='' and problem==nil)");
    assert(stat(path, &info) != 0 && errno == ENOENT);
    pass("listen failures return an error; a stream failure is raised once and stops it");

    socketPath(state, "collected", path);
    snprintf(target, sizeof target, "unix:%s", path);
    execute(state, "count=0; close=assert(stream.listen(path,function() count=count+1; finish() end))");
    pid = sine(target, YES);
    await(3, YES);
    execute(state, "close=nil; collectgarbage(); collectgarbage(); seen=count");
    await(0.3, NO);
    execute(state, "assert(count==seen,'delivered after collection')");
    reap(pid); // the closed socket ends it
    pass("a collected stream closes and delivers nothing more");

    socketPath(state, "old", path);
    snprintf(target, sizeof target, "unix:%s", path);
    execute(state, "close=assert(stream.listen(path,function() finish() end)); stream=nil");
    pid_t old = sine(target, YES);
    await(3, YES);
    [skin resetLuaState];
    skin = [LuaSkin sharedWithState:NULL];
    state = prepare(skin);
    socketPath(state, "fresh", path);
    snprintf(target, sizeof target, "unix:%s", path);
    execute(state, "chunks={}; close=assert(stream.listen(path,function(chunk) chunks[#chunks+1]=chunk end))");
    pid = sine(target, YES);
    watch(state, pid);
    await(10, YES);
    reap(old);
    assert(reap(pid) == 0);
    execute(state, "local rest=close(); assert(table.concat(chunks)..rest==reference,'old stream leaked in')");
    pass("a Lua reload mid-stream drops the old callbacks and a new stream works");

    printf("%d stream tests passed\n", passed);
  }
  return 0;
}
