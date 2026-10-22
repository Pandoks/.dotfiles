"""Check real probe failures and profile validation without changing URL handlers."""

import copy
import datetime
import importlib.util
import json
import plistlib
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("provision", root / "url_router/provision.py")
assert spec and spec.loader
provision = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provision)

key = "com.apple.developer.associated-domains.applinks.read-write"
bundle = "local.pandoks.HammerspoonURLRouter"
application = {"CFBundleIdentifier": bundle}
profile = {
    "Entitlements": {
        key: True,
        "com.apple.application-identifier": "PREFIX." + bundle,
        "com.apple.developer.team-identifier": "TEAM",
        "com.apple.security.get-task-allow": True,
        "keychain-access-groups": ["unrelated"],
    },
    "ApplicationIdentifierPrefix": ["PREFIX"],
    "TeamIdentifier": ["TEAM"],
    "ExpirationDate": datetime.datetime.now(datetime.timezone.utc)
    + datetime.timedelta(days=1),
}
selected = provision.prepare(profile, application)
assert selected == {
    key: True,
    "com.apple.application-identifier": "PREFIX." + bundle,
    "com.apple.developer.team-identifier": "TEAM",
}
print("PASS signing only claims required entitlements; app prefix need not equal team")

for name, field, value, entitlements in [
    ("missing authorization", key, None, True),
    ("false authorization", key, False, True),
    ("string authorization", key, "true", True),
    ("wrong app", "com.apple.application-identifier", "PREFIX.other.app", True),
    ("wrong prefix", "ApplicationIdentifierPrefix", ["OTHER"], False),
    ("wildcard app", "com.apple.application-identifier", "PREFIX.*", True),
    ("wrong team", "TeamIdentifier", ["OTHER"], False),
    ("missing team", "com.apple.developer.team-identifier", None, True),
    ("expired profile", "ExpirationDate", datetime.datetime(2000, 1, 1, tzinfo=datetime.timezone.utc), False),
    ("missing expiry", "ExpirationDate", None, False),
]:
    candidate = copy.deepcopy(profile)
    target = candidate["Entitlements"] if entitlements else candidate
    target[field] = value
    try:
        provision.prepare(candidate, application)
    except ValueError:
        pass
    else:
        raise AssertionError(name)
    print("PASS signing rejects " + name)

for candidate in [None, {"Entitlements": []}]:
    try:
        provision.prepare(candidate, application)
    except TypeError:
        pass
    else:
        raise AssertionError("malformed profile accepted")
print("PASS signing rejects malformed profile structures")

with tempfile.TemporaryDirectory(prefix="url-signing-test.", dir="/var/tmp") as directory:
    directory = Path(directory)
    app = directory / "Probe.app"
    build = ["zsh", str(root / "url_router/build.sh")]
    subprocess.run(build + [str(app)], check=True, capture_output=True, text=True)
    subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
    entitlements = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(app)], check=True, capture_output=True).stdout
    assert plistlib.loads(entitlements) == {"com.apple.application-identifier": "LOCALPROBE." + bundle}
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    assert info["NSUserActivityTypes"] == ["NSUserActivityTypeBrowsingWeb"]
    print("PASS real helper builds and passes signature verification")
    binary = app / "Contents/MacOS/HammerspoonURLRouter"
    for name, arguments, expected in [
        ("unentitled content URL", ["--inspect", "https://app.notion.com/p/sieve-data/probe"], "requires " + key),
        ("unentitled generic URL", ["--inspect", "https://example.com/"], "requires " + key),
        ("missing inspection URL", ["--inspect"], "usage:"),
        ("missing scheme", ["--inspect", "example.com"], "requires an HTTP(S) URL"),
        ("missing host", ["--inspect", "https:///"], "requires an HTTP(S) URL"),
        ("custom scheme", ["--inspect", "notion://app.notion.com/probe"], "requires an HTTP(S) URL"),
        ("invalid URL in batch", ["--inspect", "https://example.com/", "file:///tmp/probe"], "requires an HTTP(S) URL"),
    ]:
        result = subprocess.run([str(binary), *arguments], capture_output=True, text=True, timeout=10, check=False)
        assert result.returncode == 1, (name, result)
        assert result.stdout == "", (name, result.stdout)
        assert expected in result.stderr, (name, result.stderr)
        print("PASS probe " + name)

    marker = app / "preserve.txt"
    marker.write_text("existing application")
    for name, arguments, expected in [
        ("existing app", [str(app)], "must be a new application path"),
        ("invalid output", [str(directory / "output")], "must be a new application path"),
        ("partial signing arguments", [str(directory / "New.app"), "identity"], "usage:"),
        ("ad-hoc entitled build", [str(directory / "New.app"), "-", "missing"], "Apple signing identity is required"),
        ("missing profile", [str(directory / "New.app"), "Apple Development: unavailable", str(directory / "missing")], ""),
    ]:
        result = subprocess.run(build + arguments, capture_output=True, text=True, timeout=10, check=False)
        assert result.returncode != 0, (name, result)
        assert expected in result.stderr, (name, result.stderr)
        assert marker.read_text() == "existing application"
        assert not (directory / "New.app").exists()
        print("PASS builder rejects " + name + " without changing existing app")

    source = directory / "profile.plist"
    output = directory / "entitlements.plist"
    rejected = copy.deepcopy(profile)
    rejected["Entitlements"][key] = False
    rejected["ExpirationDate"] = rejected["ExpirationDate"].replace(tzinfo=None)
    source.write_bytes(plistlib.dumps(rejected))
    result = subprocess.run(
        ["python3", str(root / "url_router/provision.py"), str(source), str(app / "Contents/Info.plist"), str(output)],
        capture_output=True, text=True, timeout=10, check=False,
    )
    assert result.returncode != 0 and not output.exists(), result
    assert "does not authorize" in result.stderr, result.stderr
    print("PASS provisioning CLI rejects unauthorized profile without writing entitlements")

print(json.dumps({"authorized_runtime_test": "blocked: no approved profile or signing identity"}))
