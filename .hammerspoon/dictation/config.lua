---@alias DictationBackend
---| "parakeet-mlx" # Parakeet only; fastest (default)
---| "mlx-audio"    # broad: Parakeet, Granite, Qwen3-ASR, Voxtral, ...
---| "mlx-whisper"  # Whisper family

---@alias DictationTrigger
---| "hotkey"       # a key combo (see `hotkey`)
---| "modifierTap"  # tap a modifier by itself, like Raycast (see `modifierTap`)
---| "dictationKey" # the macOS mic key; unreliable, macOS always intercepts it

---@alias DictationInsertMode
---| "auto"      # insert like "direct"; if there is no focused field or insertion fails, copy the text to the clipboard instead (with a brief alert)
---| "direct"    # insert into the focused field via accessibility, clipboard untouched. Fields that ignore accessibility writes (Electron/Chromium apps) get the app's own Paste instead: text goes on the clipboard, ⌘V, previous clipboard restored 0.25 s later. Failure is reported, nothing is copied.
---| "clipboard" # only copy the text to the clipboard; nothing is inserted

---@alias DictationModifierFlag "cmd"|"alt"|"shift"|"ctrl"|"fn"

---@class DictationSttConfig
---@field backend DictationBackend Which runtime loads the model. Must match the model; see README.md.
---@field model string Hugging Face repo id, e.g. "mlx-community/parakeet-tdt-0.6b-v3". Downloaded on first use.

---@class DictationCleanupConfig
---@field enabled boolean Run the LLM cleanup pass. false = raw transcription only.
---@field model string Hugging Face repo of an MLX model (the base when `adapter` is set), e.g. "mlx-community/Qwen3.5-2B-MLX-4bit".
---@field adapter? string Hugging Face repo of a LoRA adapter for `model`. A cleanup-trained adapter ships its own prompt (system_v2.txt), which is then used verbatim: `style` and `apps` do not apply, vocabulary is applied deterministically instead. nil = plain instruct model with our prompt.
---@field max_tokens integer Max tokens the cleanup may generate (cap for long dictations).

---@class DictationAppConfig
---@field style? string Extra instructions appended to the global `style` when this app is focused.
---@field vocabulary? string[] Extra glossary words merged into the global `vocabulary` for this app.

---@class DictationHotkeyConfig
---@field mods string[] Modifiers, e.g. { "alt" } or { "cmd", "shift" }. {} for none.
---@field key string Key name as hs.hotkey expects, e.g. "space", "d", "f5".

---@class DictationModifierTapConfig
---@field keycode integer Physical key: Right Cmd 54, Left Cmd 55, Right Opt 61, Left Opt 58, Right Shift 60, Right Ctrl 62.
---@field flag DictationModifierFlag The modifier flag that key sets ("cmd" for Command, "alt" for Option, ...).
---@field taps 1|2 Taps required: 1 = single tap, 2 = double tap (safer against accidents).
---@field window number Max seconds for a tap and between taps. Longer holds are ignored.

---@class DictationKeyEventConfig
---@field subtype integer NSEvent subtype of the mic key's system event (7 on this Mac).
---@field data1 integer NSEvent data1 identifying the key (1 on this Mac).
---@field swallow boolean Try to consume the event so macOS ignores it (macOS still acts on it; see README).

