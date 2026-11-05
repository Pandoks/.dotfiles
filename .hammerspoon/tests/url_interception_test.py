#!/usr/bin/env python3
"""Exercise native selector/ACK boundaries and the installed swcd sandbox profile."""
import hashlib
import json
import os
from pathlib import Path
import select
import subprocess
import tarfile
import tempfile

root = Path(__file__).resolve().parents[1]
checksum = "2335b6c582a52654f94612bf10d2f4672805d05329aa6568b1d8cd9e5c6fb8e6"
with tempfile.TemporaryDirectory(prefix="url-interception-test.", dir="/var/tmp") as work:
    directory = Path(work)
    archive = os.environ.get("LUA_ARCHIVE")
    data = Path(archive).read_bytes() if archive else subprocess.check_output([
        "/usr/bin/curl", "--fail", "--silent", "--show-error", "--location", "--proto", "=https",
        "https://www.lua.org/ftp/lua-5.4.9.tar.gz",
    ])
    assert hashlib.sha256(data).hexdigest() == checksum, "Lua archive checksum mismatch"
    packed = directory / "lua.tar.gz"
    packed.write_bytes(data)
    with tarfile.open(packed) as source:
        source.extractall(directory, filter="data")
    lua = directory / "lua-5.4.9/src"
    matcher = (root / "lib/url_router/match.lua").read_bytes()
    (directory / "matcher.h").write_text("static const unsigned char matcher[] = {" + ",".join(map(str, matcher)) + "};\n")
    objects = []
    for source in sorted(lua.glob("*.c")):
        if source.name in ("lua.c", "luac.c"):
            continue
        output = directory / (source.stem + ".o")
        subprocess.run(["clang", "-arch", "arm64", "-O2", "-fPIC", "-DLUA_USE_MACOSX", "-I", str(lua), "-c", str(source), "-o", str(output)], check=True)
        objects.append(str(output))
    binary = directory / "test"
    sources = [root / "tests/url_interception_test.m"] + [root / "url_router/interception" / (name + ".m") for name in ("selectors", "status", "platform")]
    subprocess.run(["clang", "-arch", "arm64", "-O2", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-I", str(lua), "-I", str(directory), "-I", str(root / "url_router/interception"), *map(str, sources), *objects, "-framework", "Foundation", "-framework", "Security", "-lbsm", "-o", str(binary)], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", str(binary)], check=True)
    hook = directory / "hook.dylib"
    subprocess.run(["clang", "-arch", "arm64", "-O2", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-dynamiclib", "-I", str(lua), "-I", str(directory), "-I", str(root / "url_router/interception"), str(root / "url_router/interception/hook.m"), *map(str, sources[1:]), *objects, "-framework", "Foundation", "-framework", "Security", "-lbsm", "-o", str(hook)], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", str(hook)], check=True)
    hooked = directory / "hooked"
    subprocess.run(["clang", "-arch", "arm64", "-O2", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-DURL_ROUTER_FAKE_PLATFORM", "-I", str(lua), "-I", str(directory), "-I", str(root / "url_router/interception"), str(sources[0]), str(root / "url_router/interception/hook.m"), *map(str, sources[1:3]), *objects, "-framework", "Foundation", "-o", str(hooked)], check=True)
    selectors = directory / "selectors"
    selectors.mkdir(mode=0o700)
    cache = subprocess.check_output(["getconf", "DARWIN_USER_CACHE_DIR"], text=True).strip()
    with tempfile.TemporaryDirectory(prefix="url-interception-status.", dir=cache) as status:
        environment = {key: value for key, value in os.environ.items() if not key.startswith("URL_ROUTER_")}
        environment["DYLD_INSERT_LIBRARIES"] = str(hook)
        arguments = [str(binary), str(selectors), status, "status-snapshot"]
        result = subprocess.run(arguments, env=environment, text=True, capture_output=True, timeout=10)
        assert result.returncode == 0 and result.stdout, "Missing status path must leave the daemon running unhooked"
        environment["URL_ROUTER_STATUS_PATH"] = str(Path(status) / "status.json")
        result = subprocess.run(arguments, env=environment, text=True, capture_output=True, timeout=10)
        assert result.returncode == 0 and result.stdout, "Missing trusted target must leave the daemon running unhooked"
        event = json.loads((Path(status) / "status.json").read_text())
        build = subprocess.check_output(["sysctl", "-n", "kern.osversion"], text=True).strip()
        stage = "runtime" if "validated only" in event["error"] else "environment"
        assert event["kind"] == "error" and event["stage"] == stage and event["macOSBuild"] == build, event
        print("PASS actual injected constructor: missing status/target environment returns to the host process instead of exiting")
        (selectors / "rules.json").write_text('{"version":1,"generation":"regular-control","rules":[{"host":"ramp.com"}]}')
        for mode, expected in ((0o770, "watch-open"), (0o700, "loaded")):
            selectors.chmod(mode)
            result = subprocess.run([str(binary), str(selectors), status, "snapshot"], capture_output=True, text=True, timeout=2)
            assert result.returncode == 0 and result.stdout.strip() == expected, result
        print("PASS an unsafe selector directory withholds the store while a regular snapshot loads")
        statusfile = Path(status) / "status.json"
        contents = statusfile.read_bytes()
        statusfile.unlink()
        os.mkfifo(statusfile, 0o600)
        result = subprocess.run([str(binary), str(selectors), status, "status-snapshot"], capture_output=True, text=True, timeout=2)
        assert result.returncode == 0 and result.stdout.strip() == "error 22", result
        statusfile.unlink()
        statusfile.write_bytes(contents)
        result = subprocess.run([str(binary), str(selectors), status, "status-snapshot"], capture_output=True, text=True, timeout=2)
        assert result.returncode == 0 and result.stdout.strip() == "loaded", result
        print("PASS probe status reader rejects FIFO promptly and accepts a regular acknowledgement")
        subprocess.run([str(binary), str(selectors), status, "normal"], check=True, timeout=30)
        claimed = directory / "claimed"
        claimed.mkdir(mode=0o700)
        (claimed / "rules.json").write_text('{"version":1,"generation":"hook","rules":[{"host":"ramp.com"}]}')
        hooking = Path(status) / "hook"
        variables = {"STATUS_PATH": hooking / "status.json", "SELECTORS_PATH": claimed / "rules.json",
                     "APP_PATH": "fake", "APPLICATION_IDENTIFIER": "fake", "CODE_HASH": "fake"}
        environment = {key: value for key, value in os.environ.items() if not key.startswith("URL_ROUTER_")}
        environment.update({"URL_ROUTER_" + key: str(value) for key, value in variables.items()})
        subprocess.run([str(hooked), str(claimed), str(hooking), "hook"], env=environment, check=True, timeout=30)
        (selectors / "rules.json").write_text('{"version":1,"generation":"sandbox","rules":[{"host":"ramp.com"}]}')
        cold = Path(status) / "cold-session"
        with subprocess.Popen([str(binary), str(selectors), str(cold), "sandbox"], stdout=subprocess.PIPE, text=True) as child:
            assert child.stdout is not None
            assert select.select([child.stdout], [], [], 10)[0], "Sandbox watcher initialization timed out"
            assert child.stdout.readline().strip() == "READY sandbox watcher", "Sandbox watcher failed before starting"
            assert cold.is_dir() and cold.stat().st_mode & 0o777 == 0o700, "Cold session did not recreate a private status directory"
            replacement = selectors / "replacement.json"
            replacement.write_text('{"version":1,"generation":"sandbox-reload","rules":[{"host":"notion.com"}]}')
            replacement.replace(selectors / "rules.json")
            output, _ = child.communicate(timeout=10)
            assert child.returncode == 0, "Sandbox selector update failed"
            print(output, end="")
