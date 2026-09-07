import Foundation

/// Which APNs environment this build's push tokens actually belong to, reported to the relay so
/// it knows whether to send to `api.sandbox.push.apple.com` or `api.push.apple.com`.
///
/// Read from the embedded provisioning profile's `aps-environment` entitlement rather than
/// inferred from `#if DEBUG`. The two agree for the two common cases (Debug build → development
/// profile → sandbox; archived distribution build → production profile → production), which is
/// why `#if DEBUG` worked in practice — but they come apart for a Release-configuration build run
/// straight from Xcode onto a device. That keeps the development entitlement (so its tokens are
/// sandbox tokens) while `#if DEBUG` reports `production`, and the relay then pushes every one of
/// them to the production host, where APNs rejects them with 400 `BadDeviceToken`. Nothing in the
/// app surfaces that; it just looks like Live Activities silently not working.
///
/// The entitlement is the actual source of truth Xcode writes at signing time, so reading it
/// can't disagree with the build the way an inference can.
enum APNSEnvironment {
    /// `"sandbox"` or `"production"` — the exact strings the relay's `/register`,
    /// `/register-device`, and `/register-activity` endpoints validate against.
    static let current: String = resolve()

    private static func resolve() -> String {
        switch apsEnvironmentEntitlement() {
        case "development": return "sandbox"
        case "production": return "production"
        case let other?:
            // Unknown value: prefer the compile-time guess over inventing an answer.
            NSLog("NCDEBUG unrecognized aps-environment '%@' in provisioning profile, falling back to build configuration", other)
            return compileTimeFallback
        case nil:
            // No embedded profile at all. App Store builds are the expected case here — Apple
            // strips `embedded.mobileprovision` during processing — and those are always
            // production. The Simulator also has no profile, but it can't receive real pushes
            // anyway, so the value it reports is inert.
            return compileTimeFallback
        }
    }

    private static var compileTimeFallback: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }

    /// The `aps-environment` value from `embedded.mobileprovision`, or nil when the bundle has no
    /// profile or it can't be parsed. The file is a CMS/PKCS#7 signed blob wrapping an XML plist;
    /// rather than pulling in a CMS decoder for one string, this slices out the plist by its
    /// document markers, which is the standard approach for reading it and is safe because a
    /// parse failure is a nil, never a wrong answer.
    private static func apsEnvironmentEntitlement() -> String? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.firstRange(of: Data("<?xml".utf8)),
              let end = data.lastRange(of: Data("</plist>".utf8))
        else { return nil }

        let plistData = data[start.lowerBound..<end.upperBound]
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any]
        else { return nil }
        return entitlements["aps-environment"] as? String
    }
}
