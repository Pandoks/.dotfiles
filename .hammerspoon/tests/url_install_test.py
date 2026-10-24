"""Exercise generated launchd contracts and filesystem rollback in an isolated installation."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from unittest.mock import patch

root = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("url_install", root / "url_router/install.py")
assert spec and spec.loader
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)

with tempfile.TemporaryDirectory(prefix="url-install-test.", dir="/var/tmp") as temporary:
    temporary = Path(temporary)
    original = plistlib.loads(Path("/System/Library/LaunchAgents/com.apple.swcd.plist").read_bytes())
    paths = {"hookPath": str(temporary / "hook.dylib"), "selectorsPath": str(temporary / "rules.json"),
             "statusPath": str(temporary / "status.json"), "appPath": str(temporary / "Helper.app")}
    job = installer.launchjob(original, paths, "a" * 40)
    preserved = {key: value for key, value in job.items() if key not in ("Label", "EnvironmentVariables")}
    assert preserved == {key: value for key, value in original.items() if key not in ("Label", "EnvironmentVariables")}
    assert job["Label"] == "local.pandoks.HammerspoonURLRouter.swcd"
    assert job["EnvironmentVariables"]["DYLD_INSERT_LIBRARIES"] == paths["hookPath"]
    assert job["MachServices"] == {"com.apple.SharedWebCredentials": True}
    assert plistlib.loads(plistlib.dumps(job)) == job
    assert original["Label"] == "com.apple.swcd" and "DYLD_INSERT_LIBRARIES" not in original.get("EnvironmentVariables", {})
    print("PASS launchd clone preserves Apple's Mach service, events, and execution settings")

    snapshot = temporary / "rules.json"
    source = "import importlib.util,sys; from pathlib import Path; spec=importlib.util.spec_from_file_location('installer',sys.argv[1]); owner=importlib.util.module_from_spec(spec); spec.loader.exec_module(owner); print(owner.selectors(Path(sys.argv[2])))"
    command = [sys.executable, "-B", "-c", source, str(root / "url_router/install.py"), str(snapshot)]
    os.mkfifo(snapshot, 0o600)
    result = subprocess.run(command, capture_output=True, text=True, timeout=2)
    assert result.returncode != 0 and "regular" in result.stderr, result
    snapshot.unlink()
    snapshot.write_text(json.dumps({"version": 1, "generation": "72929621-22a6-48c9-97ea-df69e0c45918", "rules": []}))
    result = subprocess.run(command, capture_output=True, text=True, timeout=2)
    assert result.returncode == 0 and "72929621-22a6-48c9-97ea-df69e0c45918" in result.stdout, result
    snapshot.write_text(json.dumps({"version": 1, "generation": 7, "rules": []}))
    try:
        installer.selectors(snapshot)
    except ValueError as error:
        assert "generation" in str(error)
    else:
        raise AssertionError("non-string generation accepted")
    snapshot.unlink()
    print("PASS installer rejects a FIFO before reading, a non-string generation as invalid input, and accepts regular selectors")

    # Authentication can change the process that the protected helper must retire.
    servicepath = temporary / "service.json"
    launcher = temporary / "launchctl"
    launcher.write_text("#!" + sys.executable + "\n" + r"""
import json, os, signal, subprocess, sys
from pathlib import Path
path = Path(sys.argv[1])
state = json.loads(path.read_text())
operation, target = sys.argv[2], sys.argv[-1]
apple = target.endswith("/com.apple.swcd")
# Zombies have exited.
alive = bool(state["pid"]) and subprocess.run(["/bin/ps", "-o", "stat=", "-p", str(state["pid"])], capture_output=True, text=True).stdout.strip()[:1] not in ("", "Z")
if state["fail"] and (operation == "kickstart" or (operation == "bootout" and not apple)):
    sys.exit(operation + " failed")
if operation == "print":
    # A booted-out job stays listed while its process lives.
    if apple and (state["loaded"] or alive):
        print("pid = " + str(state["pid"]) if alive else "state = waiting")
    elif not apple and state["clone"]:
        print("state = running")
    else:
        sys.exit(113)
