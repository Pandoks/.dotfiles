# Local dictation for Hammerspoon

A free, fully local Raycast-style dictation pill. Press Option+Space to record, again to stop
(Escape cancels): a local speech model transcribes, a local LLM cleans up fillers and
self-corrections, your vocabulary fixes names, and the text goes into the focused field.
`~/.hammerspoon/init.lua` loads it only on Apple Silicon with macOS 14+ (MLX).

## Setup

1. `~/.hammerspoon/dictation/setup.sh` (needs `uv` and `ffmpeg` from `mise install`).
2. Grant **Hammerspoon** Microphone and Accessibility in **System Settings > Privacy & Security**.
   Browsers ask once for Automation (URL context, plain instruct cleanup models only).
3. Reload Hammerspoon. The first start downloads the models pinned in `config.lua` into
   `~/.cache/huggingface`; later starts load them offline.

Every setting lives in `config.lua`, typed, with hover docs from lua-language-server.
If Raycast also uses Option+Space, Hammerspoon wins; rebind one. The macOS dictation (mic)
key cannot be used: macOS 26 always handles it itself.

## Speech models

Set `stt.backend`, `stt.model`, and `stt.revision` (`.venv/bin/hf models info <repo> --expand sha`).
WER is the Open ASR Leaderboard English average of the upstream model.

| Model | Backend | Download | License | WER | Notes |
|---|---|---|---|---|---|
| `mlx-community/parakeet-tdt-0.6b-v2` | `parakeet-mlx` | 2.5 GB | CC-BY-4.0 | 4.70 | English only, fastest. Default. |
| `mlx-community/parakeet-tdt-0.6b-v3` | `parakeet-mlx` | 2.5 GB | CC-BY-4.0 | 4.86 | 25 EU languages; short English takes can come out in another. |
| `mlx-community/Qwen3-ASR-1.7B-4bit` | `mlx-audio` | 1.6 GB | Apache-2.0 | 4.31 | 50+ languages, slower. |
| `ibm-granite/granite-speech-4.1-2b` | `mlx-audio` | 4.9 GB | Apache-2.0 | 4.62 | Keyword biasing not wired up. |
| `mlx-community/whisper-large-v3-turbo` | `mlx-whisper` | 1.6 GB | MIT | 6.36 | 99 languages; vocabulary passed as a prompt. |
| `mistralai/Voxtral-Mini-4B-Realtime-2602` | `mlx-audio` | 18 GB | Apache-2.0 | 6.46 | Two weight copies. |

The default cleanup model is the simplewords v3 LoRA on Qwen3.5-2B (1.7 GB + 67 MB). It
ships its own prompt, so `style`, per-app `style`, and the window/URL/selection context
apply only to a plain instruct model (`cleanup.adapter = nil`). Pin only repos you trust:
mlx-lm runs Python a model repo names in its config.

## Limitations

- Electron/Chromium fields, terminals, Messages, and Mail get the text by ⌘V; the clipboard
  is restored 1 s later (first item only, with an alert).
- Firefox and other Gecko browsers are not supported (text would be inserted twice).
- A read-only text view looks like a terminal, so the ⌘V silently does nothing; every take
  is still saved to `history.directory`.

## Adding a runtime

Subclass `Speech` or `Cleaner` in `server.py`, set `name`, implement `load` and
`transcribe`/`complete`, register it in `SPEECH_BACKENDS`/`CLEANUP_BACKENDS`, and add it to
the alias in `config.lua`.

## Tests

From the dotfiles checkout (the tests are not deployed to `~/.hammerspoon`):

```sh
.hammerspoon/dictation/.venv/bin/python .hammerspoon/tests/dictation_test.py  # server.py
sh .hammerspoon/tests/dictation_test.sh  # init.lua, history.lua, engine.lua, recorder.lua
```
