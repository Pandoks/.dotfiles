import copy
import functools
import os
import re
import wave
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from streaming import Stream


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


class Speech:
    boost = 0  # Parakeet TDT: log-prob bonus per matching vocabulary letter

    def __init__(self, speech):
        self.repo, self.revision = speech["model"], pinned(speech["revision"])

    def load(self):
        raise NotImplementedError

    def stream(self, hint) -> "Stream | None":  # None: it takes only the whole recording
        return None

    def transcribe(self, wav, hint):
        raise NotImplementedError


class Parakeet(Speech):
    def __init__(self, speech):
        super().__init__(speech)
        self.boost = float(speech.get("boost") or 0)

    def load(self):
        import mlx.core as mx
        from huggingface_hub import hf_hub_download
        from mlx.utils import tree_map
        from parakeet_mlx import ParakeetTDT, from_pretrained

        # The two files from_pretrained reads, pinned; given a repo id it fetches the latest commit.
        config = hf_hub_download(self.repo, "config.json", revision=self.revision)
        hf_hub_download(self.repo, "model.safetensors", revision=self.revision)
        self.model = from_pretrained(os.path.dirname(config))
        if not isinstance(self.model, ParakeetTDT):
            raise TypeError(f"parakeet-mlx streams only Parakeet TDT models, not {self.repo}")
        # float32: M1 GPUs have no bfloat16, and the encoder runs faster with the same tokens.
        parameters = self.model.parameters()
        self.model.update(
            tree_map(
                lambda array: array.astype(mx.float32) if array.dtype == mx.bfloat16 else array,
                parameters,
            )
        )
        mx.eval(self.model.parameters())  # lazy: read the weights now, not in the first take

    def stream(self, hint):
        import streaming

        booster = self.boost and hint and streaming.Booster(self.model, hint, self.boost)
        return streaming.Stream(self.model, booster or None)


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

    def complete(self, messages, raw, between=None):  # between(), after each pass, may raise
        raise NotImplementedError


class MlxLm(Cleaner):
    cache = fold = None

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
        if self.llm.model_type == "qwen3_5":
            import speculative

            probe = self.tokenizer.encode("Move the sync to Friday at noon.")  # pyright: ignore[reportCallIssue]
            speculative.install(self.llm, self.cache or make_prompt_cache(self.llm), probe)
            self.fold = functools.cache(
                lambda token: self.tokenizer.decode([token]).strip().lower()  # pyright: ignore[reportCallIssue]
            )
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

    def complete(self, messages, raw, between=None):
        import mlx.core as mx
        from mlx_lm.generate import generate_step
        from mlx_lm.models.cache import make_prompt_cache

        prompt, cache = self.render(messages), None
        if self.cache:
            if prompt[: len(self.prefix)] != self.prefix:
                raise RuntimeError("the take's prompt does not start with the prefilled one")
            prompt, cache = prompt[len(self.prefix) :], copy.deepcopy(self.cache)
        # Room to echo the dictation; a runaway is cut back to what was said. Greedy.
        source = self.tokenizer.encode(raw)  # pyright: ignore[reportCallIssue]
        limit, eos = max(400, 2 * len(source)), set(self.tokenizer.eos_token_ids)
        if self.fold:
            import speculative

            end = self.tokenizer.convert_tokens_to_ids("<|im_end|>")  # pyright: ignore[reportCallIssue]
            drafts = speculative.Drafts([*source, end], self.fold)
            cache = cache or make_prompt_cache(self.llm)
            tokens = speculative.generate(self.llm, prompt, cache, drafts, limit, eos, between)
        else:  # mlx-lm's generate, without its per-call detokenizer: a copy of the vocabulary
            tokens = []
            for token, _ in generate_step(
                mx.array(prompt), self.llm, max_tokens=limit, prompt_cache=cache
            ):
                if token in eos:
                    break
                tokens.append(token)
                if between:
                    between()
        # Past the last "</think>": the template opens and closes an empty one, the model may again.
        reply = self.tokenizer.decode(tokens)  # pyright: ignore[reportCallIssue]
        return reply.rpartition("</think>")[2].strip()


CLEANERS = {"mlx-lm": MlxLm}
