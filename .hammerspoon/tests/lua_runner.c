#include <stdio.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

int main(int argc, char **argv) {
  if (argc < 2) return 2;
  lua_State *L = luaL_newstate();
  luaL_openlibs(L);
  lua_newtable(L);
  for (int i = 1; i < argc; ++i) {
    lua_pushstring(L, argv[i]);
    lua_rawseti(L, -2, i - 1);
  }
  lua_setglobal(L, "arg");
  int status = luaL_loadfile(L, argv[1]);
  if (!status) status = lua_pcall(L, 0, LUA_MULTRET, 0);
  if (status) fprintf(stderr, "%s\n", lua_tostring(L, -1));
  lua_close(L);
  return status ? 1 : 0;
}
