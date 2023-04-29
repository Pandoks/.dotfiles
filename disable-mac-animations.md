# Disable MacOS Animations

These are one time commands to paste into terminal to disable the infuriating animations
that you need to wait for every time you need to do something. SPEED SHIT UP!

## Table of Contents

- [Commands](#commands)
  - [Resize Time](#quicker-resize-time)
  - [Window Animations](#disable-window-animations)
  - [Finder Animations](#disable-finder-animations)
  - [Rubber Band Scrolling](#disable-rubber-band-scrolling)
  - [Smooth Scrolling](#disable-smoother-scrolling)
  - [Quick Look](#quicker-look-window-time)
  - [Fullscreen Menu Bar](#disable-fullscreen-menu-bar-wait)
  - [Scrolling Column Views](#disable-scrolling-column-views)
  - [Dock](#quicker-dock-time)
  - [Showing and Hiding Animations](#disable-showing-and-hiding-animations)
  - [iMessage Notification Animations](#disable-messages-animations)
- [Resetting](#resetting)
  - [Command Example](#command)
  - [Reset Example](#reset)
- [Others](#others)
  - [Repeating Keystrokes](#enable-repeating-keystrokes-when-holding-key)

## Commands

- #### Quicker resize time

  ```
  defaults write -g NSWindowResizeTime .001
  ```

- #### Disable window animations

  ```
  defaults write -g NSAutomaticWindowAnimationsEnabled -bool false
  ```

- #### Disable finder animations

  ```
  defaults write com.apple.finder DisableAllAnimations -bool true
  ```

- #### Disable rubber band scrolling

  ```
  defaults write -g NSScrollViewRubberbanding -bool false
  ```

- #### Disable smooth scrolling

  ```
  defaults write -g NSScrollAnimationEnabled -bool false
  ```

- #### Quicker look window time

  ```
  defaults write -g QLPanelAnimationDuration -float 0
  ```

- #### Disable fullscreen menu bar wait

  ```
  defaults write -g NSToolbarFullScreenAnimationDuration -float 0
  ```

- #### Disable scrolling column views

  ```
  defaults write -g NSBrowserColumnAnimationSpeedMultiplier -float 0
  ```

- #### Quicker dock time

```
defaults write com.apple.dock autohide-time-modifier -float 0
defaults write com.apple.dock autohide-delay -float 0
```

- #### Disable showing and hiding animations

  ```
  defaults write com.apple.dock expose-animation-duration -float 0
  ```

- #### Disable messages animations

```
defaults write com.apple.Mail DisableSendAnimations -bool true
defaults write com.apple.Mail DisableReplyAnimations -bool true
```

## Resetting

In order to reset to the defaults, just replace the `write` to `delete` and exclude the suffixes:

- **Command:**

```
defaults write -g NSAutomaticWindowAnimationsEnabled -bool false
```

- **Reset:**

```
defaults delete -g NSAutomaticWindowAnimationsEnabled
```

## Others

These are other commands that you may want to disable that aren't directly related to MacOS
animations.

- #### Enable repeating keystrokes when holding key

  ```
  defaults write -g ApplePressAndHoldEnabled -bool false
  ```
