#import <Cocoa/Cocoa.h>
#import <LuaSkin/LuaSkin.h>
#include <dlfcn.h>

static LSRefTable refTable = LUA_NOREF;
static const char *tag = "toast.glass";

// Lua closes loadlib handles on reload while a fade's completion block may still run.
static BOOL keepImageLoaded(void) {
  static void *handle;
  if (handle) return YES;
  Dl_info image;
  if (!dladdr(&tag, &image)) return NO;
  handle = dlopen(image.dli_fname, RTLD_NOW | RTLD_LOCAL);
  return handle != NULL;
}

// Full Liquid Glass (edge lensing, a rim highlight) without key focus, as AppKit's own menus get
// it: a window without an active appearance gets a subdued blur, and only the active app's key or
// main window has one.
@interface ToastPanel : NSPanel
@end

@implementation ToastPanel
- (BOOL)_hasActiveAppearanceIgnoringKeyFocus { // private
  return YES;
}
@end

// glass(canvas, radius, fade): Liquid Glass under a shown canvas, fading in with it. A child window
// below the canvas's, it moves and orders with the canvas and lets its clicks through.
static int glass(lua_State *state) {
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  [skin checkArgs:LS_TUSERDATA, "hs.canvas", LS_TNUMBER, LS_TNUMBER, LS_TBREAK];
  NSWindow *canvas = ((NSView *)[skin toNSObjectAtIndex:1]).window;
  luaL_argcheck(state, canvas != nil, 1, "canvas has no window");
  CGFloat radius = lua_tonumber(state, 2);
  NSTimeInterval fade = lua_tonumber(state, 3);
  NSPanel *panel = [[ToastPanel alloc] initWithContentRect:canvas.frame
                                                  styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
  panel.releasedWhenClosed = NO;
  panel.opaque = NO;
  panel.backgroundColor = NSColor.clearColor;
  panel.hasShadow = YES;
  panel.ignoresMouseEvents = YES;
  panel.animationBehavior = NSWindowAnimationBehaviorNone;
  panel.level = canvas.level;
  panel.collectionBehavior = canvas.collectionBehavior;
  panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];

  NSGlassEffectView *view = [[NSGlassEffectView alloc] initWithFrame:panel.contentView.bounds];
  view.cornerRadius = radius;
  // Clear glass, smoked so the toast's light text reads over a white window too.
  view.style = NSGlassEffectViewStyleClear;
  view.tintColor = [NSColor colorWithWhite:0 alpha:0.45];
  panel.contentView = view;

  panel.alphaValue = 0;
  [canvas addChildWindow:panel ordered:NSWindowBelow];
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
    context.duration = fade;
    panel.animator.alphaValue = 1;
  }];

  void **pointer = lua_newuserdata(state, sizeof(void *));
  *pointer = (__bridge_retained void *)panel;
  luaL_setmetatable(state, tag);
  return 1;
}

// glass:hide(fade): fade out with the canvas, held by the fade so a collection can't cut it short.
static int hide(lua_State *state) {
  void **pointer = luaL_checkudata(state, 1, tag);
  NSTimeInterval fade = luaL_optnumber(state, 2, 0);
  NSPanel *panel = (__bridge_transfer NSPanel *)*pointer;
  *pointer = NULL;
  void (^gone)(void) = ^{
    [panel.parentWindow removeChildWindow:panel];
    [panel orderOut:nil];
  };
  if (fade <= 0) {
    gone();
    return 0;
  }
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
    context.duration = fade;
    panel.animator.alphaValue = 0;
  } completionHandler:gone];
  return 0;
}

static int collect(lua_State *state) {
  void **pointer = luaL_checkudata(state, 1, tag);
  NSPanel *panel = (__bridge_transfer NSPanel *)*pointer;
  *pointer = NULL;
  [panel.parentWindow removeChildWindow:panel];
  [panel close];
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
  lua_setfield(state, -2, "__index");
  lua_pushcfunction(state, collect);
  lua_setfield(state, -2, "__gc");
  lua_pop(state, 1);
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  refTable = [skin registerLibrary:"toast" functions:functions metaFunctions:nil];
  return 1;
}
