"""Parakeet TDT on live audio: cut at pauses, each segment's text what one decode of all of it gives."""

import bisect
import re
from typing import NamedTuple, cast

import mlx.core as mx
import numpy as np
from parakeet_mlx import tokenizer
from parakeet_mlx.alignment import AlignedToken, sentences_to_result, tokens_to_sentences
from parakeet_mlx.audio import get_logmel
from parakeet_mlx.parakeet import DecodingConfig

from models import letters

RATE, FRAME = 16000, 320  # 20 ms frames
# Frames: a pause that cuts, the silence a segment keeps after its last sound, the sound it needs.
PAUSE, TAIL, VOICED = 20, 3, 10
PADDED = 10  # frames that kept silence is tiled to: v2's text depends on the silence it ends on
SHORTEST, LONGEST = 8 * 50, 30 * 50  # frames: no pause cut before 8 s; past 30 s, at the quietest
REFRESH = RATE  # samples of new sound between updates
SENTENCE = DecodingConfig().sentence
# Short-take garbage: special pieces (<unk>, v3's <|en|>) and rare-symbol runs ("ΨΨΨ").
GARBAGE = re.compile(r"<(?:unk|pad|\|[^<>|]*\|)>|(?<!\S)([^\x00-\x7F])\1{2,}(?!\S)")


class Booster:
    """Pulls the greedy decode toward vocabulary spellings: a bonus per letter of a piece that keeps
    the word so far a prefix of one."""

    def __init__(self, model, words, bonus):
        # Every lowercase prefix of entries of only letters, digits, and apostrophes ("GitHub's").
        entries = {word.lower() for word in words if letters(word) == word.lower()}
        self.prefixes = {word[:length] for word in entries for length in range(1, len(word) + 1)}
        self.vocabulary, self.bonus, self.biases = model.vocabulary, bonus, {}
        self.pieces = [(letters(piece), piece.startswith("▁")) for piece in model.vocabulary]
        self.width = len(model.vocabulary) + 1 + len(model.durations)

    def update(self, word, token):
        piece = self.vocabulary[token]
        core = letters(piece)
        if piece.startswith("▁") or not core:
            word = core  # a new word, or punctuation ending one
        elif word:
            word += core
        return word if not word or word in self.prefixes else None

    def bias(self, word):
        word = word or ""
        if word not in self.biases:  # added to the logits, as to log-probs: the argmax is the same
            bias = [0.0] * self.width
            for index, (core, starts) in enumerate(self.pieces):
                if core and (starts or word) and (core if starts else word + core) in self.prefixes:
                    # Zero for a first letter: it flips casing and splitting ("▁me" -> "▁M" "e").
                    bias[index] = self.bonus * (len(core) - starts)
            self.biases[word] = mx.array(bias)
        return self.biases[word]


class Step(NamedTuple):
    frame: int
    out: mx.array  # the prediction network's output this step's joint read
    pending: tuple | None  # its state, taken on if this step emits
    last: int | None
    hidden: tuple | None
    symbols: int
    word: str | None
    emitted: int  # tokens before it
    decision: tuple[int, int]  # token, duration index


