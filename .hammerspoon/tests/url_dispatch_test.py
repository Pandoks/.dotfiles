"""Exercise native URL dispatch and the real Swift process bridge without opening apps."""

import os
import ctypes
import signal
import time
import hashlib
import json
import re
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parent.parent
main = (root / "url_router/main.swift").read_text()
native = (root / "url_router/native.swift").read_text()
compiler = ["swiftc", "-swift-version", "6", "-warnings-as-errors", str(root / "url_router/universal.swift")]
subprocess.run(compiler + ["-typecheck", str(root / "url_router/main.swift"), str(root / "url_router/native.swift")], check=True)

mock = r'''
struct MockBundle {
    var bundleIdentifier: String?
    static let main = MockBundle(bundleIdentifier: "test.router")
    init(bundleIdentifier: String?) { self.bundleIdentifier = bundleIdentifier }
    init?(url: URL) {
        let name = url.deletingPathExtension().lastPathComponent
        guard name != "invalid" else { return nil }
        bundleIdentifier = name
    }
}
@MainActor
struct MockWorkspace {
    static let shared = MockWorkspace()
    func urlForApplication(withBundleIdentifier identifier: String) -> URL? {
        print("BROWSER")
        guard ProcessInfo.processInfo.environment["URL_TEST_HANDLERS", default: ""]
            .split(separator: ",").contains(Substring(identifier)) else { return nil }
        return URL(fileURLWithPath: "/mock/\(identifier).app")
    }
    func urlsForApplications(toOpen url: URL) -> [URL] {
        print("RESOLVE")
        return ProcessInfo.processInfo.environment["URL_TEST_HANDLERS", default: ""]
            .split(separator: ",").map { URL(fileURLWithPath: "/mock/\($0).app") }
    }
    func open(_ url: URL, configuration: NSWorkspace.OpenConfiguration) async throws {
        precondition(configuration.requiresUniversalLinks && !configuration.promptsUserIfNeeded)
        if ProcessInfo.processInfo.environment["URL_TEST_WARM"] == "1" {
            precondition(url.absoluteString == "https://127.0.0.1/" && !configuration.activates)
        }
        print("UNIVERSAL")
        let mode = ProcessInfo.processInfo.environment["URL_TEST_NATIVE", default: "missing"]
        if mode == "success" { return }
        if mode == "denied" { throw NSError(domain: NSOSStatusErrorDomain, code: -1743) }
        let absent = NSError(domain: NSOSStatusErrorDomain, code: Int(kLSApplicationNotFoundErr))
        if mode == "direct" { throw absent }
        throw NSError(domain: NSCocoaErrorDomain, code: 256, userInfo: [NSUnderlyingErrorKey: absent])
    }
    func open(_ urls: [URL], withApplicationAt app: URL, configuration: NSWorkspace.OpenConfiguration) async throws {
        precondition(!configuration.requiresUniversalLinks && urls.count == 1)
        precondition(!configuration.promptsUserIfNeeded)
        print("OPEN " + app.deletingPathExtension().lastPathComponent)
        print("URL " + urls[0].absoluteString)
        if ProcessInfo.processInfo.environment["URL_TEST_OPEN_FAIL"] == "1" {
            throw NSError(domain: NSOSStatusErrorDomain, code: -600)
        }
    }
}
'''

