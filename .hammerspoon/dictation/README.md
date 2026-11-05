# Local dictation for Hammerspoon

A free, fully local Raycast-style dictation pill. Press Option+Space to record, again to stop
(Escape cancels): a local speech model transcribes, a local LLM cleans up fillers and
self-corrections, your word list fixes names, and the text goes into the focused field.
`~/.hammerspoon/init.lua` loads it only on Apple Silicon with macOS 14+ (MLX).

## Setup

1. `mise bootstrap --yes` installs uv, ffmpeg, and the backend (its final hook runs
   `uv sync --locked --project ~/.hammerspoon/dictation`); rerun it whenever `uv.lock` changes.
2. Grant **Hammerspoon** Microphone and Accessibility in **System Settings > Privacy & Security**.
3. Reload Hammerspoon. The first start downloads the pinned models (about 4.3 GB) into
   `~/.cache/huggingface`; the console prints `Dictation: backend ready` once they are loaded, and
   a take recorded before then is transcribed at its stop. Later starts load them offline.

Your settings are in `config.lua`: the hotkey and `words`, each name as it should be written,
alone (`"Slack"`) or with what the speech model hears instead (`Raycast = { "ray cast" }`).
`defaults.lua` has every other setting, typed, with hover docs from lua-language-server; a key
set in `config.lua` replaces its default whole, and an unknown one alerts. `unloadMinutes = 15`
frees the models (about 4.2 GB) after 15 minutes without a take; `false` keeps them loaded.
`theme = "glass"` draws the pill in Liquid Glass (macOS 26+, light or dark with the system) instead
of the dark `"flat"` default, as `lib/toast.lua`'s glass theme does. `tint = { light = 0.5,
dark = 0.6 }` sets how white or black the glass is; `false` takes `lib/glass.lua`'s. If another
app, such as Raycast, also uses Option+Space, rebind one. The macOS dictation (mic) key cannot be
used: macOS always handles it itself.

## How it works

`init.lua` drives a take: `recorder.lua` records the default input with ffmpeg, which also streams
it over Unix sockets to the pill's equalizer (`overlay.lua`, through `lib/stream`) and to
`server.py`, a resident Python process (JSON lines on stdin and stdout, via `engine.lua`). The
backend transcribes while you speak, in segments cut at pauses, and 60 ms into each pause finishes
the whole take from the audio a stop in that pause would use, cleanup included, until what it heard
changes; a stop there types as soon as that is done. It fixes spellings, cleans up, and writes
numbers as digits. Its guard aligns the cleaned words with what was heard: the cleanup may fix
misheard words and drop stalls, fillers, repeats, and self-corrections, and whatever else it changed
or left out is put back as said ("Can you fix it?" for "Can you fix it? Just fix it." is typed
whole). A change that can't be put back cleanly, such as one inside a written number ("0.5" as
"0.05"), or a cleanup with no words when more than stalls and fillers were said, types nothing,
alerts, and keeps what was heard in `history.directory`. Otherwise `history.lua` saves the text and
`init.lua` types it into the focused field, spaced by `spacing.lua`.

## Speech models

Set `speech` in `config.lua`; it replaces the default whole, so a Parakeet TDT model needs `boost`
again:

```lua
speech = { backend = "parakeet-mlx", model = "mlx-community/parakeet-tdt-0.6b-v3", revision = "<sha>", boost = 4.5 },
```

`~/.hammerspoon/dictation/.venv/bin/hf models info <repo> --expand sha` prints a repo's SHA. Pin
only repos you trust: mlx-lm and mlx-audio run Python a model repo ships. Only `parakeet-mlx` uses
`boost`; `mlx-whisper` gets `words` as its prompt; `mlx-audio` ignores `words`. WER is the upstream
model's English average on the
[Open ASR Leaderboard](https://huggingface.co/spaces/hf-audio/open_asr_leaderboard) (26 Oct 2026).

| Model | Backend | Download | License | WER | Notes |
|---|---|---|---|---|---|
| `mlx-community/parakeet-tdt-0.6b-v2` | `parakeet-mlx` | 2.5 GB | CC-BY-4.0 | 6.02 | English only, fastest. Default. |
| `mlx-community/parakeet-tdt-0.6b-v3` | `parakeet-mlx` | 2.5 GB | CC-BY-4.0 | 6.18 | 25 EU languages; short English takes can come out in another. |
| `mlx-community/Qwen3-ASR-1.7B-4bit` | `mlx-audio` | 1.6 GB | Apache-2.0 | 5.40 | 30 languages, slower. |
| `ibm-granite/granite-speech-4.1-2b` | `mlx-audio` | 4.9 GB | Apache-2.0 | 5.96 | Lowercase, unpunctuated output: "i" and "915" can reach the field. Takes over about 2 minutes loop and type garbage. |
| `mlx-community/whisper-large-v3-turbo` | `mlx-whisper` | 1.6 GB | MIT | 7.64 | 100 languages. |
| `mistralai/Voxtral-Mini-4B-Realtime-2602` | `mlx-audio` | 18 GB | Apache-2.0 | 8.44 | Two weight copies; slower than real time (1.4-2.8x the take's length on an M1 Max). |

## Cleanup

The default cleanup model is the simplewords v3 LoRA on Qwen3.5-2B (1.7 GB + 67 MB). It ships its
own prompt, so `style` and per-app `style` apply only to a plain instruct model,
`cleanup = { backend = "mlx-lm", model = "<repo>", revision = "<sha>" }` with no `adapter`; with an
adapter they fail the load. A plain model types self-corrections as said.

## Limitations

- Electron/Chromium and Gecko (Firefox) fields, terminals, Messages, and Mail get the text by ⌘V;
  the clipboard is restored 1 s later (first item only, with an alert).
- A read-only text view looks like a terminal, so the ⌘V silently does nothing; every take is
  still saved to `history.directory`. A take the backend fails before hearing anything or never
  answers (it died, or Hammerspoon reloaded), or whose capture failed or didn't finish within 2 s
  of stop (an unplugged mic), keeps its recording there as a `.wav` if it caught any audio.
- The cleanup rewrites the whole take, starting 60 ms into each pause and dropped once what it
  heard changes: a take stopped mid-sentence waits for all of it, a 2.5-minute one about 6 s
  (M1 Max), 7 s (M5).
- A take started while the models load again after an unload (about 4 s on an M5) is transcribed
  whole at its stop, not while you speak: the pill thinks until its text is typed.
- Alerts show up to 3 lines of a failure's first line; the rest is in the Hammerspoon console and
  `~/Library/Logs/Hammerspoon/config.log`.

## Adding a runtime

In `models.py`, subclass `Speech` (`load`, and `transcribe(wav, hint)` or a `stream(hint)` that
transcribes while the take records, as `streaming.Stream` does) and register it in `SPEECH`,
or subclass `Cleaner` (`load`, `complete(messages, raw, between)`, calling `between()` after each
pass) and register it in `CLEANERS`, under the name `speech.backend` or `cleanup.backend` selects.
Then add that name to the field's type in `defaults.lua`.

## Tests

From the dotfiles checkout:

```sh
.hammerspoon/dictation/.venv/bin/python .hammerspoon/dictation/tests/server_test.py
sh .hammerspoon/dictation/tests/run.sh  # needs ffmpeg on PATH
sh .hammerspoon/tests/stream_test.sh  # needs ffmpeg on PATH
```
