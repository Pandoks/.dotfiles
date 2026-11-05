import AppKit
import Darwin

@MainActor
func terminate(_ path: String) throws {
    let destination = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    for application in NSRunningApplication.runningApplications(withBundleIdentifier: "local.pandoks.HammerspoonURLRouter") {
        guard application.bundleURL?.resolvingSymlinksInPath() == destination else { continue }
        let descriptor = kqueue()
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        var event = kevent64_s(ident: UInt64(application.processIdentifier), filter: Int16(EVFILT_PROC),
                              flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT), fflags: UInt32(NOTE_EXIT), data: 0, udata: 0, ext: (0, 0))
        guard kevent64(descriptor, &event, 1, nil, 0, 0, nil) == 0 else {
            if errno == ESRCH { continue }
            throw POSIXError(.EIO)
        }
        guard application.forceTerminate() else { throw POSIXError(.EPERM) }
        var timeout = timespec(tv_sec: 5, tv_nsec: 0)
        guard kevent64(descriptor, nil, 0, &event, 1, 0, &timeout) == 1 else {
            throw NSError(domain: "HammerspoonURLRouter", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The previous URL helper did not exit before replacement",
            ])
        }
    }
}

@MainActor
func current() throws -> [String: String] {
    var result: [String: String] = [:]
    for scheme in ["http", "https"] {
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: URL(string: scheme + "://127.0.0.1/")!) else {
            throw NSError(domain: "HammerspoonURLRouter", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The default \(scheme) handler is missing",
            ])
        }
        result[scheme] = url.path
    }
    return result
}

@MainActor
func configure(_ applications: [String: String]) async throws {
    for scheme in ["http", "https"] {
        guard let path = applications[scheme], let bundle = Bundle(url: URL(fileURLWithPath: path)),
              bundle.bundleIdentifier != nil else {
            throw NSError(domain: "HammerspoonURLRouter", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The saved \(scheme) handler is unavailable",
            ])
        }
        let existing = NSWorkspace.shared.urlForApplication(toOpen: URL(string: scheme + "://127.0.0.1/")!)
        let destination = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        if existing?.resolvingSymlinksInPath() == destination {
            print("\(scheme): already configured")
            continue
        }
        do {
            try await NSWorkspace.shared.setDefaultApplication(
                at: destination, toOpenURLsWithScheme: scheme)
            guard NSWorkspace.shared.urlForApplication(toOpen: URL(string: scheme + "://127.0.0.1/")!)?.resolvingSymlinksInPath() == destination else {
                throw NSError(domain: "HammerspoonURLRouter", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "The default handler does not match the requested application",
                ])
            }
            print("\(scheme): OK")
        } catch {
            throw NSError(domain: "HammerspoonURLRouter", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not set the default \(scheme) handler: \(error.localizedDescription)",
            ])
        }
    }
    for (scheme, path) in try current() {
        guard let requested = applications[scheme],
              URL(fileURLWithPath: path).resolvingSymlinksInPath()
                == URL(fileURLWithPath: requested).resolvingSymlinksInPath() else {
            throw NSError(domain: "HammerspoonURLRouter", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The final HTTP(S) defaults do not match the requested handlers",
            ])
        }
    }
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.count == 2 && arguments[0] == "--launch" {
        let path = URL(fileURLWithPath: arguments[1]).resolvingSymlinksInPath()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.promptsUserIfNeeded = false
        try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, any Error>) in
            NSWorkspace.shared.openApplication(at: path, configuration: configuration) { application, error in
                if let error { completion.resume(throwing: error); return }
                guard application?.bundleIdentifier == "local.pandoks.HammerspoonURLRouter", application?.bundleURL?.resolvingSymlinksInPath() == path else {
                    completion.resume(throwing: NSError(domain: "HammerspoonURLRouter", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "The running URL helper does not match the installed application",
                    ]))
                    return
                }
                completion.resume()
            }
        }
    } else if arguments.count == 2 && arguments[0] == "--terminate" {
        try terminate(arguments[1])
    } else if arguments.count == 2 && arguments[0] == "--snapshot" {
        let data = try JSONSerialization.data(withJSONObject: current(), options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: arguments[1]), options: .atomic)
    } else if arguments.count == 2 && arguments[0] == "--restore" {
        let data = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
        guard let saved = try JSONSerialization.jsonObject(with: data) as? [String: String],
              Set(saved.keys) == ["http", "https"] else {
            throw NSError(domain: "HammerspoonURLRouter", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The saved default handlers are invalid",
            ])
        }
        try await configure(saved)
    } else if arguments.count == 1 && !arguments[0].hasPrefix("--") {
        try await configure(["http": arguments[0], "https": arguments[0]])
    } else {
        throw NSError(domain: "HammerspoonURLRouter", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "usage: set_default.swift APP | --snapshot FILE | --restore FILE | --terminate APP | --launch APP",
        ])
    }
} catch {
    let message = error.localizedDescription
    NSLog("%@", message)
    FileHandle.standardError.write(Data((message + "\n").utf8))
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "Hammerspoon URL Router"
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.runModal()
    exit(1)
}