with tempfile.TemporaryDirectory(prefix="url-dispatch-test.", dir="/var/tmp") as directory:
    directory = Path(directory)
    home = directory / "home"
    snapshot = home / "Library/Application Support/HammerspoonURLRouter/selectors/rules.json"
    snapshot.parent.mkdir(parents=True)
    snapshot.write_text(json.dumps({"version": 1, "generation": "72929621-22a6-48c9-97ea-df69e0c45918", "rules": []}))
    acknowledgement = home / "HammerspoonURLRouter/status.json"
    acknowledgement.parent.mkdir()
    ready = {"version": 1, "kind": "ready", "generation": "72929621-22a6-48c9-97ea-df69e0c45918", "sha256": hashlib.sha256(snapshot.read_bytes()).hexdigest()}
    acknowledgement.write_text(json.dumps(ready))
    path = directory / "main.swift"
    binary = directory / "native"
    path.write_text(native.replace("NSWorkspace.shared", "MockWorkspace.shared").replace("Bundle.", "MockBundle.").replace("Bundle(url:", "MockBundle(url:") + mock + r'''
do {
    if ProcessInfo.processInfo.environment["URL_TEST_WARM"] == "1" {
        try await warmNativeLinks()
    } else {
        try await openNative(URL(string: ProcessInfo.processInfo.environment["URL_TEST_URL"]!)!)
    }
    print("SUCCESS")
} catch {
    print("FAILURE " + error.localizedDescription)
}
''')
    subprocess.run(compiler + [str(path), "-o", str(binary)], check=True)
    routers = "local.pandoks.HammerspoonURLRouter,org.hammerspoon.Hammerspoon,test.router"
    for mode in ("missing", "direct", "success", "denied"):
        result = subprocess.run([str(binary)], env=dict(os.environ, URL_TEST_WARM="1", URL_TEST_NATIVE=mode),
            capture_output=True, text=True, check=True)
        lines = result.stdout.splitlines()
        assert lines.count("UNIVERSAL") == 1 and lines[-1].startswith("SUCCESS" if mode in ("missing", "direct") else "FAILURE")
        assert not any(line.startswith(("OPEN ", "BROWSER", "RESOLVE")) for line in lines)
    print("PASS native client warm-up never opens a browser and accepts only the expected absent loopback handler")
    for name, url, mode, handlers, fail, universal, resolve, browser, opened, success in [
        ("native app takes precedence without Helium installed", "https://example.com/", "success", routers + ",com.apple.Safari", False, 1, 0, 0, None, True),
        ("wrapped absence opens Helium despite Safari ranking first", "https://example.com/", "missing", routers + ",com.apple.Safari,net.imput.helium", False, 1, 0, 1, "net.imput.helium", True),
        ("HTTP direct absence opens Helium", "http://localhost:3000/", "direct", routers + ",net.imput.helium,com.apple.Safari", False, 1, 0, 1, "net.imput.helium", True),
        ("uppercase HTTPS opens Helium", "HTTPS://example.com/", "missing", "net.imput.helium", False, 1, 0, 1, "net.imput.helium", True),
        ("custom schemes use their registered app", "slack://example", "missing", "org.hammerspoon.Hammerspoon,com.tinyspeck.slackmacgap", False, 0, 1, 0, "com.tinyspeck.slackmacgap", True),
        ("file URLs use their registered app", "file:///var/tmp/example.html", "missing", routers + ",com.apple.Safari", False, 0, 1, 0, "com.apple.Safari", True),
        ("actual native launch errors do not fall back", "https://example.com/", "denied", "com.apple.Safari,net.imput.helium", False, 1, 0, 0, None, False),
        ("Helium launch errors never try another app", "https://example.com/", "missing", "com.apple.Safari,net.imput.helium", True, 1, 0, 1, "net.imput.helium", False),
        ("missing Helium does not select Safari", "https://example.com/", "missing", routers + ",com.apple.Safari", False, 1, 0, 1, None, False),
        ("no web handlers fails explicitly", "https://example.com/", "missing", "", False, 1, 0, 1, None, False),
        ("no custom scheme handlers fails explicitly", "slack://example", "missing", "", False, 0, 1, 0, None, False),
        ("only routers cannot recurse", "slack://example", "missing", routers, False, 0, 1, 0, None, False),
        ("invalid bundles are skipped", "slack://example", "missing", "invalid,com.tinyspeck.slackmacgap", False, 0, 1, 0, "com.tinyspeck.slackmacgap", True),
        ("URL query and fragment survive handoff", "https://example.com/path?quote=%22&value=%5C#test", "missing", "net.imput.helium", False, 1, 0, 1, "net.imput.helium", True),
    ]:
        environment = dict(os.environ, URL_TEST_URL=url, URL_TEST_NATIVE=mode, URL_TEST_HANDLERS=handlers, URL_TEST_OPEN_FAIL=str(int(fail)))
        result = subprocess.run([str(binary)], env=environment, capture_output=True, text=True, check=True, timeout=10)
        lines = result.stdout.splitlines()
        assert lines.count("UNIVERSAL") == universal, (name, lines)
        assert lines.count("RESOLVE") == resolve, (name, lines)
        assert lines.count("BROWSER") == browser, (name, lines)
        assert [line for line in lines if line.startswith("OPEN ")] == (["OPEN " + opened] if opened else []), (name, lines)
        assert ("SUCCESS" in lines) == success, (name, lines)
        if opened:
            assert "URL " + url in lines, (name, lines)
        print("PASS native " + name)

    bridge = re.sub(r"guard let hsPath = \[.*?\]\.first", "guard let hsPath = [CommandLine.arguments[1]].first", main, count=1, flags=re.DOTALL)
    bridge = bridge.replace("FileManager.default.homeDirectoryForCurrentUser", 'URL(fileURLWithPath: ProcessInfo.processInfo.environment["URL_TEST_HOME"]!)')
    bridge = bridge.replace("FileManager.default.temporaryDirectory", 'URL(fileURLWithPath: ProcessInfo.processInfo.environment["URL_TEST_HOME"]!)')
    bridge = bridge.replace('NSRunningApplication.runningApplications(withBundleIdentifier: "org.hammerspoon.Hammerspoon")', "mockRunningApplications()")
    bridge = bridge.replace("private func route", "func route").replace("private var activeTasks", "var activeTasks").replace("private final class RouteTask", "final class RouteTask")
    bridge = bridge[:bridge.index("let application = NSApplication.shared")]
    bridge = bridge.replace("let alert = NSAlert()", "let alert = MockAlert()")
    bridge = bridge.replace("NSApplication.shared.setActivationPolicy(.accessory)", "")
    bridge = bridge.replace("NSApplication.shared.setActivationPolicy(.prohibited)", "")
    bridge = bridge.replace("NSApplication.shared.activate(ignoringOtherApps: true)", "")
    bridge = bridge.replace('NSLog("%@", message)', 'print("LOG " + message)')
    bridge = re.sub(r'(if (?:finished\.terminationStatus|status) == 0 && response == "true" \{)',
        r'\1 print("ACCEPTED"); if ProcessInfo.processInfo.environment["URL_TEST_KEEP_ALIVE"] != "1" { exit(0) };', bridge)
    bridge = bridge.replace('NSLog("URL routing failed for %@", url.host ?? "unknown host")',
        'print("REJECTED"); if ProcessInfo.processInfo.environment["URL_TEST_KEEP_ALIVE"] != "1" { exit(0) }')
    bridge += r'''
@MainActor final class MockAlert {
    static var blocked = false
    var messageText = ""
    var informativeText = ""
    var alertStyle = NSAlert.Style.warning
    func runModal() {
        print("POPUP " + informativeText)
        if ProcessInfo.processInfo.environment["URL_TEST_MODAL"] == "1" && !Self.blocked {
            Self.blocked = true
            print("MODAL_BEGIN"); fflush(nil)
            Thread.sleep(forTimeInterval: 18)
            print("MODAL_END")
        }
        if ProcessInfo.processInfo.environment["URL_TEST_KEEP_ALIVE"] != "1" { exit(0) }
    }
}
func mockRunningApplications() -> [Int] {
    ProcessInfo.processInfo.environment["URL_TEST_RUNNING"] == "0" ? [] : [1]
}
@MainActor func openNative(_ url: URL) async throws {
    print("NATIVE")
    if ProcessInfo.processInfo.environment["URL_TEST_NATIVE_FAIL"] == "1" {
        throw NSError(domain: "native-test", code: 1)
    }
    if ProcessInfo.processInfo.environment["URL_TEST_KEEP_ALIVE"] != "1" { exit(0) }
}
func descriptors() -> Int { (0..<1024).filter { fcntl(Int32($0), F_GETFD) >= 0 }.count }
let before = descriptors()
let delegate = AppDelegate()
if let type = ProcessInfo.processInfo.environment["URL_TEST_ACTIVITY"] {
    let activity = NSUserActivity(activityType: type)
    let url = ProcessInfo.processInfo.environment["URL_TEST_ACTIVITY_URL", default: "https://app.ramp.com/"]
    if url != "none" { activity.webpageURL = URL(string: url) }
    let accepted = delegate.application(NSApplication.shared, continue: activity, restorationHandler: { _ in })
    print("ACTIVITY " + String(accepted))
} else {
    delegate.route(URL(string: "https://app.ramp.com/")!)
}
if ProcessInfo.processInfo.environment["URL_TEST_KEEP_ALIVE"] == "1" {
    if ProcessInfo.processInfo.environment["URL_TEST_MODAL"] == "1" {
        delegate.application(NSApplication.shared, open: [URL(string: "fixture://another-link")!])
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        print("EARLY " + String(delegate.activeTasks.count))
    }
    let seconds: Double = ProcessInfo.processInfo.environment["URL_TEST_MODAL"] == "1" ? 19 : 16.3
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        print("FINAL tasks=\(delegate.activeTasks.count) descriptors=\(descriptors()) before=\(before)")
        exit(0)
    }
} else if delegate.activeTasks.isEmpty { exit(0) }
dispatchMain()
'''
    path.write_text(bridge)
    binary = directory / "bridge"
    subprocess.run(compiler + [str(path), "-o", str(binary)], check=True)
    cli = directory / "hs"
    cli.write_text('#!/bin/sh\nprintf "call\\n" >> "$URL_TEST_CALLS"\nprintf "%s\\n" "$URL_TEST_REPLY"\nexit "$URL_TEST_STATUS"\n')
    cli.chmod(0o700)
    invalid = directory / "invalid"
    invalid.write_text("not an executable")
    invalid.chmod(0o700)
    stalled = directory / "stalled"
    stalled.write_text("#!/bin/sh\nexec /bin/sleep 60\n")
    stalled.chmod(0o700)
    calls = directory / "calls"
    for name, target in [("selector FIFO", snapshot), ("status FIFO", acknowledgement)]:
        contents = target.read_bytes()
        target.unlink()
        os.mkfifo(target, 0o600)
        calls.write_text("")
        result = subprocess.run([str(binary), str(cli)], env=dict(os.environ, URL_TEST_HOME=str(home), URL_TEST_CALLS=str(calls)),
            capture_output=True, text=True, check=True, timeout=2)
        assert result.stdout.count("POPUP ") == 1 and "regular" in result.stdout and calls.read_text() == "", (name, result.stdout)
        target.unlink()
        target.write_bytes(contents)
        print("PASS URL bridge " + name + " fails promptly before action")
    for name, executable, reply, status, native_fail, popups, accepted, rejected, native_count in [
        ("matched success", cli, "true", 0, False, 0, 1, 0, 0),
        ("matched failure does not fall back", cli, "false", 0, False, 0, 0, 1, 0),
        ("unmatched dispatches natively", cli, "native", 0, False, 0, 0, 0, 1),
        ("native failure reports once", cli, "native", 0, True, 1, 0, 0, 1),
        ("nonzero native response is rejected", cli, "native", 69, False, 1, 0, 0, 0),
        ("process failure", cli, "", 69, False, 1, 0, 0, 0),
        ("unexpected response", cli, "error", 0, False, 1, 0, 0, 0),
        ("missing CLI", directory / "missing", "", 0, False, 1, 0, 0, 0),
        ("CLI cannot start", invalid, "", 0, False, 1, 0, 0, 0),
        ("stalled CLI is terminated before fallback", stalled, "", 0, False, 1, 0, 0, 0),
    ]:
        calls = directory / "calls"
        calls.write_text("")
        environment = dict(os.environ, URL_TEST_REPLY=reply, URL_TEST_STATUS=str(status), URL_TEST_CALLS=str(calls), URL_TEST_NATIVE_FAIL=str(int(native_fail)), URL_TEST_HOME=str(home))
        result = subprocess.run([str(binary), str(executable)], env=environment, capture_output=True, text=True, check=True, timeout=20 if executable == stalled else 10)
        assert result.stdout.count("POPUP ") == popups, (name, result.stdout)
        assert result.stdout.count("ACCEPTED") == accepted, (name, result.stdout)
        assert result.stdout.count("REJECTED") == rejected, (name, result.stdout)
        assert result.stdout.splitlines().count("NATIVE") == native_count, (name, result.stdout)
        assert calls.read_text().count("call") == int(executable == cli), name
        print("PASS URL bridge " + name)

    fixture = directory / "lifecycle.c"
    fixture.write_text(r'''
#include <stdio.h>
#include <unistd.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
int main(void) {
 const char *mode=getenv("TEST_MODE");
 FILE *pid=fopen(getenv("TEST_PID"),"w");fprintf(pid,"%d",getpid());fclose(pid);
 if(!strcmp(mode,"ignore")){signal(SIGTERM,SIG_IGN);while(1)pause();}
 if(!strcmp(mode,"closed")){close(1);close(2);signal(SIGTERM,SIG_IGN);while(1)pause();}
 if(!strcmp(mode,"inherited")){if(fork()==0){sleep(60);_exit(0);}puts("true");return 0;}
 if(!strcmp(mode,"large")){char data[8192];memset(data,'X',sizeof(data));for(int i=0;i<128;i++)if(write(2,data,sizeof(data))<0)return 1;}
 puts(!strcmp(mode,"false")?"false":!strcmp(mode,"native")?"native":"true");return 0;
}
''')
    lifecycle = directory / "lifecycle"
    subprocess.run(["clang", "-O2", str(fixture), "-o", str(lifecycle)], check=True)
    processes = []
    library = ctypes.CDLL("/usr/lib/libproc.dylib")
    try:
        for mode in ("normal", "false", "native", "ignore", "closed", "inherited", "large", "modal"):
            log = directory / (mode + ".log")
            output = log.open("w")
            pidpath = directory / (mode + ".pid")
            environment = dict(os.environ, URL_TEST_HOME=str(home), URL_TEST_KEEP_ALIVE="1",
                TEST_MODE="ignore" if mode == "modal" else mode, TEST_PID=str(pidpath),
                URL_TEST_MODAL=str(int(mode == "modal")), URL_TEST_NATIVE_FAIL=str(int(mode == "modal")))
            process = subprocess.Popen([str(binary), str(lifecycle)], env=environment, stdout=output, stderr=output, start_new_session=True)
            processes.append((mode, process, output, log, pidpath, time.monotonic()))
        modal = processes[-1]
        time.sleep(max(0, 16.3 - (time.monotonic() - modal[-1])))
        mode, process, output, log, pidpath, _ = modal
        child = int(pidpath.read_text())
        try:
            os.kill(child, 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError("CLI deadline waited for a blocked modal")
        output.flush()
        assert "MODAL_BEGIN" in log.read_text() and "MODAL_END" not in log.read_text()
        descriptors = ctypes.create_string_buffer(8192)
        assert library.proc_pidinfo(process.pid, 1, 0, descriptors, len(descriptors)) // 8 == 3, "pipe retained while modal blocked the main actor"
        for mode, process, output, log, pidpath, _ in processes:
            process.wait(timeout=5)
            output.flush()
            lines = log.read_text().splitlines()
            assert "FINAL tasks=0 descriptors=3 before=3" in lines, (mode, lines)
            try:
                os.kill(int(pidpath.read_text()), 0)
            except ProcessLookupError:
                pass
            else:
                raise AssertionError("CLI survived the deadline: " + mode)
            popups = [line for line in lines if line.startswith("POPUP ")]
            if mode in ("ignore", "closed", "inherited", "modal"):
                assert sum("timed out after 15 seconds" in line for line in popups) == 1, (mode, lines)
            if mode in ("normal", "false", "native", "large"):
                assert "EARLY 0" in lines, (mode, lines)
            if mode == "large":
                assert len(popups) == 1 and "output truncated" in popups[0] and len(popups[0]) < 4300, lines
            elif mode in ("normal", "false", "native"):
                assert not popups, (mode, lines)
                expected = {"normal": "ACCEPTED", "false": "REJECTED", "native": "NATIVE"}[mode]
                assert lines.count(expected) == 1, (mode, lines)
            print("PASS URL bridge complete process/pipe lifecycle: " + mode)
    finally:
        for _, process, output, _, pidpath, _ in processes:
            for pid in (int(pidpath.read_text()) if pidpath.exists() else None, process.pid):
                if pid is not None:
                    try:
                        os.killpg(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
            process.wait()
            output.close()

    calls.write_text("")
    result = subprocess.run([str(binary), str(cli)], env=dict(os.environ, URL_TEST_HOME=str(home), URL_TEST_CALLS=str(calls), URL_TEST_RUNNING="0"),
        capture_output=True, text=True, check=True, timeout=10)
    assert result.stdout.count("POPUP ") == 1 and "Hammerspoon is not running" in result.stdout and calls.read_text() == "", result.stdout
    print("PASS URL bridge missing Hammerspoon fails before launching its CLI")

    for name, status_value in [
        ("unacknowledged selectors", dict(ready, kind="error")),
        ("stale selector generation", dict(ready, generation="0bb7b5f5-413a-4bc4-96b5-f6d1a0dddb6d")),
        ("same generation edited bytes", dict(ready, sha256="0" * 64)),
    ]:
        acknowledgement.write_text(json.dumps(status_value))
        calls.write_text("")
        result = subprocess.run([str(binary), str(cli)], env=dict(os.environ, URL_TEST_HOME=str(home), URL_TEST_CALLS=str(calls)),
            capture_output=True, text=True, check=True, timeout=10)
        assert result.stdout.count("POPUP ") == 1 and calls.read_text() == "", (name, result.stdout)
        print("PASS URL bridge " + name + " fails before action")
    acknowledgement.write_text(json.dumps(ready))

    for name, activity_type, activity_url, accepted in [
        ("browsing-web activity", "NSUserActivityTypeBrowsingWeb", "https://app.ramp.com/", True),
        ("unrelated activity", "fixture.activity", "https://app.ramp.com/", False),
        ("browsing activity without URL", "NSUserActivityTypeBrowsingWeb", "none", False),
    ]:
        calls.write_text("")
        result = subprocess.run([str(binary), str(cli)], env=dict(os.environ, URL_TEST_HOME=str(home), URL_TEST_CALLS=str(calls),
            URL_TEST_ACTIVITY=activity_type, URL_TEST_ACTIVITY_URL=activity_url, URL_TEST_REPLY="true", URL_TEST_STATUS="0"),
            capture_output=True, text=True, check=True, timeout=10)
        assert "ACTIVITY " + str(accepted).lower() in result.stdout, (name, result.stdout)
        assert calls.read_text().count("call") == int(accepted), (name, result.stdout)
        print("PASS URL delivery " + name)

    path.write_text(main + r'''
@MainActor func openNative(_ url: URL) async throws {
    print("NATIVE " + url.absoluteString)
    if ProcessInfo.processInfo.environment["URL_TEST_NATIVE_FAIL"] == "1" {
        throw NSError(domain: "native-test", code: 1)
    }
}
@MainActor func warmNativeLinks() async throws {
    print("WARM")
    if ProcessInfo.processInfo.environment["URL_TEST_NATIVE_FAIL"] == "1" {
        throw NSError(domain: "native-test", code: 1)
    }
}
''')
    binary = directory / "command"
    subprocess.run(compiler + [str(path), "-o", str(binary)], check=True)
    for name, arguments, failed, status in [
        ("native command", ["--native", "http://localhost:3000/"], False, 0),
        ("native command failure", ["--native", "http://localhost:3000/"], True, 1),
        ("warm command", ["--warm-links"], False, 0),
        ("warm command failure", ["--warm-links"], True, 1),
        ("warm command rejects a URL argument", ["--warm-links", "https://example.com/"], False, 1),
        ("missing URL", ["--native"], False, 1),
        ("URL without scheme", ["--native", "plain-text"], False, 1),
        ("unknown command", ["--unknown", "https://example.com/"], False, 1),
    ]:
        environment = dict(os.environ, URL_TEST_NATIVE_FAIL=str(int(failed)))
        result = subprocess.run([str(binary), *arguments], env=environment, capture_output=True, text=True, timeout=10)
        assert result.returncode == status, (name, result.stdout, result.stderr)
        assert result.stdout.count("NATIVE ") == int(name.startswith("native command")), (name, result.stdout)
        assert result.stdout.count("WARM") == int(name in ("warm command", "warm command failure")), (name, result.stdout)
        print("PASS URL " + name)
