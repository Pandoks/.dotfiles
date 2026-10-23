"""Exercise native URL dispatch and the real Swift Mach port bridge without opening apps."""

import hashlib
import json
import os
import subprocess
import tempfile
import time
from pathlib import Path

root = Path(__file__).resolve().parent.parent
main = (root / "url_router/main.swift").read_text()
native = (root / "url_router/native.swift").read_text()
compiler = ["swiftc", "-swift-version", "6", "-warnings-as-errors"]
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

    bridge = main.replace('"local.pandoks.HammerspoonURLRouter.route" as CFString', 'ProcessInfo.processInfo.environment["URL_TEST_PORT"]! as CFString')
    bridge = bridge.replace("FileManager.default.homeDirectoryForCurrentUser", 'URL(fileURLWithPath: ProcessInfo.processInfo.environment["URL_TEST_HOME"]!)')
    bridge = bridge.replace("FileManager.default.temporaryDirectory", 'URL(fileURLWithPath: ProcessInfo.processInfo.environment["URL_TEST_HOME"]!)')
    bridge = bridge.replace('NSRunningApplication.runningApplications(withBundleIdentifier: "org.hammerspoon.Hammerspoon")', "mockRunningApplications()")
    bridge = bridge.replace("private func route", "func route")
    bridge = bridge[:bridge.index("let application = NSApplication.shared")]
    bridge = bridge.replace("let alert = NSAlert()", "let alert = MockAlert()")
    bridge = bridge.replace("NSApplication.shared.setActivationPolicy(.accessory)", "")
    bridge = bridge.replace("NSApplication.shared.setActivationPolicy(.prohibited)", "")
    bridge = bridge.replace("NSApplication.shared.activate(ignoringOtherApps: true)", "")
    bridge = bridge.replace('NSLog("%@", message)', 'print("LOG " + message)')
    bridge = bridge.replace('case .success("true"):\n                    return',
        'case .success("true"):\n                    print("ACCEPTED"); if ProcessInfo.processInfo.environment["URL_TEST_KEEP_ALIVE"] != "1" { exit(0) }')
    bridge = bridge.replace('NSLog("URL routing failed for %@", url.host ?? "unknown host")',
        'print("REJECTED"); if ProcessInfo.processInfo.environment["URL_TEST_KEEP_ALIVE"] != "1" { exit(0) }')
    assert bridge.count("URL_TEST_PORT") == 1 and bridge.count("ACCEPTED") == 1 and bridge.count("REJECTED") == 1
    bridge += r"""
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
setvbuf(stdout, nil, _IOLBF, 0)
let delegate = AppDelegate()
if let type = ProcessInfo.processInfo.environment["URL_TEST_ACTIVITY"] {
    let activity = NSUserActivity(activityType: type)
    let url = ProcessInfo.processInfo.environment["URL_TEST_ACTIVITY_URL", default: "https://app.ramp.com/"]
    if url != "none" { activity.webpageURL = URL(string: url) }
    let accepted = delegate.application(NSApplication.shared, continue: activity, restorationHandler: { _ in })
    print("ACTIVITY " + String(accepted))
    if !accepted { exit(0) }
} else {
    if ProcessInfo.processInfo.environment["URL_TEST_MODAL"] == "1" {
        delegate.application(NSApplication.shared, open: [URL(string: "fixture://another-link")!])
    }
    delegate.route(URL(string: "https://app.ramp.com/")!)
}
if let seconds = Double(ProcessInfo.processInfo.environment["URL_TEST_FINAL", default: ""]) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { print("FINAL"); exit(0) }
}
dispatchMain()
"""
    path.write_text(bridge)
    binary = directory / "bridge"
    subprocess.run(compiler + [str(path), "-o", str(binary)], check=True)

    # A real CFMessagePort server standing in for Hammerspoon's router port.
    (directory / "server.c").write_text(r"""
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static const char *logPath, *reply;
static unsigned delay;
static CFDataRef respond(CFMessagePortRef port, SInt32 id, CFDataRef data, void *info) {
  (void)port; (void)info;
  FILE *log = fopen(logPath, "a");
  fprintf(log, "%d:", (int)id);
  fwrite(CFDataGetBytePtr(data), 1, (size_t)CFDataGetLength(data), log);
  fputc(0, log); fclose(log);
  sleep(delay);
  return strcmp(reply, "none") ? CFDataCreate(NULL, (const UInt8 *)reply, (CFIndex)strlen(reply)) : NULL;
}
int main(int argc, char **argv) {
  if (argc != 5) return 2;
  logPath = argv[2]; reply = argv[3]; delay = (unsigned)atoi(argv[4]);
  CFStringRef name = CFStringCreateWithCString(NULL, argv[1], kCFStringEncodingUTF8);
  CFMessagePortRef port = CFMessagePortCreateLocal(NULL, name, respond, NULL, NULL);
  if (!port) return 1;
  CFRunLoopAddSource(CFRunLoopGetMain(), CFMessagePortCreateRunLoopSource(NULL, port, 0), kCFRunLoopCommonModes);
  puts("READY"); fflush(stdout);
  CFRunLoopRun();
}
""")
    server = directory / "server"
    subprocess.run(["clang", "-Wall", "-Wextra", "-Werror", "-framework", "CoreFoundation", str(server) + ".c", "-o", str(server)], check=True)
    servers = []

    def serve(label, reply="true", delay=0):
        name = f"local.pandoks.HammerspoonURLRouter.test.{os.getpid()}.{label}"
        log = directory / (label + ".requests")
        log.write_bytes(b"")
        process = subprocess.Popen([str(server), name, str(log), reply, str(delay)], stdout=subprocess.PIPE, text=True)
        servers.append(process)
        assert process.stdout and process.stdout.readline() == "READY\n", label
        return name, log

    def requests(log):
        return [entry for entry in log.read_bytes().split(b"\0") if entry]

    expected = b"1:72929621-22a6-48c9-97ea-df69e0c45918\nhttps://app.ramp.com/"
    base = dict(os.environ, URL_TEST_HOME=str(home))
    try:
        # Deadline checks run alongside the other cases; each takes about ten seconds.
        name, slow = serve("timeout", delay=60)
        started = time.monotonic()
        timeout = subprocess.Popen([str(binary)], env=dict(base, URL_TEST_PORT=name), stdout=subprocess.PIPE, text=True)
        servers.append(timeout)
        name, blocked = serve("modal", delay=60)
        modal = subprocess.Popen([str(binary)], env=dict(base, URL_TEST_PORT=name, URL_TEST_KEEP_ALIVE="1", URL_TEST_MODAL="1",
            URL_TEST_NATIVE_FAIL="1", URL_TEST_FINAL="19.5"), stdout=subprocess.PIPE, text=True)
        servers.append(modal)

        for label, target in [("selector FIFO", snapshot), ("status FIFO", acknowledgement)]:
            contents = target.read_bytes()
            target.unlink()
            os.mkfifo(target, 0o600)
            name, log = serve(label.replace(" ", "-"))
            result = subprocess.run([str(binary)], env=dict(base, URL_TEST_PORT=name), capture_output=True, text=True, check=True, timeout=2)
            assert result.stdout.count("POPUP ") == 1 and "regular" in result.stdout and not requests(log), (label, result.stdout)
            target.unlink()
            target.write_bytes(contents)
            print("PASS URL bridge " + label + " fails promptly before sending")

        for name, reply, native_fail, popups, accepted, rejected, native_count, message in [
            ("matched success", "true", False, 0, 1, 0, 0, None),
            ("matched failure does not fall back", "false", False, 0, 0, 1, 0, None),
            ("unmatched dispatches natively", "native", False, 0, 0, 0, 1, None),
            ("native failure reports once", "native", True, 1, 0, 0, 1, None),
            ("unexpected reply", "error", False, 1, 0, 0, 0, "Hammerspoon routing failed: error"),
            ("empty reply", "none", False, 1, 0, 0, 0, "Hammerspoon routing failed: "),
            ("missing port", None, False, 1, 0, 0, 0, "Hammerspoon URL router is not listening"),
        ]:
            if reply:
                port, log = serve(name.replace(" ", "-"), reply)
            else:
                port, log = f"local.pandoks.HammerspoonURLRouter.test.{os.getpid()}.absent", None
            environment = dict(base, URL_TEST_PORT=port, URL_TEST_NATIVE_FAIL=str(int(native_fail)))
            result = subprocess.run([str(binary)], env=environment, capture_output=True, text=True, check=True, timeout=10)
            assert result.stdout.count("POPUP ") == popups, (name, result.stdout)
            assert result.stdout.count("ACCEPTED") == accepted, (name, result.stdout)
            assert result.stdout.count("REJECTED") == rejected, (name, result.stdout)
            assert result.stdout.splitlines().count("NATIVE") == native_count, (name, result.stdout)
            assert not message or message in result.stdout, (name, result.stdout)
            assert not log or requests(log) == [expected], (name, requests(log))
            print("PASS URL bridge " + name)

        name, log = serve("stopped")
        result = subprocess.run([str(binary)], env=dict(base, URL_TEST_PORT=name, URL_TEST_RUNNING="0"),
            capture_output=True, text=True, check=True, timeout=10)
        assert result.stdout.count("POPUP ") == 1 and "Hammerspoon is not running" in result.stdout and not requests(log), result.stdout
        print("PASS URL bridge missing Hammerspoon fails before sending")

        for label, status_value in [
            ("unacknowledged selectors", dict(ready, kind="error")),
            ("stale selector generation", dict(ready, generation="0bb7b5f5-413a-4bc4-96b5-f6d1a0dddb6d")),
            ("same generation edited bytes", dict(ready, sha256="0" * 64)),
        ]:
            acknowledgement.write_text(json.dumps(status_value))
            result = subprocess.run([str(binary)], env=dict(base, URL_TEST_PORT=name), capture_output=True, text=True, check=True, timeout=10)
            assert result.stdout.count("POPUP ") == 1 and not requests(log), (label, result.stdout)
            print("PASS URL bridge " + label + " fails before sending")
        acknowledgement.write_text(json.dumps(ready))

        for label, activity_type, activity_url, accepted in [
            ("browsing-web activity", "NSUserActivityTypeBrowsingWeb", "https://app.ramp.com/", True),
            ("unrelated activity", "fixture.activity", "https://app.ramp.com/", False),
            ("browsing activity without URL", "NSUserActivityTypeBrowsingWeb", "none", False),
        ]:
            name, log = serve(label.replace(" ", "-"))
            result = subprocess.run([str(binary)], env=dict(base, URL_TEST_PORT=name, URL_TEST_ACTIVITY=activity_type,
                URL_TEST_ACTIVITY_URL=activity_url), capture_output=True, text=True, check=True, timeout=10)
            assert "ACTIVITY " + str(accepted).lower() in result.stdout, (label, result.stdout)
            assert requests(log) == ([expected] if accepted else []), (label, requests(log))
            assert result.stdout.count("ACCEPTED") == int(accepted), (label, result.stdout)
            print("PASS URL delivery " + label)

        output, _ = timeout.communicate(timeout=20)
        elapsed = time.monotonic() - started
        assert 9.5 < elapsed < 12 and output.count("POPUP ") == 1, (elapsed, output)
        assert "did not reply within 10 seconds" in output and requests(slow) == [expected], output
        print("PASS URL bridge unanswered request reports once at the 10-second reply deadline")
        output, _ = modal.communicate(timeout=25)
        lines = output.splitlines()
        popups = [index for index, line in enumerate(lines) if "did not reply within 10 seconds" in line and line.startswith("POPUP ")]
        assert len(popups) == 1 and lines.index("MODAL_BEGIN") < lines.index("MODAL_END") < popups[0] < lines.index("FINAL"), lines
        assert requests(blocked) == [expected], lines
        print("PASS URL bridge deadline runs while a popup blocks the main actor")
    finally:
        for process in servers:
            process.kill()
            process.wait()
            if process.stdout:
                process.stdout.close()

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
        result = subprocess.run([str(binary), *arguments], env=environment, capture_output=True, text=True, check=False, timeout=10)
        assert result.returncode == status, (name, result.stdout, result.stderr)
        assert result.stdout.count("NATIVE ") == int(name.startswith("native command")), (name, result.stdout)
        assert result.stdout.count("WARM") == int(name in ("warm command", "warm command failure")), (name, result.stdout)
        print("PASS URL " + name)
