# Signed Universal Link inspection experiment

The helper's read-only `--inspect` command queries `SFUniversalLink` and requires
its restricted entitlement. It does not open links or change preferences. This
signing experiment is independent of the selected `swcd` hook, which uses a
locally signed helper without that entitlement. See the [router guide](README.md)
for installation and tested coverage.

## Create the signing identity

For a local development test, create an **Apple Development** identity:

1. Open the full Xcode app and choose **Xcode → Settings → Accounts**.
2. Add your developer Apple Account, then select your paid development team.
3. Choose **Manage Certificates → + → Apple Development → Done**.
4. Confirm that `security find-identity -v -p codesigning` lists the new identity.

Xcode creates the certificate and its private key in the Mac's keychain. The
Command Line Tools alone do not include this account-management screen. You can
also create a CSR with Keychain Access, upload it when creating an Apple
Development certificate in the developer portal, and install the resulting
certificate on the same Mac.

## Obtain the entitlement and profile

The certificate alone does not authorize this API. In your developer account,
register the explicit Mac App ID `local.pandoks.HammerspoonURLRouter`. Check whether
Apple has granted `com.apple.developer.associated-domains.applinks.read-write` to
that App ID or team.

Apple's [Universal Link entitlement request](https://developer.apple.com/contact/request/browser-universal-links-request)
requires a web browser experience and an App Store URL. On September 18, 2026,
answering No to the browser question blocked the request for this background
router. A developer membership and signing identity alone do not establish
eligibility. Ask [Apple Developer Support](https://developer.apple.com/contact/)
under Development and Technical → Entitlements whether an exception or supported
alternative exists. `entitlement-request.md` contains the inquiry draft; it has
not been submitted.

After approval, enable the capability and create a **Mac App Development** profile
for this App ID, your Apple Development certificate, and this registered Mac.
Download the profile. The build checks its entitlement, exact App ID, team, and
expiration, then embeds it. macOS remains responsible for validating Apple's
authorization, the signing certificate, and device eligibility at launch.

If Apple approves a different distribution method, use the corresponding
certificate and provisioning profile. Eligibility for this background routing
helper and Developer ID distribution still needs confirmation from Apple.

## Build and inspect

Use the exact identity name or SHA-1 hash shown by `security find-identity`:

```sh
probe_dir=$(mktemp -d /var/tmp/url-router-signed.XXXXXX)
zsh ~/.hammerspoon/url_router/build.sh \
  "$probe_dir/Hammerspoon URL Router.app" \
  'SIGNING_IDENTITY_FROM_SECURITY' \
  "$HOME/Downloads/router.provisionprofile"

"$probe_dir/Hammerspoon URL Router.app/Contents/MacOS/HammerspoonURLRouter" \
  --inspect \
  'https://app.notion.com/p/sieve-data/url-router-probe' \
  'https://app.notion.com/login' \
  'https://example.com/'
```

The build requires a new output path and does not register the app, replace the
installed router, or change the default browser. An authorized probe prints JSON
with the associated application's path and enabled state, or `associated: false`
when the API finds no association. Missing entitlement is an error, never a
successful empty association result.

Omitting both signing arguments makes an ad-hoc build for ordinary router checks;
that build deliberately cannot inspect Universal Link preferences. Supplying only
one signing argument, an unauthorized profile, or an ad-hoc identity with a
profile fails the build.

## Acceptance for the inspection experiment

First confirm that an entitled probe identifies Notion for an eligible content
URL and distinguishes excluded paths and browser-only URLs. Then test reversible
preference changes with the original state recorded and restored, including their
scope across URL paths and domains. Finally verify real external clicks for Work,
Personal, unmatched native links, excluded paths, ordinary web links, and closed
apps. Do not credit explicit delivery to the helper as proof of ordinary-click
interception. No preference-writing command is enabled by this preparation.

## References

- [Apple: create a signing identity](https://developer.apple.com/documentation/xcode/sharing-your-teams-signing-certificates)
- [Apple: certificate types](https://developer.apple.com/help/account/certificates/certificates-overview)
- [Apple: create a CSR](https://developer.apple.com/help/account/certificates/create-a-certificate-signing-request)
- [Apple: create a development profile](https://developer.apple.com/help/account/provisioning-profiles/create-a-development-provisioning-profile)
- [Apple: SFUniversalLink](https://developer.apple.com/documentation/safariservices/sfuniversallink)
