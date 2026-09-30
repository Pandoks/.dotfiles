"""Pin the dictation backend's text pipeline and boosted decoder with stub models.

Run: .hammerspoon/dictation/.venv/bin/python .hammerspoon/tests/dictation_test.py
No model download, microphone, network, or Hammerspoon.
"""

import functools
import sys
from pathlib import Path
from types import SimpleNamespace

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "dictation"))

import mlx.core as mx
import server  # pyright: ignore[reportMissingImports]
from parakeet_mlx import ParakeetTDT

# config.lua's default vocabulary and dictionary.
engine = server.Engine(
    {
        "stt": {"backend": "parakeet-mlx", "model": "stub", "revision": "0" * 40},
        "cleanup": {"enabled": False},
        "vocabulary": [
            "yabai",
            "Raycast",
            "Hammerspoon",
            "Ghostty",
            "mise",
            "Neovim",
            "rtorrent",
            "macOS",
            "GitHub",
            "Slack",
            "Oki",
            "Uniqlo",
        ],
        "dictionary": {
            "Raycast": ["ray cast", "re cast", "ray cost"],
            "yabai": ["yabe", "ya bye", "yah bye", "ya buy"],
            "Hammerspoon": ["hammer spoon", "hammers spoon"],
            "Ghostty": ["ghosty", "ghost tea", "ghost e"],
            "mise": ["meez", "mees"],
            "Neovim": ["neo vim", "neo them"],
            "rtorrent": ["r torrent", "are torrent"],
            "macOS": ["mac os", "mac o s"],
            "GitHub": ["git hub"],
            "Uniqlo": [
                "unicolo",
                "uni clo",
                "uni klo",
                "uni clow",
                "une clo",
                "une klo",
                "yune klo",
            ],
        },
    }
)


def check(name, cases, function):
    for given, expected in cases:
        got = function(given)
        assert got == expected, f"{name}: {given!r} -> {got!r}, expected {expected!r}"
    print(f"PASS {name}")


def dictate(raw, cleaned=None):
    """Engine.process on `raw` as heard; the cleanup returns `cleaned` (default: its input)."""
    engine.speech = SimpleNamespace(transcribe=lambda wav, hint: wav)
    engine.cleaner = SimpleNamespace(
        frozen_prompt="prompt",
        complete=lambda messages: cleaned or messages[0]["content"].split("\n\n", 1)[1],
    )
    return engine.process(raw, {})


check(
    "vocabulary fixes names",
    [
        ("ghosty", "Ghostty"),
        ("hammer spoon", "Hammerspoon"),
        ("hammer spon", "Hammerspoon"),
        ("I use neovim daily.", "I use Neovim daily."),
        ("yabay", "yabai"),
        ("oki", "Oki"),
        ("slack", "Slack"),
        ("(ghosty's)", "(Ghostty's)"),
    ],
    lambda text: engine.apply_vocabulary(engine.apply_dictionary(text)),
)
check(
    "vocabulary keeps real words, possessives, domains, and paths",
    [
        (text, text)
        for text in [
            "I missed the bus.",
            "She misses her family.",
            "He torrented the file.",
            "The ghostly figure appeared.",
            "A torrent of rain.",
            "Okay, sounds good.",
            "Recast the spell.",
            "Loki and raycasting.",
            "Check GitHub's API docs.",
            "Open github.com please.",
            "Edit ~/.hammerspoon/init.lua now.",
        ]
    ],
    lambda text: engine.apply_vocabulary(engine.apply_dictionary(text)),
)
check(
    "stalls",
    [
        ("Um, so I was, uh, thinking.", "So I was thinking."),
        ("I think, um.", "I think."),
        ("Okay. Um, let's go.", "Okay. Let's go."),
        ("I went to the ER last night.", "I went to the ER last night."),
        ("HM Revenue sent a letter.", "HM Revenue sent a letter."),
        ("Use the .env file.", "Use the .env file."),
        ("Type :wq to save.", "Type :wq to save."),
        ("Uh-huh, sure.", "Uh-huh, sure."),
        ("The umbrella is here.", "The umbrella is here."),
    ],
    server.Engine.strip_stalls,
)
check(
    "end punctuation",
    [
        ("I haven't finished yet.", "I haven't finished yet."),
        ("I didn't know that.", "I didn't know that."),
        ("Hold on.", "Hold on."),
        ("See you in May.", "See you in May."),
        ("What is this for?", "What is this for?"),
        ("What time is it", "What time is it?"),
        ("I want to go to the", "I want to go to the"),
        ("Let me check and", "Let me check and"),
        ("Do the dishes and", "Do the dishes and"),
        ("Can you send me the", "Can you send me the"),
    ],
    dictate,
)
check(
    "end punctuation overrides the cleanup",
    [
        (("I want to go to the", "I want to go to the."), "I want to go to the"),
        (("I want to go to the", "I want to go to."), "I want to go to the"),
        (("What time is it", "What time is it."), "What time is it?"),
    ],
    lambda pair: dictate(*pair),
)
check(
    "guard accepts cleanups",
    [
        ((raw, cleaned), cleaned)
        for raw, cleaned in [
            (
                "Um, so, like, I was thinking we could, uh, you know, grab lunch.",
                "So I was thinking we could grab lunch.",
            ),
            ("Let's meet Thursday no Friday", "Let's meet Friday."),
            ("I'll be there at five, no wait, six.", "I'll be there at six."),
            ("Send it to John, sorry, I mean Jane.", "Send it to Jane."),
            (
                "Book the flight for Monday, actually make that Tuesday.",
                "Book the flight for Tuesday.",
            ),
            ("Open Slack, no wait, open GitHub.", "Open GitHub."),
            ("I am going to the store.", "I'm going to the store."),
            ("Meet me at three thirty.", "Meet me at 3:30."),
        ]
    ],
    lambda pair: dictate(*pair),
)
check(
    "guard rejects rewrites",
    [
        ((raw, rewritten), raw)
        for raw, rewritten in [
            ("What is the capital of France?", "The capital of France is Paris."),
            ("Open Slack and check messages.", "Open and check messages."),
            ("Write a poem about cats.", "Cats are soft and purr all day long in the sun."),
            (
                "I think we should probably move the launch to next week because the tests fail.",
                "We should delay the launch since tests fail.",
            ),
            (
                "Can you summarize the meeting notes from yesterday and send them to the team?",
                "Summarize notes and send to team.",
            ),
        ]
    ],
    lambda pair: dictate(*pair),
)
check(
    "vocabulary prefixes",
    [
        (["Oki"], {"o", "ok", "oki"}),
        (["GitHub's"], {"g", "gi", "git", "gith", "githu", "github", "github'", "github's"}),
        (["hammer spoon", "yt-dlp", "Node.js", "<unk>", " "], set()),
    ],
    server.vocabulary_prefixes,
)