elif operation == "bootout" and apple:
    state["loaded"] = False
    if alive:
        os.kill(state["pid"], signal.SIGTERM)
elif operation == "bootstrap":
    state["loaded" if target == "/System/Library/LaunchAgents/com.apple.swcd.plist" else "clone"] = True
elif operation in ("enable", "disable") and apple:
    state["disabled"] = operation == "disable"
path.write_text(json.dumps(state))
""")
    launcher.chmod(0o700)
    wrapper = temporary / "launchctl-wrapper"
    wrapper.write_text('#!/bin/sh\nexec "' + str(launcher) + '" "' + str(servicepath) + '" "$@"\n')
    wrapper.chmod(0o700)
    actual_run = installer.run
    program = "import signal,time,sys; signal.signal(signal.SIGTERM, lambda *_: (time.sleep(0.3), sys.exit(0))); print('ready', flush=True); time.sleep(30)"
    def retirement(mode):
        children = []
        def spawn():
            # The timeout process exits only after the first deadline.
            source = {"retirement timeout": program.replace("time.sleep(0.3)", "time.sleep(12)"),
                      "restore timeout": program.replace("lambda *_: (time.sleep(0.3), sys.exit(0))", "signal.SIG_IGN")}.get(mode, program)
            child = subprocess.Popen([sys.executable, "-c", source], stdout=subprocess.PIPE, text=True)
            children.append(child)
            assert child.stdout and child.stdout.readline().strip() == "ready"
            return child
        first = None if mode.startswith("started") else spawn()
        live = [first]
        servicepath.write_text(json.dumps({"pid": first.pid if first else None, "loaded": True, "clone": False,
                                           "disabled": False, "fail": mode == "restore failure"}))
        def authenticate(commands):
            if "during authentication" in mode:
                if first:
                    first.kill()
                    first.wait()
                live[0] = spawn()
                servicepath.write_text(json.dumps(dict(json.loads(servicepath.read_text()), pid=live[0].pid)))
            for command in commands:
                command = list(map(str, command))
                source = command.index("-c") + 1
                # Root runs these programs, so nobody else may be able to replace them.
                for path in (Path(part).resolve() for part in command[:source] if part.startswith("/")):
                    for item in (path, *path.parents):
                        assert item.stat().st_uid == 0 and not item.stat().st_mode & 0o022, "replaceable privileged program: " + str(item)
                assert command[source].count('"/bin/launchctl"') == 1
                command[source] = command[source].replace('"/bin/launchctl"', '"' + str(wrapper) + '"')
                if mode == "restore timeout":
                    # Shorten both deadlines so a process that never exits fails quickly.
                    assert command[source].count("time.monotonic() + 10") == 2
                    command[source] = command[source].replace("time.monotonic() + 10", "time.monotonic() + 1")
                actual_run(command)
        try:
            start = time.monotonic()
            with patch.object(installer, "admin", side_effect=authenticate):
                if mode in ("retirement timeout", "restore timeout", "restore failure"):
                    try:
                        installer.service("activate", temporary / "clone.plist")
                    except RuntimeError as error:
                        message = str(error)
                    else:
                        raise AssertionError("failed service replacement accepted")
                    state = json.loads(servicepath.read_text())
                    if mode == "retirement timeout":
                        assert "com.apple.swcd process did not exit" in message, message
                        assert state["loaded"], "Apple's job was not bootstrapped again after its process exited"
                        assert 11.8 <= time.monotonic() - start < 15
                    elif mode == "restore timeout":
                        assert "restoring com.apple.swcd also failed: The retiring gui/" in message and message.endswith("/com.apple.swcd process did not exit within 10 seconds"), message
                        assert time.monotonic() - start < 5
                    else:
                        assert "kickstart failed; restoring com.apple.swcd also failed: bootout failed" in message, message
                        assert not state["disabled"], "Apple's job stayed disabled after retiring the clone failed"
                else:
                    installer.service("activate", temporary / "clone.plist")
                    child = live[0]
                    assert child and child.poll() == 0, "replacement returned before the actual retiring process finished cleanup: " + mode
        finally:
            for child in children:
                if child.poll() is None:
                    child.kill()
                child.wait()
                child.stdout.close()
        print("PASS retiring service exit boundary: " + {
            "retirement timeout": "a missed deadline bootstraps Apple's job again once its process exits",
            "restore timeout": "a process that never exits fails the restore too, reporting both errors",
            "restore failure": "a failed restore keeps Apple's job enabled and reports both errors"}.get(mode, mode))

    for mode in ("unchanged", "replaced during authentication", "started during authentication", "retirement timeout", "restore timeout", "restore failure"):
        retirement(mode)

    payload = temporary / "payload"
    payload.mkdir()
    subprocess.run(["zsh", str(root / "url_router/build.sh"), str(payload / "Hammerspoon URL Router.app")], check=True, capture_output=True)
    (payload / "Hammerspoon URL Router.app").rename(payload / "helper.bundle")
    library = temporary / "library.c"
    library.write_text("int fixture(void) { return 0; }\n")
    subprocess.run(["clang", "-dynamiclib", str(library), "-o", str(payload / "hook.dylib")], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", str(payload / "hook.dylib")], check=True, capture_output=True)
    shutil.copyfile("/usr/bin/true", payload / "hook.dylib.probe")
    (payload / "hook.dylib.probe").chmod(0o700)
    subprocess.run(["swiftc", "-swift-version", "6", "-warnings-as-errors", str(root / "url_router/set_default.swift"), "-o", str(payload / "set-default")], check=True)
    shutil.copy2(root / "url_router/install.py", payload / "install.py")
    app_hash = installer.signing(payload / "helper.bundle")
    manifest = {"version": 1, "codeHash": app_hash,
                "files": {name: hashlib.sha256((payload / name).read_bytes()).hexdigest()
                          for name in ("hook.dylib", "hook.dylib.probe", "set-default", "install.py")}}
    (payload / "manifest.json").write_text(json.dumps(manifest))
    installer.verified(payload)
    (payload / "hook.dylib").write_bytes((payload / "hook.dylib").read_bytes() + b"altered")
    try:
        installer.verified(payload)
    except RuntimeError as error:
        assert "changed" in str(error)
    else:
        raise AssertionError("modified prepared library accepted")
    subprocess.run(["clang", "-dynamiclib", str(library), "-o", str(payload / "hook.dylib")], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", str(payload / "hook.dylib")], check=True, capture_output=True)
    assert hashlib.sha256((payload / "hook.dylib").read_bytes()).hexdigest() == manifest["files"]["hook.dylib"]
    print("PASS prepared payload rejects changed hook bytes before installation")

    platform = (root / "url_router/interception/platform.m").read_text()
    start = platform.index("  char build[64]")
    end = platform.index("\n}", start)
    platform = platform[:start] + '  return @"25G84";' + platform[end:]
    changed = temporary / "platform-newbuild.m"
    changed.write_text(platform)
    newbuild = temporary / "probe-newbuild"
    subprocess.run(["clang", "-O2", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-I", str(root / "url_router/interception"),
        str(root / "url_router/interception/probe.m"), str(changed), str(root / "url_router/interception/status.m"),
        "-framework", "Foundation", "-framework", "Security", "-lbsm", "-o", str(newbuild)], check=True)
    result = subprocess.run([str(newbuild)], text=True, capture_output=True, check=False)
    assert result.returncode == 1 and "validated only" in result.stderr, result
    print("PASS probe rejects an untested macOS build before reading any arguments")

    # Skip the build check and the live swcd query to reach the acknowledgement wait on any Mac.
    waiting = (root / "url_router/interception/probe.m").read_text()
    for live, skipped in (("if (!URLRouterCheckABI(&error))", "if (NO)"), ("NSString *message = health(deadline);", "NSString *message = nil;")):
        assert waiting.count(live) == 1, live
        waiting = waiting.replace(live, skipped)
    (temporary / "probe-wait.m").write_text(waiting)
    probe = temporary / "probe-wait"
    subprocess.run(["clang", "-O2", "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-Wno-unused-function", "-I", str(root / "url_router/interception"),
        str(temporary / "probe-wait.m"), str(root / "url_router/interception/platform.m"), str(root / "url_router/interception/status.m"),
        "-framework", "Foundation", "-framework", "Security", "-lbsm", "-o", str(probe)], check=True)
    status = temporary / "probe-status"
    status.mkdir(mode=0o700)
    (status / "status.json").write_text(json.dumps({"version": 1, "kind": "error", "stage": "target", "error": "Router code identity validation failed",
                                                    "generation": "", "sha256": "", "count": 0, "pid": os.getpid()}))
    os.chmod(status / "status.json", 0o600)
    started = time.monotonic()
    result = subprocess.run([str(probe), str(status / "status.json"), str(uuid.uuid4()), "0" * 64], text=True, capture_output=True, timeout=15)
    assert result.returncode == 1 and "identity validation failed" in result.stderr and time.monotonic() - started < 5, result
    print("PASS probe reports a running hook's setup error instead of waiting for its timeout")

    actual_run = installer.run
    actual_subprocess = installer.subprocess.run
    rules = json.dumps({"version": 1, "generation": "d0819922-4a5f-479a-9007-b73f80e37a4d", "rules": []})
    acknowledged = ["d0819922-4a5f-479a-9007-b73f80e37a4d", hashlib.sha256(rules.encode()).hexdigest()]
    for mode in ("success", "preflight", "disabled-boolean", "disabled-word", "activation", "stale-ack", "default-failure", "retry-default-failure", "admin-failure", "login", "login-default-failure", "restore-failure", "cleanup-failure", "without-helper", "job-removal-failure", "restored-reboot", "unsupported-build"):
        failure = mode == "preflight"
        home = temporary / mode
        support = home / "Library/Application Support/HammerspoonURLRouter"
        app = home / "Applications/Hammerspoon URL Router.app"
        jobpath = home / "Library/LaunchAgents" / (installer.LABEL + ".plist")
        statusroot = home / "cache"
        statusroot.mkdir(parents=True)
        app.parent.mkdir(parents=True)
        if mode != "without-helper":
            shutil.copytree(payload / "helper.bundle", app)
            info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            info["CFBundleVersion"] = "0"
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
            subprocess.run(["codesign", "--force", "--sign", "-", "--entitlements", str(root / "url_router/entitlements.plist"), str(app)], check=True, capture_output=True)
            assert installer.signing(app, local=False) != app_hash
        before = {str(path.relative_to(app)): path.read_bytes() for path in app.rglob("*") if path.is_file()}
        defaults = {"http": "/original/http.app", "https": "/original/https.app"}
        live = dict(defaults)
        service = {"original": True, "replacement": False, "disabled": False, "clone_disabled": False}
        calls = []

        def system(arguments, **kwargs):
            arguments = [str(item) for item in arguments]
            if arguments[:2] == ["/bin/launchctl", "print"]:
                name = "replacement" if arguments[2].endswith(installer.LABEL) else "original"
                return subprocess.CompletedProcess(arguments, 0 if service[name] else 113, "pid = 2147483647", "")
            if arguments[0] == "/bin/launchctl":
                admin([arguments])
                return subprocess.CompletedProcess(arguments, 0, "", "")
            return actual_subprocess(arguments, **kwargs)

        def admin(commands):
            for command in commands:
                calls.append(["ADMIN", *map(str, command)])
                if "-c" in command:
                    source = command.index("-c") + 1
                    with patch.object(sys, "argv", ["-c", *map(str, command[source + 1:])]):
                        try:
                            exec(command[source], {})  # noqa: S102 - Run the trusted installer helper with isolated launchctl.
                        except SystemExit as error:
                            raise RuntimeError("administrator operation failed") from error
                    continue
                operation = command[1]
                if operation == "disable":
                    service["clone_disabled" if str(command[-1]).endswith(installer.LABEL) else "disabled"] = True
                elif operation == "enable":
                    service["clone_disabled" if str(command[-1]).endswith(installer.LABEL) else "disabled"] = False
                elif operation in ("bootout", "bootstrap"):
                    name = "replacement" if str(command[-1]).endswith(installer.LABEL) or str(command[-1]) == str(jobpath) else "original"
                    if operation == "bootstrap" and service["clone_disabled" if name == "replacement" else "disabled"]:
                        raise RuntimeError("Bootstrap failed: 5: Input/output error")
                    service[name] = operation == "bootstrap"
                elif operation == "kickstart" and mode == "admin-failure" and not service.get("failed"):
                    service["failed"] = True
                    raise RuntimeError("administrator operation failed")

        def transport(arguments, mode=mode, **kwargs):
            arguments = [str(item) for item in arguments]
            calls.append(arguments)
            if arguments[0] == "/usr/bin/getconf":
                # dirhelper deletes idle files under the temporary directory after 3 days.
                assert arguments[1:] == ["DARWIN_USER_CACHE_DIR"], arguments
                return str(statusroot)
            if arguments[:2] == ["/bin/launchctl", "print-disabled"]:
                if mode == "disabled-boolean":
                    return '{ "com.apple.swcd" => true }'
                if mode == "disabled-word":
                    return '{ "com.apple.swcd" => disabled }'
                return '{ "com.apple.swcd" => ' + ("disabled" if service["disabled"] else "enabled") + ' }'
            if arguments[:2] == ["/bin/launchctl", "print"]:
                name = "replacement" if arguments[2].endswith(installer.LABEL) else "original"
                if not service[name]:
                    raise RuntimeError(name + " job not loaded")
                return "pid = 2147483647"
            if arguments[0].endswith("set-default"):
                if arguments[1] == "--snapshot":
                    Path(arguments[2]).write_text(json.dumps(defaults))
                elif arguments[1] == "--restore":
                    assert json.loads(Path(arguments[2]).read_text()) == defaults
                    if (mode in ("restore-failure", "admin-failure") and not service.get("refused")) or service.get("refusing"):
                        service["refused"] = True
                        raise RuntimeError("The saved http handler is unavailable")
                    live.update(defaults)
                elif arguments[1] == "--terminate":
                    assert arguments[2] == str(app)
                elif arguments[1] == "--launch":
                    assert arguments[2] == str(app) and service["replacement"]
                else:
                    assert service["replacement"], "defaults changed before the replacement service was running"
                    live.update(http=str(app), https=str(app))
                    if mode.endswith("default-failure"):
                        raise RuntimeError("default handler request failed after changing HTTP")
                return ""
            if arguments[0].endswith("/Contents/MacOS/HammerspoonURLRouter"):
                assert arguments[1] == "--warm-links" and kwargs.get("timeout") == 15
                assert service["replacement"] or service["original"]
                return ""
            if arguments[0] == installer.REGISTER:
                return ""
            if arguments[0].endswith("hook.dylib.probe"):
                if arguments[1] == "--preflight":
                    if failure:
                        raise RuntimeError("private ABI check rejected")
                    return "{}"
                assert service["replacement"], "the replacement swcd is not running"
                # Like the real probe, acknowledge only the snapshot this test wrote.
                if arguments[1:] != [str(statusroot / "HammerspoonURLRouter/status.json"), *acknowledged]:
                    raise RuntimeError("Router did not acknowledge the current selector generation within 10 seconds")
                return json.dumps({"version": 1, "kind": "ready", "pid": 777 if mode == "stale-ack" else 2147483647,
                                   "generation": acknowledged[0], "sha256": acknowledged[1]})
            return actual_run(arguments, **kwargs)

        with patch.multiple(installer, SUPPORT=support, APP=app, JOB=jobpath), patch.object(installer, "environment", return_value={}), patch.object(installer, "run", side_effect=transport), patch.object(installer, "admin", side_effect=admin), patch.object(installer.subprocess, "run", side_effect=system):
            if mode.startswith("disabled-"):
                try:
                    installer.stage(payload)
                except RuntimeError as error:
                    assert "already disabled" in str(error)
                else:
                    raise AssertionError("disabled original job accepted")
                assert not any(call[0].endswith("set-default") for call in calls)
            elif failure:
                try:
                    installer.stage(payload)
                except RuntimeError as error:
                    assert "ABI" in str(error)
                else:
                    raise AssertionError("failed preflight accepted")
            else:
                installer.stage(payload)
                assert installer.saved()["phase"] == "staged"
                assert json.loads((statusroot / "HammerspoonURLRouter/status.json").read_text()) == {"version": 1, "kind": "pending"}
                stagedjob = plistlib.loads(jobpath.read_bytes())
                assert stagedjob["EnvironmentVariables"]["URL_ROUTER_APP_PATH"] == str(app)
                assert live == defaults
                if mode != "success":
                    snapshot = support / "selectors/rules.json"
                    snapshot.parent.mkdir()
                    snapshot.write_text(rules)
                    if mode in ("stale-ack", "default-failure", "retry-default-failure", "admin-failure"):
                        service["refusing"] = mode == "retry-default-failure"
                        try:
                            installer.activate(True)
                        except RuntimeError as error:
                            expected = {"stale-ack": "acknowledgement", "default-failure": "default handler", "retry-default-failure": "default handler", "admin-failure": "administrator"}[mode]
                            assert expected in str(error)
                        else:
                            raise AssertionError("failed activation accepted")
                        if mode == "retry-default-failure":
                            # The rollback stopped at the defaults, so the helper is default and its hook is loaded.
                            assert installer.saved()["phase"] == "activation-failed" and service["replacement"] and live != defaults
                            try:
                                installer.activate(True)
                            except RuntimeError as error:
                                assert service["replacement"], "a retried activation removed the hook while the helper stayed default"
                                assert "still loaded" in str(error), error
                            else:
                                raise AssertionError("activation retried over a loaded clone")
                            service["refusing"] = False
                            installer.uninstall()
                        if mode == "admin-failure":
                            assert service["original"] and not service["disabled"] and not service["replacement"], "failed activation left Apple's swcd retired"
                            # The rollback stopped at the defaults, leaving the clone disabled; a retry must still load it.
                            assert installer.saved()["phase"] == "activation-failed" and service["clone_disabled"]
                            installer.activate(True)
                            assert installer.saved()["phase"] == "ready" and service["replacement"]
                            installer.uninstall()
                    else:
                        if mode == "login":
                            service["clone_disabled"] = True  # Left by an interrupted rollback.
                        installer.activate(not mode.startswith("login"))
                        if mode.startswith("login"):
                            assert installer.saved()["phase"] == "awaiting-login" and live == defaults
                            # A clean login loads only enabled jobs.
                            service.update(original=not service["disabled"], replacement=not service["clone_disabled"])
                            with patch.object(installer.sys, "argv", ["install.py", "finish"]):
                                if mode == "login-default-failure":
                                    try:
                                        installer.main()
                                    except RuntimeError as error:
                                        assert "default handler" in str(error)
                                    else:
                                        raise AssertionError("failed login completion accepted")
                                else:
                                    installer.main()
                        if mode != "login-default-failure":
                            assert installer.saved()["phase"] == "ready"
                            assert live == {"http": str(app), "https": str(app)}
                            barrier = next(index for index, call in enumerate(calls) if call[0].endswith("hook.dylib.probe") and call[1] != "--preflight")
                            changed = next(index for index, call in enumerate(calls) if call[0].endswith("set-default") and call[1] == str(app))
                            assert barrier < changed
                            warmed = next(index for index, call in enumerate(calls) if call[0].endswith("/Contents/MacOS/HammerspoonURLRouter") and call[1] == "--warm-links")
                            assert barrier < warmed < changed
                            if mode == "restore-failure":
                                try:
                                    installer.uninstall()
                                except RuntimeError as error:
                                    assert "unavailable" in str(error)
                                    assert service["replacement"], "helper left as the default after its hook was removed"
                                    assert installer.saved()["phase"] == "ready", "a failed default restore marked the install as uninstalling"
                                else:
                                    raise AssertionError("failed default restoration ignored")
                            if mode == "cleanup-failure":
                                remove = installer.shutil.rmtree
                                def cleanup(path, *arguments, **keywords):
                                    remove(path, *arguments, **keywords)
                                    if Path(path) == support / "original-helper.bundle":
                                        raise PermissionError("cleanup interrupted after removing the backup")
                                with patch.object(installer.shutil, "rmtree", side_effect=cleanup):
                                    try:
                                        installer.uninstall()
                                    except PermissionError:
                                        assert installer.saved()["phase"] == "restored" and live == defaults
                                    else:
                                        raise AssertionError("cleanup interruption ignored")
                            if mode in ("job-removal-failure", "restored-reboot"):
                                jobpath.parent.chmod(0o500)
                                try:
                                    try:
                                        installer.uninstall()
                                    except PermissionError:
                                        assert jobpath.exists() and live == defaults
                                        assert (support / "state.json").exists() and (support / "runtime").exists()
                                    else:
                                        raise AssertionError("real job-removal permission failure missed")
                                finally:
                                    jobpath.parent.chmod(0o700)
                                if mode == "restored-reboot":
                                    # Resume a legacy restored journal after some cleanup already completed.
                                    state = installer.saved()
                                    state["phase"] = "restored"
                                    installer.write(support / "state.json", state)
                                    shutil.rmtree(support / "runtime")
                                    shutil.rmtree(support / "original-helper.bundle")
                                    service.update(original=False, replacement=True, clone_disabled=False)
                                else:
                                    assert service["clone_disabled"], "remaining clone can reload after interrupted cleanup"
                            if mode == "unsupported-build":
                                # After the update, every probe mode fails the build check.
                                def updated(arguments, **keywords):
                                    if str(arguments[0]).endswith("hook.dylib.probe"):
                                        return actual_run([newbuild, *arguments[1:]], **keywords)
                                    return transport(arguments, **keywords)
                                with patch.object(installer, "environment", side_effect=RuntimeError("Unsupported macOS after update")), patch.object(installer, "run", side_effect=updated):
                                    try:
                                        installer.validate(installer.saved())
                                    except RuntimeError as error:
                                        assert "Unsupported macOS" in str(error)
                                    else:
                                        raise AssertionError("updated environment accepted for activation")
                                    installer.uninstall()
                            else:
                                installer.uninstall()
                else:
                    installer.uninstall()
            after = {str(path.relative_to(app)): path.read_bytes() for path in app.rglob("*") if path.is_file()}
            assert after == before
            if mode == "without-helper":
                assert not app.exists()
            assert not jobpath.exists() and not (support / "state.json").exists() and not (support / "runtime").exists()
            assert live == defaults and service["original"] and not service["replacement"] and not service["disabled"] and not service["clone_disabled"]
            if mode in ("success", "preflight", "disabled-boolean", "disabled-word"):
                assert not any(call[0] == "ADMIN" for call in calls)
        checks = {"stale-ack": "rejects an acknowledgement from another swcd process",
                  "default-failure": "rejects a partial HTTP(S) default change",
                  "retry-default-failure": "refuses to retry over a loaded clone after the rollback's default restore fails",
                  "admin-failure": "keeps Apple's swcd running when a protected step fails and the rollback stops early, then a retry loads the disabled clone,",
                  "login": "loads a clone left disabled by an interrupted rollback, preserves readiness ordering,",
                  "login-default-failure": "rejects a partial HTTP(S) default change at login completion",
                  "restore-failure": "preserves readiness ordering, keeps the hook and phase while a failed default restore leaves the helper default,"}
        print("PASS lifecycle " + ("rejects " + mode if mode.startswith("disabled-") else
              "failed preflight rolls back all staged filesystem writes" if failure else
              "stage leaves live defaults/service intact and uninstall restores the original helper" if mode == "success" else
              mode + " " + checks.get(mode, "preserves readiness ordering") + " and restores defaults/helper/service"))
