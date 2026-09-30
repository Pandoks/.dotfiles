"""Pin the dictation backend's text pipeline and boosted decoder with stub models.

Run: .hammerspoon/dictation/.venv/bin/python .hammerspoon/tests/dictation_test.py
No model load, microphone, network, or Hammerspoon; the cleanup tokenizer comes from the cache.
"""

import functools
import os
import sys
from pathlib import Path
from types import SimpleNamespace

sys.dont_write_bytecode = True
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "dictation"))

import mlx.core as mx
import server  # pyright: ignore[reportMissingImports]
from huggingface_hub import snapshot_download
from mlx_lm.utils import load_tokenizer
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
# config.lua's cleanup tokenizer (the real words Engine.load adds), from files mlx_lm.load caches.
cleanup = snapshot_download(
    "mlx-community/Qwen3.5-2B-MLX-4bit",
    revision="93760be4f1f69842a46bc13dbdc0f19e291392a3",
    allow_patterns=["*.json", "*.jinja"],
)
tokenizer = load_tokenizer(Path(cleanup))
engine.words |= server.whole_words(tokenizer.get_vocab())  # pyright: ignore[reportCallIssue]


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
        complete=lambda messages, raw: cleaned or messages[0]["content"].split("\n\n", 1)[1],
    )
    return engine.process(raw, {})


