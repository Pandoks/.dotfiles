"""Select the helper's entitlements from a decoded Apple provisioning profile."""

import datetime
import plistlib
import sys
from pathlib import Path


def prepare(profile, application):
    key = "com.apple.developer.associated-domains.applinks.read-write"
    if not isinstance(profile, dict) or not isinstance(application, dict):
        raise TypeError("Provisioning profile and app metadata must be dictionaries")
    allowed = profile.get("Entitlements", {})
    if not isinstance(allowed, dict):
        raise TypeError("Provisioning profile has invalid entitlement data")
    if allowed.get(key) is not True:
        raise ValueError("Provisioning profile does not authorize " + key)
    identifier = allowed.get("com.apple.application-identifier", "")
    prefixes = profile.get("ApplicationIdentifierPrefix", [])
    bundle = application["CFBundleIdentifier"]
    if identifier not in [prefix + "." + bundle for prefix in prefixes]:
        raise ValueError("Provisioning profile does not match the helper's App ID: " + bundle)
    team = allowed.get("com.apple.developer.team-identifier")
    if not team or team not in profile.get("TeamIdentifier", []):
        raise ValueError("Provisioning profile has no matching team identifier")
    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, datetime.datetime) or expiration.replace(
        tzinfo=datetime.timezone.utc
    ) <= datetime.datetime.now(datetime.timezone.utc):
        raise ValueError("Provisioning profile is expired or has no expiration date")
    return {
        key: True,
        "com.apple.application-identifier": identifier,
        "com.apple.developer.team-identifier": team,
    }


if __name__ == "__main__":
    try:
        if len(sys.argv) != 4:
            raise ValueError("usage: provision.py PROFILE.plist Info.plist OUTPUT.plist")
        with Path(sys.argv[1]).open("rb") as file:
            profile = plistlib.load(file)
        with Path(sys.argv[2]).open("rb") as file:
            application = plistlib.load(file)
        entitlements = prepare(profile, application)
        with Path(sys.argv[3]).open("wb") as file:
            plistlib.dump(entitlements, file)
    except (OSError, ValueError, KeyError, TypeError, plistlib.InvalidFileException) as error:
        sys.exit(str(error))
