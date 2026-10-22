import Foundation
import SafariServices
import Security

struct UniversalLinkResult: Encodable {
    let url: String
    let associated: Bool
    let application: String?
    let enabled: Bool?
}

@MainActor
func inspectUniversalLinks(_ values: [String]) throws -> Data {
    guard !values.isEmpty else {
        throw NSError(domain: "HammerspoonURLRouter", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "usage: HammerspoonURLRouter --inspect HTTP_URL [HTTP_URL ...]",
        ])
    }
    let urls = try values.map { value in
        guard let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else {
            throw NSError(domain: "HammerspoonURLRouter", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Universal Link inspection requires an HTTP(S) URL with a host",
            ])
        }
        return url
    }

    var code: SecCode?
    var executable: SecStaticCode?
    var information: CFDictionary?
    var status = SecCodeCopySelf([], &code)
    if status == errSecSuccess, let code {
        status = SecCodeCopyStaticCode(code, [], &executable)
    }
    if status == errSecSuccess, let executable {
        status = SecCodeCopySigningInformation(executable, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
    }
    guard status == errSecSuccess else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
    guard let signature = information as? [String: Any] else {
        throw NSError(domain: "HammerspoonURLRouter", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Could not read the helper's code signature",
        ])
    }
    let key = "com.apple.developer.associated-domains.applinks.read-write"
    let entitlements = signature[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
    guard entitlements?[key] as? Bool == true else {
        throw NSError(domain: "HammerspoonURLRouter", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "SFUniversalLink requires \(key). Build this helper with an authorized signing identity and provisioning profile.",
        ])
    }

    let results = urls.map { url in
        let link = SFUniversalLink(webpageURL: url)
        return UniversalLinkResult(url: url.absoluteString, associated: link != nil,
                                   application: link?.applicationURL.path, enabled: link?.isEnabled)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(results)
}
