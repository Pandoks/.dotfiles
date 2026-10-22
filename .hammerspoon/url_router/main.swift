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

private final class RouteTask: @unchecked Sendable {
    // Mutable state belongs to this queue, including cancellation while a modal occupies the main actor.
    private let queue = DispatchQueue(label: "HammerspoonURLRouter.process", qos: .userInitiated)
    private let process = Process()
    private let output = Pipe()
    private var reader: (any DispatchSourceRead)?
    private var timer: (any DispatchSourceTimer)?
    private var response = Data()
    private var status: Int32?
    private var ended = false
    private var truncated = false
    private var completion: (@Sendable (RouteTask, Int32, String, String?) -> Void)?

    init(path: String, arguments: [String], completion: @escaping @Sendable (RouteTask, Int32, String, String?) -> Void) {
        self.completion = completion
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
    }

    func run() throws {
        try queue.sync { try start() }
    }

    private func start() throws {
        let handle = output.fileHandleForReading
        let descriptor = handle.fileDescriptor
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        self.reader = reader
        reader.setEventHandler { [weak self] in
            self?.read()
        }
        reader.setCancelHandler { try? handle.close() }
        reader.activate()
        process.terminationHandler = { [weak self] finished in
            self?.queue.async { [weak self] in
                guard let self, self.completion != nil else { return }
                self.status = finished.terminationStatus
                if self.ended { self.finish() }
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        timer.schedule(deadline: .now() + 15)
        timer.setEventHandler { [weak self] in
            guard let self, self.completion != nil else { return }
            if self.process.isRunning { kill(self.process.processIdentifier, SIGKILL) }
            self.finish("Hammerspoon URL handler timed out after 15 seconds")
        }
        timer.activate()
        do {
            try process.run()
            try? output.fileHandleForWriting.close()
        } catch {
            completion = nil
            timer.cancel()
            reader.cancel()
            try? output.fileHandleForWriting.close()
            throw error
        }
    }

    private func read() {
        guard completion != nil else { return }
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
        if count > 0 {
            let retained = min(count, 4096 - response.count)
            response.append(contentsOf: bytes.prefix(retained))
            truncated = truncated || retained < count
        } else if count == 0 {
            ended = true
            reader?.cancel()
            if status != nil { finish() }
        } else if errno != EAGAIN && errno != EINTR {
            let error = errno
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            finish("Could not read Hammerspoon URL handler output: \(String(cString: strerror(error)))")
        }
    }

    private func finish(_ error: String? = nil) {
        guard let completion else { return }
        self.completion = nil
        timer?.cancel()
        timer = nil
        reader?.cancel()
        reader = nil
        process.terminationHandler = nil
        let response = String(decoding: response, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            + (truncated ? " [output truncated]" : "")
        completion(self, status ?? -1, response, error)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var activeTasks: [RouteTask] = []

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
        guard let hsPath = [
            "/opt/homebrew/bin/hs",
            "/usr/local/bin/hs",
            "/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs",
        ].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            report("Could not open link: Hammerspoon CLI is missing")
            return
        }

        let encodedURL = Data(url.absoluteString.utf8).base64EncodedString()
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/HammerspoonURLRouter/selectors/rules.json")
        let generation: String
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
            generation = Data(value.utf8).base64EncodedString()
        } catch {
            report("Could not open link: \(error.localizedDescription)")
            return
        }
        let task = RouteTask(path: hsPath, arguments: [
            "-q",
            "-t", "15",
            "-c",
            "return RouteHTTPURL(hs.base64.decode(\"\(encodedURL)\"), hs.base64.decode(\"\(generation)\"))",
        ]) { [weak self] finished, status, response, error in
            DispatchQueue.main.async {
                self?.activeTasks.removeAll { $0 === finished }
                if let error {
                    self?.report("Could not open link: \(error)")
                    return
                }
                if status == 0 && response == "true" {
                    return
                }
                if status == 0 && response == "native" {
                    self?.native(url)
                    return
                }
                if status == 0 && response == "false" {
                    // Lua already logged the failure and displayed its details.
                    NSLog("URL routing failed for %@", url.host ?? "unknown host")
                    return
                }
                self?.report("Could not open link: Hammerspoon routing failed (exit \(status)): \(response)")
            }
        }
        do {
            try task.run()
            activeTasks.append(task)
        } catch {
            report("Could not start Hammerspoon URL handler: \(error.localizedDescription)")
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
