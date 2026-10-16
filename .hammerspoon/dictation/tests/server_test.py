"""The dictation backend's text pipeline, protocol, and boosted decoder, with stub models.

Run: .hammerspoon/dictation/.venv/bin/python .hammerspoon/dictation/tests/server_test.py
No model load, microphone, or Hammerspoon; only the cleanup tokenizer's small files are fetched,
once, when they are not cached yet.
"""

import functools
import itertools
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

sys.dont_write_bytecode = True
os.environ["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import mlx.core as mx
import models  # pyright: ignore[reportMissingImports]
import server  # pyright: ignore[reportMissingImports]
from huggingface_hub import snapshot_download
from huggingface_hub.errors import LocalEntryNotFoundError
from mlx_lm.utils import load_tokenizer
from parakeet_mlx import ParakeetTDT

# config.lua's default vocabulary and dictionary.
engine = server.Engine(
    {
        "stt": {"backend": "parakeet-mlx", "model": "stub", "revision": "0" * 40},
        "cleanup": {"enabled": False},
        "vocabulary": ["yabai", "Raycast", "Hammerspoon", "Ghostty", "mise", "Neovim", "rtorrent"]
        + ["macOS", "GitHub", "Slack", "Oki", "Uniqlo"],
        "dictionary": {
            "Raycast": ["ray cast", "re cast", "ray cost"],
            "yabai": ["yabe", "ya bye", "yah bye"],
            "Hammerspoon": ["hammer spoon", "hammers spoon"],
            "Ghostty": ["ghosty", "ghost tea", "ghost e"],
            "mise": ["meez", "mees"],
            "Neovim": ["neo vim", "neo them"],
            "rtorrent": ["r torrent"],
            "macOS": ["mac os", "mac o s"],
            "GitHub": ["git hub"],
            "Uniqlo": ["unicolo", "uni clo", "uni klo", "uni clow", "une clo", "une klo"],
        },
    }
)
# config.lua's cleanup tokenizer (the real words Engine.load adds), from files mlx_lm.load caches.
tokenizer_files = {
    "repo_id": "mlx-community/Qwen3.5-2B-MLX-4bit",
    "revision": "93760be4f1f69842a46bc13dbdc0f19e291392a3",
    "allow_patterns": ["*.json", "*.jinja"],
}
try:
    cleanup = snapshot_download(**tokenizer_files, local_files_only=True)
except LocalEntryNotFoundError:  # a fresh checkout: a few MB, not the model
    cleanup = snapshot_download(**tokenizer_files)
tokenizer = load_tokenizer(Path(cleanup))
stub = {"model": "stub", "revision": "0" * 40, "maxTokens": 400}
with mock.patch("mlx_lm.load", lambda *_, **__: (None, tokenizer)):
    (loaded := models.MlxLm(stub)).load()
engine.words |= loaded.words


def check(name, cases, function):
    for given, expected in cases:
        got = function(given)
        assert got == expected, f"{name}: {given!r} -> {got!r}, expected {expected!r}"
    print(f"PASS {name}")


def dictate(raw, cleaned=None, numbers=False):
    """Engine.process on `raw` as heard; the cleanup returns `cleaned` (default: its input), and
    None means the guard rejected it. Number words stay words unless `numbers`."""
    engine.speech = SimpleNamespace(transcribe=lambda wav, hint: wav, boost=0)
    engine.cleaner = SimpleNamespace(
        prompt="prompt",
        complete=lambda messages, raw: cleaned or messages[0]["content"].split("\n\n", 1)[1],
    )
    try:
        if numbers:
            return engine.process(raw, {})
        with mock.patch.object(server, "write_numbers", lambda text, names: text):
            return engine.process(raw, {})
    except server.Rewritten:
        return None


def serve(script, takes, config="{}"):
    """server.main() after `script` (stubs), fed `takes`; its stdout events and its stderr."""
    run = subprocess.run(
        [
            sys.executable,
            "-c",
            f"import sys, server\n{script}\nsys.argv[1:] = ['--config', {config!r}]\nserver.main()",
        ],
        input="".join(json.dumps(take) + "\n" for take in takes),
        capture_output=True,
        text=True,
        cwd=Path(server.__file__).parent,
        timeout=120,
        check=False,
    )
    return [json.loads(line) for line in run.stdout.splitlines()], run.stderr


check(
    "vocabulary fixes names",
    [
        ("ghosty", "Ghostty"),
        ("hammer spoon", "Hammerspoon"),
        ("I use neovim daily.", "I use Neovim daily."),
        ("yabay", "yabai"),
        ("Yabe crashed again.", "yabai crashed again."),
        ("Ghost tea is my terminal.", "Ghostty is my terminal."),
        ("oki", "Oki"),
        ("slack", "Slack"),
        ("slack—", "Slack—"),
        ("(ghosty's)", "(Ghostty's)"),
    ],
    lambda text: engine.spell(text, {}),
)
check(
    "vocabulary keeps real words, possessives, domains, and paths",
    [
        (text, text)
        for text in [
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
            "Mail ghosty@example.com now.",
            "Mail ghosty+tag@example.com now.",
            "Open C:\\ghosty now.",
            "Open ghosty\\x now.",
            "Set KEY=ghosty now.",
            "Pull ghosty:latest now.",
            "Echo ${ghosty} now.",
            "Ping me at me@ghosty.",
            "Edit ~/.hammerspoon/init.lua now.",
            "cd ~/.hammerspoon",
            "Open ~/.config/ghostty",
            "Pass --github to it.",
            "Push to git. Hub later.",
            "It has no vim bindings.",
            "I'll hammer soon.",
            "You're cast as the lead.",
            "I have two Macs at home.",
        ]
    ],
    lambda text: engine.spell(text, {}),
)
symbols = server.Engine(
    dict(
        engine.config,
        vocabulary=["C++", "C#", ".NET", "A/B", "yt-dlp", "José", "naïve", "Node.js", "O'Reilly"]
        + ["Shell", "Visual Studio Code", "Москва", "Київ"],
    )
)
check(
    "vocabulary skips symbol entries, folds accents, and matches punctuated words exactly",
    [
        ("Install node.js now.", "Install Node.js now."),
        ("Use YT-DLP to grab it.", "Use yt-dlp to grab it."),
        ("Read o'reilly's book.", "Read O'Reilly's book."),
        ("She'll be fine.", "She'll be fine."),
        ("Open visual studio code now.", "Open Visual Studio Code now."),
        ("Open ~/visual studio code/config now.", "Open ~/visual studio code/config now."),
        ("I got a C on the net.", "I got a C on the net."),
        ("Run ytdlp now.", "Run yt-dlp now."),
        ("Jose is here.", "José is here."),
        ("JOSÉ is here.", "José is here."),
        ("From МОСКВА to КИЇВ.", "From Москва to Київ."),
        ("The nave of the church.", "The nave of the church."),
    ],
    lambda text: symbols.spell(text, {}),
)
latex = server.Engine(dict(engine.config, dictionary={"\\LaTeX": ["latex"], "\\frac": ["frac"]}))
check(
    "dictionary inserts its spelling as written",
    [("Write it in latex with frac.", "Write it in \\LaTeX with \\frac.")],
    lambda text: latex.spell(text, {}),
)
# Cleanup off: no tokenizer words, so only macOS's word list keeps real words.
off = server.Engine(engine.config)
off.speech = SimpleNamespace(transcribe=lambda wav, hint: wav, boost=0)
check(
    "cleanup off keeps inflected real words and fixes spellings",
    [
        ("I missed the bus.", "I missed the bus."),
        ("She misses her family.", "She misses her family."),
        ("Torrents of rain.", "Torrents of rain."),
        ("Ghost tea is my terminal.", "Ghostty is my terminal."),
        ("I want three things.", "I want 3 things."),
    ],
    lambda text: off.process(text, {}),
)
check(
    "number words become digits, with commas and decimal points",
    [
        (
            "I want three things at once with three sub-agents.",
            "I want 3 things at once with 3 sub-agents.",
        ),
        ("It costs one thousand two hundred forty dollars.", "It costs 1,240 dollars."),
        ("We shipped seven hundred and fifty units.", "We shipped 750 units."),
        ("We need a hundred million ARR.", "We need 100 million ARR."),
        ("Two point five million people.", "2.5 million people."),
        ("The budget is $3.2 million.", "The budget is $3.2 million."),
        ("Set it to zero point zero five.", "Set it to 0.05."),
        ("Train it for a hundred thousand steps.", "Train it for 100,000 steps."),
        ("A million things went wrong.", "1 million things went wrong."),
        ("Back in twenty twenty six.", "Back in 2026."),
        ("One eighty two merged.", "182 merged."),
        ("This is the twenty first time.", "This is the 21st time."),
        ("It's a three-year-old laptop.", "It's a 3-year-old laptop."),
        ("Pick one or two options.", "Pick 1 or 2 options."),
        ("Meet at three thirty.", "Meet at 3:30."),
        ("Let's meet at 3.30.", "Let's meet at 3:30."),
        ("The market closed at one point fifteen.", "The market closed at 1.15."),
        ("We raised at two point fifteen million dollars.", "We raised at 2.15 million dollars."),
        ("We raised at 2.15 million dollars.", "We raised at 2.15 million dollars."),
        ("Let's meet between 3.30 and 4.30 p.m.", "Let's meet between 3:30 and 4:30 p.m."),
        ("At 3.30 we have standup.", "At 3:30 we have standup."),
        ("The call is 4.45 pm.", "The call is 4:45 pm."),
        ("Version one point two point three.", "Version 1.2.3."),
        ("Set it to zero point twenty five.", "Set it to 0.25."),
        ("This is the one hundred and twenty first time.", "This is the 121st time."),
        ("This is the one hundred and first time.", "This is the 101st time."),
        ("Music from the nineteen eighties.", "Music from the 1980s."),
        ("A million people came.", "1 million people came."),
        ("The call is three thirty pm.", "The call is 3:30 pm."),
        # One alone, idioms, and readings that are not one number stay words.
        ("One of the ideas was a trinket.", "One of the ideas was a trinket."),
        ("No one came to the meeting.", "No one came to the meeting."),
        ("It was a one-off.", "It was a one-off."),
        ("It's a billion dollar company.", "It's a billion dollar company."),
        ("This is the third time.", "This is the third time."),
        ("It's three thirty.", "It's three thirty."),
        ("We're open twenty four seven.", "We're open twenty four seven."),
        ("Split it fifty-fifty.", "Split it fifty-fifty."),
        ("Hundreds of users.", "Hundreds of users."),
        ("Multiply that by 1.15.", "Multiply that by 1.15."),
        ("The rate is at 3.30 percent.", "The rate is at 3.30 percent."),
        ("One billion two hundred million people.", "1,200,000,000 people."),
        ("It grew twenty-five point five percent.", "It grew 25.5 percent."),
        ("We started in two thousand nineteen.", "We started in 2019."),
        ("We have two thousand nineteen users.", "We have 2,019 users."),
        ("It's a fifty fifty chance.", "It's a fifty fifty chance."),
        ("The page returned four oh four.", "The page returned 404."),
        ("Meet at twelve oh one.", "Meet at 12:01."),
        ("Set the rate to one point oh five.", "Set the rate to 1.05."),
        ("Room one oh one point five.", "Room 101.5."),
        ("Call at eight oh oh tomorrow.", "Call at 8:00 tomorrow."),
        ("The server returned five oh oh.", "The server returned 500."),
        ("Productivity is at 3.30 tasks per hour.", "Productivity is at 3.30 tasks per hour."),
        ("Use port eight oh eight oh.", "Use port 8080."),
        ("Dial two oh two point oh five oh.", "Dial 202.050."),
        ("The site throws four oh four a lot.", "The site throws 404 a lot."),
        ("The meeting at three thirty was cancelled.", "The meeting at 3:30 was cancelled."),
        ("Nineteen ninety nine was a great year.", "1999 was a great year."),
        ("Raise the limit to two thousand.", "Raise the limit to 2,000."),
        ("No one, two people came.", "No one, 2 people came."),
        ("At one point, five people left.", "At one point, 5 people left."),
        ("The server returned a five-oh-three.", "The server returned a 503."),
        ("Count one, two.", "Count 1, 2."),
        ("Do it in this order: one, two.", "Do it in this order: 1, 2."),
        ("The steps one, two, and three are done.", "The steps 1, 2, and 3 are done."),
        ("We got a million hits.", "We got 1 million hits."),
        ("We grew a lot during two thousand.", "We grew a lot during 2000."),
        ("One point two hundred thousand users.", "One point two hundred thousand users."),
        ("There were one point five thousand users.", "There were 1.5 thousand users."),
        ("The two hundredth item.", "The 200th item."),
        ("The one hundred and fiftieth day.", "The 150th day."),
        ("One hundredth of a second.", "One hundredth of a second."),
        ("At three thirty students arrived.", "At three thirty students arrived."),
        ("The meeting at three thirty starts soon.", "The meeting at 3:30 starts soon."),
        ("We started in two thousand.", "We started in 2000."),
        ("Count one, two, three.", "Count 1, 2, 3."),
        ("It's priced at 2.50 each.", "It's priced at 2.50 each."),
        ("Around three fifty people came.", "Around three fifty people came."),
        ("I have thirteen twenty dollar bills.", "I have thirteen twenty dollar bills."),
        ("I watched Ocean's Eleven.", "I watched Ocean's Eleven."),
        ("Capped attendance at one twenty people.", "Capped attendance at one twenty people."),
        ("Twenty One Pilots released a song.", "Twenty One Pilots released a song."),
        ("Seven Samurai is great.", "Seven Samurai is great."),
        # Names keep theirs: a path, a dotted name, a glossary entry.
        ("Edit ~/two/three.txt now.", "Edit ~/two/three.txt now."),
        ("Use three.js for it.", "Use three.js for it."),
        ("Read fifty shades today.", "Read fifty shades today."),
    ],
    lambda text: server.write_numbers(text, ["Fifty Shades"]),
)
# No run of number words, joins, and endings raises: a take always comes back.
words = ["one", "twenty", "hundred", "and", "point", "first", "eighties", "a", "thirty", "pm"]
words += ["million", "oh", "twenty-five", ","]
for size in (2, 3, 4):
    for run in itertools.product(words, repeat=size):
        server.write_numbers(" ".join(run) + ".", ())
print("PASS no number run raises")
check(
    "a cleaned take gets its numbers as digits",
    [(("Um, send three copies.", None), "Send 3 copies.")],
    lambda pair: dictate(*pair, numbers=True),
)
check(
    "stalls",
    [
        ("Um, so I was, uh, thinking.", "So I was thinking."),
        ("I think, um.", "I think."),
        ("Okay. Um, let's go.", "Okay. Let's go."),
        ("Um... I think so.", "I think so."),
        ("Uh… okay.", "Okay."),
        ("Erm, I think so.", "I think so."),
        ("I was, er, thinking.", "I was thinking."),
        ("Hm, okay.", "Okay."),
        ("Hmm, okay.", "Okay."),
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
        ("I think, um .", "I think."),
        ("git add .", "git add ."),
        ("Line one.\n\nUh, line two.", "Line one.\n\nLine two."),
        ("Hi Anna,\n\nUm, I wanted to check in.", "Hi Anna,\n\nI wanted to check in."),
        ("Okay. Um\n\nNext paragraph.", "Okay.\n\nNext paragraph."),
        # Opening a quote or bracket too; a closing '"' does not open one.
        ('She said, "Um, I\'m not sure."', 'She said, "I\'m not sure."'),
        ("She said, “uh, maybe.”", "She said, “maybe.”"),
        ('He said "fine" um.', 'He said "fine".'),
        *(
            (f"{o}Yes.{c} Um, okay.", f"{o}Yes.{c} Okay.")
            for o, c in ['""', "''", "“”", "‘’", "()", "[]"]
        ),
        *((f"{o}Um, maybe.{c}", f"{o}Maybe.{c}") for o, c in ["“”", "‘’", "()", "[]"]),
        ('("Um, maybe.")', '("Maybe.")'),
        ('["Um, maybe."]', '["Maybe."]'),
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
        ("I'd love to.", "I'd love to."),
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
        ("macOS or Linux?", "macOS or Linux?"),
        ("iPhone or Android?", "iPhone or Android?"),
        ("Um, yabai crashed again.", "yabai crashed again."),
        ("Uh, iPhone sales are up.", "iPhone sales are up."),
        ("Let me check and, uh.", "Let me check and"),
        ("Um, can you check it?", "Can you check it?"),
    ],
    dictate,
)
check(
    "end punctuation overrides the cleanup",
    [
        (("I want to go to the", "I want to go to the."), "I want to go to the"),
        (("Send it to", "Send it to."), "Send it to"),
        (
            ("Let me know what you come up with", "Let me know what you come up with."),
            "Let me know what you come up with.",
        ),
        (('He said, "I want the"', 'He said, "I want the."'), 'He said, "I want the"'),
        (("Can you send me the", "Can you send me the?"), "Can you send me the"),
        (("I want to go to the", "I want to go to the!"), "I want to go to the"),
        (("I want to go to the", "I want to go to."), "I want to go to the"),
        (("I want to go to the", "I want to go."), "I want to go to the"),
        (("You're coming?", "You're coming."), "You're coming?"),
        (("Like, you're coming?", "You're coming."), "You're coming?"),
        (("What time is it?", "What time is it."), "What time is it?"),
        (("Should we pick A?", "Should we pick A."), "Should we pick A?"),
        (("Thanks. But", "Thanks."), "Thanks. But"),
        (("Is it ready? And", "Is it ready?"), "Is it ready? And"),
        (("Stop! And", "Stop!"), "Stop! And"),
        (("Will do", "Will do."), "Will do."),
        (("I want to go to the", "I want to go to the,"), "I want to go to the,"),
        (("What a great idea", "What a great idea!"), "What a great idea!"),
        (("Can you believe it?", "Can you believe it?!"), "Can you believe it?!"),
        (("Can you believe it?!", "Can you believe it."), "Can you believe it?"),
        (("I want to go to the", "I want to go to the…"), "I want to go to the"),
        (("Let me check and…", "Let me check and."), "Let me check and"),
        (("I want to go to the", "I want to go to the—"), "I want to go to the"),
        (("He said I want the", 'He said, "I want the."'), 'He said, "I want the"'),
        (("Did he say yes", 'Did he say "yes?"'), 'Did he say "yes?"'),
        # A cut word comes back after the comma or colon said before it, inside closing quotes.
        (("Send it to John, and", "Send it to John."), "Send it to John, and"),
        (("We need eggs, milk, and", "We need eggs, milk."), "We need eggs, milk, and"),
        (("Send it to John, and the", "Send it to John."), "Send it to John, and the"),
        (("Send it to John and", "Send it to John,"), "Send it to John, and"),
        (("Send it to John, and", "Send it to John,"), "Send it to John, and"),
        (("The plan is simple: the", "The plan is simple."), "The plan is simple: the"),
        (('He said "yes", and', 'He said "yes."'), 'He said "yes", and'),
        (('He said "yes." And', 'He said "yes."'), 'He said "yes." And'),
        # The cleanup's capitals and curly marks: "API" matches "api", "it’s" matches "it's".
        (("Check the api and", "Check the API."), "Check the API and"),
        (("I think it's the", "I think it’s."), "I think it’s the"),
        (("He said I want the", "He said, “I want the.”"), "He said, “I want the”"),
        (("Did he say yes", "Did he say “yes?”"), "Did he say “yes?”"),
        (("Send it to the dogs and", "Send it to the dogs’."), "Send it to the dogs’ and"),
        (("Don't you think so?", "Don’t you think so."), "Don’t you think so?"),
        # A straight ' after an end mark closes a quote too; one inside a word opens none.
        (("Did he say yes", "Did he say 'yes?'"), "Did he say 'yes?'"),
        (('"Can you help?"', '"Can you help."'), '"Can you help?"'),
        (("It's for the dogs and", "It's for the dogs'."), "It's for the dogs' and"),
        (("He said 'yes', and", "He said 'yes'."), "He said 'yes', and"),
        (("He said ‘yes’, and", "He said ‘yes.’"), "He said ‘yes’, and"),
        (("He said 'yes.' And", "He said 'yes.'"), "He said 'yes.' And"),
        (("In the '90s, the kids' and", "In the '90s, the kids'."), "In the '90s, the kids' and"),
        (
            ("He asked me. Are you coming?", "He asked me. 'Are you coming.'"),
            "He asked me. 'Are you coming?'",
        ),
        # The speech model's '?' is kept, not one it never put: a retracted question.
        (("Is it ready? No wait, just ship it.", "Just ship it."), "Just ship it."),
        (
            ("Can you send it to John, no wait, to Jane?", "Can you send it to Jane."),
            "Can you send it to Jane?",
        ),
    ],
    lambda pair: dictate(*pair),
)
check(
    "the guard accepts left-out stalls, fillers, repeats, and self-corrections, and nothing else",
    [
        ((raw, out), False)
        for raw, out in [
            ("Um, log in to GitHub and, uh, open the repo.", "Log in to GitHub and open the repo."),
            ("The issue is, yeah, nobody tested it.", "The issue is nobody tested it."),
            (
                "Um, so, do you want pasta or, or, or pizza for dinner?",
                "Do you want pasta or pizza for dinner?",
            ),
            ("Right, right, that's right.", "Right, that's right."),
            ("Turn it on. On Friday.", "Turn it on Friday."),
            (
                "We need to order twenty five more chairs.",
                "We need to order twenty-five more chairs.",
            ),
            ("We messed up, I'm sorry, we rushed it.", "We messed up, I'm sorry we rushed it."),
            (
                "Please print ten copies of the report, sorry, twelve.",
                "Please print twelve copies of the report.",
            ),
            (
                "Schedule it for next Tuesday at ten, no wait, Wednesday.",
                "Schedule it for Wednesday at ten.",
            ),
            ("Book two double rooms, no wait, a suite.", "Book a suite."),
            ("The review is Thursday. Uh, sorry, Friday.", "The review is Friday."),
            ("Run npm install, no wait, run npm ci.", "Run npm ci."),
        ]
    ]
    + [
        ((raw, out), True)
        for raw, out in [
            ("You know the drill.", "The drill."),
            ("It's always been like that.", "It's always been that."),
            ("I ordered the blue one, not the red one.", "I ordered the blue one."),
            ("Delete all files except logs.", "Delete all files."),
            ("Include the tests.", "Exclude the tests."),
            ("Send 15 dollars.", "Send 50 dollars."),
            ("Turn the volume up, sorry, down.", "Turn the volume up."),
            ("Send it tomorrow, I'm sorry, tonight.", "Send it tonight tomorrow."),
            ("We're full, sorry, thank you.", "We're full, thank you."),
            ("I broke it, sorry, my mistake.", "I broke it, sorry."),
            ("Ship 4 units to Denver and 6, sorry, 8 to Austin.", "Ship 8 units to Austin."),
            ("Is it ready? No wait, is it done?", "Is it ready?"),
            (
                "The meeting is at four, actually, can we push it to five?",
                "The meeting is at five.",
            ),
            ("You know what I mean.", "What I mean is..."),
        ]
    ],
    lambda pair: server.looks_rewritten(*pair),
)
check(
    "any script's letters or digits count as speech",
    [
        ("Привет, как дела?", "Привет, как дела?"),
        ("你好，今天天气很好。", "你好，今天天气很好。"),
        ("42", "42"),
        ("...", ""),
        ("—–…", ""),
    ],
    dictate,
)
# An empty cleanup (no coherent speech, as the prompt asks) types nothing, and the result carries
# what was heard so Hammerspoon keeps it.
engine.speech = SimpleNamespace(transcribe=lambda wav, hint: "Mmm wha blah", boost=0)
engine.cleaner = SimpleNamespace(prompt="prompt", complete=lambda messages, raw: "")
assert engine.process("take.wav", {}) == "" and engine.heard == "Mmm wha blah", engine.heard
print("PASS an empty cleanup types nothing and keeps what was heard")

# Only protocol lines reach stdout: a library that prints, on load or during a take, goes to stderr.
chatty = """
class Chatty:
    def __init__(self, config):
        print("[WARNING] Generating with a model that requires 9000 MB")
        self.heard = None
    def load(self):
        print("loading...")
    def process(self, wav, request):
        import os
        print("[WARNING] again")
        os.write(1, b"native chatter\\n")  # as native code would, past sys.stdout
        return "ok"
server.Engine = Chatty
"""
events, stderr = serve(chatty, [{"id": 1, "wav": "x.wav"}])
assert events == [{"event": "ready"}, {"event": "final", "id": 1, "text": "ok", "heard": None}]
assert "native chatter" in stderr, stderr
print("PASS a library that prints cannot corrupt the protocol")
# A failed load reports why before it exits, and is never ready.
events, stderr = serve("", [], config='{"stt": {"backend": "nope"}}')
assert [e["event"] for e in events] == ["error"] and "id" not in events[0], events
assert "nope" in events[0]["msg"] and "Traceback" in stderr, (events, stderr)
print("PASS a failed load reports an error and never ready")
# A rewritten take fails with what was heard and no traceback; a take whose speech fails reports
# nothing heard, not the last take's: Hammerspoon would keep that text as this take's.
takes = """
from types import SimpleNamespace
heard = iter(["Send fifteen dollars.", "Send it."])
def transcribe(wav, hint):
    for text in heard:
        return text
    raise RuntimeError("the speech model failed")
class Stub(server.Engine):
    def __init__(self, config):
        self.config, self.heard = config, None
        self.speech = SimpleNamespace(transcribe=transcribe, boost=0)
        self.cleaner = SimpleNamespace(prompt="p", complete=lambda m, raw: raw.replace("fifteen", "50"))
    def load(self):
        pass
server.Engine = Stub
"""
events, stderr = serve(takes, [{"id": i, "wav": "x.wav", "app": "x"} for i in (1, 2, 3)])
assert [e["event"] for e in events] == ["ready", "error", "final", "error"], (events, stderr)
assert events[1]["heard"] == "Send fifteen dollars." and "rewrote" in events[1]["msg"], events
assert events[2] == {"event": "final", "id": 2, "text": "Send it.", "heard": "Send it."}, events
assert events[3]["heard"] is None and "speech model failed" in events[3]["msg"], events
assert stderr.count("Traceback") == 1, stderr
print("PASS a failed take reports what was heard, and only a bug's traceback")

# The prompt opens and closes an empty think block; the model may close it again, and only what
# follows is the reply.
cleaner = models.MlxLm(stub)
cleaner.llm, cleaner.tokenizer = None, tokenizer
with mock.patch("mlx_lm.generate", return_value="Fix the bug.</think>\n\nFix the bug."):
    reply = cleaner.complete([{"role": "user", "content": "Fix the bug."}], "Fix the bug.")
assert reply == "Fix the bug.", reply
print("PASS a stray closing think tag leaves only the reply")


def load_adapter(files):
    """MlxLm.load with an adapter download holding `files`: its prompt, or the failure."""
    with tempfile.TemporaryDirectory() as folder:
        for name, text in files.items():
            Path(folder, name).write_text(text)
        cleaner = models.MlxLm(dict(stub, adapter="stub/adapter", adapterRevision="0" * 40))
        with (
            mock.patch("huggingface_hub.snapshot_download", lambda *_, **__: folder),
            mock.patch("mlx_lm.load", lambda *_, **__: (None, SimpleNamespace(get_vocab=dict))),
        ):
            try:
                cleaner.load()
            except (ValueError, FileNotFoundError) as error:
                return type(error).__name__
        return cleaner.prompt


check(
    "an adapter loads only with the prompt it was trained on",
    [
        ({"system_v2.txt": "Clean it.\n"}, "Clean it."),
        ({}, "FileNotFoundError"),
        ({"system_v2.txt": " \n"}, "ValueError"),
    ],
    load_adapter,
)
parakeet = models.Parakeet({"model": "stub", "revision": "0" * 40})
parakeet.model = SimpleNamespace(transcribe=lambda wav, chunk_duration: SimpleNamespace(text=wav))
check(
    "Parakeet drops special pieces and rare symbol runs",
    [
        ("<unk> ΨΨΨ", ""),
        (" Hello <unk> there ", "Hello there"),
        ("N<|eo|>vim<|endoftext|>", "Nvim"),
        ("Привееет", "Привееет"),
        ("It cost 1000 dollars...", "It cost 1000 dollars..."),
        ("Use <div> here.", "Use <div> here."),
    ],
    lambda text: parakeet.transcribe(text, []),
)
check(
    "vocabulary prefixes",
    [
        (["GitHub's"], {"g", "gi", "git", "gith", "githu", "github", "github'", "github's"}),
        (["hammer spoon", "yt-dlp", "Node.js", "<unk>", "<|en|>", " "], set()),
    ],
    models.prefixes,
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


def boosted(prefixes, bonus):
    return lambda model, *args, **kwargs: ParakeetTDT.decode_greedy(
        models.Boosted(model, prefixes, bonus),
        *args,
        **kwargs,  # pyright: ignore
    )


unboosted = boosted(models.prefixes(["Oki", "GitHub's"]), 0.0)
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
    greedy = boosted(models.prefixes(words), bonus)
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
        # Punctuation ends the word: "ok." never continues into "oki".
        (([{"▁ok": 30}, {".": 30}, {"i": 20, "▁me": 21}], ["Oki"], 4.5), " ok. me"),
    ],
    lambda case: speak(*case),
)
# Unboosted and boosted Parakeet decodes of TTS takes (`say -v Albert`, `-v Daniel`, ...).
check(
    "a boosted word is kept only where it spells a vocabulary word",
    [
        (
            (
                "Test testing, what do you think of the older?",
                "Test testing, what do you think of the old hammers?",
            ),
            "Test testing, what do you think of the older?",
        ),
        (
            ("The morning mist was thick.", "The morning mis was thick."),
            "The morning mist was thick.",
        ),
        (
            ("The Union vote is destroyed.", "The uni uni vote is destroyed."),
            "The Union vote is destroyed.",
        ),
        (
            ("Okie said she would come later.", "Oki said she would come later."),
            "Oki said she would come later.",
        ),
        (
            ("Ghost T renders the fonts really well.", "GhostT renders the fonts really well."),
            "Ghostty renders the fonts really well.",
        ),
        (
            (
                "Test. Testing what do you think of NeoVim?",
                "Test. Testing what do you think of neovim?",
            ),
            "Test. Testing what do you think of Neovim?",
        ),
        (("", "Oki."), "Oki."),
        (("", "Hammers."), ""),
    ],
    lambda case: engine.named_only(*case, {}),
)
# Boosting decodes the take twice, once with no vocabulary to boost.
boosting = models.Parakeet({"model": "stub", "revision": "0" * 40, "boost": 4.5})
boosting.model = SimpleNamespace(
    transcribe=lambda wav, chunk_duration: SimpleNamespace(
        text=wav[bool(boosting.model.__dict__.get("decode_greedy"))]
    )
)
engine.speech, engine.cleaner = boosting, None
check(
    "boosting keeps the unboosted decode unless a vocabulary word is gained",
    [
        (
            ("What do you think of the older?", "What do you think of the old hammers?"),
            "What do you think of the older?",
        ),
        (("Ask okay if it works.", "Ask Oki if it works."), "Ask Oki if it works."),
    ],
    lambda wav: engine.process(wav, {}),
)
