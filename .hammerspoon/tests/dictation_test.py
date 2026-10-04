"""Pin the dictation backend's text pipeline and boosted decoder with stub models.

Run: .hammerspoon/dictation/.venv/bin/python .hammerspoon/tests/dictation_test.py
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
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "dictation"))

import mlx.core as mx
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
            "yabai": ["yabe", "ya bye", "yah bye"],
            "Hammerspoon": ["hammer spoon", "hammers spoon"],
            "Ghostty": ["ghosty", "ghost tea", "ghost e"],
            "mise": ["meez", "mees"],
            "Neovim": ["neo vim", "neo them"],
            "rtorrent": ["r torrent"],
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
engine.words |= server.whole_words(tokenizer.get_vocab())  # pyright: ignore[reportCallIssue]


def check(name, cases, function):
    for given, expected in cases:
        got = function(given)
        assert got == expected, f"{name}: {given!r} -> {got!r}, expected {expected!r}"
    print(f"PASS {name}")


def dictate(raw, cleaned=None, numbers=False):
    """Engine.process on `raw` as heard; the cleanup returns `cleaned` (default: its input).
    Number words stay words unless `numbers`: the guard's checks see what was said."""
    engine.speech = SimpleNamespace(transcribe=lambda wav, hint: wav)
    engine.cleaner = SimpleNamespace(
        frozen_prompt="prompt",
        complete=lambda messages, raw: cleaned or messages[0]["content"].split("\n\n", 1)[1],
    )
    try:
        if numbers:
            return engine.process(raw, {})
        with mock.patch.object(engine, "write_numbers", lambda text, names: text):
            return engine.process(raw, {})
    except server.Rewritten:  # the guard fails a rewritten take: None
        return None


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
        ("slack—", "Slack—"),
        ("(ghosty's)", "(Ghostty's)"),
    ],
    lambda text: engine.apply_vocabulary(engine.apply_dictionary(text), {}),
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
    lambda text: engine.apply_vocabulary(engine.apply_dictionary(text), {}),
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
    lambda text: symbols.apply_vocabulary(text, {}),
)
latex = server.Engine(dict(engine.config, dictionary={"\\LaTeX": ["latex"], "\\frac": ["frac"]}))
check(
    "dictionary inserts its spelling as written",
    [("Write it in latex with frac.", "Write it in \\LaTeX with \\frac.")],
    latex.apply_dictionary,
)
# Cleanup off: no tokenizer words, so only macOS's word list keeps real words.
off = server.Engine(engine.config)
off.speech = SimpleNamespace(transcribe=lambda wav, hint: wav)
check(
    "cleanup off keeps inflected real words and fixes spellings",
    [
        ("I missed the bus.", "I missed the bus."),
        ("She misses her family.", "She misses her family."),
        ("Torrents of rain.", "Torrents of rain."),
        ("Ghost tea is my terminal.", "Ghostty is my terminal."),
        ("Open hammer spon.", "Open Hammerspoon."),
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
    lambda text: server.Engine.write_numbers(text, ["Fifty Shades"]),
)
# No run of number words, joins, and endings raises: a take always comes back.
words = ["one", "twenty", "hundred", "and", "point", "first", "eighties", "a", "thirty", "pm"]
words += ["million", "oh", "twenty-five", ","]
for size in (2, 3, 4):
    for run in itertools.product(words, repeat=size):
        server.Engine.write_numbers(" ".join(run) + ".", ())
print("PASS no number run raises")
# The guard reads number words as write_numbers writes them: a cleanup that writes the same digits
# passes ("four oh four" -> "404", "one point oh five" -> "1.05", "two point one thousand").
words = ["one", "two", "eight", "oh", "point", "twenty", "hundred", "thousand", "million"]
for size in (1, 2, 3, 4):
    for run in itertools.product(words, repeat=size):
        for joint in (" ", ". ", ", ") if 1 < size < 4 else (" ",):  # across a sentence or list
            said = "Use " + run[0] + joint + " ".join(run[1:]) + " now."
            written = server.Engine.write_numbers(said, ())
            assert not server.Engine.looks_rewritten(said, written, []), f"{said!r} -> {written!r}"
print("PASS the guard accepts the digits write_numbers writes")
# After "at" or "by" too, where a run may be a time: "at eight oh oh" -> "at 8:00".
for lead, size in itertools.product(("Meet at", "Done by"), (1, 2, 3, 4)):
    for run in itertools.product(words, repeat=size):
        said = f"{lead} {' '.join(run)} now."
        written = server.Engine.write_numbers(said, ())
        assert not server.Engine.looks_rewritten(said, written, []), f"{said!r} -> {written!r}"
print("PASS the guard accepts the times write_numbers writes")
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
        (("Is it ready, no wait, just ship it?", "Just ship it."), "Just ship it."),
        (
            ("Is it ready, no wait, the status is green?", "The status is green."),
            "The status is green.",
        ),
        (
            (
                "Is it ready, no wait, the status is green, and is stable?",
                "The status is green, and is stable.",
            ),
            "The status is green, and is stable.",
        ),
        (("What time is it?", "What time is it."), "What time is it?"),
        (("Should we pick A?", "Should we pick A."), "Should we pick A?"),
        (("Thanks. But", "Thanks."), "Thanks. But"),
        (("Is it ready? And", "Is it ready?"), "Is it ready? And"),
        (("Stop! And", "Stop!"), "Stop! And"),
        (("Will do", "Will do."), "Will do."),
        (('Did he say "yes"?', 'Did he say "yes."'), 'Did he say "yes"?'),
        (("I want to go to the", "I want to go to the,"), "I want to go to the,"),
        (("What a great idea", "What a great idea!"), "What a great idea!"),
        (("Can you believe it?", "Can you believe it?!"), "Can you believe it?!"),
        (("Can you believe it?!", "Can you believe it."), "Can you believe it?"),
        (("Is it ready?", "Is it ready?."), "Is it ready?"),
        (("I want to go to the", "I want to go to the…"), "I want to go to the"),
        (("Let me check and…", "Let me check and."), "Let me check and"),
        (("I want to go to the", "I want to go to the—"), "I want to go to the"),
        (("He said I want the", 'He said, "I want the."'), 'He said, "I want the"'),
        (("Let us compare Python versus", "Let us compare Python vs."), "Let us compare Python vs"),
        (("Did he say yes", 'Did he say "yes?"'), 'Did he say "yes?"'),
        # A cut word comes back after the comma or colon said before it, inside closing quotes.
        (("Send it to John, and", "Send it to John."), "Send it to John, and"),
        (("We need eggs, milk, and", "We need eggs, milk."), "We need eggs, milk, and"),
        (("Send it to John, and the", "Send it to John."), "Send it to John, and the"),
        (("Send it to John and", "Send it to John,"), "Send it to John, and"),
        (("Send it to John, and", "Send it to John,"), "Send it to John, and"),
        (("The plan is simple: the", "The plan is simple."), "The plan is simple: the"),
        (("He said I want the", 'He said, "I want."'), 'He said, "I want the"'),
        (('He said "yes", and', 'He said "yes."'), 'He said "yes", and'),
        (('He said "yes." And', 'He said "yes."'), 'He said "yes." And'),
        # The cleanup's capitals and curly marks: "API" matches "api", "it’s" matches "it's".
        (("Check the api and", "Check the API."), "Check the API and"),
        (("I think it's the", "I think it’s."), "I think it’s the"),
        (("He said I want the", "He said, “I want the.”"), "He said, “I want the”"),
        (("He said I want the", "He said, “I want.”"), "He said, “I want the”"),
        (("Did he say yes", "Did he say “yes?”"), "Did he say “yes?”"),
        (("He said I want the", "He said, ‘I want.’"), "He said, ‘I want the’"),
        (("Send it to the dogs and", "Send it to the dogs’."), "Send it to the dogs’ and"),
        (("Don't you think so?", "Don’t you think so."), "Don’t you think so?"),
        # A straight ' after an end mark closes a quote too; one inside a word opens none.
        (("He said I want the", "He said, 'I want.'"), "He said, 'I want the'"),
        (("Did he say yes", "Did he say 'yes?'"), "Did he say 'yes?'"),
        (("Did he say yes?", "Did he say 'yes.'"), "Did he say 'yes'?"),
        (('"Can you help?"', '"Can you help."'), '"Can you help?"'),
        (("It's for the dogs and", "It's for the dogs'."), "It's for the dogs' and"),
        (("He said 'yes', and", "He said 'yes'."), "He said 'yes', and"),
        (("He said ‘yes’, and", "He said ‘yes.’"), "He said ‘yes’, and"),
        (("He said 'yes.' And", "He said 'yes.'"), "He said 'yes.' And"),
        (("In the '90s, the kids' and", "In the '90s, the kids'."), "In the '90s, the kids' and"),
        (("He said the kids' and", 'He said, "The kids’."'), 'He said, "The kids’ and"'),
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
    "guard accepts cleanups",
    [
        ((raw, cleaned), cleaned)
        for raw, cleaned in [
            # A reformatted or corrected number, a filler "like", and a set-off "you know" may go.
            ("The invoice is 1,240 dollars.", "The invoice is 1240 dollars."),
            ("Send fifteen dollars.", "Send 15 dollars."),
            ("Back in twenty twenty six.", "Back in 2026."),
            ("Set it to negative fifteen.", "Set it to -15."),
            ("Set opacity to 15 percent.", "Set opacity to 15%."),
            ("Wait fifteen minutes.", "Wait 15 minutes."),
            ("fifteen.", "15."),
            ("Set it to one point five.", "Set it to 1.5."),
            ("Okay. Let's ship it.", "Let's ship it."),
            ("Thanks. Ship it.", "Thank you. Ship it."),
            ("Set it to one hundred and five.", "Set it to 105."),
            ("Send fifteen dollars to Jane.", "Send $15 to Jane."),
            ("Send 15, no, 50 dollars.", "Send 50 dollars."),
            ("Use SHA-256, no wait, SHA-512.", "Use SHA-512."),
            ("Due March 15th.", "Due March 15."),
            ("Wait 20ms.", "Wait 20 ms."),
            ("Wait 50µs.", "Wait 50μs."),  # a micro sign as Greek mu
            ("Set opacity to .5.", "Set opacity to 0.5."),
            ("Fine, OK, send it to Jane.", "Fine, send it to Jane."),
            ("Basically we should ship it.", "We should ship it."),
            ("Email alice@example.com, no wait, bob@example.com.", "Email bob@example.com."),
            ("I will go there.", "I'll go there."),
            ("I had sent it.", "I'd sent it."),
            ("um the page returned four oh four", "The page returned 404."),
            ("Set the rate to one point oh five.", "Set the rate to 1.05."),
            ("The server returned five oh oh.", "The server returned 500."),
            ("Use port eight oh eight oh.", "Use port 8080."),
            ("What's the point? Oh, never mind.", "What's the point? Never mind."),
            ("Run the ploy script.", "Run the deploy script."),
            ("It's a the tailed plan.", "It's a detailed plan."),
            ("The rate is one point oh five oh.", "The rate is 1.05 oh."),
            ("Dial two oh two point oh five oh.", "Dial 202.050."),
            ("Um, open ports eight oh eight oh and nine oh.", "Open ports 8080 and 9 oh."),
            ("Call me at five, five five five.", "Call me at 5, five five five."),
            ("So, you know, the server returned a five-oh-three.", "So the server returned a 503."),
            ("We need, you know, two million users.", "We need 2 million users."),
            ("The budget is one point five million dollars.", "The budget is $1.5 million."),
            (
                "Uh, let's meet at three thirty, no wait, Thursday at noon.",
                "Let's meet Thursday at noon.",
            ),
            ("Uh, let's meet at seven fifteen.", "Let's meet at seven-fifteen."),
            ("The fix costs two hundred, umm, fifty dollars.", "The fix costs $250."),
            ("Uh, it look good to me.", "It looks good to me."),
            ("Um, the server die last night.", "The server died last night."),
            ("Do you, did you push it?", "Did you push it?"),
            ("Is the, uh, are the tests passing?", "Are the tests passing?"),
            ("We were, we are shipping Friday.", "We are shipping Friday."),
            (
                "Should we move the standup to ten? Actually, should we cancel it?",
                "Should we cancel it?",
            ),
            ("It only take a minute.", "It only takes a minute."),
            ("We can't, we can ship it Friday.", "We can ship it Friday."),
            ("Hey Alice? Can you review my PR?", "Hey Alice, can you review my PR?"),
            ("Can you send me the file? And the logs?", "Can you send me the file and the logs?"),
            ("The temperature is negative about fifteen.", "The temperature is about -15."),
            ("He only need the logs.", "He only needs the logs."),
            ("Did you finish? The report?", "Did you finish the report?"),
            ("we live in the north east", "We live in the northeast."),
            ("I went home; then I slept.", "I went home, then I slept."),
            ("Johnson & Johnson and Pfizer met.", "Johnson and Johnson and Pfizer met."),
            ("cat file | grep foo, no wait, cat file | sort", "cat file | sort"),
            ("Run cat file | grep foo, no wait, cat file | sort.", "Run cat file | sort."),
            (
                "I want 2 tickets for Monday, no wait, 2 tickets for Tuesday.",
                "I want 2 tickets for Tuesday.",
            ),
            ("Upgrade to Python 3.11, no wait, 3.12.", "Upgrade to Python 3.12."),
            ("Let's meet at 3.30 tomorrow.", "Let's meet at 3:30 tomorrow."),
            ("Meet me at 1.30pm.", "Meet me at 1:30pm."),
            ("The call is at 4.15pm tomorrow.", "The call is at 4:15 pm tomorrow."),
            ("Don't merge it, no wait, merge it.", "Merge it."),
            ("Never deploy, no wait, never deploy.", "Never deploy."),
            ("Call Dr. Smith, no wait, Dr. Jones.", "Call Dr. Jones."),
            # Said as written: "thank you" and "US dollars" name nobody, and a "you know", "I mean",
            # or "make it" ending a sentence is meant.
            ("Thank you for getting back to me.", "Thank you for getting back to me."),
            ("It costs 15 US dollars.", "It costs 15 US dollars."),
            ("I'll let you know.", "I'll let you know."),
            ("That's not what I mean.", "That's not what I mean."),
            ("Sorry, I can't make it.", "Sorry, I can't make it."),
            ("I mean, it's fine.", "I mean, it's fine."),  # a filler may stay
            ("It works you know.", "It works."),  # or go, set off or not
            ("Please send it, no wait, send it to Bob.", "Please send it to Bob."),
            (
                "You should call her, sorry, call her after the meeting.",
                "You should call her after the meeting.",
            ),
            (
                "Don't worry, I'll call her, no wait, call her after the meeting today.",
                "Don't worry, I'll call her after the meeting today.",
            ),
            ("We should leave at five, no wait, leave at six.", "We should leave at six."),
            ("Let's meet on Thursday. Uh, no, Friday.", "Let's meet on Friday."),
            ("cd .., no wait, cd ~", "cd ~"),
            ("Book the room for Monday sorry. Tuesday.", "Book the room for Tuesday."),
            ("I'll take the blue one actually.", "I'll take the blue one."),
            ("Meet at 3 p.m. Tuesday, sorry, 4 p.m. Tuesday.", "Meet at 4 p.m. Tuesday."),
            ("Thank you, thank you so much for your help.", "Thank you so much for your help."),
            ("We already tried that you know.", "We already tried that."),
            ("Run LS in the home folder.", "Run ls in the home folder."),  # letters heard
            ("Is it done; did you check?", "Is it done? Did you check?"),
            ("So, um, I tried it; it didn't work.", "So, I tried it, it didn't work."),
            ("Ship it Monday. Yeah. No. Ship it Tuesday.", "Ship it Tuesday."),
            ("It was, actually, fine.", "It was fine."),
            (
                "Let's meet at the coffee shop on Main Street, no wait, the library.",
                "Let's meet at the library.",
            ),
            ("I'm okay actually. I'm feeling much better.", "I'm okay. I'm feeling much better."),
            ("That's true actually. That's very true.", "That's true. That's very true."),
            ("We can do that actually. We can do that tomorrow.", "We can do that tomorrow."),
            (
                "We might ship today, no wait, we will ship today.",
                "We might ship today. No, we will ship today.",
            ),
            ("Meet at 3 p.m. tomorrow.", "Meet at 3 p.m. tomorrow."),
            ("Let's meet on Monday. I mean, Tuesday.", "Let's meet on Tuesday."),
            ("Send it to Alice. No, wait. Send it to Bob.", "Send it to Bob."),
            ("Set PATH to $HOME/bin, no wait, $HOME/.local/bin.", "Set PATH to $HOME/.local/bin."),
            ("Book it from 9.30 to 11.30 am.", "Book it from 9:30 to 11:30 am."),
            ("echo $HOME, no wait, $PATH", "echo $PATH"),
            (">> Hello there.", "Hello there."),
            ("It's ready? Right?", "It's ready, right?"),
            ("Is the meeting at 10 a.m.? Or 11 a.m.?", "Is the meeting at 10 a.m. or 11 a.m.?"),
            ("Can you review my PR I pushed the fix?", "Can you review my PR? I pushed the fix."),
            ("We're shipping Friday, okay?", "We're shipping Friday. Okay?"),
            ("Is there any updates on the deploy?", "Are there any updates on the deploy?"),
            ("Okay? So the plan is to fix the build.", "Okay, so the plan is to fix the build."),
            ("Let's meet Monday. No wait, Tuesday?", "Let's meet Tuesday."),
            (
                "Did anyone update the fire wall? Thanks, I appreciate it a lot.",
                "Did anyone update the firewall? Thank you, I appreciate it a lot.",
            ),
            ("The build's been failing.", "The build has been failing."),
            ("Uh, the API return an error.", "The API returns an error."),
            ("Email alice at example dot com.", "Email alice@example.com."),
            ("Me and him went.", "He and I went."),
            ("Use half the dose.", "Use ½ the dose."),
            ("I think that we should ship.", "I think we should ship."),
            ("It costs fifteen US dollars.", "It costs $15."),
            ("meet at three thirty", "Meet at three thirty."),
            ("Meet at three thirty pm.", "Meet at 3:30 PM."),
            ("Meet at three thirty pm.", "Meet at 3:30pm."),
            ("Turn on 2FA for my account please.", "Turn on 2FA for my account."),
            ("Use SHA-256 for it.", "Use SHA256 for it."),
            ("My three-year-old is here.", "My 3-year-old is here."),
            ("It was like really good.", "It was really good."),
            ("So, you know, we should ship it.", "So we should ship it."),
            ("So you know we should ship it today.", "We should ship it today."),
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
            ("No wait, open GitHub.", "Open GitHub."),
            ("No, no, it's fine.", "No, it's fine."),
            ("I am going to the store.", "I'm going to the store."),
            ("Meet me at three thirty.", "Meet me at 3:30."),
            ("Can you send me the, can you send me the report?", "Can you send me the report?"),
            ("Send it to the team. Scratch that. Send it to John.", "Send it to John."),
            ("I do not know.", "I don't know."),
            ("Order the large blue ceramic mug, actually, the small one.", "Order the small one."),
            ("It's not ready, actually, it's ready.", "It's ready."),
            ("I don't, I don't know.", "I don't know."),
            ("It is not, it's not working.", "It's not working."),
            ("Let's meet Thursday, no, Friday. I don't know.", "Let’s meet Friday. I don’t know."),
            ("He said don't do it.", "He said, ‘Don’t do it.’"),
            ("It's not, not working.", "It's not working."),
            ("Nobody, nobody came.", "Nobody came."),
            ("Send it to Bob, no wait, nobody.", "Send it to nobody."),
            ("Meet Thursday, no, make it Friday.", "Meet Friday."),
            ("Let's meet Thursday. No, I meant Friday.", "Let's meet Friday."),
            ("Ship it without, uh, the migration.", "Ship it without the migration."),
            ("I want go home.", "I want to go home."),
            # Glossary entries may replace the misheard words they fix.
            (
                "After the update ghostly, recast, and mice all broke again.",
                "After the update Ghostty, Raycast, and mise all broke again.",
            ),
            (
                "After the update ghostly's, recast's, and mice's configs all broke again.",
                "After the update Ghostty's, Raycast's, and mise's configs all broke again.",
            ),
            ("Open Ghostty's, no wait, yabai's config.", "Open yabai's config."),
            (
                "Here's a list. Eggs, milk, and bread.",
                "Here's a list:\n\n- Eggs\n- Milk\n- Bread",
            ),
            (
                "Two things. One, fix the build. Two, ship it.",
                "Two things:\n\n1. Fix the build.\n2. Ship it.",
            ),
        ]
    ],
    lambda pair: dictate(*pair),
)
# An unlisted cue loses Slack uncorrected; an unlisted filler is a third lost word, over the slack.
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
                (f"Okay, so, {filler}, meet Monday.", "Meet Monday.")
                for filler in ["um", "uh", "erm", "hmm", "like", "you know"]
            ),
            ("Okay, meet Friday, actually make that Monday.", "Meet Monday."),
            ("Okay, so, meet Friday, scratch that, Monday.", "Meet Monday."),
            ("Okay, so, meet Friday, no wait, Monday.", "Meet Monday."),
        ]
    ],
    lambda pair: dictate(*pair),
)
standup = (
    "I think we should move the standup to ten tomorrow because half the team is out and nobody "
    "has prepared the demo yet."
)
pricing = "Marketing wants a short video explaining the pricing changes."
# An empty cleanup (no coherent speech, as the prompt asks) types nothing, and the result carries
# what was heard so Hammerspoon keeps it.
engine.speech = SimpleNamespace(transcribe=lambda wav, hint: "Mmm wha blah")
engine.cleaner = SimpleNamespace(frozen_prompt="prompt", complete=lambda messages, raw: "")
with tempfile.NamedTemporaryFile(suffix=".wav") as take, mock.patch.object(server, "emit") as sent:
    engine.handle({"cmd": "transcribe", "id": 7, "wav": take.name})
