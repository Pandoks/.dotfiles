# Draft inquiry to Apple Developer Support

Not submitted. Category: Development and Technical → Entitlements.

Subject: SFUniversalLink entitlement eligibility for a macOS URL-routing utility

Developer team: 36PW35T7W5 (Jason Kwok)
App: Hammerspoon URL Router
Registered bundle ID: local.pandoks.HammerspoonURLRouter
Platform: macOS

I am developing a personal macOS URL-routing utility. A small native Swift helper is the default HTTP/HTTPS handler and applies explicit routing rules through Hammerspoon. Matched links open in a selected app or browser profile; unmatched links should preserve native macOS app selection, with a configured browser used for ordinary web links.

The helper does not render web pages and is not an App Store app. Native Universal Links can bypass the default browser handler and go directly to an associated app, so the default-handler mechanism alone cannot apply my routing rules first.

I would like eligibility guidance for com.apple.developer.associated-domains.applinks.read-write and SFUniversalLink. I have a working Apple Development signing identity. Xcode 27 automatic provisioning cannot include this entitlement. Your Web Browser Universal Links request form asks whether the app primarily provides a web browser experience; answering No displays: "Apps must provide a web browser experience to request this entitlement."

1. Can a non-rendering macOS URL-routing utility obtain this entitlement for local development or Developer ID distribution? If so, what application process, certificate, and provisioning profile should I use?
2. If this utility is ineligible, is there a supported macOS API or architecture that lets a user-selected router receive external HTTP(S) links before Universal Link dispatch, apply explicit per-URL overrides, and preserve native handling for unmatched links? Or is that interception requirement unsupported?

I am seeking eligibility and supported-API guidance, not representing this utility as a web browser. Please route this inquiry to the appropriate entitlement or SafariServices team if necessary.

