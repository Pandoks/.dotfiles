# Local dictation for Hammerspoon

A free, fully local replacement for macOS F5 dictation, styled after Raycast's
dictation pill. Press Option+Space to record, press again to stop; a local speech model
transcribes, a local LLM cleans it up using your style, vocabulary, and the
active app, and the result is inserted into the focused field (or copied to the
clipboard, per `insert` in config.lua).

Everything is self-contained in this directory. The only change to your existing
config is one line in `~/.hammerspoon/init.lua`:

```lua
require("dictation")
```

## What runs where

| Piece | Where | Notes |
|---|---|---|
| Hotkey, overlay, capture, insert | Hammerspoon (Lua) | this directory |
| Speech-to-text + LLM cleanup | `.venv` Python (`server.py`) | resident process, fast after first load |
| Mic capture | `ffmpeg` child process | levels drive the waveform |

## Setup

1. Install the backend (creates `.venv`, needs `uv` and `ffmpeg`):

   ```sh
   ~/.hammerspoon/dictation/setup.sh
   ```

2. Pick a trigger. By default (`trigger = "hotkey"`) press **Option+Space** to
   start and again to stop. Change it in `config.lua`:
   - A different combo: edit `hotkey` (mods + key).
   - Tap a modifier like Raycast: set `trigger = "modifierTap"` and pick
     `modifierTap.keycode` (Right Command 54, Right Option 61, Right Shift 60,
     Right Control 62) and its `flag`; `taps = 1` or `2`.
   If Raycast is also bound to Option+Space, Hammerspoon takes precedence and
   Raycast will stop opening; change one of them.

   The physical macOS dictation key (mic glyph) cannot be used: macOS 26 owns it
   and always runs its own dictation, or an "enable Dictation?" prompt when
   Dictation is off, and no third-party app can suppress that. A `dictationKey`
   mode exists but is unreliable for this reason. Leave **System Settings >
   Keyboard > Dictation** on or off as you like; it no longer matters.

3. Grant permissions to **Hammerspoon** in **System Settings > Privacy &
   Security**: Microphone (for ffmpeg), Accessibility (for the key event,
   pasting, and reading context). Slack and other Electron apps only expose their
   text field after accessibility is granted, and even then selection can be
   flaky; app name and browser URL are always available.

4. Add `require("dictation")` to `~/.hammerspoon/init.lua` and reload
   Hammerspoon. The backend loads models in the background (~10s the first time,
   plus a one-time model download).

## Choosing a speech model

Edit `stt` in `config.lua`. See `models.lua` for a curated local list, for
example Parakeet (fastest, default), Qwen3-ASR (most accurate open), Granite,
or Whisper. Any repo the mlx-audio backend supports works; for Parakeet use
`backend = "parakeet-mlx"` for the fastest path. First use downloads the model.

## Vocabulary and dictionary (names, tools, jargon)

`vocabulary` in `config.lua` is the list to maintain: just the correct
spellings. Any transcript token close to one of them ("ghosty", "hammer spoon",
"ray cast") is rewritten to it, before and after cleanup. Real English words are
never rewritten ("recast" stays "recast"), and a vocabulary word you said is
protected from being dropped by the cleanup model. With the Whisper backend the
list is also passed to the speech model as a hint; Parakeet has no such input.

`dictionary.lua` is only for stubborn mishearings the similarity match cannot
reach, mapping the correct spelling to explicit spoken variants:

```lua
mise = { "meez", "mees" },
```

End-of-text punctuation is automatic: the cleanup model ends a complete
sentence with the right mark and leaves a mid-sentence fragment (one you will
keep typing after) with no trailing punctuation. Internal punctuation is normal.

## The cleanup model

Default: simplewords v3, a LoRA adapter trained only to clean dictation, on
`mlx-community/Qwen3.5-2B-MLX-4bit` (base ~1.3 GB + adapter 67 MB, downloaded
on first use into `~/.cache/huggingface`). Greedy decoding. On this Mac it was
the only candidate that handled self-corrections ("Thursday no Friday" ->
"Friday"), never answered a dictated question, and ran in ~0.8 s. It ships its
own prompt, which is used verbatim; a vocabulary list cannot be added to it (it
echoes the list back), so vocabulary is applied deterministically as above.

`style` and per-app `apps` instructions only take effect with a plain instruct
model: set `cleanup.adapter = nil` and `cleanup.model` to e.g.
`mlx-community/Qwen2.5-1.5B-Instruct-4bit`. Generic models measured worse here
(no self-correction handling) but are steerable.

Set `cleanup.enabled = false` for raw transcription with no LLM pass.

## Files

| File | Role |
|---|---|
| `config.lua` | all user settings (models, style, vocabulary, per-app, hotkey) |
| `models.lua` | curated local speech-model list |
| `init.lua` | hotkey, orchestration, context, insertion |
| `overlay.lua` | the Raycast-style waveform pill (`hs.canvas`) |
| `recorder.lua` | asynchronous mic capture and completion |
| `analyzer.py` | owns ffmpeg and streams live levels |
| `engine.lua` | manages the resident Python backend over a JSON pipe |
| `server.py` | speech-to-text + LLM cleanup, kept resident |
| `setup.sh` | builds `.venv` |

Capture errors stop dictation and show a logged alert. Capture uses the system's
current default microphone without running discovery subprocesses.

Stopping waits for ffmpeg to finalize the WAV before transcription. Escape
cancels capture and discards pending transcription results by request ID. Meter
frames update the recording overlay directly; a timer animates only the thinking
state. Direct insertion writes through Accessibility and leaves the clipboard
untouched; clipboard mode only copies. Chromium/Electron fields (Slack, VS Code,
browsers) report Accessibility writes as supported and then ignore them, so for
those the text is pasted with the app's own ⌘V (whole text at once, not typed)
and the previous clipboard is restored 0.25 s later; macOS gives no signal for
when the app has read the clipboard, so that delay is unavoidable.
