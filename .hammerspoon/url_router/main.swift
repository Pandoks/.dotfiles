import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var activeTasks: [Process] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "http" || url.scheme == "https" {
            route(url)
        }
    }

    private func route(_ url: URL) {
        guard let hsPath = [
            "/opt/homebrew/bin/hs",
            "/usr/local/bin/hs",
            "/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs",
        ].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            openInHelium(url)
            return
        }

        let encodedURL = Data(url.absoluteString.utf8).base64EncodedString()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: hsPath)
        task.arguments = [
            "-q",
            "-t", "15",
            "-c",
            "return RouteHTTPURL(hs.base64.decode(\"\(encodedURL)\"))",
        ]
        task.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                self?.activeTasks.removeAll { $0 === finished }
                if finished.terminationStatus != 0 {
                    self?.openInHelium(url)
                }
            }
        }

        do {
            try task.run()
            activeTasks.append(task)
        } catch {
            openInHelium(url)
        }
    }

    private func openInHelium(_ url: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/Applications/Helium.app/Contents/MacOS/Helium")
        task.arguments = [url.absoluteString]
        try? task.run()
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.prohibited)
application.run()
