import AppKit

guard CommandLine.arguments.count == 2 else {
    fatalError("usage: set_default.swift /path/to/application.app")
}

let application = URL(fileURLWithPath: CommandLine.arguments[1])
let group = DispatchGroup()
var failed = false

func isCurrentHandler(for scheme: String) -> Bool {
    guard let testURL = URL(string: "\(scheme)://example.invalid"),
          let handler = NSWorkspace.shared.urlForApplication(toOpen: testURL) else {
        return false
    }
    return handler.standardizedFileURL == application.standardizedFileURL
}

for scheme in ["http", "https"] {
    group.enter()
    NSWorkspace.shared.setDefaultApplication(
        at: application,
        toOpenURLsWithScheme: scheme
    ) { error in
        if let error, !isCurrentHandler(for: scheme) {
            print("\(scheme): ERROR \(error)")
            failed = true
        } else {
            print("\(scheme): OK")
        }
        group.leave()
    }
    while group.wait(timeout: .now()) == .timedOut {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    }
}

if failed {
    exit(1)
}
