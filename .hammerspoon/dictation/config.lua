---@alias DictationBackend
---| "parakeet-mlx" # Parakeet only; fastest (default)
---| "mlx-audio"    # broad: Parakeet, Granite, Qwen3-ASR, Voxtral, ...
---| "mlx-whisper"  # Whisper family

---@alias DictationInsertMode
---| "direct"    # into the field focused at stop by accessibility, or by the app's ⌘V where writes are ignored (Electron, Gecko, terminals, Messages, Mail), the clipboard restored 1 s later. Failures are reported; the text is in `history`.
---| "clipboard" # only copy the text to the clipboard; nothing is inserted

---@class DictationSttConfig
---@field backend DictationBackend Which runtime loads the model; must match it (see README.md).
---@field model string Hugging Face repo id, e.g. "mlx-community/parakeet-tdt-0.6b-v2". Downloaded when the backend first starts.
---@field revision string Commit SHA of `model` (`.venv/bin/hf models info <repo> --expand sha`). Pinned: once cached it loads with no network, and upstream changes apply only when you change this.
---@field boost? number Parakeet TDT models only: log-prob bonus per letter toward `vocabulary`, `dictionary`, and per-app words of only letters, digits, and apostrophes; each take is also decoded without it, and a boosted word is kept only where it spells one. 0 or nil = off.

---@class DictationCleanupConfig
---@field enabled boolean Run the LLM cleanup. false = the speech model's text with only `vocabulary`/`dictionary` spellings and spoken numbers as digits ("three things" -> "3 things").
---@field model string Hugging Face repo of an MLX model (the base when `adapter` is set), e.g. "mlx-community/Qwen3.5-2B-MLX-4bit".
---@field revision string Commit SHA of `model`, pinned like `stt.revision`.
---@field adapter? string Hugging Face repo of a LoRA adapter for `model`; its own prompt (system_v2.txt) replaces `style`, per-app `style`, and the vocabulary prompt. nil = plain instruct model.
---@field adapterRevision? string Commit SHA of `adapter`, pinned like `stt.revision`. Required with `adapter`.
---@field maxTokens integer Tokens the cleanup may generate, raised to twice the dictation's so an echo is never cut.

---@class DictationAppConfig
---@field style? string Appended to the global `style` when this app is in front (plain instruct model only).
---@field vocabulary? string[] Extra `vocabulary` words for this app.

---@class DictationHistoryConfig
---@field directory string Every result is saved here as <timestamp>.txt ("~" = home) before it is inserted; a take the backend never transcribed keeps its recording here as <timestamp>.wav.
---@field maxMegabytes number Size cap of the transcripts in MB of disk (as `du` reports it); the oldest go first.

---@class DictationHotkeyConfig
---@field mods string[] Modifiers, e.g. { "alt" } or { "cmd", "shift" }. {} for none.
---@field key string Key name as hs.hotkey expects, e.g. "space", "d", "f5".

---@class DictationConfig
---@field hotkey DictationHotkeyConfig Starts and stops a take; Escape cancels it.
---@field stt DictationSttConfig Speech-to-text model.
---@field cleanup DictationCleanupConfig LLM cleanup pass.
---@field style string Opens the plain instruct cleanup model's system prompt (`cleanup.adapter = nil`); an adapter ignores it.
---@field vocabulary string[] Correct spellings of names and jargon, applied before and after cleanup: said in any case, as one word without its separators or accents ("ytdlp" -> "yt-dlp"), or as a 4+ letter non-word close to one. Real words are never fuzzy-matched: list those in `dictionary`.
---@field dictionary table<string, string[]> Correct spelling -> spoken variants, replaced in any case before and after cleanup: for mishearings `vocabulary` cannot reach, like real words.
---@field apps table<string, DictationAppConfig> Per-app `style` and `vocabulary`, keyed by the bundle id in front at stop (`osascript -e 'id of app "Slack"'`).
---@field history DictationHistoryConfig Local archive of every transcript, oldest dropped past a size cap.
---@field insert DictationInsertMode How the result is delivered: into the focused field, or to the clipboard.
---@field minLevel number 0..1 peak loudness required, else the take is treated as silence. Raise to demand a closer, louder voice.
---@field minDuration number Minimum recording length in seconds; shorter takes are ignored.
---@field overlayHeight number Pill height in points.
---@field eqBands integer Number of frequency bands (>= 2); the pill mirrors them into 2n - 1 bars.

---@type DictationConfig
local config = {
  -- Option+Space: press to start, again to stop. Escape aborts.
  hotkey = { mods = { "alt" }, key = "space" },

  -- English-only: v3 sometimes transcribes English as another language.
  stt = {
    backend = "parakeet-mlx",
    model = "mlx-community/parakeet-tdt-0.6b-v2",
    revision = "8ae155301e23d820d82aa60d24817c900e69e487",
    boost = 4.5,
  },

  -- simplewords v3: a Qwen3.5-2B LoRA trained only to clean dictation ("Thursday no Friday").
  cleanup = {
    enabled = true,
    model = "mlx-community/Qwen3.5-2B-MLX-4bit",
    revision = "93760be4f1f69842a46bc13dbdc0f19e291392a3",
    adapter = "ReFyneLabs/simplewords-dictation-cleanup-v3-adapter",
    adapterRevision = "b603b485ffb54f5458a94f1542cf1cad97cc872c",
    maxTokens = 400,
  },

  style = "You clean up dictated speech into text the user meant to type. "
    .. "Fix transcription errors, add sensible punctuation and capitalization, "
    .. "remove filler words (um, uh, like), but keep the user's wording and voice. "
    .. "Do not answer questions or add commentary. Output ONLY the cleaned text.",

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

  -- Real-word mishearings ("ghosty") go here: `vocabulary` never fuzzy-matches a real word.
  dictionary = {
    Raycast = { "ray cast", "re cast", "ray cost" },
    yabai = { "yabe", "ya bye", "yah bye" },
    Hammerspoon = { "hammer spoon", "hammers spoon" },
    Ghostty = { "ghosty", "ghost tea", "ghost e" },
    mise = { "meez", "mees" },
    Neovim = { "neo vim", "neo them" },
    rtorrent = { "r torrent" },
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

  -- 10 MB is ~2,500 takes (a 4 KB block each); Application Support, as macOS may purge Caches.
  history = { directory = "~/Library/Application Support/dictation", maxMegabytes = 10 },

  insert = "direct",

  minLevel = 0.25,
  minDuration = 0.35,

  overlayHeight = 44,
  eqBands = 15,
}

return config
