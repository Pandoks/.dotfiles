# Hammerspoon

## Implementation Notes

- Avoid polling as much as possible.
  - You should be using callbacks or event listeners instead even if it's more complex.
  - Resort to polling only when absolutely necessary and other implementation methods aren't
    possible.
- Use the fastest and lowest latency option possible.
  - You should experiment with different implementations and APIs to find the fastest one.
  - For example, the native yabai module is faster at certain things than certain native Hammerspoon
    modules, but it's the other way around for other things.
