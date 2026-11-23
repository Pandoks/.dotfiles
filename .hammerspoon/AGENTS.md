# Hammerspoon

## Implementation Notes

Most of these rules apply to Lua, but it also applies to anything in `.hammerspoon`. For example,
native modules etc.

- Avoid polling as much as possible.
  - You should be using callbacks or event listeners instead even if it's more complex.
  - Resort to polling only when absolutely necessary and other implementation methods aren't
    possible.
- Use the fastest and lowest latency option possible.
  - You should experiment with different implementations and APIs to find the fastest one.
  - For example, the native `window_manager` module is faster at certain things than certain native
    Hammerspoon modules, but it's the other way around for other things.
- Name things with full, descriptive words (`window_manager`, not `wm`), never abbreviations; follow
  the [Lua Style Guide](https://github.com/sumneko/lua-language-server/wiki/EmmyLua-Style-Guide).
- Inline functions used only once, unless the parent function would be hard to understand.
- Resolve all LSP issues. For annotations, use the
  [EmmyLua](https://github.com/sumneko/lua-language-server/wiki/Annotations) style guide.
  - Don't overly annotate. If the variable or function is typed implicitly, you shouldn't annotate.
  - Avoid `any` types as much as possible unless you have a good reason to use them.
  - If the annotation is only used once, it should be inlined. You don't need that extrapolation.
- When implementing new capabilities, build the primitives first into a module so that other
  features can reuse them.
  - You should only create modules for large new difficult features.
  - You don't need to create a module or function for every small feature as that clutters
    everything.
  - For miscellaneous utility functions, put that in a module named `utils`.
- Comment in two places only: above a function when the LSP needs it, and, in large functions ONLY,
  as a one-line label at the top of each logical block.
- We don't need retry logic or fallbacks. Just make it fail fast, log it, and notify the user with a
  pop up message.
