---@class SttModelInfo
---@field model string Hugging Face repo id
---@field backend DictationBackend
---@field size string approx download
---@field license string
---@field wer number|nil live leaderboard mean WER
---@field note string

---@type SttModelInfo[]
return {
  {
    model = "mlx-community/parakeet-tdt-0.6b-v3",
    backend = "parakeet-mlx",
    size = "~1.2 GB",
    license = "CC-BY-4.0",
    wer = 4.86,
    note = "Fastest. Best for dictation. 25 EU languages. Native streaming. Default.",
  },
  {
    model = "mlx-community/Qwen3-ASR-1.7B-4bit",
    backend = "mlx-audio",
    size = "~2 GB",
    license = "Apache-2.0",
    wer = 4.31,
    note = "Most accurate open model. 50+ languages. Slower than Parakeet.",
  },
  {
    model = "ibm-granite/granite-speech-4.1-2b",
    backend = "mlx-audio",
    size = "~4 GB",
    license = "Apache-2.0",
    wer = 4.62,
    note = "Strong EN/EU accuracy, keyword biasing. Heavier.",
  },
  {
    model = "mlx-community/whisper-large-v3-turbo",
    backend = "mlx-whisper",
    size = "~1.6 GB",
    license = "MIT",
    wer = 6.36,
    note = "99 languages, most battle-tested. Higher English WER. Verified working.",
  },
  {
    model = "mistralai/Voxtral-Mini-4B-Realtime-2602",
    backend = "mlx-audio",
    size = "~5 GB",
    license = "Apache-2.0",
    wer = 6.46,
    note = "Realtime/streaming oriented, multilingual.",
  },
}
