// BSideTestRunner — app identity + support-path routing regression.
//
// The ordinary app and the daily candidate are two fixed, recognized identity pairs. This
// suite proves the pure routing rules that BSidePlatform exposes (override > candidate default
// > ordinary default) WITHOUT touching any real support directory: every check either uses an
// explicit fake override or only compares path components/basenames.

import Foundation
import BSidePlatform

func runAppIdentityTests() {
    run("Identity.recognizedPairsAreFixed") { t in
        t.expectEqual(AppIdentity.normalBundleIdentifier, "local.bsidesmac.app",
                     "ordinary bundle identifier")
        t.expectEqual(AppIdentity.normalDisplayName, "bsideyou", "ordinary display name")
        t.expectEqual(AppIdentity.normalSupportFolderName, "BSideMac", "ordinary support folder")
        t.expectEqual(AppIdentity.dailyCandidateBundleIdentifier,
                      "local.bsidemac.dailycandidate.pzbl6ez3",
                      "candidate bundle identifier is the authorized stable ID")
        t.expectEqual(AppIdentity.dailyCandidateDisplayName, "bsideyou",
                     "candidate display name is the same exact lowercase product name")
        t.expectEqual(AppIdentity.dailyCandidateSupportFolderName, "BSideMac-DailyCandidate",
                     "candidate support folder")
        t.expectEqual(AppIdentity.recognizedBundleIdentifiers,
                      ["local.bsidesmac.app", "local.bsidemac.dailycandidate.pzbl6ez3", "local.bsidemac.desktoppreview"],
                      "exactly three recognized identities")
    }

    run("Identity.desktopPreviewIsIsolated") { t in
        let identifier = "local.bsidemac.desktoppreview"
        t.expectEqual(AppIdentity.variant(forBundleIdentifier: identifier), .desktopPreview, "preview identity")
        t.expectEqual(AppIdentity.displayName(forBundleIdentifier: identifier), "bsideyou Desktop Preview", "visible preview branding")
        t.expectEqual(AppPaths.resolvedSupportRoot(bundleIdentifier: identifier, environmentOverride: nil).lastPathComponent,
                      "BSideMac-DesktopPreview", "preview has its own support root")
        t.expectEqual(AppPaths.resolvedSupportRoot(bundleIdentifier: identifier, environmentOverride: "/tmp/preview-fixture").path,
                      "/tmp/preview-fixture", "explicit test root still takes precedence")
        t.expectNil(AppIdentity.variant(forBundleIdentifier: identifier + ".other"), "look-alike cannot enable preview")
    }

    run("Identity.variantAndFolderLookupIsExact") { t in
        t.expectEqual(AppIdentity.variant(forBundleIdentifier: "local.bsidesmac.app"), .normal,
                      "ordinary id maps to .normal")
        t.expectEqual(AppIdentity.variant(forBundleIdentifier:
            "local.bsidemac.dailycandidate.pzbl6ez3"), .dailyCandidate,
                      "candidate id maps to .dailyCandidate")
        t.expectNil(AppIdentity.variant(forBundleIdentifier: "local.bsidesmac.app.evil"),
                    "a suffix look-alike is unrecognized")
        t.expectNil(AppIdentity.variant(forBundleIdentifier: ""), "empty id is unrecognized")
        t.expectNil(AppIdentity.variant(forBundleIdentifier: "local.bsidemac.dailycandidate"),
                    "an id without the frozen suffix is unrecognized")

        t.expectEqual(AppIdentity.supportFolderName(forBundleIdentifier: "local.bsidesmac.app"),
                      "BSideMac", "ordinary folder lookup")
        t.expectEqual(AppIdentity.supportFolderName(forBundleIdentifier:
            "local.bsidemac.dailycandidate.pzbl6ez3"), "BSideMac-DailyCandidate",
                      "candidate folder lookup")
        t.expectNil(AppIdentity.supportFolderName(forBundleIdentifier: "local.unknown.app"),
                    "an unrecognized id owns no folder of its own")
        t.expectEqual(AppIdentity.displayName(forBundleIdentifier:
            "local.bsidemac.dailycandidate.pzbl6ez3"), "bsideyou",
                      "candidate display-name lookup")
        t.expectNil(AppIdentity.displayName(forBundleIdentifier: "local.unknown.app"),
                    "unrecognized id has no display name")
        t.expect(AppIdentity.normalSupportFolderName != AppIdentity.dailyCandidateSupportFolderName,
                 "candidate and ordinary data must never share a default folder")
    }

    run("Support.explicitOverrideAlwaysWins") { t in
        let override = "/tmp/bsidemac-test-override-\(UUID().uuidString)"
        for identifier in [nil, "local.bsidesmac.app", "local.bsidemac.dailycandidate.pzbl6ez3",
                           "local.unknown.app"] as [String?] {
            let resolved = AppPaths.resolvedSupportRoot(bundleIdentifier: identifier,
                                                        environmentOverride: override)
            t.expectEqual(resolved.path, override,
                          "override wins for identifier \(identifier ?? "nil")")
        }
        // The pure resolver never creates anything.
        t.expect(!FileManager.default.fileExists(atPath: override),
                 "resolution must not create the support directory")
    }

    run("Support.emptyOverrideFallsBackToIdentityDefault") { t in
        let candidate = AppPaths.resolvedSupportRoot(
            bundleIdentifier: "local.bsidemac.dailycandidate.pzbl6ez3", environmentOverride: "")
        t.expectEqual(candidate.lastPathComponent, "BSideMac-DailyCandidate",
                      "an empty override is ignored (not treated as a path)")
        let normal = AppPaths.resolvedSupportRoot(
            bundleIdentifier: "local.bsidesmac.app", environmentOverride: "")
        t.expectEqual(normal.lastPathComponent, "BSideMac", "empty override keeps ordinary")
    }

    run("Support.identityDefaultRouting") { t in
        let supportRoots = FileManager.default.urls(for: .applicationSupportDirectory,
                                                    in: .userDomainMask)[0]
        let normal = AppPaths.resolvedSupportRoot(bundleIdentifier: "local.bsidesmac.app",
                                                  environmentOverride: nil)
        let candidate = AppPaths.resolvedSupportRoot(
            bundleIdentifier: "local.bsidemac.dailycandidate.pzbl6ez3", environmentOverride: nil)
        let unrecognized = AppPaths.resolvedSupportRoot(bundleIdentifier: "local.unknown.app",
                                                        environmentOverride: nil)
        let noBundle = AppPaths.resolvedSupportRoot(bundleIdentifier: nil, environmentOverride: nil)

        t.expectEqual(normal.path, supportRoots.appendingPathComponent("BSideMac").path,
                      "ordinary default is ~/Library/Application Support/BSideMac")
        t.expectEqual(candidate.path,
                      supportRoots.appendingPathComponent("BSideMac-DailyCandidate").path,
                      "candidate default is .../BSideMac-DailyCandidate")
        t.expectEqual(unrecognized.path, normal.path,
                      "unrecognized bundle keeps the ordinary default (no invented folder)")
        t.expectEqual(noBundle.path, normal.path,
                      "a dev/test binary without a bundle identifier keeps ordinary")
        t.expectEqual(normal.deletingLastPathComponent().path,
                      candidate.deletingLastPathComponent().path,
                      "both defaults live under the same Application Support base")
    }
}