class Path:
    """parakeet-mlx's greedy TDT decode of a segment that grows: each update re-checks every earlier
    decision in one batched joint and decodes again only from the first that changed, rejoining the
    old path where the decoder state is the same again."""

    def __init__(self, model, booster=None):
        self.model, self.booster = model, booster
        self.vocabulary = len(model.vocabulary)
        self.steps, self.tokens, self.tail = [], [], None
        self.state = (
            0,
            None,
            None,
            None,
            None,
            0,
            "",
        )  # frame, last, hidden, out, pending, symbols, word

    def decide(self, logits, words):  # token and duration index per row
        logits = logits.astype(mx.float32)
        if self.booster:
            logits = logits + mx.stack([self.booster.bias(word) for word in words])
        return mx.stack(
            [
                mx.argmax(logits[..., : self.vocabulary + 1], axis=-1),
                mx.argmax(logits[..., self.vocabulary + 1 :], axis=-1),
            ],
            -1,
        )

    def update(self, features):
        """`features`: the whole segment's encoder output, [1, frames, width]."""
        if self.steps:
            frames = mx.array([step.frame for step in self.steps])
            outs = mx.concatenate([step.out.reshape(1, -1) for step in self.steps])
            joint = self.model.joint
            logits = joint.enc(features[0][frames]) + joint.pred(outs)
            for layer in joint.joint_net:
                logits = layer(logits)
            now = self.decide(logits, [step.word for step in self.steps])
            decided = mx.array([step.decision for step in self.steps])
            changed = cast(list[bool], mx.any(now != decided, axis=1).tolist())
            if any(changed):
                first = changed.index(True)
                step = self.steps[first]
                self.tail = (
                    self.steps[first:],
                    changed[first:],
                    self.tokens,
                    self.state,
                    step.emitted,
                )
                self.steps, self.tokens = self.steps[:first], self.tokens[: step.emitted]
                self.state = (
                    step.frame,
                    step.last,
                    step.hidden,
                    step.out,
                    step.pending,
                    step.symbols,
                    step.word,
                )
        self.extend(features)
        return self.tokens

    def rejoin(self, tail, frame, last, symbols, word):
        """The old path from an unchanged step in this decoder state up to its next changed one, and the
        state to go on from; None if there is none."""
        steps, changed, tokens, end, base = tail
        frames = [step.frame for step in steps]
        for index in range(bisect.bisect_left(frames, frame), bisect.bisect_right(frames, frame)):
            step = steps[index]
            same = (step.emitted, step.last, step.symbols, step.word) == (
                len(self.tokens),
                last,
                symbols,
                word,
            )
            if changed[index] or not same:
                continue
            if [token.id for token in self.tokens[base:]] != [
                token.id for token in tokens[base : step.emitted]
            ]:
                continue
            following = changed.index(True, index + 1) if True in changed[index + 1 :] else None
            self.steps += steps[index:following]
            if following is None:
                self.tokens += tokens[step.emitted :]
                self.tail = None
                return end
            resume = steps[following]
            self.tokens += tokens[step.emitted : resume.emitted]
            self.tail = (steps[following + 1 :], changed[following + 1 :], tokens, end, base)
            return (
                resume.frame,
                resume.last,
                resume.hidden,
                resume.out,
                resume.pending,
                resume.symbols,
                resume.word,
            )
        return None

    def extend(self, features):
        frame, last, hidden, out, pending, symbols, word = self.state
        model, length = self.model, features.shape[1]
        while frame < length:
            if self.tail is not None:
                state = self.rejoin(self.tail, frame, last, symbols, word)
                if state is not None:
                    frame, last, hidden, out, pending, symbols, word = state
                    continue
            if (
                out is None
            ):  # the prediction network runs only after an emission: a blank leaves its input
                prediction, (memory, cell) = model.decoder(
                    None if last is None else mx.array([[last]]), hidden
                )
                out = prediction.astype(features.dtype)
                pending = (memory.astype(features.dtype), cell.astype(features.dtype))
            logits = model.joint(features[:, frame : frame + 1], out)[0, 0]
            token, decision = cast(list[list[int]], self.decide(logits, [word]).tolist())[0]
            self.steps.append(
                Step(
                    frame,
                    out,
                    pending,
                    last,
                    hidden,
                    symbols,
                    word,
                    len(self.tokens),
                    (token, decision),
                )
            )
            duration = model.durations[decision]
            if token != self.vocabulary:
                text = tokenizer.decode([token], model.vocabulary)
                ratio = model.time_ratio
                self.tokens.append(
                    AlignedToken(
                        token,
                        start=frame * ratio,
                        duration=duration * ratio,
                        confidence=1.0,
                        text=text,
                    )
                )
                last, hidden, out = token, pending, None
                if self.booster:
                    word = self.booster.update(word, token)
            frame += duration
            symbols = 0 if duration else symbols + 1
            if not duration and model.max_symbols is not None and symbols >= model.max_symbols:
                frame, symbols = frame + 1, 0
        self.state = (frame, last, hidden, out, pending, symbols, word)
        self.tail = None