event = sent.call_args[0][0]
assert event["text"] == "" and event["heard"] == "Mmm wha blah", event
print("PASS an empty cleanup types nothing and keeps what was heard")
# Only protocol lines reach stdout: a library that prints, on load or during a take, goes to stderr.
chatter = """
import os, sys, server
class Chatty:
    def __init__(self, config):
        print("[WARNING] Generating with a model that requires 9000 MB")
    def load(self):
        print("loading...")
    def handle(self, request):
        print("[WARNING] again")
        os.write(1, b"native chatter\\n")  # as native code would, past sys.stdout
        server.emit({"event": "final", "id": request["id"], "text": "ok"})
server.Engine = Chatty
sys.argv = ["server.py", "--config", "{}"]
sys.exit(server.main())
"""
run = subprocess.run(
    [sys.executable, "-c", chatter],
    input='{"cmd": "transcribe", "id": 1}\n',
    capture_output=True,
    text=True,
    cwd=Path(server.__file__).parent,
    timeout=120,
    check=False,
)
events = [json.loads(line)["event"] for line in run.stdout.splitlines()]
assert events == ["ready", "final"] and "native chatter" in run.stderr, (run.stdout, run.stderr)
print("PASS a library that prints cannot corrupt the protocol")
# The prompt opens and closes an empty think block; the model may close it again, and only what
# follows is the reply.
cleaner = server.MlxLmCleaner("stub", "0" * 40, None, None, 400)
cleaner.llm, cleaner.tokenizer = None, tokenizer
with mock.patch("mlx_lm.generate", return_value="Fix the bug.</think>\n\nFix the bug."):
    reply = cleaner.complete([{"role": "user", "content": "Fix the bug."}], "Fix the bug.")
