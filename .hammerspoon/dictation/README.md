# Local dictation for Hammerspoon

A free, fully local replacement for macOS F5 dictation, styled after Raycast's
dictation pill. Press Option+Space to record, press again to stop; a local speech model
transcribes, a local LLM cleans it up using your style, vocabulary, and the
active app, and the result is inserted into the focused field (or copied to the
clipboard, per `insert` in config.lua).

Everything is self-contained in this directory; `~/.hammerspoon/init.lua` loads
it with `require("dictation")`.

## What runs where

| Piece | Where | Notes |
|---|---|---|
| Hotkey, overlay, capture, insert | Hammerspoon (Lua) | this directory |
| Speech-to-text + LLM cleanup | `.venv` Python (`server.py`) | resident process, fast after first load |
| Mic capture + equalizer | `ffmpeg` child + `spectrum.lua` | PCM via temp file, FFT in Lua; high-pass only, no denoising |

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
   inserting, pasting, and reading context). Slack and other Electron apps only
   expose their text field after accessibility is granted, and even then
   selection can be flaky. The window title, browser URL, and (opt-in) selection
   are read only for a plain instruct cleanup model (`cleanup.adapter = nil`);
   the default adapter ships its own prompt and never sees them. The URL needs
   Automation access, which macOS asks for once per browser.

4. Reload Hammerspoon. The backend loads models in the background (~10s the
   first time, plus a one-time model download).

## Choosing a speech model

Edit `stt` in `config.lua`; the backend must match the model. First use downloads
the model. The existing local model reference is listed below.

| Model | Backend | Approx. download | License | Recorded mean WER | Notes |
|---|---|---|---|---|---|
| `mlx-community/parakeet-tdt-0.6b-v2` | `parakeet-mlx` | ~2.3 GB | CC-BY-4.0 | 4.70 | English only, so it never outputs another language. Fastest. Default. |
| `mlx-community/parakeet-tdt-0.6b-v3` | `parakeet-mlx` | ~2.3 GB | CC-BY-4.0 | 4.86 | 25 EU languages with automatic detection: short English takes occasionally come out in another language. |
| `mlx-community/Qwen3-ASR-1.7B-4bit` | `mlx-audio` | ~2 GB | Apache-2.0 | 4.31 | Most accurate open model. 50+ languages. Slower than Parakeet. |
| `ibm-granite/granite-speech-4.1-2b` | `mlx-audio` | ~4 GB | Apache-2.0 | 4.62 | Strong EN/EU accuracy, keyword biasing. Heavier. |
| `mlx-community/whisper-large-v3-turbo` | `mlx-whisper` | ~1.6 GB | MIT | 6.36 | 99 languages, most battle-tested. Higher English WER. Verified working. |
| `mistralai/Voxtral-Mini-4B-Realtime-2602` | `mlx-audio` | ~5 GB | Apache-2.0 | 6.46 | Realtime/streaming oriented, multilingual. |

## Vocabulary and dictionary (names, tools, jargon)

