import Foundation
import Darwin
import BSidePlatform

private enum DirectoryAccessFixture {
    static let contents = Data("BSideMac owned directory access fixture".utf8)

    static func create(in root: URL) throws -> URL {
        let directory = root.appendingPathComponent("resource", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try contents.write(to: directory.appendingPathComponent("fixture.txt"))
        return directory
    }

    static func read(_ lease: DirectoryAccessLease) throws -> Data {
        try withExtendedLifetime(lease) {
            try Data(contentsOf: lease.url.appendingPathComponent("fixture.txt"))
        }
    }
}

private final class WeakDirectoryAccessLease {
    weak var value: DirectoryAccessLease?
    init(_ value: DirectoryAccessLease?) { self.value = value }
}

func runDirectoryAccessTests() {
    run("DirectoryAccess.persistentAndTransferUseActualDirectory") { t in
        do {
            let root = try ProviderFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let directory = try DirectoryAccessFixture.create(in: root)
            let selected = try DirectoryAccessLease.fromSelectedURL(directory)
            t.expectEqual(selected.lease.url, directory, "selected URL is retained without broadening to its parent")
            t.expect(!selected.persistentData.isEmpty, "creates actual persistent security-scoped data")
            let restored = try DirectoryAccessLease.resolvePersistent(selected.persistentData)
            t.expectEqual(selected.lease.representsSameDirectory(as: restored.lease), true,
                          "separately resolved leases capture the same current directory identity")
            t.expectEqual(try DirectoryAccessFixture.read(restored.lease), DirectoryAccessFixture.contents,
                          "restored persistent root reads its own fixture")
            let transfer = try restored.lease.makeTransferBookmark()
            let receiver = try DirectoryAccessLease.resolveTransfer(transfer)
            t.expectEqual(selected.lease.representsSameDirectory(as: receiver), true,
                          "transfer lease preserves current-run directory identity")
            t.expectEqual(try DirectoryAccessFixture.read(receiver), DirectoryAccessFixture.contents,
                          "ephemeral transfer resolves the same directory")
        } catch { t.expect(false, "bookmark round trip failed: \(error)") }
    }

    run("DirectoryAccess.movedDirectoryRenewsPersistentBookmark") { t in
        do {
            let root = try ProviderFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let directory = try DirectoryAccessFixture.create(in: root)
            let saved = try DirectoryAccessLease.fromSelectedURL(directory)
            let moved = root.appendingPathComponent("renamed-resource", isDirectory: true)
            try FileManager.default.moveItem(at: directory, to: moved)
            let resolved = try DirectoryAccessLease.resolvePersistent(saved.persistentData)
            t.expectEqual(saved.lease.representsSameDirectory(as: resolved.lease), true,
                          "the original captured identity remains equal after rename")
            t.expectEqual(resolved.lease.url.resolvingSymlinksInPath().path, moved.resolvingSymlinksInPath().path,
                          "bookmark follows the directory identity after rename")
            t.expectEqual(try DirectoryAccessFixture.read(resolved.lease), DirectoryAccessFixture.contents,
                          "renamed authorized directory is readable")
            guard let renewed = resolved.renewedData else {
                t.expect(false, "a renamed persistent directory returns renewed bookmark data")
                return
            }
            let nextLaunch = try DirectoryAccessLease.resolvePersistent(renewed)
            t.expectEqual(try DirectoryAccessFixture.read(nextLaunch.lease), DirectoryAccessFixture.contents,
                          "renewed persistent data remains usable")
        } catch { t.expect(false, "bookmark relocation failed: \(error)") }
    }

    run("DirectoryAccess.capturedIdentityRejectsReplacementAtCachedOldPath") { t in
        do {
            let root = try ProviderFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let directory = try DirectoryAccessFixture.create(in: root)
            _ = try directory.resourceValues(forKeys: [.fileResourceIdentifierKey])
            let original = try DirectoryAccessLease.fromSelectedURL(directory)
            let moved = root.appendingPathComponent("moved-resource", isDirectory: true)
            try FileManager.default.moveItem(at: directory, to: moved)
            let movedLease = try DirectoryAccessLease.fromSelectedURL(moved).lease
            t.expectEqual(original.lease.representsSameDirectory(as: movedLease), true,
                          "rename changes the path while retaining the captured physical identity")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("replacement-directory".utf8).write(to: directory.appendingPathComponent("fixture.txt"))
            let replacement = try DirectoryAccessLease.fromSelectedURL(directory).lease
            t.expectEqual(original.lease.representsSameDirectory(as: replacement), false,
                          "fresh metadata detects a different inode despite the cached old URL and equal path")
            t.expectEqual(replacement.representsSameDirectory(as: original.lease), false,
                          "identity comparison is symmetric and does not reread the original lease's reused path")
            let restored = try DirectoryAccessLease.resolvePersistent(original.persistentData)
            let actuallyOriginal = try DirectoryAccessFixture.read(restored.lease) == DirectoryAccessFixture.contents
            t.expectEqual(original.lease.representsSameDirectory(as: restored.lease), actuallyOriginal,
                          "identity follows the directory actually resolved, including Foundation path replacement")
        } catch { t.expect(false, "replacement identity fixture failed: \(error)") }
    }

    run("DirectoryAccess.missingDirectoryCannotClaimSameIdentity") { t in
        do {
            let root = try ProviderFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let directory = try DirectoryAccessFixture.create(in: root)
            let original = try DirectoryAccessLease.fromSelectedURL(directory)
            let transfer = try original.lease.makeTransferBookmark()
            try FileManager.default.removeItem(at: directory)
            let resolvers: [() throws -> DirectoryAccessLease] = [
                { try DirectoryAccessLease.fromSelectedURL(directory).lease },
                { try DirectoryAccessLease.resolvePersistent(original.persistentData).lease },
                { try DirectoryAccessLease.resolveTransfer(transfer) },
            ]
            for resolve in resolvers {
                do {
                    let missing = try resolve()
                    t.expectNil(missing.representsSameDirectory(as: original.lease),
                                "a missing directory has no fresh identity, even if a bookmark supplies cached metadata")
                    t.expectNil(missing.representsSameDirectory(as: missing),
                                "two absent identities must remain unknown rather than compare equal")
                } catch {
                    // Foundation may reject the missing target before it can produce a lease.
                }
            }
            t.expectThrows("captured identity is not a substitute for current file readability") {
                _ = try DirectoryAccessFixture.read(original.lease)
            }
        } catch { t.expect(false, "missing identity fixture failed: \(error)") }
    }

    run("DirectoryAccess.invalidDataNeverFallsBackToAnyPath") { t in
        for data in [Data(), Data("not a bookmark".utf8)] {
            t.expectThrows("invalid persistent bookmark is rejected") {
                _ = try DirectoryAccessLease.resolvePersistent(data)
            }
            t.expectThrows("invalid transfer bookmark is rejected") {
                _ = try DirectoryAccessLease.resolveTransfer(data)
            }
        }
        t.expectThrows("a network URL cannot become a directory lease") {
            _ = try DirectoryAccessLease.fromSelectedURL(URL(string: "https://example.invalid/resource")!)
        }
        t.expectThrows("empty legacy path must not expand into the current working directory") {
            _ = try DirectoryAccessLease.migrateLegacyPath("")
        }
    }

    run("DirectoryAccess.detachedReadOwnsLeaseUntilCompletion") { t in
        do {
            let root = try ProviderFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let directory = try DirectoryAccessFixture.create(in: root)
            var owner: DirectoryAccessLease? = try DirectoryAccessLease.fromSelectedURL(directory).lease
            let tracked = WeakDirectoryAccessLease(owner)
            let entered = DispatchSemaphore(value: 0)
            var resumeRead: AsyncStream<Void>.Continuation?
            let permission = AsyncStream<Void> { resumeRead = $0 }
            let completed = DispatchSemaphore(value: 0)
            let readSucceeded = DispatchSemaphore(value: 0)
            let reader = Task.detached { [lease = owner!] in
                entered.signal()
                // Suspend the task until the synchronous owner has been dropped; never block
                // a cooperative executor thread while the test checks the retained lease.
                for await _ in permission { break }
                return (try? DirectoryAccessFixture.read(lease)) == DirectoryAccessFixture.contents
            }
            Task.detached {
                if await reader.value { readSucceeded.signal() }
                // Observe completion from outside the reader, after its capture is released.
                completed.signal()
            }
            t.expect(entered.wait(timeout: .now() + 3) == .success, "detached reader starts")
            owner = nil
            t.expect(tracked.value != nil, "dropping the UI owner does not release an active detached reader's lease")
            resumeRead?.yield(())
            resumeRead?.finish()
            t.expect(completed.wait(timeout: .now() + 3) == .success, "detached reader completes")
            t.expect(readSucceeded.wait(timeout: .now()) == .success, "detached read keeps actual directory access")
            t.expect(tracked.value == nil, "final detached capture is released after completion")
        } catch { t.expect(false, "lease lifetime fixture failed: \(error)") }
    }

    run("DirectoryAccess.accessLeaseDoesNotReplaceRealReadValidation") { t in
        guard geteuid() != 0 else {
            print("      SKIP — root bypasses fixture permission checks")
            return
        }
        do {
            let root = try ProviderFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let directory = try DirectoryAccessFixture.create(in: root)
            let migrated = try DirectoryAccessLease.migrateLegacyPath(directory.path)
            t.expect(!migrated.persistentData.isEmpty, "legacy migration creates real security-scoped data")
            let file = directory.appendingPathComponent("fixture.txt")
            try ProviderFixture.withPermissions(0, at: file) {
                t.expectThrows("a lease/start result does not bypass current file permissions") {
                    _ = try DirectoryAccessFixture.read(migrated.lease)
                }
            }
            t.expectEqual(try DirectoryAccessFixture.read(migrated.lease), DirectoryAccessFixture.contents,
                          "same lease reads again after fixture permissions recover")
        } catch { t.expect(false, "read validation fixture failed: \(error)") }
    }

    run("DirectoryIdentity.snapshotComparisonIsThreeWay") { t in
        func snap(_ uuid: String?, _ inode: UInt64?, _ persistent: Bool?) -> DirectoryIdentitySnapshot {
            DirectoryIdentitySnapshot(volumeUUID: uuid, inode: inode,
                                      persistentIDsSupported: persistent, provenance: .explicitSelection)
        }
        let anchor = snap("VOL-A", 42, true)
        t.expectEqual(anchor.comparison(with: snap("VOL-A", 42, true)), .consistent,
                      "a complete equal tuple is consistent")
        t.expectEqual(anchor.comparison(with: snap("VOL-B", 42, true)), .conflict(.volumeChanged),
                      "different known volume UUIDs conflict")
        t.expectEqual(anchor.comparison(with: snap("VOL-A", 43, true)), .conflict(.inodeChanged),
                      "different persistent inode under the same UUID conflicts")
        t.expectEqual(anchor.comparison(with: snap("VOL-A", nil, true)), .unknown,
                      "a missing inode is unknown, never a conflict")
        t.expectEqual(anchor.comparison(with: snap(nil, 42, true)), .unknown,
                      "a missing volume namespace is unknown")
        t.expectEqual(anchor.comparison(with: snap("VOL-A", 43, false)), .unknown,
                      "inode churn without established persistence is unknown")
        t.expectEqual(anchor.comparison(with: snap("VOL-A", 43, nil)), .unknown,
                      "unknown persistence capability is unknown")
        t.expectEqual(anchor.comparison(with: snap("VOL-A", 42, nil)), .unknown,
                      "equal inode without established persistence stays unknown")
    }

    run("DirectoryIdentity.captureSerializesAndRejectsReplacement") { t in
        do {
            let root = try ProviderFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let directory = try DirectoryAccessFixture.create(in: root)
            let selected = try DirectoryAccessLease.fromSelectedURL(directory)
            guard let anchor = selected.lease.identitySnapshot(provenance: .explicitSelection) else {
                t.expect(false, "an owned local directory yields a capturable identity")
                return
            }
            t.expect(anchor.volumeUUID != nil, "a local directory carries a volume namespace")
            let encoded = try JSONEncoder().encode(anchor)
            t.expectEqual(try JSONDecoder().decode(DirectoryIdentitySnapshot.self, from: encoded), anchor,
                          "snapshot survives a versioned serialization roundtrip")
            func freshAt(_ url: URL) throws -> DirectoryIdentitySnapshot? {
                try DirectoryAccessLease.resolvePersistent(
                    DirectoryAccessLease.fromSelectedURL(url).persistentData).lease
                    .identitySnapshot(provenance: .legacyAdopted)
            }
            if anchor.persistentIDsSupported != true {
                print("      SKIP — fixture volume has no established persistent IDs")
                return
            }
            t.expectEqual(anchor.comparison(with: try freshAt(directory)!), .consistent,
                          "the unchanged directory stays consistent")
            let moved = root.appendingPathComponent("moved-resource", isDirectory: true)
            try FileManager.default.moveItem(at: directory, to: moved)
            guard let movedFresh = try DirectoryAccessLease.resolvePersistent(selected.persistentData).lease
                .identitySnapshot(provenance: .legacyAdopted) else {
                t.expect(false, "the moved original still captures fresh identity")
                return
            }
            t.expectEqual(anchor.comparison(with: movedFresh), .consistent,
                          "a same-volume move keeps the persistent tuple")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let replacement = try DirectoryAccessLease.fromSelectedURL(directory).lease
                .identitySnapshot(provenance: .explicitSelection) else {
                t.expect(false, "the replacement directory captures fresh identity")
                return
            }
            t.expectEqual(anchor.comparison(with: replacement), .conflict(.inodeChanged),
                          "a fresh inode at the old path is a detectable conflict")
        } catch { t.expect(false, "identity capture fixture failed: \(error)") }
    }

    run("DirectoryIdentity.historicalBookmarkProbeNeverInventsIdentity") { t in
        do {
            let root = try ProviderFixture.freshTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let directory = try DirectoryAccessFixture.create(in: root)
            let selected = try DirectoryAccessLease.fromSelectedURL(directory)
            let historical = DirectoryAccessLease.historicalIdentity(fromBookmarkData: selected.persistentData)
            if let historical {
                t.expectEqual(historical.version, DirectoryIdentitySnapshot.currentVersion,
                              "bookmark history is versioned")
                t.expectEqual(historical.provenance, .bookmarkHistorical,
                              "bookmark history is labelled as historical evidence")
                let fresh = selected.lease.identitySnapshot(provenance: .explicitSelection)
                t.expect(!(historical.comparison(with: fresh!) == .conflict(.volumeChanged)),
                          "a bookmark from this directory never reports a volume conflict")
            } else {
                print("      NOTE — this bookmark carries no recoverable historical identity")
            }
            t.expectNil(DirectoryAccessLease.historicalIdentity(fromBookmarkData: Data("not a bookmark".utf8)),
                        "invalid bookmark bytes never produce invented identity")
        } catch { t.expect(false, "historical bookmark probe failed: \(error)") }
    }

    run("DirectoryIdentity.unsupportedVersionIsNeverInterpreted") { t in
        let future = DirectoryIdentitySnapshot(version: 99, volumeUUID: "VOL-A", inode: 7,
                                               persistentIDsSupported: true,
                                               provenance: .explicitSelection)
        let fresh = DirectoryIdentitySnapshot(volumeUUID: "VOL-A", inode: 7,
                                              persistentIDsSupported: true,
                                              provenance: .legacyAdopted)
        t.expectEqual(future.comparison(with: fresh), .unknown,
                      "an unsupported-version anchor is never compared as consistent/conflict")
        // Prospective adoption requires a usable volume namespace; inode alone is insufficient.
        let inodeOnly = DirectoryIdentitySnapshot(volumeUUID: nil, inode: 7,
                                                  persistentIDsSupported: true,
                                                  provenance: .legacyAdopted)
        t.expectNil(inodeOnly.adoptedForLegacyMigration(),
                    "an inode without a volume namespace is not a sufficient baseline")
        t.expectEqual(DirectoryIdentitySnapshot(volumeUUID: "VOL-A", inode: nil,
                                                persistentIDsSupported: true,
                                                provenance: .legacyAdopted)
                        .adoptedForLegacyMigration()?.provenance, .legacyAdopted,
                      "a volume namespace alone is a usable prospective baseline")
        // An explicit selection whose fresh identity is unavailable still records an explicit
        // (unverified) snapshot, so it can never be implicitly rebaselined as legacy.
        let explicitUnavailable = DirectoryIdentityResolver.explicitSelection(fresh: nil)
        t.expectEqual(explicitUnavailable.snapshotValue?.provenance, .explicitSelection,
                      "an explicit selection with unavailable metadata records explicit provenance")
        t.expectNil(explicitUnavailable.snapshotValue?.volumeUUID,
                    "an explicit record records unknown metadata honestly")
        let outcome = DirectoryIdentityResolver.resolve(stored: explicitUnavailable,
                                                        bookmark: Data(), fresh: nil)
        t.expectEqual(outcome.identity, explicitUnavailable,
                      "an explicit unavailable record is retained, never dropped to legacy")
        t.expect(!outcome.adoptAfterValidation,
               "an explicit unavailable record cannot be implicitly rebaselined")
    }
}
