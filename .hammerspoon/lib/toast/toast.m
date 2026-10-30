#import <Cocoa/Cocoa.h>
#import <LuaSkin/LuaSkin.h>
#include <dlfcn.h>

static const char *glassMetatableName = "toast.glass";

// Full glass without key focus; otherwise a subdued blur.
@interface ToastPanel : NSPanel
@end

@implementation ToastPanel
- (BOOL)_hasActiveAppearanceIgnoringKeyFocus {
  return YES;
}
@end

// Tinted so its text reads over white and black windows.
static void applyAppearance(NSPanel *panel, BOOL darkAppearance) {
  panel.appearance = [NSAppearance appearanceNamed:darkAppearance ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
  NSColor *tint = darkAppearance ? [NSColor colorWithWhite:0 alpha:0.6] : [NSColor colorWithWhite:1 alpha:0.7];
  ((NSGlassEffectView *)panel.contentView).tintColor = tint;
}

static int glass(lua_State *state) {
  LuaSkin *skin = [LuaSkin sharedWithState:state];
  [skin checkArgs:LS_TUSERDATA, "hs.canvas", LS_TNUMBER, LS_TNUMBER, LS_TBOOLEAN, LS_TBREAK];
  NSWindow *canvasWindow = ((NSView *)[skin toNSObjectAtIndex:1]).window;
  luaL_argcheck(state, canvasWindow != nil, 1, "canvas has no window");
  CGFloat cornerRadius = lua_tonumber(state, 2);
  NSTimeInterval fadeSeconds = lua_tonumber(state, 3);
  void **panelSlot = lua_newuserdata(state, sizeof(void *));
  *panelSlot = NULL;
  luaL_setmetatable(state, glassMetatableName);
  NSPanel *panel = [[ToastPanel alloc] initWithContentRect:canvasWindow.frame
                                                  styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
  panel.opaque = NO;
  panel.backgroundColor = NSColor.clearColor;
  panel.ignoresMouseEvents = YES;
  panel.animationBehavior = NSWindowAnimationBehaviorNone;
  panel.collectionBehavior = canvasWindow.collectionBehavior;

  NSGlassEffectView *glassView = [[NSGlassEffectView alloc] initWithFrame:panel.contentView.bounds];
  glassView.cornerRadius = cornerRadius;
  glassView.style = NSGlassEffectViewStyleClear;
  panel.contentView = glassView;
  applyAppearance(panel, lua_toboolean(state, 4));

  panel.alphaValue = 0;
  [canvasWindow addChildWindow:panel ordered:NSWindowBelow];
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
    context.duration = fadeSeconds;
    panel.animator.alphaValue = 1;
  }];

  *panelSlot = (__bridge_retained void *)panel;
  return 1;
}

// The fade holds the panel, so a collection can't cut it short.
static int hide(lua_State *state) {
  void **panelSlot = luaL_checkudata(state, 1, glassMetatableName);
  NSTimeInterval fadeSeconds = luaL_optnumber(state, 2, 0);
  NSPanel *panel = (__bridge_transfer NSPanel *)*panelSlot;
  *panelSlot = NULL;
  if (fadeSeconds <= 0) {
    [panel orderOut:nil];
    return 0;
  }
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
    context.duration = fadeSeconds;
    panel.animator.alphaValue = 0;
  } completionHandler:^{
    [panel orderOut:nil];
  }];
  return 0;
}

static int paint(lua_State *state) {
  void **panelSlot = luaL_checkudata(state, 1, glassMetatableName);
  luaL_checktype(state, 2, LUA_TBOOLEAN);
  applyAppearance((__bridge NSPanel *)*panelSlot, lua_toboolean(state, 2));
  return 0;
}

static const luaL_Reg functions[] = {
  { "glass", glass },
  { NULL, NULL },
};

int luaopen_toast(lua_State *state) {
  // A reload dlcloses this while a fade's completion block may still run.
  static void *ownHandle;
  if (!ownHandle) {
    Dl_info imageInfo;
    if (!dladdr(&glassMetatableName, &imageInfo) || !(ownHandle = dlopen(imageInfo.dli_fname, RTLD_NOW | RTLD_LOCAL))) {
      return luaL_error(state, "could not retain toast library");
    }
  }
  if (!NSClassFromString(@"NSGlassEffectView")) return luaL_error(state, "Liquid Glass needs macOS 26");
  if (![NSPanel instancesRespondToSelector:@selector(_hasActiveAppearanceIgnoringKeyFocus)]) {
    return luaL_error(state, "Liquid Glass: AppKit has no _hasActiveAppearanceIgnoringKeyFocus");
  }
  luaL_newmetatable(state, glassMetatableName);
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
