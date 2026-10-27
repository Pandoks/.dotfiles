---@alias DictationWords table<integer|string, string|string[]> "Name", or Name = { "misheard as" }

---@class DictationConfig
---@field hotkey? { mods: string[], key: string } Starts and stops a take; Escape cancels it.
---@field words? DictationWords Names and jargon, spelled as written here.
---@field apps? table<string, { words?: DictationWords, style?: string }> By bundle id, plus global.
---@field style? string|false Instructions for a plain cleanup model; fails with an `adapter`.
---@field speech? DictationSpeech
---@field cleanup? DictationCleanup|false false = the heard text, spelled, stalls out, digits.
---@field history? DictationHistory
---@field insert? "direct"|"clipboard" Type into the field focused at stop, or only copy.
---@field minLevel? number Peak loudness (0..1) below which a take is silence.
---@field minDuration? number Seconds below which a take is an accidental tap.

---@class DictationSpeech
---@field backend "parakeet-mlx"|"mlx-audio"|"mlx-whisper" The runtime `model` needs (README.md).
---@field model string Hugging Face repo id.
---@field revision string Its commit SHA: `.venv/bin/hf models info <repo> --expand sha`.
---@field boost? number Parakeet TDT only: pull toward `words`; 0 = off.

---@class DictationCleanup
---@field backend "mlx-lm" The runtime `model` needs.
---@field model string Hugging Face repo of an MLX model; the base when `adapter` is set.
---@field revision string Its commit SHA.
---@field adapter? string Cleanup LoRA, prompt in system_v2.txt; nil = a plain model, with `style`.
---@field adapterRevision? string Its commit SHA.

---@class DictationHistory
---@field directory string Every transcript goes here first; unanswered takes keep their wav.
---@field maxMegabytes number Transcripts cap, oldest first; kept wavs are never counted or deleted.

-- A key in config.lua replaces its default whole, not field by field.
---@type DictationConfig
return {
  hotkey = { mods = { "alt" }, key = "space" },
  words = {},
  apps = {},
  style = false,

  -- English-only: v3 sometimes transcribes English as another language.
  speech = {
    backend = "parakeet-mlx",
    model = "mlx-community/parakeet-tdt-0.6b-v2",
    revision = "8ae155301e23d820d82aa60d24817c900e69e487",
    boost = 4.5,
  },

  cleanup = {
    backend = "mlx-lm",
    model = "mlx-community/Qwen3.5-2B-MLX-4bit",
    revision = "93760be4f1f69842a46bc13dbdc0f19e291392a3",
    adapter = "ReFyneLabs/simplewords-dictation-cleanup-v3-adapter",
    adapterRevision = "b603b485ffb54f5458a94f1542cf1cad97cc872c",
  },

  -- 10 MB is ~2,500 takes; Application Support, as macOS may purge Caches.
  history = { directory = "~/Library/Application Support/dictation", maxMegabytes = 10 },
  insert = "direct",
  minLevel = 0.25,
  minDuration = 0.35,
}
