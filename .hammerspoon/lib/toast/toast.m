#import <Cocoa/Cocoa.h>
#import <LuaSkin/LuaSkin.h>
#include <dlfcn.h>

static const char *tag = "toast.glass";

// A reload dlcloses this while a fade's completion block may still run.
static BOOL keepImageLoaded(void) {
  static void *handle;
  if (handle) return YES;
  Dl_info image;
  if (!dladdr(&tag, &image)) return NO;
  handle = dlopen(image.dli_fname, RTLD_NOW | RTLD_LOCAL);
  return handle != NULL;
}

// Full glass without key focus, as AppKit's menus do; otherwise it's a subdued blur.
@interface ToastPanel : NSPanel
@end

@implementation ToastPanel
- (BOOL)_hasActiveAppearanceIgnoringKeyFocus {
  return YES;
}
@end

// Tinted so its text reads over white and black windows.
static void style(NSPanel *panel, BOOL dark) {
  panel.appearance = [NSAppearance appearanceNamed:dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
  NSColor *tint = dark ? [NSColor colorWithWhite:0 alpha:0.6] : [NSColor colorWithWhite:1 alpha:0.7];
  ((NSGlassEffectView *)panel.contentView).tintColor = tint;
}

// glass(canvas, radius, fade, dark)
static int glass(lua_State *state) {
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  [skin checkArgs:LS_TUSERDATA, "hs.canvas", LS_TNUMBER, LS_TNUMBER, LS_TBOOLEAN, LS_TBREAK];
  NSWindow *canvas = ((NSView *)[skin toNSObjectAtIndex:1]).window;
  luaL_argcheck(state, canvas != nil, 1, "canvas has no window");
  CGFloat radius = lua_tonumber(state, 2);
  NSTimeInterval fade = lua_tonumber(state, 3);
  void **pointer = lua_newuserdata(state, sizeof(void *));
  *pointer = NULL;
  luaL_setmetatable(state, tag);
  NSPanel *panel = [[ToastPanel alloc] initWithContentRect:canvas.frame
                                                  styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
  panel.opaque = NO;
  panel.backgroundColor = NSColor.clearColor;
  panel.ignoresMouseEvents = YES;
  panel.animationBehavior = NSWindowAnimationBehaviorNone;
  panel.collectionBehavior = canvas.collectionBehavior;

  NSGlassEffectView *view = [[NSGlassEffectView alloc] initWithFrame:panel.contentView.bounds];
  view.cornerRadius = radius;
  view.style = NSGlassEffectViewStyleClear;
  panel.contentView = view;
  style(panel, lua_toboolean(state, 4));

  panel.alphaValue = 0;
  [canvas addChildWindow:panel ordered:NSWindowBelow];
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
    context.duration = fade;
    panel.animator.alphaValue = 1;
  }];

  *pointer = (__bridge_retained void *)panel;
  return 1;
}

// glass:hide(fade). The fade holds the panel, so a collection can't cut it short.
static int hide(lua_State *state) {
  void **pointer = luaL_checkudata(state, 1, tag);
  NSTimeInterval fade = luaL_optnumber(state, 2, 0);
  NSPanel *panel = (__bridge_transfer NSPanel *)*pointer;
  *pointer = NULL;
  if (fade <= 0) {
    [panel orderOut:nil];
    return 0;
  }
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
    context.duration = fade;
    panel.animator.alphaValue = 0;
  } completionHandler:^{
    [panel orderOut:nil];
  }];
  return 0;
}

// glass:paint(dark), once macOS's appearance changes.
static int paint(lua_State *state) {
  void **pointer = luaL_checkudata(state, 1, tag);
  luaL_checktype(state, 2, LUA_TBOOLEAN);
  style((__bridge NSPanel *)*pointer, lua_toboolean(state, 2));
  return 0;
}

static const luaL_Reg functions[] = {
  { "glass", glass },
  { NULL, NULL },
};

int luaopen_toast(lua_State *state) {
  if (!keepImageLoaded()) return luaL_error(state, "could not retain toast library");
  if (!NSClassFromString(@"NSGlassEffectView")) return luaL_error(state, "Liquid Glass needs macOS 26");
  if (![NSPanel instancesRespondToSelector:@selector(_hasActiveAppearanceIgnoringKeyFocus)]) {
    return luaL_error(state, "Liquid Glass: AppKit has no _hasActiveAppearanceIgnoringKeyFocus");
  }
  luaL_newmetatable(state, tag);
  lua_newtable(state);
  lua_pushcfunction(state, hide);
  lua_setfield(state, -2, "hide");
  lua_pushcfunction(state, paint);
  lua_setfield(state, -2, "paint");
  lua_setfield(state, -2, "__index");
  lua_pushcfunction(state, hide);
  lua_setfield(state, -2, "__gc");
  lua_pop(state, 1);
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  [skin registerLibrary:"toast" functions:functions metaFunctions:nil];
  return 1;
}
