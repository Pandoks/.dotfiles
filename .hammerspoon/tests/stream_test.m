#import <Foundation/Foundation.h>
#import <LuaSkin/LuaSkin.h>
#include <assert.h>
#include <dlfcn.h>
#include <spawn.h>
#include <stdatomic.h>
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
// LuaSkin holds its delegate weakly: without this, errors in callbacks are logged nowhere and pass.
static StreamTestLog *logger;
static int passed;

static void execute(lua_State *state, const char *code) {
  if (luaL_dostring(state, code)) { fprintf(stderr, "%s\n", lua_tostring(state, -1)); abort(); }
}
static void pass(const char *name) { printf("PASS %s\n", name); fflush(stdout); passed++; }
static int now(lua_State *state) { lua_pushnumber(state, CFAbsoluteTimeGetCurrent()); return 1; }
static int finish(lua_State *state) { (void)state; CFRunLoopStop(CFRunLoopGetMain()); return 0; }

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
    alarm(300); // the guards run on main, which a hung close() or reap() blocks
    binary = argv[1]; ffmpeg = argv[2]; directory = argv[3];
    atomic_int *armed = dlsym(RTLD_DEFAULT, "armed");
    assert(armed && unsetenv("DYLD_INSERT_LIBRARIES") == 0);
    char reference[1024], path[1024];
    snprintf(reference, sizeof reference, "%s/reference.pcm", directory);
    assert(reap(sine(reference, NO)) == 0);
    logger = [StreamTestLog new];
    LuaSkin *skin = [LuaSkin sharedWithDelegate:logger];
    lua_State *state = prepare(skin);
    struct stat info;

    execute(state, "local long=directory..'/'..string.rep('x',120);"
      " local close,problem=stream.listen(long,error); assert(close==nil and problem:find('too long'),problem);"
      " close,problem=stream.listen(directory..'/reference.pcm',error);"
      " assert(close==nil and problem:find('could not listen'),problem);"
      " assert(io.open(directory..'/reference.pcm')):close()");
    socketPath(state, "refused", path);
    execute(state, "failures={}; close=assert(stream.listen(path,function(chunk,problem)"
      " assert(chunk==nil); failures[#failures+1]=problem; finish() end))");
    // No descriptor left for accept(); first, so no earlier stream is still closing one.
    int client = socket(AF_UNIX, SOCK_STREAM, 0);
    struct rlimit limits;
    assert(client >= 0 && getrlimit(RLIMIT_NOFILE, &limits) == 0);
    struct rlimit tight = { .rlim_cur = (rlim_t)client + 1, .rlim_max = limits.rlim_max };
    assert(setrlimit(RLIMIT_NOFILE, &tight) == 0);
    assert(dup(client) < 0 && errno == EMFILE);
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    strlcpy(address.sun_path, path, sizeof address.sun_path);
    assert(connect(client, (struct sockaddr *)&address, sizeof address) == 0);
    await(30, YES);
    assert(setrlimit(RLIMIT_NOFILE, &limits) == 0);
    close(client);
    await(0.3, NO);
    execute(state, "assert(#failures==1 and failures[1]:find('accept'),failures[1]);"
      " local rest,problem=close(); assert(rest=='' and problem==nil)");
    assert(stat(path, &info) != 0 && errno == ENOENT);
    pass("listen failures return an error; a stream failure is raised once and stops it");

    socketPath(state, "live", path);
    execute(state, "chunks,times={},{}; close=assert(stream.listen(path,function(chunk,problem)"
      " assert(chunk and not problem,problem); chunks[#chunks+1]=chunk; times[#times+1]=now() end));"
      " collectgarbage()"); // test 1's closed stream, whose callback reference this one reuses
    assert(stat(path, &info) == 0 && S_ISSOCK(info.st_mode) && (info.st_mode & 0777) == 0600);
    char target[1100];
    snprintf(target, sizeof target, "unix:%s", path);
    pid_t pid = sine(target, YES);
    watch(state, pid);
    await(60, YES);
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
    int lowest = dup(STDERR_FILENO);
    close(lowest);
    // Stopped before the writer connects.
    socketPath(state, "unused", path);
    execute(state, "local rest,problem=assert(stream.listen(path,error))();"
      " assert(rest=='' and problem==nil,problem)");
    assert(stat(path, &info) != 0 && errno == ENOENT);
    // Gone before the reader can accept it.
    socketPath(state, "quick", path);
    execute(state, "alive=setmetatable({},{__mode='k'}); local data=string.rep('ab',2048); for _=1,50 do"
      " local callback=function() error(data) end; alive[callback]=true;"
      " local close=assert(stream.listen(path,callback)); send(path,data);"
      " local rest,problem=close(); assert(rest==data and problem==nil,'lost a finished writer') end");
    await(0.3, NO); // the read queue closes their sockets
    execute(state, "collectgarbage(); collectgarbage(); assert(next(alive)==nil,'kept a callback')");
    int next = dup(STDERR_FILENO);
    assert(next == lowest); // no socket left open
    close(next);
    pass("close() returns every byte not yet delivered, delivers nothing after it, and keeps no socket or callback");

    socketPath(state, "reentrant", path);
    execute(state, "closed=nil; close=assert(stream.listen(path,function(chunk)"
      " assert(chunk and not closed,'raised after close()'); closed=table.pack(close()); finish() end))");
    atomic_store(armed, 1);
    execute(state, "send(path,'ab')");
    await(30, YES);
    await(0.3, NO);
    execute(state, "assert(closed[1]=='' and closed[2] and closed[2]:find('read'),'close() lost the read error')");
    pass("close() from a chunk callback returns the read failure that came with the chunk");

    socketPath(state, "collected", path);
    snprintf(target, sizeof target, "unix:%s", path);
    execute(state, "count=0; close=assert(stream.listen(path,function() count=count+1; finish() end))");
    pid = sine(target, YES);
    await(30, YES);
    execute(state, "close=nil; collectgarbage(); collectgarbage(); seen=count");
    await(0.3, NO);
    execute(state, "assert(count==seen,'delivered after collection')");
    reap(pid); // the closed socket ends it
    pass("a collected stream closes and delivers nothing more");

    socketPath(state, "old", path);
    snprintf(target, sizeof target, "unix:%s", path);
    execute(state, "close=assert(stream.listen(path,function() finish() end))");
    pid_t old = sine(target, YES);
    await(30, YES);
    usleep(300000); // the next chunk's delivery waits on main
    [skin resetLuaState];
    await(0.3, NO); // and runs before the module loads again
    skin = [LuaSkin sharedWithState:NULL];
    state = prepare(skin);
    socketPath(state, "fresh", path);
    snprintf(target, sizeof target, "unix:%s", path);
    execute(state, "chunks={}; close=assert(stream.listen(path,function(chunk) chunks[#chunks+1]=chunk end))");
    pid = sine(target, YES);
    watch(state, pid);
    await(60, YES);
    reap(old);
    assert(reap(pid) == 0);
    execute(state, "local rest=close(); assert(table.concat(chunks)..rest==reference,'old stream leaked in')");
    pass("a Lua reload mid-stream drops the old callbacks and a new stream works");

    execute(state,
      "function encode(sample)\n"
      "  local out = {}\n"
      "  for i = 1, 1024 do\n"
      "    out[i] = string.pack('<i2', math.floor(math.max(-1, math.min(32767 / 32768, sample(i))) * 32768))\n"
      "  end\n"
      "  return table.concat(out)\n"
      "end\n"
      "function refFft(real, imag)\n"
      "  local n, j = #real, 1\n"
      "  for i = 1, n - 1 do\n"
      "    if i < j then real[i], real[j] = real[j], real[i]; imag[i], imag[j] = imag[j], imag[i] end\n"
      "    local bit = n // 2\n"
      "    while bit >= 1 and j > bit do j = j - bit; bit = bit // 2 end\n"
      "    j = j + bit\n"
      "  end\n"
      "  local span = 2\n"
      "  while span <= n do\n"
      "    local step = -2 * math.pi / span\n"
      "    local sr, si = math.cos(step), math.sin(step)\n"
      "    for start = 1, n, span do\n"
      "      local tr, ti = 1, 0\n"
      "      for off = 0, span // 2 - 1 do\n"
      "        local u, l = start + off, start + off + span // 2\n"
      "        local pr, pi = real[l] * tr - imag[l] * ti, real[l] * ti + imag[l] * tr\n"
      "        real[l], imag[l] = real[u] - pr, imag[u] - pi\n"
      "        real[u], imag[u] = real[u] + pr, imag[u] + pi\n"
      "        tr, ti = tr * sr - ti * si, tr * si + ti * sr\n"
      "      end\n"
      "    end\n"
      "    span = span * 2\n"
      "  end\n"
      "end\n");
    execute(state,
      "local function refAnalyze(pcm, bins)\n"
      "  local real, imag, energy = {}, {}, 0\n"
      "  for i = 1, 1024 do\n"
      "    local v = string.unpack('<i2', pcm, 2 * i - 1) / 32768\n"
      "    energy = energy + v * v\n"
      "    real[i] = v * (0.5 - 0.5 * math.cos(2 * math.pi * (i - 1) / 1023))\n"
      "    imag[i] = 0\n"
      "  end\n"
      "  local rms = math.sqrt(energy / 1024) + 1e-9\n"
      "  local level = math.max(0, math.min(1, (20 * math.log(rms, 10) + 50) / 40))\n"
      "  refFft(real, imag)\n"
      "  local bands = {}\n"
      "  for b = 1, #bins do\n"
      "    local low, high = bins[b - 1], math.max(bins[b - 1] + 1, bins[b])\n"
      "    local sum = 0\n"
      "    for bin = low, high - 1 do sum = sum + math.sqrt(real[bin + 1] ^ 2 + imag[bin + 1] ^ 2) end\n"
      "    bands[b] = math.sqrt(sum / (high - low))\n"
      "  end\n"
      "  return level, energy, bands\n"
      "end\n"
      "local bins = {}\n"
      "for edge = 0, 8 do\n"
      "  local freq = 80 * (8000 * 0.98 / 80) ^ (edge / 8)\n"
      "  bins[edge] = math.max(1, math.min(512, math.floor(freq / 8000 * 512)))\n"
      "end\n"
      "local sine = encode(function(i) return 0.5 * math.sin(i * 2 * math.pi * 440 / 16000) end)\n"
      "local level, energy, peak, bands = stream.analyze(sine, bins)\n"
      "local refLevel, refEnergy, refBands = refAnalyze(sine, bins)\n"
      "assert(math.abs(level - refLevel) < 1e-4 and math.abs(energy - refEnergy) < 1e-4 and math.abs(peak - refLevel) < 1e-4)\n"
      "for b = 1, 8 do\n"
      "  assert(math.abs(bands[b] - refBands[b]) < 1e-4, string.format('band %d: %g vs %g', b, bands[b], refBands[b]))\n"
      "  if b ~= 4 then assert(bands[4] > bands[b], string.format('band 4 (%g) <= band %d (%g)', bands[4], b, bands[b])) end\n"
      "end\n"
      "local multi = encode(function(i)\n"
      "  return 0.25 * math.sin(i * 2 * math.pi * 200 / 16000)\n"
      "    + 0.25 * math.sin(i * 2 * math.pi * 440 / 16000)\n"
      "    + 0.20 * math.sin(i * 2 * math.pi * 2000 / 16000)\n"
      "    + 0.20 * math.sin(i * 2 * math.pi * 7500 / 16000)\n"
      "end)\n"
      "local ml, me, mp, mb = stream.analyze(multi, bins)\n"
      "local rl, re, rb = refAnalyze(multi, bins)\n"
      "assert(math.abs(ml - rl) < 1e-4 and math.abs(me - re) < 1e-4 and math.abs(mp - rl) < 1e-4)\n"
      "for b = 1, 8 do assert(math.abs(mb[b] - rb[b]) < 1e-4) end\n"
      "local nyquist = encode(function(i) return (i % 2 == 0 and 1 or -1) * 0.5 end)\n"
      "local nyqBins = { [0] = 512, [1] = 512 }\n"
      "local nl, ne, np, nb = stream.analyze(nyquist, nyqBins)\n"
      "local rnl, rne, rnb = refAnalyze(nyquist, nyqBins)\n"
      "assert(math.abs(nl - rnl) < 1e-4 and math.abs(ne - rne) < 1e-4 and math.abs(np - rnl) < 1e-4)\n"
      "assert(math.abs(nb[1] - rnb[1]) < 1e-4 and nb[1] > 10, tostring(nb[1]))\n");
    pass("stream.analyze matches reference FFT within 1e-4 across tones and Nyquist bin");

    execute(state,
      "local bins = { [0] = 1, 2, 4, 8, 16, 32, 64, 128, 501 }\n"
      "local quiet = string.rep('\\0', 2048)\n"
      "local ql, qe, qp, qb = stream.analyze(quiet, bins)\n"
      "assert(ql == 0 and qe == 0 and qp == 0)\n"
      "for b = 1, #bins do assert(qb[b] == 0) end\n"
      "local loud = {}\n"
      "for i = 1, 1024 do loud[i] = string.pack('<i2', math.floor(0.05 * 32767 * math.sin(i * 2 * math.pi * 440 / 16000))) end\n"
      "local tone = table.concat(loud)\n"
      "local tl = stream.analyze(tone, bins)\n"
      "assert(tl > 0.5 and tl < 0.55)\n"
      "for _, pcm in ipairs({ tone .. quiet .. quiet, quiet .. tone .. quiet, 'x' .. tone .. quiet }) do\n"
      "  local l, e, p = stream.analyze(pcm, bins)\n"
      "  assert(l == 0 and e == 0 and math.abs(p - tl) < 1e-6, tostring(p))\n"
      "end\n"
      "for _, bad in ipairs({\n"
      "  function() stream.analyze() end,\n"
      "  function() stream.analyze(123, bins) end,\n"
      "  function() stream.analyze(string.rep('\\0', 2047), bins) end,\n"
      "  function() stream.analyze(quiet, 'bins') end,\n"
      "  function() stream.analyze(quiet, {}) end,\n"
      "  function() stream.analyze(quiet, { 10 }) end,\n"
      "  function() stream.analyze(quiet, { [0] = -1, [1] = 10 }) end,\n"
      "  function() stream.analyze(quiet, { [0] = 1, [1] = 513 }) end,\n"
      "  function() stream.analyze(quiet, { [0] = 1, [1] = 1.5 }) end,\n"
      "  function() stream.analyze(quiet, { [0] = 1, [1] = '10' }) end,\n"
      "}) do assert(not pcall(bad), 'expected error') end\n");
    pass("stream.analyze handles silence, multi-window unaligned peaks, and invalid inputs");

    printf("RESULT %d passed, 0 failed\n", passed);
  }
  return 0;
}
