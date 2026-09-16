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
- Ensure that the code has minimal yet human-readable variable names.
  - Make sure to abide by the [Lua Style Guide](https://github.com/sumneko/lua-language-server/wiki/EmmyLua-Style-Guide).
  - If your variable name can be a single word, it should be a single word. As minimal as possible.
  - Variable names should not be abbreviated or overly verbose.
- Your code should be as minimal as possible without sacrificing readability, maintainability,
  performance, or strucutre understanding.
  - If functions are only used once, they should be inlined unless the parent function using it is
    hard to understand. You are extrapolating it for readability and maintainability.
- There should be no LSP issues.
  - Resolve all LSP issues.
  - For annotations, use the [EmmyLua](https://github.com/sumneko/lua-language-server/wiki/Annotations)
    style guide.
  - Don't overly annotate. If the variable or function is typed implicitly, you shouldn't annotate.
  - Avoid `any` types as much as possible unless you have a good reason to use them.
  - If the annotation is only used once, it should be inlined. You don't need that extrapolation.
- When implementing new capabilities, build the primitives first into a module so that other
  features can reuse them.
  - Keep this minimal and simple.
  - You should only create modules for large new difficult features.
  - You don't need to create a module or function for every small feature as that clutters
    everything.
  - For miscallaneous utility functions, put that in a module named `utils`.