assert reply == "Fix the bug.", reply
print("PASS a stray closing think tag leaves only the reply")
# A rewritten take fails with what was heard in its error event, and no traceback logged.
rewritten = """
import sys, server
from types import SimpleNamespace
class Stub(server.Engine):
    def __init__(self, config):
        self.config, self.heard, self.cleaner, self.dictionary = config, None, None, []
        self.speech = SimpleNamespace(transcribe=lambda wav, hint: "Send fifteen dollars.")
    def load(self):
        self.cleaner = SimpleNamespace(frozen_prompt="p", complete=lambda m, raw: "Send 50 dollars.")
server.Engine = Stub
sys.argv = ["server.py", "--config", "{}"]
sys.exit(server.main())
"""
with tempfile.NamedTemporaryFile(suffix=".wav") as take:
    run = subprocess.run(
        [sys.executable, "-c", rewritten],
        input=json.dumps({"cmd": "transcribe", "id": 3, "wav": take.name}) + "\n",
        capture_output=True,
        text=True,
        cwd=Path(server.__file__).parent,
        timeout=120,
        check=False,
    )
events = [json.loads(line) for line in run.stdout.splitlines()]
assert [e["event"] for e in events] == ["ready", "error"], (run.stdout, run.stderr)
assert events[1]["heard"] == "Send fifteen dollars." and "rewrote" in events[1]["msg"], events[1]
assert "Traceback" not in run.stdout, run.stdout
print("PASS a rewritten take fails with what was heard")
# A take whose speech fails reports nothing heard, not the last take's: Hammerspoon would keep that
# text as this take's and delete this take's recording.
stale = """
import sys, server
from types import SimpleNamespace
from unittest import mock
class Stub(server.Engine):
    def __init__(self, config):
        self.config, self.heard, self.cleaner, self.dictionary = config, None, None, []
        failed = RuntimeError("the speech model failed")
        self.speech = SimpleNamespace(transcribe=mock.Mock(side_effect=["Send it.", failed]))
    def load(self):
        pass
server.Engine = Stub
sys.argv = ["server.py", "--config", "{}"]
sys.exit(server.main())
"""
with tempfile.NamedTemporaryFile(suffix=".wav") as take:
    run = subprocess.run(
        [sys.executable, "-c", stale],
        input="".join(
            json.dumps({"cmd": "transcribe", "id": i, "wav": take.name}) + "\n" for i in (1, 2)
        ),
        capture_output=True,
        text=True,
        cwd=Path(server.__file__).parent,
        timeout=120,
        check=False,
    )
