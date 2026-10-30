import copy
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
    return "".join(letter for letter in piece.lower() if letter.isalnum() or letter == "'")


def read(path, rate=16000, _dtype=None):  # the recorder's 16 kHz mono s16le wav, with no ffmpeg
    import mlx.core as mx
    import numpy as np

    with wave.open(str(path)) as audio:
        if audio.getparams()[:3] != (1, 2, rate):
            raise ValueError(f"{path}: expected {rate} Hz mono 16-bit audio")
        frames = audio.readframes(audio.getnframes())
    return mx.array(np.frombuffer(frames, np.int16)).astype(mx.float32) / 32768.0


class Boosted:
    """A Parakeet TDT model whose greedy decoder favors vocabulary spellings."""

    def __init__(self, model, words, bonus):
        # Every lowercase prefix of entries of only letters, digits, and apostrophes ("GitHub's").
        entries = {
            word.lower() for word in map(str.strip, words) if word and letters(word) == word.lower()
        }
        self.prefixes = {word[:length] for word in entries for length in range(1, len(word) + 1)}
        self.model, self.bonus = model, bonus
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

    def joint(self, feature, prediction):
        import mlx.core as mx

        word = self.word or ""
        if word not in self.biases:
            bias = [0.0] * (len(self.vocabulary) + 1 + len(self.durations))
            for token, piece in enumerate(self.vocabulary):
                core, starts = letters(piece), piece.startswith("▁")
                if core and (starts or word) and (core if starts else word + core) in self.prefixes:
                    # Zero for a first letter: it flips casing and splitting ("▁me" -> "▁M" "e").
                    bias[token] = self.bonus * (len(core) - starts)
            self.biases[word] = mx.array(bias)
        # Added to the logits, as to log-probs: the argmax is the same.
        return self.model.joint(feature, prediction).astype(mx.float32) + self.biases[word]


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
        self.boost, self.encoded = float(speech.get("boost") or 0), {}

    def load(self):
        import mlx.core as mx
        import parakeet_mlx.parakeet
        from huggingface_hub import hf_hub_download
        from parakeet_mlx import ParakeetTDT, from_pretrained

        # The two files from_pretrained reads, pinned; given a repo id it fetches the latest commit.
        config = hf_hub_download(self.repo, "config.json", revision=self.revision)
        hf_hub_download(self.repo, "model.safetensors", revision=self.revision)
        self.model = from_pretrained(os.path.dirname(config))
        mx.eval(self.model.parameters())  # lazy: read the weights now, not in the first take
        if self.boost and not isinstance(self.model, ParakeetTDT):
            raise ValueError(f"speech.boost needs a Parakeet TDT model, not {self.repo}")
        parakeet_mlx.parakeet.load_audio = read

    def transcribe(self, wav, hint):
        import numpy as np
        from parakeet_mlx import ParakeetTDT
        from parakeet_mlx.alignment import sentences_to_result, tokens_to_sentences

        model, boosting = self.model, bool(self.boost and hint)

        def generate(mel, *, decoding_config):  # ParakeetTDT's, encoding each chunk once per take
            key = np.asarray(mel).tobytes()
            features = self.encoded.pop(key, None) or model.encoder(mel)
            if boosting:
                self.encoded[key] = features
            tokens = model.decode(  # pyright: ignore[reportOptionalCall]
                *features, config=decoding_config
            )[0][0]
            return [sentences_to_result(tokens_to_sentences(tokens, decoding_config.sentence))]

        if self.boost:  # a TDT model (load checks); the unboosted pass reuses the encodings
            model.generate = generate  # pyright: ignore[reportAttributeAccessIssue]
        # Boosting swaps in a biased greedy decoder on this model instance only.
        model.__dict__.pop("decode_greedy", None)
        if boosting:
            self.encoded = {}
            boosted = Boosted(model, hint, self.boost)
            model.decode_greedy = functools.partial(
                ParakeetTDT.decode_greedy,
                boosted,  # pyright: ignore[reportArgumentType]
            )
        # Chunked like parakeet-mlx's CLI: one full-attention pass grows memory quadratically.
        text = model.transcribe(wav, chunk_duration=120).text
        # Short-take garbage: special pieces (<unk>, v3's <|en|>) and rare-symbol runs ("ΨΨΨ").
        return re.sub(r"<(?:unk|pad|\|[^<>|]*\|)>|(?<!\S)([^\x00-\x7F])\1{2,}(?!\S)", "", text)


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
        result = mlx_whisper.transcribe(read(wav), path_or_hf_repo=self.path, initial_prompt=prompt)
        return result["text"]


class MlxAudio(Speech):
    def load(self):
        from mlx_audio.stt.utils import load_model

        self.model = load_model(self.repo, revision=self.revision)

    def transcribe(self, wav, hint):
        return self.model.generate(wav).text  # pyright: ignore[reportOptionalCall]


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
    cache = None

    def load(self):
        import mlx.core as mx
        from huggingface_hub import snapshot_download
        from mlx_lm import load
        from mlx_lm.models.cache import make_prompt_cache

        adapter = None
        if self.adapter:  # it runs only with the prompt it was trained on
            adapter = snapshot_download(self.adapter, revision=self.adapter_revision)
            self.prompt = Path(adapter, "system_v2.txt").read_text().strip()
            if not self.prompt:
                raise ValueError(f"cleanup adapter {self.adapter} has an empty system_v2.txt")
        self.llm, self.tokenizer = load(self.repo, adapter_path=adapter, revision=self.revision)[:2]
        if self.prompt:
            # Every take starts with the prompt's tokens: prefilled once, then copied per take.
            takes = ([{"role": "user", "content": f"{self.prompt}\n\n{raw}"}] for raw in "ab")
            first, second = map(self.render, takes)
            self.prefix = first[
                : next(
                    index
                    for index, (token, other) in enumerate(zip(first, second))
                    if token != other
                )
            ]
            self.cache = make_prompt_cache(self.llm)
            self.llm(mx.array(self.prefix)[None], cache=self.cache)
            mx.eval([layer.state for layer in self.cache])
        # Word-initial letter tokens ("Ġtacos", "▁emacs"): a modern real-word list.
        self.words = frozenset(
            token[1:].lower()
            for token in self.tokenizer.get_vocab()  # pyright: ignore[reportCallIssue]
            if token[:1] in "Ġ▁" and token[1:].isascii() and token[1:].isalpha()
        )

    def render(self, messages):
        return self.tokenizer.apply_chat_template(
            messages, add_generation_prompt=True, enable_thinking=False
        )

    def complete(self, messages, raw):
        from mlx_lm import generate

        prompt, cache = self.render(messages), None
        if self.cache:
            if prompt[: len(self.prefix)] != self.prefix:
                raise RuntimeError("the take's prompt does not start with the prefilled one")
            prompt, cache = prompt[len(self.prefix) :], copy.deepcopy(self.cache)
        # Room to echo the dictation; a runaway is cut back to what was said. Greedy by default.
        limit = max(400, 2 * len(self.tokenizer.encode(raw)))  # pyright: ignore[reportCallIssue]
        reply = generate(self.llm, self.tokenizer, prompt, max_tokens=limit, prompt_cache=cache)
        # Past the last "</think>": the template opens and closes an empty one, the model may again.
        return reply.rpartition("</think>")[2].strip()


CLEANERS = {"mlx-lm": MlxLm}