`vocabulary` in `config.lua` is the list to maintain: just the correct
spellings. Any transcript token close to one of them ("ghosty", "hammer spoon",
"ray cast") is rewritten to it, before and after cleanup. A real English word
or its inflection is never fuzzy-matched ("recast" and "missed" stay), but an
exact case-insensitive match takes your spelling ("slack" → "Slack"). Paths and
domains are left alone ("github.com"). A vocabulary word you said is protected
from being dropped by the cleanup model unless you corrected yourself ("Slack,
no wait, GitHub"). With the Whisper backend the
list is also passed to the speech model as a prompt. With Parakeet it biases
decoding instead (`stt.boost`, default 4.5): once the model has spelled the
first letter of one of your words, pieces that continue it get a small bonus,
so a word it hears ambiguously ("oki" vs "okay") comes out as you listed it,
at no extra latency. Only single-word entries of letters, digits, and
apostrophes are boosted, and only on TDT models; multi-word, hyphenated, or
dotted entries ("yt-dlp", "Node.js") get just the text fixes above. Measured
on 80 takes of listed words: 42 → 58 correct, with no listed word inserted into
60 look-alike sentences ("okay", "ghostly", "a torrent of rain") and ordinary
dictation unchanged (error rate and casing).

`dictionary`, also in `config.lua`, is only for stubborn mishearings the
similarity match cannot reach, mapping the correct spelling to explicit spoken
variants:

```lua
dictionary = { mise = { "meez", "mees" } },
```

`config.lua` is the single settings file and is pure data (a typed Lua table,
no code), so lua-language-server gives completion and hover docs on every key.

End-of-text punctuation is automatic: the cleanup model ends a complete
sentence with the right mark, and a take that ends on a word no sentence ends
on ("the", "and", "because") is left open with no trailing punctuation, for you
to keep typing after. Internal punctuation is normal.

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

## Transcript history

Every result is written to `~/Library/Caches/dictation/<timestamp>.txt` the
moment the backend returns it, before insertion, so a paste that lands in the
wrong place (or an Escape) never loses the text. Once the directory passes
`history.maxMegabytes` of disk space (default 10, about 2,500 takes: every
file occupies at least one 4 KB block) the oldest files are deleted. Set the
folder and the cap in `history` in `config.lua`.

## Swapping models and runtimes

Models are swapped in `config.lua` alone: `stt.model` / `stt.backend` and
`cleanup.model` / `cleanup.adapter` / `cleanup.backend` (default `mlx-lm`). Any
Hugging Face repo the chosen runtime can load works; it is downloaded on first
use.

Runtimes are classes in `server.py`. Each model role is an abstract base with
one subclass per runtime, registered by name:

| Role | Method | Runtimes (`backend`) |
|---|---|---|
| `Speech` | `transcribe(wav, hint) -> str` | `parakeet-mlx`, `mlx-whisper`, `mlx-audio` |
| `Cleaner` | `complete(messages) -> str` | `mlx-lm` |

To add one (say whisper.cpp, or a GGUF cleanup model through llama.cpp),
subclass the role, set its `name`, implement `load` and the one method, and add
the class to `SPEECH_BACKENDS` / `CLEANUP_BACKENDS`; then name it in
`config.lua` (and its alias in the annotations). `Engine` owns everything
around the models, in order: dictionary and vocabulary, the prompt (or the
adapter's frozen prompt), the rewrite guard, stall stripping, the question
mark, and the end policy, so a new runtime gets the same behavior for free.

## Capture and insertion

Capture errors stop dictation and show a logged alert, as does a take quieter
than `minLevel` or with no recognized words; one shorter than `minDuration` is
dropped as an accidental tap. Capture uses the system's current default
microphone. The audio is only high-passed (90 Hz): denoising
(`afftdn`) and silence trimming were measured to make things worse, because
their fixed dB thresholds delete a quiet or distant speaker outright (a take
25 dB below full scale came back empty), while Parakeet itself is flat at
7–9% WER from full scale down to -35 dB and across pink, brown, fan, and
20–10 dB babble noise. Only loud overlapping speech (babble at ≤5 dB SNR)
defeats it, and no filter recovers that. ffmpeg writes the wav and, in
parallel, raw PCM to a flushed temp file; the 30 fps tick reads the new bytes
and `spectrum.lua` runs the FFT in Lua (~2 ms/frame). No Python is involved in
capture: Hammerspoon decodes task output as text (dropping PCM bytes) and
`io.popen` would block the main thread, while a page-cached file read costs
~13 µs per frame.

Stopping sends SIGINT so ffmpeg finalizes the WAV before transcription; if
Hammerspoon quits or crashes mid-take, a watchdog on ffmpeg's stdin sends it
instead, so the mic never stays open. Escape cancels capture and discards
pending transcription results by request ID. One timer drives the pill: a
glowing ripple from the center until the mic opens, crossfading (~0.4 s) into
the equalizer while recording (flat in silence, brighter when louder), a
glowing shimmer while transcribing.

Insertion (`insert` in config.lua): `auto` (default) inserts into the focused
field and, when there is no field or insertion fails, copies the text to the
clipboard and shows a brief alert; `direct` inserts only and reports failures;
`clipboard` only copies. The text goes only to the field that was focused when
dictation stopped: if focus moved while transcribing, that counts as a failure.
Direct insertion writes through Accessibility and leaves the clipboard
untouched. Chromium/Electron fields (Slack, VS Code, browsers) report
Accessibility writes as supported and then ignore them, so for those the text is
pasted with the app's own ⌘V (whole text at once, not typed) and the previous
clipboard is restored 0.25 s later; macOS gives no signal for when the app has
read the clipboard, so that delay is unavoidable. `hs.pasteboard` restores only
the first clipboard item, so several copied files come back as the first one,
with an alert.

## Files

| File | Role |
|---|---|
| `config.lua` | the only settings file: trigger, models, style, vocabulary, dictionary, per-app, insertion (pure data) |
| `init.lua` | hotkey, orchestration, context, insertion |
| `overlay.lua` | the Raycast-style waveform pill (`hs.canvas`) |
| `recorder.lua` | asynchronous mic capture and completion |
| `history.lua` | saves every transcript as a `.txt` file, deleting the oldest past a size cap |
| `spectrum.lua` | pure-Lua FFT: PCM window -> equalizer bands + level |
| `engine.lua` | manages the resident Python backend over a JSON pipe |
| `server.py` | speech-to-text + LLM cleanup, kept resident; `Speech`/`Cleaner` classes, one per runtime, picked by `backend` |
| `setup.sh` | builds `.venv` |
