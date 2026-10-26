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

// glass(canvas, radius, fade)
static int glass(lua_State *state) {
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  [skin checkArgs:LS_TUSERDATA, "hs.canvas", LS_TNUMBER, LS_TNUMBER, LS_TBREAK];
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
  // Smoked so light text reads over white.
  view.style = NSGlassEffectViewStyleClear;
  view.tintColor = [NSColor colorWithWhite:0 alpha:0.45];
  panel.contentView = view;

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
  lua_pushcfunction(state, hide);
  lua_setfield(state, -2, "__gc");
  lua_pop(state, 1);
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  [skin registerLibrary:"toast" functions:functions metaFunctions:nil];
  return 1;
}