events = [e for e in map(json.loads, run.stdout.splitlines()) if e["event"] != "log"]
assert [e["event"] for e in events] == ["ready", "final", "error"], (run.stdout, run.stderr)
assert events[1]["text"] == "Send it." and events[2]["id"] == 2, events
assert events[2]["heard"] is None and "speech model failed" in events[2]["msg"], events[2]
print("PASS a take whose speech fails reports nothing heard")
# A stall between two counts does not join them; between a number's parts it does.
check(
    "guard reads a number across a stall only when it goes on",
    [
        (("Um, I need five, uh, six servers.", "I need 56 servers."), True),
        (("I need five umm six servers.", "I need 56 servers."), True),
        (("The fix costs two hundred, um, fifty dollars.", "The fix costs $250."), False),
    ],
    lambda pair: server.Engine.looks_rewritten(*pair, []),
)
closed = "Please remind everyone the office is closed Monday."
check(
    "guard rejects rewrites",
    [
        ((raw, rewritten), None)
        for raw, rewritten in [
            # A replaced, dropped, or invented number, a cut verb "like", and a meant "you know".
            ("Send 15 dollars.", "Send 50 dollars."),
            ("Send fifteen dollars.", "Send 50 dollars."),
            ("Send 15 dollars.", "Send fifty dollars."),
            ("Send 15 dollars.", "Send dollars."),
            ("Send fifteen dollars.", "Send dollars."),
            ("Send fifteen dollars.", "Send 15 15 dollars."),
            ("Meet at three thirty.", "Meet at 330 330."),
            ("Meet at three thirty.", "Meet at 3 3."),
            ("Meet at three thirty.", "Meet at 3."),
            ("We have eight hundred users.", "We have 8:00 users."),
            ("Wait fifteen minutes.", "Wait 15 seconds."),
            ("Wait fifteen minutes.", "Wait 15."),
            ("Wait fifteen long minutes.", "Wait 15 long seconds."),
            ("Drive fifteen miles per hour.", "Drive 15 miles per minute."),
            ("Pick two of the apples.", "Pick 2 apples."),  # the words after a number stay
            ("It costs 3.30.", "It costs 3:30."),  # a price is no time
            ("Always run the tests, no wait, run the tests.", "Always run the tests."),
            (
                "Never skip the tests, sorry, skip the tests on docs changes.",
                "Never skip the tests on docs changes.",
            ),
            (
                "Never use tabs, I mean, use tabs for indentation.",
                "Never use tabs for indentation.",
            ),
            ("Never push to main. Merge it, no wait, close it.", "Close it."),  # its sentence only
            ("Do not deploy. Merge it, no wait, merge it.", "Merge it."),
            ("Sorry, I can't make it.", "Sorry, I can't."),
            ("Tell me what you know.", "Tell me what."),
            ("I know that you know.", "I know that."),
            # Shell input keeps its operators, operands, quoting, and case.
            ("echo hi; rm x", "echo hi rm x"),
            ("git add .", "git add"),
            ('echo "a|touch b"', "echo a|touch b"),
            ("git checkout HEAD", "git checkout head"),
            ("Take the service online.", "Take the service offline."),
            ("Rebuild the index.", "Build the index."),
            ("Select all users.", "Delete all users."),  # a destructive verb never said
            ("Meet at 3 p.m. Wait.", "Meet at 3 p.m."),
            ("cd ~", "cd /"),
            ("Tell him that you know.", "Tell him that."),
            ("So, um, run make; make install.", "So, run make make install."),
            ("I'm really sorry. I missed the meeting.", "I missed the meeting."),
            ("You mustn't merge it, no wait, merge it today.", "You mustn't merge it today."),
            ("Let's meet at 3 p.m. Tuesday, no wait, Wednesday.", "Let's meet at Wednesday."),
            ("Use the red one actually. Use the blue one.", "Use the red one. Use the blue one."),
            ("Meet at 3 p.m. Thanks.", "Meet at 3 p.m."),  # its "." before a capital ends one
            ("Thank you for helping.", "Thank for helping."),
            ("Please wait.", "Please."),
            ("Copy it from the source folder.", "Copy it the source folder."),
            ("Uh, don't call me, sorry, call me after five.", "Don't call me after five."),
            (
                "Um never skip the tests, sorry, skip the tests on docs changes.",
                "Never skip the tests on docs changes.",
            ),
            ("You can't merge it, no wait, merge it today.", "You can't merge it today."),
            (
                "Delete all the branches, no wait, delete the merged branches.",
                "Delete all the merged branches.",
            ),
            ("It's not working, no wait, it's working.", "It's not working."),
            ("I don't think so, no wait, I think so.", "I don't think so."),
            (
                "Run cat log | grep error, no wait, cat log | grep warning.",
                "Run cat log grep warning.",
            ),
            ("Set it to exactly fifteen.", "Set it to 15."),
            ("Set it to at least fifteen.", "Set it to 15."),
            ("Set it to over fifteen.", "Set it to 15."),
            ("Set it to only fifteen.", "Set it to 15."),
            ("Turn logging off.", "Turn logging on."),
            ("Run this before Friday.", "Run this after Friday."),
            ("Enable access for all users.", "Enable access for some users."),
            ("Include the tests.", "Exclude the tests."),
            ("The policy denies access.", "The policy allows access."),
            ("The config includes tests.", "The config excludes tests."),
            ("Set it to at least fifteen.", "Set it to at most 15."),
            ("Open settings. Delete files.", "Open settings."),
            ("Thanks. And the", "Thanks."),
            ("Open settings. Delete files.", "Open settings. Upload logs."),
            ("Open settings. Delete files.", "Open settings. Deliver secrets."),
            ("Use SHA256.", "Use 256."),
            ("Enable 2FA.", "Enable 2."),
            ("Use SHA256.", "Use 56."),
            ("Use TLS1.3.", "Use 3."),
            ("Use SHA-256.", "Use 256."),
            ("Use HTTP/2.", "Use 2."),
            ("Use ГОСТ123.", "Use 123."),
            ("Use SHA-256.", "Use SHA-512."),
            ("Use TLS1.3.", "Use TLS13."),
            ("Connect to 192.168.1.1.", "Connect to 192.168.1.2."),
            ("Set timeout to 20 before retrying.", "Set timeout to 20ms before retrying."),
            ("Allocate 16GB.", "Allocate 16Gb."),
            ("Transfer at 16GB then 8Gb.", "Transfer at 16Gb then 8GB."),
            ("Allocate sixteen GB.", "Allocate 16 Gb."),
            ("Send it to Alice.", "Send it to Bob."),
            ("Alice sent it.", "Bob sent it."),
            ("PostgreSQL is down.", "MySQL is down."),
            ("Use -1e-3.", "Use 1e-3."),
            ("Email alice@example.com today.", "Email bob@example.com today."),
            ("Open /usr/local/bin.", "Open /usr/share/bin."),
            ("Run it with --force.", "Run it with --delete."),
            ("Write it in C++.", "Write it in C#."),
            ("Send it to him.", "Send it to her."),
            ("Put this here.", "Put that there."),
            ("Delete all files.", "Delete files."),
            ("Always encrypt backups.", "Encrypt backups."),
            ("Users must authenticate.", "Users authenticate."),
            ("Open example dot com.", "Open examples.com."),
            ("Use force please.", "Use --force please."),
            ("He approved it.", "They approved it."),
            ("Send it to him.", "Send it."),
            ("Can you send it to my", "Can you send it?"),
            ("Use half the dose.", "Use double the dose."),
            ("Retry once.", "Retry twice."),
            ("Email alice@example.com and alice@example.com.", "Email alice@example.com."),
            ("Turn logging off.", "Turn logging."),
            ("Run before deploy.", "Run deploy."),
            ("Use ½ the dose.", "Use ¼ the dose."),
            ("Use image latest.", "Use image:latest."),
            ("He sent him the report.", "He sent the report."),
            ("Put this here.", "Put here."),
            ("Run deploy.", "Run before deploy."),
            ("Turn logging off and tracing off.", "Turn logging and tracing off."),
            ("Move foo slash bar baz.", "Move foo/bar/baz."),
            (
                "Email alice at example dot com and alice example com.",
                "Email alice@example.com and alice@example.com.",
            ),
            ("Alice emailed Alice.", "Alice emailed."),
            ("They paid us dollars.", "They paid dollars."),
            ("Set gain to plus fifteen.", "Set gain to 15."),
            ("Compare Java and JavaScript.", "Compare JavaScript."),
            ("Send the report.", "Send her the report."),
            ("Email marc today.", "Email Mark today."),
            ("Use one dozen eggs.", "Use 112 eggs."),
            ("Send it now.", "Send now."),
            ("Make it bold.", "Bold."),
            ("Where should we deploy?", "When should we deploy?"),
            ("Delete all files except logs.", "Delete all files."),
            ("Grant access.", "Grant admin access."),
            ("Deploy staging or production.", "Deploy staging and production."),
            ("Run echo home.", "Run echo $HOME."),
            ("Run echo hello grep hello.", "Run echo hello | grep hello."),
            ("Delete logs.", "Delete just logs."),
            ("Meet next Monday.", "Meet Monday."),
            ("Deploy tomorrow.", "Deploy today."),
            ("Someone called.", "Called."),
            ("Run echo hello echo goodbye.", "Run echo hello; echo goodbye."),
            ("Maybe delete the files.", "Delete the files."),
            ("Grant user access.", "Grant admin access."),
            ("Do not deploy until Friday.", "Do not deploy Friday."),
            ("Delete logs and backups.", "Delete logs."),
            ("Send it to Alice.", "Send it from Alice."),
            ("Move files into staging.", "Move files from staging."),
            ("Encrypt the backup.", "Decrypt the backup."),
            ("Activate the license.", "Deactivate the license."),
            ("The license was activated.", "The license was deactivated."),
            ("Keep the selected items.", "Keep the deselected items."),
            ("The service is running.", "The service was running."),
            ("Do not delete backups.", "Did not delete backups."),
            ("Don't delete the backups.", "Didn't delete the backups."),
            ("Don't do that.", "Do that."),
            ("You can't not test it.", "You can't test it."),
            ("The problem is she's on vacation.", "The problem is on vacation."),
            ("Delete the old backup.", "Delete the old backups."),
            ("Revert John's commit.", "Revert John's commits."),
            ("Is it ready?", "It's ready."),
            ("Hmm, is it ready?", "It's ready."),
            ("Has it shipped?", "It's shipped."),
            ("It is, it was working.", "It is working."),
            ("We did have a backup.", "We have a backup."),
            ("Restart the server that crashed.", "Restart the servers that crashed."),
            ("Did you see the build? Is it ready?", "Did you see the build? It's ready."),
            ("Is it ready? Ship it.", "It's ready. Ship it."),
            ("Is it ready, no wait, is it deployed?", "It's deployed."),
            ("Would you like coffee?", "You'd like coffee."),
            ("I can, I can't come tomorrow.", "I can come tomorrow."),
            ("This is useful.", "This is useless."),
            ("Move it north.", "Move it south."),
            ("Use the eastern exit.", "Use the western exit."),
            ("Head northeast.", "Head northwest."),
            ("The wind is westerly.", "The wind is easterly."),
            ("Turn east here.", "Turn west here."),
            ("echo hi | grep x", "echo hi grep x"),
            ("ls > out.txt", "ls out.txt"),
            ("Alice has the key.", "Alice is the key."),
            ("You are coming? Then call me.", "You are coming. Then call me."),
            ("The test is positive.", "The test is negative."),
            ("Delete bakcup and restore datbase.", "Delete database and restore backup."),
            ("Is it at 3 p.m.?", "It's at 3 p.m."),
            ("And is that, is that safe to merge?", "That is safe to merge."),
            ("Which server is down?", "Which servers are down?"),
            ("Bob's brother has the key.", "Bob's brother is the key."),
            ("I do not, I do want it.", "I do not want it."),
            ("The build is not, the build is working.", "The build is not working."),
            ("Hey Alice? Is the deploy done?", "Hey Alice? The deploy's done."),
            ("You want coffee? I can make some.", "You want coffee. I can make some."),
            (
                "Also, who owns this repo? I need access.",
                "Also, who owns this repo. I need access.",
            ),
            ("Is it at three thirty?", "It's at 3:30."),
            ("Is it ready? Can I merge?", "It's ready, can I merge."),
            ("Is it at 3 p.m.? I'll be there.", "It's at 3 p.m. I'll be there."),
            ("Is it under 50ms? It was 80ms yesterday.", "It's under 50ms. It was 80ms yesterday."),
            ("Did it work? No? Then roll it back.", "Did it work? No. Then roll it back."),
            ("Actually, did it work? No? Then roll it back.", "Actually, then roll it back."),
            ('Is it "3 p.m." or "4 p.m."?', 'It\'s "3 p.m." or "4 p.m."'),
            ("Is the service running?", "The service was running."),
            ("We need two—three servers.", "We need 23 servers."),
            ("Delete the backup.", "Delete the backups."),
            ("Commission the cluster.", "Decommission the cluster."),
            ("Delete the backups by Friday.", "Delete the backups Friday."),
            ("Users got to authenticate.", "Users authenticate."),
            ("If tests pass, deploy.", "Tests pass, deploy."),
            ("Definitely delete the backups.", "Delete the backups."),
            ("Meet on Friday.", "Meet at Friday."),
            ("He sent her the report.", "She sent him the report."),
            ("The data is safe.", "The data is unsafe."),
            ("Set opacity to .5.", "Set opacity to .8."),
            ("Set it to −15.", "Set it to 15."),
            ("Use 1e-3.", "Use 1e3."),
            ("Use 15, no 50, with 15 retries.", "Use 50 with retries."),
            ("Wait 20ms.", "Wait 50ms."),
            ("Buy 16GB.", "Buy 16MB."),
            ("My 3-year-old is here.", "My 5-year-old is here."),
            ("The minimum is fifteen.", "The maximum is 15."),
            ("The panel is shown.", "The panel is hidden."),
            ("Set it to one point five.", "Set it to 1 5."),
            ("Set the rate to one point oh five.", "Set the rate to 1.5."),
            ("Send fifteen Canadian dollars.", "Send fifteen US dollars."),
            ("Wait fifteen very long minutes.", "Wait 15 very long seconds."),
            ("Set it to approximately fifteen.", "Set it to 15."),
            ("Set it to about fifteen.", "Set it to 15."),
            ("Buy fifteen apples then sell oranges.", "Buy apples then sell 15 oranges."),
            ("Meet me at noon.", "Meet me at midnight."),
            ("The package weighs fifteen pounds.", "The package weighs £15."),
            ("Set width to fifteen and height to twenty.", "Set width to 20 and height to 15."),
            ("Set it to negative 15.", "Set it to 15."),
            ("Set it to 15.", "Set it to -15."),
            ("Set it to negative approximately fifteen.", "Set it to approximately 15."),
            ("Pay 15 US dollars.", "Pay 15 US."),
            ("Set opacity to 15%.", "Set opacity to 15."),
            ("Send $15 to Jane.", "Send 15 to Jane."),
            ("Refund -$15 today.", "Refund $15 today."),
            ("Temperature is +15 degrees.", "Temperature is 15 degrees."),
            ("I hardly know him.", "I know him."),
            ("Move 15 files into 15 folders.", "Move 15 files into folders."),
            ("Send dollars.", "Send 50 dollars."),
            ("I like cats.", "I cats."),
            # A cue word said as a word takes nothing back; a word in any script counts.
            ("Can you please wait for the build to finish.", "For the build to finish."),
            ("Привет Slack как дела сегодня", "Slack."),
            ("Children like cats.", "Children cats."),
            ("You know the answer.", "The answer."),
            ("I mean it.", "It."),
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
            ("Yeah.", "Okay."),
            ("Thanks.", "You're welcome!"),
            ("Thanks.", "Thanks. You're welcome!"),
            ("Thanks.", "Sure. Thanks."),
            ("What is the capital of France?", "What is the capital of France? Paris."),
            ("We should not deploy on Friday.", "We should deploy on Friday."),
            ("We should deploy on Friday.", "We should not deploy on Friday."),
            ("The tests pass on my machine, no idea why CI fails.", "No idea why CI fails."),
            (
                "Actually the budget review is on Tuesday and the planning meeting is on Thursday.",
                "The planning meeting is on Thursday.",
            ),
            ("No, I use Neovim.", "No, I use Vim."),
            # A cue word that takes nothing back leaves glossary words and "no" protected.
            ("Open Ghostty. No idea why it crashed.", "Open ghostly. No idea why it crashed."),
            # A possessive protects its name too.
            ("Open Ghostty's settings.", "Open ghostly's settings."),
            ("Check yabai's logs.", "Check the logs."),
            ("Restart Raycast’s extension.", "Restart Recast’s extension."),
            ("We have no tests for this.", "We have tests for this."),
            # A "no" cut with the words before it still negates what follows it.
            ("It has no tests yet, merge it anyway.", "Merge it anyway."),
            ("There's no way this ships Friday.", "This ships Friday."),
            ("We have tests for this.", "We have no tests for this."),
            ("Send the draft to Anna and then to Ben.", "Send the draft to Ben and then to Anna."),
            ("I never said that.", "I said that."),
            ("We cannot ship this today.", "We can ship this today."),
            ("I will delete the backups.", "I delete the backups."),
            ("I would delete the backups.", "I delete the backups."),
            ("We should deploy on Friday.", "We shouldn’t deploy on Friday."),
            ("It's not actually broken.", "It's broken."),
            ("I don't actually know.", "I know."),
            (
                "We should not merge it if CI is not green.",
                "We should merge it if CI is not green.",
            ),
            ("It doesn't build and it doesn't run.", "It builds and it doesn't run."),
            ("Never push to main and never force push.", "Push to main and never force push."),
            ("Nobody touched the database.", "Somebody touched the database."),
            ("There's nothing wrong with the build.", "There's something wrong with the build."),
            ("None of the tests pass.", "All of the tests pass."),
            ("Ship it without the migration.", "Ship it with the migration."),
            ("Neither option works for me.", "Either option works for me."),
            ("We should go nowhere near prod.", "We should go somewhere near prod."),
            ("Can you send it? Thanks.", "Can you send it? Sure. Thanks."),
            (
                "What's the capital of France? I need it for the quiz.",
                "What's the capital of France? Paris. I need it for the quiz.",
            ),
            (
                "Tell me a joke.",
                "Tell me a joke. Why did the chicken cross the road? To get to the other side.",
            ),
            ("Send the report to the team.", "Send the report to the entire marketing team today."),
            (
                "Send the report to the team today.",
                "Send the final quarterly sales report to the team today.",
            ),
            ("The capital of France is", "The capital of France is Paris."),
            # A synonym is no fix, and glossary words replace only lost words, never one said.
            ("Update mise now.", "Update mice now."),
            (
                "Please check the server logs and tell me what broke.",
                "Please review the server logs and inform me what failed.",
            ),
            (
                "Open the terminal, then run the update.",
                "Open the Ghostty terminal, then run the mise yabai update.",
            ),
            # A short input loses at most 2 words (or 30%).
            ("Send the report to a reviewer on the team.", "Send report to reviewer team."),
            (standup, f"{standup} Domain vocabulary: {', '.join(engine.glossary({}))}."),
            (f"{standup} {pricing} {closed}", f"{standup} {closed}"),
            # A cue takes back at most the 6 words before it.
            (
                (
                    "I think we should move the standup to ten tomorrow because half the team is "
                    "out, actually nobody has prepared the demo yet."
                ),
                "Nobody has prepared the demo yet.",
            ),
        ]
    ],
    lambda pair: dictate(*pair),
)
# A reply in place of a trailing stall.
check(
    "guard rejects a reply after a stall",
    [(("Thanks, um.", "Thanks. Okay."), None)],
    lambda pair: dictate(*pair),
)
# Entries match as word runs, 's dropped: "Node.js" is "node js", "A/B" protects no lone "a".
entries = ["yt-dlp", "Node.js", "Claude Code", "A/B", "McDonald's"]
check(
    "guard keeps hyphenated, dotted, and multi-word glossary entries",
    [
        (("Use yt-dlp for that.", "Use YouTube-DL for that."), True),
        (("Rewrite the server in Node.js today.", "Rewrite the server in Deno today."), True),
        (("Open it in Claude Code.", "Open it in Cloud Code."), True),
        (("Open Claude Code's config.", "Open Cloud Code's config."), True),
        (("Meet me at McDonald's.", "Meet me at Macy's."), True),
        (("Open it in cloud code.", "Open it in Claude Code."), False),
        (("Open Claude Code, no wait, open Cursor.", "Open Cursor."), False),
        (("I need a, uh, the report.", "I need the report."), False),
    ],
    lambda pair: server.Engine.looks_rewritten(pair[0], pair[1], entries),
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
        ("Привееет", "Привееет"),
        ("It cost 1000 dollars...", "It cost 1000 dollars..."),
        ("Use <div> here.", "Use <div> here."),
    ],
    lambda text: parakeet.transcribe(text, []),
)


