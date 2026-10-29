import functools
import os
import re
import wave
from pathlib import Path


def pinned(revision):
    # A commit SHA loads from the cache with no Hub request; a branch is looked up every launch.
    if not re.fullmatch(r"[0-9a-f]{40}", str(revision)):
        raise ValueError(f"model revisions must be 40-character commit SHAs, got {revision!r}")
    return revision


def letters(piece):
    if re.fullmatch(r"<[^<>]+>", piece):
        return ""  # special pieces (<unk>, v3's <|en|>) are never boosted or part of a word
    return "".join(c for c in piece.lower() if c.isalnum() or c == "'")


def prefixes(words):
    # Every lowercase prefix of entries of only letters, digits, and apostrophes ("GitHub's").
    full = {w.lower() for w in map(str.strip, words) if w and letters(w) == w.lower()}
    return {w[:i] for w in full for i in range(1, len(w) + 1)}


class Boosted:
    """A Parakeet TDT model for parakeet-mlx's greedy decoder, biased toward vocabulary spellings:
    a piece that keeps its word a vocabulary prefix gains `bonus` per letter it adds, except the
    first, which flips casing and splitting ("▁me" -> "▁M" "e")."""

    def __init__(self, model, prefixes, bonus):
        self.model, self.prefixes, self.bonus = model, prefixes, bonus
        self.word, self.seen, self.biases = "", None, {}

    def __getattr__(self, name):
        return getattr(self.model, name)

    def decoder(self, token, hidden):
        # A new decoder state follows each emitted piece, which extends the word or starts one.
        if token is None:
            self.word = ""
        elif hidden is not self.seen:
            piece = self.vocabulary[int(token.item())]
            core = letters(piece)
            if piece.startswith("▁") or not core:
                self.word = core  # a new word, or punctuation ending one
            elif self.word:
                self.word += core
            if self.word and self.word not in self.prefixes:
                self.word = None  # it can no longer become a vocabulary word
        self.seen = hidden
        return self.model.decoder(token, hidden)

    def joint(self, feature, decoder_out):
        import mlx.core as mx

        word = self.word or ""
        if word not in self.biases:
            bias = [0.0] * (len(self.vocabulary) + 1 + len(self.durations))
            for i, piece in enumerate(self.vocabulary):
                core, starts = letters(piece), piece.startswith("▁")
                if core and (starts or word) and (core if starts else word + core) in self.prefixes:
                    bias[i] = self.bonus * (len(core) - starts)
            self.biases[word] = mx.array(bias)
        # Added to the logits, as to log-probs: the argmax is the same.
        return self.model.joint(feature, decoder_out).astype(mx.float32) + self.biases[word]


class Speech:
    boost = 0  # Parakeet TDT: log-prob bonus per matching vocabulary letter

    def __init__(self, speech):
        self.repo, self.revision = speech["model"], pinned(speech["revision"])

    def load(self):
        raise NotImplementedError

    def transcribe(self, wav, hint):
        raise NotImplementedError


class Parakeet(Speech):
    def __init__(self, speech):
        super().__init__(speech)
        self.boost = float(speech.get("boost") or 0)

    def load(self):
        import mlx.core as mx
        import numpy as np
        import parakeet_mlx.parakeet
        from huggingface_hub import hf_hub_download
        from parakeet_mlx import ParakeetTDT, from_pretrained

        def read(path, rate, _dtype):  # the recorder's 16 kHz mono s16le wav, with no ffmpeg
            with wave.open(str(path)) as audio:
                if audio.getparams()[:3] != (1, 2, rate):
                    raise ValueError(f"{path}: expected {rate} Hz mono 16-bit audio")
                frames = audio.readframes(audio.getnframes())
            return mx.array(np.frombuffer(frames, np.int16)).astype(mx.float32) / 32768.0

        # The two files from_pretrained reads, pinned; given a repo id it fetches the latest commit.
        config = hf_hub_download(self.repo, "config.json", revision=self.revision)
        hf_hub_download(self.repo, "model.safetensors", revision=self.revision)
        self.model = from_pretrained(os.path.dirname(config))
        mx.eval(self.model.parameters())  # lazy: read the weights now, not in the first take
        if self.boost and not isinstance(self.model, ParakeetTDT):
            raise ValueError(f"speech.boost needs a Parakeet TDT model, not {self.repo}")
        parakeet_mlx.parakeet.load_audio = read

    def transcribe(self, wav, hint):
        from parakeet_mlx import ParakeetTDT

        # Boosting swaps in a biased greedy decoder on this model instance only.
        self.model.__dict__.pop("decode_greedy", None)
        if self.boost and hint:
            boosted = Boosted(self.model, prefixes(hint), self.boost)
            self.model.decode_greedy = functools.partial(
                ParakeetTDT.decode_greedy,
                boosted,  # pyright: ignore[reportArgumentType]
            )
        # Chunked like parakeet-mlx's CLI: one full-attention pass grows memory quadratically.
        text = self.model.transcribe(wav, chunk_duration=120).text
        # Short-take garbage: special pieces (<unk>, v3's <|en|>) and rare-symbol runs ("ΨΨΨ").
        text = re.sub(r"<(?:unk|pad|\|[^<>|]*\|)>|(?<!\S)([^\x00-\x7F])\1{2,}(?!\S)", "", text)
        return " ".join(text.split())


