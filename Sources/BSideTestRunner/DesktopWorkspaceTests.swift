import Foundation
import BSideCore
import BSidePlatform

func runDesktopWorkspaceTests() {
    run("DesktopWorkspace.folderContainmentAndNames") { t in
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-workspace-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        do {
            let root = base.appendingPathComponent("chosen")
            let child = root.appendingPathComponent("中文 folder")
            let sibling = base.appendingPathComponent("chosen-extra")
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
            let file = child.appendingPathComponent("音乐 notes.txt")
            try Data("fixture".utf8).write(to: file)
            let outside = root.appendingPathComponent("outside-link")
            try FileManager.default.createSymbolicLink(at: outside, withDestinationURL: sibling)
            let inside = root.appendingPathComponent("inside-link")
            try FileManager.default.createSymbolicLink(at: inside, withDestinationURL: child)
            t.expectEqual(try DesktopWorkspaceFiles.validatedURL(file, within: root), file,
                          "spaces and CJK names stay exact")
            t.expectEqual(try DesktopWorkspaceFiles.validatedURL(inside, within: root).path, child.path,
                          "an in-root symbolic link resolves within the grant")
            for denied in [sibling, outside, root.appendingPathComponent("../chosen-extra")] {
                do {
                    _ = try DesktopWorkspaceFiles.validatedURL(denied, within: root)
                    t.expect(false, "root prefix look-alikes, traversal and escaping symlinks must fail")
                } catch DesktopWorkspaceFileError.outsideRoot {} catch {
                    t.expect(false, "expected containment refusal, got \(error)")
                }
            }
            let listing = try DesktopWorkspaceFiles.children(of: root, within: root, limit: 2)
            t.expectEqual(listing.entries.count, 2, "listing result is bounded")
            t.expect(listing.isTruncated, "large listing discloses the display bound")
            t.expectEqual(try Data(contentsOf: file), Data("fixture".utf8), "browsing never mutates file content")
        } catch { t.expect(false, "fixture failed: \(error)") }
    }

    run("DesktopWorkspace.bookmarkAndStoreIsolation") { t in
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        do {
            let folder = base.appendingPathComponent("selected folder")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let selection = try DirectoryAccessLease.fromSelectedURL(folder)
            let restored = try DirectoryAccessLease.resolvePersistent(selection.persistentData)
            t.expectEqual(restored.lease.url.resolvingSymlinksInPath(), folder.resolvingSymlinksInPath(),
                          "persistent bookmark restores the selected folder")
            let store = base.appendingPathComponent("desktop-workspace.json")
            var preferences = DesktopWorkspacePreferences()
            preferences.folderPath = folder.path
            preferences.folderBookmark = selection.persistentData
            preferences.pinnedApplications = ["/Applications/Example App.app"]
            try preferences.save(to: store)
            t.expectEqual(try DesktopWorkspacePreferences.load(from: store), preferences,
                          "separate desktop preferences roundtrip")
            let malformed = Data("{not-json".utf8)
            try malformed.write(to: store)
            do {
                _ = try DesktopWorkspacePreferences.load(from: store)
                t.expect(false, "corrupt preferences must fail visibly")
            } catch {}
            t.expectEqual(try Data(contentsOf: store), malformed, "loading preserves corrupt evidence")
            preferences.version = 99
            do {
                try preferences.save(to: store)
                t.expect(false, "unknown schema must not overwrite existing data")
            } catch {}
            t.expectEqual(try Data(contentsOf: store), malformed, "unsupported save preserves existing bytes")
        } catch { t.expect(false, "fixture failed: \(error)") }
    }

    run("DesktopWorkspace.hiddenLifecycleIsEmpty") { t in
        let host = DesktopWorkspaceHost()
        host.update(DesktopWorkspacePresentation())
        host.teardown()
        host.teardown()
        t.expect(host.windowFrames.isEmpty, "hidden and repeated teardown retain no desktop windows")
    }
}
