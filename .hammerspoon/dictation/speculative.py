"""Greedy decoding with mlx-lm's exact output, several tokens per pass, for Qwen3.5 models.

Drafts copy the dictation, which the cleanup mostly echoes. A pass of at most ROWS tokens gives each
row bit for bit what a one-token pass would: the 4-bit matmul keeps its kernel up to 5 rows (mlx
0.32.2), attention and each LoRA product run one row at a time, and a rejected draft's GatedDeltaNet
state is recomputed from that pass's own inputs. load() checks this on the GPU it runs on."""

import copy
import itertools
from typing import cast

import mlx.core as mx
from mlx import nn
from mlx_lm.generate import generation_stream, wired_limit
from mlx_lm.models import qwen3_5, qwen3_next
from mlx_lm.models.cache import KVCache
from mlx_lm.models.gated_delta import gated_delta_update as update
from mlx_lm.tuner.lora import LoRALinear

ROWS = 5
SIBLINGS = (  # layers that read the same input share one first-factor product
    ("in_proj_qkv", "in_proj_z", "in_proj_b", "in_proj_a"),
    ("q_proj", "k_proj", "v_proj"),
    ("gate_proj", "up_proj"),
)
active = True  # False: every pass as shipped
recording = None  # per GatedDeltaNet layer of the running pass: its conv input and update arguments


attend = qwen3_next.scaled_dot_product_attention  # pyright: ignore[reportPrivateImportUsage]


def attention(queries, keys, values, cache, scale, mask, **kwargs):
    """Each row over the keys a one-token pass has: from ~1,000 keys on, MLX picks its kernel by
    the row count."""
    rows = queries.shape[2]
    if not active or rows == 1 or rows > ROWS:
        return attend(queries, keys, values, cache=cache, scale=scale, mask=mask, **kwargs)
    seen = keys.shape[2] - rows
    return mx.concatenate(
        [
            attend(
                queries[:, :, row : row + 1],
                keys[:, :, : seen + row + 1],
                values[:, :, : seen + row + 1],
                cache=cache,
                scale=scale,
                mask=None,
                **kwargs,
            )
            for row in range(rows)
        ],
        axis=2,
    )


def recorded(*args, **kwargs):
    if recording is not None:
        recording[-1]["update"] = args
    return update(*args, **kwargs)


def tiled(weight):  # a copy per row: a broadcast one gets folded into one matrix product
    return mx.contiguous(mx.broadcast_to(weight, (ROWS, *weight.shape)))


class Conv(nn.Conv1d):
    def __call__(self, x):
        if recording is not None:
            recording.append({"conv": x})
        return super().__call__(x)


class Lora(LoRALinear):
    def __call__(self, x):
        rows = x.shape[-2]
        if not active or rows > ROWS:  # the prompt, as shipped
            return super().__call__(x)
        group = self.__dict__["group"]
        if group["input"] is not x:  # held, so a later input can't reuse its id
            if rows == 1:
                product = self.dropout(x) @ group["first"]
            else:
                padded = mx.pad(
                    self.dropout(x).reshape(rows, 1, -1), [(0, ROWS - rows), (0, 0), (0, 0)]
                )
                product = padded @ group["tiles"]
            group["input"], group["parts"] = x, mx.split(product, group["splits"], axis=-1)
        part = group["parts"][self.__dict__["index"]]
        if rows == 1:
            second = part @ self.lora_b
        else:
            second = (part @ self.__dict__["tiles"])[:rows].reshape(*x.shape[:-1], -1)
        return self.linear(x) + (self.scale * second).astype(x.dtype)


