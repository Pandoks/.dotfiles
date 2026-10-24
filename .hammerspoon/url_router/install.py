#!/usr/bin/env python3
"""Build, stage, activate, inspect, and reverse the per-user swcd installation."""

import argparse
import ctypes
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import stat
import subprocess
import sys
import uuid

SOURCE = Path(__file__).resolve().parent
SUPPORT = Path.home() / "Library/Application Support/HammerspoonURLRouter"
APP = Path.home() / "Applications/Hammerspoon URL Router.app"
LABEL = "local.pandoks.HammerspoonURLRouter.swcd"
JOB = Path.home() / "Library/LaunchAgents" / (LABEL + ".plist")
ORIGINAL = Path("/System/Library/LaunchAgents/com.apple.swcd.plist")
REGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
IDENTIFIER = "LOCALPROBE.local.pandoks.HammerspoonURLRouter"
BUNDLE = "local.pandoks.HammerspoonURLRouter"
DISABLED = r'"com\.apple\.swcd"\s*=>\s*(?:true|disabled)\b'
# Root-owned; /usr/bin/python3 can resolve into admin-writable /Applications.
PYTHON = "/Library/Developer/CommandLineTools/usr/bin/python3"


def run(arguments, **kwargs):
    result = subprocess.run([str(item) for item in arguments], text=True, capture_output=True, **kwargs)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or f"Command failed: {arguments[0]}")
    return result.stdout.strip()


def write(path, value):
    path = Path(path)
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex)
    try:
        with temporary.open("x") as file:
            os.chmod(temporary, 0o600)
            json.dump(value, file, sort_keys=True)
            file.write("\n")
            file.flush()
            os.fsync(file.fileno())
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def environment():
    mask = ctypes.c_uint32()
    if ctypes.CDLL(None).csr_get_active_config(ctypes.byref(mask)) or mask.value != 0x46:
        raise RuntimeError(f"Tested SIP configuration 0x46 is required (current: {mask.value:#x})")
    version = run(["/usr/bin/sw_vers", "-productVersion"])
    build = run(["/usr/bin/sw_vers", "-buildVersion"])
    if (version, build) not in (("26.6.2", "25G83"), ("27.0.1", "26A434")):
        raise RuntimeError(f"Unsupported macOS {version} ({build}); the private ABI must be verified before installation")
    if "-arm64e_preview_abi" not in run(["/usr/sbin/nvram", "boot-args"]).split():
        raise RuntimeError("The tested -arm64e_preview_abi boot argument is required")
    if not os.access(PYTHON, os.X_OK):
        raise RuntimeError("The command-line tools' Python is required at " + PYTHON)
    return {"version": version, "build": build, "csr": mask.value}


def signing(app, local=True):
    run(["/usr/bin/codesign", "--verify", "--strict", app])
    details = subprocess.run(["/usr/bin/codesign", "-dv", "--verbose=4", str(app)], capture_output=True, text=True, check=True)
    match = re.search(r"^CDHash=([0-9a-f]{40})$", details.stderr, re.MULTILINE)
    if not match:
        raise RuntimeError("Could not read the helper's code hash")
    if local:
        entitlement = run(["/usr/bin/codesign", "-d", "--entitlements", ":-", app])
        if plistlib.loads(entitlement.encode()).get("com.apple.application-identifier") != IDENTIFIER:
            raise RuntimeError("The helper has the wrong application identifier")
    return match.group(1)