check(
    "vocabulary fixes names",
    [
        ("ghosty", "Ghostty"),
        ("hammer spoon", "Hammerspoon"),
        ("hammer spon", "Hammerspoon"),
        ("Open hammer spon.", "Open Hammerspoon."),
        ("Open hammer spon's config.", "Open Hammerspoon's config."),
        ("I use neovim daily.", "I use Neovim daily."),
        ("yabay", "yabai"),
        ("Yabe crashed again.", "yabai crashed again."),
        ("Ghost tea is my terminal.", "Ghostty is my terminal."),
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
            "Let's get tacos for lunch.",
            "I switched from Emacs to Neovim.",
            "Pipe it through sort and uniq.",
            "Loki and raycasting.",
            "Check GitHub's API docs.",
            "Open github.com please.",
            "Edit ~/.hammerspoon/init.lua now.",
            "cd ~/.hammerspoon",
            "Open ~/.config/ghostty",
            "Pass --github to it.",
            "Push to git. Hub later.",
            "It has no vim bindings.",
            "I'll hammer soon.",
            "You're cast as the lead.",
        ]
    ],
    lambda text: engine.apply_vocabulary(engine.apply_dictionary(text)),
)
symbols = server.Engine(
    dict(engine.config, vocabulary=["C++", "C#", ".NET", "A/B", "yt-dlp", "José", "naïve"])
)
check(
    "vocabulary skips symbol entries and folds accents",
    [
        ("I got a C on the net.", "I got a C on the net."),
        ("Run ytdlp now.", "Run yt-dlp now."),
        ("Jose is here.", "José is here."),
        ("The nave of the church.", "The nave of the church."),
    ],
    symbols.apply_vocabulary,
)
check(
    "stalls",
    [
        ("Um, so I was, uh, thinking.", "So I was thinking."),
        ("I think, um.", "I think."),
        ("Okay. Um, let's go.", "Okay. Let's go."),
        ("Um... I think so.", "I think so."),
        ("Uh… okay.", "Okay."),
        ("I went to the ER last night.", "I went to the ER last night."),
        ("HM Revenue sent a letter.", "HM Revenue sent a letter."),
        ("Use the .env file.", "Use the .env file."),
        ("Type :wq to save.", "Type :wq to save."),
        ("Uh-huh, sure.", "Uh-huh, sure."),
        ("The umbrella is here.", "The umbrella is here."),
        ("Order it from hm.com today.", "Order it from hm.com today."),
        ("Open ~/um/notes.txt now.", "Open ~/um/notes.txt now."),
        ("Email er@acme.com please.", "Email er@acme.com please."),
        ("Um?", ""),
        ("Okay. Um?", "Okay."),
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
        ("Let's go with option A.", "Let's go with option A."),
        ("Take him to the OR.", "Take him to the OR."),
        ("Oh my!", "Oh my!"),
        ("What if?", "What if?"),
        ("Will do.", "Will do."),
        ("May is warm.", "May is warm."),
        ("Don't forget the milk", "Don't forget the milk"),
        ("Do not merge this", "Do not merge this"),
        ("Don't you think so", "Don't you think so?"),
        ("macOS or Linux?", "macOS or Linux?"),
        ("iPhone or Android?", "iPhone or Android?"),
        ("Um, yabai crashed again.", "yabai crashed again."),
        ("Uh, iPhone sales are up.", "iPhone sales are up."),
        ("Let me check and, uh.", "Let me check and"),
        ("Um, can you check it", "Can you check it?"),
        ("Will do", "Will do"),
        ("Can confirm", "Can confirm"),
        ("Did GitHub go down", "Did GitHub go down?"),
        ("Can you send it,", "Can you send it?"),
        ("How's it going", "How's it going?"),
        ("Is it ready", "Is it ready?"),
        ("Can you check. I think it's broken", "Can you check. I think it's broken"),
        ("Hey John. Can you send me the file", "Hey John. Can you send me the file?"),
        ("What not to do", "What not to do"),
    ],
    dictate,
)
check(
    "end punctuation overrides the cleanup",
    [
        (("I want to go to the", "I want to go to the."), "I want to go to the"),
        (("I want to go to the", "I want to go to."), "I want to go to the"),
        (("What time is it", "What time is it."), "What time is it?"),
        (("Should we pick A", "Should we pick A."), "Should we pick A?"),
        (("Thanks. But", "Thanks."), "Thanks. But"),
        (("Will do", "Will do."), "Will do."),
        (('Did he say "yes"', 'Did he say "yes."'), 'Did he say "yes"?'),
        (("I want to go to the", "I want to go to the,"), "I want to go to the,"),
        (("When I get home", "When I get home."), "When I get home."),
        (("What a great idea", "What a great idea!"), "What a great idea!"),
        (("Do it now", "Do it now."), "Do it now."),
        (("Don't anyone move", "Don't anyone move."), "Don't anyone move."),
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
            ("Can you send me the, can you send me the report?", "Can you send me the report?"),
            ("Send it to the team. Scratch that. Send it to John.", "Send it to John."),
            ("I do not know.", "I don't know."),
        ]
    ],
    lambda pair: dictate(*pair),
)
# Short enough that one unlisted cue or filler exceeds the guard's 2-word slack.
check(
    "guard accepts each cue and filler",
    [
        ((raw, cleaned), cleaned)
        for raw, cleaned in [
            *(
                (f"Open Slack, {cue} GitHub.", "Open GitHub.")
                for cue in ["no,", "wait,", "sorry,", "I mean", "scratch that,", "actually"]
            ),
            *(
                (f"So, {filler}, meet Friday, no, Monday.", "Meet Monday.")
                for filler in ["um", "uh", "erm", "hmm", "like"]
            ),
            ("You know, meet Friday, no, Monday.", "Meet Monday."),
            ("So, meet Friday, I mean Monday.", "Meet Monday."),
        ]
    ],
    lambda pair: dictate(*pair),
)
standup = (
    "I think we should move the standup to ten tomorrow because half the team is out and nobody "
    "has prepared the demo yet."
)
pricing = "Marketing wants a short video explaining the pricing changes."
closed = "Please remind everyone the office is closed Monday."
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
            ("iPhone sales are up.", "The capital of France is Paris."),
            ("Thanks.", "You're welcome!"),
            ("Thanks.", "Thanks. You're welcome!"),
            ("What is the capital of France?", "What is the capital of France? Paris."),
            ("We should not deploy on Friday.", "We should deploy on Friday."),
            ("No, I use Neovim.", "No, I use Vim."),
            (
                "Tell me a joke.",
                "Tell me a joke. Why did the chicken cross the road? To get to the other side.",
            ),
            ("Send the report to the team.", "Send the report to the entire marketing team today."),
            (standup, f"{standup} Domain vocabulary: {', '.join(engine.glossary())}."),
            (f"{standup} {pricing} {closed}", f"{standup} {closed}"),
        ]
    ],
    lambda pair: dictate(*pair),
)
check(
    "any script's letters or digits count as speech",
    [
        ("Привет, как дела?", "Привет, как дела?"),
        ("你好，今天天气很好。", "你好，今天天气很好。"),
        ("ㅋㅋㅋ 진짜 웃겨", "ㅋㅋㅋ 진짜 웃겨"),
        ("42", "42"),
        ("...", ""),
        ("—–…", ""),
    ],
    dictate,
)
parakeet = server.ParakeetSpeech("stub", "0" * 40, 0.0)
parakeet.model = SimpleNamespace(transcribe=lambda wav, chunk_duration: SimpleNamespace(text=wav))
check(
    "Parakeet drops special pieces and rare symbol runs",
    [
        ("<unk> ΨΨΨ", ""),
        (" Hello <unk> there ", "Hello there"),
        ("N<|eo|>vim<|endoftext|>", "Nvim"),
        ("Привет", "Привет"),
    ],
    lambda text: parakeet.transcribe(text, []),
)
check(
    "vocabulary prefixes",
    [
        (["Oki"], {"o", "ok", "oki"}),
        (["GitHub's"], {"g", "gi", "git", "gith", "githu", "github", "github'", "github's"}),
        (["hammer spoon", "yt-dlp", "Node.js", "<unk>", "<|en|>", " "], set()),
    ],
    server.vocabulary_prefixes,
)