def load_adapter(files):
    """MlxLmCleaner.load with an adapter download holding `files`; its prompt, or the failure."""
    with tempfile.TemporaryDirectory() as folder:
        for name, text in files.items():
            Path(folder, name).write_text(text)
        cleaner = server.MlxLmCleaner("stub", "0" * 40, "stub/adapter", "0" * 40, 400)
        loaded = (None, SimpleNamespace(get_vocab=dict))
        with (
            mock.patch("huggingface_hub.snapshot_download", lambda *_, **__: folder),
            mock.patch("mlx_lm.load", lambda *_, **__: loaded),
        ):
            try:
                cleaner.load()
            except ValueError as error:
                return str(error)
        return cleaner.frozen_prompt


check(
    "an adapter loads only with the prompt it was trained on",
    [
        ({"system_v2.txt": "Clean it.\n"}, "Clean it."),
        ({}, "cleanup adapter stub/adapter has no system_v2.txt prompt"),
        ({"system_v2.txt": " \n"}, "cleanup adapter stub/adapter has no system_v2.txt prompt"),
    ],
    load_adapter,
)
check(
    "vocabulary prefixes",
    [
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
        # Punctuation ends the word: "ok." never continues into "oki".
        (([{"▁ok": 30}, {".": 30}, {"i": 20, "▁me": 21}], ["Oki"], 4.5), " ok. me"),
    ],
    lambda case: speak(*case),
)