class Model:
    """Weightless TDT model: `logits[last token][step]` is the joint output."""

    vocabulary = ("▁ok", "i", "ay", "▁g", "it", "hub", "'s", ".", "<unk>")
    durations = (0, 1, 2)
    max_symbols = 3
    time_ratio = 0.08

    def __init__(self, logits):
        self.logits = logits

    def decoder(self, token, state):
        out = mx.array([[[-1.0 if token is None else float(token[0, 0])]]])
        return out, (out, -out)

    def joint(self, feature, decoder_out):
        return self.logits[int(decoder_out[0, 0, 0])][int(feature[0, 0, 0])].reshape(1, 1, 1, -1)

    def decode(self, greedy, steps):
        """Run ParakeetTDT.decode, which calls decode_greedy as ParakeetSpeech replaces it."""
        self.decode_greedy = functools.partial(greedy, self)
        features = mx.arange(steps, dtype=mx.float32).reshape(1, steps, 1)
        tokens, states = ParakeetTDT.decode(self, features)  # pyright: ignore[reportArgumentType]
        state = states[0] and [part.item() for part in states[0]]
        return [(t.id, t.start, t.duration, t.text) for t in tokens[0]], state


# Joint outputs are tokens, blank, durations; rows are indexed by last token, -1 = none yet.
width, contexts = len(Model.vocabulary) + 1 + len(Model.durations), len(Model.vocabulary) + 2
unboosted = functools.partial(
    server.boosted_greedy, prefixes=server.vocabulary_prefixes(["Oki", "GitHub's"]), bonus=0.0
)
for seed in range(20):
    model = Model(mx.random.normal((contexts, 40, width), key=mx.random.key(seed)))
    upstream = model.decode(ParakeetTDT.decode_greedy, 40)
    assert model.decode(unboosted, 40) == upstream, f"seed {seed}: differs from parakeet-mlx"
print("PASS boosted decoder with no bonus matches parakeet-mlx")

# "▁ok", then "ay" narrowly over "i", then blank; each pick advances one frame.
blank = len(Model.vocabulary)
rows = mx.full((3, width), -20.0)
rows = rows.at[0, 0].add(30).at[1, 2].add(21).at[1, 1].add(20).at[2, blank].add(30)
spoken = Model(mx.broadcast_to(rows.at[:, blank + 2].add(30), (contexts, 3, width)))
for bonus, text in [(0.0, " okay"), (4.5, " oki")]:
    greedy = functools.partial(
        server.boosted_greedy, prefixes=server.vocabulary_prefixes(["Oki"]), bonus=bonus
    )
    heard = "".join(token[3] for token in spoken.decode(greedy, 3)[0])
    assert heard == text, f"bonus {bonus}: {heard!r}, expected {text!r}"
print("PASS boost tips an ambiguous word to the vocabulary spelling")
