"""Exercise default-handler completion, persistence, and prompting without showing UI."""

import json
import os
import subprocess
import tempfile
from pathlib import Path

source = Path(__file__).resolve().parent.parent / "url_router/set_default.swift"
subprocess.run(["swiftc", "-swift-version", "6", "-warnings-as-errors", "-typecheck", str(source)], check=True)

mock = r'''
struct MockBundle {
    let bundleIdentifier: String?
    init?(url: URL) {
        guard !url.path.contains("missing") else { return nil }
        bundleIdentifier = url.deletingPathExtension().lastPathComponent
    }
}
@MainActor
final class MockWorkspace {
    static let shared = MockWorkspace()
    var handlers: [String: URL] = ["http": URL(fileURLWithPath: "/mock/original-http.app"),
                                   "https": URL(fileURLWithPath: "/mock/original-https.app")]
    init() {
        for scheme in ProcessInfo.processInfo.environment["ALREADY", default: ""].split(separator: ",") {
            handlers[String(scheme)] = URL(fileURLWithPath: ProcessInfo.processInfo.environment["EXISTING_PATH", default: "/mock/target.app"])
        }
    }
    func urlForApplication(toOpen url: URL) -> URL? { handlers[url.scheme!] }
    func setDefaultApplication(at: URL, toOpenURLsWithScheme scheme: String) async throws {
        print("ATTEMPT " + scheme)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { continuation.resume() }
        }
        if ProcessInfo.processInfo.environment["FAIL_SCHEME"] == scheme {
            throw NSError(domain: "installer-test", code: 1)
        }
        if ProcessInfo.processInfo.environment["IGNORE_CHANGE"] == "1" { return }
        handlers[scheme] = at
        if ProcessInfo.processInfo.environment["AUTO_BOTH"] == "1" {
            handlers["http"] = at
            handlers["https"] = at
        }
    }
}
final class MockAlert {
    var messageText = ""
    var informativeText = ""
    var alertStyle = NSAlert.Style.warning
    func runModal() { print("POPUP " + informativeText) }
}
'''


def replace(text, old, new, count=1):
    assert text.count(old) == count, (old, text.count(old))
    return text.replace(old, new)


# Only the untested --launch path keeps the real workspace.
text = replace(source.read_text(), "NSWorkspace.shared", "MockWorkspace.shared", 5)
text = replace(text, "MockWorkspace.shared.openApplication", "NSWorkspace.shared.openApplication")
text = replace(replace(text, "Bundle(url:", "MockBundle(url:"), "let alert = NSAlert()", "let alert = MockAlert()")
text = replace(text, 'NSLog("%@", message)', 'print("LOG " + message)')
text = replace(text, "NSApplication.shared.", "// NSApplication.shared.", 2)
text = replace(text, "import AppKit", "import AppKit\n" + mock)
assert "NSAlert()" not in text and text.count("NSWorkspace.shared") == 1

with tempfile.TemporaryDirectory(prefix="url-set-default-test.", dir="/var/tmp") as directory:
    directory = Path(directory)
    test = directory / "main.swift"
    test.write_text(text)
    binary = directory / "installer"
    subprocess.run(["swiftc", "-swift-version", "6", "-warnings-as-errors", str(test), "-o", str(binary)], check=True)
    for name, failure, already, automatic, attempts in [
        ("async completion", "", "", "", ["http", "https"]),
        ("HTTP failure stops immediately", "http", "", "", ["http"]),
        ("HTTPS failure stops immediately", "https", "", "", ["http", "https"]),
        ("already configured skips both prompts", "", "http,https", "", []),
        ("existing HTTP skips its prompt", "", "http", "", ["https"]),
        ("macOS changing both defaults skips redundant HTTPS prompt", "", "", "1", ["http"]),
    ]:
        result = subprocess.run([str(binary), "/mock/target.app"],
            env=dict(os.environ, FAIL_SCHEME=failure, ALREADY=already, AUTO_BOTH=automatic),
            capture_output=True, text=True, timeout=10)
        assert result.returncode == bool(failure), result.stderr
        assert [line.removeprefix("ATTEMPT ") for line in result.stdout.splitlines() if line.startswith("ATTEMPT ")] == attempts, result.stdout
        assert result.stdout.count("POPUP ") == bool(failure), result.stdout
        assert result.stdout.count("LOG ") == bool(failure), result.stdout
        print("PASS defaults " + name)
    snapshot = directory / "defaults.json"
    subprocess.run([str(binary), "--snapshot", str(snapshot)], check=True, capture_output=True)
    expected = {"http": "/mock/original-http.app", "https": "/mock/original-https.app"}
    assert json.loads(snapshot.read_text()) == expected
    result = subprocess.run([str(binary), "--restore", str(snapshot)], check=True, capture_output=True, text=True)
    assert "ATTEMPT " not in result.stdout
    snapshot.write_text(json.dumps({"http": "/mock/target.app", "https": "/mock/target.app"}))
    result = subprocess.run([str(binary), "--restore", str(snapshot)], check=True, capture_output=True, text=True)
    assert result.stdout.splitlines() == ["ATTEMPT http", "http: OK", "ATTEMPT https", "https: OK"]
    for invalid in ({"http": "/mock/target.app"}, {"http": "/mock/missing.app", "https": "/mock/target.app"}):
        snapshot.write_text(json.dumps(invalid))
        result = subprocess.run([str(binary), "--restore", str(snapshot)], capture_output=True, text=True)
        assert result.returncode == 1 and "ATTEMPT " not in result.stdout
        assert result.stdout.count("POPUP ") == 1
    print("PASS defaults snapshot and restoration retain each scheme and reject invalid saves")
    result = subprocess.run([str(binary), "/mock/target.app"],
        env=dict(os.environ, ALREADY="http,https", EXISTING_PATH="/other/target.app"),
        capture_output=True, text=True, timeout=10)
    assert result.returncode == 0 and result.stdout.splitlines() == ["ATTEMPT http", "http: OK", "ATTEMPT https", "https: OK"]
    print("PASS defaults restore the requested path when another copy has the same bundle identifier")
    result = subprocess.run([str(binary), "/mock/target.app"], env=dict(os.environ, IGNORE_CHANGE="1"),
        capture_output=True, text=True, timeout=10)
    assert result.returncode == 1 and result.stdout.count("ATTEMPT ") == 1
    assert result.stdout.count("POPUP ") == 1 and "does not match" in result.stdout
    print("PASS defaults reject successful API completion that leaves the wrong handler")
    snapshot.write_text(json.dumps(expected))
    for coupling in ("", "1"):
        result = subprocess.run([str(binary), "--restore", str(snapshot)],
            env=dict(os.environ, ALREADY="http,https", AUTO_BOTH=coupling), capture_output=True, text=True, timeout=10)
        assert result.returncode == bool(coupling) and result.stdout.count("ATTEMPT ") == 2
        assert result.stdout.count("POPUP ") == bool(coupling)
        if coupling:
            assert "final HTTP(S) defaults" in result.stdout
    print("PASS defaults verify the complete saved pair after coupled browser changes")
