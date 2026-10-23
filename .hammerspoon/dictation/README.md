# Local dictation for Hammerspoon

A free, fully local Raycast-style dictation pill. Press Option+Space to record, again to stop
(Escape cancels): a local speech model transcribes, a local LLM cleans up fillers and
self-corrections, your word list fixes names, and the text goes into the focused field.
`~/.hammerspoon/init.lua` loads it only on Apple Silicon with macOS 14+ (MLX).

## Setup

1. `~/.hammerspoon/dictation/setup.sh` (needs `uv` and `ffmpeg` from `mise install`).
2. Grant **Hammerspoon** Microphone and Accessibility in **System Settings > Privacy & Security**.
3. Reload Hammerspoon. The first start downloads the models pinned in `defaults.lua` into
   `~/.cache/huggingface`; later starts load them offline.

Your settings are in `config.lua`: the hotkey and `words`, each name as it should be written,
alone (`"Slack"`) or with what the speech model hears instead (`Raycast = { "ray cast" }`).
`defaults.lua` has every other setting, typed, with hover docs from lua-language-server; a key
set in `config.lua` replaces its default whole, and an unknown one alerts.
If Raycast also uses Option+Space, Hammerspoon wins; rebind one. The macOS dictation (mic)
key cannot be used: macOS 26 always handles it itself.

## How it works

`init.lua` drives a take: `recorder.lua` records the default input with ffmpeg, which also streams
it over a Unix socket (`lib/stream`) to the pill's equalizer (`overlay.lua`); at stop, `engine.lua`
sends the wav to `server.py`, a resident Python process (JSON lines on stdin and stdout) that
transcribes, fixes spellings, cleans up, and writes numbers as digits. Its guard aligns the cleaned
words with what was heard: if the cleanup did more than fix misheard words and drop stalls,
fillers, repeats, and self-corrections, the take types nothing, alerts, and keeps what was heard in
`history.directory`. Otherwise, `history.lua` saves the text and `init.lua` types it into the
focused field, spaced by `spacing.lua`.

## Speech models

Set `speech.backend`, `speech.model`, and `speech.revision`
(`.venv/bin/hf models info <repo> --expand sha`). WER is the Open ASR Leaderboard English average
of the upstream model. Only `parakeet-mlx` takes `speech.boost`; `mlx-whisper` gets `words`
as a prompt; `mlx-audio` ignores it.

| Model | Backend | Download | License | WER | Notes |
|---|---|---|---|---|---|
| `mlx-community/parakeet-tdt-0.6b-v2` | `parakeet-mlx` | 2.5 GB | CC-BY-4.0 | 4.70 | English only, fastest. Default. |
| `mlx-community/parakeet-tdt-0.6b-v3` | `parakeet-mlx` | 2.5 GB | CC-BY-4.0 | 4.86 | 25 EU languages; short English takes can come out in another. |
| `mlx-community/Qwen3-ASR-1.7B-4bit` | `mlx-audio` | 1.6 GB | Apache-2.0 | 4.31 | 50+ languages, slower. |
| `ibm-granite/granite-speech-4.1-2b` | `mlx-audio` | 4.9 GB | Apache-2.0 | 4.62 | |
| `mlx-community/whisper-large-v3-turbo` | `mlx-whisper` | 1.6 GB | MIT | 6.36 | 99 languages. |
| `mistralai/Voxtral-Mini-4B-Realtime-2602` | `mlx-audio` | 18 GB | Apache-2.0 | 6.46 | Two weight copies. |

## Cleanup

The default cleanup model is the simplewords v3 LoRA on Qwen3.5-2B (1.7 GB + 67 MB). It ships
its own prompt, so `style` and per-app `style` apply only to a plain instruct model
(`cleanup.adapter = nil`); with an adapter they fail the load. Pin only repos you trust: mlx-lm
runs Python a model repo names in its config.

## Limitations

- Electron/Chromium and Gecko (Firefox) fields, terminals, Messages, and Mail get the text by ⌘V;
  the clipboard is restored 1 s later (first item only, with an alert).
- A read-only text view looks like a terminal, so the ⌘V silently does nothing; every take
  is still saved to `history.directory`. A take the backend fails before hearing anything, or
  never answers (it died, or Hammerspoon reloaded), keeps its recording there as a `.wav`.

## Adding a runtime

In `models.py`, subclass `Speech` (`load`, `transcribe(wav, hint)`) and register it in `SPEECH`,
or subclass `Cleaner` (`load`, `complete(messages, raw)`) and register it in `CLEANERS`, under
the name `speech.backend` or `cleanup.backend` (default `mlx-lm`) selects. Then add that name to
the field's type in `defaults.lua`.

## Tests

From the dotfiles checkout:

```sh
.hammerspoon/dictation/.venv/bin/python .hammerspoon/dictation/tests/server_test.py
sh .hammerspoon/dictation/tests/run.sh
```