---@class DictationConfig
---@field trigger DictationTrigger How dictation is started/stopped.
---@field hotkey DictationHotkeyConfig Used when trigger = "hotkey".
---@field modifierTap DictationModifierTapConfig Used when trigger = "modifierTap".
---@field dictationKey DictationKeyEventConfig Used when trigger = "dictationKey".
---@field stt DictationSttConfig Speech-to-text model.
---@field cleanup DictationCleanupConfig LLM cleanup pass.
---@field style string Global instructions: the cleanup model's system prompt. This is what you tune.
---@field vocabulary string[] Correct spellings of names, tools, jargon. Misheard tokens close to one of these are rewritten to it (real English words are never touched), before and after cleanup, and the word is protected from being dropped. This is the list to maintain.
---@field dictionary table<string, string[]> Word -> spoken variants. Applied deterministically to the transcript and given to the models. Edit dictionary.lua.
---@field apps table<string, DictationAppConfig> Per-app overrides keyed by bundle id (`osascript -e 'id of app "Slack"'`).
---@field insert DictationInsertMode How the result is delivered: into the focused field, to the clipboard, or field-with-clipboard-fallback.
---@field includeSelection boolean Send the current text selection as context. Off by default (privacy; can cause echoing). Only a real selection, capped, is ever sent.
---@field minLevel number 0..1 peak loudness required, else the take is treated as silence. Raise to demand a closer, louder voice.
---@field minDuration number Minimum recording length in seconds; shorter takes are ignored.
---@field noiseReduction boolean High-pass, denoise, and silence-trim the audio so only clear, close speech reaches the model.
---@field overlayHeight number Pill height in points. ~30 matches Raycast; larger looks bulky.
---@field eqBands integer Number of frequency bands in the equalizer (mirrored around the center).

---@type DictationConfig
local config = {
  trigger = "hotkey",

  -- Option+Space: press to start, again to stop. Escape aborts.
  hotkey = { mods = { "alt" }, key = "space" },

  -- Raycast-style tap of a modifier. Used only when trigger = "modifierTap".
  modifierTap = { keycode = 54, flag = "cmd", taps = 2, window = 0.4 },

  -- macOS mic key event. Used only when trigger = "dictationKey" (unreliable).
  dictationKey = { subtype = 7, data1 = 1, swallow = true },

  stt = {
    backend = "parakeet-mlx",
    model = "mlx-community/parakeet-tdt-0.6b-v3",
  },

  -- 1.5B halves cleanup latency (~0.8s vs ~1.4s) at the same quality as 3B on
  -- dictation; 0.5B is too weak (misses corrections and punctuation).
  -- simplewords v3: a LoRA trained only to clean dictation (fixes fillers and
  -- self-corrections like "Thursday no Friday", never answers or paraphrases),
  -- on Qwen3.5-2B. ~0.8s per utterance. Base ~1.3 GB + adapter 67 MB, fetched
  -- on first use. Set adapter = nil to use a generic instruct model with the
  -- `style`/`apps` prompt instead.
  cleanup = {
    enabled = true,
    model = "mlx-community/Qwen3.5-2B-MLX-4bit",
    adapter = "ReFyneLabs/simplewords-dictation-cleanup-v3-adapter",
    max_tokens = 400,
  },

  -- Global instructions (the "fine tuning").
  style = table.concat({
    "You clean up dictated speech into text the user meant to type.",
    "Fix transcription errors, add sensible punctuation and capitalization,",
    "remove filler words (um, uh, like), but keep the user's wording and voice.",
    "Do not answer questions or add commentary. Output ONLY the cleaned text.",
  }, " "),

  -- Brand names, tools, jargon: see dictionary.lua (word -> how it's misheard).
  dictionary = require("dictation.dictionary"),
  -- Plain extra glossary words (no variants). Usually leave empty and use the
  -- dictionary instead.
  vocabulary = {
    "yabai", "Raycast", "Hammerspoon", "Ghostty", "mise", "Neovim", "rtorrent",
    "macOS", "GitHub", "Slack",
  },

  apps = {
    ["com.tinyspeck.slackmacgap"] = {
      style = "This is a Slack message. Keep it concise and conversational.",
    },
    ["com.microsoft.VSCode"] = {
      style = "This is code, a code comment, or a commit message. Be terse and technical.",
    },
    ["com.apple.Terminal"] = {
      style = "This is a shell command or terminal input. Prefer exact command syntax.",
    },
    ["com.mitchellh.ghostty"] = {
      style = "This is a shell command or terminal input. Prefer exact command syntax.",
    },
  },

  insert = "auto",
  includeSelection = false,

  minLevel = 0.25,
  minDuration = 0.35,
  noiseReduction = true,

  overlayHeight = 44,
  eqBands = 15,
}

return config
