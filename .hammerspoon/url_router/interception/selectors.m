#import "selectors.h"
#import "matcher.h"
#import <CommonCrypto/CommonDigest.h>
#import <os/lock.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

static void push(lua_State *state, NSString *value) {
  if (!value) { lua_pushnil(state); return; }
  NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
  lua_pushlstring(state, data.bytes, data.length);
}

@implementation URLSelectorStore {
  lua_State *_state;
  os_unfair_lock _lock;
  int _directory;
  NSString *_name;
  dispatch_queue_t _queue;
  dispatch_source_t _source;
  NSData *_bytes;
  NSDictionary *_snapshot;
  NSMutableDictionary *_generations;
  void (^_report)(NSDictionary *);
}

- (instancetype)initWithPath:(NSString *)path report:(void (^)(NSDictionary *))report {
  if (!(self = [super init])) return nil;
  _lock = OS_UNFAIR_LOCK_INIT;
  _report = [report copy];
  _generations = [NSMutableDictionary new];
  _snapshot = @{};
  _name = path.lastPathComponent;
  _directory = open(path.stringByDeletingLastPathComponent.fileSystemRepresentation,
    O_EVTONLY | O_CLOEXEC | O_NOFOLLOW);
  struct stat directory;
  if (_directory < 0 || fstat(_directory, &directory) || !S_ISDIR(directory.st_mode)
      || directory.st_uid != getuid() || (directory.st_mode & 0022)) {
    if (_directory >= 0) close(_directory);
    _directory = -1;
    [self fail:@"watch-open" error:@"Selector directory must be owned by this user and not writable by others"];
    return self;
  }
  _queue = dispatch_queue_create("local.pandoks.url-router.selectors", DISPATCH_QUEUE_SERIAL);
  _source = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)_directory,
    DISPATCH_VNODE_WRITE | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_REVOKE, _queue);
  if (!_source) {
    close(_directory); _directory = -1;
    [self fail:@"watch-create" error:@"Could not watch selector directory"];
    return self;
  }
  __weak URLSelectorStore *weak = self;
  dispatch_source_set_event_handler(_source, ^{
    URLSelectorStore *store = weak;
    if (!store) return;
    unsigned long flags = dispatch_source_get_data(store->_source);
    if (flags & (DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_REVOKE)) {
      [store fail:@"watch-invalidated" error:@"Selector directory was removed or replaced"];
      dispatch_source_cancel(store->_source);
      return;
    }
    [store reload];
  });
  int descriptor = _directory;
  dispatch_source_set_cancel_handler(_source, ^{ close(descriptor); });
  dispatch_resume(_source);
  dispatch_sync(_queue, ^{ [self reload]; });
  return self;
}

- (NSDictionary *)snapshot {
  os_unfair_lock_lock(&_lock);
  NSDictionary *snapshot = _snapshot;
  os_unfair_lock_unlock(&_lock);
  return snapshot;
}

- (void)fail:(NSString *)stage error:(NSString *)error {
  os_unfair_lock_lock(&_lock);
  lua_State *previous = _state;
  _state = NULL;
  NSMutableDictionary *event = [_snapshot mutableCopy];
  event[@"kind"] = @"error";
  event[@"stage"] = stage;
  event[@"error"] = error ?: @"Unknown selector error";
  _snapshot = [event copy];
  os_unfair_lock_unlock(&_lock);
  if (previous) lua_close(previous);
  _report(event);
}

