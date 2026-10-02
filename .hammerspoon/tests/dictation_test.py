"""Pin the dictation backend's text pipeline and boosted decoder with stub models.

Run: .hammerspoon/dictation/.venv/bin/python .hammerspoon/tests/dictation_test.py
No model load, microphone, or Hammerspoon; only the cleanup tokenizer's small files are fetched,
once, when they are not cached yet.
"""

import functools
import os
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
            "Open C:\\ghosty\\x now.",
            "Set KEY=ghosty now.",
            "Pull ghosty:latest now.",
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
    ],
    lambda text: off.process(text, {}),
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
        (('He said, "I want the"', 'He said, "I want the."'), 'He said, "I want the"'),
        (("Can you send me the", "Can you send me the?"), "Can you send me the"),
        (("I want to go to the", "I want to go to the!"), "I want to go to the"),
        (("I want to go to the", "I want to go to."), "I want to go to the"),
        (("I want to go to the", "I want to go."), "I want to go to the"),
        (("Can you send it to my", "Can you send it?"), "Can you send it to my"),
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
        (("Thanks. And the", "Thanks."), "Thanks. And the"),
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
            ("Set opacity to .5.", "Set opacity to 0.5."),
            ("Fine, OK, send it to Jane.", "Fine, send it to Jane."),
            ("Basically we should ship it.", "We should ship it."),
            ("Email alice@example.com, no wait, bob@example.com.", "Email bob@example.com."),
            ("I will go there.", "I'll go there."),
            ("Email alice at example dot com.", "Email alice@example.com."),
            ("Me and him went.", "He and I went."),
            ("Use half the dose.", "Use ½ the dose."),
            ("I think that we should ship.", "I think we should ship."),
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
closed = "Please remind everyone the office is closed Monday."
check(
    "guard rejects rewrites",
    [
        ((raw, rewritten), raw)
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
            ("Wait fifteen minutes.", "Wait 15 seconds."),
            ("Wait fifteen minutes.", "Wait 15."),
            ("Wait fifteen long minutes.", "Wait 15 long seconds."),
            ("Drive fifteen miles per hour.", "Drive 15 miles per minute."),
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
            ("Set timeout to 50 before retrying.", "Set timeout to 50μs before retrying."),
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
            ("Email Alice today.", "Email alice@example.com today."),
            ("Use force please.", "Use --force please."),
            ("He approved it.", "They approved it."),
            ("Send it to him.", "Send it."),
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
            # A synonym is no fix, and glossary words replace only words that were lost.
            (
                "Please check the server logs and tell me what broke.",
                "Please review the server logs and inform me what failed.",
            ),
            (
                "Open the terminal, then run the update.",
                "Open the Ghostty terminal, then run the mise yabai update.",
            ),
            # A short input loses at most 2 words (or 30%).
            ("Send the big report to the whole team now.", "Send the report to the team."),
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
# A reply in place of a trailing stall: the rejected take loses only the stall.
check(
    "guard rejects a reply after a stall",
    [(("Thanks, um.", "Thanks. You're welcome!"), "Thanks.")],
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