def read(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as file:
        before = os.fstat(file.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or before.st_mode & 0o022 or not 0 < before.st_size <= 1024 * 1024:
            raise RuntimeError("Expected a user-owned regular router file of at most 1 MiB, not writable by others")
        data = file.read(before.st_size + 1)
        after = os.fstat(file.fileno())
        if len(data) != before.st_size or before.st_size != after.st_size or before.st_mtime_ns != after.st_mtime_ns:
            raise RuntimeError("The router file changed while reading; publish replacements atomically")
        return data


def selectors(path):
    data = read(path)
    snapshot = json.loads(data)
    if not isinstance(snapshot, dict) or type(snapshot.get("version")) is not int or snapshot["version"] != 1:
        raise RuntimeError("The selector snapshot version is invalid")
    if not isinstance(snapshot.get("rules"), list):
        raise RuntimeError("The selector snapshot rules are invalid")
    if not isinstance(snapshot.get("generation"), str):
        raise ValueError("The selector snapshot generation is invalid")
    uuid.UUID(snapshot["generation"])
    for rule in snapshot["rules"]:
        if not isinstance(rule, dict) or set(rule) not in ({"host"}, {"pattern"}):
            raise RuntimeError("The selector snapshot has an invalid rule")
        if not isinstance(next(iter(rule.values())), str):
            raise RuntimeError("The selector snapshot has an invalid selector")
    return snapshot["generation"], hashlib.sha256(data).hexdigest()


def launchjob(original, paths, code):
    if original.get("Label") != "com.apple.swcd" or original.get("ProgramArguments") != ["/usr/libexec/swcd"]:
        raise RuntimeError("The system swcd launch job is incompatible")
    result = dict(original)
    result["Label"] = LABEL
    result["EnvironmentVariables"] = dict(original.get("EnvironmentVariables", {}), **{
        "DYLD_INSERT_LIBRARIES": paths["hookPath"],
        "URL_ROUTER_SELECTORS_PATH": paths["selectorsPath"],
        "URL_ROUTER_STATUS_PATH": paths["statusPath"],
        "URL_ROUTER_APP_PATH": paths["appPath"],
        "URL_ROUTER_APPLICATION_IDENTIFIER": IDENTIFIER,
        "URL_ROUTER_CODE_HASH": code,
    })
    return result


def prepare(directory):
    environment()
    if directory.exists() or directory.is_symlink():
        raise RuntimeError("The prepare output must be a new directory")
    directory.mkdir(parents=True, mode=0o700)
    try:
        app = directory / "Hammerspoon URL Router.app"
        run(["/bin/zsh", SOURCE / "build.sh", app])
        app.rename(directory / "helper.bundle")
        app = directory / "helper.bundle"
        run(["/bin/zsh", SOURCE / "interception/build.sh", directory / "hook.dylib"])
        run(["/usr/bin/swiftc", "-swift-version", "6", "-warnings-as-errors", SOURCE / "set_default.swift", "-o", directory / "set-default"])
        shutil.copy2(SOURCE / "install.py", directory / "install.py")
        paths = ["hook.dylib", "hook.dylib.probe", "set-default", "install.py"]
        write(directory / "manifest.json", {"version": 1, "codeHash": signing(app),
            "files": {name: digest(directory / name) for name in paths}})
    except BaseException:
        shutil.rmtree(directory)
        raise
    print(directory)


def verified(directory):
    manifest = json.loads(read(directory / "manifest.json"))
    expected = {"hook.dylib", "hook.dylib.probe", "set-default", "install.py"}
    if not isinstance(manifest, dict) or manifest.get("version") != 1 or not isinstance(manifest.get("files"), dict) or set(manifest["files"]) != expected:
        raise RuntimeError("The prepared payload manifest is invalid")
    for name in expected:
        if digest(directory / name) != manifest["files"][name]:
            raise RuntimeError("The prepared payload changed: " + name)
    if signing(directory / "helper.bundle") != manifest.get("codeHash"):
        raise RuntimeError("The prepared helper changed")
    run(["/usr/bin/codesign", "--verify", "--strict", directory / "hook.dylib"])
    run(["/usr/bin/codesign", "--verify", "--strict", directory / "hook.dylib.probe"])
    return manifest


def saved():
    state = json.loads(read(SUPPORT / "state.json"))
    if not isinstance(state, dict) or state.get("version") != 1 or state.get("appPath") != str(APP) or state.get("jobPath") != str(JOB) or state.get("hookPath") != str(SUPPORT / "runtime/hook.dylib"):
        raise RuntimeError("The installed router state is invalid")
    cache = Path(run(["/usr/bin/getconf", "DARWIN_USER_CACHE_DIR"])) / "HammerspoonURLRouter/status.json"
    if state.get("statusPath") != str(cache) or state.get("selectorsPath") != str(SUPPORT / "selectors/rules.json") or state.get("probePath") != str(SUPPORT / "runtime/hook.dylib.probe"):
        raise RuntimeError("The installed router paths are invalid. Uninstall an installation staged before the status file moved with its own copy: "
                           + shlex.join([PYTHON, "-I", str(SUPPORT / "runtime/install.py"), "uninstall"]))
    return state


def stage(directory):
    environment()
    manifest = verified(directory)
    if (SUPPORT / "state.json").exists() or JOB.exists() or JOB.is_symlink():
        raise RuntimeError("A router installation already exists; inspect or uninstall it before staging")
    if APP.is_symlink() or (APP.exists() and plistlib.loads((APP / "Contents/Info.plist").read_bytes()).get("CFBundleIdentifier") != BUNDLE):
        raise RuntimeError("The helper destination belongs to a different application")
    if SUPPORT.is_symlink():
        raise RuntimeError("The router support directory must not be a symlink")
    SUPPORT.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(SUPPORT, 0o700)
    cache = Path(run(["/usr/bin/getconf", "DARWIN_USER_CACHE_DIR"])) / "HammerspoonURLRouter"
    if cache.is_symlink():
        raise RuntimeError("The router status directory must not be a symlink")
    cache.mkdir(mode=0o700, exist_ok=True)
    os.chmod(cache, 0o700)
    paths = {"appPath": str(APP), "jobPath": str(JOB), "selectorsPath": str(SUPPORT / "selectors/rules.json"),
             "statusPath": str(cache / "status.json"), "hookPath": str(SUPPORT / "runtime/hook.dylib"),
             "probePath": str(SUPPORT / "runtime/hook.dylib.probe")}
    original = plistlib.loads(ORIGINAL.read_bytes())
    clone = launchjob(original, paths, manifest["codeHash"])
    state = dict(paths, version=1, phase="staging", originalJobSHA256=digest(ORIGINAL),
                 codeHash=manifest["codeHash"], hadHelper=APP.exists(), helperReplaced=False,
                 previousCodeHash=signing(APP, local=False) if APP.exists() else None)
    disabled = run(["/bin/launchctl", "print-disabled", f"gui/{os.getuid()}"])
    if re.search(DISABLED, disabled):
        raise RuntimeError("The original swcd job is already disabled; restore its configuration before installing")
    if (SUPPORT / "runtime").exists() or (SUPPORT / "original-helper.bundle").exists():
        raise RuntimeError("Existing runtime or backup artifacts must be reviewed before staging")
    try:
        run([directory / "set-default", "--snapshot", SUPPORT / "original-defaults.json"])
        if APP.exists():
            shutil.copytree(APP, SUPPORT / "original-helper.bundle", symlinks=True)
        shutil.copytree(directory, SUPPORT / "runtime", symlinks=True)
        write(SUPPORT / "state.json", state)
        write(cache / "status.json", {"version": 1, "kind": "pending"})
    except BaseException:
        if (SUPPORT / "runtime").exists():
            shutil.rmtree(SUPPORT / "runtime")
        if (SUPPORT / "original-helper.bundle").exists():
            shutil.rmtree(SUPPORT / "original-helper.bundle")
        (SUPPORT / "original-defaults.json").unlink(missing_ok=True)
        (SUPPORT / "state.json").unlink(missing_ok=True)
        raise
    try:
        APP.parent.mkdir(parents=True, exist_ok=True)
        replacement = SUPPORT / "replacement-helper.bundle"
        displaced = SUPPORT / "displaced-helper.bundle"
        if replacement.exists() or displaced.exists():
            raise RuntimeError("Existing helper replacement artifacts must be reviewed")
        shutil.copytree(directory / "helper.bundle", replacement, symlinks=True)
        run([SUPPORT / "runtime/set-default", "--terminate", APP])
        state["helperReplaced"] = True
        write(SUPPORT / "state.json", state)
        if APP.exists():
            run([REGISTER, "-u", APP])
            APP.rename(displaced)
        replacement.rename(APP)
        if displaced.exists():
            shutil.rmtree(displaced)
        run([REGISTER, "-f", APP])
        run([Path(paths["probePath"]), "--preflight", APP, IDENTIFIER, state["codeHash"]])
        # A login before activation must not load the clone.
        run(["/bin/launchctl", "disable", f"gui/{os.getuid()}/" + LABEL])
        JOB.parent.mkdir(parents=True, exist_ok=True)
        with JOB.open("xb") as file:
            plistlib.dump(clone, file)
        os.chmod(JOB, 0o644)
        state["phase"] = "staged"
        write(SUPPORT / "state.json", state)
    except BaseException:
        state["phase"] = "stage-failed"
        write(SUPPORT / "state.json", state)
        try:
            uninstall()
        except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError) as rollback:
            print("Staging rollback failed: " + str(rollback) + "; run install.sh uninstall after resolving it", file=sys.stderr)
        raise
    print("Staged. Reload Hammerspoon, then run install.sh activate --warm or activate --login.")


def admin(commands):
    command = "\n".join(" ".join(shlex.quote(str(part)) for part in parts) for parts in commands)
    command = "set -e\n" + command
    authentication = subprocess.run(["/usr/bin/sudo", "-n", "true"], capture_output=True)
    if authentication.returncode == 0:
        run(["/usr/bin/sudo", "-n", "/bin/sh", "-c", command])
    else:
        script = "do shell script " + json.dumps(command) + " with administrator privileges"
        run(["/usr/bin/osascript", "-e", script])


# The process snapshot and exit barrier must run after administrator authentication.
SERVICE = r"""import errno
import re
import select
import subprocess
import sys
import time

deadline = time.monotonic() + 10
exiting = None

def remaining(message):
    seconds = deadline - time.monotonic()
    if seconds <= 0:
        raise RuntimeError(message)
    return seconds

def launch(*arguments, absent=False):
    late = "launchctl " + " ".join(arguments) + " missed its 10-second deadline"
    result = subprocess.run(["/bin/launchctl", *arguments], text=True, capture_output=True, timeout=remaining(late))
    if absent and result.returncode == 113:
        return None
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "Protected launchctl operation failed")
    return result.stdout

def wait():
    global exiting
    if exiting:
        service, queue = exiting
        late = "The retiring " + service + " process did not exit within 10 seconds"
        if not queue.control(None, 1, remaining(late)):
            raise RuntimeError(late)
    exiting = None

def retire(service, absent=False):
    global exiting
    launch("disable", service)
    details = launch("print", service, absent=absent)
    if details is None:
        return
    pid = re.search(r"^\s*pid = (\d+)\s*$", details, re.MULTILINE)
    if pid:
        queue = select.kqueue()
        event = select.kevent(int(pid.group(1)), filter=select.KQ_FILTER_PROC,
                             flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE | select.KQ_EV_ONESHOT,
                             fflags=select.KQ_NOTE_EXIT)
        try:
            queue.control([event], 0, 0)
            exiting = (service, queue)
        except OSError as error:
            if error.errno != errno.ESRCH:
                raise
    launch("bootout", service)
    wait()

def restore():
    global deadline
    deadline = time.monotonic() + 10
    launch("disable", domain + "/" + label)
    launch("enable", domain + "/com.apple.swcd")
    # A booted-out job stays listed until its process exits.
    wait()
    retire(domain + "/" + label, absent=True)
    if launch("print", domain + "/com.apple.swcd", absent=True) is None:
        launch("bootstrap", domain, original)

try:
    mode, domain, original, label = sys.argv[1:5]
    if mode == "activate":
        try:
            retire(domain + "/com.apple.swcd")
            launch("enable", domain + "/" + label)
            launch("bootstrap", domain, sys.argv[5])
            launch("kickstart", domain + "/" + label)
        except BaseException as error:
            # Never leave Apple's job retired without a running replacement.
            try:
                restore()
            except BaseException as failure:
                raise RuntimeError(f"{error}; restoring com.apple.swcd also failed: {failure}") from error
            raise
    else:
        restore()
except (OSError, RuntimeError, subprocess.SubprocessError) as error:
    print(str(error), file=sys.stderr)
    sys.exit(1)
"""


def service(mode, *extra):
    admin([["/usr/bin/env", "-i", PYTHON, "-I", "-S", "-c", SERVICE, mode, f"gui/{os.getuid()}", ORIGINAL, LABEL, *extra]])


def complete(state):
    validate(state)
    generation, sha = selectors(Path(state["selectorsPath"]))
    acknowledgement = json.loads(run([state["probePath"], state["statusPath"], generation, sha]))
    service = run(["/bin/launchctl", "print", f"gui/{os.getuid()}/" + LABEL])
    pid = re.search(r"^\s*pid = (\d+)\s*$", service, re.MULTILINE)
    if not pid or int(pid.group(1)) != acknowledgement.get("pid"):
        raise RuntimeError("The ready acknowledgement does not belong to the replacement swcd process")
    run([SUPPORT / "runtime/set-default", "--launch", APP])
    run([APP / "Contents/MacOS/HammerspoonURLRouter", "--warm-links"], timeout=15)
    run([SUPPORT / "runtime/set-default", APP])
    state["phase"] = "ready"
    write(SUPPORT / "state.json", state)


def validate(state):
    environment()
    if digest(ORIGINAL) != state["originalJobSHA256"]:
        raise RuntimeError("The system swcd job changed after staging")
    if signing(APP) != state["codeHash"]:
        raise RuntimeError("The installed helper changed after staging")
    verified(SUPPORT / "runtime")
    selectors(Path(state["selectorsPath"]))
    expected = launchjob(plistlib.loads(ORIGINAL.read_bytes()), state, state["codeHash"])
    if plistlib.loads(JOB.read_bytes()) != expected:
        raise RuntimeError("The staged launch job changed")
    run([state["probePath"], "--preflight", APP, IDENTIFIER, state["codeHash"]])


def activate(warm):
    state = saved()
    if state["phase"] not in ("staged", "activation-failed"):
        raise RuntimeError("Only a staged installation can be activated")
    if subprocess.run(["/bin/launchctl", "print", f"gui/{os.getuid()}/" + LABEL], capture_output=True).returncode == 0:
        raise RuntimeError("A previous activation is still loaded; run install.sh uninstall")
    validate(state)
    state["phase"] = "activating"
    state["activationMode"] = "warm" if warm else "login"
    write(SUPPORT / "state.json", state)
    try:
        if warm:
            service("activate", JOB)
        else:
            # Staging disabled the clone.
            admin([["/bin/launchctl", "enable", f"gui/{os.getuid()}/" + LABEL],
                   ["/bin/launchctl", "disable", f"gui/{os.getuid()}/com.apple.swcd"]])
        state["phase"] = "activated" if warm else "awaiting-login"
        write(SUPPORT / "state.json", state)
        if warm:
            complete(state)
    except BaseException:
        state["phase"] = "activation-failed"
        write(SUPPORT / "state.json", state)
        try:
            uninstall()
        except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError) as rollback:
            print("Activation rollback failed: " + str(rollback) + "; run install.sh uninstall after resolving it", file=sys.stderr)
        raise
    print("Ready. Verify a configured link and an unmatched native link." if warm else
          "Activation is staged for a clean login/reboot. After logging in, run install.sh finish. This script does not log out or restart the Mac.")


