import AppKit
import CryptoKit
import Darwin

private struct StatKey: Equatable {
    let dev: dev_t
    let ino: ino_t
    let size: off_t
    let mtimeSec: Int
    let mtimeNsec: Int
    let mode: mode_t
    let uid: uid_t

    init?(_ info: stat) {
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o022 == 0, info.st_size > 0, info.st_size <= 1024 * 1024 else {
            return nil
        }
        dev = info.st_dev
        ino = info.st_ino
        size = info.st_size
        mtimeSec = info.st_mtimespec.tv_sec
        mtimeNsec = info.st_mtimespec.tv_nsec
        mode = info.st_mode
        uid = info.st_uid
    }
}

private func statKey(_ path: String) -> StatKey? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    return StatKey(info)
}

private func readSnapshot(_ path: URL) throws -> (Data, StatKey) {
    let descriptor = Darwin.open(path.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? file.close() }
    var before = stat()
    guard fstat(descriptor, &before) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    guard let initial = StatKey(before) else {
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
    guard fstat(descriptor, &after) == 0, let final = StatKey(after),
          data.count == before.st_size, initial == final else {
        throw NSError(domain: "HammerspoonURLRouter", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "The router file changed while reading; publish replacements atomically",
        ])
    }
    return (data, final)
}

// Accessed only on `routes`.
private nonisolated(unsafe) var remote: CFMessagePort?

private func connect() throws -> CFMessagePort {
    guard let port = CFMessagePortCreateRemote(nil, "local.pandoks.HammerspoonURLRouter.route" as CFString) else {
        throw NSError(domain: "HammerspoonURLRouter", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Hammerspoon URL router is not listening; reload Hammerspoon",
        ])
    }
    remote = port
    return port
}

// Blocks up to 15 seconds per request; callers stay off the main actor so a popup can't stall the reply.
private func requestRoute(_ request: Data) throws -> String {
    let port: CFMessagePort
    if let cached = remote, CFMessagePortIsValid(cached) {
        port = cached
    } else {
        remote = nil
        port = try connect()
    }
    var reply: Unmanaged<CFData>?
    let status = CFMessagePortSendRequest(port, 1, request as CFData, 5, 10, CFRunLoopMode.defaultMode.rawValue, &reply)
    let data = reply?.takeRetainedValue()
    guard status == kCFMessagePortSuccess else {
        CFMessagePortInvalidate(port)
        remote = nil
        let message = switch status {
        case kCFMessagePortSendTimeout: "Hammerspoon URL router did not accept the link within 5 seconds"
        case kCFMessagePortReceiveTimeout: "Hammerspoon URL router did not reply within 10 seconds"
        default: "Hammerspoon URL router request failed (CFMessagePort status \(status))"
        }
        throw NSError(domain: "HammerspoonURLRouter", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    return data.map { String(decoding: $0 as Data, as: UTF8.self) } ?? ""
}

// CFMessagePort shares one remote and reply port per name, so requests run one at a time.
private let routes = DispatchQueue(label: "HammerspoonURLRouter.route", qos: .userInitiated)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private struct Verification {
        let rulesPath: String
        let rulesStat: StatKey
        let statusPath: String
        let statusStat: StatKey
        let generation: String
    }

    private var verification: Verification?
    private var cache: URL?

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

    private func cacheDirectory() throws -> URL {
        if let cache { return cache }
        // dirhelper never prunes the Darwin cache directory, unlike its temporary directory.
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count) > 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let url = URL(fileURLWithFileSystemRepresentation: buffer, isDirectory: true, relativeTo: nil)
        cache = url
        return url
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
            let statusPath = try cacheDirectory().appendingPathComponent("HammerspoonURLRouter/status.json")
            let generation: String
            if let cached = verification,
               cached.rulesPath == path.path,
               cached.statusPath == statusPath.path,
               let rulesStat = statKey(path.path),
               let statusStat = statKey(statusPath.path),
               cached.rulesStat == rulesStat,
               cached.statusStat == statusStat {
                generation = cached.generation
            } else {
                verification = nil
                let (data, rulesStat) = try readSnapshot(path)
                guard let snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      snapshot["version"] as? Int == 1,
                      let value = snapshot["generation"] as? String,
                      UUID(uuidString: value) != nil else {
                    throw NSError(domain: "HammerspoonURLRouter", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "URL selectors are invalid; reload Hammerspoon",
                    ])
                }
                let (statusData, statusStat) = try readSnapshot(statusPath)
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
                verification = Verification(
                    rulesPath: path.path,
                    rulesStat: rulesStat,
                    statusPath: statusPath.path,
                    statusStat: statusStat,
                    generation: value
                )
                generation = value
            }
            request = Data("\(generation)\n\(url.absoluteString)".utf8)
        } catch {
            report("Could not open link: \(error.localizedDescription)")
            return
        }
        routes.async {
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

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.prohibited)
if CommandLine.arguments.count > 1 {
    let warm = Array(CommandLine.arguments.dropFirst()) == ["--warm-links"]
    let url = CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--native"
        ? URL(string: CommandLine.arguments[2]) : nil
    guard warm || url?.scheme != nil else {
        FileHandle.standardError.write(Data("usage: HammerspoonURLRouter --native URL | --warm-links\n".utf8))
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
