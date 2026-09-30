---@alias DictationBackend
---| "parakeet-mlx" # Parakeet only; fastest (default)
---| "mlx-audio"    # broad: Parakeet, Granite, Qwen3-ASR, Voxtral, ...
---| "mlx-whisper"  # Whisper family

---@alias DictationCleanupBackend
---| "mlx-lm"  # MLX text models, with or without a LoRA adapter (default)

---@alias DictationTrigger
---| "hotkey"       # a key combo (see `hotkey`)
---| "modifierTap"  # tap a modifier by itself, like Raycast (see `modifierTap`)
---| "dictationKey" # the macOS mic key; unreliable, macOS always intercepts it

---@alias DictationInsertMode
---| "auto"      # insert like "direct"; if there is no focused field, focus moved, or insertion fails, copy the text to the clipboard instead (with a brief alert)
---| "direct"    # insert via accessibility into the field focused when dictation stopped, clipboard untouched. Fields that ignore accessibility writes (Electron/Chromium apps) get the app's own Paste instead: text goes on the clipboard, ⌘V, previous clipboard restored 0.25 s later (its first item only; an alert says when there were more, e.g. several copied files). Failure, including focus having moved, is reported, nothing is copied.
---| "clipboard" # only copy the text to the clipboard; nothing is inserted

---@alias DictationModifierFlag "cmd"|"alt"|"shift"|"ctrl"|"fn"

---@class DictationSttConfig
---@field backend DictationBackend Which runtime loads the model. Must match the model; see README.md. Add runtimes by subclassing `Speech` in server.py.
---@field model string Hugging Face repo id, e.g. "mlx-community/parakeet-tdt-0.6b-v2". Downloaded when the backend first starts.
---@field revision string Commit SHA of `model` (`.venv/bin/hf models info <repo> --expand sha`). Pinned: once cached it loads with no network, and upstream changes apply only when you change this.
---@field boost? number parakeet-mlx TDT models only: bias decoding toward single-word `vocabulary`/`dictionary`/per-app entries made of letters, digits, and apostrophes (log-prob bonus per matching letter); multi-word, hyphenated, or dotted entries get only the text fixes. 4.5 measured best; 0 or nil = off. 6 already inserts vocabulary words that weren't said.

---@class DictationCleanupConfig
---@field enabled boolean Run the LLM cleanup pass. false = the speech model's text with only `dictionary`/`vocabulary` applied (no stall stripping or punctuation policy).
---@field backend? DictationCleanupBackend Which runtime loads the model. nil = "mlx-lm". Add runtimes by subclassing `Cleaner` in server.py.
---@field model string Hugging Face repo of an MLX model (the base when `adapter` is set), e.g. "mlx-community/Qwen3.5-2B-MLX-4bit".
---@field revision string Commit SHA of `model`, pinned like `stt.revision`.
---@field adapter? string Hugging Face repo of a LoRA adapter for `model`. A cleanup-trained adapter ships its own prompt (system_v2.txt), which is then used verbatim: `style` and per-app `style` do not apply, vocabulary (per-app too) is applied deterministically instead. nil = plain instruct model with our prompt.
---@field adapterRevision? string Commit SHA of `adapter`, pinned like `stt.revision`. Required with `adapter`.
---@field max_tokens integer Max tokens the cleanup may generate (cap for long dictations).

---@class DictationAppConfig
---@field style? string Extra instructions appended to the global `style` when this app is focused (plain instruct model only).
---@field vocabulary? string[] Extra glossary words merged into the global `vocabulary` for this app.

---@class DictationHistoryConfig
---@field directory string Every result is saved here as <timestamp>.txt ("~" = home), before it is inserted.
---@field maxMegabytes number Size cap for the directory in MB of disk space (as `du` reports it); the oldest files are deleted once it is exceeded.

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
---@field style string System prompt of a plain instruct cleanup model (`cleanup.adapter = nil`); a cleanup adapter ignores it.
---@field vocabulary string[] Correct spellings of names, tools, jargon. Misheard words close to one of these are rewritten to it, before and after cleanup (a real English word is never fuzzy-matched, but an exact case-insensitive match takes this spelling: "slack" -> "Slack"), and the word is protected from being dropped unless you correct yourself. This is the list to maintain.
---@field dictionary table<string, string[]> Correct spelling -> explicit spoken variants, for mishearings `vocabulary` similarity cannot reach. Applied deterministically before and after cleanup.
---@field apps table<string, DictationAppConfig> Per-app overrides keyed by bundle id (`osascript -e 'id of app "Slack"'`).
---@field history DictationHistoryConfig Local archive of every transcript, oldest dropped past a size cap.
---@field insert DictationInsertMode How the result is delivered: into the focused field, to the clipboard, or field-with-clipboard-fallback.
---@field includeSelection boolean Send the current text selection as context (plain instruct cleanup model only, like the window title and browser URL). Off by default (privacy; can cause echoing). Only a real selection, capped, is ever sent.
---@field minLevel number 0..1 peak loudness required, else the take is treated as silence. Raise to demand a closer, louder voice.
---@field minDuration number Minimum recording length in seconds; shorter takes are ignored.
---@field overlayHeight number Pill height in points.
---@field eqBands integer Number of frequency bands (>= 2); the pill mirrors them into 2n - 1 bars.