class Model:
    """Weightless TDT model: `logits[last token][step]` is the joint output."""

    vocabulary = ("▁ok", "i", "ay", "▁g", "it", "hub", "'s", "▁me", "▁M", "e", ".")
    vocabulary += ("<unk>", "<|eo|>")  # special pieces
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

# Each frame scores pieces over -20 and each pick advances one frame; a blank frame ends it.
blank = len(Model.vocabulary)


def speak(frames, words, bonus):
    """Boosted decoding of `frames` ({piece: score}) with `words` listed."""
    rows = mx.full((len(frames) + 1, width), -20.0).at[-1, blank].add(30).at[:, blank + 2].add(30)
    for step, frame in enumerate(frames):
        for piece, score in frame.items():
            rows = rows.at[step, Model.vocabulary.index(piece)].add(score)
    greedy = functools.partial(
        server.boosted_greedy, prefixes=server.vocabulary_prefixes(words), bonus=bonus
    )
    tokens = Model(mx.broadcast_to(rows, (contexts, *rows.shape))).decode(greedy, len(frames) + 1)
    return "".join(token[3] for token in tokens[0])


check(
    "boost tips an ambiguous word to the vocabulary spelling, never on its first letter",
    [
        (([{"▁ok": 30}, {"ay": 21, "i": 20}], ["Oki"], 0.0), " okay"),
        (([{"▁ok": 30}, {"ay": 21, "i": 20}], ["Oki"], 4.5), " oki"),
        # A first-letter bonus would flip casing and splitting: "▁me" -> "▁M" "e".
        (([{"▁me": 21, "▁M": 20}], ["mise"], 4.5), " me"),
        # The bonus is per letter: two letters outweigh what one could not (20 + 9 > 26).
        (([{"▁g": 30}, {"it": 20, "e": 26}], ["GitHub"], 4.5), " git"),
        # Special pieces spell nothing: v3's "<|eo|>" must not outscore "e" in "Meow".
        (([{"▁M": 30}, {"e": 20, "<|eo|>": 16}], ["Meow"], 4.5), " Me"),
    ],
    lambda case: speak(*case),
)