def text(tokens):
    return " ".join(
        GARBAGE.sub("", sentences_to_result(tokens_to_sentences(tokens, SENTENCE)).text).split()
    )


class Stream:
    """A take's audio as it arrives. A 20 ms frame is silent 35 dB under the take's loudest (and under
    -60 dBFS). A segment's text comes from its audio up to TAIL frames after its last sound, tiled to
    PADDED, so a pause gives the text a release in it would. 400 ms of silence cuts a segment 8 s long
    there."""

    def __init__(self, model, booster):
        self.model = model
        self.paths = [Path(model)] + ([Path(model, booster)] if booster else [])
        self.open = np.zeros(0, np.float32)
        self.levels, self.silent = [], []
        self.peak, self.run, self.voiced = -120.0, 0, 0
        self.closed = []  # per closed segment: plain text, boosted text or None
        self.encoded = None  # (closed segments, open samples, padded) of the last encode

    def texts(self):
        """Every segment's (plain, boosted) so far, the open one as of its last encode if it has
        words: a cut in a pause changes none."""
        plain, *boosted = (text(path.tokens) for path in self.paths)
        opened = [(plain, boosted[0] if boosted else None)] if plain or any(boosted) else []
        return [*self.closed, *opened]

    def kept(self):
        """Samples of the open segment its text comes from, and whether they end on kept silence."""
        if self.run >= TAIL:
            return (len(self.levels) - self.run + TAIL) * FRAME, True
        return len(self.open), False

    def encode(self, length, padded):
        if self.encoded == (len(self.closed), length, padded):
            return
        audio = self.open[:length]
        if padded:
            silence = audio[-TAIL * FRAME :]
            tiles = np.tile(silence, -(-PADDED // TAIL))[: PADDED * FRAME]
            audio = np.concatenate([audio[: -TAIL * FRAME], tiles])
        features = self.model.encoder(get_logmel(mx.array(audio), self.model.preprocessor_config))[
            0
        ]
        mx.eval(features)
        self.encoded = (len(self.closed), length, padded)
        for path in self.paths:
            path.update(features)

    def feed(self, samples):
        """Returns whether the open segment was just encoded as a release now would encode it."""
        self.open = np.concatenate([self.open, samples])
        while (len(self.levels) + 1) * FRAME <= len(self.open):  # a cut shortens self.open
            frame = self.open[len(self.levels) * FRAME : (len(self.levels) + 1) * FRAME]
            level = float(10 * np.log10(np.mean(frame * frame) + 1e-12))
            self.peak = max(self.peak, level)
            silent = level < max(self.peak - 35, -60)
            self.levels.append(level)
            self.silent.append(silent)
            self.run = self.run + 1 if silent else 0
            self.voiced += not silent
            if self.run >= PAUSE and self.voiced >= VOICED and len(self.levels) >= SHORTEST:
                self.cut(len(self.levels) - self.run + TAIL, True)
            elif len(self.levels) >= LONGEST:
                recent = range(len(self.levels) - 100, len(self.levels))
                self.cut(min(recent, key=lambda index: self.levels[index]), False)
        if self.voiced < VOICED or self.encoded == (len(self.closed), *self.kept()):
            return False
        encoded = self.encoded[1] if self.encoded and self.encoded[0] == len(self.closed) else 0
        if self.run >= TAIL or len(self.open) - encoded >= REFRESH:
            self.encode(*self.kept())
            return self.run >= TAIL
        return False

    def cut(self, frame, padded):
        self.encode(frame * FRAME, padded)
        self.closed = self.texts()
        self.paths = [Path(self.model, path.booster) for path in self.paths]
        self.open, self.levels = self.open[frame * FRAME :], self.levels[frame:]
        self.silent = self.silent[frame:]
        self.voiced = len(self.silent) - sum(self.silent)
        silences = (index for index, silent in enumerate(reversed(self.silent)) if not silent)
        self.run, self.encoded = next(silences, len(self.silent)), None

    def finish(self):
        """Every segment's (plain, boosted), the open one from all its audio but the silence past TAIL."""
        if self.voiced and self.kept()[0] >= RATE // 10:
            self.encode(*self.kept())
            return self.texts()
        return self.closed