def status():
    if not (SUPPORT / "state.json").exists():
        print(json.dumps({"installed": False}))
        return
    state = saved()
    result = {"installed": True, "phase": state["phase"], "statusPath": state["statusPath"]}
    path = Path(state["statusPath"])
    if path.exists():
        result["hook"] = json.loads(read(path))
        if not isinstance(result["hook"], dict):
            raise RuntimeError("The hook status is invalid")
    service = subprocess.run(["/bin/launchctl", "print", f"gui/{os.getuid()}/{LABEL}"], capture_output=True, text=True)
    result["jobLoaded"] = service.returncode == 0
    pid = re.search(r"^\s*pid = (\d+)\s*$", service.stdout, re.MULTILINE)
    try:
        generation, sha = selectors(Path(state["selectorsPath"]))
        hook = result.get("hook", {})
        result["acknowledged"] = bool(pid) and hook.get("pid") == int(pid.group(1)) and hook.get("kind") == "ready" and hook.get("generation") == generation and hook.get("sha256") == sha
    except (OSError, ValueError, KeyError, TypeError):
        result["acknowledged"] = False
    print(json.dumps(result, sort_keys=True))


def uninstall():
    state = saved()
    if APP.is_symlink() or (APP.exists() and signing(APP, local=False) not in (state["codeHash"], state.get("previousCodeHash"))):
        raise RuntimeError("The installed helper changed; preserve it before uninstalling")
    if state["phase"] == "restored":
        if state["hadHelper"]:
            if not APP.exists() or signing(APP, local=False) != state.get("previousCodeHash"):
                raise RuntimeError("The restored helper changed; preserve it before cleanup")
        elif APP.exists():
            raise RuntimeError("A new helper appeared after restoration; preserve it before cleanup")
        if state.get("activationMode"):
            service("restore")
    else:
        if state["hadHelper"] and signing(SUPPORT / "original-helper.bundle", local=False) != state.get("previousCodeHash"):
            raise RuntimeError("The original helper backup changed")
        # Restore defaults first so a refused prompt leaves the helper's hook running.
        run([SUPPORT / "runtime/set-default", "--restore", SUPPORT / "original-defaults.json"])
        state["phase"] = "uninstalling"
        write(SUPPORT / "state.json", state)
        if state.get("activationMode"):
            service("restore")
        restored = SUPPORT / "restored-helper.bundle"
        displaced = SUPPORT / "displaced-helper.bundle"
        if restored.exists():
            shutil.rmtree(restored)
        if state["hadHelper"]:
            shutil.copytree(SUPPORT / "original-helper.bundle", restored, symlinks=True)
            if signing(restored, local=False) != state.get("previousCodeHash"):
                raise RuntimeError("The helper restoration copy changed")
        if displaced.exists():
            if signing(displaced, local=False) not in (state["codeHash"], state.get("previousCodeHash")):
                raise RuntimeError("The displaced helper changed; preserve it before uninstalling")
            shutil.rmtree(displaced)
        run([SUPPORT / "runtime/set-default", "--terminate", APP])
        if APP.exists():
            run([REGISTER, "-u", APP])
            APP.rename(displaced)
        if state["hadHelper"]:
            restored.rename(APP)
            run([REGISTER, "-f", APP])
        if state.get("activationMode"):
            run([SUPPORT / "runtime/helper.bundle/Contents/MacOS/HammerspoonURLRouter", "--warm-links"], timeout=15)
        JOB.unlink(missing_ok=True)
        state["phase"] = "restored"
        write(SUPPORT / "state.json", state)
    JOB.unlink(missing_ok=True)
    run(["/bin/launchctl", "enable", f"gui/{os.getuid()}/" + LABEL])
    Path(state["statusPath"]).unlink(missing_ok=True)
    for path in (SUPPORT / "runtime", SUPPORT / "original-helper.bundle", SUPPORT / "replacement-helper.bundle", SUPPORT / "displaced-helper.bundle", SUPPORT / "restored-helper.bundle"):
        if path.exists():
            shutil.rmtree(path)
    (SUPPORT / "original-defaults.json").unlink(missing_ok=True)
    (SUPPORT / "state.json").unlink()
    print("Restored the original swcd job, helper, and HTTP(S) defaults. Reload Hammerspoon.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("prepare", "stage"):
        commands.add_parser(name).add_argument("directory", type=Path)
    activation = commands.add_parser("activate")
    modes = activation.add_mutually_exclusive_group(required=True)
    modes.add_argument("--warm", action="store_true")
    modes.add_argument("--login", action="store_true")
    for name in ("status", "uninstall", "check", "finish"):
        commands.add_parser(name)
    arguments = parser.parse_args()
    if arguments.command == "check":
        print(json.dumps(environment(), sort_keys=True))
        return
    if arguments.command == "status":
        status()
        return
    if arguments.command == "prepare":
        prepare(arguments.directory.resolve())
        return
    if os.geteuid() == 0:
        raise RuntimeError("Run the installer as the logged-in user; administrator authentication is requested only for protected launchctl operations")
    SUPPORT.parent.mkdir(parents=True, exist_ok=True)
    with (SUPPORT.parent / ".HammerspoonURLRouter.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if arguments.command == "stage":
            stage(arguments.directory.resolve())
        elif arguments.command == "activate":
            activate(arguments.warm)
        elif arguments.command == "finish":
            state = saved()
            if state["phase"] != "awaiting-login":
                raise RuntimeError("Only an installation awaiting a clean login can be completed")
            try:
                complete(state)
            except BaseException:
                try:
                    uninstall()
                except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError) as rollback:
                    print("Completion rollback failed: " + str(rollback) + "; run install.sh uninstall after resolving it", file=sys.stderr)
                raise
        else:
            uninstall()


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError) as error:
        message = str(error)
        print("URL router: " + message, file=sys.stderr)
        subprocess.run(["/usr/bin/logger", "-t", "HammerspoonURLRouter", message], check=False)
        if len(sys.argv) > 1 and sys.argv[1] not in ("status", "check", "prepare"):
            script = 'display alert "Hammerspoon URL Router" message ' + json.dumps(message) + " as warning"
            subprocess.run(["/usr/bin/osascript", "-e", script], capture_output=True, check=False)
        sys.exit(1)
