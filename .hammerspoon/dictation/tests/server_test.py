import functools
import itertools
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import wave
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

os.environ["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"

import mlx.core as mx
from huggingface_hub import snapshot_download
from huggingface_hub.errors import LocalEntryNotFoundError
from mlx_lm.utils import load_tokenizer
from parakeet_mlx import ParakeetTDT

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import models
import server

engine = server.Engine(
    {
        "speech": {"backend": "parakeet-mlx", "model": "stub", "revision": "0" * 40},
        "cleanup": False,
        "words": {
            "Raycast": ["ray cast", "re cast", "ray cost"],
            "yabai": ["yabe", "ya bye", "yah bye"],
            "Hammerspoon": ["hammer spoon", "hammers spoon"],
            "Ghostty": ["ghosty", "ghost tea", "ghost e"],
            "mise": ["meez", "mees"],
            "Neovim": ["neo vim", "neo them"],
            "rtorrent": ["r torrent"],
            "macOS": ["mac os", "mac o s"],
            "GitHub": ["git hub"],
            "Slack": [],
            "Oki": [],
            "Uniqlo": ["unicolo", "uni clo", "uni klo", "uni clow", "une clo", "une klo"],
        },
    }
)
# defaults.lua's cleanup tokenizer (the real words Engine.load adds), from files mlx_lm.load caches.
tokenizer_files = {
    "repo_id": "mlx-community/Qwen3.5-2B-MLX-4bit",
    "revision": "93760be4f1f69842a46bc13dbdc0f19e291392a3",
    "allow_patterns": ["*.json", "*.jinja"],
}
try:
    cleanup = snapshot_download(**tokenizer_files, local_files_only=True)
except LocalEntryNotFoundError:  # a fresh checkout: about 26 MB, not the model
    cleanup = snapshot_download(**tokenizer_files)
tokenizer = load_tokenizer(Path(cleanup))
stub = {"model": "stub", "revision": "0" * 40}
engine.speech, engine.cleaner = SimpleNamespace(repo="stub", load=lambda: None), models.MlxLm(stub)
with mock.patch("mlx_lm.load", lambda *_, **__: (None, tokenizer)):
    engine.load()


def check(name, cases, function):
    for given, expected in cases:
        got = function(given)
        assert got == expected, f"{name}: {given!r} -> {got!r}, expected {expected!r}"
    print(f"PASS {name}")


def dictate(raw, cleaned=None, numbers=False):
    """Engine.process on `raw`, the cleanup returning `cleaned` or its input; None if rejected."""
    engine.speech = SimpleNamespace(transcribe=lambda wav, hint: wav, boost=0)
    engine.cleaner = SimpleNamespace(  # pyright: ignore[reportAttributeAccessIssue]
        prompt="prompt",
        complete=lambda messages, raw: raw if cleaned is None else cleaned,
    )
    try:
        if numbers:
            return engine.process(raw, {})
        with mock.patch.object(server, "digits", lambda text, names: text):
            return engine.process(raw, {})
    except server.Rejected:
        return None


def serve(script, takes, config="{}"):
    run = subprocess.run(
        [
            sys.executable,
            "-c",
            f"import sys, server\n{script}\nsys.argv[1:] = [{config!r}]\nserver.main()",
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
        ("Restart yabay's config.", "Restart yabai's config."),
    ],
    lambda text: engine.spell(text, {}),
)
check(
    "vocabulary keeps real words, contractions, domains, and paths",
    [
        (text, text)
        for text in [
            "The ghostly figure appeared.",
            "Let's get tacos for lunch.",
            "I switched from Emacs to Neovim.",
            "Pipe it through sort and uniq.",
            "Loki and raycasting.",
            "Open github.com please.",
            "Mail ghosty@example.com now.",
            "Mail ghosty+tag@example.com now.",
            "Open C:\\ghosty now.",
            "Open ghosty\\x now.",
            "Set KEY=ghosty now.",
            "Pull ghosty:latest now.",
            "Echo ${ghosty} now.",
            "Ping me at me@ghosty.",
            "Edit hammerspoon/init.lua now.",
            "cd ~/.hammerspoon",
            "Open ~/.config/ghostty",
            "Pass --github to it.",
            "Push to git. Hub later.",
            "You're cast as the lead.",
            "I have two Macs at home.",
            "Install uTorrent now.",
        ]
    ],
    lambda text: engine.spell(text, {}),
)
symbols = server.Engine(
    dict(
        engine.config,
        words={
            word: []
            for word in ["C++", "C#", ".NET", "A/B", "yt-dlp", "José", "naïve", "Node.js"]
            + ["O'Reilly", "Shell", "Visual Studio Code", "Москва", "Київ"]
        },
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
        ("I got a C on the net.", "I got a C on the net."),
        ("Run ytdlp now.", "Run yt-dlp now."),
        ("Jose is here.", "José is here."),
        ("JOSÉ is here.", "José is here."),
        ("From МОСКВА to КИЇВ.", "From Москва to Київ."),
        ("The nave of the church.", "The nave of the church."),
    ],
    lambda text: symbols.spell(text, {}),
)
apps = server.Engine(
    dict(engine.config, apps={"com.x": {"words": {"Zed": [], "GitHub": ["get hub"]}}})
)
check(
    "an app's words apply only while it is in front, added to the others",
    [
        (({"app": "com.x"}, "Use zed."), "Use Zed."),
        (({}, "Use zed."), "Use zed."),
        (({"app": "com.x"}, "Push to git hub, then get hub."), "Push to GitHub, then GitHub."),
    ],
    lambda pair: apps.spell(pair[1], pair[0]),
)
nested = server.Engine(
    dict(
        engine.config,
        words={"Ray": ["rey"], "Raycast": ["rey cast"], "Hammerspoon": ["hammer", "hammer spoon"]},
    )
)
check(
    "a longer mishearing wins over one inside it",
    [
        ("Open rey cast now.", "Open Raycast now."),
        ("Ask rey.", "Ask Ray."),
        ("Open hammer spoon now.", "Open Hammerspoon now."),
    ],
    lambda text: nested.spell(text, {}),
)
latex = server.Engine(dict(engine.config, words={"\\LaTeX": ["latex"], "\\frac": ["frac"]}))
check(
    "a word goes in as written",
    [("Write it in latex with frac.", "Write it in \\LaTeX with \\frac.")],
    lambda text: latex.spell(text, {}),
)
# Cleanup off: no tokenizer words, so only macOS's word list keeps real words.
off = server.Engine(engine.config)
off.speech = SimpleNamespace(transcribe=lambda wav, hint: wav, boost=0)
check(
    "cleanup off fixes spellings, numbers, stalls, and unfinished ends, keeping real words; stalls"
    " alone are no speech",
    [
        ("I missed the bus.", "I missed the bus."),
        ("She misses her family.", "She misses her family."),
        ("Ghost tea is my terminal.", "Ghostty is my terminal."),
        ("I want three things.", "I want 3 things."),
        ("Um, yabai is, uh, open.", "yabai is open."),
        ("Send it to.", "Send it to"),
        ("Ah, um.", ""),
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
        ("Lunch at 12.30 works for me.", "Lunch at 12:30 works for me."),
        ("The train at 7.15 leaves from platform 2.", "The train at 7:15 leaves from platform 2."),
        ("Cut it at 2.45 meters or at 2.45 inches.", "Cut it at 2.45 meters or at 2.45 inches."),
        ("Play the video at 1.30 times speed.", "Play the video at 1.30 times speed."),
        ("The market closed at one point fifteen.", "The market closed at 1.15."),
        ("We raised at two point fifteen million dollars.", "We raised at 2.15 million dollars."),
        ("We raised at 2.15 million dollars.", "We raised at 2.15 million dollars."),
        ("Let's meet between 3.30 and 4.30 p.m.", "Let's meet between 3:30 and 4:30 p.m."),
        (
            "It moved from 9.15 to 9.45, so join at 9.45.",
            "It moved from 9:15 to 9:45, so join at 9:45.",
        ),
        ("The call is between 9.15 and 10.30.", "The call is between 9:15 and 10:30."),
        ("It went from 1.15 to 1.45 dollars.", "It went from 1.15 to 1.45 dollars."),
        ("Pick between 2.5 and 3.5.", "Pick between 2.5 and 3.5."),
        ("At 3.30 we have standup.", "At 3:30 we have standup."),
        ("The call is 4.45 pm.", "The call is 4:45 pm."),
        ("Version one point two point three.", "Version 1.2.3."),
        ("Set it to zero point twenty five.", "Set it to 0.25."),
        ("This is the one hundred and twenty first time.", "This is the 121st time."),
        ("This is the one hundred and first time.", "This is the 101st time."),
        ("The one hundred and twelfth day.", "The 112th day."),
        ("Music from the nineteen eighties.", "Music from the 1980s."),
        ("In the two thousand twenties.", "In the two thousand twenties."),
        ("A million people came.", "1 million people came."),
        ("The call is three thirty pm.", "The call is 3:30 pm."),
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
        ("It weighs a hundred oh five pounds.", "It weighs a hundred oh five pounds."),
        ("Meet at twelve oh one.", "Meet at 12:01."),
        ("Set the rate to one point oh five.", "Set the rate to 1.05."),
        ("Room one oh one point five.", "Room 101.5."),
        ("Call at eight oh oh tomorrow.", "Call at 8:00 tomorrow."),
        ("The server returned five oh oh.", "The server returned 500."),
        ("The latency peaked at 1.15 seconds.", "The latency peaked at 1.15 seconds."),
        ("Use port eight oh eight oh.", "Use port 8080."),
        ("Dial two oh two point oh five oh.", "Dial 202.050."),
        ("The site throws four oh four a lot.", "The site throws 404 a lot."),
        ("The meeting at three thirty was cancelled.", "The meeting at 3:30 was cancelled."),
        ("Nineteen ninety nine was a great year.", "1999 was a great year."),
        ("Raise the limit to two thousand.", "Raise the limit to 2,000."),
        ("No one, two people came.", "No one, 2 people came."),
        ("At one point, five people left.", "At one point, 5 people left."),
        ("The server returned a five-oh-three.", "The server returned a 503."),
        ("Do it in this order: one, two.", "Do it in this order: 1, 2."),
        (
            "One, fix the overlay. Two, update the README.",
            "1, fix the overlay. 2, update the README.",
        ),
        (
            "Two things. One, the pill is too big and two, it's too bright.",
            "2 things. 1, the pill is too big and 2, it's too bright.",
        ),
        (
            "I tried the blue one, it's fine. One, it's fast. Two, it's cheap.",
            "I tried the blue one, it's fine. 1, it's fast. 2, it's cheap.",
        ),
        (
            "I'd pick the blue one, honestly. Two of the others are broken.",
            "I'd pick the blue one, honestly. 2 of the others are broken.",
        ),
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
        ("The year two thousand.", "The year 2000."),
        ("Last year two thousand people came.", "Last year 2,000 people came."),
        ("This year two thousand of them signed up.", "This year 2,000 of them signed up."),
        ("The two of us went to lunch.", "The two of us went to lunch."),
        ("The three tests failed.", "The 3 tests failed."),
        ("It's priced at 2.50 each.", "It's priced at 2.50 each."),
        ("Around three fifty people came.", "Around three fifty people came."),
        ("I have thirteen twenty dollar bills.", "I have thirteen twenty dollar bills."),
        ("I watched Ocean's Eleven.", "I watched Ocean's Eleven."),
        ("Capped attendance at one twenty people.", "Capped attendance at one twenty people."),
        ("Twenty One Pilots released a song.", "Twenty One Pilots released a song."),
        ("Seven Samurai is great.", "Seven Samurai is great."),
        # Names keep theirs: a path, a dotted name, a glossary entry.
        ("Open ~/two now.", "Open ~/two now."),
        ("Use three.js for it.", "Use three.js for it."),
        ("Read fifty shades today.", "Read fifty shades today."),
        ("Add a thirty-second timeout.", "Add a thirty-second timeout."),
        ("The class of two thousand eight.", "The class of 2008."),
        ("March fifth, two thousand twenty five.", "March fifth, 2025."),
        ("We sold two thousand fifty of them.", "We sold 2,050 of them."),
        ("Crash of two thousand eight, of course, hit us.", "Crash of 2008, of course, hit us."),
        ("It costs a few hundred dollars.", "It costs a few hundred dollars."),
        ("We raised half a million dollars.", "We raised half a million dollars."),
        ("They raised several million dollars.", "They raised several million dollars."),
        ("It costs five or six thousand dollars.", "It costs 5,000 or 6,000 dollars."),
        ("Count from ten to two thousand.", "Count from 10 to 2,000."),
    ],
    lambda text: server.digits(text, ["Fifty Shades"]),
)
words = ["one", "twenty", "hundred", "and", "point", "first", "eighties", "a", "thirty", "pm"]
words += ["million", "oh", "twenty-five", ","]
for size in (2, 3, 4):
    for run in itertools.product(words, repeat=size):
        server.digits(" ".join(run) + ".", ())
print("PASS no number run raises")
check(
    "a cleaned take loses its stalls before spelling, and gets its numbers as digits",
    [
        (("Um, send three copies.", None), "Send 3 copies."),
        (("Um, yabai crashed again.", None), "yabai crashed again."),
        (("Erm, I think, hmm, we should, ahm, go.", None), "I think we should go."),
        (("MM, maybe later.", None), "Maybe later."),
        (("MMM, that sounds good.", None), "That sounds good."),
    ],
    lambda pair: dictate(*pair, numbers=True),
)
check(
    "stalls, and an article said twice",
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
        ("Uh, iPhone sales are up.", "iPhone sales are up."),
        ("Uh-huh, sure.", "Uh-huh, sure."),
        ("Uh huh, sure.", "Uh huh, sure."),
        ("The umbrella is here.", "The umbrella is here."),
        ("Order it from hm.com today.", "Order it from hm.com today."),
        ("Open ~/um now.", "Open ~/um now."),
        ("Email er@acme.com please.", "Email er@acme.com please."),
        ("Um?", ""),
        ("Um ahm.", ""),
        ("The, uh, the dog ate an, um, an apple and a a pear.", "The dog ate an apple and a pear."),
        ("I got an A a week ago.", "I got an A a week ago."),
        ("Can you look at the... The overlay code?", "Can you look at the overlay code?"),
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
    server.strip_stalls,
)
check(
    "end punctuation",
    [
        ("I haven't finished yet.", "I haven't finished yet."),
        ("I didn't know that.", "I didn't know that."),
        ("Hold on.", "Hold on."),
        ("See you in May.", "See you in May."),
        ("I'd love to.", "I'd love to."),
        ("Let's go with option A.", "Let's go with option A."),
        ("Take him to the OR.", "Take him to the OR."),
        ("Oh my!", "Oh my!"),
        ("What if?", "What if?"),
        ("Let me check and, uh.", "Let me check and"),
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
        (("Send it to", "Send it."), "Send it to"),
        (("We can ship it unless", "We can ship it unless."), "We can ship it unless"),
        (("So I was thinking, you know, and", "So I was thinking."), "So I was thinking, and"),
        (("I think so, but", "I think."), "I think so, but"),
        (("I want one like the", "I want one."), "I want one like the"),
        (("You're coming?", "You're coming."), "You're coming?"),
        (("Like, you're coming?", "You're coming."), "You're coming?"),
        (("Thanks. But", "Thanks."), "Thanks. But"),
        (("Is it ready? And", "Is it ready?"), "Is it ready? And"),
        (("Stop! And", "Stop!"), "Stop! And"),
        (("I want to go to the", "I want to go to the,"), "I want to go to the,"),
        (("Can you believe it?", "Can you believe it?!"), "Can you believe it?!"),
        (("Can you believe it?!", "Can you believe it."), "Can you believe it?"),
        (
            ("Did it work? Can you check?", "Did it work? Can you check."),
            "Did it work? Can you check?",
        ),
        (("Is it done, I wonder?", "Is it done? I wonder."), "Is it done? I wonder."),
        (("I want to go to the", "I want to go to the…"), "I want to go to the"),
        (("Let me check and…", "Let me check and."), "Let me check and"),
        (("I want to go to the", "I want to go to the—"), "I want to go to the"),
        (("He said I want the", 'He said, "I want the."'), 'He said, "I want the"'),
        # A cut word comes back after the comma or colon said before it, inside closing quotes.
        (("Send it to John, and", "Send it to John."), "Send it to John, and"),
        (("Send it to John and", "Send it to John,"), "Send it to John, and"),
        (("Send it to John, and", "Send it to John,"), "Send it to John, and"),
        (("The plan is simple: the", "The plan is simple."), "The plan is simple: the"),
        (('He said "yes", and', 'He said "yes."'), 'He said "yes", and'),
        (('He said "yes." And', 'He said "yes."'), 'He said "yes." And'),
        # The cleanup's capitals and curly marks: "API" matches "api", "it’s" matches "it's".
        (("Check the api and", "Check the API."), "Check the API and"),
        (("I think it's the", "I think it’s."), "I think it’s the"),
        (("He said I want the", "He said, “I want the.”"), "He said, “I want the”"),
        (("Send it to the dogs and", "Send it to the dogs’."), "Send it to the dogs’ and"),
        (("Don't you think so?", "Don’t you think so."), "Don’t you think so?"),
        # A straight ' after an end mark closes a quote too; one inside a word opens none.
        (('"Can you help?"', '"Can you help."'), '"Can you help?"'),
        (("He said 'yes', and", "He said 'yes.'"), "He said 'yes', and"),
        (("He said ‘yes’, and", "He said ‘yes.’"), "He said ‘yes’, and"),
        (("He said 'yes.' And", "He said 'yes.'"), "He said 'yes.' And"),
        (("In the '90s, the kids' and", "In the '90s, the kids'."), "In the '90s, the kids' and"),
        (
            ("He asked me. Are you coming?", "He asked me. 'Are you coming.'"),
            "He asked me. 'Are you coming?'",
        ),
        # The speech model's '?' is kept, not one it never put: a retracted question.
        (("Is it ready? No wait, just ship it.", "Just ship it."), "Just ship it."),
        (("Sounds good. Yeah?", "Sounds good."), "Sounds good."),
        (("It's broken again, you know?", "It's broken again."), "It's broken again."),
        (("Take the car and the", "Take the car."), "Take the car and the"),
        (
            ("Can you send it to John, no wait, to Jane?", "Can you send it to Jane."),
            "Can you send it to Jane?",
        ),
    ],
    lambda pair: dictate(*pair),
)
check(
    "the guard accepts these cleanups",
    [
        (pair, pair[1])
        for pair in [
            ("The issue is, yeah, nobody tested it.", "The issue is nobody tested it."),
            (
                "Um, so, do you want pasta or, or, or pizza for dinner?",
                "Do you want pasta or pizza for dinner?",
            ),
            ("Turn it on. On Friday.", "Turn it on Friday."),
            ("I need one ticket, no, two.", "I need two tickets."),
            ("I need two tickets, no, no, three.", "I need three tickets."),
            ("Book two rooms, no, sorry, three.", "Book three rooms."),
            (
                "Book two rooms, sorry, three rooms for Tuesday. Can you do that?",
                "Book three rooms for Tuesday. Can you do that?",
            ),
            (
                "I keep telling the team that, you know, you have to test it.",
                "I keep telling the team that you have to test it.",
            ),
            ("Don't merge it, scratch that, merge it.", "Merge it."),
            ("I'll take the blue one actually.", "I'll take the blue one."),
            (
                "Set the timeout to 30 seconds actually. Make it 60 seconds.",
                "Set the timeout to 60 seconds.",
            ),
            (
                "Please print ten copies of the report, sorry, twelve.",
                "Please print twelve copies of the report.",
            ),
            (
                "Schedule it for next Tuesday at ten, no wait, Wednesday.",
                "Schedule it for Wednesday at ten.",
            ),
            ("Email Lisa Tuesday, actually, Karen.", "Email Karen Tuesday."),
            ("The review is Thursday. Uh, sorry, Friday.", "The review is Friday."),
            ("We need five chairs, I mean six.", "We need six chairs."),
            ("Is that right? So we ship it.", "Is that right? We ship it."),
            (
                "Book it for Monday, sorry, Tuesday for your team, if you can.",
                "Book it for Tuesday for your team, if you can.",
            ),
            (
                "Couldn't we do Monday, sorry, Tuesday after lunch?",
                "Couldn't we do Tuesday after lunch?",
            ),
            ("Fine by me yeah.", "Fine by me."),
            ("Like you're being very vague.", "You're being very vague."),
            ("Can you make one? Like I forgot its name.", "Can you make one? I forgot its name."),
            ("It's like so slow.", "It's so slow."),
            ("I'm like so tired.", "I'm so tired."),
            ("That's the one that you know, I told you about.", "That's the one I told you about."),
            ("Show 10² rows, not ①.", "Show 10² rows, not ①."),
            ("Meet İbrahim Monday, sorry, Tuesday.", "Meet İbrahim Tuesday."),
            ("I don't know weather to go.", "I don't know whether to go."),
            ("Send me an e mail.", "Send me an email."),
            ("Call me at 1.30pm.", "Call me at 1:30 pm."),
            ("I counted to 10 oh my god it was huge.", "I counted to 10, oh my god it was huge."),
            ("Meet at eight oh five.", "Meet at 8:05."),
            ("Meet at 10 oh 5.", "Meet at 10:05."),
            ("Test testing one two.", "Testing one two."),
            ("Run it with, without the cache.", "Run it without the cache."),
            ("The meeting took about, about an hour.", "The meeting took about an hour."),
            ("It's on the 2nd, 2nd floor.", "It's on the 2nd floor."),
            ("It's the forth quarter already.", "It's the fourth quarter already."),
            ("Um, so I think we should ship it.", "I think we should ship it."),
        ]
    ],
    lambda pair: server.restore(*pair),
)
check(
    "what a cleanup left out or changed beyond its rules is typed as said, or the take is rejected",
    [
        ((raw, out), raw)
        for raw, out in [
            ("It's always been like that.", "It's always been that."),
            ("He's like my best friend.", "He's my best friend."),
            ("It should be like the Raycast one.", "It should be the Raycast one."),
            ("It's like a car.", "It's a car."),
            ("Delete all files except logs.", "Delete all files."),
            ("Include the tests.", "Exclude the tests."),
            ("I can, I can't come tonight.", "I can come tonight."),
            ("I could, I couldn't come tonight.", "I could come tonight."),
            ("We raised a billion dollars.", "We raised a million dollars."),
            ("Don't lose it.", "Don't loose it."),
            ("Send 15000 dollars.", "Send 150000 dollars."),
            ("It costs 14.99.", "It costs 1499."),
            ("Meet at five forty five.", "Meet at five-fort-five."),
            ("Turn the volume up, sorry, down.", "Turn the volume up."),
            ("Turn the volume up, wait, no, down.", "Turn the volume up, down."),
            ("npm install dash dash save dev", "npm install dash save dev"),
            ("Meet at seven seventeen.", "Meet at seven."),
            ("I think he knows you know.", "I think he knows you."),
            ("Send it tomorrow, I'm sorry, tonight.", "Send it tonight tomorrow."),
            ("We're full, sorry, thank you.", "Thank you."),
            ("The meeting isn't on Monday, sorry, Tuesday.", "The meeting isn't on Tuesday."),
            ("Should I bring a jacket? Probably not, no.", "Should I bring a jacket?"),
            ("Call 555 555 1234.", "Call 555 1234."),
            ("Ship 4 units to Denver and 6, sorry, 8 to Austin.", "Ship 8 to Austin."),
            ("Ship 4 units to Denver and 6, sorry, 8 to Austin.", "Ship 8 units to Austin."),
            (
                "Order a pepperoni pizza and a salad for the table, sorry, two salads.",
                "Order two salads for the table.",
            ),
            (
                "The meeting is at four, actually, can we push it to five?",
                "The meeting is at five.",
            ),
            ("Don't, don't delete it.", "Delete it."),
            ("Take him to the ER now.", "Take him to the now."),
            ("Let's go with plan A", "Let's go with plan."),
            ("Room two oh one is free.", "Room two one is free."),
            ("Delete the master branch.", "Delete the faster branch."),
            ("I think so.", "I think."),
            ("Run it with, without the cache.", "Run it with the cache."),
            ("It's on the fifteenth.", "It's on the fiftieth."),
            ("It's the seventh.", "It's the seventy."),
            ("Call me, we can talk later tonight.", "Call me later tonight."),
            ("I checked; the logs are clean anyway.", "I checked anyway."),
            (
                "I might try a smaller adapter, or maybe just cache the prompt prefix.",
                "I might try a smaller adapter. Maybe just cache the prompt prefix.",
            ),
            ("It runs now, and Neovim is fast.", "It runs now. Neovim is fast."),
            ("Shopping list eggs milk bread and butter", "- Eggs\n- Milk\n- Bread\n- Butter"),
            ("Shopping list eggs milk bread and butter", "- Eggs\r- Milk\r- Bread\r- Butter"),
            ("Name tab age tab city.", "Name\tage\tcity."),
            ("I guess so.", "I guessed so."),
            ("We miss missed the bus this morning.", "We missed the bus this morning."),
            ("Uh-huh.", "Huh."),
            ("Uh huh.", "Huh."),
            ("Like I said the deploy failed again.", "I said the deploy failed again."),
            ("It costs one thousand dollars.", "It costs 1,000 dollars."),
            ("It costs 1,000 dollars.", "It costs 1.00 dollars."),
        ]
    ]
    + [
        (("Add 0.5 cups.", "Add 0.05 cups."), None),
        (("Meet at 10 oh 5 tomorrow.", "Meet at 10:5 tomorrow."), None),
        (
            (
                "So the plan is. First we update the docs. Then we, um, release it on Friday.",
                "So the plan is to update the docs and release it on Friday.",
            ),
            "So the plan is. First we update the docs. Then we release it on Friday.",
        ),
        (
            (
                "Can we have the styles as configs, um, with that?",
                "Can we have the styles as configs?",
            ),
            "Can we have the styles as configs with that?",
        ),
        (("You know the drill.", "The drill."), "You know the drill."),
        (("Uh, honestly, just ship it.", "Just ship it."), "Honestly, just ship it."),
        (("Send it to Bob.", "Please send it to Bob."), "Send it to Bob."),
        (("Send it to Bob.", "Send it to Bob now."), "Send it to Bob."),
        (
            ("You shouldn't deploy on Friday with that.", "You should deploy on Friday."),
            "You shouldn't deploy on Friday with that.",
        ),
        (("Call at eight oh oh tomorrow.", "Call at eight oh tomorrow."), None),
        # The marks, capitals, and apostrophes said, not the cleanup's, around what comes back.
        (
            ("Oh, like the here? Can you print these?", "Can you print these?"),
            "Oh, like the here? Can you print these?",
        ),
        (
            ("Is it done? I think it is. Ship it.", "Is it done? Ship it."),
            "Is it done? I think it is. Ship it.",
        ),
        (("I think so.", "Yes, I think so."), "I think so."),
        (
            (
                "Can you look at the logs or something? Could you could you make it darker?",
                "Can you look at the logs? Could you make it darker?",
            ),
            "Can you look at the logs or something? Could you could you make it darker?",
        ),
        (("Okay. Um, the build broke. Fix it.", "Okay. Fix it."), "Okay. The build broke. Fix it."),
        (("Fix it. Um. Thanks for that.", "Fix it."), "Fix it. Thanks for that."),
        (("'Cause I need it.", "Because I need it."), "'Cause I need it."),
        (
            (
                "Then put it in one of the corners, probably bottom left or bottom right, and.",
                "Then put it in one of the corners.",
            ),
            "Then put it in one of the corners, probably bottom left or bottom right, and",
        ),
        (("Room one oh one point five.", "Room one oh point five."), None),
        (
            ("I'm done. Is it done? Ship it.", "I'm done. Ship it."),
            "I'm done. Is it done? Ship it.",
        ),
        (("Take 1.5 one hour breaks.", "Take one hour breaks."), "Take 1.5 one hour breaks."),
        (
            ("Can you fix it? Ship it.", "Can you fix it? Sure. Ship it."),
            "Can you fix it? Ship it.",
        ),
        (
            ("Check the logs first. Then restart it.", "Check the logs, then restart it."),
            "Check the logs first. Then restart it.",
        ),
        (
            ("How do we fix it? Can you fix it? Just fix it.", "How do we fix it? Can you fix it?"),
            "How do we fix it? Can you fix it? Just fix it.",
        ),
        (
            (
                "Make it discreet and friendly, I guess? Then put it in a corner.",
                "Make it discreet and friendly? Then put it in a corner.",
            ),
            "Make it discreet and friendly, I guess? Then put it in a corner.",
        ),
        (
            (
                "We're facing a lot of like something being written.",
                "We're facing a lot of something being written.",
            ),
            "We're facing a lot of like something being written.",
        ),
        (
            ("Did you also restart T Through?", "Did you also restart T?"),
            "Did you also restart T Through?",
        ),
        (
            ("You shouldn't deploy on Friday.", "You should deploy on Friday."),
            "You shouldn't deploy on Friday.",
        ),
        (("What's the capital of France?", "Paris."), "What's the capital of France?"),
    ],
    lambda pair: dictate(*pair),
)
check(
    "any script's words count as speech; stalls alone are none, and a cleanup with no words types"
    " nothing if it left out only stalls and fillers, else is rejected",
    [
        (("Привет, как дела?", None), "Привет, как дела?"),
        (("你好，今天天气很好。", None), "你好，今天天气很好。"),
        (("42", None), "42"),
        (("Hum?", None), ""),
        (("Like.", "."), ""),
        (("Like", ""), ""),
        (("Hmm, you know.", "Hmm."), ""),
        (("Hmm, just fix it.", "Hmm."), None),
    ],
    lambda pair: dictate(*pair),
)
engine.speech = SimpleNamespace(transcribe=lambda wav, hint: "Mmm wha blah", boost=0)
engine.cleaner = SimpleNamespace(  # pyright: ignore[reportAttributeAccessIssue]
    prompt="prompt", complete=lambda messages, raw: ""
)
try:
    engine.process("take.wav", {})
    raise AssertionError("an empty cleanup was typed")
except server.Rejected as error:
    assert "no words" in str(error) and engine.heard == "Mmm wha blah", engine.heard
print("PASS an empty cleanup is reported, not typed, and keeps what was heard")

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
assert events == [{"event": "ready"}, {"event": "final", "id": 1, "text": "ok"}]
assert "native chatter" in stderr, stderr
print("PASS a library that prints cannot corrupt the protocol")
events, stderr = serve("", [], config='{"speech": {"backend": "nope"}}')
assert [e["event"] for e in events] == ["error"] and "id" not in events[0], events
assert "nope" in events[0]["msg"] and "Traceback" in stderr, (events, stderr)
failing = """
class Failing(server.Engine):
    def load(self):
        raise RuntimeError("no weights")
server.Engine = Failing
"""
config = json.dumps(
    {
        "speech": {"backend": "parakeet-mlx", "model": "s", "revision": "0" * 40},
        "cleanup": False,
    }
)
events, stderr = serve(failing, [], config=config)
assert [e["event"] for e in events] == ["error"] and "no weights" in events[0]["msg"], events
print("PASS a failed load reports an error and never ready")
# Hammerspoon never closes stdin: replies, and what libraries print, must arrive while it is open.
live = subprocess.Popen(
    [sys.executable, "-c", f"import sys, server\n{chatty}\nsys.argv[1:] = ['{{}}']\nserver.main()"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    cwd=Path(server.__file__).parent,
    env={k: v for k, v in os.environ.items() if k != "PYTHONUNBUFFERED"},
)
deadline = threading.Timer(60, live.kill)
deadline.start()
try:
    assert live.stdout and live.stdin and live.stderr
    assert live.stdout.readline() == '{"event": "ready"}\n'
    assert live.stderr.readline().startswith("[WARNING] Generating"), "a print was held back"
    live.stdin.write(json.dumps({"id": 1, "wav": "x.wav"}) + "\n")
    live.stdin.flush()
    assert json.loads(live.stdout.readline())["text"] == "ok"
finally:
    deadline.cancel()
    live.kill()
    live.wait()
print("PASS replies and prints arrive while stdin is still open")
takes = """
from types import SimpleNamespace
heard = iter(["Add 0.5 cups.", "Send it."])
def transcribe(wav, hint):
    for text in heard:
        return text
    raise RuntimeError("the speech model failed")
class Stub(server.Engine):
    def __init__(self, config):
        self.config, self.heard = config, None
        self.speech = SimpleNamespace(transcribe=transcribe, boost=0)
        self.cleaner = SimpleNamespace(prompt="p")
        self.cleaner.complete = lambda m, raw: raw.replace("0.5", "0.05")
    def load(self):
        pass
server.Engine = Stub
"""
events, stderr = serve(takes, [{"id": i, "wav": "x.wav", "app": "x"} for i in (1, 2, 3)])
assert [e["event"] for e in events] == ["ready", "error", "final", "error"], (events, stderr)
assert events[1]["heard"] == "Add 0.5 cups." and "rewrote" in events[1]["msg"], events
assert events[2] == {"event": "final", "id": 2, "text": "Send it."}, events
assert events[3]["heard"] is None and "speech model failed" in events[3]["msg"], events
assert stderr.count("Traceback") == 1 and "RuntimeError: the speech model failed" in stderr, stderr
print("PASS a failed take reports what was heard, and only a bug's traceback")

# A take needing words put back trusts none of the cleanup's moved-up corrections: a shuffle of
# the said words through one would type them in another order.
said = "We need eggs, milk, and bread, no wait, eggs and bread."
got = dictate(said, "We need and milk, bread. no eggs, and bread, wait, eggs")
assert got and re.findall(r"[\w']+", got.lower()) == re.findall(r"[\w']+", said.lower()), got
print("PASS words put back keep the order said")

# The model may close the template's think block again.
cleaner = models.MlxLm(stub)
cleaner.llm, cleaner.tokenizer = None, tokenizer  # pyright: ignore[reportAttributeAccessIssue]
rendered, limits = [], []


def generate(llm, tokenizer, prompt, max_tokens=None, prompt_cache=None):
    if prompt_cache:  # as mlx-lm does, the take extends the cache it is given
        prompt_cache[0].seen += prompt
        prompt = prompt_cache[0].seen
    rendered.append(tokenizer.decode(prompt))
    limits.append(max_tokens)
    return "Thinking about it.</think>\n\nFix the bug."


long = "word " * 600
with mock.patch("mlx_lm.generate", generate):
    reply = cleaner.complete([{"role": "user", "content": "Fix the bug."}], "Fix the bug.")
    cleaner.complete([{"role": "user", "content": long}], long)
assert reply == "Fix the bug.", reply
assert rendered[0].endswith("<think>\n\n</think>\n\n"), rendered[0]  # no thinking before the reply
# mlx-lm's default 256 would cut long takes; 600 words are 600+ tokens.
assert limits[0] >= 400 and limits[1] > 600, limits
print("PASS the cleanup skips thinking, has room to echo the take, and drops a stray think tag")


class Llm:
    """Its prompt cache records the tokens it was given."""

    def make_cache(self):
        return [SimpleNamespace(state=[], seen=[])]

    def __call__(self, tokens, cache):
        cache[0].seen += tokens[0].tolist()


def load_adapter(files):
    with tempfile.TemporaryDirectory() as folder:
        for name, text in files.items():
            Path(folder, name).write_text(text)
        cleaner = models.MlxLm(dict(stub, adapter="stub/adapter", adapterRevision="0" * 40))
        with (
            mock.patch("huggingface_hub.snapshot_download", lambda *_, **__: folder),
            mock.patch("mlx_lm.load", lambda *_, **__: (Llm(), tokenizer)),
        ):
            cleaner.load()
        return cleaner


def prompt(files):
    try:
        return load_adapter(files).prompt
    except (ValueError, FileNotFoundError) as error:
        return type(error).__name__


check(
    "an adapter loads only with the prompt it was trained on",
    [
        ({"system_v2.txt": "Clean it.\n"}, "Clean it."),
        ({}, "FileNotFoundError"),
        ({"system_v2.txt": " \n"}, "ValueError"),
    ],
    prompt,
)
# Prefilled once, copied per take: each take's model sees what it would see without the prefill.
adapted = load_adapter({"system_v2.txt": "Clean it."})
with mock.patch("mlx_lm.generate", generate):
    for raw in ("Fix the bug.", "Ship it."):
        take = [{"role": "user", "content": f"Clean it.\n\n{raw}"}]
        cleaner.complete(take, raw)
        adapted.complete(take, raw)
assert rendered[2::2] == rendered[3::2], rendered[2:]
print("PASS a prefilled prompt gives each take the tokens it would have without it")


def styled(config):
    adapter = {"adapter": "stub/adapter", "adapterRevision": "0" * 40}
    try:
        cleanup = dict(stub, backend="mlx-lm", **adapter)
        server.Engine(dict(engine.config, cleanup=cleanup, **config))
    except ValueError:
        return "ValueError"
    return "ok"


check(
    "a style with an adapter, or an empty mishearing, fails the load",
    [
        ({}, "ok"),
        ({"style": "Be terse."}, "ValueError"),
        ({"apps": {"com.x": {"style": "Be terse."}}}, "ValueError"),
        ({"apps": {"com.x": {"words": {"Zed": []}}}}, "ok"),
        ({"words": {"Oki": [""]}}, "ValueError"),
        ({"apps": {"com.x": {"words": {"Zed": [" "]}}}}, "ValueError"),
    ],
    styled,
)
plain = server.Engine(
    dict(
        engine.config, style="Be terse.", apps={"com.x": {"style": "A chat."}}, words={"yabai": []}
    )
)
prompts = []
plain.speech = SimpleNamespace(transcribe=lambda wav, hint: wav, boost=0)
fake = SimpleNamespace(prompt=None, complete=lambda messages, raw: prompts.append(messages) or raw)
plain.cleaner = fake  # pyright: ignore[reportAttributeAccessIssue]
plain.process("Restart yabai.", {"app": "com.x"})
plain.config = dict(plain.config, style=False)  # pyright: ignore[reportAttributeAccessIssue]
plain.process("Restart yabai.", {})
fake.prompt = "P"
plain.process("Restart yabai.", {})
vocabulary = "Domain vocabulary (spell these exactly): yabai."
assert prompts[0] == [
    {"role": "system", "content": f"Be terse.\nA chat.\n{vocabulary}\n{server.PROMPT}"},
    {"role": "user", "content": server.FRAME.format("Restart yabai.")},
], prompts[0]
assert prompts[1][0]["content"] == f"{server.STYLE}\n{vocabulary}\n{server.PROMPT}"
# An adapter's prompt is used as trained: prompt, blank line, take.
assert prompts[2] == [{"role": "user", "content": "P\n\nRestart yabai."}], prompts[2]
print(
    "PASS a plain model gets the style, the app's, the vocabulary, the rules, then the framed take;"
    " an adapter gets its own prompt, then the take"
)


def pin(kind, settings):
    try:
        kind(settings)
    except (ValueError, TypeError) as error:
        return type(error).__name__
    return "ok"


check(
    "model revisions are commit SHAs, never a branch that moves; only false turns the cleanup off",
    [
        ((models.Parakeet, dict(stub, revision="main")), "ValueError"),
        ((models.MlxLm, dict(stub, revision="main")), "ValueError"),
        ((models.MlxLm, dict(stub, adapter="a", adapterRevision="main")), "ValueError"),
        ((server.Engine, dict(engine.config, cleanup=[])), "TypeError"),  # hs.json's {}
    ],
    lambda case: pin(*case),
)
parakeet = models.Parakeet({"model": "stub", "revision": "0" * 40})
parakeet.model = SimpleNamespace(  # pyright: ignore[reportAttributeAccessIssue]
    transcribe=lambda wav, chunk_duration: SimpleNamespace(text=wav)
)
check(
    "Parakeet drops special pieces and rare symbol runs",
    [
        ("<unk> <pad> ΨΨΨ", ""),
        (" Hello <unk> there ", "Hello there"),
        ("N<|eo|>vim<|endoftext|>", "Nvim"),
        ("Привееет", "Привееет"),
        ("Dial 000 now.", "Dial 000 now."),
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
    lambda words: models.Boosted(None, words, 0).prefixes,
)


class Model:
    """Weightless TDT model: `logits[last token][step]` is the joint output."""

    vocabulary = ("▁ok", "i", "ay", "▁g", "it", "hub", "'s", "▁me", "▁M", "e", ".")
    vocabulary += ("<unk>", "<|eo|>")
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
        """Run ParakeetTDT.decode, which calls decode_greedy as Parakeet replaces it."""
        self.decode_greedy = functools.partial(greedy, self)
        features = mx.arange(steps, dtype=mx.float32).reshape(1, steps, 1)
        tokens, states = ParakeetTDT.decode(self, features)  # pyright: ignore[reportArgumentType]
        state = states[0] and [part.item() for part in states[0]]
        return [(t.id, t.start, t.duration, t.text) for t in tokens[0]], state


# Joint outputs are tokens, blank, durations; rows are indexed by last token, -1 = none yet.
width, contexts = len(Model.vocabulary) + 1 + len(Model.durations), len(Model.vocabulary) + 2


def boosted(words, bonus):
    return lambda model, *args, **kwargs: ParakeetTDT.decode_greedy(
        models.Boosted(model, words, bonus),  # pyright: ignore[reportArgumentType]
        *args,
        **kwargs,
    )


unboosted = boosted(["Oki", "GitHub's"], 0.0)
for seed in range(20):
    model = Model(mx.random.normal((contexts, 40, width), key=mx.random.key(seed)))
    upstream = model.decode(ParakeetTDT.decode_greedy, 40)
    assert model.decode(unboosted, 40) == upstream, f"seed {seed}: differs from parakeet-mlx"
print("PASS boosted decoder with no bonus matches parakeet-mlx")

# Each frame scores pieces over -20 and each pick advances one frame; a blank frame ends it.
blank = len(Model.vocabulary)


def scores(frames):
    rows = mx.full((len(frames) + 1, width), -20.0).at[-1, blank].add(30).at[:, blank + 2].add(30)
    for step, frame in enumerate(frames):
        if not frame:
            rows = rows.at[step, blank].add(30)
        for piece, score in frame.items():
            rows = rows.at[step, Model.vocabulary.index(piece)].add(score)
    return mx.broadcast_to(rows, (contexts, *rows.shape))


def speak(frames, words, bonus):
    tokens = Model(scores(frames)).decode(boosted(words, bonus), len(frames) + 1)
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
        # After punctuation only a word start begins a vocabulary word: never "ok.it" for "Item".
        (([{"▁ok": 30}, {".": 30}, {"it": 20, "▁me": 21}], ["Item"], 4.5), " ok. me"),
        # A third piece, past a blank frame, still extends the word: hub (20 + 13.5) > e (21).
        (([{"▁g": 30}, {"it": 30}, {}, {"hub": 20, "e": 21}], ["GitHub"], 4.5), " github"),
    ],
    lambda case: speak(*case),
)


# Through parakeet-mlx's transcribe: the unboosted pass decodes the boosted pass's encoding.
class Transcriber(Model):
    decode = ParakeetTDT.decode  # pyright: ignore[reportAssignmentType]
    decode_greedy, transcribe = ParakeetTDT.decode_greedy, ParakeetTDT.transcribe
    preprocessor_config = SimpleNamespace(sample_rate=16000)

    def encoder(self, mel):
        encoded.append(mel)
        return mel, mx.array([mel.shape[1]])


encoded = []
reusing = models.Parakeet({"model": "stub", "revision": "0" * 40, "boost": 4.5})
reusing.model = Transcriber(  # pyright: ignore[reportAttributeAccessIssue]
    scores([{"▁ok": 30}, {"ay": 21, "i": 20}])
)
with (
    tempfile.TemporaryDirectory() as folder,
    mock.patch("parakeet_mlx.parakeet.load_audio", models.read),  # as Parakeet.load sets it
    mock.patch("parakeet_mlx.parakeet.get_logmel", lambda *_: mx.arange(3.0)[None, :, None]),
):
    with wave.open(f"{folder}/take.wav", "wb") as audio:  # the recorder's 16 kHz mono s16le
        audio.setparams((1, 2, 16000, 0, "NONE", ""))
        audio.writeframes(bytes(32000))
    texts = [reusing.transcribe(f"{folder}/take.wav", hint) for hint in (["Oki"], [])]
assert texts == ["oki", "okay"] and len(encoded) == 1, (texts, encoded)
print("PASS boosting encodes a take once, and the unboosted pass decodes it unboosted")
# Unboosted and boosted Parakeet decodes of TTS takes (`say -v Albert`, `-v Daniel`, ...).
check(
    "a boosted word is kept only where it spells a vocabulary word, never over a stall",
    [
        (
            ("The morning mist was thick.", "The morning mis was thick."),
            "The morning mist was thick.",
        ),
        (
            ("The Union vote is destroyed.", "The uni uni vote is destroyed."),
            "The Union vote is destroyed.",
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
        (("Mm-hmm.", "Mise."), "Mm-hmm."),
    ],
    lambda case: engine.merge(case[0], case[1], {}),
)
# Boosting decodes the take twice, once with no vocabulary to boost.
engine.speech = SimpleNamespace(transcribe=lambda wav, hint: wav[bool(hint)], boost=4.5)
engine.cleaner = None
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
