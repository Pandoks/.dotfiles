// Remote CFMessagePort client using a private reply mode so sends never pump the main run loop.
#import <Foundation/Foundation.h>
#import <LuaSkin/LuaSkin.h>

static const char *metatableName = "port.remote";

static int closePort(lua_State *state) {
  CFMessagePortRef *box = luaL_checkudata(state, 1, metatableName);
  if (*box) {
    CFMessagePortInvalidate(*box);
    CFRelease(*box);
    *box = NULL;
  }
  return 0;
}

static int valid(lua_State *state) {
  CFMessagePortRef *box = luaL_checkudata(state, 1, metatableName);
  lua_pushboolean(state, *box && CFMessagePortIsValid(*box));
  return 1;
}

static const char *statusMessage(SInt32 status) {
  switch (status) {
  case kCFMessagePortSendTimeout: return "send timed out";
  case kCFMessagePortReceiveTimeout: return "receive timed out";
  case kCFMessagePortIsInvalid: return "port is invalid";
  case kCFMessagePortTransportError: return "transport error";
  case kCFMessagePortBecameInvalidError: return "port became invalid";
  default: return NULL;
  }
}

static int sendMessage(lua_State *state) {
  CFMessagePortRef *box = luaL_checkudata(state, 1, metatableName);
  size_t length = 0;
  const char *bytes = luaL_checklstring(state, 2, &length);
  double timeout = luaL_optnumber(state, 3, 0.5);
  if (!*box || !CFMessagePortIsValid(*box)) {
    lua_pushboolean(state, 0);
    lua_pushliteral(state, "port is invalid");
    return 2;
  }
  CFDataRef data = CFDataCreate(NULL, (const UInt8 *)bytes, (CFIndex)length);
  if (!data) {
    lua_pushboolean(state, 0);
    lua_pushliteral(state, "could not encode request");
    return 2;
  }
  CFDataRef reply = NULL;
  SInt32 status = CFMessagePortSendRequest(
    *box, 0, data, timeout, timeout, CFSTR("org.hammerspoon.port.reply"), &reply);
  CFRelease(data);
  if (status != kCFMessagePortSuccess) {
    if (reply) CFRelease(reply);
    lua_pushboolean(state, 0);
    const char *message = statusMessage(status);
    if (message) lua_pushstring(state, message);
    else lua_pushfstring(state, "send failed (%d)", (int)status);
    return 2;
  }
  lua_pushboolean(state, 1);
  if (reply) {
    lua_pushlstring(state, (const char *)CFDataGetBytePtr(reply), (size_t)CFDataGetLength(reply));
    CFRelease(reply);
  } else {
    lua_pushliteral(state, "");
  }
  return 2;
}

static int openPort(lua_State *state) {
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  [skin checkArgs:LS_TSTRING, LS_TBREAK];
  NSString *name = [skin toNSObjectAtIndex:1];
  CFMessagePortRef port = CFMessagePortCreateRemote(NULL, (__bridge CFStringRef)name);
  if (!port) {
    lua_pushnil(state);
    return 1;
  }
  CFMessagePortRef *box = lua_newuserdata(state, sizeof *box);
  *box = port;
  luaL_setmetatable(state, metatableName);
  return 1;
}

static const luaL_Reg functions[] = {
  { "open", openPort },
  { NULL, NULL },
};

static const luaL_Reg methods[] = {
  { "delete", closePort },
  { "isValid", valid },
  { "send", sendMessage },
  { "__gc", closePort },
  { NULL, NULL },
};

int luaopen_port(lua_State *state) {
  luaL_newmetatable(state, metatableName);
  lua_pushvalue(state, -1);
  lua_setfield(state, -2, "__index");
  luaL_setfuncs(state, methods, 0);
  lua_pop(state, 1);
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  [skin registerLibrary:"port" functions:functions metaFunctions:nil];
  return 1;
}