def install(model, cache, tokens):
    """Swaps in the exact layers, then checks a speculative pass and rollback against one-token passes
    bit for bit after `cache` and after 1,100 more tokens, over `tokens` (5+)."""
    global active, recording
    qwen3_5.gated_delta_update = recorded  # pyright: ignore[reportPrivateImportUsage]
    qwen3_next.scaled_dot_product_attention = attention  # pyright: ignore[reportPrivateImportUsage]
    modules = [module for _, module in model.named_modules()]
    grouped = []
    for module, names in itertools.product(modules, SIBLINGS):
        members = [module.get(name) for name in names]
        if all(isinstance(member, LoRALinear) for member in members):
            grouped.append(members)
    seen = {id(member) for members in grouped for member in members}
    grouped += [
        [module] for module in modules if isinstance(module, LoRALinear) and id(module) not in seen
    ]
    for members in grouped:
        first = mx.concatenate([member.lora_a for member in members], axis=1)
        ends = list(itertools.accumulate(member.lora_a.shape[1] for member in members))
        group = {"first": first, "tiles": tiled(first), "splits": ends[:-1], "input": None}
        for index, member in enumerate(members):
            member.__class__ = Lora
            member.__dict__.update(group=group, index=index, tiles=tiled(member.lora_b))
        mx.eval(group["tiles"], [member.__dict__["tiles"] for member in members])
    for module in modules:
        if isinstance(module, qwen3_5.GatedDeltaNet):
            module.conv1d.__class__ = Conv

    def passes(start, chunks):
        state = copy.deepcopy(start)
        rows = [model(mx.array(chunk)[None], cache=state)[0] for chunk in chunks]
        return state, mx.concatenate(rows)

    with mx.stream(generation_stream):
        longer = copy.deepcopy(cache)
        model(mx.array((tokens * 1100)[:1100])[None], cache=longer)
        for start in (cache, longer):
            active = False
            _, shipped = passes(start, [[token] for token in tokens[:5]])
            active, recording = True, []
            state, verified = passes(start, [tokens[:5]])
            rollback(state, 2, 5)
            recording = None
            resumed = model(mx.array(tokens[2:3])[None], cache=state)[0]
            if not (
                mx.array_equal(verified, shipped).item()
                and mx.array_equal(resumed, shipped[2:3]).item()
            ):
                raise RuntimeError("speculative decoding is not exact on this GPU")


def rollback(cache, keep, rows):
    """Leaves only the first `keep` of the last pass's `rows` in `cache`."""
    layers = iter(recording or [])
    for entry in cache:
        if isinstance(entry, KVCache):
            entry.trim(rows - keep)
            continue
        step = next(layers)
        conv, (*_, decay, bias, state, mask) = step["conv"], step["update"]
        entry[0] = mx.contiguous(conv[:, keep : keep + conv.shape[1] - rows])
        queries, keys, values, gates, betas = [array[:, :keep] for array in step["update"][:5]]
        entry[1] = update(queries, keys, values, gates, betas, decay, bias, state, mask)[1]


class Drafts:
    """Guesses the next tokens by finding the output's last 1-4 tokens, case and spaces folded, in
    the dictation's."""

    def __init__(self, source, fold):
        self.source, self.fold, self.at = source, fold, 0
        keys = [fold(token) for token in source]
        self.ends = {}
        for length in range(1, 5):
            for end in range(length, len(source) + 1):
                self.ends.setdefault(tuple(keys[end - length : end]), []).append(end)

    def next(self, tokens, count):
        for length in range(min(4, len(tokens)), 0, -1):
            ends = self.ends.get(tuple(map(self.fold, tokens[-length:])))
            if ends:  # the copy's nearest match; with none, the copy goes on where it was
                self.at = min(ends, key=lambda end: (abs(end - self.at - 1), -end))
                break
        return self.source[self.at : self.at + count]


def generate(model, prompt, cache, drafts, limit, eos):
    """Greedy tokens for `prompt` after `cache`, the same as mlx-lm's generate_step gives."""
    global recording
    tokens = []
    with wired_limit(model, [generation_stream]), mx.stream(generation_stream):  # pyright: ignore[reportArgumentType]
        while len(prompt) > 1:  # all but the last token, as generate_step prefills
            size = min(2048, len(prompt) - 1)
            model(mx.array(prompt[:size])[None], cache=cache)
            mx.eval([entry.state for entry in cache])
            prompt = prompt[size:]
        feed = prompt
        try:
            while True:
                guesses = drafts.next(tokens, min(ROWS - len(feed), limit - len(tokens)))
                recording = []
                logits = model(mx.array(feed + guesses)[None], cache=cache)[0, len(feed) - 1 :]
                best = cast(list[int], mx.argmax(logits, axis=-1).tolist())
                accepted = next(
                    (index for index, guess in enumerate(guesses) if guess != best[index]),
                    len(guesses),
                )
                drafts.at += accepted
                for token in guesses[:accepted] + [best[accepted]]:
                    if token in eos:
                        return tokens
                    tokens.append(token)
                    if len(tokens) == limit:
                        return tokens
                if accepted < len(guesses):
                    rollback(cache, len(feed) + accepted, len(feed) + len(guesses))
                feed = [best[accepted]]
        finally:
            recording = None
