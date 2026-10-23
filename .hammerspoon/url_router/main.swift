import AppKit
import CryptoKit
import Darwin

private func readSnapshot(_ path: URL) throws -> Data {
    let descriptor = Darwin.open(path.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? file.close() }
    var before = stat()
    guard fstat(descriptor, &before) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    guard before.st_mode & S_IFMT == S_IFREG, before.st_uid == getuid(),
          before.st_mode & 0o022 == 0, before.st_size > 0, before.st_size <= 1024 * 1024 else {
        throw NSError(domain: "HammerspoonURLRouter", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Expected a user-owned regular router file of at most 1 MiB, not writable by others",
        ])
    }
    var data = Data()
    while data.count <= before.st_size {
        guard let next = try file.read(upToCount: Int(before.st_size) + 1 - data.count), !next.isEmpty else { break }
        data.append(next)
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0, data.count == before.st_size, before.st_size == after.st_size,
          before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
          before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
        throw NSError(domain: "HammerspoonURLRouter", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "The router file changed while reading; publish replacements atomically",
        ])
    }
    return data
}

// Blocks up to 15 seconds; callers stay off the main actor so a popup can't stall the reply.
private func requestRoute(_ request: Data) throws -> String {
    guard let port = CFMessagePortCreateRemote(nil, "local.pandoks.HammerspoonURLRouter.route" as CFString) else {
        throw NSError(domain: "HammerspoonURLRouter", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Hammerspoon URL router is not listening; reload Hammerspoon",
        ])
    }
    var reply: Unmanaged<CFData>?
    let status = CFMessagePortSendRequest(port, 1, request as CFData, 5, 10, CFRunLoopMode.defaultMode.rawValue, &reply)
    let data = reply?.takeRetainedValue()
    guard status == kCFMessagePortSuccess else {
        let message = switch status {
        case kCFMessagePortSendTimeout: "Hammerspoon URL router did not accept the link within 5 seconds"
        case kCFMessagePortReceiveTimeout: "Hammerspoon URL router did not reply within 10 seconds"
        default: "Hammerspoon URL router request failed (CFMessagePort status \(status))"
        }
        throw NSError(domain: "HammerspoonURLRouter", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    return data.map { String(decoding: $0 as Data, as: UTF8.self) } ?? ""
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, willContinueUserActivityWithType type: String) -> Bool {
        type == NSUserActivityTypeBrowsingWeb
    }

    func application(_ application: NSApplication, continue activity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard activity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = activity.webpageURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        route(url)
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                route(url)
            } else {
                native(url)
            }
        }
    }

    private func native(_ url: URL) {
        Task {
            do {
                try await openNative(url)
            } catch {
                report("Could not open link: \(error.localizedDescription)")
            }
        }
    }

    private func report(_ message: String) {
        NSLog("%@", message)
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Hammerspoon URL Router"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
        NSApplication.shared.setActivationPolicy(.prohibited)
    }

    private func route(_ url: URL) {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "org.hammerspoon.Hammerspoon").isEmpty else {
            report("Could not open link: Hammerspoon is not running")
            return
        }
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/HammerspoonURLRouter/selectors/rules.json")
        let request: Data
        do {
            let data = try readSnapshot(path)
            guard let snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  snapshot["version"] as? Int == 1,
                  let value = snapshot["generation"] as? String,
                  UUID(uuidString: value) != nil else {
                throw NSError(domain: "HammerspoonURLRouter", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "URL selectors are invalid; reload Hammerspoon",
                ])
            }
            let statusPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("HammerspoonURLRouter/status.json")
            let statusData = try readSnapshot(statusPath)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard let status = try JSONSerialization.jsonObject(with: statusData) as? [String: Any],
                  status["version"] as? Int == 1,
                  status["kind"] as? String == "ready",
                  status["generation"] as? String == value,
                  status["sha256"] as? String == digest else {
                throw NSError(domain: "HammerspoonURLRouter", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "URL selectors are not acknowledged; check the router status",
                ])
            }
            request = Data("\(value)\n\(url.absoluteString)".utf8)
        } catch {
            report("Could not open link: \(error.localizedDescription)")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try requestRoute(request) }
            DispatchQueue.main.async {
                switch result {
                case .success("true"):
                    return
                case .success("native"):
                    self.native(url)
                case .success("false"):
                    // Lua already logged the failure and displayed its details.
                    NSLog("URL routing failed for %@", url.host ?? "unknown host")
                case .success(let reply):
                    self.report("Could not open link: Hammerspoon routing failed: \(reply)")
                case .failure(let error):
                    self.report("Could not open link: \(error.localizedDescription)")
                }
            }
        }
    }
}

if CommandLine.arguments.dropFirst().first == "--inspect" {
    do {
        let result = try inspectUniversalLinks(Array(CommandLine.arguments.dropFirst(2)))
        FileHandle.standardOutput.write(result + Data([10]))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        exit(1)
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.prohibited)
if CommandLine.arguments.count > 1 {
    let warm = Array(CommandLine.arguments.dropFirst()) == ["--warm-links"]
    let url = CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--native"
        ? URL(string: CommandLine.arguments[2]) : nil
    guard warm || url?.scheme != nil else {
        FileHandle.standardError.write(Data("usage: HammerspoonURLRouter --native URL | --warm-links | --inspect HTTP_URL [HTTP_URL ...]\n".utf8))
        exit(1)
    }
    Task {
        do {
            if warm {
                try await warmNativeLinks()
            } else if let url {
                try await openNative(url)
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
application.run()