- (void)reload {
  int file = openat(_directory, _name.fileSystemRepresentation, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW);
  if (file < 0) {
    _bytes = nil;
    [self fail:@"snapshot-open" error:@(strerror(errno))];
    return;
  }
  struct stat before, after;
  if (fstat(file, &before) || !S_ISREG(before.st_mode) || before.st_uid != getuid()
      || (before.st_mode & 0022) || before.st_size <= 0 || before.st_size > 1024 * 1024) {
    close(file); _bytes = nil;
    [self fail:@"snapshot-file" error:@"Expected a user-owned regular snapshot of at most 1 MiB, not writable by others"];
    return;
  }
  NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)before.st_size];
  size_t offset = 0;
  while (offset < data.length) {
    ssize_t count = pread(file, (char *)data.mutableBytes + offset, data.length - offset, (off_t)offset);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) break;
    offset += (size_t)count;
  }
  BOOL unchanged = fstat(file, &after) == 0 && before.st_size == after.st_size
    && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
    && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec;
  close(file);
  if (offset != data.length || !unchanged) {
    _bytes = nil;
    [self fail:@"snapshot-read" error:@"Snapshot changed while reading; publish replacements atomically"];
    return;
  }
  if ([data isEqualToData:_bytes]) return;
  _bytes = [data copy];
  NSError *error;
  id document = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
  id rules = [document isKindOfClass:NSDictionary.class] ? document[@"rules"] : nil;
  id version = [document isKindOfClass:NSDictionary.class] ? document[@"version"] : nil;
  id generation = [document isKindOfClass:NSDictionary.class] ? document[@"generation"] : nil;
  NSCharacterSet *tokens = [NSCharacterSet characterSetWithCharactersInString:
    @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"];
  if (![version isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)version) == CFBooleanGetTypeID()
      || [version doubleValue] != 1 || ![rules isKindOfClass:NSArray.class]
      || ![generation isKindOfClass:NSString.class] || ![generation length] || [generation length] > 128
      || [generation rangeOfCharacterFromSet:tokens.invertedSet].location != NSNotFound) {
    [self fail:@"snapshot-json" error:error.localizedDescription ?: @"Expected version 1, a generation token and ordered rules"];
    return;
  }
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
  NSMutableString *hash = [NSMutableString new];
  for (NSUInteger i = 0; i < sizeof(digest); i++) [hash appendFormat:@"%02x", digest[i]];
  NSDictionary *metadata = @{@"generation": generation, @"sha256": hash, @"count": @([rules count]), @"kind": @"loaded"};
  if (_generations[generation] && ![_generations[generation] isEqual:hash]) {
    [self fail:@"snapshot-generation" error:@"A generation token cannot identify different selector bytes"];
    return;
  }
  for (id rule in rules) {
    if (![rule isKindOfClass:NSDictionary.class]) {
      [self fail:@"snapshot-rule" error:@"Expected selector objects"];
      return;
    }
    id host = rule[@"host"], pattern = rule[@"pattern"];
    BOOL validHost = [host isKindOfClass:NSString.class] && [host length] && !pattern;
    BOOL validPattern = [pattern isKindOfClass:NSString.class] && !host;
    if ((!validHost && !validPattern) || [rule count] != 1) {
      [self fail:@"snapshot-rule" error:@"Each selector must contain exactly one host or Lua pattern"];
      return;
    }
  }
  lua_State *next = luaL_newstate();
  if (!next) { [self fail:@"snapshot-lua" error:@"Could not initialize Lua"]; return; }
  luaL_requiref(next, "_G", luaopen_base, 1); lua_pop(next, 1);
  luaL_requiref(next, LUA_STRLIBNAME, luaopen_string, 1); lua_pop(next, 1);
  if (luaL_loadbuffer(next, (const char *)matcher, sizeof(matcher), "url_router.match") != LUA_OK
      || lua_pcall(next, 0, 1, 0) != LUA_OK) {
    NSString *failure = @(lua_tostring(next, -1) ?: "Could not compile selector matcher");
    lua_close(next); [self fail:@"snapshot-compile" error:failure]; return;
  }
  lua_setglobal(next, "classify");
  lua_createtable(next, (int)[rules count], 0);
  NSUInteger index = 0;
  for (NSDictionary *rule in rules) {
    if (rule[@"pattern"]) {
      lua_getglobal(next, "string"); lua_getfield(next, -1, "match"); lua_remove(next, -2);
      lua_pushliteral(next, ""); push(next, rule[@"pattern"]);
      if (lua_pcall(next, 2, 1, 0) != LUA_OK) {
        NSString *failure = @(lua_tostring(next, -1) ?: "Invalid Lua pattern");
        lua_close(next); [self fail:@"snapshot-pattern" error:failure]; return;
      }
      lua_pop(next, 1);
    }
    lua_createtable(next, 0, 1);
    NSString *key = rule[@"host"] ? @"host" : @"pattern";
    push(next, rule[key]); lua_setfield(next, -2, key.UTF8String);
    lua_rawseti(next, -2, (lua_Integer)++index);
  }
  lua_setglobal(next, "rules");
  os_unfair_lock_lock(&_lock);
  lua_State *previous = _state;
  _state = next;
  _snapshot = metadata;
  os_unfair_lock_unlock(&_lock);
  if (previous) lua_close(previous);
  _generations[generation] = hash;
  _report(metadata);
}

- (int)classifyURL:(NSURL *)url snapshot:(NSDictionary **)snapshot {
  os_unfair_lock_lock(&_lock);
  if (snapshot) *snapshot = _snapshot;
  if (!_state) { os_unfair_lock_unlock(&_lock); return -1; }
  lua_getglobal(_state, "classify"); lua_getglobal(_state, "rules");
  push(_state, url.absoluteString); push(_state, url.host); push(_state, url.scheme);
  int result = -1;
  NSString *error;
  if (lua_pcall(_state, 4, 2, 0) == LUA_OK) {
    result = (int)lua_tointeger(_state, -2);
    if (result < 0) error = @(lua_tostring(_state, -1) ?: "Rule classification failed");
    lua_pop(_state, 2);
  } else {
    error = @(lua_tostring(_state, -1) ?: "Rule classification failed");
    lua_pop(_state, 1);
  }
  if (!error) { os_unfair_lock_unlock(&_lock); return result; }
  lua_State *previous = _state;
  _state = NULL;
  NSMutableDictionary *event = [_snapshot mutableCopy];
  event[@"kind"] = @"error"; event[@"stage"] = @"classifier"; event[@"error"] = error;
  _snapshot = [event copy];
  NSDictionary *failed = _snapshot;
  os_unfair_lock_unlock(&_lock);
  lua_close(previous);
  dispatch_async(_queue, ^{ if (self.snapshot == failed) self->_report(failed); });
  return -1;
}

- (void)stop {
  if (_source) dispatch_source_cancel(_source);
}

- (void)dealloc {
  if (_source) dispatch_source_cancel(_source);
  if (_state) lua_close(_state);
}
@end