class Whisper(Speech):
    def load(self):
        import mlx.core as mx
        from huggingface_hub import snapshot_download
        from mlx_whisper.transcribe import ModelHolder

        # Pinned local dir; given a repo id, mlx_whisper fetches the latest commit.
        self.path = snapshot_download(self.repo, revision=self.revision)
        ModelHolder.get_model(self.path, mx.float16)  # warm the cache transcribe() reads

    def transcribe(self, wav, hint):
        import mlx_whisper

        prompt = ", ".join(hint) or None
        result = mlx_whisper.transcribe(wav, path_or_hf_repo=self.path, initial_prompt=prompt)
        return result["text"].strip()  # pyright: ignore[reportAttributeAccessIssue]


class MlxAudio(Speech):
    def load(self):
        from mlx_audio.stt.utils import load_model

        self.model = load_model(self.repo, revision=self.revision)

    def transcribe(self, wav, hint):
        return self.model.generate(wav).text.strip()  # pyright: ignore[reportOptionalCall]


SPEECH = {"parakeet-mlx": Parakeet, "mlx-whisper": Whisper, "mlx-audio": MlxAudio}


class Cleaner:
    prompt = None  # a cleanup-trained adapter's own prompt, used verbatim; None = plain model
    words = frozenset()  # its tokenizer's whole words, kept as real words by the spelling pass

    def __init__(self, cleanup):
        self.repo, self.revision = cleanup["model"], pinned(cleanup["revision"])
        self.adapter = cleanup.get("adapter")
        self.adapter_revision = self.adapter and pinned(cleanup["adapterRevision"])

    def load(self):
        raise NotImplementedError

    def complete(self, messages, raw):
        raise NotImplementedError


class MlxLm(Cleaner):
    def load(self):
        from huggingface_hub import snapshot_download
        from mlx_lm import load

        adapter = None
        if self.adapter:  # it runs only with the prompt it was trained on
            adapter = snapshot_download(self.adapter, revision=self.adapter_revision)
            self.prompt = Path(adapter, "system_v2.txt").read_text().strip()
            if not self.prompt:
                raise ValueError(f"cleanup adapter {self.adapter} has an empty system_v2.txt")
        self.llm, self.tokenizer = load(self.repo, adapter_path=adapter, revision=self.revision)[:2]
        # Word-initial letter tokens ("Ġtacos", "▁emacs"): a modern real-word list.
        self.words = frozenset(
            t[1:].lower()
            for t in self.tokenizer.get_vocab()  # pyright: ignore[reportCallIssue]
            if t[:1] in "Ġ▁" and t[1:].isascii() and t[1:].isalpha()
        )

    def complete(self, messages, raw):
        from mlx_lm import generate

        prompt = self.tokenizer.apply_chat_template(
            messages, add_generation_prompt=True, enable_thinking=False
        )
        # Room to echo the dictation; a runaway is cut back to what was said. Greedy by default.
        limit = max(400, 2 * len(self.tokenizer.encode(raw)))  # pyright: ignore
        out = generate(self.llm, self.tokenizer, prompt, max_tokens=limit)
        # Past the last "</think>": the template opens and closes an empty one, the model may again.
        return out.rpartition("</think>")[2].strip()


CLEANERS = {"mlx-lm": MlxLm}
