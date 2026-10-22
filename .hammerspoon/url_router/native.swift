import AppKit

@MainActor
func warmNativeLinks() async throws {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.promptsUserIfNeeded = false
    configuration.requiresUniversalLinks = true
    do {
        _ = try await NSWorkspace.shared.open(URL(string: "https://127.0.0.1/")!, configuration: configuration)
        throw NSError(domain: "HammerspoonURLRouter", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "An application unexpectedly claims the loopback health URL",
        ])
    } catch {
        var cause = error as NSError
        while let underlying = cause.userInfo[NSUnderlyingErrorKey] as? NSError { cause = underlying }
        guard cause.domain == NSOSStatusErrorDomain, cause.code == Int(kLSApplicationNotFoundErr) else { throw error }
    }
}

@MainActor
func openNative(_ url: URL) async throws {
    let workspace = NSWorkspace.shared
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.promptsUserIfNeeded = false
    let application: URL
    if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
        configuration.requiresUniversalLinks = true
        do {
            _ = try await workspace.open(url, configuration: configuration)
            return
        } catch {
            var failure = error as NSError
            while let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError {
                failure = underlying
            }
            guard failure.domain == NSOSStatusErrorDomain,
                  failure.code == Int(kLSApplicationNotFoundErr) else {
                throw error
            }
        }

        guard let browser = workspace.urlForApplication(withBundleIdentifier: "net.imput.helium") else {
            throw NSError(domain: "HammerspoonURLRouter", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Helium is required to open web links",
            ])
        }
        application = browser
    } else {
        let excluded: Set<String> = [
            "org.hammerspoon.hammerspoon",
            "local.pandoks.hammerspoonurlrouter",
            Bundle.main.bundleIdentifier?.lowercased() ?? "",
        ]
        guard let handler = workspace.urlsForApplications(toOpen: url).first(where: {
            guard let identifier = Bundle(url: $0)?.bundleIdentifier?.lowercased() else { return false }
            return !excluded.contains(identifier)
        }) else {
            throw NSError(domain: "HammerspoonURLRouter", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No application outside Hammerspoon can open \(url.scheme ?? "this") links",
            ])
        }
        application = handler
    }

    configuration.requiresUniversalLinks = false
    _ = try await workspace.open([url], withApplicationAt: application, configuration: configuration)
}