---@type DictationConfig
local config = {
  trigger = "hotkey",

  -- Option+Space: press to start, again to stop. Escape aborts.
  hotkey = { mods = { "alt" }, key = "space" },

  -- Raycast-style tap of a modifier. Used only when trigger = "modifierTap".
  modifierTap = { keycode = 54, flag = "cmd", taps = 2, window = 0.4 },

  -- macOS mic key event. Used only when trigger = "dictationKey" (unreliable).
  dictationKey = { subtype = 7, data1 = 1, swallow = true },

  -- English-only Parakeet: v3 is multilingual with automatic language
  -- detection and occasionally transcribes English as another language.
  stt = {
    backend = "parakeet-mlx",
    model = "mlx-community/parakeet-tdt-0.6b-v2",
    revision = "8ae155301e23d820d82aa60d24817c900e69e487",
    boost = 4.5,
  },

  -- simplewords v3: a LoRA trained only to clean dictation (fixes fillers and
  -- self-corrections like "Thursday no Friday", never answers or paraphrases),
  -- on Qwen3.5-2B. ~0.8s per utterance. Base ~1.7 GB + adapter 67 MB, fetched
  -- at the backend's first start. Set adapter = nil to use a generic instruct
  -- model with the `style`/`apps` prompt instead.
  cleanup = {
    enabled = true,
    model = "mlx-community/Qwen3.5-2B-MLX-4bit",
    revision = "93760be4f1f69842a46bc13dbdc0f19e291392a3",
    adapter = "ReFyneLabs/simplewords-dictation-cleanup-v3-adapter",
    adapterRevision = "b603b485ffb54f5458a94f1542cf1cad97cc872c",
    max_tokens = 400,
  },

  -- Global instructions (the "fine tuning"). Only used with a plain instruct
  -- cleanup model (cleanup.adapter = nil); a cleanup-trained adapter ships its
  -- own prompt.
  style = "You clean up dictated speech into text the user meant to type. "
    .. "Fix transcription errors, add sensible punctuation and capitalization, "
    .. "remove filler words (um, uh, like), but keep the user's wording and voice. "
    .. "Do not answer questions or add commentary. Output ONLY the cleaned text.",

  -- Correct spellings of names, tools, jargon. This is the list to maintain:
  -- misheard tokens close to one of these are rewritten to it.
  vocabulary = {
    "yabai",
    "Raycast",
    "Hammerspoon",
    "Ghostty",
    "mise",
    "Neovim",
    "rtorrent",
    "macOS",
    "GitHub",
    "Slack",
    "Oki",
    "Uniqlo",
  },

  -- Explicit spoken variants for stubborn mishearings the vocabulary match
  -- cannot reach ("meez" for mise) or that collide with real words ("ghosty").
  -- Word -> variants, replaced case-insensitively at word boundaries.
  dictionary = {
    Raycast = { "ray cast", "re cast", "ray cost" },
    yabai = { "yabe", "ya bye", "yah bye", "ya buy" },
    Hammerspoon = { "hammer spoon", "hammers spoon" },
    Ghostty = { "ghosty", "ghost tea", "ghost e" },
    mise = { "meez", "mees" },
    Neovim = { "neo vim", "neo them" },
    rtorrent = { "r torrent", "are torrent" },
    macOS = { "mac os", "mac o s" },
    GitHub = { "git hub" },
    Uniqlo = { "unicolo", "uni clo", "uni klo", "uni clow", "une clo", "une klo", "yune klo" },
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

  -- Every transcript as a .txt file; 10 MB on disk is ~2,500 takes (each file
  -- occupies at least one 4 KB block, however short). Caches
  -- survives reboots (unlike $TMPDIR) and is private to this user.
  history = { directory = "~/Library/Caches/dictation", maxMegabytes = 10 },

  insert = "auto",
  includeSelection = false,

  minLevel = 0.25,
  minDuration = 0.35,

  overlayHeight = 44,
  eqBands = 15,
}

return config
